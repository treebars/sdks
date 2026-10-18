import { afterEach, describe, expect, it, vi } from 'vitest';

import { WebPush } from '../src/push';
import { install, type FakeNode } from './fake-dom';

/**
 * Subscribing a browser to web push, and the soft prompt that asks first. The browser's own prompt is shown once and a
 * "no" there is for good, so what is asked when, and what is registered with Treebars after a yes, is pinned here: the
 * worker registered at the site's path, an existing subscription reused, the VAPID key handed over as bytes, and the
 * subscription registered and flushed.
 */

function memoryStorage() {
  const map = new Map<string, string>();
  return { getItem: (k: string) => map.get(k) ?? null, setItem: (k: string, v: string) => void map.set(k, v), removeItem: (k: string) => void map.delete(k) };
}

/** A browser that can take a push: its permission, what asking answers, and a worker with or without a subscription. */
function browser({ permission = 'default', answer = 'granted', existing = null as string | null } = {}) {
  vi.stubGlobal('localStorage', memoryStorage());
  vi.stubGlobal('window', { PushManager: class {} });
  const asked: string[] = [];
  const notification = {
    permission: permission as NotificationPermission,
    requestPermission: vi.fn(async () => {
      asked.push('permission');
      notification.permission = answer as NotificationPermission;
      return answer;
    }),
  };
  vi.stubGlobal('Notification', notification);
  const sub = (endpoint: string) => ({ endpoint, toJSON: () => ({ endpoint, keys: { p256dh: 'p', auth: 'a' } }) });
  const subscribeCalls: Array<{ userVisibleOnly: boolean; applicationServerKey: Uint8Array }> = [];
  const registered: string[] = [];
  const pushManager = {
    getSubscription: async () => (existing ? sub(existing) : null),
    subscribe: async (options: { userVisibleOnly: boolean; applicationServerKey: Uint8Array }) => {
      subscribeCalls.push(options);
      return sub('https://push.example/fresh');
    },
  };
  let onchange: (() => void) | null = null;
  vi.stubGlobal('navigator', {
    serviceWorker: {
      register: async (path: string) => {
        registered.push(path);
        return { pushManager };
      },
      ready: Promise.resolve(),
      getRegistration: async () => ({ pushManager }),
    },
    permissions: {
      query: async () => ({
        set onchange(fn: () => void) {
          onchange = fn;
        },
      }),
    },
  });
  return { asked, subscribeCalls, registered, notification, permissionChanged: () => onchange?.() };
}

function sdk(persist = true) {
  const tracked: [string, Record<string, unknown>][] = [];
  let flushed = 0;
  const push = new WebPush({ track: (e, p) => tracked.push([e, p]), flush: () => void (flushed += 1), persist: () => persist });
  return { push, tracked, flushed: () => flushed };
}

const settle = async () => {
  for (let turn = 0; turn < 20; turn += 1) await Promise.resolve();
};

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe('subscribing a browser', () => {
  it('asks once, registers the worker at the site’s path, subscribes with the key as bytes, and registers the subscription', async () => {
    const b = browser();
    const { push, tracked, flushed } = sdk();
    // "AQAB" is the bytes 1, 0, 1: the key arrives URL-safe base64 and leaves as bytes.
    expect(await push.subscribe({ vapidPublicKey: 'AQAB', serviceWorkerPath: '/sw/treebars-sw.js' })).toBe('subscribed');
    expect(b.asked).toEqual(['permission']);
    expect(b.registered).toEqual(['/sw/treebars-sw.js']);
    expect(b.subscribeCalls).toHaveLength(1);
    expect(b.subscribeCalls[0]!.userVisibleOnly).toBe(true);
    expect([...b.subscribeCalls[0]!.applicationServerKey]).toEqual([1, 0, 1]);
    expect(tracked).toEqual([['push_token_registered', { token: JSON.stringify({ endpoint: 'https://push.example/fresh', keys: { p256dh: 'p', auth: 'a' } }), provider: 'webpush' }]]);
    expect(JSON.parse(localStorage.getItem('treebars.push.registered.v1')!)).toEqual({ endpoint: 'https://push.example/fresh', path: '/sw/treebars-sw.js' });
    expect(flushed()).toBe(1);
  });

  it('reuses a subscription the browser already holds, and does not ask an answered permission again', async () => {
    const b = browser({ permission: 'granted', existing: 'https://push.example/kept' });
    const { push, tracked } = sdk();
    expect(await push.subscribe({ vapidPublicKey: 'AQAB' })).toBe('subscribed');
    expect(b.asked).toEqual([]);
    expect(b.registered).toEqual(['/treebars-sw.js']);
    expect(b.subscribeCalls).toEqual([]);
    expect(String(tracked[0]![1].token)).toContain('https://push.example/kept');
  });

  it('answers denied, and registers nothing, when the person says no', async () => {
    const b = browser({ answer: 'denied' });
    const { push, tracked } = sdk();
    expect(await push.subscribe({ vapidPublicKey: 'AQAB' })).toBe('denied');
    expect(b.registered).toEqual([]);
    expect(tracked.filter(([event]) => event === 'push_token_registered')).toEqual([]);
  });

  it('answers unsupported in a browser without push, and asks nothing', async () => {
    vi.stubGlobal('window', {});
    vi.stubGlobal('navigator', {});
    const { push } = sdk();
    expect(await push.subscribe({ vapidPublicKey: 'AQAB' })).toBe('unsupported');
    expect(await push.requestPermission()).toBe('unsupported');
    expect(push.status()).toBe('unsupported');
  });
});

