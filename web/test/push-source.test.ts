import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { TreebarsWeb } from '../src/index';
import { triggerMatches } from '../src/in-app';

/**
 * A push and the in-app message somebody then saw, followed from one to the other.
 *
 * Every in-app event after a push open in the same session names that push, which is the only way a report can count
 * the people who came in from a push and then saw or tapped a message. And the "Only from the notification" trigger
 * fires for its own push and no other, so the message reaches exactly the people that push brought in.
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

describe('the push a session was opened from', () => {
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
      writeKey: 'pk_test_push_source',
      backendUrl: 'https://ingest.test',
      autoPageViews: false,
      autoLifecycle: false,
      autoSessions: false,
      inAppEnabled: false,
      flushIntervalMs: 60 * 60 * 1000,
    });

  // What reached the queue, as the SDK stamped it: the upload carries exactly these properties.
  const queued = () => {
    const calls: [string, Record<string, unknown>][] = [];
    const spy = vi.spyOn(sdk as unknown as { enqueue: (name: string, properties: Record<string, unknown>, session: string) => unknown }, 'enqueue');
    spy.mockImplementation(function (this: unknown, name, properties) {
      calls.push([name, properties]);
      return {};
    });
    return calls;
  };
  const sourceOf = (calls: [string, Record<string, unknown>][], name: string) =>
    calls.filter(([event]) => event === name).map(([, properties]) => properties.treebars_source_delivery_id);

  it('names the opening push on the in-app events after it, and on nothing else', () => {
    page(undefined);
    start();
    const calls = queued();
    sdk.track('in_app_displayed', { treebars_delivery_id: 'before' });
    sdk.track('notification_opened', { treebars_delivery_id: 'push-1' });
    sdk.track('in_app_displayed', { treebars_delivery_id: 'message-1' });
    sdk.track('in_app_clicked', { treebars_delivery_id: 'message-1' });
    sdk.track('checkout_viewed');

    expect(sourceOf(calls, 'in_app_displayed')).toEqual([undefined, 'push-1']);
    expect(sourceOf(calls, 'in_app_clicked')).toEqual(['push-1']);
    expect(sourceOf(calls, 'checkout_viewed')).toEqual([undefined]);
    expect(sourceOf(calls, 'notification_opened')).toEqual([undefined]);
  });

  it('is kept for the session across pages', () => {
    page(undefined);
    start();
    sdk.track('notification_opened', { treebars_delivery_id: 'push-2' });
    sdk.shutdown();
    // The next page of the same visit: a new SDK, the same storage and session.
    sdk = new TreebarsWeb();
    start();
    const calls = queued();
    sdk.track('in_app_displayed', { treebars_delivery_id: 'message-2' });
    expect(sourceOf(calls, 'in_app_displayed')).toEqual(['push-2']);
  });
});

describe('the "Only from the notification" trigger', () => {
  it('fires for the push that names this message, and for no other open', () => {
    const trigger = { kind: 'companion_push' } as const;
    expect(triggerMatches(trigger, 'notification_opened', { treebars_companion_of: 'm1' }, { deliveryId: 'm1' })).toBe(true);
    expect(triggerMatches(trigger, 'notification_opened', { treebars_companion_of: 'm2' }, { deliveryId: 'm1' })).toBe(false);
    expect(triggerMatches(trigger, 'notification_opened', {}, { deliveryId: 'm1' })).toBe(false);
    expect(triggerMatches(trigger, 'app_open', { treebars_companion_of: 'm1' }, { deliveryId: 'm1' })).toBe(false);
    expect(triggerMatches(trigger, 'notification_opened', { treebars_companion_of: 'm1' })).toBe(false);
  });
});
