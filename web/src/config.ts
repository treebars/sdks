import {
  AUTH_COOLDOWN_SECONDS,
  AUTH_STATUSES,
  CONFIG_EXPOSURE_FLOOR_SECONDS,
  CONFIG_RETRY_SECONDS,
  RETRY_AFTER_MAX_SECONDS,
  RETRY_AFTER_STATUSES,
  STORAGE_KEYS,
} from './generated/constants';
import { safeGet, safeRemove, safeSet } from './storage';

/**
 * Remote config: values an app reads by key and Treebars decides.
 *
 * Treebars works out this install's answers and hands them over whole — one value for each variable, and
 * nothing about why. This file holds them, answers reads from them, and decides when to ask again. The Android
 * and iOS SDKs implement the same rules, and all three run the same scenarios
 * (`test/fixtures/config-scenarios.json`).
 *
 * **A read never waits and never fails.** It answers from what this install holds, and the fallback the caller
 * passed when it holds nothing for that key or holds something of another kind.
 *
 * **A key keeps its answer for the session.** The first read of a key in a session fixes what that key reads
 * as until the session ends — "not set" included — so a screen never changes under somebody because a newer
 * answer arrived half-way through. A key not read yet takes the newest answer held; a new session, or
 * `activate()`, forgets what was read.
 *
 * **It asks only when there is something to learn.** Every accepted upload names the current version, so this
 * learns its copy is stale from an answer it was already waiting for. With nothing held and no version named,
 * nothing is asked at all: an app whose project has no variables never makes a config request. It also asks
 * when who is asking changes in a way an answer may depend on — an account signs in or out, the app sets
 * different attributes, the device describes itself differently than it did — and whenever the app says to.
 *
 * **An account's answers do not outlive the account.** At sign-out, and when a different account signs in, the
 * answers that depended on the last one are dropped at once, before the next ones arrive.
 *
 * **A variant is reported when a read answers it, not when it arrives.** A value that is an experiment's variant
 * says so, and the first read to answer it reports that this install was shown that variant — at most once a
 * day for the same variant, and at once for a different one. A value held and never read reports nothing: no
 * screen used it. Nor does a read answered by an override, a read as another kind, or a listing of every value.
 */

export type ConfigType = 'boolean' | 'string' | 'number' | 'json';

export interface ConfigEntry {
  key: string;
  type: ConfigType;
  value: unknown;
  /** The answer may differ for a different account, or with nobody signed in. */
  user_dependent?: boolean;
  /** Set when the value is an experiment's variant. */
  experiment?: { id: string; key: string; variant: string; unit: string };
}

/** The answers held, and how they were asked for. */
interface HeldConfig {
  version: string;
  values: ConfigEntry[];
  /** How the device described itself when these were asked for. */
  context: string;
  /** Who is asking has changed since: these stand until the next answer, and another ask is owed. */
  stale: boolean;
}

/** What this install was last reported as shown, by experiment id. */
type Exposed = Record<string, { variant: string; at: number }>;

interface StoredConfig {
  set: HeldConfig | null;
  /** No ask before this moment, in epoch milliseconds: a refusal's wait, kept across page loads. */
  not_before: number;
  /** Kept with the answers, so a page load does not report again what the last page reported. */
  exposed?: Exposed;
}

/** A read answered an experiment's variant: what is reported about it. */
export interface ConfigExposure {
  experimentId: string;
  experimentKey: string;
  variant: string;
  /** The key that was read. */
  variable: string;
  /** What the variant was drawn by: `device` or `user`. */
  unit: string;
}

interface SessionReads {
  id: string;
  /** What each key read as; null is "not set". */
  seen: Record<string, ConfigEntry | null>;
}

export type ConfigAttributes = Record<string, string | number | boolean>;

/** Who is asking, as an ask carries it. */
export interface ConfigAsk {
  userId: string | null;
  attributes: ConfigAttributes;
}

/** What an ask came back with: the answer's body, or how it failed. */
export type ConfigAnswer = { ok: true; body: unknown } | { ok: false; status?: number; retryAfter?: string | null };

