import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import type { InAppMessage } from '../src/in-app';
import type { TreebarsWebConfig } from '../src/types';

/**
 * A message shown when a session starts, on a website. A site records `app_open` on every page load, so such a message
 * matched on every page of a visit and was drawn on each one until it was closed — a journey's message "never stopped".
 * It is drawn at most once a session now, and again in the next session.
 */

const drawn = vi.hoisted(() => ({ views: [] as Array<{ id: string; folded: boolean; minimise: (value: boolean) => void; dismiss: () => void }> }));

vi.mock('../src/on-site', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../src/on-site')>()),
  renderBuiltIn: (view: { message: InAppMessage; onDismiss: () => void; onShown?: () => void; onMinimise?: (value: boolean) => void }) => {
    drawn.views.push({
      id: view.message.delivery_id,
      folded: view.message.content.in_app?.placement?.start_minimised === true,
      minimise: (value) => view.onMinimise?.(value),
      dismiss: () => view.onDismiss(),
    });
    view.onShown?.();
    return () => undefined;
  },
}));

const { TreebarsWeb } = await import('../src/index');
type Sdk = InstanceType<typeof TreebarsWeb>;

const FOLDS = { vertical: 'bottom', horizontal: 'end', no_backdrop: true, minimisable: true };
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

const message = (id: string, trigger: Trigger = { kind: 'session_start' }, display: Record<string, unknown> = {}, placement: Record<string, unknown> = FOLDS): InAppMessage => ({
  delivery_id: id,
  campaign_id: `campaign-${id}`,
  created_at: '2026-10-06T00:00:00.000Z',
  expires_at: null,
  content: { title: id, in_app: { surface: 'overlay', layout: 'modal', body_mode: 'html', html: `<p>${id}</p>`, trigger, display, placement } as never },
});

/** Lets everything already resolved run: the turn `init` waits, and an answered sync being read and kept. */
const settle = async () => {
  for (let turn = 0; turn < 60; turn += 1) await Promise.resolve();
};

describe('a session-start message on a website', () => {
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

  it('is drawn once a session, not on every page of the visit, and again in the next session', async () => {
    queue = [message('welcome', { kind: 'session_start' }, {}, {})];
    open();
    await settle();
    expect(shown()).toEqual(['welcome']);

    // Two more pages of the same visit, and a reload: nothing.
    openLater();
    await settle();
    vi.setSystemTime(Date.now() + 5_000);
    open();
    await settle();
    vi.stubGlobal('performance', { now: () => 0, getEntriesByType: () => [{ type: 'reload' }] });
    open();
    await settle();
    expect(shown()).toEqual(['welcome']);
    expect(displayed()).toEqual(['welcome']);

    // Back after the session has ended: a new session, and the message is a session's.
    vi.setSystemTime(Date.now() + 31 * 60 * 1000);
    open();
    await settle();
    expect(shown()).toEqual(['welcome', 'welcome']);
    expect(displayed()).toEqual(['welcome', 'welcome']);
  });

  it('a message that arrives later in the visit is still drawn on the next page', async () => {
    open();
    await settle();
    expect(shown()).toEqual([]);
    queue = [message('late', { kind: 'session_start' }, {}, {})];
    openLater();
    await settle();
    expect(shown()).toEqual(['late']);
    openLater();
    await settle();
    expect(shown()).toEqual(['late']);
  });
});
