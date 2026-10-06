import { readFileSync } from 'node:fs';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import {
  FlushPace,
  boundedFlushSpacing,
  flushDueAt,
  flushSpacingMs,
  readFlushSpacing,
  type FlushConditions,
} from '../src/flush-pace';
import {
  BATCH_SIZE,
  DEFAULT_FLUSH_INTERVAL_MS,
  FLUSH_DEBOUNCE_MS,
  FLUSH_SPACING_MAX_MS,
  FLUSH_SPACING_METERED_MS,
  FLUSH_SPACING_MIN_MS,
  FLUSH_SPACING_MS,
  FLUSH_SPACING_TEST_MS,
  STORAGE_KEYS,
  TRIGGER_FLUSH_DEBOUNCE_MS,
} from '../src/generated/constants';
import { EventStore } from '../src/storage';
import { TriggerEvents } from '../src/triggers';
import type { QueuedEvent } from '../src/types';
import { Uploader, UploaderStore, type PendingBatch, type UploadResponse } from '../src/uploader';

/**
 * The shared pace scenarios, run against this SDK's pace wired to its real uploader.
 *
 * The same scenario file drives the Android and iOS SDKs' pace tests as well, so the three are held
 * to one pace. What is under test is the pair, wired the way `TreebarsWeb` wires them:
 *
 * - every request for a batch tells the pace an upload began, from the transport;
 * - the uploader reads the spacing off an accepted answer and tells the pace;
 * - every queued event is offered to both — the uploader, for the trigger list, and the pace;
 * - a full batch is flushed at once, by the host, with no regard for either;
 * - the uploader says when a flush ended with events still waiting and no gate closed, and the pace
 *   arms the upload that carries on;
 * - each keeps one wake of its own. `TreebarsWeb` holds a `setTimeout` for each and calls `woken()`
 *   on whichever fires, so the harness keeps two slots and fires each as the clock passes it.
 *
 * `flush-pace-transport.test.ts` is where the real timers, `fetch` and the page are exercised.
 */

interface ScriptedResponse {
  status: number;
  flush_ms?: number;
}

interface Step {
  do: 'track' | 'advance';
  at: number;
  events?: string[];
  /** The events of this step are on the stored trigger list. */
  trigger?: boolean;
  responses?: ScriptedResponse[];
  expect?: { sent: Array<{ events: string[] }> };
}

interface Scenario {
  id: string;
  rule: string;
  name: string;
  key?: 'live' | 'test';
  network?: 'unmetered' | 'metered' | 'constrained';
  flush_interval_ms?: number;
  batch_size?: number;
  /** What storage holds before the first step: events an earlier page load queued and never sent. */
  queue?: string[];
  steps: Step[];
}

const fixture = JSON.parse(
  readFileSync(new URL('./fixtures/flush-pace-scenarios.json', import.meta.url), 'utf8'),
) as { epoch_ms: number; policy: Record<string, number>; scenarios: Scenario[] };

/** The one name on the stored trigger list, and the name every other event carries. */
const LISTED = 'listed_event';
const UNLISTED = 'plain_event';

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

const UNHURRIED: FlushConditions = { constrained: false, metered: false };

