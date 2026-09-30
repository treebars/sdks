import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import type { WebExperienceWire } from '../src/experiences';
import { TreebarsWeb } from '../src/index';
import { FakeElement, fakeDocument } from './fake-dom';

/*
 * What happens to an experience after the first paint: which redirect is followed and counted, a goal credited once
 * however often the page is viewed, exposures that end when the experience does or the person signs out, and a
 * single-page app's next page taking back what it no longer runs.
 */

function webStorage() {
  const map = new Map<string, string>();
  return {
    map,
    get length() {
      return map.size;
    },
    key: (index: number) => [...map.keys()][index] ?? null,
    getItem: (key: string) => map.get(key) ?? null,
    setItem: (key: string, value: string) => void map.set(key, value),
    removeItem: (key: string) => void map.delete(key),
    clear: () => map.clear(),
  };
}

const ids = {
  sale: '1a1a1a1a-0000-4000-8000-000000000001',
  product: '1a1a1a1a-0000-4000-8000-000000000002',
  hero: '1a1a1a1a-0000-4000-8000-000000000003',
};

function split(id: string, priority: number, to: string, page = 'https://shop.test/'): WebExperienceWire {
  return {
    id,
    kind: 'split_url',
    url_rules: [{ op: 'contains', value: page }],
    url_match: 'all',
    rules: [],
    variations: [{ id: 'b', weight: 100, changes: [], redirect_url: to }],
    goal_event: 'purchase',
    priority,
  };
}

const control = (id: string, goal: string): WebExperienceWire => ({
  id,
  kind: 'visual',
  url_rules: [{ op: 'contains', value: 'shop.test' }],
  url_match: 'all',
  rules: [],
  variations: [{ id: 'a', weight: 100, control: true, changes: [] }],
  goal_event: goal,
  priority: 5,
});

