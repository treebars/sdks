import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { TreebarsWeb } from '../src/index';
import type { InAppMessage } from '../src/in-app';

/**
 * A dimension row on a real draw: `track` stamps the event with its dimensions and hands the SAME object to the
 * in-app evaluator, so a trigger reads what the stored row will hold. `in-app-filters.test.ts` pins the evaluator;
 * this pins the wiring — that `considerInApp` is handed the map at all, and the one the event went out with rather
 * than a second read.
 */

function memoryStorage(): Storage {
  const map = new Map<string, string>();
  return {
    get length() {
      return map.size;
    },
    clear: () => map.clear(),
    getItem: (key) => map.get(key) ?? null,
    key: (index) => [...map.keys()][index] ?? null,
    removeItem: (key) => void map.delete(key),
    setItem: (key, value) => void map.set(key, String(value)),
  };
}

const message = (id: string, filter: Record<string, unknown>): InAppMessage => ({
  delivery_id: id,
  campaign_id: null,
  created_at: '2026-09-15T00:00:00.000Z',
  expires_at: null,
  content: {
    in_app: {
      surface: 'overlay',
      layout: 'modal',
      trigger: { kind: 'event', event_name: 'purchase', filters: [filter as never] },
    } as never,
  },
});

describe('a dimension row on a real draw', () => {
  let uploaded: Array<Record<string, unknown>>;
  let drawn: string[];
  let sdk: TreebarsWeb;

  beforeEach(() => {
    vi.useFakeTimers({ now: Date.parse('2026-09-15T12:00:00.000Z') });
    vi.stubGlobal('localStorage', memoryStorage());
    vi.stubGlobal('sessionStorage', memoryStorage());
    uploaded = [];
    drawn = [];
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string, init: RequestInit = {}) => {
        const path = new URL(url).pathname;
        if (path === '/v1/in-app') {
          return Response.json({
            messages: [
              message('on-ios', { key: 'platform_type', op: 'eq', value: 'ios', source: 'dimension' }),
              message('on-web', { key: 'platform_type', op: 'eq', value: 'web', source: 'dimension' }),
            ],
            policy: null,
            server_time: 'now',
          });
        }
        if (path === '/v1/events' && typeof init.body === 'string') {
          uploaded.push(...(JSON.parse(init.body) as { events: Array<Record<string, unknown>> }).events);
        }
        return new Response('{}', { status: 200 });
      }),
    );
    // Uncompressed, so the upload's body can be read back: Node has `CompressionStream`, and a batch past
    // the gzip threshold would otherwise go out as bytes.
    vi.stubGlobal('CompressionStream', undefined);
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
  });

  afterEach(() => {
    sdk.shutdown();
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it('draws the message whose dimension row the stamped event satisfies, and not the other', async () => {
    sdk.init({
      writeKey: 'pk_test_dimensions',
      backendUrl: 'https://ingest.test',
      inAppEnabled: true,
      autoPageViews: false,
      autoLifecycle: false,
      flushIntervalMs: 60 * 60 * 1000,
    });
    sdk.setInAppRenderer(({ message: shown }) => drawn.push(shown.delivery_id));
    sdk.track('app_open');
    await vi.advanceTimersByTimeAsync(0);

    // A property named like the dimension is not the dimension.
    sdk.track('purchase', { platform_type: 'ios' });
    expect(drawn).toEqual(['on-web']);

    await sdk.flush();
    const purchase = uploaded.find((event) => event.event_name === 'purchase');
    expect(purchase?.platform_type).toBe('web');
    expect(purchase?.screen_name).toBe('Checkout');
  });
});
