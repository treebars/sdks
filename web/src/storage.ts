import { QUEUE_CAP, STORAGE_KEYS } from './generated/constants';
import type { QueuedEvent } from './types';

/**
 * Persistent event queue backed by localStorage.
 *
 * A browser tab can be closed at any moment, so events buffered only in memory are
 * routinely lost. Persisting them means an event captured just before a navigation
 * is still delivered on the next page load.
 *
 * Every storage access is guarded: Safari in private mode, a blocked third-party
 * context and a full quota all throw on write, and analytics must never break the
 * host page.
 */

const QUEUE_KEY = 'treebars.queue.v1';
const DEVICE_KEY = 'treebars.device.v1';
const CONTEXT_HASH_KEY = 'treebars.device_context.v1';
const FETCH_SECRET_KEY = 'treebars.fetch_secret.v1';
const FIRST_SEEN_KEY = 'treebars.first_seen.v1';
const IDENTIFIED_USER_KEY = 'treebars.identified_user.v1';
const SIGNED_IN_USER_KEY = STORAGE_KEYS.signedInUser;
const SIGNED_IN_USER_SIGNATURE_KEY = STORAGE_KEYS.signedInUserSignature;

/** Bounds the queue so a page that never reaches the network cannot fill the quota. */
const MAX_QUEUED_EVENTS = QUEUE_CAP;

export function safeGet(key: string): string | null {
  try {
    return globalThis.localStorage?.getItem(key) ?? null;
  } catch {
    return null;
  }
}

export function safeSet(key: string, value: string): boolean {
  try {
    globalThis.localStorage?.setItem(key, value);
    return true;
  } catch {
    return false;
  }
}

export function safeRemove(key: string): void {
  try {
    globalThis.localStorage?.removeItem(key);
  } catch {
    // A storage that will not answer holds nothing to remove.
  }
}

/**
 * The opt-out (`optOut()`), read once at `init`. Deliberately not among what `wipeStoredData` clears:
 * it is the person's answer rather than data about them, and a wipe that turned a "no" back into a
 * "yes" would be the SDK deciding for them.
 */
const OPT_OUT_KEY = 'treebars.opted_out.v1';

export function readOptedOut(persist: boolean): boolean {
  return persist && safeGet(OPT_OUT_KEY) === '1';
}

export function writeOptedOut(optedOut: boolean, persist: boolean): void {
  if (!persist) return;
  if (optedOut) safeSet(OPT_OUT_KEY, '1');
  else safeRemove(OPT_OUT_KEY);
}

/**
 * What an earlier visit left unsent — the queue and the uploader's sealed batches — for a page that
 * starts opted out. That page keeps its own stores in memory and never reads these, so without this a
 * later `optIn()` would send, on the next visit, events recorded before the "no".
 */
export function dropStoredQueue(): void {
  safeRemove(QUEUE_KEY);
  safeRemove(STORAGE_KEYS.uploader);
}

/**
 * Every key this SDK keeps in this browser, in both storages — everything under `treebars.` —
 * except the opt-out. A prefix rather than a list, so a store added later cannot be forgotten by it:
 * the device id and its secret, the queue and the uploader's sealed batches, the session, who was
 * signed in and who had been, the in-app and notification stores, the trigger list, the carried
 * click. `wipeLocalData` is its only caller.
 */
export function wipeStoredData(): void {
  for (const name of ['localStorage', 'sessionStorage'] as const) {
    try {
      const storage = globalThis[name];
      if (!storage) continue;
      const doomed: string[] = [];
      for (let index = 0; index < storage.length; index += 1) {
        const key = storage.key(index);
        if (key?.startsWith('treebars.') && key !== OPT_OUT_KEY) doomed.push(key);
      }
      for (const key of doomed) storage.removeItem(key);
    } catch {
      // A storage that will not answer holds nothing to remove.
    }
  }
}