describe('experiences after the first paint', () => {
  let local: ReturnType<typeof webStorage>;
  let session: ReturnType<typeof webStorage>;
  let replace: ReturnType<typeof vi.fn>;
  let location: { href: string; pathname: string; search: string; origin: string; hostname: string; protocol: string; replace: typeof replace };
  let served: WebExperienceWire[];
  let sdks: TreebarsWeb[];

  beforeEach(() => {
    local = webStorage();
    session = webStorage();
    replace = vi.fn();
    sdks = [];
    served = [];
    vi.stubGlobal('localStorage', local);
    vi.stubGlobal('sessionStorage', session);
    vi.stubGlobal('navigator', { userAgent: 'vitest', language: 'en-GB', sendBeacon: () => true });
    vi.stubGlobal('document', Object.assign(new EventTarget(), { visibilityState: 'visible', title: 'Shop', referrer: '', cookie: '', readyState: 'complete', getElementById: () => null }));
    location = { href: 'https://shop.test/', pathname: '/', search: '', origin: 'https://shop.test', hostname: 'shop.test', protocol: 'https:', replace };
    vi.stubGlobal('location', location);
    vi.stubGlobal('window', Object.assign(new EventTarget(), { screen: { width: 1280, height: 800 }, devicePixelRatio: 1, location }));
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string) =>
        new URL(url).pathname === '/v1/experiences'
          ? Response.json({ experiences: served })
          : Response.json({ accepted: 1, messages: [], notifications: [], unread_count: 0, server_time: 'now' }),
      ),
    );
  });

  afterEach(() => {
    for (const sdk of sdks) sdk.shutdown();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  /** A page load: a fresh SDK over the same storage, with the experiences fetched and decided. */
  async function load(options: { disableStorage?: boolean } = {}) {
    const sdk = new TreebarsWeb();
    sdks.push(sdk);
    const track = vi.spyOn(sdk, 'track');
    sdk.init({ writeKey: 'pk_live_web', backendUrl: 'https://ingest.test', autoPageViews: false, experiences: true, flushIntervalMs: 60 * 60 * 1000, ...options });
    await vi.waitFor(() => expect((sdk as unknown as { experienceList: unknown }).experienceList).toEqual(served), { timeout: 3000, interval: 10 });
    const named = (name: string) => track.mock.calls.filter(([event]) => event === name).map(([, properties]) => properties);
    return { sdk, named };
  }
  const exposures = () => JSON.parse(local.getItem('treebars.experiences.v1') ?? '{}') as Record<string, { variation_id: string; converted?: boolean }>;

  it('follows one redirect when two split-URL tests match — the higher priority’s — and counts only it', async () => {
    served = [split(ids.sale, 3, 'https://shop.test/sale.html'), split(ids.product, 8, 'https://shop.test/product.html')];
    const { named } = await load();
    expect(replace.mock.calls).toEqual([['https://shop.test/product.html']]);
    expect(named('experience_viewed')).toEqual([{ experience_id: ids.product, variation_id: 'b' }]);
    expect(Object.keys(exposures())).toEqual([ids.product]);
  });

  it('does not send the visitor on again when the host served the target under another address', async () => {
    // `/sale.html` is served as `/sale`, and the test's page rule (`sale`) matches both.
    served = [split(ids.sale, 5, 'https://shop.test/sale.html', 'sale')];
    location.href = 'https://shop.test/sale';
    location.pathname = '/sale';
    const first = await load();
    expect(replace).toHaveBeenCalledTimes(1);
    expect(first.named('experience_viewed')).toEqual([{ experience_id: ids.sale, variation_id: 'b' }]);

    // The host answers with `/sale` again: a new page load in the same tab.
    const second = await load();
    expect(replace).toHaveBeenCalledTimes(1);
    // A router's replaceState is a new decision on the same page, and it must not start the loop again either.
    second.sdk.track('page_view', { url: location.href });
    expect(replace).toHaveBeenCalledTimes(1);
    // Arrived: counted once, and not a second visitor.
    expect(second.named('experience_viewed')).toEqual([{ experience_id: ids.sale, variation_id: 'b' }]);

    // Later in the same tab, a fresh visit to the page is decided afresh.
    const third = await load();
    expect(third.named('experience_viewed')).toEqual([{ experience_id: ids.sale, variation_id: 'b' }]);
    expect(replace).toHaveBeenCalledTimes(2);
  });

  it('does not redirect at all where nothing can be stored, and counts nothing for it', async () => {
    served = [split(ids.sale, 5, 'https://shop.test/sale.html')];
    session.setItem('treebars.split_hop.v1', JSON.stringify({ experience_id: ids.sale, at: Date.now() }));
    const { sdk, named } = await load({ disableStorage: true });
    expect(replace).not.toHaveBeenCalled();
    expect(named('experience_viewed')).toEqual([]);
    // And storage is left alone, as everywhere else in that mode: not read, not cleared.
    sdk.identify('user_1');
    sdk.reset();
    expect(session.getItem('treebars.split_hop.v1')).not.toBeNull();
  });

  it('credits a goal once per experience, however many times the page is viewed after it', async () => {
    served = [control(ids.hero, 'add_to_cart')];
    const first = await load();
    first.sdk.track('add_to_cart', {});
    expect(first.named('experience_converted')).toHaveLength(1);
    const again = await load();
    expect(again.named('experience_viewed')).toHaveLength(1);
    again.sdk.track('add_to_cart', {});
    expect(again.named('experience_converted')).toEqual([]);
    expect(exposures()[ids.hero]?.converted).toBe(true);
  });

  it('stops crediting an experience that is no longer running, and forgets every exposure at sign-out', async () => {
    served = [control(ids.hero, 'add_to_cart'), control(ids.sale, 'signup')];
    await load();
    expect(Object.keys(exposures()).sort()).toEqual([ids.hero, ids.sale].sort());

    served = [control(ids.sale, 'signup')];
    const paused = await load();
    expect(Object.keys(exposures())).toEqual([ids.sale]);
    paused.sdk.track('add_to_cart', {});
    expect(paused.named('experience_converted')).toEqual([]);

    paused.sdk.identify('user_1');
    paused.sdk.reset();
    expect(exposures()).toEqual({});
    paused.sdk.track('signup', {});
    expect(paused.named('experience_converted')).toEqual([]);
  });

  it('takes a change back on a single-page app’s next page that the experience does not run on', async () => {
    const title = new FakeElement('h1', {}, []);
    title.textContent = 'Pricing';
    const header = new FakeElement('header', {}, [title]);
    vi.stubGlobal('document', Object.assign(new EventTarget(), fakeDocument(new FakeElement('body', {}, [header])), { visibilityState: 'visible', title: 'Shop', referrer: '', cookie: '', readyState: 'complete', getElementById: () => null }));
    served = [
      {
        id: ids.hero,
        kind: 'visual',
        url_rules: [{ op: 'path_equals', value: '/pricing' }],
        url_match: 'all',
        rules: [],
        variations: [{ id: 'b', weight: 100, changes: [{ op: 'text', selector: 'header > h1', value: 'Half price' }] }],
        goal_event: null,
        priority: 5,
      },
    ];
    location.href = 'https://shop.test/pricing';
    location.pathname = '/pricing';
    const { sdk } = await load();
    expect(title.textContent).toBe('Half price');

    location.href = 'https://shop.test/about';
    location.pathname = '/about';
    sdk.track('page_view', { url: location.href });
    expect(title.textContent).toBe('Pricing');

    // Back on a page it runs on, it is put on again.
    location.href = 'https://shop.test/pricing';
    location.pathname = '/pricing';
    sdk.track('page_view', { url: location.href });
    expect(title.textContent).toBe('Half price');
  });
});