export interface RemoteConfigOptions {
  persist: boolean;
  /** Asks the ingest endpoint for this install's answers. Never rejects. */
  fetch: (ask: ConfigAsk) => Promise<ConfigAnswer>;
  /** Told when a read answers an experiment's variant that is due to be reported. */
  expose?: (exposure: ConfigExposure) => void;
  now?: () => number;
  log?: (message: string) => void;
}

const TYPES: readonly ConfigType[] = ['boolean', 'string', 'number', 'json'];

function readEntry(value: unknown): ConfigEntry | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const raw = value as Record<string, unknown>;
  if (typeof raw.key !== 'string' || raw.key === '' || !TYPES.includes(raw.type as ConfigType) || raw.value === undefined) return null;
  const entry: ConfigEntry = { key: raw.key, type: raw.type as ConfigType, value: raw.value };
  if (raw.user_dependent === true) entry.user_dependent = true;
  const experiment = raw.experiment as Record<string, unknown> | undefined;
  if (experiment && typeof experiment === 'object' && typeof experiment.id === 'string' && typeof experiment.key === 'string' && typeof experiment.variant === 'string') {
    entry.experiment = { id: experiment.id, key: experiment.key, variant: experiment.variant, unit: typeof experiment.unit === 'string' ? experiment.unit : 'device' };
  }
  return entry;
}

/** An answer off the wire, checked rather than trusted: a version and a list. An entry that is not one is left out. */
export function readConfigAnswer(value: unknown): { version: string; values: ConfigEntry[] } | null {
  if (!value || typeof value !== 'object') return null;
  const { version, values } = value as Record<string, unknown>;
  if (typeof version !== 'string' || version === '' || !Array.isArray(values)) return null;
  return { version, values: values.map(readEntry).filter((entry): entry is ConfigEntry => entry !== null) };
}

function readHeld(value: unknown): HeldConfig | null {
  const answer = readConfigAnswer(value);
  if (!answer) return null;
  const raw = value as Record<string, unknown>;
  return { ...answer, context: typeof raw.context === 'string' ? raw.context : '', stale: raw.stale === true };
}

function readExposed(value: unknown): Exposed {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return {};
  const out: Exposed = {};
  for (const [id, one] of Object.entries(value as Record<string, unknown>)) {
    const raw = one as { variant?: unknown; at?: unknown } | null;
    if (raw && typeof raw.variant === 'string' && typeof raw.at === 'number' && Number.isFinite(raw.at)) out[id] = { variant: raw.variant, at: raw.at };
  }
  return out;
}

function readAttributes(value: unknown): ConfigAttributes {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return {};
  const out: ConfigAttributes = {};
  // Sorted, so the same attributes set in another order are the same attributes.
  for (const key of Object.keys(value).sort()) {
    const one = (value as Record<string, unknown>)[key];
    if (key !== '' && (typeof one === 'string' || typeof one === 'boolean' || (typeof one === 'number' && Number.isFinite(one)))) out[key] = one;
  }
  return out;
}

const same = (a: unknown, b: unknown): boolean => JSON.stringify(a ?? null) === JSON.stringify(b ?? null);

/** How long a refusal asks this install to wait, in milliseconds. */
function waitFor(answer: Extract<ConfigAnswer, { ok: false }>): number {
  const status = answer.status;
  if (status !== undefined && (AUTH_STATUSES as readonly number[]).includes(status)) return AUTH_COOLDOWN_SECONDS * 1000;
  if (status !== undefined && (RETRY_AFTER_STATUSES as readonly number[]).includes(status) && answer.retryAfter) {
    const seconds = Number(answer.retryAfter);
    if (Number.isFinite(seconds) && seconds >= 0) return Math.min(seconds, RETRY_AFTER_MAX_SECONDS) * 1000;
  }
  return CONFIG_RETRY_SECONDS * 1000;
}