/*
 * Which write key the stored data was recorded under.
 *
 * Almost everything this SDK keeps belongs to ONE project: the queue and the uploader's sealed batches, the session a
 * `session_end` will be sent for, the in-app queue and its ledger, the notification feed, the trigger list, the
 * carried ad click, the context this device last reported. So the key is stamped beside the data, and a different key at `init` — a new project, a key moved to another environment —
 * drops the data before any store reads it. Events are never sent to a project they were not recorded for, and
 * in-app messages fetched for one project are never drawn or reported under another.
 *
 * Dropped rather than sent under the key it was recorded with: this SDK holds one key, and a key that was rotated away
 * is typically revoked, so there is nowhere left to send it. That includes rotating a key WITHIN one project, which the
 * browser cannot tell from a switch to another project without asking the server: what is lost there is the unsent
 * tail of the previous visit and one `session_end`, which is the cheaper mistake.
 *
 * A keep-list rather than a drop-list, so a store added later is dropped by default: kept is only what belongs to the
 * browser or the person rather than the project — the device id and its secret (which move together), the opt-out,
 * who is signed in and who had been, the first-seen and first-session facts, the push prompt's history, and this
 * stamp. The device context is dropped on purpose: the new project has never seen this device, so it has to be
 * reported again.
 *
 * No stamp at all is a first visit, or data stored before the stamp was: the key is adopted and nothing is dropped,
 * because there is nothing to compare against.
 */
const WRITE_KEY_KEY = 'treebars.write_key.v1';

const BROWSER_KEYS = new Set<string>([
  WRITE_KEY_KEY,
  OPT_OUT_KEY,
  DEVICE_KEY,
  FETCH_SECRET_KEY,
  FIRST_SEEN_KEY,
  IDENTIFIED_USER_KEY,
  SIGNED_IN_USER_KEY,
  SIGNED_IN_USER_SIGNATURE_KEY,
  'treebars.session_ever_started.v1',
  'treebars.first_session.v1',
  'treebars.push.prompt.v1',
  'treebars.push.permission.v1',
]);

/**
 * Stamps this browser's stored data with `writeKey`, dropping what another key left first. Returns whether anything was
 * dropped. Call before any store is constructed: they read what they hold once, when they are built.
 */
export function claimStoredData(writeKey: string): boolean {
  const stamped = safeGet(WRITE_KEY_KEY);
  if (stamped === writeKey) return false;
  const dropped = stamped !== null;
  if (dropped) {
    for (const name of ['localStorage', 'sessionStorage'] as const) {
      try {
        const storage = globalThis[name];
        if (!storage) continue;
        const doomed: string[] = [];
        for (let index = 0; index < storage.length; index += 1) {
          const key = storage.key(index);
          if (key?.startsWith('treebars.') && !BROWSER_KEYS.has(key)) doomed.push(key);
        }
        for (const key of doomed) storage.removeItem(key);
      } catch {
        // A storage that will not answer holds nothing to drop.
      }
    }
  }
  safeSet(WRITE_KEY_KEY, writeKey);
  return dropped;
}

export class EventStore {
  private memory: QueuedEvent[] = [];

  constructor(private readonly persist: boolean) {
    if (persist) this.memory = this.read();
  }

  private read(): QueuedEvent[] {
    const raw = safeGet(QUEUE_KEY);
    if (!raw) return [];
    try {
      const parsed = JSON.parse(raw) as QueuedEvent[];
      return Array.isArray(parsed) ? parsed : [];
    } catch {
      return [];
    }
  }

  private write(): void {
    if (!this.persist) return;
    // A failed write is not fatal: the in-memory copy still flushes this page view.
    safeSet(QUEUE_KEY, JSON.stringify(this.memory));
  }