describe('the pace agrees with the shared scenarios', () => {
  beforeEach(() => vi.stubGlobal('localStorage', memoryStorage()));
  afterEach(() => vi.unstubAllGlobals());

  /*
   * The numbers in the scenarios are consequences of the policy. If the generated constants moved
   * and the fixture did not, every expectation below would be checking the wrong arithmetic.
   */
  it('runs against the policy the fixture was derived from', () => {
    expect({
      debounce_ms: FLUSH_DEBOUNCE_MS,
      spacing_ms: FLUSH_SPACING_MS,
      spacing_metered_ms: FLUSH_SPACING_METERED_MS,
      spacing_test_ms: FLUSH_SPACING_TEST_MS,
      // A device saving data keeps the interval every device kept before there was a faster pace.
      spacing_constrained_ms: DEFAULT_FLUSH_INTERVAL_MS,
      spacing_min_ms: FLUSH_SPACING_MIN_MS,
      spacing_max_ms: FLUSH_SPACING_MAX_MS,
      batch_size: BATCH_SIZE,
    }).toEqual(fixture.policy);
    // A listed event waits the same second; it differs only in ignoring the spacing.
    expect(TRIGGER_FLUSH_DEBOUNCE_MS).toBe(FLUSH_DEBOUNCE_MS);
  });

  it.each(fixture.scenarios.map((each) => [`${each.id} ${each.name}`, each] as const))('%s', async (_, scenario) => {
    const epoch = fixture.epoch_ms;
    let clock = epoch;
    let minted = 0;
    /** The host's two timers: when each is due, or null. */
    let uploaderWake: number | null = null;
    let paceWake: number | null = null;
    let responses: ScriptedResponse[] = [];
    let unscripted: string[] = [];
    let sent: PendingBatch[] = [];

    localStorage.setItem(STORAGE_KEYS.triggers, JSON.stringify({ version: 'v1', names: [LISTED] }));

    const transport = async (batch: PendingBatch): Promise<UploadResponse> => {
      pace.uploadBegan();
      const next = responses.shift();
      if (!next) {
        unscripted.push(`an upload of ${batch.events.map((each) => each.event_id).join(', ')}`);
        throw new Error('no response scripted');
      }
      sent.push(batch);
      return {
        status: next.status,
        retryAfter: null,
        triggersVersion: null,
        flushSpacing: next.flush_ms === undefined ? null : String(next.flush_ms),
      };
    };

    const queue = new EventStore(true);
    // Left by an earlier page load, so nothing on this one was told they were logged.
    for (const id of scenario.queue ?? []) queue.add(event(id, UNLISTED));
    const batchSize = scenario.batch_size ?? BATCH_SIZE;
    const uploader = new Uploader({
      queue,
      store: new UploaderStore(true),
      transport,
      writeKey: scenario.key === 'test' ? 'pk_test_fixture' : 'pk_live_fixture',
      batchSize: scenario.batch_size,
      now: () => clock,
      random: () => {
        unscripted.push('a random draw');
        // Not zero: an unscripted failure retried after no delay at all would fall due again at
        // once, and the advance below would never end.
        return 0.5;
      },
      newBatchId: () => `b${(minted += 1)}`,
      wake: (at) => {
        uploaderWake = at;
      },
      triggers: new TriggerEvents({
        persist: true,
        fetch: async () => {
          unscripted.push('a trigger list fetch');
          return null;
        },
      }),
      spacingNamed: (milliseconds) => pace.spacingNamed(milliseconds),
      backlogLeft: () => pace.backlogLeft(),
    });
    const pace: FlushPace = new FlushPace({
      writeKey: scenario.key === 'test' ? 'pk_test_fixture' : 'pk_live_fixture',
      chosenMs: scenario.flush_interval_ms,
      named: uploader.flushSpacing,
      now: () => clock,
      conditions: () => ({
        constrained: scenario.network === 'constrained',
        metered: scenario.network === 'metered',
      }),
      wake: (at) => {
        paceWake = at;
      },
      flush: () => uploader.flush(),
    });

    /** Fires each timer every time the clock passes it, the earlier first, the way `setTimeout` would. */
    const advanceTo = async (at: number) => {
      for (let fired = 0; ; fired += 1) {
        // A pair that re-arms itself at the moment it is woken would otherwise hang the suite.
        if (fired > 200) throw new Error(`wakes kept falling due before ${at}; the scenario cannot settle`);
        const uploaderDue: number = uploaderWake ?? Infinity;
        const paceDue: number = paceWake ?? Infinity;
        const due = Math.min(uploaderDue, paceDue);
        if (due > epoch + at) break;
        clock = Math.max(clock, due);
        if (uploaderDue <= paceDue) {
          uploaderWake = null;
          await uploader.woken();
        } else {
          paceWake = null;
          await pace.woken();
        }
      }
      clock = epoch + at;
    };

    for (const [index, step] of scenario.steps.entries()) {
      const label = `${scenario.id} step ${index + 1} (${step.do})`;
      sent = [];
      unscripted = [];
      responses = [...(step.responses ?? [])];

      await advanceTo(step.at);
      if (step.do === 'track') {
        for (const id of step.events ?? []) {
          const name = step.trigger ? LISTED : UNLISTED;
          // `TreebarsWeb.enqueue`: on the queue, then offered to the uploader and to the pace.
          queue.add(event(id, name));
          uploader.eventLogged(name);
          pace.eventLogged();
          // `TreebarsWeb.track`: a full batch goes at once.
          if (queue.size >= batchSize) await uploader.flush();
        }
      }

      expect(unscripted, `${label}: not in the scenario`).toEqual([]);
      expect(responses, `${label}: responses never asked for`).toEqual([]);
      expect(
        sent.map((batch) => ({ events: batch.events.map((each) => each.event_id) })),
        `${label}: sent`,
      ).toEqual(step.expect?.sent ?? []);
    }

    // Everything tracked was sent: nothing is left for a wake the scenario never reached.
    expect(new EventStore(true).all().map((each) => each.event_id), `${scenario.id}: left on the queue`).toEqual([]);
    expect(new UploaderStore(true).load().pending, `${scenario.id}: left pending`).toEqual([]);
  });
});