export class RemoteConfig {
  private held: HeldConfig | null = null;
  private notBefore = 0;
  private exposed: Exposed = {};
  private reads: SessionReads = { id: '', seen: {} };
  private attributes: ConfigAttributes = {};
  private readonly overrides = new Map<string, unknown>();
  private readonly listeners = new Set<() => void>();
  private userId: string | null = null;
  private context = '';
  /** The ask that is out, if one is. */
  private asking: Promise<boolean> | null = null;
  /** Who is asking changed while an ask was out: one more follows it. */
  private again = false;
  /** The next answer is for a different account than the last: what depended on the account is read afresh from it. */
  private reopen = false;
  private readonly now: () => number;

  constructor(private readonly options: RemoteConfigOptions) {
    this.now = options.now ?? Date.now;
    if (!options.persist) return;
    try {
      const stored = JSON.parse(safeGet(STORAGE_KEYS.config) ?? 'null') as Partial<StoredConfig> | null;
      this.held = readHeld(stored?.set);
      this.notBefore = typeof stored?.not_before === 'number' && Number.isFinite(stored.not_before) ? stored.not_before : 0;
      this.exposed = readExposed(stored?.exposed);
    } catch {
      // A corrupt copy is no copy: the next answer writes a good one.
    }
    try {
      const reads = JSON.parse(safeGet(STORAGE_KEYS.configSession) ?? 'null') as Partial<SessionReads> | null;
      if (reads && typeof reads.id === 'string' && reads.seen && typeof reads.seen === 'object') {
        const seen: SessionReads['seen'] = {};
        for (const [key, entry] of Object.entries(reads.seen)) seen[key] = entry === null ? null : readEntry(entry);
        this.reads = { id: reads.id, seen };
      }
    } catch {
      // What was read is forgotten, which is what a new session does anyway.
    }
    try {
      this.attributes = readAttributes(JSON.parse(safeGet(STORAGE_KEYS.configAttributes) ?? 'null'));
    } catch {
      // The app sets them again.
    }
  }

  /** The version held, or null when nothing is. */
  get version(): string | null {
    return this.held?.version ?? null;
  }

  /** Whether there is something to ask for that no upload's answer will prompt: nothing held, or an ask still owed. */
  get wanting(): boolean {
    return this.held === null || this.held.stale;
  }

  /**
   * Called once the SDK knows its session, who is signed in, and how the device describes itself (`context`:
   * any string that changes when that description does). Asks when the answers held were asked for by a
   * device that described itself differently, or when an ask is still owed from before.
   */
  start(state: { sessionId?: string; userId: string | null; context: string }): void {
    this.userId = state.userId;
    this.context = state.context;
    // Where the session is not known yet, what was read stands until `sessionStarted` says which one this is.
    if (state.sessionId !== undefined) this.sessionStarted(state.sessionId);
    if (this.held && this.held.values.length > 0 && this.held.context !== this.context) this.held.stale = true;
    if (this.held?.stale) void this.refresh();
  }

  /** A session began, or is the one already running. A different one forgets what was read. */
  sessionStarted(sessionId: string): void {
    if (sessionId === this.reads.id) return;
    const moved = this.wouldChange();
    this.reads = { id: sessionId, seen: {} };
    this.saveReads();
    if (moved) this.announce();
  }

  /** The entry a key answers with now, or null for "not set". The first read of a key in a session fixes it. */
  private entry(key: string): ConfigEntry | null {
    if (Object.prototype.hasOwnProperty.call(this.reads.seen, key)) return this.reads.seen[key] ?? null;
    const entry = this.held?.values.find((one) => one.key === key) ?? null;
    this.reads.seen[key] = entry;
    this.saveReads();
    return entry;
  }

  /**
   * One key, as the kind asked for. The fallback when nothing is held for it, or what is held is another kind:
   * a value is never bent into shape.
   */
  read<T>(key: string, type: ConfigType, fallback: T): T {
    if (this.overrides.has(key)) {
      const value = this.overrides.get(key);
      return RemoteConfig.fits(value, type) ? (value as T) : fallback;
    }
    const entry = this.entry(key);
    if (!entry || entry.type !== type || !RemoteConfig.fits(entry.value, type)) return fallback;
    this.report(entry);
    return entry.value as T;
  }

