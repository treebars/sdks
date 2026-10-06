import { gunzipSync } from 'node:zlib';

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import {
  DEFAULT_FLUSH_INTERVAL_MS,
  FLUSH_DEBOUNCE_MS,
  FLUSH_SPACING_MIN_MS,
  FLUSH_SPACING_MS,
  FLUSH_SPACING_TEST_MS,
  HEADERS,
  STORAGE_KEYS,
} from '../src/generated/constants';
import { TreebarsWeb } from '../src/index';
import type { TreebarsWebConfig } from '../src/types';

/**
 * The half of the pace the shared scenarios cannot reach: what `TreebarsWeb` does with real timers,
 * a real `fetch` and a page. The scenarios pin when an upload is due; these pin that the browser
 * glue feeds the pace what it needs — every queued event, every upload that begins, the spacing
 * off the response header and out of storage on the next page load, what the browser says about
 * saving data — and that the network coming back sends what was waiting.
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

interface Upload {
  /** Milliseconds after the test began. */
  at: number;
  batchId: string;
  events: string[];
}

const START = Date.parse('2026-09-15T12:00:00.000Z');

describe('the browser glue around the pace', () => {
  let uploads: Upload[];
  /** What the next upload is answered with. Stays until a test changes it. */
  let answer: () => Response;
  let page: EventTarget & { visibilityState: string; title: string; referrer: string };
  let connection: { saveData?: boolean } | undefined;
  let sdk: TreebarsWeb;

  beforeEach(() => {
    vi.useFakeTimers({ now: START });
    vi.stubGlobal('localStorage', memoryStorage());
    vi.stubGlobal('sessionStorage', memoryStorage());
    uploads = [];
    answer = () => new Response('{}', { status: 200 });
    connection = undefined;

    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string, init: RequestInit = {}) => {
        if (new URL(url).pathname !== '/v1/events') return Response.json({ server_time: 'now' });
        const headers = (init.headers ?? {}) as Record<string, string>;
        const text =
          headers['Content-Encoding'] === 'gzip'
            ? gunzipSync(Buffer.from(init.body as ArrayBuffer)).toString('utf8')
            : String(init.body);
        const body = JSON.parse(text) as { batch_id: string; events: Array<{ event_name: string }> };
        uploads.push({ at: Date.now() - START, batchId: body.batch_id, events: body.events.map((each) => each.event_name) });
        return answer();
      }),
    );
    vi.stubGlobal('navigator', {
      userAgent: 'vitest',
      language: 'en-GB',
      get connection() {
        return connection;
      },
    });
    page = Object.assign(new EventTarget(), { visibilityState: 'visible', title: 'Test', referrer: '' });
    vi.stubGlobal('document', page);
    vi.stubGlobal(
      'window',
      Object.assign(new EventTarget(), {
        screen: { width: 1280, height: 800 },
        devicePixelRatio: 1,
        location: { pathname: '/', hostname: 'shop.test', href: 'https://shop.test/', origin: 'https://shop.test' },
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

  /**
   * Starts the SDK and lets `init`'s own upload — the device context — go out and be answered, so
   * every test begins from the same place: one upload, begun at zero, and an empty queue.
   */
  const start = async (config: Partial<TreebarsWebConfig> = {}) => {
    sdk.init({
      writeKey: 'pk_live_pace',
      backendUrl: 'https://ingest.test',
      inAppEnabled: false,
      autoPageViews: false,
      autoLifecycle: false,
      autoSessions: false,
      ...config,
    });
    await vi.advanceTimersByTimeAsync(0);
    expect(uploads.map((each) => ({ at: each.at, events: each.events }))).toEqual([{ at: 0, events: ['device_context'] }]);
  };

  /** What was uploaded since `start`, as `[milliseconds after the test began, the events]`. */
  const since = () => uploads.slice(1).map((each) => [each.at, each.events] as const);

  /**
   * Lets the page go quiet after `start`. The device context armed an upload, and the one that
   * carried it pushed that out by a spacing; it falls due here, finds nothing queued and sends
   * nothing.
   */
  const settle = async () => {
    await vi.advanceTimersByTimeAsync(FLUSH_SPACING_MS);
    expect(since()).toEqual([]);
  };

  it('uploads an event a second after it is logged on a quiet page, and holds a busy one to the spacing', async () => {
    await start();
    await settle();

    sdk.track('viewed');
    // A burst inside the second is one upload, and does not move the wait.
    await vi.advanceTimersByTimeAsync(FLUSH_DEBOUNCE_MS - 100);
    sdk.track('added');
    await vi.advanceTimersByTimeAsync(99);
    expect(since()).toEqual([]);
    await vi.advanceTimersByTimeAsync(1);
    const first = FLUSH_SPACING_MS + FLUSH_DEBOUNCE_MS;
    expect(since()).toEqual([[first, ['viewed', 'added']]]);

    // Busy now: the next one waits for the spacing to pass since that upload began.
    sdk.track('bought');
    await vi.advanceTimersByTimeAsync(FLUSH_SPACING_MS - 1);
    expect(since()).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(since()).toEqual([
      [first, ['viewed', 'added']],
      [first + FLUSH_SPACING_MS, ['bought']],
    ]);
  });

  it('keeps no timer running on a page with nothing to send', async () => {
    await start();
    await settle();
    expect(vi.getTimerCount()).toBe(0);

    sdk.track('viewed');
    expect(vi.getTimerCount()).toBe(1);
    await vi.advanceTimersByTimeAsync(FLUSH_DEBOUNCE_MS);
    expect(since()).toEqual([[FLUSH_SPACING_MS + FLUSH_DEBOUNCE_MS, ['viewed']]]);
    expect(vi.getTimerCount()).toBe(0);

    // And nothing wakes on its own, however long the page stays open.
    await vi.advanceTimersByTimeAsync(60 * 60 * 1000);
    expect(since()).toHaveLength(1);
  });

  it('takes the spacing an accepted upload names off the header, and starts the next page load with it', async () => {
    const named = FLUSH_SPACING_MIN_MS * 2;
    answer = () => new Response('{}', { status: 200, headers: { [HEADERS.flushSpacing]: String(named) } });
    await start();
    expect(JSON.parse(localStorage.getItem(STORAGE_KEYS.uploader)!)).toMatchObject({ flush_spacing_ms: named });
    await settle();

    sdk.track('viewed');
    await vi.advanceTimersByTimeAsync(FLUSH_DEBOUNCE_MS);
    const first = FLUSH_SPACING_MS + FLUSH_DEBOUNCE_MS;
    expect(since()).toEqual([[first, ['viewed']]]);
    // Busy now, and held to what the server named rather than to the default.
    sdk.track('bought');
    await vi.advanceTimersByTimeAsync(named - 1);
    expect(since()).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(since()).toEqual([
      [first, ['viewed']],
      [first + named, ['bought']],
    ]);

    // A new page load over the same storage, whose own first upload names nothing.
    sdk.shutdown();
    answer = () => new Response('{}', { status: 200 });
    sdk = new TreebarsWeb();
    sdk.init({ writeKey: 'pk_live_pace', backendUrl: 'https://ingest.test', inAppEnabled: false, autoPageViews: false, autoLifecycle: false, autoSessions: false });
    // `init`'s own flush finds nothing to send, and is let finish: a flush called while it runs is turned away.
    await vi.advanceTimersByTimeAsync(0);
    sdk.track('reloaded');
    await sdk.flush();
    const began = Date.now() - START;
    sdk.track('viewed_again');
    await vi.advanceTimersByTimeAsync(named - 1);
    expect(uploads.at(-1)!.events).toEqual(['reloaded']);
    await vi.advanceTimersByTimeAsync(1);
    expect(uploads.at(-1)).toMatchObject({ at: began + named, events: ['viewed_again'] });
  });

  it('keeps a second under a test key, where somebody is watching for the event', async () => {
    await start({ writeKey: 'pk_test_pace' });
    sdk.track('viewed');
    await vi.advanceTimersByTimeAsync(FLUSH_SPACING_TEST_MS - 1);
    expect(since()).toEqual([]);
    await vi.advanceTimersByTimeAsync(1);
    expect(since()).toEqual([[FLUSH_SPACING_TEST_MS, ['viewed']]]);
  });

  it('reads `flushIntervalMs` as the least time between uploads, not as a timer', async () => {
    const chosen = 4 * FLUSH_SPACING_MS;
    await start({ flushIntervalMs: chosen });

    sdk.track('viewed');
    await vi.advanceTimersByTimeAsync(chosen - 1);
    expect(since()).toEqual([]);
    await vi.advanceTimersByTimeAsync(1);
    expect(since()).toEqual([[chosen, ['viewed']]]);

    // Quiet for longer than the interval: the next event is a second away, not an interval away.
    await vi.advanceTimersByTimeAsync(chosen);
    sdk.track('bought');
    await vi.advanceTimersByTimeAsync(FLUSH_DEBOUNCE_MS);
    expect(since()).toEqual([
      [chosen, ['viewed']],
      [2 * chosen + FLUSH_DEBOUNCE_MS, ['bought']],
    ]);
  });

  it('sleeps no longer than a timer can when the page chose an interval past that, rather than firing at once', async () => {
    const timers = vi.spyOn(globalThis, 'setTimeout');
    await start({ flushIntervalMs: Number.MAX_SAFE_INTEGER });
    sdk.track('viewed');
    await vi.advanceTimersByTimeAsync(60 * 60 * 1000);

    expect(since()).toEqual([]);
    // A browser fires a timer asked to sleep past this at once, which would be an upload per event.
    expect(timers).toHaveBeenCalled();
    for (const [, delay] of timers.mock.calls) expect(delay ?? 0).toBeLessThanOrEqual(2 ** 31 - 1);
    // An explicit flush is still the page's to call.
    await sdk.flush();
    expect(since()).toHaveLength(1);
  });

  it('keeps thirty seconds between uploads in a browser asked to save data, whatever else is true', async () => {
    connection = { saveData: true };
    await start({ writeKey: 'pk_test_pace', flushIntervalMs: FLUSH_SPACING_MS });

    sdk.track('viewed');
    await vi.advanceTimersByTimeAsync(DEFAULT_FLUSH_INTERVAL_MS - 1);
    expect(since()).toEqual([]);
    await vi.advanceTimersByTimeAsync(1);
    expect(since()).toEqual([[DEFAULT_FLUSH_INTERVAL_MS, ['viewed']]]);
  });

  it('reads the saving-data switch as each upload is armed, so turning it on is felt by the next one', async () => {
    await start();
    await settle();
    await vi.advanceTimersByTimeAsync(FLUSH_SPACING_MS);

    sdk.track('viewed');
    await vi.advanceTimersByTimeAsync(FLUSH_DEBOUNCE_MS);
    const first = 2 * FLUSH_SPACING_MS + FLUSH_DEBOUNCE_MS;
    expect(since()).toEqual([[first, ['viewed']]]);

    connection = { saveData: true };
    sdk.track('bought');
    await vi.advanceTimersByTimeAsync(DEFAULT_FLUSH_INTERVAL_MS - 1);
    expect(since()).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(since()).toEqual([
      [first, ['viewed']],
      [first + DEFAULT_FLUSH_INTERVAL_MS, ['bought']],
    ]);
  });

  it('counts the upload sent as the page is hidden, and sends that batch again only when the spacing allows', async () => {
    await start();
    await settle();

    sdk.track('viewed');
    await vi.advanceTimersByTimeAsync(100);
    page.visibilityState = 'hidden';
    page.dispatchEvent(new Event('visibilitychange'));
    const hidden = FLUSH_SPACING_MS + 100;
    expect(since()).toEqual([[hidden, ['viewed']]]);

    // Its answer is never read, so the batch is still pending — and the upload this event had armed
    // for a second after it is now due a spacing after the page-hide one began.
    await vi.advanceTimersByTimeAsync(FLUSH_SPACING_MS - 1);
    expect(since()).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(since()).toEqual([
      [hidden, ['viewed']],
      [hidden + FLUSH_SPACING_MS, ['viewed']],
    ]);
    expect(uploads.at(-1)!.batchId).toBe(uploads.at(-2)!.batchId);
  });

  it('carries a backlog on a spacing at a time, on a page that logs nothing', async () => {
    await start({ batchSize: 2 });
    await settle();
    sdk.shutdown();

    // What an earlier visit left unsent: more than one flush sends, at ten batches of two.
    const template = { session_id: 's0', device_id: 'dev_left', properties: {}, timestamp: '2026-09-15T11:00:00.000Z', sdk_version: '0.0.0', sdk_name: 'treebars-web', env: 'production', platform_type: 'web' };
    const left = Array.from({ length: 45 }, (_, index) => ({ ...template, event_id: `left_${index}`, event_name: `left_${index}` }));
    localStorage.setItem(STORAGE_KEYS.queue, JSON.stringify(left));

    sdk = new TreebarsWeb();
    sdk.init({ writeKey: 'pk_live_pace', backendUrl: 'https://ingest.test', batchSize: 2, inAppEnabled: false, autoPageViews: false, autoLifecycle: false, autoSessions: false });
    const began = Date.now() - START;
    await vi.advanceTimersByTimeAsync(0);
    const sentBy = (at: number) => uploads.slice(1).filter((each) => each.at <= at).flatMap((each) => each.events).length;
    expect(sentBy(began)).toBe(20);

    // No event is logged from here on. Each flush is ten batches, and the next follows a spacing after.
    await vi.advanceTimersByTimeAsync(FLUSH_SPACING_MS - 1);
    expect(sentBy(Infinity)).toBe(20);
    await vi.advanceTimersByTimeAsync(1);
    expect(sentBy(Infinity)).toBe(40);
    await vi.advanceTimersByTimeAsync(FLUSH_SPACING_MS);
    expect(uploads.slice(1).flatMap((each) => each.events)).toEqual(left.map((each) => each.event_name));

    // And with nothing left, nothing more is armed.
    expect(vi.getTimerCount()).toBe(0);
  });

  describe('when the network comes back', () => {
    const online = () => window.dispatchEvent(new Event('online'));

    it('sends what was waiting at once, without waiting out the spacing', async () => {
      await start();
      sdk.track('viewed');
      await vi.advanceTimersByTimeAsync(100);
      expect(since()).toEqual([]);

      online();
      await vi.advanceTimersByTimeAsync(0);
      expect(since()).toEqual([[100, ['viewed']]]);
    });

    it('sends a batch an earlier failure left pending, with nothing new on the queue', async () => {
      // No answer at all, as offline: the batch stays pending, behind a backoff of exactly a second.
      vi.spyOn(Math, 'random').mockReturnValue(0.5);
      answer = () => {
        throw new TypeError('Failed to fetch');
      };
      sdk.init({ writeKey: 'pk_live_pace', backendUrl: 'https://ingest.test', inAppEnabled: false, autoPageViews: false, autoLifecycle: false, autoSessions: false });
      await vi.advanceTimersByTimeAsync(0);
      expect(uploads).toHaveLength(1);
      const gate = (JSON.parse(localStorage.getItem(STORAGE_KEYS.uploader)!) as { next_allowed_at: number }).next_allowed_at;
      expect(gate).toBe(START + 1000);

      // Still inside the backoff, the network coming back sends nothing: the gate decides.
      answer = () => new Response('{}', { status: 200 });
      online();
      await vi.advanceTimersByTimeAsync(0);
      expect(uploads).toHaveLength(1);

      // Moved without running timers, so the retry armed for this moment is not what sends it.
      vi.setSystemTime(gate);
      online();
      await vi.advanceTimersByTimeAsync(0);
      expect(uploads).toHaveLength(2);
      expect(uploads[1]!.batchId).toBe(uploads[0]!.batchId);
    });

    it('asks for nothing when nothing is waiting', async () => {
      await start();
      online();
      await vi.advanceTimersByTimeAsync(0);
      expect(since()).toEqual([]);
    });

    it('leaves a closed gate closed: the server said when to come back', async () => {
      answer = () => new Response(null, { status: 503, headers: { 'Retry-After': '30' } });
      sdk.init({ writeKey: 'pk_live_pace', backendUrl: 'https://ingest.test', inAppEnabled: false, autoPageViews: false, autoLifecycle: false, autoSessions: false });
      await vi.advanceTimersByTimeAsync(0);
      expect(uploads).toHaveLength(1);

      const timers = vi.spyOn(globalThis, 'setTimeout');
      online();
      await vi.advanceTimersByTimeAsync(29_999);
      expect(uploads).toHaveLength(1);
      // And nothing keeps waking to ask: the batch waits on the one wake armed for when the gate opens.
      expect(timers).not.toHaveBeenCalled();

      answer = () => new Response('{}', { status: 200 });
      await vi.advanceTimersByTimeAsync(1);
      expect(uploads).toHaveLength(2);
    });

    it('stops listening at shutdown', async () => {
      const added = vi.spyOn(window, 'addEventListener');
      const removed = vi.spyOn(window, 'removeEventListener');
      await start();
      const listener = added.mock.calls.find(([type]) => type === 'online')?.[1];
      expect(listener).toBeTypeOf('function');

      // With an upload armed, so there is a timer for shutdown to stop as well.
      sdk.track('viewed');
      expect(vi.getTimerCount()).toBe(1);
      sdk.shutdown();
      expect(removed).toHaveBeenCalledWith('online', listener);
      expect(vi.getTimerCount()).toBe(0);
    });
  });
});