describe('the permission', () => {
  it('reads in the words every SDK shares, and reports a change only once it has a before', async () => {
    const b = browser({ permission: 'default' });
    const { push, tracked } = sdk();
    expect(push.status()).toBe('not_determined');
    push.notePermission();
    // The first reading is the starting point, not a change.
    expect(tracked).toEqual([]);
    b.notification.permission = 'granted';
    push.notePermission();
    push.notePermission();
    expect(tracked).toEqual([['notification_permission_changed', { from: 'not_determined', to: 'authorized' }]]);
  });

  it('is watched while the page is open, where the browser says', async () => {
    const b = browser({ permission: 'granted' });
    const { push, tracked } = sdk();
    await push.refresh();
    await settle();
    b.notification.permission = 'denied';
    b.permissionChanged();
    expect(tracked).toEqual([['notification_permission_changed', { from: 'authorized', to: 'denied' }]]);
  });

  it('the in-app opt-in button asks for permission only, until the site has subscribed on this page', async () => {
    const b = browser();
    const { push } = sdk();
    expect(await push.requestPermission()).toBe('subscribed');
    expect(b.asked).toEqual(['permission']);
    expect(b.registered).toEqual([]);

    const after = browser();
    const second = sdk();
    await second.push.subscribe({ vapidPublicKey: 'AQAB' });
    after.registered.length = 0;
    expect(await second.push.requestPermission()).toBe('subscribed');
    expect(after.registered).toEqual(['/treebars-sw.js']);
  });
});

describe('the soft prompt', () => {
  const promptBox = (body: FakeNode) => body.find((node) => node.getAttribute('role') === 'dialog');

  it('shows the site’s words, and a yes goes on to the browser’s prompt and subscribes', async () => {
    const { body } = install();
    const b = browser();
    const { push } = sdk();
    const answer = push.prompt({ vapidPublicKey: 'AQAB', text: 'Hear about drops first', allow: 'Yes please', deny: 'Maybe later' });
    await settle();
    expect(promptBox(body)!.textContent).toBe('Hear about drops firstMaybe laterYes please');
    // Nothing asked of the browser until the person says yes on the page.
    expect(b.asked).toEqual([]);
    body.byName('Yes please')!.click();
    expect(await answer).toBe('subscribed');
    expect(b.asked).toEqual(['permission']);
    expect(promptBox(body)).toBeUndefined();
  });

  it('a "not now" keeps it away for the days asked, and asks the browser nothing', async () => {
    const { body } = install();
    const b = browser();
    const { push } = sdk();
    const answer = push.prompt({ vapidPublicKey: 'AQAB', reappearDays: 3 });
    await settle();
    const before = Date.now();
    body.byName('Not now')!.click();
    expect(await answer).toBe('dismissed');
    expect(b.asked).toEqual([]);
    const until = Number(localStorage.getItem('treebars.push.prompt.v1'));
    expect(until - before).toBeGreaterThanOrEqual(3 * 86_400_000);
    expect(until - before).toBeLessThan(3 * 86_400_000 + 1_000);
    expect(await push.prompt({ vapidPublicKey: 'AQAB' })).toBe('later');
  });

  it('as an overlay dims the page behind it, and takes the dim away with it', async () => {
    const { body } = install();
    browser();
    const { push } = sdk();
    const answer = push.prompt({ vapidPublicKey: 'AQAB', style: 'overlay' });
    await settle();
    expect(body.children).toHaveLength(2);
    expect(body.children[0]!.style.cssText).toContain('inset:0');
    body.byName('Not now')!.click();
    await answer;
    expect(body.children).toHaveLength(0);
  });

  it('waits the delay asked before showing, and skips itself once the browser has said yes', async () => {
    vi.useFakeTimers();
    const { body } = install();
    browser();
    const { push } = sdk();
    const answer = push.prompt({ vapidPublicKey: 'AQAB', delaySeconds: 5 });
    await vi.advanceTimersByTimeAsync(4_000);
    expect(promptBox(body)).toBeUndefined();
    await vi.advanceTimersByTimeAsync(1_000);
    expect(promptBox(body)).toBeDefined();
    body.byName('Not now')!.click();
    await answer;

    const granted = browser({ permission: 'granted' });
    expect(await push.prompt({ vapidPublicKey: 'AQAB' })).toBe('subscribed');
    expect(granted.registered).toEqual(['/treebars-sw.js']);
  });
});
