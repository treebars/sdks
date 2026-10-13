import { readFileSync } from 'node:fs';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { RemoteConfig, type ConfigAnswer, type ConfigAsk, type ConfigAttributes, type ConfigEntry, type ConfigType } from '../src/config';
import { AUTH_COOLDOWN_SECONDS, CONFIG_EXPOSURE_FLOOR_SECONDS, CONFIG_RETRY_SECONDS, RETRY_AFTER_MAX_SECONDS, STORAGE_KEYS } from '../src/generated/constants';

/**
 * The shared remote config scenarios, run against this core.
 *
 * The same scenario file drives the Android and iOS SDKs' config tests, so the three cores are held to one
 * set of rules: when to ask, what a read answers, and what a sign-in or a sign-out does to both. The harness
 * owns exactly what the host owns in the page — storage, the clock, and the request — and scripts the answers.
 * `config-transport.test.ts` is where the real `fetch`, the upload's header and the page are exercised.
 */

interface Asked {
  user: string | null;
  attributes: ConfigAttributes;
}

type Scripted = { version?: unknown; values?: unknown; status?: number; retry_after?: string; network_error?: boolean };

/** A reported exposure, as the scenarios name one. */
interface Exposed {
  experiment: string;
  variant: string;
  variable: string;
}

interface Expect {
  value?: unknown;
  fetches?: Asked[];
  held?: string | null;
  changes?: number;
  result?: boolean;
  exposures?: Exposed[];
}

interface Step {
  do: 'read' | 'list' | 'upload' | 'session' | 'identify' | 'reset' | 'attributes' | 'activate' | 'override' | 'fetch' | 'answer' | 'relaunch';
  at?: number;
  key?: string;
  as?: ConfigType;
  fallback?: unknown;
  config_version?: string | null;
  id?: string;
  user?: string | null;
  session?: string;
  context?: string;
  set?: ConfigAttributes;
  value?: unknown;
  hold?: boolean;
  responses?: Scripted[];
  expect?: Expect;
}

interface Scenario {
  id: string;
  rule: string;
  name: string;
  stored: {
    config: { version: string; values: ConfigEntry[]; asked_as: { context: string } } | null;
    session: { id: string; seen: Record<string, ConfigEntry | null> } | null;
    attributes: ConfigAttributes | null;
  };
  start: { session: string; user: string | null; context: string; responses?: Scripted[]; expect?: Expect };
  steps: Step[];
}

const fixture = JSON.parse(readFileSync(new URL('./fixtures/config-scenarios.json', import.meta.url), 'utf8')) as {
  epoch_ms: number;
  policy: { config_retry_seconds: number; retry_after_max_seconds: number; auth_cooldown_seconds: number; config_exposure_floor_seconds: number };
  scenarios: Scenario[];
};

function memoryStorage() {
  const map = new Map<string, string>();
  return {
    getItem: (key: string) => map.get(key) ?? null,
    setItem: (key: string, value: string) => void map.set(key, value),
    removeItem: (key: string) => void map.delete(key),
    clear: () => map.clear(),
    key: (index: number) => [...map.keys()][index] ?? null,
    get length() {
      return map.size;
    },
  };
}

/** Lets every promise the step started run to where it waits on something only a later step gives. */
const settle = async (): Promise<void> => {
  for (let turn = 0; turn < 20; turn += 1) await Promise.resolve();
};

