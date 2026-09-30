import {
  AUTH_COOLDOWN_SECONDS,
  AUTH_STATUSES,
  BACKOFF_BASE_SECONDS,
  BACKOFF_CAP_SECONDS,
  BATCH_SIZE,
  DRAIN_MAX_BATCHES,
  RETRY_AFTER_MAX_SECONDS,
  RETRY_AFTER_STATUSES,
  STORAGE_KEYS,
  TRIGGER_FLUSH_DEBOUNCE_MS,
} from './generated/constants';
import { safeGet, safeSet, type EventStore } from './storage';
import type { TriggerEvents } from './triggers';
import type { QueuedEvent } from './types';

/**
 * The upload policy. The Android and iOS SDKs implement the same policy, and all three run the
 * same scenarios (`test/fixtures/uploader-scenarios.json`).
 *
 * A `batch_id` works as a deduplication key only if a batch keeps it until somebody has
 * acknowledged it, and that includes a reload in between. A batch whose response was lost —
 * sent, written, and the connection dropped before the 200 arrived — is sent again under the
 * same id, so the server recognises it instead of counting it twice. So a batch is sealed and
 * written to storage before its first send, every retry sends exactly that, and only a 2xx
 * takes it away.
 *
 * Deliberately free of `fetch`, timers and the page: the transport, the clock and the jitter are
 * handed in, which is what lets the same scenarios drive this and the Android and iOS SDKs.
 */

export interface PendingBatch {
  batch_id: string;
  /**
   * When the batch was sealed. It is resent unchanged, so this is not refreshed per attempt —
   * a retry that restamped it would no longer be the batch the server may already hold.
   */
  sent_at: string;
  events: QueuedEvent[];
}

export interface UploaderState {
  /** The head is the batch in flight; halves of a split wait behind it in order. */
  pending: PendingBatch[];
  /** Consecutive retryable failures. The jitter ceiling doubles with each. */
  attempt: number;
  /** Epoch milliseconds before which nothing is sent. Zero is no gate. */
  next_allowed_at: number;
  /** Epoch milliseconds before which `auth_key` is not tried again. Zero is no cooldown. */
  auth_blocked_until: number;
  /** The write key that was refused. A different key is not held to its cooldown. */
  auth_key: string | null;
}

export interface UploadResponse {
  status: number;
  retryAfter: string | null;
  /** `X-Treebars-Triggers-Version`, which the ingest endpoint sets on an accepted upload and nothing else. */
  triggersVersion?: string | null;
}

/** Sends one batch. A rejection is a network failure; any HTTP answer resolves. */
export type UploadTransport = (batch: PendingBatch) => Promise<UploadResponse>;

const emptyState = (): UploaderState => ({
  pending: [],
  attempt: 0,
  next_allowed_at: 0,
  auth_blocked_until: 0,
  auth_key: null,
});

const finite = (value: unknown): number =>
  typeof value === 'number' && Number.isFinite(value) ? value : 0;

/**
 * The persisted half: pending batches and both gates, under a key of their own.
 *
 * With storage disabled it keeps nothing, and the uploader's own copy is the whole of it — the
 * same trade the queue makes, and for the same consent reason.
 */
export class UploaderStore {
  constructor(private readonly persist: boolean) {}

  load(): UploaderState {
    if (!this.persist) return emptyState();
    const raw = safeGet(STORAGE_KEYS.uploader);
    if (!raw) return emptyState();
    try {
      const parsed = JSON.parse(raw) as Partial<UploaderState>;
      const pending = Array.isArray(parsed.pending)
        ? parsed.pending.filter(
            (batch): batch is PendingBatch =>
              !!batch &&
              typeof batch.batch_id === 'string' &&
              typeof batch.sent_at === 'string' &&
              Array.isArray(batch.events),
          )
        : [];
      return {
        pending,
        attempt: finite(parsed.attempt),
        next_allowed_at: finite(parsed.next_allowed_at),
        auth_blocked_until: finite(parsed.auth_blocked_until),
        auth_key: typeof parsed.auth_key === 'string' ? parsed.auth_key : null,
      };
    } catch {
      return emptyState();
    }
  }

