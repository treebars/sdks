import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { SHARED_BROWSER_COOKIE } from '../src/acquisition';
import { STORAGE_KEYS } from '../src/generated/constants';
import { TreebarsWeb } from '../src/index';

/**
 * A person's two controls over what the SDK does in their browser: stop (`optOut`), and forget
 * (`wipeLocalData`). Neither is `reset()`, which signs out and keeps the device id and its secret by
 * design: opting out stops the anonymous device being recorded as well, and a wipe replaces the
 * browser's id and secret, so nothing left behind can be matched to the person again.
 */

/** Storage as the Web Storage API has it, `key()` and `length` included — the wipe walks it. */
function webStorage() {
  const map = new Map<string, string>();
  return {
    map,
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

describe('opting out, and wiping what the SDK kept', () => {
  let local: ReturnType<typeof webStorage>;
  let session: ReturnType<typeof webStorage>;
  let cookies: string[];
  let requests: string[];
  let sdk: TreebarsWeb | null;

  beforeEach(() => {
    vi.useFakeTimers({ now: Date.parse('2026-09-25T12:00:00.000Z') });
    local = webStorage();
    session = webStorage();
    cookies = [];
    requests = [];
    sdk = null;
    vi.stubGlobal('localStorage', local);
    vi.stubGlobal('sessionStorage', session);
    vi.stubGlobal('navigator', { userAgent: 'vitest', language: 'en-GB', sendBeacon: () => true });
    const document = Object.assign(new EventTarget(), { visibilityState: 'visible', title: 'Shop', referrer: '' });
    Object.defineProperty(document, 'cookie', {
      get: () => cookies.join('; '),
      set: (value: string) => void cookies.push(value),
    });
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
      vi.fn(async (url: string) => {
        requests.push(new URL(url).pathname);
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

  function start(): TreebarsWeb {
    sdk = new TreebarsWeb();
    sdk.init({ writeKey: 'pk_live_optout', backendUrl: 'https://ingest.test', autoPageViews: false, flushIntervalMs: 60 * 60 * 1000 });
    return sdk;
  }

  it('records and sends nothing once a person opts out, and drops what was waiting', async () => {
    const instance = start();
    await vi.runOnlyPendingTimersAsync();
    instance.track('viewed', { sku: 'A1' });
    instance.optOut();
    requests = [];

    instance.track('bought', { sku: 'A1' });
    instance.identify('user_42', { plan: 'pro' });
    await instance.flush();
    await instance.syncInAppMessages();
    await instance.notifications.list();

    expect(requests).toEqual([]);
    expect(JSON.parse(local.getItem(STORAGE_KEYS.queue) ?? '[]')).toEqual([]);
    expect(instance.isOptedOut()).toBe(true);
  });

  it('stays opted out on the next visit, which writes nothing into the browser', () => {
    start().optOut();
    sdk!.shutdown();
    local.map.delete(STORAGE_KEYS.device);
    local.map.delete(STORAGE_KEYS.fetchSecret);

    const next = start();
    expect(next.isOptedOut()).toBe(true);
    // No device id and no secret minted for a person who said no.
    expect(local.getItem(STORAGE_KEYS.device)).toBeNull();
    expect(local.getItem(STORAGE_KEYS.fetchSecret)).toBeNull();
  });

  it('can be answered before init, as a consent prompt answers first', () => {
    sdk = new TreebarsWeb();
    sdk.optOut();
    sdk.init({ writeKey: 'pk_live_optout', backendUrl: 'https://ingest.test', autoPageViews: false });
    expect(sdk.isOptedOut()).toBe(true);
    expect(local.getItem(STORAGE_KEYS.device)).toBeNull();
  });

  it('drops what an earlier visit left unsent when a page starts opted out', async () => {
    // A visit that queued and sealed events, and closed before they went.
    local.setItem(STORAGE_KEYS.queue, JSON.stringify([{ event_id: 'e1', event_name: 'viewed' }]));
    local.setItem(
      STORAGE_KEYS.uploader,
      JSON.stringify({ pending: [{ batch_id: 'b1', sent_at: '2026-09-24T12:00:00.000Z', events: [{ event_id: 'e0' }] }] }),
    );
    sdk = new TreebarsWeb();
    sdk.optOut();
    sdk.init({ writeKey: 'pk_live_optout', backendUrl: 'https://ingest.test', autoPageViews: false });
    await vi.runOnlyPendingTimersAsync();

    expect(requests).toEqual([]);
    // Gone, so a later opt-in cannot send events recorded before the "no".
    expect(local.getItem(STORAGE_KEYS.queue)).toBeNull();
    expect(local.getItem(STORAGE_KEYS.uploader)).toBeNull();
  });

  it('stores an answer given before init only where the page allows storage', () => {
    sdk = new TreebarsWeb();
    sdk.optOut();
    sdk.init({ writeKey: 'pk_live_optout', backendUrl: 'https://ingest.test', autoPageViews: false, disableStorage: true });

    expect(sdk.isOptedOut()).toBe(true);
    expect([...local.map.keys(), ...session.map.keys()].filter((key) => key.startsWith('treebars.'))).toEqual([]);
  });

  it('takes an opt-in given before init over the opt-out an earlier visit stored', async () => {
    start().optOut();
    sdk!.shutdown();

    sdk = new TreebarsWeb();
    sdk.optIn();
    sdk.init({ writeKey: 'pk_live_optout', backendUrl: 'https://ingest.test', autoPageViews: false, flushIntervalMs: 60 * 60 * 1000 });
    expect(sdk.isOptedOut()).toBe(false);
    expect(local.getItem('treebars.opted_out.v1')).toBeNull();

    await vi.runOnlyPendingTimersAsync();
    requests = [];
    const instance = sdk;
    instance.track('came_back');
    await vi.waitFor(async () => {
      await instance.flush();
      expect(requests).toContain('/v1/events');
    });
  });

  it('resumes recording after optIn', async () => {
    const instance = start();
    // Let the flush `init` starts finish, so the one below is not turned away as already running.
    await vi.runOnlyPendingTimersAsync();
    instance.optOut();
    instance.optIn();
    requests = [];
    instance.track('came_back');
    // Retried, because a flush the interval started may still be out and turns a second one away.
    await vi.waitFor(async () => {
      await instance.flush();
      expect(requests).toContain('/v1/events');
    });
    expect(instance.isOptedOut()).toBe(false);
  });

  it('wipes every key it kept and the browser cookie, and carries on as a browser it has never seen', () => {
    const instance = start();
    const firstDevice = local.getItem(STORAGE_KEYS.device);
    const firstSecret = local.getItem(STORAGE_KEYS.fetchSecret);
    expect(firstDevice).not.toBeNull();
    instance.identify('user_42');
    local.setItem('someone-else.key', 'kept');
    requests = [];

    instance.wipeLocalData();

    // Nothing sent on the way out: no sign-out event, no upload.
    expect(requests).toEqual([]);
    expect(local.getItem('someone-else.key')).toBe('kept');
    expect(local.getItem(STORAGE_KEYS.signedInUser)).toBeNull();
    expect(local.getItem(STORAGE_KEYS.identifiedUser)).toBeNull();
    // A new id and a new secret — together, never a new secret under the old id.
    expect(local.getItem(STORAGE_KEYS.device)).not.toBeNull();
    expect(local.getItem(STORAGE_KEYS.device)).not.toBe(firstDevice);
    expect(local.getItem(STORAGE_KEYS.fetchSecret)).not.toBe(firstSecret);
    // Expired on the registrable domain and host-only, wherever it was set.
    expect(cookies.filter((cookie) => cookie.startsWith(`${SHARED_BROWSER_COOKIE}=;`) && cookie.includes('Max-Age=0'))).not.toHaveLength(0);
  });

  it('keeps the opt-out through a wipe, and then writes nothing back', () => {
    const instance = start();
    instance.optOut();
    instance.wipeLocalData();

    const left = [...local.map.keys(), ...session.map.keys()].filter((key) => key.startsWith('treebars.'));
    expect(left).toEqual(['treebars.opted_out.v1']);
    expect(instance.isOptedOut()).toBe(true);
  });
});
