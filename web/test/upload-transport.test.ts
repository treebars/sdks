import { randomBytes } from 'node:crypto';
import { gunzipSync } from 'node:zlib';

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { STORAGE_KEYS } from '../src/generated/constants';
import { TreebarsWeb } from '../src/index';

/**
 * The half of uploading the shared scenarios cannot reach: what `TreebarsWeb` does with a real
 * `fetch`, a real `setTimeout` and a page that can be hidden. The scenarios pin the policy;
 * these pin that the browser glue hands it what it needs — the `Retry-After` header, a wake at
 * the moment a retry falls due, `keepalive` only where the browser allows it, a batch gzipped when
 * it is worth it, and a page-hide upload that sends the pending batch rather than a new one, the
 * way a flush sends it and without credentials.
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

interface Sent {
  url: string;
  init: RequestInit;
  body: { batch_id: string; sent_at: string; events: Array<{ event_id: string; event_name: string }> };
}

const pendingState = () =>
  JSON.parse(localStorage.getItem(STORAGE_KEYS.uploader) ?? '{"pending":[]}') as {
    pending: Array<{ batch_id: string }>;
    next_allowed_at: number;
  };

describe('the browser transport under the upload policy', () => {
  let sent: Sent[];
  let answers: Array<() => Promise<Response>>;
  let beaconCalls: number;
  let page: EventTarget & { visibilityState: string; title: string; referrer: string };
  let sdk: TreebarsWeb;

  beforeEach(() => {
    vi.useFakeTimers({ now: Date.parse('2026-09-15T12:00:00.000Z') });
    // The jitter's only randomness: half the ceiling, so the first backoff is exactly a second.
    vi.spyOn(Math, 'random').mockReturnValue(0.5);
    vi.stubGlobal('localStorage', memoryStorage());
    vi.stubGlobal('sessionStorage', memoryStorage());

    sent = [];
    answers = [];
    beaconCalls = 0;

    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string, init: RequestInit) => {
        const headers = (init.headers ?? {}) as Record<string, string>;
        const text =
          headers['Content-Encoding'] === 'gzip'
            ? gunzipSync(Buffer.from(init.body as ArrayBuffer)).toString('utf8')
            : String(init.body);
        sent.push({ url, init, body: JSON.parse(text) as Sent['body'] });
        const answer = answers.shift();
        if (!answer) throw new Error(`unexpected request to ${url}`);
        return answer();
      }),
    );
    vi.stubGlobal('navigator', {
      userAgent: 'vitest',
      language: 'en-GB',
      // Present, so using it would be seen: it always sends credentials, which the ingest endpoint does not grant.
      sendBeacon: () => {
        beaconCalls += 1;
        return true;
      },
    });
    page = Object.assign(new EventTarget(), { visibilityState: 'visible', title: 'Test', referrer: '' });
    vi.stubGlobal('document', page);
    vi.stubGlobal(
      'window',
      Object.assign(new EventTarget(), {
        screen: { width: 1280, height: 800 },
        devicePixelRatio: 1,
        location: { pathname: '/', href: 'https://shop.test/', origin: 'https://shop.test' },
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
      writeKey: 'pk_test_transport',
      backendUrl: 'https://ingest.test',
      autoPageViews: false,
      autoLifecycle: false,
      autoSessions: false,
      flushIntervalMs: 60 * 60 * 1000,
    });

  const hide = () => {
    page.visibilityState = 'hidden';
    page.dispatchEvent(new Event('visibilitychange'));
  };

  it('reads Retry-After off the response and wakes exactly when it falls due, resending the same batch', async () => {
    answers.push(async () => new Response(null, { status: 503, headers: { 'Retry-After': '5' } }));
    start();
    await vi.advanceTimersByTimeAsync(0);

    expect(sent).toHaveLength(1);
    const first = sent[0]!.body;
    expect(pendingState().next_allowed_at).toBe(Date.now() + 5000);

    // Without the wake nothing would send it: the spacing configured above is an hour, and no event is logged.
    answers.push(async () => new Response('{}', { status: 200 }));
    await vi.advanceTimersByTimeAsync(4999);
    expect(sent).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(1);

    expect(sent).toHaveLength(2);
    expect(sent[1]!.body).toEqual(first);
    expect(pendingState().pending).toEqual([]);
  });

  it('sets keepalive only on a body the browser will accept with it, measured as it is sent', async () => {
    answers.push(async () => new Response('{}', { status: 200 }));
    start();
    await vi.advanceTimersByTimeAsync(0);
    expect(sent[0]!.init.keepalive).toBe(true);

    // Over 64 KiB a keepalive request fails before it leaves the browser, so it must go without.
    // Random bytes, because it is the compressed size that is measured and these barely compress.
    sdk.track('large', { blob: randomBytes(100_000).toString('base64') });
    answers.push(async () => new Response('{}', { status: 200 }));
    await sdk.flush();
    expect(sent[1]!.body.events.map((each) => each.event_name)).toEqual(['large']);
    expect(sent[1]!.init.keepalive).toBe(false);

    // Seventy kilobytes that compress to almost nothing fit the quota, measured compressed.
    sdk.track('repetitive', { blob: 'x'.repeat(70_000) });
    answers.push(async () => new Response('{}', { status: 200 }));
    await sdk.flush();
    expect(sent[2]!.init.keepalive).toBe(true);
  });

  it('gzips a batch worth compressing and sends a short one as it is', async () => {
    answers.push(async () => new Response('{}', { status: 200 }));
    start();
    await vi.advanceTimersByTimeAsync(0);
    const short = sent[0]!;
    expect((short.init.headers as Record<string, string>)['Content-Encoding']).toBeUndefined();
    expect(typeof short.init.body).toBe('string');

    sdk.track('checkout_viewed', { items: Array.from({ length: 40 }, (_, i) => `sku_${i}`) });
    for (let i = 0; i < 20; i += 1) sdk.track('screen_view', { screen: `step_${i}` });
    answers.push(async () => new Response('{}', { status: 200 }));
    await sdk.flush();
    const long = sent[1]!;
    expect((long.init.headers as Record<string, string>)['Content-Encoding']).toBe('gzip');
    expect((long.init.body as ArrayBuffer).byteLength).toBeLessThan(JSON.stringify(long.body).length / 2);
  });

  it('sends plainly while the page is hidden, where it cannot wait for a compression', async () => {
    answers.push(async () => new Response('{}', { status: 200 }));
    start();
    await vi.advanceTimersByTimeAsync(0);

    page.visibilityState = 'hidden';
    sdk.track('large', { blob: 'x'.repeat(10_000) });
    answers.push(async () => new Response('{}', { status: 200 }));
    await sdk.flush();
    expect((sent[1]!.init.headers as Record<string, string>)['Content-Encoding']).toBeUndefined();
  });

  const headersOf = (entry: Sent) => entry.init.headers as Record<string, string>;

  it('sends the gzip copy a flush already made of the pending batch on page hide, naming it in a header', async () => {
    answers.push(async () => new Response('{}', { status: 200 }));
    start();
    await vi.advanceTimersByTimeAsync(0);

    sdk.track('large', { blob: 'x'.repeat(10_000) });
    answers.push(async () => {
      throw new TypeError('Failed to fetch');
    });
    await sdk.flush();
    const pending = sent[1]!.body;
    vi.setSystemTime(pendingState().next_allowed_at);

    answers.push(async () => new Response('{}', { status: 200 }));
    hide();

    expect(sent).toHaveLength(3);
    expect(sent[2]!.url).toBe('https://ingest.test/v1/events');
    expect(headersOf(sent[2]!)['Content-Encoding']).toBe('gzip');
    expect(sent[2]!.body).toEqual(pending);
  });

  it('sends the pending batch on page hide as a flush does, without credentials, and keeps it until a flush is answered', async () => {
    answers.push(async () => {
      throw new TypeError('Failed to fetch');
    });
    start();
    await vi.advanceTimersByTimeAsync(0);
    const pending = sent[0]!.body;
    const gate = pendingState().next_allowed_at;
    expect(gate).toBe(Date.now() + 1000);

    // Moved without running timers, so the retry wake armed for this moment does not fire first.
    vi.setSystemTime(gate);
    answers.push(async () => new Response('{}', { status: 200 }));
    hide();

    /*
     * No `sendBeacon`: a beacon always carries credentials, its JSON body is preflighted, and the ingest endpoint grants
     * no credentials, so a browser refuses it. So: the flush's URL, its headers and no credentials — the same preflight
     * cache entry the page already holds.
     */
    expect(beaconCalls).toBe(0);
    expect(sent).toHaveLength(2);
    expect(sent[1]!.url).toBe('https://ingest.test/v1/events');
    expect(sent[1]!.init).toMatchObject({ method: 'POST', credentials: 'omit', keepalive: true });
    expect(headersOf(sent[1]!)).toMatchObject({ 'Content-Type': 'application/json', 'X-Treebars-Key': 'pk_test_transport' });
    expect(headersOf(sent[1]!)['X-Treebars-Device-Auth']).toBeTruthy();
    expect(sent[1]!.body).toEqual(pending);
    // Its answer is never read, so nothing it carried has been acknowledged.
    await vi.advanceTimersByTimeAsync(0);
    expect(pendingState().pending.map((each) => each.batch_id)).toEqual([pending.batch_id]);

    answers.push(async () => new Response('{}', { status: 200 }));
    await sdk.flush();
    expect(sent.at(-1)!.body).toEqual(pending);
    expect(pendingState().pending).toEqual([]);
  });

  it('sends nothing more on page hide while a flush is in flight, because that request is already the last chance', async () => {
    let answer!: (response: Response) => void;
    answers.push(() => new Promise<Response>((resolve) => (answer = resolve)));
    start();
    await vi.advanceTimersByTimeAsync(0);
    expect(sent).toHaveLength(1);

    hide();
    expect(sent).toHaveLength(1);

    answer(new Response('{}', { status: 200 }));
    await vi.advanceTimersByTimeAsync(0);
    expect(pendingState().pending).toEqual([]);
  });

  it('keeps the batch, and throws nothing into the page, when the page-hide upload fails', async () => {
    answers.push(async () => new Response(null, { status: 500 }));
    start();
    await vi.advanceTimersByTimeAsync(0);
    const gate = pendingState().next_allowed_at;
    vi.setSystemTime(gate);

    answers.push(async () => {
      throw new TypeError('Failed to fetch');
    });
    hide();
    await vi.advanceTimersByTimeAsync(0);
    expect(sent).toHaveLength(2);
    expect(pendingState().pending).toHaveLength(1);
  });
});
