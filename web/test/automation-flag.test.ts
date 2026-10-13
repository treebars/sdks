import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { STORAGE_KEYS } from '../src/generated/constants';
import { TreebarsWeb } from '../src/index';

/**
 * A browser that automation is driving says so on what it sends, and a person's says nothing.
 *
 * Both halves matter. The flag is how a project leaves its test runs and crawlers out of its numbers, so
 * it has to be on every body that can make a person: an upload, a sign-in, a recorded visit. And it has
 * to be ABSENT rather than false from everybody else, because a field on every request of every visitor
 * would be one more thing sent for no reason. The SDK itself carries on either way: a team's own browser
 * test has to be able to watch a message being drawn.
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

describe('the automation flag', () => {
  let bodies: { url: string; body: Record<string, unknown> }[];
  let status: number;
  let sdk: TreebarsWeb;

  function page(webdriver: boolean | undefined) {
    vi.stubGlobal('navigator', { userAgent: 'vitest', language: 'en-GB', ...(webdriver === undefined ? {} : { webdriver }) });
  }

  beforeEach(() => {
    vi.useFakeTimers({ now: Date.parse('2026-10-09T12:00:00.000Z') });
    vi.stubGlobal('localStorage', memoryStorage());
    vi.stubGlobal('sessionStorage', memoryStorage());
    bodies = [];
    status = 200;
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string, init: RequestInit = {}) => {
        if (init.method === 'POST') bodies.push({ url, body: JSON.parse(String(init.body)) as Record<string, unknown> });
        return new Response('{}', { status, headers: status === 503 ? { 'Retry-After': '60' } : {} });
      }),
    );
    const document = Object.assign(new EventTarget(), { visibilityState: 'visible', title: 'Test', referrer: '', cookie: '' });
    vi.stubGlobal('document', document);
    vi.stubGlobal(
      'window',
      Object.assign(new EventTarget(), {
        screen: { width: 1280, height: 800 },
        devicePixelRatio: 1,
        location: { pathname: '/', href: 'https://shop.test/', origin: 'https://shop.test', hostname: 'shop.test' },
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

  const start = () =>
    sdk.init({
      writeKey: 'pk_test_automation',
      backendUrl: 'https://ingest.test',
      autoPageViews: false,
      autoLifecycle: false,
      autoSessions: false,
      inAppEnabled: false,
      flushIntervalMs: 60 * 60 * 1000,
    });

  const sentTo = (path: string) => bodies.filter((sent) => sent.url === `https://ingest.test${path}`).map((sent) => sent.body);

  it('is on an automated browser’s uploads and sign-ins, and the SDK works as it always does', async () => {
    page(true);
    start();
    sdk.track('checkout_viewed');
    await sdk.flush();
    sdk.identify('user-1');
    await vi.advanceTimersByTimeAsync(0);

    const uploads = sentTo('/v1/events');
    expect(uploads.length).toBeGreaterThan(0);
    for (const upload of uploads) expect(upload.automated).toBe(true);
    // The events are all there: saying what it is does not make the SDK do less.
    expect(uploads.flatMap((upload) => (upload.events as { event_name: string }[]).map((event) => event.event_name))).toContain('checkout_viewed');

    const [signIn] = sentTo('/v1/identify');
    expect(signIn).toMatchObject({ user_id: 'user-1', automated: true });
  });

  it.each([[false], [undefined]])('is absent, not false, from a browser that reports %s', async (webdriver) => {
    page(webdriver);
    start();
    sdk.track('checkout_viewed');
    await sdk.flush();
    sdk.identify('user-1');
    await vi.advanceTimersByTimeAsync(0);

    const all = [...sentTo('/v1/events'), ...sentTo('/v1/identify')];
    expect(all.length).toBeGreaterThan(1);
    for (const body of all) expect(body).not.toHaveProperty('automated');
  });

  /* A batch is stored and resent as it was sealed. The flag is the sending page's, so it is never stored with it. */
  it('is added as a batch is sent, never kept in the stored batch', async () => {
    page(true);
    // Refused, so the batch stays stored for a resend: the one moment there is a stored batch to look at.
    status = 503;
    start();
    sdk.track('checkout_viewed');
    await sdk.flush();

    expect(sentTo('/v1/events')[0]).toMatchObject({ automated: true });
    const stored = localStorage.getItem(STORAGE_KEYS.uploader) ?? '';
    expect((JSON.parse(stored) as { pending: unknown[] }).pending).toHaveLength(1);
    expect(stored).not.toContain('automated');
  });
});
