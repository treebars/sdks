import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { TreebarsWeb } from '../src/index';
import {
  EventStore,
  adoptStoredDevice,
  keepPendingBackground,
  takeLeftBackgrounds,
  takePendingBackground,
} from '../src/storage';
import { DEFAULT_EVENTS, type QueuedEvent, type TreebarsWebConfig } from '../src/types';

/**
 * A hide that does not last is not a background.
 *
 * A page is hidden and shown again for reasons that are not somebody leaving it — a glance at another tab, a window
 * passing over it, a browser panel covering and uncovering it — and recorded as it happens, each is an
 * `app_background` and an `app_foreground` milliseconds apart, with an upload to carry them. So a hide is watched
 * first: shown again within two seconds it records nothing, and one that lasts is recorded with the time it began.
 *
 * A hidden page can also be frozen or discarded before that wait ends, so what it is waiting to record is kept in
 * storage too, and recorded once by whichever gets there first: the wait ending, the page being left, the page being
 * shown again late, or the next `init` on the origin. These drive a page through each of those.
 */

/** How long a page has to stay hidden, as the SDK has it (`LIFECYCLE_BLIP_MS`). */
const BLIP_MS = 2_000;
const PENDING_KEY = 'treebars.pending_background.v1';
const START = Date.parse('2026-10-06T12:00:00.000Z');
const MINUTE = 60_000;
const BACKGROUND = DEFAULT_EVENTS.APP_BACKGROUND;
const FOREGROUND = DEFAULT_EVENTS.APP_FOREGROUND;

/** Storage as the Web Storage API has it, `key()` and `length` included — a wipe walks it. */
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

/** The moment `ms` after the test began, as an event's timestamp has it. */
const moment = (ms: number) => new Date(START + ms).toISOString();

