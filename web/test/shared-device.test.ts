import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { SHARED_BROWSER_COOKIE, sharedBrowserId } from '../src/acquisition';
import { HEADERS, STORAGE_KEYS } from '../src/generated/constants';
import type { InAppStore } from '../src/in-app';
import { TreebarsWeb } from '../src/index';
import { SHARED_DEVICE_COOKIES } from '../src/shared-device';
import type { TreebarsWebConfig } from '../src/types';
import { CookieJar } from './cookie-jar';

/**
 * One device across a site's subdomains (`shareAcrossSubdomains`).
 *
 * `localStorage` is per origin, so each test here is a browser with several origins in it: one cookie jar, and a
 * storage of its own for every origin a page is opened on. What is asserted is always the pair — the device id AND its
 * secret — because an origin holding the right id with another secret is a device that cannot prove itself.
 */

/** Storage as the Web Storage API has it, `key()` and `length` included — the write-key claim walks it. */
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

interface Seen {
  path: string;
  headers: Record<string, string>;
  body: Record<string, unknown>;
}

interface SentEvent {
  event_name: string;
  device_id: string;
  session_id: string;
  user_id?: string;
  properties: Record<string, unknown>;
}

const NOW = Date.parse('2026-10-05T12:00:00.000Z');
const MINUTE = 60 * 1000;
const DAY = 24 * 60 * MINUTE;
const SIGNATURE = 'a1'.repeat(32);
const DEVICE = /^dev_[0-9a-f]{32}$/;
const SECRET = /^[0-9a-f]{64}$/;
/** A well-formed pair nobody in these tests minted: what another tab, or another script, could have put there. */
const OTHER = { id: `dev_${'7'.repeat(32)}`, secret: '9'.repeat(64) };

/** One browser: a cookie jar, and a storage per origin. Only one page is open at a time. */
class Browser {
  readonly jar: CookieJar;
  private readonly origins = new Map<string, { local: ReturnType<typeof webStorage>; session: ReturnType<typeof webStorage> }>();
  requests: Seen[] = [];
  /** No upload gets through, so what a page queued is still queued when the next one loads. */
  offline = false;
  private page: TreebarsWeb | null = null;

  constructor(jar = new CookieJar()) {
    this.jar = jar;
  }

  storage(href: string) {
    const origin = new URL(href).origin;
    let found = this.origins.get(origin);
    if (!found) {
      found = { local: webStorage(), session: webStorage() };
      this.origins.set(origin, found);
    }
    return found;
  }

  /** The pair an origin holds in its own storage. */
  device(href: string): { id: string | null; secret: string | null } {
    const { local } = this.storage(href);
    return { id: local.getItem(STORAGE_KEYS.device), secret: local.getItem(STORAGE_KEYS.fetchSecret) };
  }

  /** The pair the cookie holds, split as the SDK splits it. Null when there is no such cookie. */
  shared(name: string = SHARED_DEVICE_COOKIES.live): { id: string; secret: string } | null {
    const [cookie] = this.jar.named(name);
    if (!cookie) return null;
    const dot = cookie.value.indexOf('.');
    return { id: cookie.value.slice(0, dot), secret: cookie.value.slice(dot + 1) };
  }

  /** Points every global a page reads at the page at `href`. */
  visit(href: string): void {
    const url = new URL(href);
    const { local, session } = this.storage(href);
    const location = { href: url.href, pathname: url.pathname, origin: url.origin, hostname: url.hostname, protocol: url.protocol, assign: vi.fn() };
    vi.stubGlobal('localStorage', local);
    vi.stubGlobal('sessionStorage', session);
    vi.stubGlobal('location', location);
    vi.stubGlobal('document', this.jar.attach(Object.assign(new EventTarget(), { visibilityState: 'visible', title: 'Page', referrer: '' }), href));
    vi.stubGlobal('window', Object.assign(new EventTarget(), { screen: { width: 1280, height: 800 }, devicePixelRatio: 1, location }));
    vi.stubGlobal(
      'fetch',
      vi.fn(async (target: string, init: RequestInit = {}) => {
        const path = new URL(target).pathname;
        this.requests.push({
          path,
          headers: (init.headers ?? {}) as Record<string, string>,
          body: typeof init.body === 'string' ? (JSON.parse(init.body) as Record<string, unknown>) : {},
        });
        if (this.offline && path === '/v1/events') throw new TypeError('offline');
        return Response.json({ accepted: 1, messages: [], notifications: [], unread_count: 0, server_time: 'now' });
      }),
    );
  }

