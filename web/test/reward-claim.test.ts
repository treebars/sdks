import { readFileSync } from 'node:fs';

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import {
  BACKOFF_BASE_SECONDS,
  BACKOFF_CAP_SECONDS,
  REWARD_CLAIM_BUDGET_MS,
  REWARD_CLAIM_RETRIES,
  RETRY_AFTER_STATUSES,
} from '../src/generated/constants';
import { TreebarsWeb } from '../src/index';
import { claimWithRetries, rewardRefusal, type RewardAttempt } from '../src/reward-claim';

/**
 * The shared reward-claim scenarios, run against this core, and then the one thing they cannot reach: that
 * `TreebarsWeb` hands the loop a real `fetch`'s status and `Retry-After`, and tells the page what came back.
 */

interface Answer {
  status: number | null;
  retry_after?: string;
  answer?: boolean;
  took_ms?: number;
}

interface Scenario {
  id: string;
  name: string;
  answers: Answer[];
  random: number[];
  expect: { requests: number; waits: number[]; outcome: string };
}

const fixture = JSON.parse(
  readFileSync(new URL('./fixtures/reward-claim-scenarios.json', import.meta.url), 'utf8'),
) as { now_ms: number; policy: Record<string, unknown>; scenarios: Scenario[] };

describe('the shared reward-claim scenarios', () => {
  // The numbers in the scenarios are consequences of the policy; a moved constant would make them check the wrong sums.
  it('were derived from the generated policy', () => {
    expect(fixture.policy).toEqual({
      retries: REWARD_CLAIM_RETRIES,
      budget_ms: REWARD_CLAIM_BUDGET_MS,
      retry_after_statuses: [...RETRY_AFTER_STATUSES],
      backoff_base_seconds: BACKOFF_BASE_SECONDS,
      backoff_cap_seconds: BACKOFF_CAP_SECONDS,
    });
  });

  it.each(fixture.scenarios.map((scenario) => [`${scenario.id} ${scenario.name}`, scenario] as const))('%s', async (_, scenario) => {
    let clock = 0;
    const answers = [...scenario.answers];
    const random = [...scenario.random];
    const waits: number[] = [];
    let requests = 0;

    const last = await claimWithRetries(
      async (): Promise<RewardAttempt> => {
        const next = answers.shift();
        if (!next) throw new Error(`${scenario.id}: a request with no answer left`);
        requests += 1;
        clock += next.took_ms ?? 0;
        return { status: next.status, retryAfter: next.retry_after ?? null, answer: next.answer ? { won: true } : null };
      },
      {
        elapsed: () => clock,
        now: () => fixture.now_ms + clock,
        sleep: async (ms) => {
          waits.push(ms);
          clock += ms;
        },
        random: () => {
          if (random.length === 0) throw new Error(`${scenario.id}: a jitter draw the scenario did not expect`);
          return random.shift()!;
        },
      },
    );

    expect(requests).toBe(scenario.expect.requests);
    expect(waits).toEqual(scenario.expect.waits);
    expect(last.answer ? 'answer' : rewardRefusal(last).reason).toBe(scenario.expect.outcome);
    expect(random, `${scenario.id}: random values never drawn`).toEqual([]);
    expect(answers, `${scenario.id}: answers never asked for`).toEqual([]);
  });
});

describe('the browser asking for a reward', () => {
  let rewards: Array<() => Response>;
  let asked: number;
  let sdk: TreebarsWeb;

  function memoryStorage() {
    const map = new Map<string, string>();
    return {
      getItem: (key: string) => map.get(key) ?? null,
      setItem: (key: string, value: string) => void map.set(key, value),
      removeItem: (key: string) => void map.delete(key),
      clear: () => map.clear(),
    };
  }

  beforeEach(() => {
    vi.useFakeTimers({ now: Date.parse('2026-09-28T12:00:00.000Z') });
    // Half the jitter's ceiling: the first draw is exactly a second, the second two.
    vi.spyOn(Math, 'random').mockReturnValue(0.5);
    vi.stubGlobal('localStorage', memoryStorage());
    vi.stubGlobal('sessionStorage', memoryStorage());
    rewards = [];
    asked = 0;
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string) => {
        if (!String(url).endsWith('/v1/in-app/reward')) return new Response('{}', { status: 200 });
        asked += 1;
        const next = rewards.shift();
        if (!next) throw new TypeError('Failed to fetch');
        return next();
      }),
    );
    vi.stubGlobal('navigator', { userAgent: 'vitest', language: 'en-GB' });
    vi.stubGlobal('document', Object.assign(new EventTarget(), { visibilityState: 'visible', title: 'Test', referrer: '' }));
    vi.stubGlobal(
      'window',
      Object.assign(new EventTarget(), {
        screen: { width: 1280, height: 800 },
        devicePixelRatio: 1,
        location: { pathname: '/', href: 'https://shop.test/', origin: 'https://shop.test' },
      }),
    );
    sdk = new TreebarsWeb();
    sdk.init({
      writeKey: 'pk_test_rewards',
      backendUrl: 'https://ingest.test',
      autoPageViews: false,
      autoLifecycle: false,
      autoSessions: false,
      flushIntervalMs: 60 * 60 * 1000,
    });
  });

  afterEach(() => {
    sdk.shutdown();
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  const claim = () => (sdk as unknown as { claimReward(pool: string, deliveryId: string): Promise<Record<string, unknown>> }).claimReward('wheel', 'delivery-1');

  it('asks again after a 503, reading its Retry-After, and hands the page the answer', async () => {
    rewards.push(
      () => new Response(null, { status: 503, headers: { 'Retry-After': '2' } }),
      () => new Response(JSON.stringify({ won: true, prize: '10% off', code: 'AUTUMN-7' }), { status: 200 }),
    );
    const answer = claim();
    await vi.advanceTimersByTimeAsync(1_999);
    // The draw was a second and the server asked for two: the longer is the wait.
    expect(asked).toBe(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(await answer).toEqual({ won: true, prize: '10% off', code: 'AUTUMN-7' });
    expect(asked).toBe(2);
  });

  it('tells the page offline once no answer has come three times', async () => {
    const answer = claim();
    await vi.advanceTimersByTimeAsync(1_000 + 2_000);
    expect(await answer).toEqual({ ok: false, reason: 'offline' });
    expect(asked).toBe(3);
  });

  it('does not ask a 404 again, nor wait out a 429 longer than the page can spin', async () => {
    rewards.push(() => new Response(null, { status: 404 }));
    expect(await claim()).toEqual({ ok: false, reason: 'not_available' });
    rewards.push(() => new Response(null, { status: 429, headers: { 'Retry-After': '60' } }));
    expect(await claim()).toEqual({ ok: false, reason: 'failed' });
    expect(asked).toBe(2);
  });
});
