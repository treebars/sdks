import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { STORAGE_KEYS } from '../src/generated/constants';
import { TreebarsWeb } from '../src/index';

/**
 * The half of the trigger flush the shared scenarios cannot reach: what `TreebarsWeb` does with a
 * real `fetch`, a real `setTimeout` and a page. The scenarios pin the policy; these pin that the
 * browser glue feeds it — every queued event reaches the uploader, the session opening syncs even
 * with in-app off, the version is read off the header, and the list is fetched alone rather than
 * through a sync that would mark messages fetched.
 */

function memoryStorage() {
  const map = new Map<string, string>();
  return {
    getItem: (key: string) => map.get(key) ?? null,
    setItem: (key: string, value: string) => void map.set(key, value),
    removeItem: (key: string) => void map.delete(key),
    clear: () => map.clear(),
  };
}

interface Request {
  method: string;
  url: URL;
  headers: Record<string, string>;
  events: string[];
}

describe('the browser glue around the trigger flush', () => {
  let requests: Request[];
  let answer: (request: Request) => Response;
  let sdk: TreebarsWeb;

  beforeEach(() => {
    vi.useFakeTimers({ now: Date.parse('2026-09-15T12:00:00.000Z') });
    vi.stubGlobal('localStorage', memoryStorage());
    vi.stubGlobal('sessionStorage', memoryStorage());
    requests = [];
    answer = () => new Response('{}', { status: 200 });

    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string, init: RequestInit = {}) => {
        const body = typeof init.body === 'string' ? (JSON.parse(init.body) as { events?: Array<{ event_name: string }> }) : {};
        const request: Request = {
          method: init.method ?? 'GET',
          url: new URL(url),
          headers: (init.headers ?? {}) as Record<string, string>,
          events: (body.events ?? []).map((each) => each.event_name),
        };
        requests.push(request);
        return answer(request);
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

  const start = (inAppEnabled: boolean) =>
    sdk.init({
      writeKey: 'pk_test_triggers',
      backendUrl: 'https://ingest.test',
      inAppEnabled,
      autoPageViews: false,
      autoLifecycle: false,
      autoSessions: false,
      flushIntervalMs: 60 * 60 * 1000,
    });

  const uploads = () => requests.filter((each) => each.method === 'POST' && each.url.pathname === '/v1/events');
  const syncs = () => requests.filter((each) => each.url.pathname === '/v1/in-app');
  const stored = () => JSON.parse(localStorage.getItem(STORAGE_KEYS.triggers) ?? 'null') as unknown;

  it('opens a session with a trigger-only sync when in-app is off, and keeps the list it brings', async () => {
    answer = (request) =>
      request.url.pathname === '/v1/in-app'
        ? Response.json({ trigger_events: { version: 'v1', names: ['purchase'] }, server_time: 'now' })
        : new Response('{}', { status: 200 });
    start(false);
    sdk.track('screen_view');
    await vi.advanceTimersByTimeAsync(0);

    expect(syncs()).toHaveLength(1);
    const [sync] = syncs();
    expect(sync!.url.searchParams.get('triggers_only')).toBe('1');
    expect(sync!.url.searchParams.get('device_id')).toMatch(/^dev_/);
    // The list belongs to the environment, not the device, so no device secret is sent with it.
    expect(sync!.headers['X-Treebars-Device-Auth']).toBeUndefined();
    expect(sync!.headers['X-Treebars-Key']).toBe('pk_test_triggers');
    expect(stored()).toEqual({ version: 'v1', names: ['purchase'] });
  });

  it('reads the list off the whole sync when in-app is on, without a second request', async () => {
    answer = (request) =>
      request.url.pathname === '/v1/in-app'
        ? Response.json({ messages: [], policy: null, trigger_events: { version: 'v1', names: ['signup'] }, server_time: 'now' })
        : new Response('{}', { status: 200 });
    start(true);
    // What `init` uploads on its own leaves first, a turn after it, so no upload of this page is still being
    // compressed when the test ends.
    await vi.advanceTimersByTimeAsync(0);
    sdk.track('screen_view');
    await vi.advanceTimersByTimeAsync(0);

    expect(syncs()).toHaveLength(1);
    expect(syncs()[0]!.url.searchParams.has('triggers_only')).toBe(false);
    expect(stored()).toEqual({ version: 'v1', names: ['signup'] });
  });

  it('uploads a listed event a second after it is logged, through the real timer', async () => {
    localStorage.setItem(STORAGE_KEYS.triggers, JSON.stringify({ version: 'v1', names: ['purchase'] }));
    answer = (request) =>
      request.url.pathname === '/v1/in-app'
        ? Response.json({ trigger_events: { version: 'v1', names: ['purchase'] }, server_time: 'now' })
        : new Response('{}', { status: 200, headers: { 'X-Treebars-Triggers-Version': 'v1' } });
    start(false);
    // What `init` sends on its own — the device context and the session's sync — settles first, or
    // the drain it starts would carry the trigger out before its debounce and prove nothing.
    await vi.advanceTimersByTimeAsync(0);
    const before = uploads().length;

    sdk.track('purchase');
    await vi.advanceTimersByTimeAsync(999);
    expect(uploads()).toHaveLength(before);

    await vi.advanceTimersByTimeAsync(1);
    expect(uploads()).toHaveLength(before + 1);
    expect(uploads().at(-1)!.events).toEqual(['purchase']);
  });

  it('fetches the list alone when an upload answers with another version', async () => {
    localStorage.setItem(STORAGE_KEYS.triggers, JSON.stringify({ version: 'v1', names: ['purchase'] }));
    let listRequests = 0;
    let releaseUpload!: () => void;
    answer = (request) => {
      if (request.url.pathname === '/v1/in-app') {
        listRequests += 1;
        // The session's own sync answers without a list, so only the header can bring v2.
        return listRequests === 1
          ? Response.json({ server_time: 'now' })
          : Response.json({ trigger_events: { version: 'v2', names: ['purchase', 'signup'] }, server_time: 'now' });
      }
      return new Promise<Response>((resolve) => {
        releaseUpload = () => resolve(new Response('{}', { status: 200, headers: { 'X-Treebars-Triggers-Version': 'v2' } }));
      }) as unknown as Response;
    };
    start(false);
    await vi.advanceTimersByTimeAsync(0);
    expect(syncs()).toHaveLength(1);
    expect(uploads()).toHaveLength(1);

    releaseUpload();
    await vi.advanceTimersByTimeAsync(0);

    expect(syncs()).toHaveLength(2);
    expect(syncs().every((each) => each.url.searchParams.get('triggers_only') === '1')).toBe(true);
    expect(stored()).toEqual({ version: 'v2', names: ['purchase', 'signup'] });
  });
});
