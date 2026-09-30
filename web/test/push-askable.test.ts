import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { TreebarsWeb, type InAppView } from '../src/index';
import type { InAppMessage } from '../src/in-app';
import { pushAskableBlock } from '../src/on-site';

/**
 * A push primer waits for people who can still be asked: held back — never spent — from a browser that already
 * allows push, refused it, or has nothing to ask with, and asked again at each look. The same words and the same
 * answer as the Android and iOS SDKs, from one generated list.
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

describe('who a primer is for', () => {
  it('answers the shared words as the Android and iOS SDKs do', () => {
    const primer = { only_when_push_askable: true };
    for (const status of ['not_determined', 'provisional', 'denied_askable']) expect(pushAskableBlock(primer, status), status).toBeNull();
    for (const status of ['authorized', 'ephemeral', 'denied', 'unsupported']) expect(pushAskableBlock(primer, status), status).toBe('push_answered');
    expect(pushAskableBlock({}, 'authorized')).toBeNull();
    expect(pushAskableBlock(undefined, 'authorized')).toBeNull();
  });
});

describe('a primer on a page', () => {
  let tracked: Array<{ name: string; properties: Record<string, unknown> }>;
  let views: InAppView[];
  let sdk: TreebarsWeb;
  let permission: NotificationPermission;

  const primer: InAppMessage = {
    delivery_id: 'primer',
    campaign_id: '9f0c7a52-1111-4a55-8a55-000000000001',
    created_at: '2026-09-15T00:00:00.000Z',
    expires_at: null,
    content: { title: 'Allow push', in_app: { surface: 'overlay', layout: 'modal', trigger: { kind: 'event', event_name: 'product_view' }, display: { only_when_push_askable: true } } as never },
  };

  beforeEach(async () => {
    vi.useFakeTimers({ now: Date.parse('2026-09-15T12:00:00.000Z') });
    vi.stubGlobal('localStorage', memoryStorage());
    vi.stubGlobal('sessionStorage', memoryStorage());
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string) =>
        new URL(url).pathname === '/v1/in-app' ? Response.json({ messages: [primer], policy: null, server_time: 'now' }) : new Response('{}', { status: 200 }),
      ),
    );
    vi.stubGlobal('CompressionStream', undefined);
    permission = 'granted';
    // A browser that can receive push: a worker, a push manager, and notifications whose answer the test sets.
    vi.stubGlobal('navigator', { userAgent: 'vitest', language: 'en-GB', sendBeacon: () => true, serviceWorker: {} });
    vi.stubGlobal('Notification', { get permission() { return permission; } });
    vi.stubGlobal('document', Object.assign(new EventTarget(), { visibilityState: 'visible', title: 'Product', referrer: '' }));
    vi.stubGlobal(
      'window',
      Object.assign(new EventTarget(), { PushManager: function PushManager() {}, screen: { width: 1280, height: 800 }, devicePixelRatio: 1, location: { pathname: '/', href: 'https://shop.test/', origin: 'https://shop.test' } }),
    );
    vi.stubGlobal('location', { href: 'https://shop.test/', assign: vi.fn() });
    tracked = [];
    views = [];
    sdk = new TreebarsWeb();
    sdk.init({ writeKey: 'pk_test_primer', backendUrl: 'https://ingest.test', autoPageViews: false, autoLifecycle: false, flushIntervalMs: 60 * 60 * 1000 });
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

  it('is held back from a browser that already allows push, named once, and shown once it can be asked', () => {
    sdk.track('product_view');
    expect(views).toHaveLength(0);
    const failed = tracked.filter((event) => event.name === 'in_app_failed');
    expect(failed.map((event) => event.properties.reason)).toEqual(['push_answered']);
    // Never spent: the same message is asked again at the next look, and permission is read then, not remembered.
    permission = 'default';
    sdk.track('product_view');
    expect(views.map((view) => view.message.delivery_id)).toEqual(['primer']);
  });

  it('is held back from a browser that refused, where it will not ask again', () => {
    permission = 'denied';
    sdk.track('product_view');
    expect(views).toHaveLength(0);
  });
});
