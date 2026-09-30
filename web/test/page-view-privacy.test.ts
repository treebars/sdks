import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { TreebarsWeb } from '../src/index';

/**
 * What a page view says about the address it was made on (`src/page-url.ts`).
 *
 * The query and fragment of an address carry reset tokens, magic-link codes, OAuth grants and the
 * emails forms redirect with, so `page_view` keeps only the parameters it knows are safe. Every case
 * here names a secret that must not leave the page and a label that must, because attribution and
 * the campaign breakdowns read them.
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
  path: string;
  body: Record<string, unknown>;
}

const TOKEN = 'reset-5e3c7a9f1b';
const EMAIL = 'ada@example.com';

describe('the address a page view carries', () => {
  let seen: Seen[];
  let sdk: TreebarsWeb | null;

  function stubPage(href: string, referrer = ''): void {
    const url = new URL(href);
    vi.stubGlobal('document', Object.assign(new EventTarget(), { visibilityState: 'visible', title: 'Test', referrer }));
    vi.stubGlobal(
      'window',
      Object.assign(new EventTarget(), {
        screen: { width: 1280, height: 800 },
        devicePixelRatio: 1,
        location: { pathname: url.pathname, href: url.href, origin: url.origin, search: url.search, hash: url.hash },
      }),
    );
  }

  function start(extra: Record<string, unknown> = {}): TreebarsWeb {
    sdk = new TreebarsWeb();
    sdk.init({
      writeKey: 'pk_live_pages',
      backendUrl: 'https://ingest.test',
      autoPageViews: false,
      autoLifecycle: false,
      autoSessions: false,
      carryClickToStore: false,
      flushIntervalMs: 60 * 60 * 1000,
      ...extra,
    });
    return sdk;
  }

  async function pageView(instance: TreebarsWeb): Promise<Record<string, unknown>> {
    instance.page();
    await vi.advanceTimersByTimeAsync(0);
    await instance.flush();
    const event = seen
      .filter((each) => each.path === '/v1/events')
      .flatMap((each) => (each.body.events ?? []) as { event_name: string; properties: Record<string, unknown> }[])
      .find((each) => each.event_name === 'page_view');
    if (!event) throw new Error('no page_view was uploaded');
    return event.properties;
  }

  beforeEach(() => {
    vi.useFakeTimers({ now: Date.parse('2026-09-24T12:00:00.000Z') });
    vi.stubGlobal('localStorage', memoryStorage());
    vi.stubGlobal('sessionStorage', memoryStorage());
    vi.stubGlobal('navigator', { userAgent: 'vitest', language: 'en-GB', sendBeacon: () => true });
    seen = [];
    sdk = null;
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string, init: RequestInit = {}) => {
        seen.push({
          path: new URL(url).pathname,
          body: typeof init.body === 'string' ? (JSON.parse(init.body) as Record<string, unknown>) : {},
        });
        return Response.json({ recorded: false, messages: [], triggers: [] });
      }),
    );
  });

  afterEach(() => {
    sdk?.shutdown();
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it('keeps the campaign labels and click ids, and drops every other parameter and the fragment', async () => {
    stubPage(
      `https://shop.test/reset?token=${TOKEN}&email=${encodeURIComponent(EMAIL)}&utm_source=newsletter&utm_campaign=fall&gclid=G-1&tbrs_click_id=C-1#access_token=${TOKEN}`,
    );
    const properties = await pageView(start());

    expect(properties.url).toBe('https://shop.test/reset?utm_source=newsletter&utm_campaign=fall&gclid=G-1&tbrs_click_id=C-1');
    expect(properties.path).toBe('/reset');
    expect(JSON.stringify(properties)).not.toContain(TOKEN);
    expect(JSON.stringify(properties)).not.toContain('ada');
  });

  it("keeps a hash router's route, without the route's own query", async () => {
    stubPage(`https://shop.test/#/orders/42?token=${TOKEN}`);
    const properties = await pageView(start());

    expect(properties.url).toBe('https://shop.test/#/orders/42');
  });

  it('sends the referrer as origin and path', async () => {
    stubPage('https://shop.test/login', `https://shop.test/reset?token=${TOKEN}#code=${TOKEN}`);
    const properties = await pageView(start());

    expect(properties.referrer).toBe('https://shop.test/reset');
    expect(JSON.stringify(properties)).not.toContain(TOKEN);
  });

  it('keeps a parameter the site names in pageUrlParams, and no other', async () => {
    stubPage(`https://shop.test/pricing?plan=pro&token=${TOKEN}`);
    const properties = await pageView(start({ pageUrlParams: ['plan'] }));

    expect(properties.url).toBe('https://shop.test/pricing?plan=pro');
  });

  it("records an ad's visit from the labels it needs, not the page's secrets", async () => {
    stubPage(`https://shop.test/landing?gclid=G-2&utm_source=google&utm_campaign=fall&session=${TOKEN}`);
    start({ carryClickToStore: true });
    await vi.advanceTimersByTimeAsync(0);

    const click = seen.find((each) => each.path === '/v1/web-click');
    expect(click?.body.url).toBe('https://shop.test/landing?gclid=G-2&utm_source=google&utm_campaign=fall');
  });
});