  /** False when the write did not land, which the uploader must know before it empties the queue. */
  save(state: UploaderState): boolean {
    if (!this.persist) return true;
    return safeSet(STORAGE_KEYS.uploader, JSON.stringify(state));
  }
}

export interface UploaderOptions {
  queue: EventStore;
  store: UploaderStore;
  transport: UploadTransport;
  writeKey: string;
  batchSize?: number;
  now?: () => number;
  /** In [0, 1). The jitter source, and the only randomness in the policy. */
  random?: () => number;
  newBatchId?: () => string;
  log?: (message: string) => void;
  /**
   * Asked to call `woken()` at `at`, replacing whatever it was last asked for — one timer, which
   * the uploader keeps pointed at the earliest moment anything needs: a retry falling due, or a
   * listed event's debounce running out. Absent means no wakes, which is how the upload scenarios
   * drive time themselves.
   */
  wake?: (at: number) => void;
  /** The trigger list. Absent means no event flushes early and no version is acted on. */
  triggers?: TriggerEvents;
}

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/**
 * How long a `Retry-After` asks for, in milliseconds from `now`, or null when it says nothing
 * usable. Zero or negative when a date has already passed.
 *
 * Delta-seconds or an IMF-fixdate, and nothing looser. `Date.parse` would accept a dozen other
 * shapes the Android and iOS SDKs do not, and a header one SDK honours and another ignores
 * is three policies again — which is also why the date is computed by hand rather than by
 * `Date.UTC`, which reads a year below 100 as the twentieth century. A value this refuses
 * falls back to jitter, which is never faster than the policy, so being strict cannot make a
 * device hammer anything.
 */
export function retryAfterDelayMs(header: string | null, now: number): number | null {
  if (header === null) return null;
  const value = header.trim();
  // Any number past an hour is capped anyway; the clamp only keeps the arithmetic finite.
  if (/^[0-9]+$/.test(value)) return Math.min(Number(value) * 1000, 1e15);

  const match =
    /^(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun), ([0-9]{2}) ([A-Z][a-z]{2}) ([0-9]{4}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) GMT$/.exec(
      value,
    );
  if (!match) return null;
  const day = Number(match[1]);
  const month = MONTHS.indexOf(match[2]!) + 1;
  const year = Number(match[3]);
  const hour = Number(match[4]);
  const minute = Number(match[5]);
  const second = Number(match[6]);
  if (month < 1 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 60) return null;
  const at = daysFromCivil(year, month, day) * 86_400_000 + ((hour * 60 + minute) * 60 + second) * 1000;
  return at - now;
}

/** Days since 1970-01-01 for a proleptic Gregorian date, month 1-12 (Howard Hinnant's algorithm). */
function daysFromCivil(year: number, month: number, day: number): number {
  const y = month <= 2 ? year - 1 : year;
  const era = Math.floor(y / 400);
  const yearOfEra = y - era * 400;
  const dayOfYear = Math.floor((153 * ((month + 9) % 12) + 2) / 5) + day - 1;
  const dayOfEra = yearOfEra * 365 + Math.floor(yearOfEra / 4) - Math.floor(yearOfEra / 100) + dayOfYear;
  return era * 146_097 + dayOfEra - 719_468;
}

/** `random(0, min(cap, base * 2^attempt))`, in whole milliseconds. */
export function jitterMs(attempt: number, random: number): number {
  const ceilingMs =
    Math.min(BACKOFF_CAP_SECONDS, BACKOFF_BASE_SECONDS * 2 ** Math.min(attempt, 30)) * 1000;
  return Math.floor(random * ceilingMs);
}

/*
 * How far ahead either gate may legitimately be. Anything further is a clock that moved
 * backwards after the gate was written, and a persisted gate would otherwise hold a device
 * silent until the clock caught up — a day, for somebody who set their phone back a day.
 */