  /** Loads the page at `href` and starts the SDK on it. `before` runs on the new instance ahead of `init`. */
  open(href: string, config: Partial<TreebarsWebConfig> = {}, before?: (sdk: TreebarsWeb) => void): TreebarsWeb {
    this.visit(href);
    const sdk = new TreebarsWeb();
    before?.(sdk);
    sdk.init({ writeKey: 'pk_live_shared', backendUrl: 'https://ingest.test', autoPageViews: false, flushIntervalMs: 24 * 60 * MINUTE, ...config });
    this.page = sdk;
    return sdk;
  }

  /** Lets the page's uploads and reads finish, then closes it — the next page must not find this one still writing. */
  async close(): Promise<void> {
    const sdk = this.page;
    if (!sdk) return;
    await vi.advanceTimersByTimeAsync(0);
    await sdk.flush();
    await vi.advanceTimersByTimeAsync(0);
    sdk.shutdown();
    this.page = null;
  }

  /** Every event uploaded so far, in order. */
  events(): SentEvent[] {
    return this.requests.filter((each) => each.path === '/v1/events').flatMap((each) => (each.body.events ?? []) as SentEvent[]);
  }
}

/** The pair a running SDK reports as, which with storage off is nowhere else. */
const running = (sdk: TreebarsWeb) => {
  const held = sdk as unknown as { deviceId: string; fetchSecret: string };
  return { id: held.deviceId, secret: held.fetchSecret };
};

const cookieWrites = (browser: Browser) => browser.jar.writes.filter((write) => write.text.startsWith('tbrs_dv_'));

