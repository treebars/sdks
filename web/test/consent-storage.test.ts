import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { carriedClick, rememberClick, SHARED_BROWSER_COOKIE } from '../src/acquisition';
import { STORAGE_KEYS } from '../src/generated/constants';
import { TreebarsWeb } from '../src/index';

/**
 * `disableStorage` is the switch a site flips before a visitor has consented, and its promise is
 * that nothing is written to the browser and nothing read back from it.
 *
 * Acquisition keeps it too. With storage off, a landing page from an ad writes no carried click to
 * localStorage, marks no `link_opened` as seen, sets no `tbrs_bs` cookie on the registrable domain,
 * and does not post the visit to `/v1/web-click` — the request that sends the browser id, time zone
 * and screen size an app install is matched against. The click on the page's own address is still
 * reported once, and nothing about it is kept.
 */

function memoryStorage() {
  const map = new Map<string, string>();
  return {
    map,
    getItem: (key: string) => map.get(key) ?? null,
    setItem: (key: string, value: string) => void map.set(key, value),
    removeItem: (key: string) => void map.delete(key),
    clear: () => map.clear(),
  };
}

/** Opened by one of our tracker links: the address carries our click id. */
const TRACKER_LANDING = 'https://shop.test/spring?tbrs_click_id=clk_abc12345';
/** Opened by an ad pointed straight at the site: the network's click id, and none of ours. */
const AD_LANDING = 'https://shop.test/spring?gclid=G-7&utm_source=google&utm_campaign=spring';

describe('a visit from an ad, with storage off', () => {
  let local: ReturnType<typeof memoryStorage>;
  let session: ReturnType<typeof memoryStorage>;
  let cookies: string[];
  let posted: { path: string; body: Record<string, unknown> }[];
  let sdk: TreebarsWeb | null;

  beforeEach(() => {
    vi.useFakeTimers({ now: Date.parse('2026-09-24T12:00:00.000Z') });
    local = memoryStorage();
    session = memoryStorage();
    cookies = [];
    posted = [];
    sdk = null;
    vi.stubGlobal('localStorage', local);
    vi.stubGlobal('sessionStorage', session);
    vi.stubGlobal('navigator', { userAgent: 'vitest', language: 'en-GB', sendBeacon: () => true });
    const document = Object.assign(new EventTarget(), { visibilityState: 'visible', title: 'Spring', referrer: '' });
    Object.defineProperty(document, 'cookie', {
      get: () => cookies.join('; '),
      set: (value: string) => void cookies.push(value.split(';')[0]!),
    });
    vi.stubGlobal('document', document);
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string, init: RequestInit = {}) => {
        posted.push({
          path: new URL(url).pathname,
          body: typeof init.body === 'string' ? (JSON.parse(init.body) as Record<string, unknown>) : {},
        });
        return Response.json({ recorded: true, click_id: 'clk_server0001', source: 'google', messages: [], triggers: [] });
      }),
    );
  });

  afterEach(() => {
    sdk?.shutdown();
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  function stubWindow(href: string): void {
    const url = new URL(href);
    vi.stubGlobal(
      'window',
      Object.assign(new EventTarget(), {
        screen: { width: 390, height: 844 },
        devicePixelRatio: 3,
        localStorage: local,
        location: { href: url.href, pathname: url.pathname, origin: url.origin, hostname: url.hostname, protocol: url.protocol },
      }),
    );
  }

  function start(href: string, disableStorage: boolean): TreebarsWeb {
    stubWindow(href);
    sdk = new TreebarsWeb();
    sdk.init({
      writeKey: 'pk_live_consent',
      backendUrl: 'https://ingest.test',
      autoPageViews: false,
      autoLifecycle: false,
      autoSessions: false,
      flushIntervalMs: 60 * 60 * 1000,
      disableStorage,
    });
    return sdk;
  }

  it('writes nothing, sets no cookie and records no click', async () => {
    const instance = start(AD_LANDING, true);
    await vi.advanceTimersByTimeAsync(0);
    await instance.flush();

    expect([...local.map.keys()], 'localStorage').toEqual([]);
    expect([...session.map.keys()], 'sessionStorage').toEqual([]);
    expect(cookies.filter((cookie) => cookie.startsWith(`${SHARED_BROWSER_COOKIE}=`))).toEqual([]);
    expect(posted.map((each) => each.path)).not.toContain('/v1/web-click');
  });

  it('still reports the arrival, once, from the click on its own address, and remembers nothing', async () => {
    const instance = start(TRACKER_LANDING, true);
    await vi.advanceTimersByTimeAsync(0);
    await instance.flush();

    const opened = posted
      .flatMap((each) => (each.body.events ?? []) as { event_name: string; properties: Record<string, unknown> }[])
      .filter((event) => event.event_name === 'link_opened');
    expect(opened.map((event) => event.properties.click_id)).toEqual(['clk_abc12345']);
    expect([...local.map.keys()], 'localStorage').toEqual([]);
  });

  it('reads the click off the page, and neither remembers it nor reads one back', () => {
    stubWindow(TRACKER_LANDING);
    expect(carriedClick(TRACKER_LANDING, false)?.clickId).toBe('clk_abc12345');
    rememberClick({ clickId: 'clk_zzz99999', deepLinkPath: null }, false);
    expect(local.map.has(STORAGE_KEYS.acquisitionClick)).toBe(false);

    local.setItem(STORAGE_KEYS.acquisitionClick, JSON.stringify({ clickId: 'clk_stored0001', deepLinkPath: null }));
    expect(carriedClick('https://shop.test/features', false)).toBeNull();
    expect(carriedClick('https://shop.test/features', true)?.clickId).toBe('clk_stored0001');
  });

  it('with storage on, remembers the click and records a visit from an ad as before', async () => {
    const instance = start(AD_LANDING, false);
    await vi.advanceTimersByTimeAsync(0);
    await instance.flush();

    expect(posted.map((each) => each.path)).toContain('/v1/web-click');
    expect(cookies.some((cookie) => cookie.startsWith(`${SHARED_BROWSER_COOKIE}=`))).toBe(true);
    expect(local.map.has(STORAGE_KEYS.acquisitionClick)).toBe(true);
  });
});