  /**
   * Reports that a read answered an experiment's variant, where that is due: the first time, a day after the
   * last report of the same variant, or at once when the variant is not the one last reported.
   *
   * Counted on this install's own clock, in either direction: a clock set back does not silence the report
   * for as long as it was set back by.
   */
  private report(entry: ConfigEntry): void {
    const experiment = entry.experiment;
    if (!experiment || !this.options.expose) return;
    const now = this.now();
    const last = this.exposed[experiment.id];
    if (last && last.variant === experiment.variant && Math.abs(now - last.at) < CONFIG_EXPOSURE_FLOOR_SECONDS * 1000) return;
    this.exposed[experiment.id] = { variant: experiment.variant, at: now };
    this.save();
    try {
      this.options.expose({ experimentId: experiment.id, experimentKey: experiment.key, variant: experiment.variant, variable: entry.key, unit: experiment.unit });
    } catch (error) {
      this.options.log?.(`reporting an exposure failed: ${String(error)}`);
    }
  }

  private static fits(value: unknown, type: ConfigType): boolean {
    if (type === 'boolean') return typeof value === 'boolean';
    if (type === 'string') return typeof value === 'string';
    if (type === 'number') return typeof value === 'number' && Number.isFinite(value);
    return value !== undefined;
  }

  /** Every key held, with the value a read would answer. Reading them all fixes them all for the session. */
  all(): Record<string, unknown> {
    const out: Record<string, unknown> = {};
    for (const one of this.held?.values ?? []) {
      const entry = this.entry(one.key);
      if (entry) out[one.key] = entry.value;
    }
    for (const key of Object.keys(this.reads.seen)) {
      const entry = this.reads.seen[key];
      if (entry && !(key in out)) out[key] = entry.value;
    }
    for (const [key, value] of this.overrides) out[key] = value;
    return out;
  }

  /** Whether a key already read would answer differently if it were read afresh. */
  private wouldChange(): boolean {
    return Object.keys(this.reads.seen).some((key) => !same(this.reads.seen[key], this.held?.values.find((one) => one.key === key) ?? null));
  }

  /** Applies the newest answers to keys already read. True when a read now answers differently. */
  activate(): boolean {
    const moved = this.wouldChange();
    this.reads = { id: this.reads.id, seen: {} };
    this.saveReads();
    if (moved) this.announce();
    return moved;
  }

  /** What an upload's answer said the current version is. A different one asks; so does an ask still owed. */
  observe(version: string | null): void {
    if (version && version !== this.held?.version) void this.refresh();
    else if (this.held?.stale) void this.refresh();
  }

  /**
   * Somebody signed in, or out (`null`). What depended on the account is read afresh; when the last one was
   * an account, its answers are dropped now rather than when the next ones arrive.
   */
  identityChanged(userId: string | null): void {
    if (userId === this.userId) return;
    const previous = this.userId;
    this.userId = userId;
    const held = this.held;
    if (!held || !held.values.some((entry) => entry.user_dependent)) return;

    for (const key of Object.keys(this.reads.seen)) {
      if (this.reads.seen[key]?.user_dependent || held.values.some((entry) => entry.key === key && entry.user_dependent)) delete this.reads.seen[key];
    }
    this.saveReads();
    // Kept from nobody to somebody: the same person, a moment before they said who they are.
    if (previous !== null) held.values = held.values.filter((entry) => !entry.user_dependent);
    held.stale = true;
    this.reopen = true;
    this.save();
    if (previous !== null) this.announce();
    void this.refresh();
  }

  /** What the app says about this install, for rules to read. The same attributes again change nothing. */
  setAttributes(attributes: unknown): void {
    const next = readAttributes(attributes);
    if (same(next, this.attributes)) return;
    this.attributes = next;
    if (this.options.persist) {
      if (Object.keys(next).length > 0) safeSet(STORAGE_KEYS.configAttributes, JSON.stringify(next));
      else safeRemove(STORAGE_KEYS.configAttributes);
    }
    if (!this.held || this.held.values.length === 0) return;
    this.held.stale = true;
    this.save();
    void this.refresh();
  }

