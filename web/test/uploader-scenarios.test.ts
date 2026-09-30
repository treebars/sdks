import { readFileSync } from 'node:fs';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import {
  AUTH_COOLDOWN_SECONDS,
  AUTH_STATUSES,
  BACKOFF_BASE_SECONDS,
  BACKOFF_CAP_SECONDS,
  BATCH_SIZE,
  DRAIN_MAX_BATCHES,
  RETRY_AFTER_MAX_SECONDS,
  RETRY_AFTER_STATUSES,
} from '../src/generated/constants';
import { EventStore } from '../src/storage';
import type { QueuedEvent } from '../src/types';
import {
  Uploader,
  UploaderStore,
  retryAfterDelayMs,
  type PendingBatch,
  type UploadResponse,
} from '../src/uploader';

/**
 * The shared upload scenarios, run against this core.
 *
 * The same file drives the Android and iOS SDKs' uploader tests, and that is the point of it
 * being data: three implementations of one policy agree only if each is asked the same
 * questions. The clock is vitest's fake one — the uploader reads `Date.now()` as it
 * does in a browser — and storage is a map standing in for `localStorage`, read back fresh after
 * every step so what is asserted is what a reload would find.
 */

interface ResponseStep {
  status?: number;
  retry_after?: string;
  network_error?: boolean;
}

interface BatchExpect {
  batch_id: string;
  events: string[];
}

interface Expect {
  sent?: BatchExpect[];
  pending?: BatchExpect[];
  queue?: string[];
  attempt?: number;
  next_allowed_at?: number | null;
  auth_blocked_until?: number | null;
  dropped?: string[];
}

interface Step {
  do: 'flush' | 'beacon' | 'track' | 'relaunch';
  at?: number;
  responses?: ResponseStep[];
  random?: number[];
  events?: string[];
  write_key?: string;
  expect?: Expect;
}

interface Scenario {
  id: string;
  name: string;
  platforms?: string[];
  batch_size?: number;
  write_key?: string;
  queue: string[];
  steps: Step[];
}

interface Fixture {
  epoch_ms: number;
  write_key: string;
  policy: Record<string, unknown>;
  scenarios: Scenario[];
}

const fixture = JSON.parse(
  readFileSync(
    new URL('./fixtures/uploader-scenarios.json', import.meta.url),
    'utf8',
  ),
) as Fixture;

function memoryStorage() {
  const map = new Map<string, string>();
  return {
    getItem: (key: string) => map.get(key) ?? null,
    setItem: (key: string, value: string) => void map.set(key, value),
    removeItem: (key: string) => void map.delete(key),
    clear: () => map.clear(),
  };
}

function event(id: string): QueuedEvent {
  return {
    event_id: id,
    session_id: 's1',
    device_id: 'dev_fixture',
    event_name: `evt_${id}`,
    properties: { id },
    timestamp: '2026-09-15T12:00:00.000Z',
    sdk_version: '0.0.0',
    sdk_name: 'treebars-web',
    env: 'test',
    platform_type: 'web',
  };
}

const ids = (batch: PendingBatch) => batch.events.map((each) => each.event_id);
const shape = (batch: PendingBatch): BatchExpect => ({ batch_id: batch.batch_id, events: ids(batch) });

