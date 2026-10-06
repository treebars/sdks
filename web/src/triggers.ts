import { STORAGE_KEYS } from './generated/constants';
import { safeGet, safeSet } from './storage';

/**
 * The environment's trigger list: the events this page sends within a second of logging them,
 * however lately it last uploaded — every other event waits out the spacing between uploads
 * (`flush-pace.ts`). The Android and iOS SDKs implement the same list, and all three run the same
 * scenarios (`test/fixtures/trigger-scenarios.json`).
 *
 * Treebars decides what is on it — the events that start or advance a live campaign or journey —
 * and hands it over in the in-app sync. Every accepted upload carries the list's version, so a
 * page learns its copy is stale from an answer it was already waiting for, and only then fetches
 * the list — alone, with `triggers_only=1`, which is much lighter than a full sync.
 *
 * Kept in storage so a reload flushes a listed event promptly before its own sync has returned.
 * The list belongs to the write key's environment rather than to anybody signed in, so a sign-out
 * leaves it alone; a build that switches keys carries the other environment's list only until its
 * first upload's version says otherwise.
 */

export interface TriggerList {
  version: string;
  names: string[];
}

/** A list off the wire or out of storage, checked rather than trusted. Null for anything else. */
export function readTriggerList(value: unknown): TriggerList | null {
  if (!value || typeof value !== 'object') return null;
  const { version, names } = value as Record<string, unknown>;
  if (typeof version !== 'string' || version === '' || !Array.isArray(names)) return null;
  return { version, names: names.filter((name): name is string => typeof name === 'string') };
}

export interface TriggerEventsOptions {
  persist: boolean;
  /** Asks the ingest endpoint for the list alone. Null when it could not be had. */
  fetch: () => Promise<TriggerList | null>;
  log?: (message: string) => void;
}

export class TriggerEvents {
  private list: TriggerList | null = null;
  private names = new Set<string>();
  /**
   * Syncs in flight, the session's whole sync included. While one is out, a stale version on an
   * upload does not start another: the answer on its way carries the list, and a cold start —
   * whose first flush and first sync leave together — would otherwise fetch it twice.
   */
  private syncing = 0;

  constructor(private readonly options: TriggerEventsOptions) {
    if (!options.persist) return;
    try {
      this.remember(readTriggerList(JSON.parse(safeGet(STORAGE_KEYS.triggers) ?? 'null')));
    } catch {
      // A corrupt copy is no copy: the next sync writes a good one.
    }
  }

  get version(): string | null {
    return this.list?.version ?? null;
  }

  has(eventName: string): boolean {
    return this.names.has(eventName);
  }

  /** Called before a sync that may carry the list is sent. */
  beginSync(): void {
    this.syncing += 1;
  }

  /**
   * Called when it has answered, with whatever its `trigger_events` held — or nothing, when it
   * failed or carried none, which keeps the list this page already has.
   */
  endSync(value: unknown): void {
    this.syncing = Math.max(0, this.syncing - 1);
    const list = readTriggerList(value);
    if (!list) return;
    this.remember(list);
    if (this.options.persist) safeSet(STORAGE_KEYS.triggers, JSON.stringify(list));
  }

  /** Fetches the list alone, unless a sync that will carry it is already out. Never throws. */
  async refresh(): Promise<void> {
    if (this.syncing > 0) return;
    this.beginSync();
    let list: TriggerList | null = null;
    try {
      list = await this.options.fetch();
    } catch (error) {
      this.options.log?.(`trigger list refresh failed: ${String(error)}`);
    }
    this.endSync(list);
  }

  /**
   * What an upload's answer said the current version is. A different one refreshes the list; the
   * same one, or none — a refusal carries none — changes nothing.
   */
  async observe(version: string | null): Promise<void> {
    if (!version || version === this.version) return;
    await this.refresh();
  }

  private remember(list: TriggerList | null): void {
    if (!list) return;
    this.list = list;
    this.names = new Set(list.names);
  }
}
