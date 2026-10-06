import {
  DEFAULT_FLUSH_INTERVAL_MS,
  FLUSH_DEBOUNCE_MS,
  FLUSH_SPACING_MAX_MS,
  FLUSH_SPACING_METERED_MS,
  FLUSH_SPACING_MIN_MS,
  FLUSH_SPACING_MS,
  FLUSH_SPACING_TEST_MS,
} from './generated/constants';

/**
 * The pace: when an event is uploaded. The Android and iOS SDKs implement the same pace, and all
 * three run the same scenarios (`test/fixtures/flush-pace-scenarios.json`).
 *
 * An event arms one upload. It is due a debounce after the event, or at the end of the spacing
 * since the last upload began, whichever is later — so an event on a quiet page is on its way a
 * second after it happened, and a busy page is held to one upload per spacing. The first event
 * arms the wait and later ones ride it rather than pushing it back, or a page logging an event
 * every nine hundred milliseconds would never upload.
 *
 * The spacing is counted from when an upload BEGAN, and from every upload, whoever asked for it:
 * the one armed here, a listed event's, a full batch, a retry, a `flush()` the page called, the one
 * sent as the page is hidden. An upload that begins while one is armed pushes the armed one out to
 * the end of its own spacing: the upload that began has normally carried what the armed one was
 * for, and what it left is not sent sooner than the spacing allows.
 *
 * A backlog arms one too. A flush sends a bounded number of batches, so one that ends with events
 * still waiting, and nothing holding the device back, arms the next a spacing after its last upload
 * began — with no event needed to ask for it, or a page that logged nothing more would keep what
 * it had left until its next visit.
 *
 * It decides when, and nothing else. What fires is an ordinary flush, so the uploader's gates — a
 * `Retry-After`, a refused write key — decide whether a request goes; and neither a full batch nor
 * an event on the trigger list waits for any of this.
 *
 * Deliberately free of timers, the network and the page: the clock, the conditions and the one
 * wake are handed in, which is what lets the scenarios drive it without waiting.
 */

/** What about this device slows its uploads down, read as an upload is armed and not kept. */
export interface FlushConditions {
  /** Saving data or power: the person asked the whole device to do less. */
  constrained: boolean;
  /** A network paid for by use. */
  metered: boolean;
}

/** What decides the spacing, apart from the device's conditions. */
export interface FlushSpacingRule {
  /** The interval the app chose at `init`, in milliseconds. Absent when it chose none. */
  chosen?: number | null;
  /** Whether the write key is a test environment's. */
  testKey: boolean;
  /** The spacing the last accepted upload named, already within bounds. Null until one has. */
  named: number | null;
}

/** A test environment's write key. */
export const isTestKey = (writeKey: string): boolean => writeKey.startsWith('pk_test_');

/**
 * How far apart two uploads are kept, in milliseconds.
 *
 * A device saving data keeps the widest spacing whatever else is true: the person asked the whole
 * device to do less, and that outranks an app's choice, a test key and the server alike. Otherwise
 * the app's own interval is the spacing, never tighter than the debounce. Otherwise a test key
 * keeps almost none — somebody is watching a screen for the event they just caused. Otherwise it is
 * what the last accepted upload named, or the default before any has, and never under the metered
 * floor on a network paid for by use.
 */
export function flushSpacingMs(rule: FlushSpacingRule, conditions: FlushConditions): number {
  if (conditions.constrained) return DEFAULT_FLUSH_INTERVAL_MS;
  // Not a number is no choice at all, rather than a spacing no clock could count.
  if (typeof rule.chosen === 'number' && !Number.isNaN(rule.chosen)) return Math.max(rule.chosen, FLUSH_DEBOUNCE_MS);
  if (rule.testKey) return FLUSH_SPACING_TEST_MS;
  const asked = rule.named ?? FLUSH_SPACING_MS;
  return conditions.metered ? Math.max(asked, FLUSH_SPACING_METERED_MS) : asked;
}

/**
 * When an upload armed at `now` is due. `spacing` is asked only when there is an upload to space
 * from, so a quiet device's conditions are never read.
 */
export function flushDueAt(now: number, lastBegan: number | null, spacing: () => number): number {
  const debounced = now + FLUSH_DEBOUNCE_MS;
  if (lastBegan === null) return debounced;
  // An upload that began after `now` is a clock that moved backwards since; it began no later than now.
  return Math.max(debounced, Math.min(lastBegan, now) + spacing());
}

