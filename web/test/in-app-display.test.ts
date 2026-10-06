import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { hashDeviceContext, type WebDeviceContext } from '../src/device';
import { CONTEXT_SETTLE_MS } from '../src/generated/constants';
import { TreebarsWeb } from '../src/index';
import { EventStore } from '../src/storage';
import type { QueuedEvent } from '../src/types';

/**
 * `in_app_display` on `device_context`: what draws this page's in-app messages — this SDK (`sdk`), the page's own
 * renderer (`app`), or nothing (`off`).
 *
 * It is the one value in the context the page's own code sets, usually a moment after `init`, so what these pin is
 * as much *when* it is reported as *what*: never inside `init`, where it would still say `sdk` for a page about to
 * register its renderer; once per page load at most; and again only for a change that stood.
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

/** The contexts and hashes every Treebars SDK answers alike, the Android and iOS SDKs from their own copies. */
const HASHES = JSON.parse(readFileSync(fileURLToPath(new URL('./fixtures/device-context-hash.json', import.meta.url)), 'utf8')) as {
  cases: { name: string; context: Record<string, string>; hash: string }[];
};

const CONTEXT_KEY = 'treebars.device_context.v1';
const renderer = () => undefined;

describe('what device_context says about in-app messages', () => {
  /** Every event as it went onto the queue, across every page load of the test. */
  let queued: QueuedEvent[];
  let local: ReturnType<typeof webStorage>;
  let sdk: TreebarsWeb | null;

  beforeEach(() => {
    vi.useFakeTimers({ now: Date.parse('2026-10-06T12:00:00.000Z') });
    local = webStorage();
    vi.stubGlobal('localStorage', local);
    vi.stubGlobal('sessionStorage', webStorage());
    queued = [];
    sdk = null;
    const add = EventStore.prototype.add;
    vi.spyOn(EventStore.prototype, 'add').mockImplementation(function (this: EventStore, event: QueuedEvent) {
      queued.push(event);
      add.call(this, event);
    });
    vi.stubGlobal('fetch', vi.fn(async () => Response.json({ messages: [], server_time: 'now' })));
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
  });

  afterEach(() => {
    sdk?.shutdown();
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  /** A page load: a new SDK over whatever the browser already holds. */
  function load(config: { inAppEnabled?: boolean; disableStorage?: boolean } = {}): TreebarsWeb {
    sdk?.shutdown();
    sdk = new TreebarsWeb();
    sdk.init({
      writeKey: 'pk_live_display',
      backendUrl: 'https://ingest.test',
      autoPageViews: false,
      autoLifecycle: false,
      autoSessions: false,
      shareAcrossSubdomains: false,
      ...config,
    });
    return sdk;
  }

  const contexts = () => queued.filter((event) => event.event_name === 'device_context');
  const displays = () => contexts().map((event) => event.properties.in_app_display);
  /** The script that called `init` has run. */
  const turn = () => vi.advanceTimersByTimeAsync(0);
  /** And the page has stood long enough for a later report to be made. */
  const settle = () => vi.advanceTimersByTimeAsync(CONTEXT_SETTLE_MS);

  describe('the three answers', () => {
    it('is sdk when the page says nothing: in-app is on, and this SDK draws', async () => {
      load();
      await turn();
      expect(displays()).toEqual(['sdk']);
    });

    it('is app when the page registered its own renderer', async () => {
      load().setInAppRenderer(renderer);
      await turn();
      expect(displays()).toEqual(['app']);
    });

    it('is app when the renderer was registered before init', async () => {
      sdk = new TreebarsWeb();
      sdk.setInAppRenderer(renderer);
      sdk.init({ writeKey: 'pk_live_display', backendUrl: 'https://ingest.test', autoPageViews: false, autoLifecycle: false, shareAcrossSubdomains: false });
      await turn();
      expect(displays()).toEqual(['app']);
    });

    it('is off when in-app is switched off at init', async () => {
      load({ inAppEnabled: false });
      await turn();
      expect(displays()).toEqual(['off']);
    });

    it('is off when the page set drawing to nothing', async () => {
      load().setInAppRenderer(null);
      await turn();
      expect(displays()).toEqual(['off']);
    });

    it('is off for a page with in-app off, whatever renderer it also registered', async () => {
      load({ inAppEnabled: false }).setInAppRenderer(renderer);
      await turn();
      expect(displays()).toEqual(['off']);
    });

    it('is sdk again once the page hands drawing back', async () => {
      const page = load();
      page.setInAppRenderer(renderer);
      page.setInAppRenderer('builtin');
      await turn();
      expect(displays()).toEqual(['sdk']);
    });
  });

  describe('it is in the hash, like every other key of the context', () => {
    it('reports the hash of exactly what the event carries', async () => {
      load().setInAppRenderer(renderer);
      await turn();
      const [event] = contexts();
      const { context_hash: hash, fetch_secret: _secret, ...context } = event!.properties;
      expect(context).toHaveProperty('in_app_display', 'app');
      expect(hash).toBe(hashDeviceContext(context as unknown as WebDeviceContext));
    });

    it.each(HASHES.cases)('hashes as the other SDKs do: $name', ({ context, hash }) => {
      expect(hashDeviceContext(context as unknown as WebDeviceContext)).toBe(hash);
    });

    it('is told apart by the shared cases themselves: one hash for each of the three answers', () => {
      const byDisplay = new Map(HASHES.cases.filter((each) => 'app_id' in each.context).map((each) => [each.context.in_app_display, each.hash]));
      expect([...byDisplay.keys()].sort()).toEqual(['app', 'off', 'sdk', undefined].sort());
      expect(new Set(byDisplay.values()).size).toBe(4);
    });

    it('hashes the three answers apart, and one answer the same way twice', () => {
      const context = (display: 'sdk' | 'app' | 'off'): WebDeviceContext => ({ platform_type: 'web', locale: 'en-GB', in_app_display: display });
      const hashes = (['sdk', 'app', 'off'] as const).map((display) => hashDeviceContext(context(display)));
      expect(new Set(hashes).size).toBe(3);
      expect(hashDeviceContext(context('app'))).toBe(hashes[1]);
      // And apart from a context that predates the key, which is what sends the first report after an upgrade.
      expect(hashes).not.toContain(hashDeviceContext({ platform_type: 'web', locale: 'en-GB' }));
    });
  });

  describe('true, not early', () => {
    it('records nothing inside init, where the page has not yet said how it draws', () => {
      load();
      expect(contexts()).toEqual([]);
    });

    it('reports the page’s own renderer once, when it is set right after init', async () => {
      load().setInAppRenderer(renderer);
      await turn();
      await settle();
      await settle();
      expect(displays()).toEqual(['app']);
    });

    it('reports nothing on a later page load whose renderer arrives a moment after init, as a framework effect does', async () => {
      load().setInAppRenderer(renderer);
      await turn();
      expect(displays()).toEqual(['app']);

      // The next page: `init` in one script, the renderer in an effect after the first paint.
      const next = load();
      await vi.advanceTimersByTimeAsync(120);
      next.setInAppRenderer(renderer);
      await settle();
      await settle();

      // Not `sdk` for the moment before the effect ran, and not `app` again: the page never changed.
      expect(displays()).toEqual(['app']);
    });

    it('waits out the settle before a returning browser reports what its page now says', async () => {
      load();
      await turn();
      expect(displays()).toEqual(['sdk']);

      // The site shipped its own renderer; this browser has been here before.
      load().setInAppRenderer(renderer);
      await turn();
      await vi.advanceTimersByTimeAsync(CONTEXT_SETTLE_MS - 1);
      expect(displays()).toEqual(['sdk']);
      await vi.advanceTimersByTimeAsync(1);
      expect(displays()).toEqual(['sdk', 'app']);
    });

    it('reports a page that switched in-app off on the first load that has it off', async () => {
      load();
      await turn();
      load({ inAppEnabled: false });
      await turn();
      await settle();
      expect(displays()).toEqual(['sdk', 'off']);
    });
  });

  describe('a later change is reported once', () => {
    it('reports a renderer registered long after the page opened, once it has stood', async () => {
      const page = load();
      await turn();
      await vi.advanceTimersByTimeAsync(60_000);
      page.setInAppRenderer(renderer);
      expect(displays()).toEqual(['sdk']);
      await settle();
      expect(displays()).toEqual(['sdk', 'app']);
      expect(contexts()[1]!.properties.context_hash).not.toBe(contexts()[0]!.properties.context_hash);
    });

    it('reports a renderer cleared to nothing', async () => {
      const page = load();
      page.setInAppRenderer(renderer);
      await turn();
      page.setInAppRenderer(null);
      await settle();
      expect(displays()).toEqual(['app', 'off']);
    });

    it('reports nothing for a page that registers a new function on every render', async () => {
      const page = load();
      page.setInAppRenderer(() => undefined);
      await turn();
      for (let render = 0; render < 50; render += 1) {
        page.setInAppRenderer(() => undefined);
        await vi.advanceTimersByTimeAsync(100);
      }
      await settle();
      expect(displays()).toEqual(['app']);
    });

    it('does not let those registrations push back a report the page owes', async () => {
      load();
      await turn();

      // A returning browser on a page that now draws its own, and registers its renderer on every render.
      const page = load();
      page.setInAppRenderer(() => undefined);
      await turn();
      for (let render = 0; render < 30; render += 1) {
        await vi.advanceTimersByTimeAsync(100);
        page.setInAppRenderer(() => undefined);
      }
      // Reported when the answer had stood for the settle, though the function changed thirty times meanwhile.
      expect(displays()).toEqual(['sdk', 'app']);
    });

    it('reports nothing for a renderer cleared and set again inside the settle', async () => {
      const page = load();
      page.setInAppRenderer(renderer);
      await turn();

      // A host unmounting and mounting: its cleanup clears the renderer, its next effect registers it.
      page.setInAppRenderer('builtin');
      await vi.advanceTimersByTimeAsync(CONTEXT_SETTLE_MS - 1);
      page.setInAppRenderer(renderer);
      await settle();
      await settle();
      expect(displays()).toEqual(['app']);
    });

    it('reports each answer that stood, in order', async () => {
      const page = load();
      await turn();
      page.setInAppRenderer(renderer);
      await settle();
      page.setInAppRenderer(null);
      await settle();
      page.setInAppRenderer('builtin');
      await settle();
      expect(displays()).toEqual(['sdk', 'app', 'off', 'sdk']);
    });
  });

  describe('a person who opted out is not described', () => {
    it('reports nothing for a page loaded opted out, whatever it does to the renderer', async () => {
      sdk = new TreebarsWeb();
      sdk.optOut();
      sdk.init({ writeKey: 'pk_live_display', backendUrl: 'https://ingest.test', autoPageViews: false, shareAcrossSubdomains: false });
      await turn();
      sdk.setInAppRenderer(renderer);
      await settle();
      sdk.setInAppRenderer(null);
      await settle();
      expect(queued).toEqual([]);
      expect(local.getItem(CONTEXT_KEY)).toBeNull();
    });

    it('reports nothing for a change waiting out its settle when the person opts out, and does not count it as made', async () => {
      const page = load();
      await turn();
      const record = local.getItem(CONTEXT_KEY);
      expect(record).not.toBeNull();

      page.setInAppRenderer(renderer);
      page.optOut();
      await settle();
      await settle();

      expect(displays()).toEqual(['sdk']);
      // Still the record of what was last said, so the change is owed, not forgotten.
      expect(local.getItem(CONTEXT_KEY)).toBe(record);
    });

    it('reports nothing where the page keeps no storage, as before', async () => {
      const page = load({ disableStorage: true });
      await turn();
      page.setInAppRenderer(renderer);
      await settle();
      expect(contexts()).toEqual([]);
    });
  });

  describe('nothing more is kept in the browser for it', () => {
    it('stores nothing a change of renderer did not already store', async () => {
      const page = load();
      await turn();
      const keys = [...local.map.keys()].sort();

      page.setInAppRenderer(renderer);
      await settle();
      expect(displays()).toEqual(['sdk', 'app']);
      expect([...local.map.keys()].sort()).toEqual(keys);
    });

    it('drops a report waiting out its settle when the browser is wiped, and leaves no record of one', async () => {
      const page = load();
      await turn();
      page.setInAppRenderer(renderer);
      page.wipeLocalData();
      await settle();
      await settle();

      expect(displays()).toEqual(['sdk']);
      expect(local.getItem(CONTEXT_KEY)).toBeNull();
    });

    it('stops waiting when the SDK is shut down', async () => {
      const page = load();
      await turn();
      page.setInAppRenderer(renderer);
      page.shutdown();
      await settle();
      expect(displays()).toEqual(['sdk']);
    });
  });
});
