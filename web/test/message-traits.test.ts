import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { STORAGE_KEYS } from '../src/generated/constants';
import { TreebarsWeb } from '../src/index';

/**
 * Traits a message sets before anybody signs in go on the anonymous visitor as `traits_set`, and the server carries
 * them into the account at sign-in — so an onboarding survey keeps the answers of exactly the people it is shown to.
 * A signed-in person's go through `identify()`.
 */

function webStorage() {
  const map = new Map<string, string>();
  return {
    get length() {
      return map.size;
    },
    key: (index: number) => [...map.keys()][index] ?? null,
    getItem: (key: string) => map.get(key) ?? null,
    setItem: (key: string, value: string) => void map.set(key, value),
    removeItem: (key: string) => void map.delete(key),
    clear: () => map.clear(),
  };
}

describe('traits a message sets', () => {
  let local: ReturnType<typeof webStorage>;
  let posted: { path: string; body: Record<string, unknown> }[];
  let sdk: TreebarsWeb | null;

  beforeEach(() => {
    vi.useFakeTimers({ now: Date.parse('2026-09-28T12:00:00.000Z') });
    local = webStorage();
    posted = [];
    sdk = null;
    vi.stubGlobal('localStorage', local);
    vi.stubGlobal('sessionStorage', webStorage());
    vi.stubGlobal('navigator', { userAgent: 'vitest', language: 'en-GB', sendBeacon: () => true });
    const document = Object.assign(new EventTarget(), { visibilityState: 'visible', title: 'Shop', referrer: '', cookie: '' });
    vi.stubGlobal('document', document);
    vi.stubGlobal(
      'window',
      Object.assign(new EventTarget(), {
        screen: { width: 1280, height: 800 },
        devicePixelRatio: 1,
        location: { href: 'https://shop.test/', pathname: '/', origin: 'https://shop.test', hostname: 'shop.test', protocol: 'https:' },
      }),
    );
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string, init?: RequestInit) => {
        const body = typeof init?.body === 'string' ? (JSON.parse(init.body) as Record<string, unknown>) : {};
        posted.push({ path: new URL(url).pathname, body });
        return Response.json({ accepted: 1, messages: [], notifications: [], unread_count: 0, server_time: 'now' });
      }),
    );
  });

  afterEach(() => {
    sdk?.shutdown();
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  function start(): TreebarsWeb & { setMessageTraits(traits: Record<string, unknown>): void } {
    sdk = new TreebarsWeb();
    sdk.init({ writeKey: 'pk_live_traits', backendUrl: 'https://ingest.test', autoPageViews: false, flushIntervalMs: 60 * 60 * 1000 });
    return sdk as TreebarsWeb & { setMessageTraits(traits: Record<string, unknown>): void };
  }

  const queued = () => JSON.parse(local.getItem(STORAGE_KEYS.queue) ?? '[]') as { event_name: string; properties: Record<string, unknown> }[];

  it('go on the anonymous visitor as traits_set, with nothing sent to the sign-in route', async () => {
    const instance = start();
    await vi.runOnlyPendingTimersAsync();
    posted = [];

    instance.setMessageTraits({ streak: 3, first_name: 'Ada' });
    const event = queued().find((row) => row.event_name === 'traits_set');
    expect(event?.properties).toEqual({ trait_keys: ['first_name', 'streak'], traits: { streak: 3, first_name: 'Ada' } });
    expect(posted.filter((request) => request.path === '/v1/identify')).toEqual([]);
  });

  it('go through identify() for somebody signed in, as they always did', async () => {
    const instance = start();
    instance.identify('user_42');
    await vi.runOnlyPendingTimersAsync();
    posted = [];

    instance.setMessageTraits({ streak: 3 });
    await vi.runOnlyPendingTimersAsync();
    expect(queued().some((row) => row.event_name === 'traits_set')).toBe(false);
    const signIn = posted.find((request) => request.path === '/v1/identify');
    expect(signIn?.body).toMatchObject({ user_id: 'user_42', attributes: { streak: 3 } });
  });
});