describe('the spacing between uploads', () => {
  const rule = { chosen: null, testKey: false, named: null };

  it('is the default until an upload names one, and what it named from then on', () => {
    expect(flushSpacingMs(rule, UNHURRIED)).toBe(FLUSH_SPACING_MS);
    expect(flushSpacingMs({ ...rule, named: FLUSH_SPACING_MIN_MS }, UNHURRIED)).toBe(FLUSH_SPACING_MIN_MS);
  });

  it('keeps an interval the app chose, never tighter than the debounce', () => {
    expect(flushSpacingMs({ ...rule, chosen: FLUSH_SPACING_MAX_MS, named: FLUSH_SPACING_MIN_MS }, UNHURRIED)).toBe(FLUSH_SPACING_MAX_MS);
    expect(flushSpacingMs({ ...rule, chosen: 0 }, UNHURRIED)).toBe(FLUSH_DEBOUNCE_MS);
    expect(flushSpacingMs({ ...rule, chosen: -1 }, UNHURRIED)).toBe(FLUSH_DEBOUNCE_MS);
  });

  it('takes an interval that is not a number as no choice at all', () => {
    expect(flushSpacingMs({ ...rule, chosen: Number.NaN }, UNHURRIED)).toBe(FLUSH_SPACING_MS);
    expect(flushSpacingMs({ ...rule, chosen: undefined }, UNHURRIED)).toBe(FLUSH_SPACING_MS);
    // An interval of forever is a choice: nothing is uploaded for the spacing's sake.
    expect(flushSpacingMs({ ...rule, chosen: Infinity }, UNHURRIED)).toBe(Infinity);
  });

  it('does not ask a quiet device for its conditions', () => {
    const asked = vi.fn(() => FLUSH_SPACING_MS);
    expect(flushDueAt(10_000, null, asked)).toBe(10_000 + FLUSH_DEBOUNCE_MS);
    expect(asked).not.toHaveBeenCalled();
  });

  it('counts an upload that began after now as beginning now: the clock moved backwards since', () => {
    expect(flushDueAt(10_000, 99_000, () => FLUSH_SPACING_MS)).toBe(10_000 + FLUSH_SPACING_MS);
  });

  it('reads whole milliseconds off the header and nothing looser, within bounds', () => {
    expect(readFlushSpacing(String(FLUSH_SPACING_MS))).toBe(FLUSH_SPACING_MS);
    expect(readFlushSpacing(` ${FLUSH_SPACING_MS} `)).toBe(FLUSH_SPACING_MS);
    expect(readFlushSpacing('0')).toBe(FLUSH_SPACING_MIN_MS);
    expect(readFlushSpacing('9'.repeat(400))).toBe(FLUSH_SPACING_MAX_MS);
    for (const unreadable of [null, undefined, '', ' ', 'soon', '2.5', '-5000', '5e3', '0x1388', '5000ms', '5 000']) {
      expect(readFlushSpacing(unreadable), String(unreadable)).toBeNull();
    }
  });

  it('holds a stored spacing to the bounds again, and takes anything else as none', () => {
    expect(boundedFlushSpacing(FLUSH_SPACING_MS)).toBe(FLUSH_SPACING_MS);
    expect(boundedFlushSpacing(1)).toBe(FLUSH_SPACING_MIN_MS);
    expect(boundedFlushSpacing(Infinity)).toBe(FLUSH_SPACING_MAX_MS);
    for (const junk of [null, undefined, Number.NaN, '5000', {}, true]) expect(boundedFlushSpacing(junk)).toBeNull();
  });
});