describe('a hide that does not last is not a background', () => {
  /** Every event as it went onto the queue, in the order it was recorded. */
  let queued: QueuedEvent[];
  /** Every upload of events, as when it began — in milliseconds after the test began — and the names it carried. */
  let uploads: Array<{ at: number; events: string[] }>;
  let page: EventTarget & { visibilityState: string; title: string; referrer: string };
  let sdk: TreebarsWeb;

  beforeEach(() => {
    vi.useFakeTimers({ now: START });
    vi.stubGlobal('localStorage', webStorage());
    vi.stubGlobal('sessionStorage', webStorage());
    queued = [];
    uploads = [];
    const add = EventStore.prototype.add;
    vi.spyOn(EventStore.prototype, 'add').mockImplementation(function (this: EventStore, event: QueuedEvent) {
      queued.push(event);
      add.call(this, event);
    });

    // Never compressed, so an upload's body can be read as the text it is.
    vi.stubGlobal('CompressionStream', undefined);
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string, init: RequestInit = {}) => {
        if (new URL(url).pathname === '/v1/events') {
          const body = JSON.parse(String(init.body)) as { events: Array<{ event_name: string }> };
          uploads.push({ at: Date.now() - START, events: body.events.map((each) => each.event_name) });
        }
        return Response.json({ server_time: 'now' });
      }),
    );
    vi.stubGlobal('navigator', { userAgent: 'vitest', language: 'en-GB' });
    page = Object.assign(new EventTarget(), { visibilityState: 'visible', title: 'Test', referrer: '' });
    vi.stubGlobal('document', page);
    vi.stubGlobal(
      'window',
      Object.assign(new EventTarget(), {
        screen: { width: 1280, height: 800 },
        devicePixelRatio: 1,
        location: { pathname: '/', hostname: 'shop.example.com', href: 'https://shop.example.com/', origin: 'https://shop.example.com' },
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

  /** Starts the SDK and lets the upload `init` makes go out, so what a test sees uploaded is its own. */
  const start = async (config: Partial<TreebarsWebConfig> = {}) => {
    sdk.init({
      writeKey: 'pk_test_blip',
      backendUrl: 'https://ingest.test',
      inAppEnabled: false,
      autoPageViews: false,
      autoSessions: false,
      ...config,
    });
    await vi.advanceTimersByTimeAsync(0);
  };

  const turn = (visibility: 'hidden' | 'visible') => {
    page.visibilityState = visibility;
    page.dispatchEvent(new Event('visibilitychange'));
  };
  const hide = () => turn('hidden');
  const show = () => turn('visible');
  /** The page is being left: closed, or navigated away from. */
  const leave = () => window.dispatchEvent(new Event('pagehide'));

  /** Lets `ms` pass with the page's timers running, as on a page the browser leaves alone. */
  const pass = (ms: number) => vi.advanceTimersByTimeAsync(ms);
  /** Lets `ms` pass with no timer run: a page the browser froze while it was hidden. */
  const frozenFor = (ms: number) => vi.setSystemTime(Date.now() + ms);

  /**
   * The page is discarded as it stands — no timer of its runs again and no further event reaches it — and the same
   * tab loads it again `after` milliseconds later. Everything queued from here on is the new page load's.
   */
  const discardAndLoadAgain = async (after: number, config: Partial<TreebarsWebConfig> = {}) => {
    sdk.shutdown();
    vi.setSystemTime(Date.now() + after);
    queued = [];
    page.visibilityState = 'visible';
    sdk = new TreebarsWeb();
    await start(config);
  };

  /** The two events recorded so far: each one's name, its properties, and when it says it happened. */
  const transitions = () =>
    queued
      .filter((each) => each.event_name === BACKGROUND || each.event_name === FOREGROUND)
      .map((each) => ({ name: each.event_name, properties: each.properties, at: Date.parse(each.timestamp) - START }));

  const names = () => queued.map((each) => each.event_name);

  /** What storage holds for hidden pages: one entry each, while its `app_background` is still to be decided. */
  const kept = () => JSON.parse(localStorage.getItem(PENDING_KEY) ?? '[]') as Array<{ at: number; foregroundMs: number; session: string | null }>;

  const NAME = { name: 'shop.example.com' };

  describe('while the page lives', () => {
    it('records nothing for a page shown again within the wait, and sends nothing for it', async () => {
      await start();
      await pass(5_000);
      const sent = uploads.length;

      hide();
      expect(kept()).toHaveLength(1);
      await pass(BLIP_MS - 1);
      show();
      await pass(MINUTE);

      expect(transitions()).toEqual([]);
      expect(localStorage.getItem(PENDING_KEY)).toBeNull();
      expect(uploads).toHaveLength(sent);
    });

    it('records one `app_background` for a hide that lasts, stamped when the page was hidden, and sends it then', async () => {
      await start();
      await pass(4_000);

      hide();
      await pass(BLIP_MS - 1);
      expect(transitions()).toEqual([]);
      await pass(1);
      expect(transitions()).toEqual([{ name: BACKGROUND, properties: { foreground_ms: 4_000, ...NAME }, at: 4_000 }]);
      expect(localStorage.getItem(PENDING_KEY)).toBeNull();
      // From the wait's own timer, not with whatever the page next uploads — which, hidden, may be nothing.
      expect(uploads.find((each) => each.events.includes(BACKGROUND))).toEqual({ at: 4_000 + BLIP_MS, events: [BACKGROUND] });

      // Nine seconds hidden in all, and that is what the return says.
      await pass(7_000);
      show();
      expect(transitions()).toEqual([
        { name: BACKGROUND, properties: { foreground_ms: 4_000, ...NAME }, at: 4_000 },
        { name: FOREGROUND, properties: { background_ms: 9_000, ...NAME }, at: 13_000 },
      ]);
    });

    it('records nothing for blip after blip, and counts the time they took as time in the foreground', async () => {
      await start();
      await pass(1_000);
      for (let blip = 0; blip < 5; blip += 1) {
        hide();
        await pass(500);
        show();
        await pass(500);
      }
      expect(transitions()).toEqual([]);

      // Six seconds since the page loaded, half of them spent in hides that came to nothing.
      hide();
      await pass(BLIP_MS);
      expect(transitions()).toEqual([{ name: BACKGROUND, properties: { foreground_ms: 6_000, ...NAME }, at: 6_000 }]);
    });

    it('counts the next foreground from the return, once a hide did last', async () => {
      await start();
      await pass(1_000);
      hide();
      await pass(3_000);
      show();
      await pass(2_500);
      hide();
      await pass(BLIP_MS);

      expect(transitions()).toEqual([
        { name: BACKGROUND, properties: { foreground_ms: 1_000, ...NAME }, at: 1_000 },
        { name: FOREGROUND, properties: { background_ms: 3_000, ...NAME }, at: 4_000 },
        { name: BACKGROUND, properties: { foreground_ms: 2_500, ...NAME }, at: 6_500 },
      ]);
    });

    it('records a pending one at once when the page is left, and sends it with that upload', async () => {
      await start();
      await pass(3_000);
      hide();
      await pass(200);
      expect(transitions()).toEqual([]);
      const sent = uploads.length;

      leave();
      expect(transitions()).toEqual([{ name: BACKGROUND, properties: { foreground_ms: 3_000, ...NAME }, at: 3_000 }]);
      expect(uploads).toHaveLength(sent + 1);
      expect(uploads[uploads.length - 1]).toEqual({ at: 3_200, events: [BACKGROUND] });
      expect(localStorage.getItem(PENDING_KEY)).toBeNull();

      // The wait it no longer needed ends without a second one.
      await pass(BLIP_MS * 2);
      expect(transitions()).toHaveLength(1);
    });

    it('does not wait on a page that is hidden because it is being left', async () => {
      await start();
      await pass(3_000);

      // A page unloaded while visible is told it is leaving first and that it is hidden second.
      leave();
      hide();
      expect(transitions()).toEqual([{ name: BACKGROUND, properties: { foreground_ms: 3_000, ...NAME }, at: 3_000 }]);
      expect(uploads[uploads.length - 1]).toEqual({ at: 3_000, events: [BACKGROUND] });
      expect(localStorage.getItem(PENDING_KEY)).toBeNull();

      // Brought back out of the back-forward cache: a return like any other, and the next hide waits again.
      await pass(700);
      window.dispatchEvent(new Event('pageshow'));
      show();
      expect(transitions()[1]).toEqual({ name: FOREGROUND, properties: { background_ms: 700, ...NAME }, at: 3_700 });
      hide();
      expect(transitions()).toHaveLength(2);
      expect(kept()).toHaveLength(1);
    });

    it('waits again on the next hide once the page has been shown, told that it came back or not', async () => {
      await start();
      await pass(1_000);
      leave();
      hide();
      expect(transitions()).toHaveLength(1);

      // No `pageshow` this time: being shown is enough to say the page was not left after all.
      await pass(3_000);
      show();
      await pass(1_000);
      hide();
      await pass(BLIP_MS - 1);
      show();
      expect(transitions().map((each) => each.name)).toEqual([BACKGROUND, FOREGROUND]);
    });

    it('records the background on the way back, stamped at the hide, on a page whose timers never ran', async () => {
      await start();
      await pass(4_000);
      hide();
      frozenFor(9_000);
      expect(transitions()).toEqual([]);
      show();

      expect(transitions()).toEqual([
        { name: BACKGROUND, properties: { foreground_ms: 4_000, ...NAME }, at: 4_000 },
        { name: FOREGROUND, properties: { background_ms: 9_000, ...NAME }, at: 13_000 },
      ]);
      expect(localStorage.getItem(PENDING_KEY)).toBeNull();
    });

    it('ends the session with the background when the page comes back after the session has timed out', async () => {
      await start({ autoSessions: true });
      const session = queued[0]!.session_id;
      await pass(4_000);
      hide();
      frozenFor(45 * MINUTE);
      queued = [];
      show();

      // As it would read had the background been recorded on the spot: the last thing that session did.
      expect(names()).toEqual([BACKGROUND, 'session_end', 'session_start', FOREGROUND]);
      expect(queued[0]).toMatchObject({ session_id: session, timestamp: moment(4_000) });
      expect(queued[1]).toMatchObject({ session_id: session, timestamp: moment(4_000), properties: { duration_ms: 4_000 } });
      expect(queued[3]!.session_id).not.toBe(session);
    });

    it('owes no background to a page that was hidden from the start, and records its first showing as a return', async () => {
      page.visibilityState = 'hidden';
      await start();
      hide();
      expect(localStorage.getItem(PENDING_KEY)).toBeNull();
      await pass(3_000);
      show();
      expect(transitions()).toEqual([{ name: FOREGROUND, properties: { background_ms: 3_000, ...NAME }, at: 3_000 }]);

      // And its time in the foreground is counted from there.
      await pass(1_500);
      hide();
      await pass(BLIP_MS);
      expect(transitions()[1]).toEqual({ name: BACKGROUND, properties: { foreground_ms: 1_500, ...NAME }, at: 4_500 });
    });

    it('records nothing for a page that loaded hidden and was shown a moment later', async () => {
      page.visibilityState = 'hidden';
      await start();
      await pass(BLIP_MS - 1);
      show();
      expect(transitions()).toEqual([]);
    });
  });

  describe('when the page never gets to say so', () => {
    it('records the one a discarded page left, once, at the next `init`, with the time the page was hidden', async () => {
      await start({ autoSessions: true });
      const session = queued[0]!.session_id;
      await pass(3_000);
      hide();
      await pass(500);
      expect(kept()).toEqual([{ id: expect.any(String), at: START + 3_000, foregroundMs: 3_000, session }]);

      await discardAndLoadAgain(60 * MINUTE, { autoSessions: true });

      // Ahead of the page load's own events, in the session the page was in — which it was the last event of.
      expect(names().slice(0, 4)).toEqual([BACKGROUND, 'session_end', 'session_start', DEFAULT_EVENTS.APP_OPEN]);
      expect(queued[0]).toMatchObject({ session_id: session, timestamp: moment(3_000), properties: { foreground_ms: 3_000, ...NAME } });
      expect(queued[1]).toMatchObject({ session_id: session, timestamp: moment(3_000), properties: { duration_ms: 3_000, event_count: 3 } });
      expect(localStorage.getItem(PENDING_KEY)).toBeNull();
      expect(uploads[uploads.length - 1]!.events.slice(0, 2)).toEqual([BACKGROUND, 'session_end']);

      // And not again: the load after that one finds nothing left.
      await discardAndLoadAgain(MINUTE, { autoSessions: true });
      expect(names()).not.toContain(BACKGROUND);
    });

    it('files one another tab left under the session that tab was in, and leaves this tab’s own alone', async () => {
      await start({ autoSessions: true });
      const session = queued[0]!.session_id;
      await pass(3_000);
      hide();
      await pass(500);

      // A different tab of the same origin: the same storage, and no session of its own yet.
      sessionStorage.clear();
      await discardAndLoadAgain(10 * MINUTE, { autoSessions: true });

      expect(names().slice(0, 3)).toEqual([BACKGROUND, 'session_start', DEFAULT_EVENTS.APP_OPEN]);
      expect(queued[0]).toMatchObject({ session_id: session, timestamp: moment(3_000) });
      expect(queued[1]!.session_id).not.toBe(session);
      expect(queued[1]!.timestamp).toBe(moment(3_500 + 10 * MINUTE));
    });

    it('does not record again what another page load on the origin already took, and still records the return', async () => {
      await start();
      await pass(1_000);
      hide();

      // What a second tab's `init` does while this one is hidden.
      expect(takeLeftBackgrounds(true)).toEqual([{ at: START + 1_000, foregroundMs: 1_000, session: expect.any(String) }]);

      await pass(BLIP_MS * 2);
      expect(transitions()).toEqual([]);
      await pass(1_000);
      show();
      expect(transitions()).toEqual([{ name: FOREGROUND, properties: { background_ms: 5_000, ...NAME }, at: 6_000 }]);
    });

    it('takes what a write key that is not this one left as that project’s, and records none of it', async () => {
      await start();
      await pass(1_000);
      hide();
      await discardAndLoadAgain(MINUTE, { writeKey: 'pk_test_another' });

      expect(names()).not.toContain(BACKGROUND);
      expect(localStorage.getItem(PENDING_KEY)).toBeNull();
    });

    it('reads past anything in storage that is not an entry, and clears it', async () => {
      for (const junk of ['not json', '{"at":1}', '[null, 7, {"id":"x"}, {"id":"y","at":"soon","foregroundMs":1,"session":null}]']) {
        localStorage.setItem(PENDING_KEY, junk);
        await start();
        expect(names()).not.toContain(BACKGROUND);
        expect(localStorage.getItem(PENDING_KEY)).toBeNull();
        sdk.shutdown();
        sdk = new TreebarsWeb();
      }
    });
  });

  describe('where the page may keep or record nothing', () => {
    it('keeps nothing in storage with `disableStorage`, and still tells a background from a blip', async () => {
      await start({ disableStorage: true });
      await pass(1_000);
      hide();
      expect(localStorage.length).toBe(0);
      await pass(500);
      show();
      await pass(500);
      expect(transitions()).toEqual([]);

      hide();
      expect(localStorage.length).toBe(0);
      await pass(BLIP_MS);
      expect(transitions()).toEqual([{ name: BACKGROUND, properties: { foreground_ms: 2_000, ...NAME }, at: 2_000 }]);
      expect(sessionStorage.length).toBe(0);
    });

    it('keeps and records nothing for a person who opted out before `init`', async () => {
      sdk.optOut();
      await start();
      hide();
      expect(localStorage.getItem(PENDING_KEY)).toBeNull();
      await pass(BLIP_MS * 2);
      show();
      expect(transitions()).toEqual([]);
    });

    it('keeps and records nothing once a person opts out, and drops the one that was waiting', async () => {
      await start();
      await pass(1_000);
      hide();
      expect(kept()).toHaveLength(1);

      sdk.optOut();
      expect(localStorage.getItem(PENDING_KEY)).toBeNull();
      await pass(BLIP_MS * 2);
      show();
      await pass(1_000);
      hide();
      expect(localStorage.getItem(PENDING_KEY)).toBeNull();
      await pass(BLIP_MS * 2);
      expect(transitions()).toEqual([]);
    });

    it('drops the one an earlier visit left when the next one starts opted out', async () => {
      await start();
      await pass(1_000);
      hide();
      sdk.shutdown();
      sdk = new TreebarsWeb();
      queued = [];
      page.visibilityState = 'visible';

      sdk.optOut();
      await start();
      expect(localStorage.getItem(PENDING_KEY)).toBeNull();

      // Opting back in later brings nothing from before the "no" with it.
      sdk.optIn();
      await discardAndLoadAgain(MINUTE);
      expect(names()).not.toContain(BACKGROUND);
    });

    it('records nothing after a wipe for the hide the page was in', async () => {
      await start();
      await pass(1_000);
      hide();
      expect(kept()).toHaveLength(1);

      sdk.wipeLocalData();
      expect(localStorage.getItem(PENDING_KEY)).toBeNull();
      await pass(BLIP_MS * 2);
      expect(transitions()).toEqual([]);
    });

    it('records neither event with `autoLifecycle` off, and still sends what is queued as the page is hidden', async () => {
      await start({ autoLifecycle: false });
      await pass(5_000);
      const sent = uploads.length;

      sdk.track('viewed');
      hide();
      expect(uploads[sent]).toEqual({ at: 5_000, events: ['viewed'] });
      expect(localStorage.getItem(PENDING_KEY)).toBeNull();

      await pass(BLIP_MS * 2);
      leave();
      show();
      expect(transitions()).toEqual([]);
      expect(names()).not.toContain(DEFAULT_EVENTS.APP_OPEN);
    });

    it('takes out, unrecorded, what an earlier page load left when this one has `autoLifecycle` off', async () => {
      await start();
      await pass(1_000);
      hide();
      await discardAndLoadAgain(MINUTE, { autoLifecycle: false });

      expect(names()).not.toContain(BACKGROUND);
      expect(localStorage.getItem(PENDING_KEY)).toBeNull();
    });
  });
});

describe('what storage keeps for a hidden page', () => {
  beforeEach(() => {
    vi.stubGlobal('localStorage', webStorage());
    vi.stubGlobal('sessionStorage', webStorage());
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  const first = { at: 1_000, foregroundMs: 10, session: 's-first' };
  const second = { at: 2_000, foregroundMs: 20, session: null };

  it('keeps an entry per hidden page, and hands each over once to whoever takes it first', () => {
    // Kept later-first, as two tabs hidden in that order would: the next page load reads them oldest first.
    const later = keepPendingBackground(second, true)!;
    const earlier = keepPendingBackground(first, true)!;
    expect(later).not.toBe(earlier);

    // The page itself, when its hide lasted or came to nothing.
    expect(takePendingBackground(later)).toBe(true);
    expect(takePendingBackground(later)).toBe(false);

    // The next page load, for a page that never got to.
    expect(takeLeftBackgrounds(true)).toEqual([first]);
    expect(takeLeftBackgrounds(true)).toEqual([]);
    expect(takePendingBackground(earlier)).toBe(false);
  });

  it('hands the next page load every entry, oldest first', () => {
    keepPendingBackground(second, true);
    keepPendingBackground(first, true);
    expect(takeLeftBackgrounds(true)).toEqual([first, second]);
  });

  it('keeps nothing where it may not, and says so where storage will not hold it', () => {
    expect(keepPendingBackground(first, false)).toBeNull();
    expect(localStorage.length).toBe(0);
    expect(takeLeftBackgrounds(false)).toEqual([]);

    // A storage that refuses the write.
    vi.stubGlobal('localStorage', {
      getItem: () => null,
      setItem: () => {
        throw new Error('QuotaExceededError');
      },
      removeItem: () => undefined,
    });
    expect(keepPendingBackground(first, true)).toBeNull();

    // And one that takes it without a word and keeps nothing.
    vi.stubGlobal('localStorage', { getItem: () => null, setItem: () => undefined, removeItem: () => undefined });
    expect(keepPendingBackground(first, true)).toBeNull();
  });

  it('drops what the previous device was owed when the origin adopts another', () => {
    const held = { id: `dev_${'a'.repeat(32)}`, secret: 'a'.repeat(64) };
    adoptStoredDevice(held);
    keepPendingBackground(first, true);

    // The device it already has: nothing changes hands.
    adoptStoredDevice(held);
    expect(localStorage.getItem(PENDING_KEY)).not.toBeNull();

    adoptStoredDevice({ id: `dev_${'b'.repeat(32)}`, secret: 'b'.repeat(64) });
    expect(takeLeftBackgrounds(true)).toEqual([]);
  });
});