const RETRY_GATE_CEILING_MS = Math.max(BACKOFF_CAP_SECONDS, RETRY_AFTER_MAX_SECONDS) * 1000;
const AUTH_GATE_CEILING_MS = AUTH_COOLDOWN_SECONDS * 1000;

export class Uploader {
  private readonly queue: EventStore;
  private readonly store: UploaderStore;
  private readonly transport: UploadTransport;
  private readonly writeKey: string;
  private readonly batchSize: number;
  private readonly now: () => number;
  private readonly random: () => number;
  private readonly newBatchId: () => string;
  private readonly log: (message: string) => void;
  private readonly wake: ((at: number) => void) | null;
  private readonly triggers: TriggerEvents | null;
  private state: UploaderState;
  private flushing = false;
  /** When the one wake is due, or zero when none is armed. */
  private wakeAt = 0;
  /** The newest trigger version the current flush's answers carried. */
  private seenTriggersVersion: string | null = null;

  constructor(options: UploaderOptions) {
    this.queue = options.queue;
    this.store = options.store;
    this.transport = options.transport;
    this.writeKey = options.writeKey;
    this.batchSize = Math.max(1, options.batchSize ?? BATCH_SIZE);
    this.now = options.now ?? (() => Date.now());
    this.random = options.random ?? Math.random;
    this.newBatchId = options.newBatchId ?? mintBatchId;
    this.log = options.log ?? (() => {});
    this.wake = options.wake ?? null;
    this.triggers = options.triggers ?? null;

    this.state = this.store.load();
    /*
     * A batch is written out and only then taken off the queue, so a page closed between the two
     * leaves its events in both. They are the same events under the same ids, and sending the
     * queue's copies as a new batch is exactly the double count this exists to prevent.
     */
    this.queue.removeIds(this.pendingEventIds());
  }

  /** Bumped by `discard`, so an upload that was out at the time settles nothing when it answers. */
  private generation = 0;

  /**
   * Drops the queue and every sealed batch, with the gates they had closed — for an opt-out or a wipe,
   * where the person said stop rather than "after these".
   */
  discard(): void {
    this.generation += 1;
    this.queue.clear();
    this.state = emptyState();
    this.store.save(this.state);
  }

  /** Events sealed into batches and not yet acknowledged. */
  get pendingEvents(): number {
    return this.state.pending.reduce((total, batch) => total + batch.events.length, 0);
  }

  /**
   * Sends batches until the queue is empty, a gate closes, a batch fails, or
   * `DRAIN_MAX_BATCHES` have gone — and then, if an answer said the trigger list has moved on,
   * fetches it.
   *
   * Nothing is awaited before the first request, which the page-hide path depends on: a flush
   * started while the page is being hidden gets its request out before the handler returns.
   *
   * The refresh waits for the drain rather than interrupting it, so the uploads a page has
   * queued are never held up behind a list, and a drain whose answers all carried the new
   * version fetches the list once.
   */
  async flush(): Promise<void> {
    if (this.flushing) return;
    this.flushing = true;
    this.seenTriggersVersion = null;
    try {
      await this.drain();
    } finally {
      this.flushing = false;
    }
    await this.triggers?.observe(this.seenTriggersVersion);
  }

  /**
   * What the host calls when the wake it was asked for fires: the wake is spent, then a flush.
   *
   * Told rather than inferred from the clock. The timer runs on a monotonic clock and `now()` is the
   * wall clock, so a wake can fire a moment before `now()` reaches the time it was armed for — and
   * a wake that still looked pending would refuse to arm the next one, leaving a retry to the
   * thirty-second tick.
   */
  woken(): Promise<void> {
    this.wakeAt = 0;
    return this.flush();
  }