  add(event: QueuedEvent): void {
    this.memory.push(event);
    // Drop the oldest rather than the newest: recent behaviour is more useful, and
    // the alternative is silently refusing to record anything once full.
    if (this.memory.length > MAX_QUEUED_EVENTS) {
      this.memory.splice(0, this.memory.length - MAX_QUEUED_EVENTS);
    }
    this.write();
  }

  peek(count: number): QueuedEvent[] {
    return this.memory.slice(0, count);
  }

  remove(count: number): void {
    this.memory.splice(0, count);
    this.write();
  }

  /**
   * Removes these events wherever they are, rather than the first `n`.
   *
   * By id because the uploader removes a batch's events at two moments that are not "now, from
   * the head": when a reload finds a batch in both stores, and when a batch whose state write
   * failed is finally acknowledged. By the second, the page has gone on tracking for the length
   * of a request, and at the cap every event it tracked evicted one from the front — so a
   * `remove(n)` would take events that were never sent.
   */
  removeIds(ids: ReadonlySet<string>): number {
    const before = this.memory.length;
    this.memory = this.memory.filter((event) => !ids.has(event.event_id));
    const removed = before - this.memory.length;
    if (removed > 0) this.write();
    return removed;
  }

  all(): QueuedEvent[] {
    return [...this.memory];
  }

  clear(): void {
    this.memory = [];
    this.write();
  }

  get size(): number {
    return this.memory.length;
  }
}

/**
 * A stable pseudonymous device id.
 *
 * This is a first-party random identifier: nothing about the device or browser feeds it,
 * so clearing site data resets it. The SDK does report coarse browser and OS dimensions
 * from ./device, but they are derived independently and never mixed into this value —
 * the id stays a random number that the user can clear.
 */
