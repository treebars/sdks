import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { TreebarsWeb, type InAppView } from '../src/index';
import type { InAppMessage } from '../src/in-app';

/**
 * The in-app API under the names common engagement SDKs use, so a migration keeps its call sites: what a
 * self-handled message hands the page, and what a drawn message reports through the window event. The harness is
 * the one in-app-presentation.test.ts uses.
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


/*
 * Named to match common engagement SDKs' web names: `onsite.getSelfHandledOSM` hands the page a self-handled message
 * instead of the renderer, and the page hears every message through the TREEBARS_AUTOMATED_EVENTS window event, which is
 * the only listener — there is no `onInAppAction` or `onSelfHandledInApp`.
 */
const selfHandled = (id: string): InAppMessage => ({
  ...message(id),
  content: { title: id, in_app: { surface: 'overlay', layout: 'modal', trigger: { kind: 'event', event_name: 'product_view' }, display: { self_handled: true } } as never },
});

describe('the web SDK under the common engagement-SDK names', () => {
  let tracked: Array<{ name: string; properties: Record<string, unknown> }>;
  let views: InAppView[];
  let heard: Array<{ name: string; data: Record<string, unknown> }>;
  let sdk: TreebarsWeb;

  beforeEach(async () => {
    vi.useFakeTimers({ now: Date.parse('2026-09-15T12:00:00.000Z') });
    vi.stubGlobal('localStorage', memoryStorage());
    vi.stubGlobal('sessionStorage', memoryStorage());
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string) => {
        if (new URL(url).pathname === '/v1/in-app') {
          return Response.json({ messages: [selfHandled('s'), message('a')], policy: null, server_time: 'now' });
        }
        return new Response('{}', { status: 200 });
      }),
    );
    vi.stubGlobal('CompressionStream', undefined);
    vi.stubGlobal('navigator', { userAgent: 'vitest', language: 'en-GB', sendBeacon: () => true });
    vi.stubGlobal('document', Object.assign(new EventTarget(), { visibilityState: 'visible', title: 'Product', referrer: '' }));
    const target = Object.assign(new EventTarget(), {
      screen: { width: 1280, height: 800 },
      devicePixelRatio: 1,
      location: { pathname: '/', href: 'https://shop.test/', origin: 'https://shop.test' },
    });
    vi.stubGlobal('window', target);
    vi.stubGlobal('location', { href: 'https://shop.test/', assign: vi.fn() });
    heard = [];
    target.addEventListener('TREEBARS_AUTOMATED_EVENTS', (event) => heard.push((event as CustomEvent).detail));
    tracked = [];
    views = [];
    sdk = new TreebarsWeb();
    sdk.init({ writeKey: 'pk_test_names', backendUrl: 'https://ingest.test', autoPageViews: false, autoLifecycle: false, flushIntervalMs: 60 * 60 * 1000 });
    const track = sdk.track.bind(sdk);
    vi.spyOn(sdk, 'track').mockImplementation((name, properties = {}) => {
      tracked.push({ name, properties });
      track(name, properties);
    });
    sdk.setInAppRenderer((view) => views.push(view));
    await sdk.syncInAppMessages();
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it('hands a self-handled message to onsite.getSelfHandledOSM, and spends nothing until the page says it showed it', () => {
    const handed: InAppMessage[] = [];
    sdk.onsite.getSelfHandledOSM((message) => handed.push(message));
    sdk.track('product_view');
    expect(handed.map((message) => message.delivery_id)).toEqual(['s']);
    expect(views).toHaveLength(0);
    expect(tracked.filter((event) => event.name === 'in_app_displayed')).toHaveLength(0);

    sdk.onsite.selfHandledShown(handed[0]!);
    expect(tracked.filter((event) => event.name === 'in_app_displayed')).toHaveLength(1);
    sdk.onsite.selfHandledClicked(handed[0]!, { label: 'Go', action: 'url', value: 'https://shop.test/go' });
    expect(tracked.find((event) => event.name === 'in_app_clicked')!.properties).toMatchObject({ treebars_delivery_id: 's', button_label: 'Go' });
    sdk.onsite.selfHandledDismissed(handed[0]!);
    expect(heard.map((event) => event.name)).toEqual(['TREEBARS_ONSITE_MESSAGE_SHOWN', 'TREEBARS_ONSITE_MESSAGE_CLICKED', 'TREEBARS_ONSITE_MESSAGE_DISMISSED']);
  });

  it('draws a self-handled message like any other when the page does not listen', () => {
    sdk.track('product_view');
    expect(views.map((view) => view.message.delivery_id)).toEqual(['s']);
  });

  it('tells the page a drawn message was shown, pressed with a custom button’s keys, and closed by itself', () => {
    sdk.onsite.getSelfHandledOSM(null);
    sdk.track('product_view');
    const view = views[0]!;
    expect(heard.at(-1)).toEqual({ name: 'TREEBARS_ONSITE_MESSAGE_SHOWN', data: { treebars_delivery_id: 's', treebars_campaign_id: 'campaign-s' } });
    view.onClick({ label: 'Keys', action: 'custom', data: { coupon: 'SPRING' } });
    expect(heard.at(-1)).toMatchObject({ name: 'TREEBARS_ONSITE_MESSAGE_CLICKED', data: { action: 'custom', values: { coupon: 'SPRING' }, button_label: 'Keys' } });
    // A link's key-values ride beside its value, never in place of it: a listener routes on `value`.
    view.onClick({ label: 'Shop', action: 'deep_link', value: 'app://sale?utm_source=in_app', data: { utm_source: 'in_app' } });
    expect(heard.at(-1)).toMatchObject({ name: 'TREEBARS_ONSITE_MESSAGE_CLICKED', data: { action: 'deep_link', values: { utm_source: 'in_app', value: 'app://sale?utm_source=in_app' } } });
    view.onDismiss('auto');
    expect(heard.at(-1)!.name).toBe('TREEBARS_ONSITE_MESSAGE_AUTO_DISMISS');
  });

  it('sets and clears the contexts under the common Android names', () => {
    expect(typeof sdk.setInAppContext).toBe('function');
    expect(typeof sdk.resetInAppContext).toBe('function');
    expect((sdk as unknown as Record<string, unknown>).setAppContext).toBeUndefined();
    expect((sdk as unknown as Record<string, unknown>).onInAppAction).toBeUndefined();
  });
});