  /**
   * A logged event, told to the uploader after it is on the queue. A listed one asks for a flush
   * `TRIGGER_FLUSH_DEBOUNCE_MS` from now.
   *
   * It asks and nothing more. The flush that answers checks the `Retry-After` gate and the auth
   * cooldown like every other flush, so a trigger cannot send anything a 429 said to hold — and a
   * wake already due sooner, a retry's, is left where it is and carries the trigger with it. Only
   * the first trigger arms the wake: later ones inside the second ride it rather than pushing it
   * back, or a trigger every nine hundred milliseconds would never be sent.
   */
  eventLogged(eventName: string): void {
    if (!this.triggers?.has(eventName)) return;
    this.requestWake(this.now() + TRIGGER_FLUSH_DEBOUNCE_MS);
  }

  private async drain(): Promise<void> {
    for (let sends = 0; sends < DRAIN_MAX_BATCHES; sends += 1) {
      if (this.gated(this.now())) return;
      const batch = this.state.pending[0] ?? this.seal();
      if (!batch) return;

      const started = this.generation;
      let response: UploadResponse | null = null;
      try {
        response = await this.transport(batch);
      } catch (error) {
        this.log(`upload failed: ${String(error)}`);
      }
      // Discarded while the request was out: the batch it answers for is gone, and all behind it.
      if (this.generation !== started) return;
      if (response?.triggersVersion) this.seenTriggersVersion = response.triggersVersion;
      if (!this.settle(batch, response)) return;
    }
  }

  /**
   * One wake, at the earliest moment anything has asked for.
   *
   * A wake still sleeping towards this moment or an earlier one is left alone: it will flush, find
   * whatever gate is closed, and ask again. A wake that has fired is spent (`woken`), and one whose
   * time has passed without firing — a throttled background tab — is not treated as pending either.
   */
  private requestWake(at: number): void {
    if (!this.wake) return;
    if (this.wakeAt > this.now() && this.wakeAt <= at) return;
    this.wakeAt = at;
    this.wake(at);
  }

  /**
   * The batch page hide should send: the pending head, or a newly sealed one. Null when a gate
   * is closed or there is nothing to send.
   *
   * Also null while a flush is in flight. Its request is already out, and either it carries
   * `keepalive` and outlives the page, or it is too large for the keepalive quota — which a
   * beacon shares, so the beacon would be refused as well. A second copy adds only a duplicate.
   *
   * What it returns stays pending: a beacon is never answered, and only an answer removes a
   * batch. The next flush sends it again under the same id and the server recognises it.
   */
  nextBeaconBatch(): PendingBatch | null {
    if (this.flushing || this.gated(this.now())) return null;
    return this.state.pending[0] ?? this.seal();
  }

  private pendingEventIds(): Set<string> {
    return new Set(this.state.pending.flatMap((batch) => batch.events.map((event) => event.event_id)));
  }

  private save(): boolean {
    const saved = this.store.save(this.state);
    if (!saved) this.log('upload state could not be written to storage');
    return saved;
  }

  /**
   * Whether either gate is closed at `now`, re-basing one that sits further ahead than it ever
   * could have been written — see the ceilings above.
   */
  private gated(now: number): boolean {
    let moved = false;
    if (this.state.next_allowed_at > now + RETRY_GATE_CEILING_MS) {
      this.state.next_allowed_at = now + RETRY_GATE_CEILING_MS;
      moved = true;
    }
    if (this.state.auth_blocked_until > now + AUTH_GATE_CEILING_MS) {
      this.state.auth_blocked_until = now + AUTH_GATE_CEILING_MS;
      moved = true;
    }
    if (moved) this.save();

    if (this.state.auth_blocked_until > now && this.state.auth_key === this.writeKey) return true;
    if (this.state.next_allowed_at > now) {
      this.requestWake(this.state.next_allowed_at);
      return true;
    }
    return false;
  }

  /**
   * Takes the head of the queue as a new pending batch, written before anything is sent.
   *
   * The queue's copies are removed only once that write has landed. If it did not — a full
   * quota — they stay queued and are removed on acknowledgement instead, so a reload in between
   * re-sends them rather than losing them.
   */
  private seal(): PendingBatch | null {
    const events = this.queue.peek(this.batchSize);
    if (events.length === 0) return null;

    const batch: PendingBatch = {
      batch_id: this.newBatchId(),
      sent_at: new Date(this.now()).toISOString(),
      events,
    };
    this.state.pending = [batch];
    if (this.save()) this.queue.removeIds(new Set(events.map((event) => event.event_id)));
    return batch;
  }