describe('the pace, armed', () => {
  /** A pace on a clock the test moves. `flushed` is called with it each time its wake flushes. */
  const build = (clock: { now: number }, flushed: (pace: FlushPace) => void = () => {}) => {
    const wakes: number[] = [];
    const flush = vi.fn(async () => flushed(pace));
    const pace: FlushPace = new FlushPace({
      writeKey: 'pk_live_pace',
      now: () => clock.now,
      wake: (at) => void wakes.push(at),
      flush,
    });
    return { pace, wakes, flush };
  };

  it('pushes an armed upload out when another begins, and never pulls one in', () => {
    const clock = { now: 0 };
    const { pace, wakes } = build(clock);
    pace.eventLogged();
    expect(wakes).toEqual([FLUSH_DEBOUNCE_MS]);

    // Somebody else's upload — a listed event's, a `flush()` — carries what this one was armed for.
    clock.now = 400;
    pace.uploadBegan();
    expect(wakes).toEqual([FLUSH_DEBOUNCE_MS, 400 + FLUSH_SPACING_MS]);
    expect(pace.dueAt).toBe(400 + FLUSH_SPACING_MS);

    // Later events ride the armed upload rather than moving it.
    clock.now = 900;
    pace.eventLogged();
    expect(wakes).toHaveLength(2);
  });

  it('is spent before it flushes, so the upload it starts leaves nothing armed', async () => {
    const clock = { now: 0 };
    // The flush it asks for sends a batch, as a flush with something queued does.
    const { pace, wakes, flush } = build(clock, (armed) => armed.uploadBegan());
    pace.eventLogged();
    clock.now = FLUSH_DEBOUNCE_MS;
    await pace.woken();

    expect(flush).toHaveBeenCalledTimes(1);
    expect(pace.dueAt).toBeNull();
    expect(wakes).toEqual([FLUSH_DEBOUNCE_MS]);

    // A wake nothing armed flushes nothing.
    await pace.woken();
    expect(flush).toHaveBeenCalledTimes(1);
  });

  it('arms the upload that carries a backlog on, a spacing after the last one began, with no event to ask', () => {
    const clock = { now: 0 };
    const { pace, wakes } = build(clock);
    pace.uploadBegan();
    clock.now = 300;
    pace.backlogLeft();
    expect(wakes).toEqual([FLUSH_SPACING_MS]);

    // One armed already is left where it is: every upload that began pushed it at least this far.
    pace.backlogLeft();
    expect(wakes).toHaveLength(1);
  });

  it('starts from the spacing an earlier page load was told', () => {
    const clock = { now: 0 };
    const wakes: number[] = [];
    const pace = new FlushPace({
      writeKey: 'pk_live_pace',
      named: FLUSH_SPACING_MAX_MS,
      now: () => clock.now,
      wake: (at) => void wakes.push(at),
      flush: () => {},
    });
    pace.uploadBegan();
    pace.eventLogged();
    expect(wakes).toEqual([FLUSH_SPACING_MAX_MS]);
  });

  it('holds what it is started with to the bounds, whoever kept it', () => {
    const wakes: number[] = [];
    const pace = new FlushPace({
      writeKey: 'pk_live_pace',
      named: FLUSH_SPACING_MAX_MS * 10,
      now: () => 0,
      wake: (at) => void wakes.push(at),
      flush: () => {},
    });
    pace.uploadBegan();
    pace.eventLogged();
    expect(wakes).toEqual([FLUSH_SPACING_MAX_MS]);
  });
});
