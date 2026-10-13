import { gunzipSync } from 'node:zlib';

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { TreebarsWeb } from '../src/index';

/**
 * What a session says about how its visit began: the page it opened on, and the page before it.
 *
 * The two facts a visit's source is worked out from, sent once, on `session_start`. Three things are pinned,
 * each of which is wrong silently. The referrer belongs to a session that ARRIVES with the page — a session
 * that opens later in the same document did not come from that page again, and saying it did would credit
 * one search with every return to an open tab. A page that loads inside a running session opens none, so its
 * referrer is not a visit's. And both values are trimmed as a page view's are: a referrer is another page's
 * address, and its query is where that page keeps what it was handed.
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

const HALF_AN_HOUR = 30 * 60 * 1000;

describe('a session’s landing', () => {
  let sent: Array<{ event_name: string; session_id: string; properties: Record<string, unknown> }>;
  let sdk: TreebarsWeb;
  let local: ReturnType<typeof memoryStorage>;

  /** A page load: a document with its referrer and an address, in the same browser (the same storage). */
  function load(href: string, referrer: string) {
    const url = new URL(href);
    vi.stubGlobal('document', Object.assign(new EventTarget(), { visibilityState: 'visible', title: 'Test', referrer, cookie: '' }));
    vi.stubGlobal(
      'window',
      Object.assign(new EventTarget(), {
        screen: { width: 1280, height: 800 },
        devicePixelRatio: 1,
        location: { pathname: url.pathname, href, origin: url.origin, hostname: url.hostname },
      }),
    );
    sdk = new TreebarsWeb();
    sdk.init({
      writeKey: 'pk_test_landing',
      backendUrl: 'https://ingest.test',
      autoPageViews: false,
      autoLifecycle: false,
      inAppEnabled: false,
      flushIntervalMs: 60 * 60 * 1000,
    });
  }

  const sessionStarts = () => sent.filter((event) => event.event_name === 'session_start');

  beforeEach(() => {
    vi.useFakeTimers({ now: Date.parse('2026-10-09T12:00:00.000Z') });
    local = memoryStorage();
    vi.stubGlobal('localStorage', local);
    vi.stubGlobal('sessionStorage', memoryStorage());
    vi.stubGlobal('navigator', { userAgent: 'vitest', language: 'en-GB' });
    sent = [];
    vi.stubGlobal(
      'fetch',
      vi.fn(async (_url: string, init: RequestInit = {}) => {
        if (init.method === 'POST' && init.body) {
          // A batch worth compressing goes out gzipped; a short one as it is.
          const gzipped = ((init.headers ?? {}) as Record<string, string>)['Content-Encoding'] === 'gzip';
          const text = gzipped ? gunzipSync(Buffer.from(init.body as ArrayBuffer)).toString('utf8') : String(init.body);
          const body = JSON.parse(text) as { events?: typeof sent };
          sent.push(...(body.events ?? []));
        }
        return new Response('{}', { status: 200 });
      }),
    );
  });

  afterEach(() => {
    sdk.shutdown();
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it('is the page it opened on and the page before it, when the session arrives with the page', async () => {
    load('https://shop.test/pricing?utm_source=newsletter&utm_medium=email&token=secret#plans', 'https://www.google.com/search?q=private+words');
    sdk.track('pricing_viewed');
    await sdk.flush();

    expect(sessionStarts()).toHaveLength(1);
    expect(sessionStarts()[0]!.properties).toMatchObject({
      // The campaign's labels stay, which is what the visit is credited by; a token on the address does not.
      url: 'https://shop.test/pricing?utm_source=newsletter&utm_medium=email',
      // Origin and path: what somebody searched for is that page's business.
      referrer: 'https://www.google.com/search',
    });
  });

  it('says so with an empty referrer when nothing sent the visit', async () => {
    load('https://shop.test/', '');
    sdk.track('home_viewed');
    await sdk.flush();
    expect(sessionStarts()[0]!.properties).toMatchObject({ url: 'https://shop.test/', referrer: '' });
  });

  /* The tab left for an hour and come back to. It did not arrive from the search again. */
  it('does not repeat the referrer for a session that opens later in the same document', async () => {
    load('https://shop.test/', 'https://www.google.com/');
    sdk.track('home_viewed');
    await sdk.flush();

    await vi.advanceTimersByTimeAsync(HALF_AN_HOUR + 1000);
    sdk.track('came_back');
    await sdk.flush();

    const [first, second] = sessionStarts();
    expect(first!.properties.referrer).toBe('https://www.google.com/');
    expect(second!.session_id).not.toBe(first!.session_id);
    expect(second!.properties).toMatchObject({ url: 'https://shop.test/', referrer: '' });
  });

  /*
   * A page loaded inside a running session opens no session, so its referrer is nobody's landing — and when that
   * document's session later runs out, the one that replaces it did not arrive from that page either.
   */
  it('is not taken from a page that loaded inside a running session', async () => {
    load('https://shop.test/', '');
    sdk.track('home_viewed');
    await sdk.flush();
    sdk.shutdown();

    load('https://shop.test/checkout', 'https://pay.example/return?order=1');
    sdk.track('checkout_viewed');
    await sdk.flush();
    expect(sessionStarts()).toHaveLength(1);

    await vi.advanceTimersByTimeAsync(HALF_AN_HOUR + 1000);
    sdk.track('came_back');
    await sdk.flush();
    expect(sessionStarts()).toHaveLength(2);
    expect(sessionStarts()[1]!.properties).toMatchObject({ url: 'https://shop.test/checkout', referrer: '' });
  });
});