describe('the uploader agrees with the shared scenarios', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.stubGlobal('localStorage', memoryStorage());
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  /*
   * The numbers in the scenarios are consequences of the policy. If the generated constants moved
   * and the fixture did not, every expectation below would be checking the wrong arithmetic.
   */
  it('runs against the policy the fixture was derived from', () => {
    expect({
      batch_size: BATCH_SIZE,
      drain_max_batches: DRAIN_MAX_BATCHES,
      backoff_base_seconds: BACKOFF_BASE_SECONDS,
      backoff_cap_seconds: BACKOFF_CAP_SECONDS,
      retry_after_statuses: [...RETRY_AFTER_STATUSES],
      retry_after_max_seconds: RETRY_AFTER_MAX_SECONDS,
      auth_statuses: [...AUTH_STATUSES],
      auth_cooldown_seconds: AUTH_COOLDOWN_SECONDS,
    }).toEqual(fixture.policy);
  });

  /*
   * The HTTP date is parsed by hand in all three cores, so that none of them inherits a platform
   * parser's leniency. Here that arithmetic is checked against the platform instead, across two
   * thousand instants spread over sixty-eight years — the scenarios can only afford two dates.
   */
  it('reads an IMF-fixdate to the same instant the platform does', () => {
    let seed = 7;
    for (let index = 0; index < 2000; index += 1) {
      seed = (seed * 48271) % 2147483647;
      const at = Date.UTC(1971, 0, 1) + seed * 1000;
      expect(retryAfterDelayMs(new Date(at).toUTCString(), 0), new Date(at).toUTCString()).toBe(at);
    }
  });

  const scenarios = fixture.scenarios.filter((each) => !each.platforms || each.platforms.includes('web'));

  it.each(scenarios.map((each) => [`${each.id} ${each.name}`, each] as const))('%s', async (_, scenario) => {
    const epoch = fixture.epoch_ms;
    let writeKey = scenario.write_key ?? fixture.write_key;
    let minted = 0;
    let responses: ResponseStep[] = [];
    let randoms: number[] = [];
    /*
     * Recorded rather than thrown where they happen: the uploader catches a transport failure as
     * a network error, so a throw here would surface as whatever the policy did next.
     */
    let unscripted: string[] = [];
    let sent: Array<{ batch: PendingBatch; status: number | null }> = [];
    /** batch_id -> what its first send carried, for the unchanged-on-resend invariant. */
    const firstSend = new Map<string, string>();

    const persistedPending = () => new UploaderStore(true).load().pending;

    /** The two invariants every send must satisfy, whatever the scenario is about. */
    const checkSend = (batch: PendingBatch) => {
      const head = persistedPending()[0];
      expect(head && shape(head), `${batch.batch_id} was sent before it was the persisted head`).toEqual(
        shape(batch),
      );
      const carried = JSON.stringify({ sent_at: batch.sent_at, events: batch.events });
      const first = firstSend.get(batch.batch_id);
      if (first === undefined) firstSend.set(batch.batch_id, carried);
      else expect(carried, `${batch.batch_id} changed between sends`).toBe(first);
    };

    const transport = async (batch: PendingBatch): Promise<UploadResponse> => {
      checkSend(batch);
      const next = responses.shift();
      if (!next) {
        unscripted.push(`a request for ${batch.batch_id}`);
        throw new Error('no response scripted');
      }
      sent.push({ batch, status: next.network_error ? null : next.status! });
      if (next.network_error) throw new TypeError('Failed to fetch');
      return { status: next.status!, retryAfter: next.retry_after ?? null };
    };

    let queue = new EventStore(true);
    for (const id of scenario.queue) queue.add(event(id));

    const build = () =>
      new Uploader({
        queue,
        store: new UploaderStore(true),
        transport,
        writeKey,
        batchSize: scenario.batch_size,
        random: () => {
          const value = randoms.shift();
          if (value !== undefined) return value;
          unscripted.push('a random draw');
          return 0;
        },
        newBatchId: () => `b${(minted += 1)}`,
      });
    let uploader = build();

    const offset = (value: number) => (value === 0 ? null : value - epoch);

    const verify = (label: string, expected: Expect, full: boolean) => {
      const state = new UploaderStore(true).load();
      const pending = state.pending.map(shape);
      const queued = new EventStore(true).all().map((each) => each.event_id);

      if (full || expected.sent) expect(sent.map((each) => shape(each.batch)), `${label}: sent`).toEqual(expected.sent ?? []);
      if (full || expected.pending) expect(pending, `${label}: pending`).toEqual(expected.pending ?? []);
      if (full || expected.queue) expect(queued, `${label}: queue`).toEqual(expected.queue ?? []);
      if (full || expected.attempt !== undefined) expect(state.attempt, `${label}: attempt`).toBe(expected.attempt ?? 0);
      if (full || expected.next_allowed_at !== undefined) {
        expect(offset(state.next_allowed_at), `${label}: next_allowed_at`).toBe(expected.next_allowed_at ?? null);
      }
      if (full || expected.auth_blocked_until !== undefined) {
        expect(offset(state.auth_blocked_until), `${label}: auth_blocked_until`).toBe(
          expected.auth_blocked_until ?? null,
        );
      }
      if (full || expected.dropped) {
        // Sent in this step, never acknowledged, and now in neither store.
        const acknowledged = new Set(
          sent.filter((each) => each.status !== null && each.status >= 200 && each.status < 300).flatMap((each) => ids(each.batch)),
        );
        const kept = new Set([...pending.flatMap((each) => each.events), ...queued]);
        const dropped = [...new Set(sent.flatMap((each) => ids(each.batch)))].filter(
          (id) => !acknowledged.has(id) && !kept.has(id),
        );
        expect(dropped, `${label}: dropped`).toEqual(expected.dropped ?? []);
      }
    };

    for (const [index, step] of scenario.steps.entries()) {
      const label = `${scenario.id} step ${index + 1} (${step.do})`;
      sent = [];
      unscripted = [];

      switch (step.do) {
        case 'flush': {
          vi.setSystemTime(epoch + step.at!);
          responses = [...(step.responses ?? [])];
          randoms = [...(step.random ?? [])];
          await uploader.flush();
          expect(unscripted, `${label}: not in the scenario`).toEqual([]);
          expect(responses, `${label}: responses never asked for`).toEqual([]);
          expect(randoms, `${label}: random values never drawn`).toEqual([]);
          verify(label, step.expect ?? {}, true);
          break;
        }
        case 'beacon': {
          vi.setSystemTime(epoch + step.at!);
          const batch = uploader.nextBeaconBatch();
          if (batch) {
            checkSend(batch);
            sent.push({ batch, status: null });
          }
          verify(label, step.expect ?? {}, true);
          break;
        }
        case 'track': {
          for (const id of step.events ?? []) queue.add(event(id));
          if (step.expect) verify(label, step.expect, false);
          break;
        }
        case 'relaunch': {
          writeKey = step.write_key ?? writeKey;
          queue = new EventStore(true);
          uploader = build();
          if (step.expect) verify(label, step.expect, false);
          break;
        }
      }
    }
  });
});
