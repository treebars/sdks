import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { TreebarsWeb, type InAppView } from '../src/index';
import type { InAppMessage } from '../src/in-app';

/**
 * A markup body naming a stored file that is gone (the asset manifest's `missing`) is a failed display with its
 * reason, `asset_download`, never one drawn with a hole in it — as on Android and iOS. A browser draws the files that
 * exist from its own cache, so this SDK prefetches nothing; `missing` is the one thing it reads.
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

const GONE = `https://api.treebars.test/assets/11111111-1111-4111-8111-111111111111/${'d'.repeat(64)}.png`;

const markup: InAppMessage = {
  delivery_id: 'markup',
  campaign_id: 'campaign-markup',
  created_at: '2026-09-28T00:00:00.000Z',
  expires_at: null,
  content: { in_app: { surface: 'overlay', layout: 'modal', body_mode: 'html', html: `<img src="${GONE}">`, trigger: { kind: 'event', event_name: 'product_view' } } as never },
  assets: { files: [], missing: [GONE] },
};

const standard: InAppMessage = {
  delivery_id: 'standard',
  campaign_id: 'campaign-standard',
  created_at: '2026-09-28T00:00:00.000Z',
  expires_at: null,
  content: { title: 'Sale', image_url: GONE, in_app: { surface: 'overlay', layout: 'modal', trigger: { kind: 'event', event_name: 'cart_view' } } as never },
  assets: { files: [], missing: [GONE] },
};

describe('a message whose store file is gone', () => {
  let tracked: Array<{ name: string; properties: Record<string, unknown> }>;
  let views: InAppView[];
  let sdk: TreebarsWeb;

  beforeEach(async () => {
    vi.useFakeTimers({ now: Date.parse('2026-09-28T12:00:00.000Z') });
    vi.stubGlobal('localStorage', memoryStorage());
    vi.stubGlobal('sessionStorage', memoryStorage());
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string) =>
        new URL(url).pathname === '/v1/in-app'
          ? Response.json({ messages: [markup, standard], policy: null, server_time: 'now' })
          : new Response('{}', { status: 200 }),
      ),
    );
    vi.stubGlobal('CompressionStream', undefined);
    vi.stubGlobal('navigator', { userAgent: 'vitest', language: 'en-GB', sendBeacon: () => true });
    vi.stubGlobal('document', Object.assign(new EventTarget(), { visibilityState: 'visible', title: 'Product', referrer: '' }));
    vi.stubGlobal(
      'window',
      Object.assign(new EventTarget(), {
        screen: { width: 1280, height: 800 },
        devicePixelRatio: 1,
        location: { pathname: '/', href: 'https://shop.test/', origin: 'https://shop.test' },
      }),
    );
    tracked = [];
    views = [];
    sdk = new TreebarsWeb();
    sdk.init({ writeKey: 'pk_test_assets', backendUrl: 'https://ingest.test', autoPageViews: false, autoLifecycle: false, flushIntervalMs: 60 * 60 * 1000 });
    const track = sdk.track.bind(sdk);
    vi.spyOn(sdk, 'track').mockImplementation((name, properties = {}) => {
      tracked.push({ name, properties });
      track(name, properties);
    });
    sdk.setInAppRenderer((view) => views.push(view));
    await sdk.syncInAppMessages();
  });

  afterEach(() => {
    sdk.shutdown();
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it('is not drawn when it is a markup body, and says why', () => {
    sdk.track('product_view');
    const failed = tracked.filter((event) => event.name === 'in_app_failed');
    expect(failed.map((event) => [event.properties.treebars_delivery_id, event.properties.reason])).toEqual([['markup', 'asset_download']]);
    expect(tracked.some((event) => event.name === 'in_app_displayed')).toBe(false);
  });

  it('is drawn as before when it is a standard body, whose picture is a placeholder the renderer keeps if it fails', () => {
    sdk.track('cart_view');
    expect(views).toHaveLength(1);
    expect(tracked.some((event) => event.name === 'in_app_failed')).toBe(false);
  });
});