function randomHex(bytes: number): string {
  const buffer = new Uint8Array(bytes);
  crypto.getRandomValues(buffer);
  return [...buffer].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/**
 * Whether this browser can mint the device secret at all — WebCrypto's generator, which
 * needs no secure context and which every browser this SDK otherwise runs in has.
 *
 * The secret is the credential in-app and inbox reads are made with, so it only ever comes
 * from a cryptographic generator. A browser without WebCrypto gets no SDK rather than a
 * guessable secret — `init` stays off and says why.
 */
export function canMintSecrets(): boolean {
  return typeof crypto !== 'undefined' && typeof crypto.getRandomValues === 'function';
}

/**
 * The secret this browser authenticates its in-app message sync with.
 *
 * Stored beside the device id so clearing site data takes both: the id and its secret
 * belong together, and one is never kept without the other.
 */
export function getFetchSecret(persist: boolean): string {
  if (persist) {
    const existing = safeGet(FETCH_SECRET_KEY);
    if (existing) return existing;
  }
  const secret = randomHex(32);
  if (persist) safeSet(FETCH_SECRET_KEY, secret);
  return secret;
}

export function getDeviceId(persist: boolean): string {
  if (persist) {
    const existing = safeGet(DEVICE_KEY);
    if (existing) return existing;
  }

  // getRandomValues rather than randomUUID, which needs a secure context. A browser
  // without it never gets this far (`canMintSecrets`).
  const id = `dev_${randomHex(16)}`;

  if (persist) safeSet(DEVICE_KEY, id);
  return id;
}

/**
 * How long a report is trusted before the browser says it all again.
 *
 * The hash alone would be a one-way promise: this browser remembers having reported, but
 * cannot see whether Treebars still holds the report — a project reset or a privacy erase
 * removes it, and nothing on this side could notice. A week costs one extra event per
 * browser per week and lets the device record repair itself.
 */
const CONTEXT_REPORT_TTL_MS = 7 * 24 * 60 * 60 * 1000;

/**
 * Whether the device context needs reporting, recording it if so.
 *
 * True when the context has changed, and also when the last report has aged past the TTL.
 *
 * With storage off, under a consent regime, this returns false rather than true: the
 * caller has already been told not to persist anything, and re-registering the device on
 * every page load would be the noisiest possible way to ignore that.
 *
 * Hash and timestamp are one value rather than two keys, so a write that only half lands
 * cannot leave a hash that never expires — the failure the TTL exists to end.
 */
export function shouldReportContext(hash: string, persist: boolean): boolean {
  if (!persist) return false;

  const stored = safeGet(CONTEXT_HASH_KEY);
  if (stored && !isStale(stored, hash)) return false;

  safeSet(CONTEXT_HASH_KEY, `${hash}:${Date.now()}`);
  return true;
}

function isStale(stored: string, hash: string): boolean {
  const separator = stored.lastIndexOf(':');
  // A record with no timestamp re-reports once, which is what refreshes it.
  if (separator === -1) return true;

  const reportedAt = Number(stored.slice(separator + 1));
  if (!Number.isFinite(reportedAt)) return true;

  return stored.slice(0, separator) !== hash || Date.now() - reportedAt >= CONTEXT_REPORT_TTL_MS;
}

/**
 * When this browser was first seen, minted on the first visit that is allowed to persist.
 *
 * Two callers, one fact. The profile wants the timestamp — it is the one date about a
 * person the SDK can state and the site usually cannot — and `app_open` wants the
 * boolean underneath it.
 *
 * With storage off, under a consent regime, this reports neither. Deriving a first visit
 * from "nothing was stored" would declare every page load a first visit and walk the
 * profile's `first_seen_at` forward to today on every one of them, which is a worse
 * answer than no answer.
 */
export function readFirstSeen(persist: boolean): { firstSeenAt?: string; isFirstVisit: boolean } {
  if (!persist) return { isFirstVisit: false };

  const existing = safeGet(FIRST_SEEN_KEY);
  if (existing) return { firstSeenAt: existing, isFirstVisit: false };

  const now = new Date().toISOString();
  if (!safeSet(FIRST_SEEN_KEY, now)) return { isFirstVisit: false };

  return { firstSeenAt: now, isFirstVisit: true };
}

/** The last user id identified in this browser, so a repeat identify is recognisable. */
export function readIdentifiedUser(persist: boolean): string | null {
  return persist ? safeGet(IDENTIFIED_USER_KEY) : null;
}

export function writeIdentifiedUser(userId: string, persist: boolean): void {
  if (persist) safeSet(IDENTIFIED_USER_KEY, userId);
}

/**
 * Who is signed in RIGHT NOW, which is a different question from the one above.
 *
 * `identifiedUser` is history and survives `reset()`, because `previous_user_id` is
 * computed from it. This is state: written at sign-in, cleared at sign-out, and restored on
 * `init()` so that after a reload the SDK's reads are still made for the signed-in person
 * rather than as an anonymous device.
 */
export function readSignedInUser(persist: boolean): string | null {
  return persist ? safeGet(SIGNED_IN_USER_KEY) : null;
}

/**
 * The customer backend's signature for the signed-in account id, kept as one with it.
 *
 * Written, replaced and cleared together with the id, never alone: a signature left over from the
 * previous person must never be sent beside the next one's id, where it proves nothing. So
 * `writeSignedInUser` without a signature clears it rather than keeping it.
 */
export function readSignedInUserSignature(persist: boolean): string | null {
  return persist ? safeGet(SIGNED_IN_USER_SIGNATURE_KEY) : null;
}

export function writeSignedInUser(userId: string, persist: boolean, signature?: string): void {
  if (!persist) return;
  safeSet(SIGNED_IN_USER_KEY, userId);
  if (signature) safeSet(SIGNED_IN_USER_SIGNATURE_KEY, signature);
  else safeRemove(SIGNED_IN_USER_SIGNATURE_KEY);
}

export function clearSignedInUser(persist: boolean): void {
  if (!persist) return;
  safeRemove(SIGNED_IN_USER_KEY);
  safeRemove(SIGNED_IN_USER_SIGNATURE_KEY);
}
