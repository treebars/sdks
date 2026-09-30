import { readFileSync } from 'node:fs';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import {
  AUTH_COOLDOWN_SECONDS,
  BACKOFF_BASE_SECONDS,
  STORAGE_KEYS,
  TRIGGER_FLUSH_DEBOUNCE_MS,
} from '../src/generated/constants';
import { EventStore } from '../src/storage';
import { TriggerEvents, readTriggerList } from '../src/triggers';
import type { QueuedEvent } from '../src/types';
import { Uploader, UploaderStore, type PendingBatch, type UploadResponse } from '../src/uploader';

/**
 * The shared trigger scenarios, run against this core.
 *
 * The same scenario file drives the Android and iOS SDKs' trigger tests as well, so the three
 * cores are held to one policy. The wake is the one thing the host owns here —
 * `TreebarsWeb.wake` keeps a single `setTimeout`, rearms it whenever the uploader asks, and calls
 * `woken()` when it fires — so the harness keeps a single slot the same way and fires it as the
 * clock passes it. What the wake does once it fires is all the uploader's.
 * `trigger-transport.test.ts` is where the real timer, `fetch` and the page are exercised.
 */

interface TriggerListShape {
  version: string;
  names: string[];
}

interface ScriptedResponse {
  status?: number;
  retry_after?: string;
  triggers_version?: string;
  network_error?: boolean;
}

interface ScriptedSync {
  trigger_events?: TriggerListShape;
  network_error?: boolean;
}

interface BatchExpect {
  batch_id: string;
  events: string[];
}

interface Step {
  do: 'track' | 'advance' | 'tick' | 'sync_start' | 'sync_end' | 'relaunch';
  at: number;
  events?: Array<{ id: string; name: string }>;
  responses?: ScriptedResponse[];
  syncs?: ScriptedSync[];
  random?: number[];
  trigger_events?: TriggerListShape;
  expect?: {
    sent?: BatchExpect[];
    synced?: number;
    triggers?: TriggerListShape | null;
    queue?: string[];
    pending?: BatchExpect[];
    next_allowed_at?: number | null;
    auth_blocked_until?: number | null;
  };
}

interface Scenario {
  id: string;
  name: string;
  stored_triggers: TriggerListShape | null;
  batch_size?: number;
  queue: Array<{ id: string; name: string }>;
  steps: Step[];
}

const fixture = JSON.parse(
  readFileSync(new URL('./fixtures/trigger-scenarios.json', import.meta.url), 'utf8'),
) as { epoch_ms: number; write_key: string; policy: Record<string, unknown>; scenarios: Scenario[] };

function memoryStorage() {
  const map = new Map<string, string>();
  return {
    getItem: (key: string) => map.get(key) ?? null,
    setItem: (key: string, value: string) => void map.set(key, value),
    removeItem: (key: string) => void map.delete(key),
    clear: () => map.clear(),
  };
}

function event(id: string, name: string): QueuedEvent {
  return {
    event_id: id,
    session_id: 's1',
    device_id: 'dev_fixture',
    event_name: name,
    properties: {},
    timestamp: '2026-09-15T12:00:00.000Z',
    sdk_version: '0.0.0',
    sdk_name: 'treebars-web',
    env: 'test',
    platform_type: 'web',
  };
}

const shape = (batch: PendingBatch): BatchExpect => ({
  batch_id: batch.batch_id,
  events: batch.events.map((each) => each.event_id),
});

