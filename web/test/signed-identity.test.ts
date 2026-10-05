import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { HEADERS, STORAGE_KEYS } from '../src/generated/constants';
import { TreebarsWeb } from '../src/index';
import type { NotificationPage } from '../src/notifications';

/**
 * The browser's half of signed identity: the signature the customer's backend made rides on every
 * content read, survives a reload beside the account it names, and leaves with it.
 *
 * A live environment refuses a signed-in person's content reads without it, so each way of losing it
 * here — a route that forgets the header, a reload that restores the id and not the signature, a
 * re-identify that drops it — is somebody's messages silently gone.
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

interface Seen {
  method: string;
  url: URL;
  headers: Record<string, string>;
  body: Record<string, unknown>;
}

const SIGNATURE = 'a1'.repeat(32);

describe('a signed identity in the browser', () => {
  let seen: Seen[];
  let answer: (request: Seen) => Response;
  let sdk: TreebarsWeb;

  beforeEach(() => {
    vi.useFakeTimers({ now: Date.parse('2026-09-24T12:00:00.000Z') });
    vi.stubGlobal('localStorage', memoryStorage());
    vi.stubGlobal('sessionStorage', memoryStorage());
    seen = [];
    answer = () => Response.json({ messages: [], notifications: [], unread_count: 0, server_time: 'now' });
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string, init: RequestInit = {}) => {
        const request: Seen = {
          method: init.method ?? 'GET',
          url: new URL(url),
          headers: (init.headers ?? {}) as Record<string, string>,
          body: typeof init.body === 'string' ? (JSON.parse(init.body) as Record<string, unknown>) : {},
        };
        seen.push(request);
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
    sdk = start();
  });

  afterEach(() => {
    sdk.shutdown();
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  function start(): TreebarsWeb {
    const instance = new TreebarsWeb();
    instance.init({
      writeKey: 'pk_live_signed',
      backendUrl: 'https://ingest.test',
      autoPageViews: false,
      autoLifecycle: false,
      autoSessions: false,
      flushIntervalMs: 60 * 60 * 1000,
    });
    return instance;
  }

  /** One of each content route, in the order a page makes them. */
  async function readEverything(instance: TreebarsWeb): Promise<Seen[]> {
    seen = [];
    await instance.syncInAppMessages();
    await instance.notifications.list();
    await instance.notifications.markRead('group-1');
    return seen.filter((each) => each.url.pathname !== '/v1/events' && each.url.pathname !== '/v1/identify');
  }

  it('rides on every content read, as a header and never in the URL', async () => {
    sdk.identify('user_42', {}, SIGNATURE);
    const reads = await readEverything(sdk);

    expect(reads.map((each) => `${each.method} ${each.url.pathname}`)).toEqual([
      'GET /v1/in-app',
      'GET /v1/notifications',
      'POST /v1/notifications/state',
    ]);
    for (const read of reads) {
      expect(read.headers[HEADERS.userSignature], read.url.pathname).toBe(SIGNATURE);
      expect(read.url.search).not.toContain(SIGNATURE);
      // The account id too: a URL is what every proxy and access log keeps.
      expect(read.headers[HEADERS.userId], read.url.pathname).toBe('user_42');
      expect(read.url.search, read.url.pathname).not.toContain('user_42');
      // No `v` field, in the query or in the body.
      expect(read.url.searchParams.has('v'), read.url.pathname).toBe(false);
      expect(read.body.v, read.url.pathname).toBeUndefined();
    }
    expect(reads[2]!.body.user_id).toBe('user_42');
  });

  it('is percent-encoded, so an account id no header can carry raw still reaches the server', async () => {
    sdk.identify('José 用户+42@x', {}, SIGNATURE);
    const reads = await readEverything(sdk);

    expect(reads).toHaveLength(3);
    for (const read of reads) {
      expect(read.headers[HEADERS.userId], read.url.pathname).toBe('Jos%C3%A9%20%E7%94%A8%E6%88%B7%2B42%40x');
      // What a browser does with a header value: refuses one that is not Latin-1, and the read with it.
      expect(() => new Headers(read.headers), read.url.pathname).not.toThrow();
    }
    // The state write's body is JSON, which carries any string as itself.
    expect(reads[2]!.body.user_id).toBe('José 用户+42@x');
  });

  it('rides on the sign-in itself, which a live environment refuses without it', async () => {
    sdk.identify('user_42', { plan: 'pro' }, SIGNATURE);
    await vi.advanceTimersByTimeAsync(0);
    const signIn = seen.find((each) => each.url.pathname === '/v1/identify');
    expect(signIn?.headers[HEADERS.userSignature]).toBe(SIGNATURE);
    expect(signIn?.body).toMatchObject({ user_id: 'user_42' });
    expect(JSON.stringify(signIn?.body)).not.toContain(SIGNATURE);
  });

  /*
   * The signature says who; this says where. Every sign-in and upload presents the one device secret
   * this browser holds, so all of its requests prove the same device — with storage off too, where the
   * secret is held in memory and is still the same for every request.
   */
  it.each([true, false])('proves the device on the sign-in and on uploads, with one secret (storage %s)', async (persist) => {
    sdk.shutdown();
    localStorage.clear();
    seen = [];
    sdk = new TreebarsWeb();
    sdk.init({
      writeKey: 'pk_live_signed',
      backendUrl: 'https://ingest.test',
      autoPageViews: false,
      autoLifecycle: false,
      autoSessions: false,
      flushIntervalMs: 60 * 60 * 1000,
      disableStorage: !persist,
    });
    sdk.identify('user_42', {}, SIGNATURE);
    await vi.advanceTimersByTimeAsync(0);
    await sdk.flush();
    // Before the reads, which start their own record.
    const sent = [...seen];
    const reads = await readEverything(sdk);

    const secret = sent.find((each) => each.url.pathname === '/v1/identify')?.headers[HEADERS.deviceAuth];
    expect(secret).toMatch(/^[0-9a-f]{64}$/);
    const uploads = sent.filter((each) => each.url.pathname === '/v1/events');
    expect(uploads.length).toBeGreaterThan(0);
    for (const request of [...uploads, ...reads]) {
      expect(request.headers[HEADERS.deviceAuth], request.url.pathname).toBe(secret);
      expect(request.url.search).not.toContain(secret);
    }
    // The one the device claims: `device_context` carries it on a first report, which needs storage.
    if (persist) {
      expect(localStorage.getItem(STORAGE_KEYS.fetchSecret)).toBe(secret);
      const claim = uploads
        .flatMap((each) => (each.body.events ?? []) as { event_name: string; properties?: Record<string, unknown> }[])
        .find((event) => event.event_name === 'device_context');
      expect(claim?.properties?.fetch_secret).toBe(secret);
    }
  });

  it('says once, out loud, when the environment refused an unsigned sign-in', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => undefined);
    answer = (request) =>
      request.url.pathname === '/v1/identify'
        ? Response.json({ error: 'signature_required', message: 'sign it' }, { status: 403 })
        : Response.json({ messages: [], notifications: [], unread_count: 0, server_time: 'now' });
    sdk.identify('user_42');
    sdk.identify('user_43');
    await vi.advanceTimersByTimeAsync(0);

    const told = warn.mock.calls.filter((call) => String(call[0]).includes('signed identity'));
    expect(told).toHaveLength(1);
    expect(String(told[0]![0])).toContain('sign-ins are not recorded');
  });

  it('comes back after a reload with the account it names', async () => {
    sdk.identify('user_42', {}, SIGNATURE);
    sdk.shutdown();

    sdk = start();
    const [inApp] = await readEverything(sdk);
    expect(inApp!.headers[HEADERS.userId]).toBe('user_42');
    expect(inApp!.headers[HEADERS.userSignature]).toBe(SIGNATURE);
  });

  it('is kept when the same person is identified again without one, and dropped for anybody else', async () => {
    sdk.identify('user_42', {}, SIGNATURE);
    sdk.identify('user_42', { plan: 'pro' });
    expect((await readEverything(sdk))[0]!.headers[HEADERS.userSignature]).toBe(SIGNATURE);
    expect(localStorage.getItem(STORAGE_KEYS.signedInUserSignature)).toBe(SIGNATURE);

    // A signature is a claim about one account; handing it to the next would be sending a wrong one.
    sdk.identify('user_43');
    expect((await readEverything(sdk))[0]!.headers[HEADERS.userSignature]).toBeUndefined();
    expect(localStorage.getItem(STORAGE_KEYS.signedInUserSignature)).toBeNull();
  });

  it('leaves with the person on reset(), here and on the next load', async () => {
    sdk.identify('user_42', {}, SIGNATURE);
    sdk.reset();
    for (const read of await readEverything(sdk)) {
      expect(read.headers[HEADERS.userSignature], read.url.pathname).toBeUndefined();
    }
    expect(localStorage.getItem(STORAGE_KEYS.signedInUserSignature)).toBeNull();

    sdk.shutdown();
    sdk = start();
    expect((await readEverything(sdk))[0]!.headers[HEADERS.userSignature]).toBeUndefined();
  });

  it('says once, out loud, when the environment wants one and the page sent none', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => undefined);
    answer = () =>
      Response.json({ messages: [], notifications: [], unread_count: 0, signature_required: true, server_time: 'now' });
    sdk.identify('user_42');
    await readEverything(sdk);
    await readEverything(sdk);

    const told = warn.mock.calls.filter((call) => String(call[0]).includes('signed identity'));
    expect(told).toHaveLength(1);
    expect(String(told[0]![0])).toContain('identify(userId, attributes, signature)');
  });

  it('reports no read the server refused to record', async () => {
    vi.spyOn(console, 'warn').mockImplementation(() => undefined);
    answer = () => Response.json({ unread_count: 0, signature_required: true, server_time: 'now' });
    sdk.identify('user_42');
    await sdk.notifications.markRead('group-1');
    await sdk.flush();

    const reported = seen
      .filter((each) => each.url.pathname === '/v1/events')
      .flatMap((each) => (each.body.events as Array<{ event_name: string }> | undefined) ?? [])
      .map((each) => each.event_name);
    expect(reported).not.toContain('notification_read');
  });

  /*
   * The notification history is the person's too. `list()` answers from the cached first page when the server cannot,
   * and that page is handed over without asking whose it is — so it is gone the moment somebody else is signed in or
   * the person signs out, and stays gone on the next load.
   */
  describe('the cached notifications', () => {
    const row = (groupId: string) => ({
      group_id: groupId,
      campaign_id: null,
      channel_type: 'push',
      device_count: 1,
      content: { title: groupId },
      created_at: '2026-09-24T11:00:00.000Z',
      read_at: null,
      opened_at: null,
      expires_at: null,
    });
    const held = async (instance: TreebarsWeb) => (await instance.notifications.list()).notifications.map((each) => each.group_id);

    beforeEach(async () => {
      vi.spyOn(console, 'warn').mockImplementation(() => undefined);
      sdk.identify('user_42');
      answer = () => Response.json({ messages: [], notifications: [row('for-42')], unread_count: 1, server_time: 'now' });
      expect(await held(sdk)).toEqual(['for-42']);
      // From here the server cannot answer, so every list is what this browser kept.
      answer = () => new Response('', { status: 503 });
    });

    it('stay for the same person identified again', async () => {
      sdk.identify('user_42', { plan: 'pro' });
      expect(await held(sdk)).toEqual(['for-42']);
    });

    it('are gone when somebody else signs in with no sign-out between, here and on the next load', async () => {
      const told: NotificationPage[] = [];
      sdk.notifications.onChange((page) => told.push(page));
      sdk.identify('user_43');
      expect(told[told.length - 1]).toEqual({ notifications: [], unreadCount: 0, nextCursor: null, fromCache: true });
      expect(await held(sdk)).toEqual([]);

      sdk.shutdown();
      sdk = start();
      expect(await held(sdk)).toEqual([]);
    });

    it('are gone after reset(), here and on the next load', async () => {
      sdk.reset();
      expect(await held(sdk)).toEqual([]);

      sdk.shutdown();
      sdk = start();
      expect(await held(sdk)).toEqual([]);
    });
  });
});
