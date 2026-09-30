import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import { afterEach, describe, expect, it, vi } from 'vitest';

import { WebPush } from '../src/push';

/*
 * Web push in the browser: the page a notification opened reports the click once and cleans its address, the soft
 * prompt keeps away after a "not now", and the service worker draws only its own pushes and opens the right page.
 */

function memoryStorage() {
  const map = new Map<string, string>();
  return { getItem: (k: string) => map.get(k) ?? null, setItem: (k: string, v: string) => void map.set(k, v), removeItem: (k: string) => void map.delete(k) };
}

afterEach(() => vi.unstubAllGlobals());

describe('the page a push opened', () => {
  it('reports notification_opened with the delivery, campaign and button, and takes them out of the URL', () => {
    const replaced: string[] = [];
    vi.stubGlobal('location', { href: 'https://shop.example.com/cart?x=1&treebars_delivery_id=d1&treebars_campaign_id=c1&treebars_button_id=buy' });
    vi.stubGlobal('history', { state: null, replaceState: (_s: unknown, _t: string, url: string) => replaced.push(url) });
    const tracked: [string, Record<string, unknown>][] = [];
    new WebPush({ track: (e, p) => tracked.push([e, p]), flush: () => {}, persist: () => true }).trackOpened();
    expect(tracked).toEqual([['notification_opened', { treebars_delivery_id: 'd1', treebars_campaign_id: 'c1', treebars_button_id: 'buy' }]]);
    expect(replaced).toEqual(['https://shop.example.com/cart?x=1']);
  });

  it('does nothing on an ordinary page', () => {
    vi.stubGlobal('location', { href: 'https://shop.example.com/' });
    vi.stubGlobal('history', { state: null, replaceState: () => {} });
    const tracked: unknown[] = [];
    new WebPush({ track: (e) => tracked.push(e), flush: () => {}, persist: () => true }).trackOpened();
    expect(tracked).toEqual([]);
  });
});

describe('the soft prompt', () => {
  it('answers unsupported without a push manager, and later while a "not now" stands', async () => {
    const push = new WebPush({ track: () => {}, flush: () => {}, persist: () => true });
    expect(await push.prompt({ vapidPublicKey: 'k' })).toBe('unsupported');
    vi.stubGlobal('localStorage', memoryStorage());
    vi.stubGlobal('window', { PushManager: class {} });
    vi.stubGlobal('navigator', { serviceWorker: {} });
    vi.stubGlobal('Notification', { permission: 'default' });
    localStorage.setItem('treebars.push.prompt.v1', String(Date.now() + 60_000));
    expect(await push.prompt({ vapidPublicKey: 'k' })).toBe('later');
    vi.stubGlobal('Notification', { permission: 'denied' });
    expect(await push.prompt({ vapidPublicKey: 'k' })).toBe('denied');
  });
});

/*
 * The subscription and the permission are read on every page load, not only inside `subscribe`, so a subscription the
 * browser rotated is registered again and a revoked permission is reported. Each load compares, and reports only what
 * moved.
 */
describe('every page load', () => {
  function browser(endpoint: string | null, permission: NotificationPermission = 'granted') {
    vi.stubGlobal('localStorage', memoryStorage());
    vi.stubGlobal('window', { PushManager: class {} });
    vi.stubGlobal('Notification', { permission });
    const subscription = endpoint ? { endpoint, toJSON: () => ({ endpoint, keys: { p256dh: 'p', auth: 'a' } }) } : null;
    vi.stubGlobal('navigator', {
      serviceWorker: { getRegistration: async () => ({ pushManager: { getSubscription: async () => subscription } }) },
    });
  }
  const host = () => {
    const tracked: [string, Record<string, unknown>][] = [];
    return { tracked, push: new WebPush({ track: (e, p) => tracked.push([e, p]), flush: () => {}, persist: () => true }) };
  };

  it('registers a subscription the browser rotated, and nothing when it is the one on file', async () => {
    browser('https://push.example/new');
    localStorage.setItem('treebars.push.registered.v1', JSON.stringify({ endpoint: 'https://push.example/old', path: '/treebars-sw.js' }));
    localStorage.setItem('treebars.push.permission.v1', 'authorized');
    const { tracked, push } = host();
    await push.refresh();
    expect(tracked.map(([event]) => event)).toEqual(['push_token_registered']);
    expect(String(tracked[0]![1].token)).toContain('https://push.example/new');

    await push.refresh();
    expect(tracked).toHaveLength(1);
  });

  it('never subscribes a browser the site did not subscribe', async () => {
    browser('https://push.example/someone-elses');
    const { tracked, push } = host();
    await push.refresh();
    expect(tracked.filter(([event]) => event === 'push_token_registered')).toEqual([]);
  });

  it('reports a permission revoked since the last page', async () => {
    browser(null, 'denied');
    localStorage.setItem('treebars.push.permission.v1', 'authorized');
    const { tracked, push } = host();
    await push.refresh();
    expect(tracked).toEqual([['notification_permission_changed', { from: 'authorized', to: 'denied' }]]);
  });
});

