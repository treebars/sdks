import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { TreebarsWeb } from '../src/index';
import { EventStore } from '../src/storage';
import { DEFAULT_EVENTS, type QueuedEvent, type TreebarsWebConfig } from '../src/types';

/**
 * What `app_open`, `app_foreground` and `app_background` carry.
 *
 * The three are recorded by the SDK on every site, with nothing in them to tell one site's from
 * another's — so each also says which app it is about, as `name`: the name the page gave at `init`
 * (`appName`), or the page's hostname. These pin the whole of each event's properties, so a
 * property that is added, renamed or dropped shows here.
 *
 * Every hide here lasts longer than the two seconds a page has to stay hidden before the hide is a
 * background at all; what a shorter one records, which is nothing, is `lifecycle-blip.test.ts`.
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

describe('the lifecycle events say which app they are about', () => {
  /** Every event as it went onto the queue, which is before anything decides when to upload it. */
  let queued: QueuedEvent[];
  let page: EventTarget & { visibilityState: string; title: string; referrer: string };
  let location: { pathname: string; hostname: string; href: string; origin: string };
  let sdk: TreebarsWeb;

  beforeEach(() => {
    vi.useFakeTimers({ now: Date.parse('2026-10-06T12:00:00.000Z') });
    vi.stubGlobal('localStorage', memoryStorage());
    vi.stubGlobal('sessionStorage', memoryStorage());
    queued = [];
    const add = EventStore.prototype.add;
    vi.spyOn(EventStore.prototype, 'add').mockImplementation(function (this: EventStore, event: QueuedEvent) {
      queued.push(event);
      add.call(this, event);
    });

    vi.stubGlobal('fetch', vi.fn(async () => Response.json({ server_time: 'now' })));
    vi.stubGlobal('navigator', { userAgent: 'vitest', language: 'en-GB' });
    page = Object.assign(new EventTarget(), { visibilityState: 'visible', title: 'Test', referrer: '' });
    vi.stubGlobal('document', page);
    location = { pathname: '/', hostname: 'shop.example.com', href: 'https://shop.example.com/', origin: 'https://shop.example.com' };
    vi.stubGlobal(
      'window',
      Object.assign(new EventTarget(), { screen: { width: 1280, height: 800 }, devicePixelRatio: 1, location }),
    );
    sdk = new TreebarsWeb();
  });

  afterEach(() => {
    sdk.shutdown();
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  const start = (config: Partial<TreebarsWebConfig> = {}) =>
    sdk.init({
      writeKey: 'pk_test_lifecycle',
      backendUrl: 'https://ingest.test',
      inAppEnabled: false,
      autoPageViews: false,
      autoSessions: false,
      ...config,
    });

  /** Hides or shows the tab, `after` milliseconds from now, the page's own timers running until then. */
  const turn = (visibility: 'hidden' | 'visible', after: number) => {
    vi.advanceTimersByTime(after);
    page.visibilityState = visibility;
    page.dispatchEvent(new Event('visibilitychange'));
  };

  /** The properties of every event of that name, in the order they were recorded. */
  const propertiesOf = (name: string) => queued.filter((each) => each.event_name === name).map((each) => each.properties);

  it('names the page’s hostname when the page gave no name', () => {
    start();
    turn('hidden', 4_000);
    turn('visible', 9_000);

    expect(propertiesOf(DEFAULT_EVENTS.APP_OPEN)).toEqual([{ is_first_launch: true, name: 'shop.example.com' }]);
    expect(propertiesOf(DEFAULT_EVENTS.APP_BACKGROUND)).toEqual([{ foreground_ms: 4_000, name: 'shop.example.com' }]);
    expect(propertiesOf(DEFAULT_EVENTS.APP_FOREGROUND)).toEqual([{ background_ms: 9_000, name: 'shop.example.com' }]);
  });

  it('names what the page called itself at `init`, on all three', () => {
    start({ appName: 'Acme Shop' });
    turn('hidden', 1_000);
    turn('visible', 3_000);

    expect(propertiesOf(DEFAULT_EVENTS.APP_OPEN)).toEqual([{ is_first_launch: true, name: 'Acme Shop' }]);
    expect(propertiesOf(DEFAULT_EVENTS.APP_BACKGROUND)).toEqual([{ foreground_ms: 1_000, name: 'Acme Shop' }]);
    expect(propertiesOf(DEFAULT_EVENTS.APP_FOREGROUND)).toEqual([{ background_ms: 3_000, name: 'Acme Shop' }]);
  });

  it('takes a blank name as none, and trims one that is not', () => {
    start({ appName: '   ' });
    expect(propertiesOf(DEFAULT_EVENTS.APP_OPEN)).toEqual([{ is_first_launch: true, name: 'shop.example.com' }]);

    // A second load in the same browser, so no longer its first launch.
    sdk.shutdown();
    queued = [];
    sdk = new TreebarsWeb();
    start({ appName: '  Acme Shop ' });
    expect(propertiesOf(DEFAULT_EVENTS.APP_OPEN)).toEqual([{ is_first_launch: false, name: 'Acme Shop' }]);
  });

  it('leaves the name out where the page has no hostname, rather than sending an empty one', () => {
    location.hostname = '';
    start();
    turn('hidden', 1_000);
    turn('visible', 3_000);

    expect(propertiesOf(DEFAULT_EVENTS.APP_OPEN)).toEqual([{ is_first_launch: true }]);
    expect(propertiesOf(DEFAULT_EVENTS.APP_BACKGROUND)).toEqual([{ foreground_ms: 1_000 }]);
    expect(propertiesOf(DEFAULT_EVENTS.APP_FOREGROUND)).toEqual([{ background_ms: 3_000 }]);
  });

  it('puts it on these three and nothing else', async () => {
    start({ appName: 'Acme Shop', autoSessions: true });
    // The browser's own description is recorded once the script that called `init` has run.
    await vi.advanceTimersByTimeAsync(0);
    sdk.page();
    sdk.track('viewed', { sku: 'a1' });
    turn('hidden', 1_000);
    turn('visible', 3_000);

    const named = queued.filter((each) => 'name' in each.properties).map((each) => each.event_name);
    expect(named).toEqual([DEFAULT_EVENTS.APP_OPEN, DEFAULT_EVENTS.APP_BACKGROUND, DEFAULT_EVENTS.APP_FOREGROUND]);
    expect(queued.map((each) => each.event_name)).toEqual(
      expect.arrayContaining(['session_start', 'page_view', 'device_context', 'viewed']),
    );
  });

  it('records none of the three, named or not, with `autoLifecycle` off', () => {
    start({ appName: 'Acme Shop', autoLifecycle: false });
    turn('hidden', 1_000);
    turn('visible', 3_000);
    const lifecycle: string[] = [DEFAULT_EVENTS.APP_OPEN, DEFAULT_EVENTS.APP_BACKGROUND, DEFAULT_EVENTS.APP_FOREGROUND];
    expect(queued.filter((each) => lifecycle.includes(each.event_name))).toEqual([]);
  });
});