describe('the trigger flush agrees with the shared scenarios', () => {
  beforeEach(() => vi.stubGlobal('localStorage', memoryStorage()));
  afterEach(() => vi.unstubAllGlobals());

  it('runs against the policy the fixture was derived from', () => {
    expect({
      trigger_flush_debounce_ms: TRIGGER_FLUSH_DEBOUNCE_MS,
      backoff_base_seconds: BACKOFF_BASE_SECONDS,
      auth_cooldown_seconds: AUTH_COOLDOWN_SECONDS,
    }).toEqual(fixture.policy);
  });

  it.each(fixture.scenarios.map((each) => [`${each.id} ${each.name}`, each] as const))('%s', async (_, scenario) => {
    const epoch = fixture.epoch_ms;
    let clock = epoch;
    let minted = 0;
    /** The host's one timer: when it is due, or null. */
    let armed: number | null = null;
    let responses: ScriptedResponse[] = [];
    let syncs: ScriptedSync[] = [];
    let randoms: number[] = [];
    let unscripted: string[] = [];
    let sent: PendingBatch[] = [];
    let synced = 0;

    if (scenario.stored_triggers) {
      localStorage.setItem(STORAGE_KEYS.triggers, JSON.stringify(scenario.stored_triggers));
    }

    const transport = async (batch: PendingBatch): Promise<UploadResponse> => {
      const next = responses.shift();
      if (!next) {
        unscripted.push(`an upload of ${batch.batch_id}`);
        throw new Error('no response scripted');
      }
      sent.push(batch);
      if (next.network_error) throw new TypeError('Failed to fetch');
      return { status: next.status!, retryAfter: next.retry_after ?? null, triggersVersion: next.triggers_version ?? null };
    };

    const fetchTriggers = async () => {
      synced += 1;
      const next = syncs.shift();
      if (!next) {
        unscripted.push('a trigger list fetch');
        return null;
      }
      if (next.network_error) throw new TypeError('Failed to fetch');
      return readTriggerList(next.trigger_events);
    };

    let queue = new EventStore(true);
    for (const each of scenario.queue) queue.add(event(each.id, each.name));

    let triggers!: TriggerEvents;
    const build = () => {
      triggers = new TriggerEvents({ persist: true, fetch: fetchTriggers });
      return new Uploader({
        queue,
        store: new UploaderStore(true),
        transport,
        writeKey: fixture.write_key,
        batchSize: scenario.batch_size,
        now: () => clock,
        random: () => {
          const value = randoms.shift();
          if (value !== undefined) return value;
          unscripted.push('a random draw');
          // Not zero: with wakes live, an unscripted failure retried after no delay at all would
          // fall due again at once, and the advance below would never end.
          return 0.5;
        },
        newBatchId: () => `b${(minted += 1)}`,
        wake: (at) => {
          armed = at;
        },
        triggers,
      });
    };
    let uploader = build();

    /** Fires the host's timer every time the clock passes it, the way `setTimeout` would. */
    const advanceTo = async (at: number) => {
      for (let fired = 0; armed !== null && armed <= epoch + at; fired += 1) {
        // A core that re-arms itself at the moment it is woken would otherwise hang the suite.
        if (fired > 200) throw new Error(`wakes kept falling due before ${at}; the scenario cannot settle`);
        const due: number = armed;
        armed = null;
        clock = Math.max(clock, due);
        await uploader.woken();
      }
      clock = epoch + at;
    };

    const offset = (value: number) => (value === 0 ? null : value - epoch);

    for (const [index, step] of scenario.steps.entries()) {
      const label = `${scenario.id} step ${index + 1} (${step.do})`;
      sent = [];
      synced = 0;
      unscripted = [];
      responses = [...(step.responses ?? [])];
      syncs = [...(step.syncs ?? [])];
      randoms = [...(step.random ?? [])];

      await advanceTo(step.at);
      switch (step.do) {
        case 'track':
          for (const each of step.events ?? []) {
            queue.add(event(each.id, each.name));
            uploader.eventLogged(each.name);
          }
          break;
        case 'tick':
          await uploader.flush();
          break;
        case 'sync_start':
          triggers.beginSync();
          break;
        case 'sync_end':
          triggers.endSync(step.trigger_events ?? null);
          break;
        case 'relaunch':
          queue = new EventStore(true);
          armed = null;
          uploader = build();
          break;
        case 'advance':
          break;
      }

      expect(unscripted, `${label}: not in the scenario`).toEqual([]);
      expect(responses, `${label}: responses never asked for`).toEqual([]);
      expect(syncs, `${label}: trigger list answers never asked for`).toEqual([]);
      expect(randoms, `${label}: random values never drawn`).toEqual([]);

      const expected = step.expect ?? {};
      expect(sent.map(shape), `${label}: sent`).toEqual(expected.sent ?? []);
      expect(synced, `${label}: trigger list fetches`).toBe(expected.synced ?? 0);

      if ('triggers' in expected) {
        const raw = localStorage.getItem(STORAGE_KEYS.triggers);
        expect(raw === null ? null : JSON.parse(raw), `${label}: stored triggers`).toEqual(expected.triggers);
      }
      if (expected.queue) {
        expect(new EventStore(true).all().map((each) => each.event_id), `${label}: queue`).toEqual(expected.queue);
      }
      const state = new UploaderStore(true).load();
      if (expected.pending) expect(state.pending.map(shape), `${label}: pending`).toEqual(expected.pending);
      if (expected.next_allowed_at !== undefined) {
        expect(offset(state.next_allowed_at), `${label}: next_allowed_at`).toBe(expected.next_allowed_at);
      }
      if (expected.auth_blocked_until !== undefined) {
        expect(offset(state.auth_blocked_until), `${label}: auth_blocked_until`).toBe(expected.auth_blocked_until);
      }
    }
  });
});
