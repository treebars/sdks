import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { HEADERS, SESSION_TIMEOUT_MS } from '../src/generated/constants';
import { TreebarsWeb } from '../src/index';

/**
 * `contextToken()` in the browser: the page asks the ingest endpoint for a token before a purchase and hands it to whatever
 * will report it — the backend's `context.treebars`, Stripe's `metadata.treebars_context`. What it has to get right: that
 * the request proves this browser the way a sign-in does, that the session it names is the one the purchase will be in,
 * and that it never costs the page a purchase when the ingest endpoint is unreachable.
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
  url: URL;
  headers: Record<string, string>;
  body: Record<string, unknown>;
}

const TOKEN = '3f2a9c1e-7b4d-4e8a-9c21-5d6e7f809a1b';

describe('contextToken', () => {
  let seen: Seen[];
  let answer: (request: Seen) => Response;
  let sdk: TreebarsWeb;

  beforeEach(() => {
    vi.useFakeTimers({ now: Date.parse('2026-09-29T12:00:00.000Z') });
    vi.stubGlobal('localStorage', memoryStorage());
    vi.stubGlobal('sessionStorage', memoryStorage());
    vi.stubGlobal('CompressionStream', undefined);
    seen = [];
    answer = (request) =>
      request.url.pathname === '/v1/context-token'
        ? Response.json({ token: TOKEN.toUpperCase() }, { status: 201 })
        : Response.json({ messages: [], accepted: 1, rejected: 0, duplicates: 0 });
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string, init: RequestInit = {}) => {
        const request: Seen = {
          url: new URL(url),
          headers: (init.headers ?? {}) as Record<string, string>,
          body: typeof init.body === 'string' ? (JSON.parse(init.body) as Record<string, unknown>) : {},
        };
        seen.push(request);
        return answer(request);
      }),
    );
    vi.stubGlobal('navigator', { userAgent: 'vitest', language: 'en-GB', sendBeacon: () => true });
    vi.stubGlobal('document', Object.assign(new EventTarget(), { visibilityState: 'visible', title: 'Checkout', referrer: '' }));
    vi.stubGlobal(
      'window',
      Object.assign(new EventTarget(), {
        screen: { width: 1280, height: 800 },
        devicePixelRatio: 1,
        location: { pathname: '/', href: 'https://shop.test/', origin: 'https://shop.test' },
      }),
    );
    sdk = new TreebarsWeb();
    sdk.init({ writeKey: 'pk_live_ctx', backendUrl: 'https://ingest.test', autoPageViews: false, autoLifecycle: false, flushIntervalMs: 60 * 60 * 1000 });
  });

  afterEach(() => {
    sdk.shutdown();
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  const asked = () => seen.filter((request) => request.url.pathname === '/v1/context-token');
  const uploaded = async () => {
    await sdk.flush();
    return seen
      .filter((request) => request.url.pathname === '/v1/events')
      .flatMap((request) => (request.body.events as { event_name: string; session_id: string }[]) ?? []);
  };

  it('asks for this browser and the session its events are in, proving the browser as a sign-in does', async () => {
    sdk.track('checkout_started');
    const token = await sdk.contextToken();
    expect(token).toBe(TOKEN);

    const [request] = asked();
    const events = await uploaded();
    const session = events.find((event) => event.event_name === 'checkout_started')!.session_id;
    expect(request!.body).toEqual({ device_id: expect.stringMatching(/^dev_/), session_id: session });
    expect(request!.headers[HEADERS.writeKey]).toBe('pk_live_ctx');
    expect(request!.headers[HEADERS.deviceAuth]).toEqual(expect.any(String));
    expect(request!.headers[HEADERS.deviceAuth]).not.toBe('');
  });

  it('names the signed-in account, with the signature a live environment asks for', async () => {
    sdk.identify('user_42', {}, 'ab'.repeat(32));
    await sdk.contextToken();
    const [request] = asked();
    expect(request!.body).toMatchObject({ user_id: 'user_42' });
    expect(request!.headers[HEADERS.userSignature]).toBe('ab'.repeat(32));
  });

  /*
   * After half an hour away the purchase happens in a NEW session, so the token must name that one — and the old one
   * has to close and the new one open exactly as the next event would have made them. The token itself is not an event.
   */
  it('rolls an expired session over as an event would, and is not itself an event', async () => {
    sdk.track('product_view');
    vi.advanceTimersByTime(SESSION_TIMEOUT_MS + 1_000);
    await sdk.contextToken();
    sdk.track('purchase_confirmed');

    const events = await uploaded();
    const names = events.map((event) => event.event_name);
    expect(names.filter((name) => name === 'session_end')).toHaveLength(1);
    expect(names.filter((name) => name === 'session_start')).toHaveLength(2);
    const first = events.find((event) => event.event_name === 'product_view')!.session_id;
    const confirmed = events.find((event) => event.event_name === 'purchase_confirmed')!.session_id;
    expect(asked()[0]!.body.session_id).toBe(confirmed);
    expect(confirmed).not.toBe(first);
    const ended = events.find((event) => event.event_name === 'session_end') as unknown as { properties: { event_count: number } };
    // The first session's two events, `device_context` at start-up and `product_view`: the token added nothing.
    expect(ended.properties.event_count).toBe(2);
  });

  it('is null, never a throw, when ingest cannot make one — and when the browser opted out', async () => {
    answer = (request) => (request.url.pathname === '/v1/context-token' ? new Response('{}', { status: 503 }) : Response.json({}));
    expect(await sdk.contextToken()).toBeNull();
    answer = () => {
      throw new TypeError('Failed to fetch');
    };
    expect(await sdk.contextToken()).toBeNull();

    sdk.optOut();
    seen = [];
    expect(await sdk.contextToken()).toBeNull();
    expect(asked()).toHaveLength(0);
  });

  it('says once that the environment wants a signed identity, as identify does', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => undefined);
    answer = (request) =>
      request.url.pathname === '/v1/context-token' ? Response.json({ error: 'signature_required' }, { status: 403 }) : Response.json({});
    sdk.identify('user_42');
    expect(await sdk.contextToken()).toBeNull();
    expect(warn).toHaveBeenCalledWith(expect.stringMatching(/signed identity/));
  });
});
