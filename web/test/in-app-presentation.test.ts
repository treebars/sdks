import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { TreebarsWeb, type InAppView } from '../src/index';
import type { InAppMessage } from '../src/in-app';

/**
 * What a drawn message does to the ones behind it, and what its buttons report.
 *
 * Several messages queued for the same event are drawn one at a time, each with its own `in_app_displayed`, rather than
 * stacked as overlays; a call to action spends the message, so the next event does not draw it again; the push opt-in
 * button asks for permission rather than navigating to `treebars://push-permission`; and a click or a dismissal names
 * its campaign.
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

const message = (id: string): InAppMessage => ({
  delivery_id: id,
  campaign_id: `campaign-${id}`,
  created_at: '2026-09-15T00:00:00.000Z',
  expires_at: null,
  content: { title: id, in_app: { surface: 'overlay', layout: 'modal', trigger: { kind: 'event', event_name: 'product_view' } } as never },
});

describe('an in-app message on screen', () => {
  let tracked: Array<{ name: string; properties: Record<string, unknown> }>;
  let views: InAppView[];
  let sdk: TreebarsWeb;
  const assign = vi.fn();

  beforeEach(async () => {
    vi.useFakeTimers({ now: Date.parse('2026-09-15T12:00:00.000Z') });
    vi.stubGlobal('localStorage', memoryStorage());
    vi.stubGlobal('sessionStorage', memoryStorage());
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string) => {
        if (new URL(url).pathname === '/v1/in-app') {
          return Response.json({ messages: [message('a'), message('b'), message('c')], policy: null, server_time: 'now' });
        }
        return new Response('{}', { status: 200 });
      }),
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
    vi.stubGlobal('location', { href: 'https://shop.test/', assign });
    assign.mockReset();
    tracked = [];
    views = [];
    sdk = new TreebarsWeb();
    sdk.init({ writeKey: 'pk_test_presentation', backendUrl: 'https://ingest.test', autoPageViews: false, autoLifecycle: false, flushIntervalMs: 60 * 60 * 1000 });
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

  const displayed = () => tracked.filter((event) => event.name === 'in_app_displayed').map((event) => event.properties.treebars_delivery_id);

  it('draws one at a time, and the next only once the person has answered', () => {
    sdk.track('product_view');
    sdk.track('product_view');
    sdk.track('product_view');
    expect(displayed()).toEqual(['a']);

    views[0]!.onDismiss();
    sdk.track('product_view');
    expect(displayed()).toEqual(['a', 'b']);
  });

  it('frees the screen after the hold when a renderer never reports back', () => {
    sdk.track('product_view');
    vi.advanceTimersByTime(29_000);
    sdk.track('product_view');
    expect(displayed()).toEqual(['a']);
    vi.advanceTimersByTime(1_000);
    sdk.track('product_view');
    // Nothing answered, so nothing was spent: the same message is the next one, as in the Android and iOS SDKs.
    expect(displayed()).toEqual(['a', 'a']);
  });

  it('spends a message on a call to action, and names the campaign on the click and the dismissal', () => {
    sdk.track('product_view');
    views[0]!.onClick({ label: 'Join', action: 'set_attribute', key: 'newsletter', value: 'yes' });
    const click = tracked.find((event) => event.name === 'in_app_clicked')!;
    expect(click.properties).toEqual({ treebars_delivery_id: 'a', treebars_campaign_id: 'campaign-a' , button_label: 'Join' });

    // Spent, and the screen is free: the next event draws the next message, never `a` again.
    sdk.track('product_view');
    expect(displayed()).toEqual(['a', 'b']);
    views[1]!.onDismiss();
    expect(tracked.find((event) => event.name === 'in_app_dismissed')!.properties).toEqual({ treebars_delivery_id: 'b', treebars_campaign_id: 'campaign-b' });
    sdk.track('product_view');
    expect(displayed()).toEqual(['a', 'b', 'c']);
  });

  it('asks for push permission from the opt-in button and goes nowhere', () => {
    sdk.setInAppRenderer('builtin');
    const requested = vi.fn(async () => 'granted' as NotificationPermission);
    vi.stubGlobal('window', Object.assign(window, { PushManager: class {} }));
    vi.stubGlobal('navigator', { userAgent: 'vitest', language: 'en-GB', sendBeacon: () => true, serviceWorker: {} });
    vi.stubGlobal('Notification', { permission: 'default', requestPermission: requested });
    // Drawn through a renderer of our own, with the built-in renderer's navigation rule in force.
    (sdk as unknown as { renderer: unknown }).renderer = 'builtin';
    const shown = message('a');
    (sdk as unknown as { inAppButton: (m: InAppMessage, b: unknown) => void }).inAppButton(shown, {
      label: 'Allow',
      action: 'deep_link',
      value: 'treebars://push-permission',
    });
    expect(requested).toHaveBeenCalledTimes(1);
    expect(assign).not.toHaveBeenCalled();
  });
  it('never spends a message on the page being left', () => {
    // `immediate` matches every event, the SDK's own `app_background` among them — so a page that is hidden or being
    // left is no moment to draw: a link click would spend the next queued message on the page being left, and the
    // next page would draw nothing.
    const immediate = (id: string): InAppMessage => ({
      ...message(id),
      content: { title: id, in_app: { surface: 'overlay', layout: 'modal', trigger: { kind: 'immediate' } } as never },
    });
    (sdk as unknown as { inApp: { accept: (body: unknown) => void } }).inApp.accept({ messages: [immediate('x')], policy: null });

    sdk.track('app_background');
    sdk.track('session_end');
    (document as { visibilityState: string }).visibilityState = 'hidden';
    sdk.track('checkout_abandoned');
    expect(displayed()).toEqual([]);

    // Still queued, unspent: the first event on a visible page is its moment.
    (document as { visibilityState: string }).visibilityState = 'visible';
    sdk.track('product_view');
    expect(displayed()).toEqual(['x']);
  });
  it('drops a sync that was asked for the person who has since signed out', async () => {
    // A sync asked for the previous person can land after reset() has emptied the store. Its answer is dropped, so
    // their queue is never put back on the signed-out screen.
    sdk.identify('user_1');
    let answer!: (response: Response) => void;
    vi.stubGlobal('fetch', vi.fn(() => new Promise<Response>((resolve) => (answer = resolve))));
    const syncing = sdk.syncInAppMessages();
    sdk.reset();
    answer(Response.json({ messages: [message('stale')], policy: null, server_time: 'now' }));
    await syncing;

    expect((sdk as unknown as { inApp: { list: () => InAppMessage[] } }).inApp.list()).toEqual([]);
    sdk.track('product_view');
    expect(displayed()).toEqual([]);
  });

  it('changes nothing on reset() with nobody signed in: the same visitor keeps their queue and what they answered', () => {
    sdk.track('product_view');
    views[0]!.onDismiss();
    expect(displayed()).toEqual(['a']);

    // A page may call reset() defensively on load; with nobody signed in the ledger is kept, so `a` is not offered
    // again.
    sdk.reset();
    sdk.track('product_view');
    expect(displayed()).toEqual(['a', 'b']);
    expect(tracked.filter((event) => event.name === 'user_signed_out')).toEqual([]);
  });

  it('keeps the queue through a first sign-in and a repeat of it, and clears it when somebody else signs in', () => {
    // The queue synced for the anonymous visitor is the same person's once they sign in, and still theirs when the
    // page identifies them again.
    sdk.identify('user_1');
    sdk.identify('user_1', { plan: 'pro' });
    sdk.track('product_view');
    expect(displayed()).toEqual(['a']);
    views[0]!.onDismiss();

    // Somebody else, with no reset() between: `b` and `c` were user_1's, so neither is drawn for user_2.
    sdk.identify('user_2');
    expect((sdk as unknown as { inApp: { list: () => InAppMessage[] } }).inApp.list()).toEqual([]);
    sdk.track('product_view');
    expect(displayed()).toEqual(['a']);
  });

  it('does not draw a message that was waiting for its moment once somebody else has signed in', () => {
    const later: InAppMessage = {
      ...message('later'),
      content: {
        title: 'later',
        in_app: { surface: 'overlay', layout: 'modal', trigger: { kind: 'event', event_name: 'product_view' }, display: { on: 'delay', delay_seconds: 5 } } as never,
      },
    };
    (sdk as unknown as { inApp: { accept: (body: unknown) => void } }).inApp.accept({ messages: [later], policy: null });
    sdk.identify('user_1');
    sdk.track('product_view');
    expect((sdk as unknown as { pendingDisplay: unknown }).pendingDisplay).not.toBeNull();

    // The delay it was waiting out ends after user_2 signed in: it was user_1's, and is not drawn.
    sdk.identify('user_2');
    vi.advanceTimersByTime(6_000);
    expect(displayed()).toEqual([]);
  });
});