  /** Applies one answer. True when the drain may continue. */
  private settle(batch: PendingBatch, response: UploadResponse | null): boolean {
    const now = this.now();
    const status = response?.status ?? 0;

    if (response && status >= 200 && status < 300) {
      this.finish(batch);
      this.clearGates();
      this.save();
      this.log(`uploaded ${batch.events.length} event(s)`);
      return true;
    }

    if (response && status === 413) {
      if (batch.events.length > 1) {
        /*
         * Halves under derived ids, written in place of the batch. Derived rather than minted so
         * that a split replayed after a crash — the whole batch resent, refused again, split
         * again — produces the same two ids, and a half the server already took is recognised.
         */
        const middle = Math.ceil(batch.events.length / 2);
        this.state.pending.splice(
          0,
          1,
          { batch_id: `${batch.batch_id}.0`, sent_at: batch.sent_at, events: batch.events.slice(0, middle) },
          { batch_id: `${batch.batch_id}.1`, sent_at: batch.sent_at, events: batch.events.slice(middle) },
        );
        this.clearRetry();
        this.save();
        this.log(`batch of ${batch.events.length} too large; split in two`);
        return true;
      }
      this.drop(batch, status);
      return false;
    }

    if (response && (AUTH_STATUSES as readonly number[]).includes(status)) {
      this.clearRetry();
      this.state.auth_blocked_until = now + AUTH_GATE_CEILING_MS;
      this.state.auth_key = this.writeKey;
      this.save();
      this.log(`upload refused (${status}); the write key waits ${AUTH_COOLDOWN_SECONDS}s`);
      return false;
    }

    const retryable = !response || (RETRY_AFTER_STATUSES as readonly number[]).includes(status);
    if (!retryable && status >= 400 && status < 500) {
      this.drop(batch, status);
      return false;
    }

    /*
     * Everything else is worth another attempt: no answer at all, a 5xx, a 429, and whatever
     * a proxy invents. The server's own delay wins where it gave a usable one; otherwise jitter.
     */
    const asked = (RETRY_AFTER_STATUSES as readonly number[]).includes(status)
      ? retryAfterDelayMs(response?.retryAfter ?? null, now)
      : null;
    const delay =
      asked !== null && asked > 0
        ? Math.min(asked, RETRY_AFTER_MAX_SECONDS * 1000)
        : jitterMs(this.state.attempt, this.random());
    this.state.next_allowed_at = now + delay;
    this.state.attempt += 1;
    this.save();
    this.log(`upload not accepted (${status || 'network'}); next attempt in ${delay}ms`);
    this.requestWake(this.state.next_allowed_at);
    return false;
  }

  /** A batch that will never succeed. Gone from both stores, and the drain ends with it. */
  private drop(batch: PendingBatch, status: number): void {
    this.finish(batch);
    this.clearRetry();
    this.save();
    this.log(`server refused ${batch.events.length} event(s) with ${status}; discarded`);
  }

  private finish(batch: PendingBatch): void {
    this.state.pending = this.state.pending.filter((each) => each !== batch);
    // Normally a no-op: see `seal` for the one case where the queue still holds them.
    this.queue.removeIds(new Set(batch.events.map((event) => event.event_id)));
  }

  /** An answer from the server proves the path works, so the backoff starts again from zero. */
  private clearRetry(): void {
    this.state.attempt = 0;
    this.state.next_allowed_at = 0;
  }

  private clearGates(): void {
    this.clearRetry();
    this.state.auth_blocked_until = 0;
    this.state.auth_key = null;
  }
}

function mintBatchId(): string {
  if (typeof crypto !== 'undefined' && 'randomUUID' in crypto) return crypto.randomUUID();
  return `batch_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 10)}`;
}
