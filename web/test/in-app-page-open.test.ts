import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import type { InAppMessage } from '../src/in-app';
import type { TreebarsWebConfig } from '../src/types';

/**
 * A page that calls `init` shows its in-app messages.
 *
 * Three things hold that up. The SDK draws messages itself unless the page says otherwise, so there is no second call
 * to forget. A page asks for its messages as it opens, so a reload after publishing fetches. And a message that
 * arrives with that answer is shown on that page — the events it was waiting for are offered again — rather than held
 * for the next one.
 *
 * Each "page" here is a new SDK instance over the same storage, which is what a navigation or a reload is. The
 * drawing itself is the built-in renderer's, stood in for.
 */

const drawn = vi.hoisted(() => ({ views: [] as Array<{ id: string; dismiss: () => void }> }));

vi.mock('../src/on-site', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../src/on-site')>()),
  renderBuiltIn: (view: { message: InAppMessage; onDismiss: () => void; onShown?: () => void }) => {
    drawn.views.push({ id: view.message.delivery_id, dismiss: () => view.onDismiss() });
    view.onShown?.();
    return () => undefined;
  },
}));

const { TreebarsWeb } = await import('../src/index');
type Sdk = InstanceType<typeof TreebarsWeb>;

const START = Date.parse('2026-10-06T12:00:00.000Z');
/** The spacing between two syncs a page open asks for, and the window its answer may still be shown in, as the SDK has them. */
const SPACING_MS = 30_000;
const WINDOW_MS = 10_000;