describe('one device across a site’s subdomains', () => {
  let browser: Browser;

  beforeEach(() => {
    vi.useFakeTimers({ now: NOW });
    // Uploads as plain JSON, so a test reads them back without unzipping.
    vi.stubGlobal('CompressionStream', undefined);
    vi.stubGlobal('navigator', { userAgent: 'vitest', language: 'en-GB', sendBeacon: () => true });
    browser = new Browser();
  });

  afterEach(async () => {
    await browser.close();
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  describe('which origins become one device', () => {
    it('gives the apex and a subdomain the same id and secret when the apex loads first', async () => {
      browser.open('https://example.com/');
      await browser.close();
      const apex = browser.device('https://example.com/');
      expect(apex.id).toMatch(DEVICE);
      expect(apex.secret).toMatch(SECRET);

      const app = browser.open('https://app.example.com/');
      expect(browser.device('https://app.example.com/')).toEqual(apex);
      expect(running(app)).toEqual(apex);
      expect(browser.shared()).toEqual(apex);
    });

    it('gives them the same id and secret when the subdomain loads first', async () => {
      browser.open('https://app.example.com/');
      await browser.close();
      const app = browser.device('https://app.example.com/');

      browser.open('https://example.com/');
      await browser.close();
      expect(browser.device('https://example.com/')).toEqual(app);

      // And a third, two labels deeper, which is under the same parent.
      browser.open('https://eu.shop.example.com/');
      expect(browser.device('https://eu.shop.example.com/')).toEqual(app);
      // One cookie, on the parent — not one per subdomain that wrote.
      expect(browser.jar.named(SHARED_DEVICE_COOKIES.live).map((cookie) => [cookie.domain, cookie.hostOnly])).toEqual([['example.com', false]]);
    });

    it('does not join two unrelated domains', async () => {
      browser.open('https://example.com/');
      await browser.close();
      browser.open('https://app.other.com/');
      await browser.close();

      const first = browser.device('https://example.com/');
      const second = browser.device('https://app.other.com/');
      expect(second.id).toMatch(DEVICE);
      expect(second.id).not.toBe(first.id);
      expect(second.secret).not.toBe(first.secret);
      expect(browser.jar.named(SHARED_DEVICE_COOKIES.live).map((cookie) => cookie.domain).sort()).toEqual(['example.com', 'other.com']);
    });

    it('does not join a pk_test_ site and a pk_live_ site that sit on sibling subdomains', async () => {
      browser.open('https://www.example.com/', { writeKey: 'pk_live_production' });
      await browser.close();
      browser.open('https://staging.example.com/', { writeKey: 'pk_test_staging' });
      await browser.close();

      const live = browser.device('https://www.example.com/');
      const test = browser.device('https://staging.example.com/');
      expect(test.id).not.toBe(live.id);
      expect(browser.shared(SHARED_DEVICE_COOKIES.live)).toEqual(live);
      expect(browser.shared(SHARED_DEVICE_COOKIES.test)).toEqual(test);

      // A second test-key origin joins the test device, not the live one.
      browser.open('https://preview.example.com/', { writeKey: 'pk_test_staging' });
      expect(browser.device('https://preview.example.com/')).toEqual(test);
    });

    it('shares nothing for a write key of neither kind', async () => {
      const sdk = browser.open('https://example.com/', { writeKey: 'some_other_key' });
      expect(running(sdk).id).toMatch(DEVICE);
      expect(cookieWrites(browser)).toEqual([]);
    });
  });

  describe('the cookie itself', () => {
    it('is the id and the secret, for 400 days, on the parent domain, Lax and Secure', async () => {
      browser.open('https://app.example.com/');
      const { id, secret } = browser.device('https://app.example.com/');
      expect(cookieWrites(browser).map((write) => write.text)).toEqual([
        `tbrs_dv_live=${id}.${secret}; Domain=example.com; Max-Age=34560000; Path=/; SameSite=Lax; Secure`,
      ]);
      expect(browser.jar.named('tbrs_dv_live')).toEqual([
        { name: 'tbrs_dv_live', value: `${id}.${secret}`, domain: 'example.com', hostOnly: false, path: '/', secure: true, sameSite: 'Lax', expiresAt: NOW + 400 * DAY },
      ]);
      // Nothing is left behind by finding the domain.
      expect(browser.jar.all().map((cookie) => cookie.name)).toEqual(['tbrs_dv_live']);
    });

    it('is named for the kind of key, and is not Secure on a plain-http page', async () => {
      browser.open('http://app.example.com/', { writeKey: 'pk_test_local' });
      const { id, secret } = browser.device('http://app.example.com/');
      expect(cookieWrites(browser).map((write) => write.text)).toEqual([
        `tbrs_dv_test=${id}.${secret}; Domain=example.com; Max-Age=34560000; Path=/; SameSite=Lax`,
      ]);
    });

    it('has its lifetime renewed by every init, so it runs from the last visit', async () => {
      browser.open('https://example.com/');
      await browser.close();
      const first = browser.device('https://example.com/');

      vi.setSystemTime(NOW + 300 * DAY);
      browser.open('https://app.example.com/');
      await browser.close();
      expect(browser.jar.named('tbrs_dv_live')[0]!.expiresAt).toBe(NOW + 700 * DAY);

      // Past the first 400 days: still there, because the visit on day 300 renewed it.
      vi.setSystemTime(NOW + 600 * DAY);
      browser.open('https://docs.example.com/');
      expect(browser.device('https://docs.example.com/')).toEqual(first);
    });

    it('is renewed on the domain it lives on where the suffix has two labels', async () => {
      browser.open('https://shop.example.co.uk/');
      await browser.close();
      vi.setSystemTime(NOW + 300 * DAY);
      browser.open('https://shop.example.co.uk/');
      // A write that stopped at `co.uk` — refused, with the value already readable — would have renewed nothing.
      expect(browser.jar.named('tbrs_dv_live')).toMatchObject([{ domain: 'example.co.uk', expiresAt: NOW + 700 * DAY }]);
    });

    it('puts the browser id of an ad visit on the same domain, through the same helper', () => {
      browser.visit('https://shop.example.co.uk/spring');
      const id = sharedBrowserId();
      expect(id).toMatch(/^[a-z0-9]{22}$/);
      expect(browser.jar.named(SHARED_BROWSER_COOKIE)).toMatchObject([{ value: id, domain: 'example.co.uk', hostOnly: false, expiresAt: NOW + 6 * 60 * MINUTE }]);

      // Read back and renewed, on that domain, by a page on a sibling subdomain.
      vi.setSystemTime(NOW + 60 * MINUTE);
      browser.visit('https://www.example.co.uk/');
      expect(sharedBrowserId()).toBe(id);
      expect(browser.jar.named(SHARED_BROWSER_COOKIE)).toMatchObject([{ value: id, domain: 'example.co.uk', expiresAt: NOW + 7 * 60 * MINUTE }]);
    });
  });

  describe('an origin that already had a device of its own', () => {
    const APP = 'https://app.example.com/';
    const message = { delivery_id: 'd-old', campaign_id: 'c-old', content: { in_app: { surface: 'overlay', layout: 'modal', trigger: { kind: 'event', event_name: 'never' } } }, created_at: '2026-10-05T09:00:00.000Z', expires_at: null };

    /** The app as it was before sharing: its own device, somebody signed in, and everything that device left behind. */
    async function appWithItsOwnDevice(): Promise<{ id: string | null; secret: string | null }> {
      browser.offline = true;
      const app = browser.open(APP, { shareAcrossSubdomains: false });
      app.identify('user_42', { plan: 'pro' }, SIGNATURE);
      app.track('viewed', { sku: 'A1' });
      await browser.close();

      const { local } = browser.storage(APP);
      local.setItem(STORAGE_KEYS.inApp, JSON.stringify([message]));
      local.setItem(STORAGE_KEYS.inAppLedger, JSON.stringify({ 'd-old': { displays: 2 } }));
      local.setItem(STORAGE_KEYS.notifications, JSON.stringify({ owner: 'user_42', notifications: [], unreadCount: 3, nextCursor: null }));
      local.setItem(STORAGE_KEYS.notificationLedger, JSON.stringify({ read: { 'g-old': true }, dismissed: {}, readThrough: null }));
      local.setItem('treebars.push.registered.v1', JSON.stringify({ endpoint: 'https://push.example/e1', path: '/sw.js' }));
      browser.offline = false;
      return browser.device(APP);
    }

    it('adopts the cookie’s device, drops what the old one left, and signs its person in again exactly once', async () => {
      const old = await appWithItsOwnDevice();
      const { local, session } = browser.storage(APP);
      const oldSession = (JSON.parse(session.getItem(STORAGE_KEYS.session)!) as { id: string }).id;
      const oldContext = local.getItem(STORAGE_KEYS.deviceContext);
      expect(oldContext).not.toBeNull();
      expect(browser.shared()).toBeNull();

      // The marketing site loads first and offers its device.
      browser.open('https://example.com/');
      await browser.close();
      const shared = browser.device('https://example.com/');
      expect(shared.id).not.toBe(old.id);

      // Five minutes on: well inside the session the app's last page was in.
      vi.setSystemTime(NOW + 5 * MINUTE);
      browser.requests = [];
      const app = browser.open(APP);

      // The cookie's pair, in storage and in use.
      expect(browser.device(APP)).toEqual(shared);
      expect(running(app)).toEqual(shared);
      // What the old device left is gone before any store read it.
      expect((app as unknown as { inApp: InAppStore }).inApp.list()).toEqual([]);
      expect(local.getItem(STORAGE_KEYS.inApp)).toBeNull();
      expect(local.getItem(STORAGE_KEYS.inAppLedger)).toBeNull();
      expect(local.getItem(STORAGE_KEYS.notifications)).toBeNull();
      expect(local.getItem(STORAGE_KEYS.notificationLedger)).toBeNull();
      // The session is a new one, though the old one had not timed out.
      const newSession = (JSON.parse(session.getItem(STORAGE_KEYS.session)!) as { id: string }).id;
      expect(newSession).not.toBe(oldSession);
      // The push subscription is on file as owed a registration, under the worker it was made through.
      expect(JSON.parse(local.getItem('treebars.push.registered.v1')!)).toEqual({ path: '/sw.js' });
      // Who is signed in is the person's, and stays.
      expect(local.getItem(STORAGE_KEYS.signedInUser)).toBe('user_42');
      expect(local.getItem(STORAGE_KEYS.signedInUserSignature)).toBe(SIGNATURE);
      await browser.close();

      // Signed in again on the shared device: the same account, its stored signature, the device's own secret.
      const signIns = browser.requests.filter((each) => each.path === '/v1/identify');
      expect(signIns).toHaveLength(1);
      expect(signIns[0]!.body).toMatchObject({ user_id: 'user_42', device_id: shared.id });
      expect(signIns[0]!.headers[HEADERS.userSignature]).toBe(SIGNATURE);
      expect(signIns[0]!.headers[HEADERS.deviceAuth]).toBe(shared.secret);

      const events = browser.events();
      const under = (id: string | null) => events.filter((event) => event.device_id === id);
      // Every event is under one device or the other, and each kept the id it was recorded with.
      expect(under(old.id).length + under(shared.id).length).toBe(events.length);
      // The old device's unsent events were left as they were, and went out as that device's.
      expect(under(old.id).map((event) => event.event_name)).toEqual(expect.arrayContaining(['app_open', 'user_identified', 'viewed']));
      expect(under(old.id).every((event) => event.session_id === oldSession)).toBe(true);
      // This load's events are the shared device's, in the new session, as the signed-in person.
      expect(under(shared.id).map((event) => event.event_name)).toEqual(expect.arrayContaining(['session_start', 'app_open', 'device_context', 'user_identified']));
      expect(under(shared.id).every((event) => event.session_id === newSession && event.user_id === 'user_42')).toBe(true);
      expect(under(shared.id).filter((event) => event.event_name === 'user_identified')).toHaveLength(1);
      // The context is reported again, registering the shared secret from this origin.
      expect(local.getItem(STORAGE_KEYS.deviceContext)).not.toBe(oldContext);
      expect(under(shared.id).find((event) => event.event_name === 'device_context')!.properties.fetch_secret).toBe(shared.secret);

      // The next load finds the device it already has: nobody is signed in again, and nothing is reported twice.
      vi.setSystemTime(NOW + 10 * MINUTE);
      browser.requests = [];
      browser.open(APP);
      await browser.close();
      expect(browser.device(APP)).toEqual(shared);
      expect(browser.requests.filter((each) => each.path === '/v1/identify')).toEqual([]);
      expect(browser.events().map((event) => event.event_name)).not.toContain('user_identified');
      expect(browser.events().map((event) => event.event_name)).not.toContain('device_context');
      expect((JSON.parse(session.getItem(STORAGE_KEYS.session)!) as { id: string }).id).toBe(newSession);
    });

    it('offers its own device when it is the first to load, and the rest of the site adopts that one', async () => {
      const old = await appWithItsOwnDevice();
      const { local } = browser.storage(APP);
      browser.requests = [];
      browser.open(APP);
      // Nothing changed here, so nothing was dropped and nobody is signed in again.
      expect(browser.device(APP)).toEqual(old);
      expect(browser.shared()).toEqual(old);
      expect(JSON.parse(local.getItem(STORAGE_KEYS.inApp)!)).toHaveLength(1);
      expect(JSON.parse(local.getItem('treebars.push.registered.v1')!)).toMatchObject({ endpoint: 'https://push.example/e1' });
      await browser.close();
      expect(browser.requests.filter((each) => each.path === '/v1/identify')).toEqual([]);

      browser.open('https://example.com/');
      expect(browser.device('https://example.com/')).toEqual(old);
    });

    it('adopts the device a page on another subdomain wrote between its look and its write', async () => {
      const old = await appWithItsOwnDevice();
      // The other page's write lands just after this one's: the jar ends up holding theirs.
      const set = browser.jar.set.bind(browser.jar);
      let raced = false;
      vi.spyOn(browser.jar, 'set').mockImplementation((href, text) => {
        set(href, text);
        if (!raced && text.startsWith('tbrs_dv_live=')) {
          raced = true;
          set('https://example.com/', `tbrs_dv_live=${OTHER.id}.${OTHER.secret}; Domain=example.com; Max-Age=34560000; Path=/; SameSite=Lax; Secure`);
        }
      });

      browser.requests = [];
      const app = browser.open(APP);
      expect(running(app)).toEqual(OTHER);
      expect(browser.device(APP)).toEqual(OTHER);
      expect(browser.shared()).toEqual(OTHER);
      expect(browser.device(APP).id).not.toBe(old.id);
      await browser.close();
      expect(browser.requests.filter((each) => each.path === '/v1/identify').map((each) => each.body.device_id)).toEqual([OTHER.id]);
    });

    it('takes the cookie’s secret for the device it already is, and drops nothing', async () => {
      browser.open(APP);
      await browser.close();
      const shared = browser.device(APP);
      const { local } = browser.storage(APP);
      local.setItem(STORAGE_KEYS.inApp, JSON.stringify([message]));
      local.removeItem(STORAGE_KEYS.fetchSecret);

      browser.requests = [];
      const app = browser.open(APP);
      expect(running(app)).toEqual(shared);
      expect(browser.device(APP)).toEqual(shared);
      expect(JSON.parse(local.getItem(STORAGE_KEYS.inApp)!)).toHaveLength(1);
    });

    it('puts the device back from the cookie when only this origin’s storage was cleared', async () => {
      browser.open(APP);
      await browser.close();
      const shared = browser.device(APP);
      browser.storage(APP).local.clear();

      browser.open(APP);
      expect(browser.device(APP)).toEqual(shared);
    });

    it('keeps a device in a shape it would not accept back, without offering it, and still adopts a shared one', async () => {
      const { local } = browser.storage(APP);
      // An id in the shape an early version stored, spelled in pieces so it does not read as a key to a scanner.
      const older = ['0b9f6c1e', '6f0e', '4b53', '9a6d', '1c2f3a4b5c6d'].join('-');
      local.setItem(STORAGE_KEYS.device, older);
      local.setItem(STORAGE_KEYS.fetchSecret, 'f'.repeat(64));
      const app = browser.open(APP);
      expect(running(app).id).toBe(older);
      expect(cookieWrites(browser)).toEqual([]);
      await browser.close();

      browser.open('https://example.com/');
      await browser.close();
      const shared = browser.device('https://example.com/');
      browser.open(APP);
      expect(browser.device(APP)).toEqual(shared);
    });
  });

  describe('where it is switched off', () => {
    const cases: Array<[string, Partial<TreebarsWebConfig>, ((sdk: TreebarsWeb) => void) | undefined]> = [
      ['disableStorage', { disableStorage: true }, undefined],
      ['a visitor who opted out', {}, (sdk) => sdk.optOut()],
      ['shareAcrossSubdomains: false', { shareAcrossSubdomains: false }, undefined],
    ];

    for (const [name, config, before] of cases) {
      it(`${name}: writes no cookie where there is none`, async () => {
        const sdk = browser.open('https://app.example.com/', config, before);
        sdk.track('viewed');
        await browser.close();
        // Not the device cookie, and not the moment's cookie that finding its domain sets.
        expect(browser.jar.writes).toEqual([]);
      });

      it(`${name}: reads none, and leaves one another subdomain set exactly as it is`, async () => {
        browser.open('https://example.com/');
        await browser.close();
        const shared = browser.device('https://example.com/');
        const before_ = { writes: browser.jar.writes.length, cookies: browser.jar.all() };

        vi.setSystemTime(NOW + 30 * DAY);
        const sdk = browser.open('https://app.example.com/', config, before);
        expect(running(sdk).id).toMatch(DEVICE);
        expect(running(sdk).id).not.toBe(shared.id);
        expect(running(sdk).secret).not.toBe(shared.secret);
        await browser.close();
        // Not read, not renewed, not removed.
        expect(browser.jar.writes).toHaveLength(before_.writes);
        expect(browser.jar.all()).toEqual(before_.cookies);
      });
    }

    it('shareAcrossSubdomains: false keeps a device of its own in storage, and its wipe leaves the cookie', async () => {
      browser.open('https://example.com/');
      await browser.close();
      const shared = browser.device('https://example.com/');

      const sdk = browser.open('https://app.example.com/', { shareAcrossSubdomains: false });
      const own = browser.device('https://app.example.com/');
      expect(own.id).toMatch(DEVICE);
      expect(own.id).not.toBe(shared.id);
      sdk.wipeLocalData();
      expect(browser.device('https://app.example.com/').id).not.toBe(own.id);
      expect(browser.shared()).toEqual(shared);
    });

    it('keeps the cookie through optOut, which stops without forgetting, and neither reads nor renews it after', async () => {
      const sdk = browser.open('https://example.com/');
      const shared = browser.device('https://example.com/');
      sdk.optOut();
      await browser.close();
      // As the device id in storage is: still there.
      expect(browser.device('https://example.com/')).toEqual(shared);
      expect(browser.shared()).toEqual(shared);

      const writes = browser.jar.writes.length;
      vi.setSystemTime(NOW + 30 * DAY);
      const next = browser.open('https://example.com/');
      expect(next.isOptedOut()).toBe(true);
      expect(running(next).id).not.toBe(shared.id);
      expect(browser.jar.writes).toHaveLength(writes);
      expect(browser.jar.named('tbrs_dv_live')[0]!.expiresAt).toBe(NOW + 400 * DAY);
    });
  });

  describe('wipeLocalData', () => {
    it('removes the device from the cookie, and the next init is a device nobody has seen', async () => {
      const sdk = browser.open('https://example.com/');
      const first = browser.device('https://example.com/');
      sdk.wipeLocalData();

      // The old pair is nowhere: not in storage, not in the cookie.
      const second = browser.device('https://example.com/');
      expect(second.id).toMatch(DEVICE);
      expect(second.id).not.toBe(first.id);
      expect(second.secret).not.toBe(first.secret);
      expect(browser.jar.all().some((cookie) => cookie.value.includes(first.id!) || cookie.value.includes(first.secret!))).toBe(false);
      // Expired wherever it could have been set, before the new one was written.
      const expired = cookieWrites(browser).map((write) => write.text).filter((text) => text.includes('Max-Age=0'));
      expect(expired).toEqual(['tbrs_dv_live=; Domain=example.com; Max-Age=0; Path=/', 'tbrs_dv_live=; Max-Age=0; Path=/']);
      await browser.close();

      const next = browser.open('https://example.com/');
      expect(running(next)).toEqual(second);
      expect(browser.shared()).toEqual(second);
    });

    it('moves the other subdomains to the new device, instead of one of them offering the forgotten one again', async () => {
      browser.open('https://example.com/');
      await browser.close();
      browser.open('https://app.example.com/');
      await browser.close();
      const forgotten = browser.device('https://app.example.com/');
      expect(forgotten).toEqual(browser.device('https://example.com/'));

      browser.open('https://example.com/').wipeLocalData();
      await browser.close();
      const fresh = browser.device('https://example.com/');

      // The app still holds the forgotten device in its own storage, and loads next.
      browser.open('https://app.example.com/');
      await browser.close();
      expect(browser.device('https://app.example.com/')).toEqual(fresh);
      browser.open('https://example.com/');
      expect(browser.device('https://example.com/')).toEqual(fresh);
      expect(browser.shared()!.id).not.toBe(forgotten.id);
    });

    it('asked before init, removes the cookie under both names, and init then mints a new device', async () => {
      browser.open('https://example.com/');
      await browser.close();
      browser.open('https://staging.example.com/', { writeKey: 'pk_test_staging' });
      await browser.close();
      const first = browser.device('https://example.com/');
      expect(browser.jar.all().map((cookie) => cookie.name).sort()).toEqual(['tbrs_dv_live', 'tbrs_dv_test']);

      const sdk = browser.open('https://example.com/', {}, (instance) => {
        instance.wipeLocalData();
        expect(browser.jar.all()).toEqual([]);
        expect(browser.device('https://example.com/')).toEqual({ id: null, secret: null });
      });
      expect(running(sdk).id).toMatch(DEVICE);
      expect(running(sdk).id).not.toBe(first.id);
      expect(browser.shared()).toEqual(running(sdk));
    });

    it('for a visitor who also opted out, removes the cookie and writes none back', async () => {
      const sdk = browser.open('https://example.com/');
      sdk.optOut();
      sdk.wipeLocalData();
      expect(browser.jar.all()).toEqual([]);
      expect(browser.device('https://example.com/')).toEqual({ id: null, secret: null });
    });
  });

  describe('a browser that refuses the parent domain', () => {
    it('keeps the cookie on the site’s own name under a public suffix, so two tenants of one suffix are not joined', async () => {
      browser.open('https://ada.github.io/');
      await browser.close();
      browser.open('https://grace.github.io/');
      await browser.close();

      expect(browser.device('https://grace.github.io/').id).not.toBe(browser.device('https://ada.github.io/').id);
      expect(browser.jar.named('tbrs_dv_live').map((cookie) => cookie.domain).sort()).toEqual(['ada.github.io', 'grace.github.io']);
      // And each still works: the same device on the next load.
      const ada = browser.device('https://ada.github.io/');
      browser.open('https://ada.github.io/');
      expect(browser.device('https://ada.github.io/')).toEqual(ada);
    });

    it('falls back to a host-only cookie on a host with no parent to share with, and still works', async () => {
      for (const href of ['http://localhost:5173/', 'http://192.168.1.20:8080/']) {
        const sdk = browser.open(href, { writeKey: 'pk_test_local' });
        const own = browser.device(href);
        expect(own.id).toMatch(DEVICE);
        expect(running(sdk)).toEqual(own);
        await browser.close();
        const host = new URL(href).hostname;
        expect(browser.jar.named('tbrs_dv_test').filter((cookie) => cookie.domain === host)).toMatchObject([{ value: `${own.id}.${own.secret}`, hostOnly: true, secure: false }]);

        // The same device on the next load — from the cookie alone, with this origin's storage gone.
        browser.storage(href).local.clear();
        browser.open(href, { writeKey: 'pk_test_local' });
        expect(browser.device(href)).toEqual(own);
        await browser.close();
      }
    });

    it('still runs, on a device of its own, in a browser that keeps no cookie at all', async () => {
      const refusing = new Browser(new CookieJar());
      vi.spyOn(refusing.jar, 'set').mockImplementation(() => undefined);
      const sdk = refusing.open('https://example.com/');
      const own = refusing.device('https://example.com/');
      expect(own.id).toMatch(DEVICE);
      expect(running(sdk)).toEqual(own);
      await refusing.close();

      const next = refusing.open('https://example.com/');
      expect(running(next)).toEqual(own);
      await refusing.close();
    });
  });

  describe('a cookie value that is not a device', () => {
    const id = `dev_${'ab12'.repeat(8)}`;
    const secret = 'cd34'.repeat(16);
    const malformed: Array<[string, string]> = [
      ['words', 'garbage'],
      ['empty', ''],
      ['an id with no secret', id],
      ['a secret one character short', `${id}.${secret.slice(1)}`],
      ['a secret one character long', `${id}.${secret}0`],
      ['an id in capitals', `${id.toUpperCase()}.${secret}`],
      ['an id without its prefix', `${'ab12'.repeat(8)}.${secret}`],
      ['an id that is not hex', `dev_${'zz12'.repeat(8)}.${secret}`],
      ['a third part', `${id}.${secret}.${secret}`],
      ['markup', `${id}.<script>alert(1)</script>`],
      ['a pair with a space in it', `${id}. ${secret.slice(1)}`],
    ];

    for (const [name, value] of malformed) {
      it(`ignores and replaces ${name}`, async () => {
        browser.jar.set('https://example.com/', `tbrs_dv_live=${value}; Domain=example.com; Max-Age=34560000; Path=/; SameSite=Lax; Secure`);
        const sdk = browser.open('https://app.example.com/');
        const own = browser.device('https://app.example.com/');
        expect(own.id).toMatch(DEVICE);
        expect(own.secret).toMatch(SECRET);
        expect(own.id).not.toBe(id);
        expect(own.secret).not.toBe(secret);
        expect(running(sdk)).toEqual(own);
        // Replaced, on the same domain: one cookie, holding this origin's pair.
        expect(browser.jar.named('tbrs_dv_live')).toMatchObject([{ value: `${own.id}.${own.secret}`, domain: 'example.com' }]);
      });
    }

    it('does not move an origin off the device it has', async () => {
      browser.open('https://app.example.com/');
      await browser.close();
      const own = browser.device('https://app.example.com/');
      // Something on the site cut the cookie short.
      browser.jar.set('https://example.com/', `tbrs_dv_live=${own.id}.${own.secret!.slice(0, 40)}; Domain=example.com; Max-Age=34560000; Path=/`);

      browser.requests = [];
      browser.open('https://app.example.com/');
      expect(browser.device('https://app.example.com/')).toEqual(own);
      expect(browser.shared()).toEqual(own);
    });

    it('passes over a malformed value to a valid one set at another domain', async () => {
      // A valid pair on the parent, and junk under the same name on the page's own host.
      browser.jar.set('https://app.example.com/', 'tbrs_dv_live=garbage; Max-Age=34560000; Path=/');
      browser.jar.set('https://example.com/', `tbrs_dv_live=${OTHER.id}.${OTHER.secret}; Domain=example.com; Max-Age=34560000; Path=/`);
      browser.open('https://app.example.com/');
      expect(browser.device('https://app.example.com/')).toEqual(OTHER);
    });
  });
});