/**
 * A spacing held to the bounds a device accepts, or null for anything that is not a number.
 *
 * Outside the bounds it is taken as the nearest bound rather than ignored, so a server asking for
 * more than a device will give still gets the most it will give.
 */
export function boundedFlushSpacing(value: unknown): number | null {
  if (typeof value !== 'number' || Number.isNaN(value)) return null;
  return Math.min(Math.max(value, FLUSH_SPACING_MIN_MS), FLUSH_SPACING_MAX_MS);
}

/**
 * The spacing a response named, in milliseconds and within bounds, or null when it named none this
 * can read — which changes nothing, and the spacing in force stays.
 *
 * Whole milliseconds and nothing looser: `Number` would also take `1e3`, `0x10` and an empty
 * string, and a header one SDK honours and another ignores is three paces.
 */
export function readFlushSpacing(header: string | null | undefined): number | null {
  const value = header?.trim();
  if (!value || !/^[0-9]+$/.test(value)) return null;
  // Digits past what a number holds exactly are far past the upper bound either way.
  return boundedFlushSpacing(Number(value));
}

export interface FlushPaceOptions {
  writeKey: string;
  /** The interval the app chose at `init`, in milliseconds. Absent when it chose none. */
  chosenMs?: number | null;
  /** The spacing an earlier page load was told, so this one starts with it. */
  named?: number | null;
  now?: () => number;
  /** Read each time an upload is armed. Absent means nothing slows this device down. */
  conditions?: () => FlushConditions;
  /**
   * Asked to call `woken()` at `at`, replacing whatever it was last asked for: one timer, which is
   * the armed upload.
   */
  wake: (at: number) => void;
  /** Asks the uploader to drain. The only thing a fired wake does. */
  flush: () => Promise<void> | void;
}

const UNHURRIED: FlushConditions = { constrained: false, metered: false };

export class FlushPace {
  private readonly rule: FlushSpacingRule;
  private readonly now: () => number;
  private readonly conditions: () => FlushConditions;
  private readonly wake: (at: number) => void;
  private readonly flush: () => Promise<void> | void;
  /** When the last upload began. Null until one has. */
  private lastBegan: number | null = null;
  /** When the armed upload is due. Null when none is armed. */
  private due: number | null = null;

  constructor(options: FlushPaceOptions) {
    this.rule = {
      chosen: options.chosenMs ?? null,
      testKey: isTestKey(options.writeKey),
      named: boundedFlushSpacing(options.named),
    };
    this.now = options.now ?? (() => Date.now());
    this.conditions = options.conditions ?? (() => UNHURRIED);
    this.wake = options.wake;
    this.flush = options.flush;
  }

  /** When the armed upload is due, in epoch milliseconds. Null when none is armed. */
  get dueAt(): number | null {
    return this.due;
  }

  /** An event is on the queue. Arms an upload unless one is armed already. */
  eventLogged(): void {
    if (this.due !== null) return;
    this.arm(flushDueAt(this.now(), this.lastBegan, () => this.spacing()));
  }

  /**
   * A batch is going out now. Said for every one, because the spacing is counted from all of them —
   * and whether or not it is accepted, because what the spacing bounds is requests.
   */
  uploadBegan(): void {
    const now = this.now();
    this.lastBegan = now;
    if (this.due === null) return;
    const earliest = now + this.spacing();
    if (earliest > this.due) this.arm(earliest);
  }

  /** The spacing an accepted upload named, already within bounds. Kept from then on. */
  spacingNamed(milliseconds: number): void {
    this.rule.named = milliseconds;
  }

  /**
   * A flush ended with events still waiting and nothing holding the device back. Arms the upload
   * that carries on, a spacing after the last one began, unless one is armed already — every
   * upload that began pushed an armed one at least that far out.
   */
  backlogLeft(): void {
    if (this.due !== null) return;
    const now = this.now();
    // As in `flushDueAt`: an upload cannot have begun after now.
    this.arm((this.lastBegan === null ? now : Math.min(this.lastBegan, now)) + this.spacing());
  }

  /**
   * What the host calls when the wake it was asked for fires. Spent before it flushes, so the
   * upload it starts finds nothing armed to push out.
   */
  async woken(): Promise<void> {
    if (this.due === null) return;
    this.due = null;
    await this.flush();
  }

  private spacing(): number {
    return flushSpacingMs(this.rule, this.conditions());
  }

  private arm(at: number): void {
    this.due = at;
    this.wake(at);
  }
}