  /** Answers a key with `value` on this page, before anything held. `undefined` or `null` takes it back. Never kept. */
  override(key: string, value: unknown): void {
    if (value === undefined || value === null) this.overrides.delete(key);
    else this.overrides.set(key, value);
    this.announce();
  }

  /** Called whenever what a read answers may have changed. Returns the way to stop hearing. */
  onChange(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  /**
   * Asks now, unless a refusal's wait is still running. Joins an ask already out. Resolves true when answers
   * arrived, false when they did not; never rejects.
   */
  refresh(): Promise<boolean> {
    if (this.asking) {
      this.again = true;
      return this.asking;
    }
    if (this.now() < this.notBefore) return Promise.resolve(false);
    const asked: ConfigAsk = { userId: this.userId, attributes: { ...this.attributes } };
    const context = this.context;
    const run = (async () => {
      let answer: ConfigAnswer;
      try {
        answer = await this.options.fetch(asked);
      } catch (error) {
        this.options.log?.(`config fetch failed: ${String(error)}`);
        answer = { ok: false };
      }
      this.asking = null;
      const again = this.again;
      this.again = false;
      const read = answer.ok ? readConfigAnswer(answer.body) : null;
      if (!read) {
        this.notBefore = this.now() + waitFor(answer.ok ? { ok: false } : answer);
        this.save();
        return false;
      }
      // Whether who asked is still who is asking: if not, these stand for now and one more ask follows.
      const current = asked.userId === this.userId && same(asked.attributes, this.attributes) && context === this.context;
      this.adopt({ ...read, context, stale: !current });
      if (!current || (again && this.held?.stale)) void this.refresh();
      return true;
    })();
    this.asking = run;
    return run;
  }

  private adopt(next: HeldConfig): void {
    const previous = this.held;
    this.held = next;
    this.notBefore = 0;
    // An experiment no longer among the answers, last reported more than a day ago, would be reported afresh anyway.
    const now = this.now();
    for (const id of Object.keys(this.exposed)) {
      const due = Math.abs(now - this.exposed[id]!.at) >= CONFIG_EXPOSURE_FLOOR_SECONDS * 1000;
      if (due && !next.values.some((entry) => entry.experiment?.id === id)) delete this.exposed[id];
    }
    if (this.reopen) {
      for (const key of Object.keys(this.reads.seen)) {
        if (this.reads.seen[key]?.user_dependent || next.values.some((entry) => entry.key === key && entry.user_dependent)) delete this.reads.seen[key];
      }
      this.saveReads();
      if (!next.stale) this.reopen = false;
    }
    this.save();
    if (!previous || previous.version !== next.version || previous.stale) this.announce();
  }

  /** Forgets everything held: for a visitor who opted out. */
  clear(): void {
    this.held = null;
    this.notBefore = 0;
    this.exposed = {};
    this.reads = { id: this.reads.id, seen: {} };
    this.attributes = {};
    this.overrides.clear();
    if (this.options.persist) {
      safeRemove(STORAGE_KEYS.config);
      safeRemove(STORAGE_KEYS.configSession);
      safeRemove(STORAGE_KEYS.configAttributes);
    }
  }

  private announce(): void {
    for (const listener of [...this.listeners]) {
      try {
        listener();
      } catch (error) {
        this.options.log?.(`a config listener threw: ${String(error)}`);
      }
    }
  }

  private save(): void {
    if (!this.options.persist) return;
    const stored: StoredConfig = { set: this.held, not_before: this.notBefore, ...(Object.keys(this.exposed).length > 0 ? { exposed: this.exposed } : {}) };
    safeSet(STORAGE_KEYS.config, JSON.stringify(stored));
  }

  private saveReads(): void {
    if (this.options.persist) safeSet(STORAGE_KEYS.configSession, JSON.stringify(this.reads));
  }
}