describe('the shared remote config scenarios', () => {
  beforeEach(() => {
    vi.stubGlobal('localStorage', memoryStorage());
    vi.stubGlobal('sessionStorage', memoryStorage());
  });
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('were written against the waits this SDK is built with', () => {
    expect(fixture.policy).toEqual({
      config_retry_seconds: CONFIG_RETRY_SECONDS,
      retry_after_max_seconds: RETRY_AFTER_MAX_SECONDS,
      auth_cooldown_seconds: AUTH_COOLDOWN_SECONDS,
      config_exposure_floor_seconds: CONFIG_EXPOSURE_FLOOR_SECONDS,
    });
  });

  it.each(fixture.scenarios.map((scenario) => [scenario.id, scenario.name, scenario] as const))('%s: %s', async (_id, _name, scenario) => {
    let now = fixture.epoch_ms;
    let asked: Asked[] = [];
    let changes = 0;
    let exposures: Exposed[] = [];
    /** The answers scripted for the asks the running step starts, and the asks left out by a `hold`. */
    let scripted: Scripted[] = [];
    let holding = false;
    const out: Array<(answer: ConfigAnswer) => void> = [];

    const answerFor = (response: Scripted | undefined): ConfigAnswer => {
      if (!response) throw new Error(`${scenario.id}: an ask was started with no answer scripted for it`);
      if (response.network_error) return { ok: false };
      if (response.status !== undefined) return { ok: false, status: response.status, retryAfter: response.retry_after ?? null };
      return { ok: true, body: { version: response.version, values: response.values } };
    };
    const fetch = (ask: ConfigAsk): Promise<ConfigAnswer> => {
      asked.push({ user: ask.userId, attributes: ask.attributes });
      if (holding) return new Promise((resolve) => out.push(resolve));
      return Promise.resolve(answerFor(scripted.shift()));
    };

    if (scenario.stored.config) {
      const { version, values, asked_as } = scenario.stored.config;
      localStorage.setItem(STORAGE_KEYS.config, JSON.stringify({ set: { version, values, context: asked_as.context, stale: false }, not_before: 0 }));
    }
    if (scenario.stored.session) localStorage.setItem(STORAGE_KEYS.configSession, JSON.stringify(scenario.stored.session));
    if (scenario.stored.attributes) localStorage.setItem(STORAGE_KEYS.configAttributes, JSON.stringify(scenario.stored.attributes));

    let config!: RemoteConfig;
    let user: string | null = null;
    const launch = (state: { session: string; user: string | null; context: string }) => {
      config = new RemoteConfig({
        persist: true,
        fetch,
        expose: (exposure) => exposures.push({ experiment: exposure.experimentKey, variant: exposure.variant, variable: exposure.variable }),
        now: () => now,
      });
      config.onChange(() => {
        changes += 1;
      });
      user = state.user;
      config.start({ sessionId: state.session, userId: state.user, context: state.context });
    };

    const check = (label: string, expected: Expect | undefined, result?: unknown) => {
      if (!expected) return;
      if ('fetches' in expected) expect(asked, `${label}: who asked`).toEqual(expected.fetches);
      if ('held' in expected) expect(config.version, `${label}: the version held`).toBe(expected.held);
      if ('changes' in expected) expect(changes, `${label}: changes announced`).toBe(expected.changes);
      if ('result' in expected) expect(result, `${label}: what the call answered`).toBe(expected.result);
      if ('value' in expected) expect(result, `${label}: what the read answered`).toEqual(expected.value);
      if ('exposures' in expected) expect(exposures, `${label}: exposures reported`).toEqual(expected.exposures);
    };

    scripted = [...(scenario.start.responses ?? [])];
    launch(scenario.start);
    await settle();
    check(`${scenario.id} start`, scenario.start.expect);
    expect(scripted, `${scenario.id} start: answers scripted and never asked for`).toEqual([]);

    for (const [index, step] of scenario.steps.entries()) {
      const label = `${scenario.id} step ${index + 1} (${step.do})`;
      if (step.at !== undefined) now = fixture.epoch_ms + step.at;
      asked = [];
      changes = 0;
      exposures = [];
      scripted = [...(step.responses ?? [])];
      holding = step.hold === true;
      let result: unknown;

      switch (step.do) {
        case 'read':
          result = config.read(step.key!, step.as!, step.fallback);
          break;
        case 'list':
          config.all();
          break;
        case 'upload':
          config.observe(step.config_version ?? null);
          break;
        case 'session':
          config.sessionStarted(step.id!);
          break;
        case 'identify':
          user = step.user ?? null;
          config.identityChanged(user);
          break;
        case 'reset':
          user = null;
          config.identityChanged(null);
          break;
        case 'attributes':
          config.setAttributes(step.set);
          break;
        case 'activate':
          result = config.activate();
          break;
        case 'override':
          config.override(step.key!, step.value);
          break;
        case 'fetch':
          result = await config.refresh();
          break;
        case 'answer':
          // The asks left out are answered in the order they were started; one an answer starts takes the next.
          while (out.length > 0) {
            out.shift()!(answerFor(scripted.shift()));
            await settle();
          }
          break;
        case 'relaunch':
          launch({ session: step.session!, user: step.user ?? null, context: step.context! });
          break;
      }
      holding = false;
      await settle();
      check(label, step.expect, result);
      expect(scripted, `${label}: answers scripted and never asked for`).toEqual([]);
    }
    expect(out, `${scenario.id}: an ask was left out and never answered`).toEqual([]);
    // Used only to keep the harness honest about who it believes is signed in.
    void user;
  });
});
