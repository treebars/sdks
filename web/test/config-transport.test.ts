import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { STORAGE_KEYS } from '../src/generated/constants';
import { TreebarsWeb } from '../src/index';

/**
 * The half of remote config the shared scenarios cannot reach: what `TreebarsWeb` does with a real `fetch`, a
 * real timer and a page. The scenarios pin the rules; these pin that the browser glue feeds them — the version
 * is read off an accepted upload's answer, the request says who is asking and proves it, an opted-out visitor
 * is never asked about, and what a key read as survives a page load inside the session.
 */

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

interface Request {
  method: string;
  url: URL;
  headers: Record<string, string>;
  body: Record<string, unknown>;
}

const values = (flag: boolean, more: unknown[] = []) => ({
  version: flag ? '3' : '4',
  values: [{ key: 'new_checkout', type: 'boolean', value: flag }, ...more],
  server_time: 'now',
});

describe('the browser glue around remote config', () => {
  let requests: Request[];
  /** What an upload's answer names as the config version, or null for none. */
  let named: string | null;
  let config: (request: Request) => Response | Promise<Response>;
  let sdk: TreebarsWeb;

  beforeEach(() => {
    vi.useFakeTimers({ now: Date.parse('2026-09-15T12:00:00.000Z') });
    // Uncompressed: Node has `CompressionStream`, and a stream finishes over real turns of the loop, which a faked
    // clock does not wait for — so an upload's answer would arrive after the assertion that reads it.
    vi.stubGlobal('CompressionStream', undefined);
    vi.stubGlobal('localStorage', memoryStorage());
    vi.stubGlobal('sessionStorage', memoryStorage());
    requests = [];
    named = null;
    config = () => Response.json(values(true));

    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string, init: RequestInit = {}) => {
        const request: Request = {
          method: init.method ?? 'GET',
          url: new URL(url),
          headers: (init.headers ?? {}) as Record<string, string>,
          body: typeof init.body === 'string' ? (JSON.parse(init.body) as Record<string, unknown>) : {},
        };
        requests.push(request);
        if (request.url.pathname === '/v1/config') return config(request);
        if (request.url.pathname === '/v1/events') return new Response('{}', { status: 200, headers: named ? { 'X-Treebars-Config-Version': named } : {} });
        return new Response('{}', { status: 200 });
      }),
    );
    vi.stubGlobal('navigator', { userAgent: 'vitest', language: 'en-GB', sendBeacon: () => true });
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
  });

  afterEach(() => {
    sdk.shutdown();
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  const start = (client: TreebarsWeb = sdk) =>
    client.init({
      writeKey: 'pk_test_config',
      backendUrl: 'https://ingest.test',
      inAppEnabled: false,
      autoPageViews: false,
      autoLifecycle: false,
      autoSessions: false,
    });
  /** Moves the clock, and lets what that started — an upload, the ask its answer prompts — finish. */
  const settle = async (milliseconds = 0) => {
    await vi.advanceTimersByTimeAsync(milliseconds);
    for (let turn = 0; turn < 4; turn += 1) await vi.advanceTimersByTimeAsync(0);
  };
  /** An event, and the upload it arms, answered. */
  const upload = async (client: TreebarsWeb = sdk) => {
    client.track('screen_view');
    await settle(3_000);
  };
  const asks = () => requests.filter((each) => each.url.pathname === '/v1/config');

  it('asks nothing while no upload names a version, and reads answer the fallback', async () => {
    start();
    await upload();
    expect(asks()).toHaveLength(0);
    expect(sdk.getConfigBoolean('new_checkout', false)).toBe(false);
    expect(sdk.allConfig()).toEqual({});
  });

  it('reads a value as the kind its fallback is, and never as the kind that was published', async () => {
    config = () =>
      Response.json(
        values(true, [
          { key: 'headline', type: 'string', value: 'Hello' },
          { key: 'limit', type: 'number', value: 25 },
          { key: 'layout', type: 'json', value: { columns: 3 } },
          // A flag somebody published as text: it must not read as on.
          { key: 'texted', type: 'string', value: 'false' },
        ]),
      );
    start();
    named = '3';
    await upload();

    expect(sdk.getConfig('new_checkout', false)).toBe(true);
    expect(sdk.getConfig('headline', 'Welcome')).toBe('Hello');
    expect(sdk.getConfig('limit', 10)).toBe(25);
    expect(sdk.getConfig('layout', { columns: 2 })).toEqual({ columns: 3 });
    // Another kind than the fallback's is the fallback, whatever is held.
    expect(sdk.getConfig('texted', true)).toBe(true);
    expect(sdk.getConfig('headline', 0)).toBe(0);
    expect(sdk.getConfig('missing', '')).toBe('');
    // An empty fallback is still a kind; nothing at all is not, and is answered with nothing.
    expect((sdk.getConfig as (key: string, fallback: unknown) => unknown)('headline', null)).toBeNull();
    expect((sdk.getConfig as (key: string, fallback: unknown) => unknown)('headline', undefined)).toBeNull();
  });

  it('answers null, not a guess, for a kind named with no fallback', async () => {
    config = () => Response.json(values(true, [{ key: 'headline', type: 'string', value: 'Hello' }, { key: 'layout', type: 'json', value: [1, 2] }]));
    start();
    // Before anything is held, and for a key nobody published.
    expect(sdk.getConfigString('headline')).toBeNull();
    expect(sdk.getConfigBoolean('never_made')).toBeNull();
    named = '3';
    await upload();

    // `headline` was read as "not set" above, and a key keeps its answer for the session: applied, it answers.
    sdk.activateConfig();
    expect(sdk.getConfigString('headline')).toBe('Hello');
    expect(sdk.getConfigBoolean('new_checkout')).toBe(true);
    expect(sdk.getConfigJson<number[]>('layout')).toEqual([1, 2]);
    expect(sdk.getConfigNumber('headline')).toBeNull();
    expect(sdk.getConfigNumber('never_made')).toBeNull();
  });

  it('asks once when an upload names a version it does not hold, as this browser and nobody', async () => {
    start();
    named = '3';
    await upload();

    expect(asks()).toHaveLength(1);
    const [ask] = asks();
    expect(ask!.method).toBe('POST');
    expect(ask!.headers['X-Treebars-Key']).toBe('pk_test_config');
    // The answer is this browser's own experience: no secret is sent where none is needed.
    expect(ask!.headers['X-Treebars-Device-Auth']).toBeUndefined();
    expect(ask!.headers['X-Treebars-User-Signature']).toBeUndefined();
    expect(ask!.body.device_id).toMatch(/^dev_/);
    expect(ask!.body.user_id).toBeUndefined();
    expect(ask!.body.attributes).toBeUndefined();
    expect(ask!.body.context).toMatchObject({ platform_type: 'web', locale: 'en-GB' });

    expect(sdk.getConfigBoolean('new_checkout', false)).toBe(true);
    // The same version on the next upload is not news.
    await upload();
    expect(asks()).toHaveLength(1);
  });

  it('says who is signed in, and proves it with the signature held', async () => {
    start();
    named = '3';
    config = () => Response.json(values(true, [{ key: 'tier', type: 'string', value: 'free', user_dependent: true }]));
    await upload();
    expect(asks()).toHaveLength(1);

    config = () => Response.json(values(true, [{ key: 'tier', type: 'string', value: 'gold', user_dependent: true }]));
    sdk.identify('user_42', {}, 'a1b2c3');
    await settle();
    expect(asks()).toHaveLength(2);
    expect(asks()[1]!.body.user_id).toBe('user_42');
    expect(asks()[1]!.headers['X-Treebars-User-Signature']).toBe('a1b2c3');
    expect(sdk.getConfigString('tier', 'none')).toBe('gold');

    // Signing out drops the account's answer at once, and asks again as nobody.
    config = () => new Promise<Response>(() => {});
    sdk.reset();
    expect(sdk.getConfigString('tier', 'none')).toBe('none');
    await settle();
    expect(asks()).toHaveLength(3);
    expect(asks()[2]!.body.user_id).toBeUndefined();
    expect(asks()[2]!.headers['X-Treebars-User-Signature']).toBeUndefined();
  });

  it('sends what the page set, even when it was set before init', async () => {
    sdk.setConfigAttributes({ plan: 'pro', seats: 5 });
    start();
    named = '3';
    await upload();
    expect(asks()[0]!.body.attributes).toEqual({ plan: 'pro', seats: 5 });

    // The same ones again are not a change; different ones ask.
    sdk.setConfigAttributes({ seats: 5, plan: 'pro' });
    await settle();
    expect(asks()).toHaveLength(1);
    sdk.setConfigAttributes({ plan: 'team' });
    await settle();
    expect(asks()).toHaveLength(2);
    expect(asks()[1]!.body.attributes).toEqual({ plan: 'team' });
  });

  it('configReady asks on a first visit and waits for the answer, and asks nothing once values are held', async () => {
    start();
    const ready = sdk.configReady();
    await settle();
    await expect(ready).resolves.toBe(true);
    expect(asks()).toHaveLength(1);
    expect(sdk.getConfigBoolean('new_checkout', false)).toBe(true);

    await expect(sdk.configReady()).resolves.toBe(true);
    expect(asks()).toHaveLength(1);
  });

  it('configReady gives up at its timeout and the page goes on with its own values', async () => {
    start();
    config = () => new Promise<Response>(() => {});
    const ready = sdk.configReady(500);
    await vi.advanceTimersByTimeAsync(499);
    let done = false;
    void ready.then(() => {
      done = true;
    });
    await settle();
    expect(done).toBe(false);
    await vi.advanceTimersByTimeAsync(1);
    await expect(ready).resolves.toBe(false);
    expect(sdk.getConfigBoolean('new_checkout', false)).toBe(false);
  });

  it('keeps what it holds when the endpoint cannot say, and waits before asking again', async () => {
    start();
    named = '3';
    await upload();
    expect(sdk.getConfigBoolean('new_checkout', false)).toBe(true);

    named = '4';
    config = () => new Response('{"error":"config_unavailable"}', { status: 503, headers: { 'Retry-After': '120' } });
    sdk.shutdown();
    sdk = new TreebarsWeb();
    start();
    await upload();
    expect(asks()).toHaveLength(2);
    // A second upload inside the wait asks nothing more.
    await upload();
    expect(asks()).toHaveLength(2);
    expect(JSON.parse(localStorage.getItem(STORAGE_KEYS.config)!).set.version).toBe('3');
  });

  it('keeps a key’s answer across a page load inside the session', async () => {
    start();
    named = '3';
    await upload();
    expect(sdk.getConfigBoolean('new_checkout', false)).toBe(true);

    // A newer config is published and reaches this browser; the key already read keeps its answer…
    named = '4';
    config = () => Response.json(values(false));
    await upload();
    expect(asks()).toHaveLength(2);
    expect(sdk.getConfigBoolean('new_checkout', false)).toBe(true);

    // …on the next page of the same visit too.
    sdk.shutdown();
    sdk = new TreebarsWeb();
    start();
    sdk.track('screen_view');
    expect(sdk.getConfigBoolean('new_checkout', true)).toBe(true);
    // Until the page says it can redraw.
    expect(sdk.activateConfig()).toBe(true);
    expect(sdk.getConfigBoolean('new_checkout', true)).toBe(false);
  });

  it('tells the page when a read may answer differently, and stops when asked to', async () => {
    let heard = 0;
    const stop = sdk.onConfigChange(() => {
      heard += 1;
    });
    start();
    named = '3';
    await upload();
    expect(heard).toBe(1);

    sdk.setConfigOverride('new_checkout', false);
    expect(heard).toBe(2);
    expect(sdk.getConfigBoolean('new_checkout', true)).toBe(false);
    stop();
    sdk.setConfigOverride('new_checkout', undefined);
    expect(heard).toBe(2);
    expect(sdk.getConfigBoolean('new_checkout', false)).toBe(true);
  });

  it('records the variant a read answered as an event, once, and nothing for a value never read', async () => {
    start();
    named = '3';
    const experiment = { id: 'e-1', key: 'checkout_test', variant: 'one_tap', unit: 'device' };
    config = () =>
      Response.json({
        version: '3',
        values: [
          { key: 'new_checkout', type: 'boolean', value: true, experiment },
          { key: 'unread', type: 'string', value: 'b', experiment: { id: 'e-2', key: 'copy_test', variant: 'b', unit: 'device' } },
        ],
        server_time: 'now',
      });
    await upload();
    const exposures = () =>
      requests
        .filter((each) => each.url.pathname === '/v1/events')
        .flatMap((each) => each.body.events as Array<{ event_name: string; properties: Record<string, unknown> }>)
        .filter((event) => event.event_name === 'experiment_exposed');
    // Holding a variant is not being shown it.
    expect(exposures()).toHaveLength(0);

    expect(sdk.getConfigBoolean('new_checkout', false)).toBe(true);
    expect(sdk.getConfigBoolean('new_checkout', false)).toBe(true);
    await settle(3_000);
    expect(exposures().map((event) => event.properties)).toEqual([
      expect.objectContaining({ experiment_id: 'e-1', experiment_key: 'checkout_test', variant: 'one_tap', variable: 'new_checkout', unit: 'device' }),
    ]);

    // The next page of the visit reads it again and reports nothing more.
    sdk.shutdown();
    sdk = new TreebarsWeb();
    start();
    expect(sdk.getConfigBoolean('new_checkout', false)).toBe(true);
    await upload();
    expect(exposures()).toHaveLength(1);
  });

  it('asks nothing for a visitor who opted out, and forgets what it held', async () => {
    start();
    named = '3';
    await upload();
    expect(sdk.getConfigBoolean('new_checkout', false)).toBe(true);

    sdk.optOut();
    expect(sdk.getConfigBoolean('new_checkout', false)).toBe(false);
    expect(localStorage.getItem(STORAGE_KEYS.config)).toBeNull();
    await expect(sdk.fetchConfig()).resolves.toBe(false);
    await expect(sdk.configReady()).resolves.toBe(false);
    expect(asks()).toHaveLength(1);
  });

  it('drops another write key’s values with everything else that key left', async () => {
    start();
    named = '3';
    await upload();
    expect(localStorage.getItem(STORAGE_KEYS.config)).not.toBeNull();

    sdk.shutdown();
    sdk = new TreebarsWeb();
    sdk.init({ writeKey: 'pk_test_other', backendUrl: 'https://ingest.test', inAppEnabled: false, autoPageViews: false, autoLifecycle: false, autoSessions: false });
    expect(sdk.getConfigBoolean('new_checkout', false)).toBe(false);
    expect(localStorage.getItem(STORAGE_KEYS.config)).toBeNull();
  });
});