function webStorage(): Storage {
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

type Trigger = { kind: 'session_start' } | { kind: 'immediate' } | { kind: 'event'; event_name: string };

const message = (id: string, trigger: Trigger = { kind: 'session_start' }, display: Record<string, unknown> = {}): InAppMessage => ({
  delivery_id: id,
  campaign_id: `campaign-${id}`,
  created_at: '2026-10-06T00:00:00.000Z',
  expires_at: null,
  content: { title: id, in_app: { surface: 'overlay', layout: 'modal', body_mode: 'html', html: `<p>${id}</p>`, trigger, display } as never },
});

/** Lets everything already resolved run: the turn `init` waits, and an answered sync being read and kept. */
const settle = async () => {
  for (let turn = 0; turn < 60; turn += 1) await Promise.resolve();
};

describe('in-app messages on a page that only calls init', () => {
  /** What the server holds for this browser: the answer to a sync. */
  let queue: InAppMessage[];
  /** Every request for messages, as its query string: `triggers_only=1` is the trigger list alone. */
  let asked: string[];
  /** When set, a sync waits here for the test to answer it. */
  let held: Array<(messages: InAppMessage[]) => void> | null;
  let tracked: Array<{ name: string; properties: Record<string, unknown> }>;
  let page: EventTarget & { visibilityState: string; title: string; referrer: string };
  let pages: Sdk[];

  beforeEach(() => {
    drawn.views = [];
    queue = [];
    asked = [];
    held = null;
    tracked = [];
    pages = [];
    vi.useFakeTimers({ now: START });
    vi.stubGlobal('localStorage', webStorage());
    vi.stubGlobal('sessionStorage', webStorage());
    vi.stubGlobal('CompressionStream', undefined);
    vi.stubGlobal('navigator', { userAgent: 'vitest', language: 'en-GB', sendBeacon: () => true });
    page = Object.assign(new EventTarget(), { visibilityState: 'visible', title: 'Home', referrer: '' });
    vi.stubGlobal('document', page);
    const location = { pathname: '/', hostname: 'shop.test', href: 'https://shop.test/', origin: 'https://shop.test', assign: vi.fn() };
    vi.stubGlobal('window', Object.assign(new EventTarget(), { screen: { width: 1280, height: 800 }, devicePixelRatio: 1, location }));
    vi.stubGlobal('location', location);
    vi.stubGlobal(
      'fetch',
      vi.fn((url: string) => {
        const { pathname, searchParams } = new URL(url);
        // An answer read in microtasks alone, so a test decides exactly when it lands.
        const answer = (body: unknown) => ({ ok: true, status: 200, headers: new Headers(), json: async () => body }) as unknown as Response;
        if (pathname !== '/v1/in-app') return Promise.resolve(answer({}));
        asked.push(searchParams.has('triggers_only') ? 'triggers_only=1' : 'messages');
        if (searchParams.has('triggers_only')) return Promise.resolve(answer({ server_time: 'now' }));
        if (!held) return Promise.resolve(answer({ messages: queue, policy: null, server_time: 'now' }));
        return new Promise<Response>((resolve) => held!.push((messages) => resolve(answer({ messages, policy: null, server_time: 'now' }))));
      }),
    );
  });

  afterEach(() => {
    for (const sdk of pages) sdk.shutdown();
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  /**
   * A page load: the page before it is gone, and a new SDK starts over the same storage. `before` runs ahead of
   * `init`, for what a page sets up first.
   */
  const open = (config: Partial<TreebarsWebConfig> = {}, before?: (sdk: Sdk) => void): Sdk => {
    pages.at(-1)?.shutdown();
    const sdk = new TreebarsWeb();
    pages.push(sdk);
    const track = sdk.track.bind(sdk);
    vi.spyOn(sdk, 'track').mockImplementation((name, properties = {}) => {
      tracked.push({ name, properties });
      track(name, properties);
    });
    before?.(sdk);
    sdk.init({ writeKey: 'pk_test_page_open', backendUrl: 'https://ingest.test', autoPageViews: false, flushIntervalMs: 60 * 60 * 1000, ...config });
    return sdk;
  };

  /** The next page, long enough after the last sync that it asks for its messages. */
  const openLater = (config: Partial<TreebarsWebConfig> = {}, before?: (sdk: Sdk) => void): Sdk => {
    vi.setSystemTime(Date.now() + SPACING_MS + 1_000);
    return open(config, before);
  };

  const shown = () => drawn.views.map((view) => view.id);
  const displayed = () => tracked.filter((event) => event.name === 'in_app_displayed').map((event) => event.properties.treebars_delivery_id);
  const failed = () => tracked.filter((event) => event.name === 'in_app_failed').map((event) => event.properties.reason);
  const syncs = () => asked.filter((kind) => kind === 'messages').length;

  it('draws a message with nothing but init called', async () => {
    queue = [message('welcome')];
    open();
    await settle();
    expect(shown()).toEqual(['welcome']);
    expect(displayed()).toEqual(['welcome']);
    expect(failed()).toEqual([]);
  });

  it('draws nothing after setInAppRenderer(null), and reports the message as held back', async () => {
    queue = [message('welcome')];
    open({}, (sdk) => sdk.setInAppRenderer(null));
    await settle();
    expect(shown()).toEqual([]);
    expect(displayed()).toEqual([]);
    expect(failed()).toEqual(['no_renderer']);
  });

  it('fetches no messages with inAppEnabled false: the trigger list alone at a new session, and nothing at a page open', async () => {
    queue = [message('welcome')];
    open({ inAppEnabled: false });
    await settle();
    expect(asked).toEqual(['triggers_only=1']);

    openLater({ inAppEnabled: false });
    await settle();
    expect(asked).toEqual(['triggers_only=1']);
    expect(shown()).toEqual([]);
  });

  it('asks as a page opens inside a running session: at most once in thirty seconds, and always on a reload', async () => {
    open();
    await settle();
    // The session this page opened asks once, and the page open waits for that answer rather than asking again.
    expect(syncs()).toBe(1);

    openLater();
    await settle();
    expect(tracked.filter((event) => event.name === 'session_start')).toHaveLength(0);
    expect(syncs()).toBe(2);

    // The next page, five seconds on: a sync answered this browser a moment ago.
    vi.setSystemTime(Date.now() + 5_000);
    open();
    await settle();
    expect(syncs()).toBe(2);

    // A reload asks whatever was answered a moment ago: it is what somebody does to see what they just published.
    vi.stubGlobal('performance', { now: () => 0, getEntriesByType: () => [{ type: 'reload' }] });
    open();
    await settle();
    expect(syncs()).toBe(3);
  });

  it('shows on that page a message that arrives with the page open’s sync, and only once', async () => {
    open();
    await settle();
    expect(shown()).toEqual([]);

    // Published since. The next page asks, and the page opening — already gone by when the answer lands — is offered again.
    queue = [message('welcome')];
    const sdk = openLater();
    expect(shown()).toEqual([]);
    await settle();
    expect(shown()).toEqual(['welcome']);
    expect(displayed()).toEqual(['welcome']);

    // On screen and unanswered, then dismissed: neither a later event nor the next page draws it again.
    sdk.track('product_view');
    drawn.views[0]!.dismiss();
    sdk.track('product_view');
    openLater();
    await settle();
    expect(shown()).toEqual(['welcome']);
    expect(displayed()).toEqual(['welcome']);
  });

  it('shows a send-now message that arrives with the page open’s sync, which no later event had to bring', async () => {
    open();
    await settle();

    queue = [message('now', { kind: 'immediate' })];
    openLater();
    await settle();
    expect(shown()).toEqual(['now']);
    expect(displayed()).toEqual(['now']);
  });

  it('shows a message waiting on an event the page recorded while its sync was out', async () => {
    open();
    await settle();

    held = [];
    const sdk = openLater();
    await settle();
    sdk.track('product_view', { sku: 'A1' });
    expect(shown()).toEqual([]);

    held.shift()!([message('offer', { kind: 'event', event_name: 'product_view' })]);
    await settle();
    expect(shown()).toEqual(['offer']);
  });

  it('does not follow a message the page open already drew with another when the answer lands', async () => {
    // What an earlier page left in this browser, unshown: that page was hidden.
    queue = [message('first')];
    page.visibilityState = 'hidden';
    open();
    await settle();
    page.visibilityState = 'visible';

    held = [];
    openLater();
    await settle();
    expect(shown()).toEqual(['first']);
    // Answered before the sync is: the screen is free, and the page open has still had its message.
    drawn.views[0]!.dismiss();
    held.shift()!([message('first'), message('second')]);
    await settle();
    expect(shown()).toEqual(['first']);
  });

  it('does not draw a message for a page open on a page that has been open a while', async () => {
    open();
    await settle();

    // The page open's own answer, late: the person has been on the page past the window.
    held = [];
    const sdk = openLater();
    await settle();
    vi.setSystemTime(Date.now() + WINDOW_MS + 1_000);
    held.shift()!([message('welcome')]);
    await settle();
    expect(shown()).toEqual([]);

    // Nor does a sync the page asks for later, or an event the message is not waiting on.
    held = null;
    queue = [message('welcome')];
    await sdk.syncInAppMessages();
    await settle();
    sdk.track('product_view');
    expect(shown()).toEqual([]);
    expect(failed()).toEqual([]);

    // Unspent: the next page opening is its moment, from what this browser already holds.
    vi.setSystemTime(Date.now() + 1_000);
    open();
    await settle();
    expect(shown()).toEqual(['welcome']);
  });

  it('spends nothing on a hidden page', async () => {
    queue = [message('welcome')];
    page.visibilityState = 'hidden';
    open();
    await settle();
    expect(shown()).toEqual([]);
    expect(displayed()).toEqual([]);
    expect(failed()).toEqual([]);

    // Still queued, unspent: the next page somebody can see draws it.
    page.visibilityState = 'visible';
    vi.setSystemTime(Date.now() + 1_000);
    open();
    await settle();
    expect(shown()).toEqual(['welcome']);
    expect(displayed()).toEqual(['welcome']);
  });

  it('keeps the messages it holds when an answer carries no queue', async () => {
    queue = [message('welcome')];
    page.visibilityState = 'hidden';
    open();
    await settle();

    // Not a sync's answer — a proxy's own page, say: nothing in it says the queue is empty. Nothing is drawn on this
    // page, so the message is still there to be drawn on the next.
    page.visibilityState = 'visible';
    queue = undefined as never;
    openLater({}, (sdk) => sdk.setInAppRenderer(null));
    await settle();
    expect(syncs()).toBe(2);

    vi.setSystemTime(Date.now() + 1_000);
    open();
    await settle();
    expect(shown()).toEqual(['welcome']);
  });

  it('answers a page that opened in a background tab when it is first seen', async () => {
    open();
    await settle();

    // Opened hidden, minutes before anybody looks at it: nothing is asked for and nothing is drawn.
    queue = [message('welcome')];
    page.visibilityState = 'hidden';
    openLater();
    await settle();
    expect(syncs()).toBe(1);
    expect(shown()).toEqual([]);

    // First seen: this is the page opening, for the person. It asks, and what comes back is shown.
    vi.setSystemTime(Date.now() + 5 * 60_000);
    page.visibilityState = 'visible';
    page.dispatchEvent(new Event('visibilitychange'));
    await settle();
    expect(syncs()).toBe(2);
    expect(shown()).toEqual(['welcome']);
    expect(displayed()).toEqual(['welcome']);

    // Once: hidden and shown again is a return to the tab, not another page opening.
    drawn.views[0]!.dismiss();
    page.visibilityState = 'hidden';
    page.dispatchEvent(new Event('visibilitychange'));
    page.visibilityState = 'visible';
    page.dispatchEvent(new Event('visibilitychange'));
    await settle();
    expect(shown()).toEqual(['welcome']);
  });

  it('draws the first message with whatever the script that called init set up, in either order', async () => {
    // Held by this browser from an earlier, hidden page: there to be drawn the moment this page opens.
    queue = [message('welcome'), message('own', { kind: 'session_start' }, { self_handled: true, priority: 9 })];
    page.visibilityState = 'hidden';
    open();
    await settle();
    page.visibilityState = 'visible';

    const views: string[] = [];
    const handed: string[] = [];
    vi.setSystemTime(Date.now() + 1_000);
    const sdk = open();
    // After `init`, in the same script: both are in effect before anything is drawn.
    sdk.setInAppRenderer((view) => views.push(view.message.delivery_id));
    sdk.onsite.getSelfHandledOSM((handedOver) => handed.push(handedOver.delivery_id));
    await settle();
    // The self-handled one went to the page, once — that is this page open's message — and the SDK's own renderer
    // drew nothing.
    expect(handed).toEqual(['own']);
    expect(views).toEqual([]);
    expect(shown()).toEqual([]);

    // And the page's renderer is the one handed the next.
    sdk.onsite.selfHandledDismissed(queue[1]!);
    sdk.track('app_open');
    expect(views).toEqual(['welcome']);
    expect(shown()).toEqual([]);
  });

  it('hands the page’s own renderer the first message when it is set right after init', async () => {
    queue = [message('welcome')];
    page.visibilityState = 'hidden';
    open();
    await settle();
    page.visibilityState = 'visible';

    const views: string[] = [];
    vi.setSystemTime(Date.now() + 1_000);
    const sdk = open();
    // Nothing was drawn inside `init`, so the renderer set on the next line is the one that draws.
    expect(shown()).toEqual([]);
    sdk.setInAppRenderer((view) => views.push(view.message.delivery_id));
    await settle();
    expect(views).toEqual(['welcome']);
    expect(shown()).toEqual([]);
    expect(displayed()).toEqual(['welcome']);
  });
});