describe('the service worker', () => {
  function worker() {
    const listeners: Record<string, (event: unknown) => void> = {};
    const shown: [string, Record<string, unknown>][] = [];
    const opened: string[] = [];
    const self = {
      location: { origin: 'https://shop.example.com' },
      addEventListener: (name: string, fn: (event: unknown) => void) => (listeners[name] = fn),
      registration: { showNotification: (title: string, options: Record<string, unknown>) => (shown.push([title, options]), Promise.resolve()) },
      clients: { openWindow: (url: string) => (opened.push(url), Promise.resolve()) },
    };
    runInNewContext(readFileSync(new URL('../treebars-sw.js', import.meta.url), 'utf8'), { self, URL });
    return { listeners, shown, opened };
  }
  const push = {
    title: 'Back in stock',
    body: 'The blue one',
    url: '/p/1',
    tag: 'stock1',
    actions: [{ id: 'buy', title: 'Buy', url: '/cart' }],
    data: { treebars_delivery_id: 'd1', treebars_campaign_id: 'c1' },
  };

  it('subscribes afresh with the same key when the browser retires the subscription', () => {
    const subscribed: unknown[] = [];
    const listeners: Record<string, (event: unknown) => void> = {};
    const self = {
      location: { origin: 'https://shop.example.com' },
      addEventListener: (name: string, fn: (event: unknown) => void) => (listeners[name] = fn),
      registration: { pushManager: { subscribe: (options: unknown) => (subscribed.push(options), Promise.resolve()) } },
    };
    runInNewContext(readFileSync(new URL('../treebars-sw.js', import.meta.url), 'utf8'), { self, URL });
    listeners.pushsubscriptionchange!({ oldSubscription: { options: { applicationServerKey: 'key' } }, waitUntil: () => {} });
    // No old subscription is no key to reuse: the site's own subscribe() is the way back.
    listeners.pushsubscriptionchange!({ oldSubscription: null, waitUntil: () => {} });
    expect(subscribed).toEqual([{ userVisibleOnly: true, applicationServerKey: 'key' }]);
  });

  it('draws a Treebars push and leaves anybody else\'s alone', () => {
    const { listeners, shown } = worker();
    listeners.push!({ data: { json: () => ({ treebars: push }) }, waitUntil: () => {} });
    listeners.push!({ data: { json: () => ({ other: true }) }, waitUntil: () => {} });
    expect(shown).toHaveLength(1);
    expect(shown[0]![0]).toBe('Back in stock');
    expect(shown[0]![1]).toMatchObject({ body: 'The blue one', tag: 'stock1', renotify: true, actions: [{ action: 'buy', title: 'Buy' }] });
  });

  it('draws the badge and each button\'s icon, and closes an auto-dismissed push after 8 seconds', async () => {
    const listeners: Record<string, (event: unknown) => void> = {};
    const shown: Record<string, unknown>[] = [];
    const closed: string[] = [];
    const waits: number[] = [];
    const drawn = (tag: string, delivery: string) => ({ data: { data: { treebars_delivery_id: delivery } }, close: () => closed.push(`${tag}:${delivery}`) });
    const self = {
      location: { origin: 'https://shop.example.com' },
      addEventListener: (name: string, fn: (event: unknown) => void) => (listeners[name] = fn),
      registration: {
        showNotification: (_title: string, options: Record<string, unknown>) => (shown.push(options), Promise.resolve()),
        // Two on the tag: this push and an older one that replaced nothing. Only this one is closed.
        getNotifications: (filter: { tag: string }) => Promise.resolve([drawn(filter.tag, 'd1'), drawn(filter.tag, 'older')]),
      },
      clients: { openWindow: () => Promise.resolve() },
    };
    const setTimeout = (fn: () => void, ms: number) => (waits.push(ms), fn());
    runInNewContext(readFileSync(new URL('../treebars-sw.js', import.meta.url), 'utf8'), { self, URL, setTimeout });
    let held: Promise<unknown> = Promise.resolve();
    const withIcons = { ...push, badge: 'https://cdn.example.com/badge.png', auto_dismiss: true, actions: [{ id: 'buy', title: 'Buy', url: '/cart', icon: 'https://cdn.example.com/cart.png' }] };
    listeners.push!({ data: { json: () => ({ treebars: withIcons }) }, waitUntil: (promise: Promise<unknown>) => (held = promise) });
    await held;
    expect(shown[0]).toMatchObject({ badge: 'https://cdn.example.com/badge.png', actions: [{ action: 'buy', title: 'Buy', icon: 'https://cdn.example.com/cart.png' }] });
    expect(waits).toEqual([8000]);
    expect(closed).toEqual(['stock1:d1']);
  });

  it('opens the button\'s page with the delivery named, and a page of another site without it', () => {
    const { listeners, opened } = worker();
    const click = (data: unknown, action = '') => listeners.notificationclick!({ notification: { data, close: () => {} }, action, waitUntil: () => {} });
    click(push, 'buy');
    click(push);
    click({ ...push, url: 'https://elsewhere.example.org/x' });
    expect(opened).toEqual([
      'https://shop.example.com/cart?treebars_delivery_id=d1&treebars_campaign_id=c1&treebars_button_id=buy',
      'https://shop.example.com/p/1?treebars_delivery_id=d1&treebars_campaign_id=c1',
      'https://elsewhere.example.org/x',
    ]);
  });
});
