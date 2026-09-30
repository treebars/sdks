import { gunzipSync } from 'node:zlib';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { STORAGE_KEYS } from '../src/generated/constants';
import type { InAppStore } from '../src/in-app';
import { TreebarsWeb } from '../src/index';
import { claimStoredData } from '../src/storage';

/**
 * A site that changes its write key. What the previous key left in the browser — its unsent events, the session a
 * `session_end` is owed for, the in-app messages it fetched — belongs to the previous project, so it is dropped on the
 * first load under the new key, before anything there can send, close or draw it.
 */

/** Storage as the Web Storage API has it, `key()` and `length` included — the claim walks it. */
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

const NOW = Date.parse('2026-09-25T12:00:00.000Z');
const HOUR = 60 * 60 * 1000;

describe('a changed write key', () => {
  let local: ReturnType<typeof webStorage>;
  let session: ReturnType<typeof webStorage>;
  let sent: Array<{ key: string; events: Array<{ event_id: string; event_name: string; session_id?: string }> }>;
  let sdk: TreebarsWeb | null;

  beforeEach(() => {
    // Only the clock: a batch is gzipped through a stream, which a faked timer queue never lets finish.
    vi.useFakeTimers({ now: NOW, toFake: ['Date'] });
    local = webStorage();
    session = webStorage();
    sent = [];
    sdk = null;
    vi.stubGlobal('localStorage', local);
    vi.stubGlobal('sessionStorage', session);
    vi.stubGlobal('navigator', { userAgent: 'vitest', language: 'en-GB', sendBeacon: () => true });
    vi.stubGlobal('document', Object.assign(new EventTarget(), { visibilityState: 'visible', title: 'Shop', referrer: '', cookie: '' }));
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
      vi.fn(async (url: string, init: RequestInit = {}) => {
        if (new URL(url).pathname === '/v1/events') {
          const headers = (init.headers ?? {}) as Record<string, string>;
          const text = headers['Content-Encoding'] === 'gzip' ? gunzipSync(Buffer.from(init.body as ArrayBuffer)).toString('utf8') : String(init.body);
          const key = Object.entries(headers).find(([name]) => name.toLowerCase().includes('key'))?.[1] ?? '';
          sent.push({ key, events: (JSON.parse(text) as { events: never[] }).events });
          return Response.json({ accepted: 1 });
        }
        // Never answers: the in-app sync that would replace the stored queue has not come back yet.
        if (new URL(url).pathname.startsWith('/v1/in-app')) return new Promise<Response>(() => {});
        return Response.json({ accepted: 1, messages: [], notifications: [], unread_count: 0, server_time: 'now' });
      }),
    );
    // What the previous key's visit left: a session that has since aged out, two unsent events and one in-app message.
    local.setItem('treebars.write_key.v1', 'pk_live_before');
    local.setItem(STORAGE_KEYS.device, 'device-1');
    local.setItem(
      STORAGE_KEYS.queue,
      JSON.stringify([
        { event_id: 'old-1', event_name: 'viewed', device_id: 'device-1', session_id: 'old-session', timestamp: '2026-09-25T09:00:00.000Z', properties: {} },
        { event_id: 'old-2', event_name: 'bought', device_id: 'device-1', session_id: 'old-session', timestamp: '2026-09-25T09:01:00.000Z', properties: {} },
      ]),
    );
    local.setItem(
      STORAGE_KEYS.inApp,
      JSON.stringify([{ delivery_id: 'd-old', campaign_id: 'c-old', content: { in_app: { surface: 'overlay', layout: 'modal', trigger: { kind: 'immediate' } } }, created_at: '2026-09-25T09:00:00.000Z', expires_at: null }]),
    );
    session.setItem(STORAGE_KEYS.session, JSON.stringify({ id: 'old-session', lastActivity: NOW - 3 * HOUR, startedAt: NOW - 4 * HOUR, eventCount: 4 }));
  });

  afterEach(() => {
    sdk?.shutdown();
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  function start(writeKey: string): TreebarsWeb {
    sdk = new TreebarsWeb();
    sdk.init({ writeKey, backendUrl: 'https://ingest.test', autoPageViews: false, flushIntervalMs: HOUR });
    return sdk;
  }

  /**
   * Until `landed` — tracked after everything a load queues by itself — has reached the server. The load's own flush
   * runs first, and a second flush returns at once while one is running, so this asks again until it lands.
   */
  async function settle(instance: TreebarsWeb): Promise<void> {
    await vi.waitFor(
      async () => {
        await instance.flush();
        expect(sent.flatMap((batch) => batch.events).map((event) => event.event_name)).toContain('landed');
      },
      { timeout: 3000, interval: 20 },
    );
  }

  const inAppOf = (instance: TreebarsWeb) => (instance as unknown as { inApp: InAppStore }).inApp;

  it('drops what the previous key left, before anything is sent, closed or drawn under the new one', async () => {
    const instance = start('pk_live_after');
    // Before any answer: the stored message is not there to be drawn or reported.
    expect(inAppOf(instance).list()).toEqual([]);
    instance.track('landed');
    await settle(instance);

    const events = sent.flatMap((batch) => batch.events);
    expect(events.map((event) => event.event_id)).not.toContain('old-1');
    expect(events.map((event) => event.event_id)).not.toContain('old-2');
    // The previous key's session is not closed into this project.
    expect(events.filter((event) => event.event_name === 'session_end')).toEqual([]);
    expect(events.map((event) => event.event_name)).toContain('landed');
    expect(local.getItem('treebars.write_key.v1')).toBe('pk_live_after');
    // The device is still this browser: the id moves across, and so does its secret.
    expect(events.every((event) => (event as { device_id?: string }).device_id === 'device-1')).toBe(true);
  });

  it('keeps all of it under the same key: the unsent events go, and the aged-out session is closed', async () => {
    const instance = start('pk_live_before');
    expect(inAppOf(instance).list().map((message) => message.delivery_id)).toEqual(['d-old']);
    instance.track('landed');
    await settle(instance);

    const events = sent.flatMap((batch) => batch.events);
    expect(events.map((event) => event.event_id)).toEqual(expect.arrayContaining(['old-1', 'old-2']));
    expect(events.filter((event) => event.event_name === 'session_end').map((event) => event.session_id)).toEqual(['old-session']);
  });

  it('adopts the key of a browser that has no stamp yet, and drops nothing', () => {
    local.removeItem('treebars.write_key.v1');
    expect(claimStoredData('pk_live_after')).toBe(false);
    expect(local.getItem(STORAGE_KEYS.queue)).not.toBeNull();
    expect(local.getItem('treebars.write_key.v1')).toBe('pk_live_after');
  });

  it('keeps what belongs to the browser or the person rather than the project', () => {
    for (const key of [STORAGE_KEYS.fetchSecret, STORAGE_KEYS.signedInUser, STORAGE_KEYS.identifiedUser, 'treebars.opted_out.v1', 'treebars.session_ever_started.v1']) {
      local.setItem(key, 'kept');
    }
    for (const key of [STORAGE_KEYS.uploader, STORAGE_KEYS.triggers, STORAGE_KEYS.deviceContext, STORAGE_KEYS.notifications, 'treebars.experiences.v1', 'treebars.some_future_store.v1']) {
      local.setItem(key, 'dropped');
    }
    expect(claimStoredData('pk_live_after')).toBe(true);
    expect([...local.map.keys()].sort()).toEqual(
      [STORAGE_KEYS.device, STORAGE_KEYS.fetchSecret, STORAGE_KEYS.signedInUser, STORAGE_KEYS.identifiedUser, 'treebars.opted_out.v1', 'treebars.session_ever_started.v1', 'treebars.write_key.v1'].sort(),
    );
    expect(session.getItem(STORAGE_KEYS.session)).toBeNull();
  });
});
