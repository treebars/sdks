import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { TreebarsWeb } from '../src/index';
import { NotificationStore, type NotificationTopic, type TreebarsNotification } from '../src/notifications';

/**
 * Topics: the centre's tabs. A page asks for one tab with `topic=`, a first page carries the tabs with their counts,
 * and a mark-all of one tab sends that tab with its watermark — and marks only that tab's rows here meanwhile.
 */

const row = (id: string, topic: string | null, created = '2026-10-11T12:00:00.000Z'): TreebarsNotification => ({
  group_id: id,
  campaign_id: null,
  channel_type: 'push',
  device_count: 1,
  content: { title: id },
  created_at: created,
  read_at: null,
  opened_at: null,
  expires_at: null,
  topic: topic ? { key: topic, name: topic } : null,
});

const tabs = (all: number, offers: number, news: number): NotificationTopic[] => [
  { key: null, name: 'All', unread: all, total: 9 },
  { key: 'offers', name: 'Offers', unread: offers, total: 4 },
  { key: 'news', name: 'News', unread: news, total: 3 },
];

describe('the store’s overlay of the tabs', () => {
  it('empties one tab after its mark-all, takes it off All, and leaves the other tabs alone', () => {
    const store = new NotificationStore(false);
    const rows = [row('o1', 'offers'), row('n1', 'news'), row('x1', null)];
    store.noteReadThrough('2026-10-11T13:00:00.000Z', 'offers');
    const page = store.present(rows, 5, tabs(5, 2, 1));
    expect(page.topics!.map((tab) => tab.unread)).toEqual([3, 0, 1]);
    // Only that tab's rows read as read here.
    expect(page.notifications.map((one) => Boolean(one.read_at))).toEqual([true, false, false]);
    // And All is the badge.
    expect(page.unreadCount).toBe(3);
  });

  it('empties every tab after a mark-all of everything', () => {
    const store = new NotificationStore(false);
    store.noteReadThrough('2026-10-11T13:00:00.000Z');
    const page = store.present([row('o1', 'offers')], 3, tabs(3, 2, 1));
    expect(page.topics!.map((tab) => tab.unread)).toEqual([0, 0, 0]);
    expect(page.unreadCount).toBe(0);
  });

  it('takes a row marked on its own off its tab and off All, when it came with the tabs', () => {
    const store = new NotificationStore(false);
    store.noteRead('n1');
    const page = store.present([row('o1', 'offers'), row('n1', 'news')], 3, tabs(3, 2, 1));
    expect(page.topics!.map((tab) => tab.unread)).toEqual([2, 2, 0]);
    expect(page.unreadCount).toBe(2);
  });

  it('forgets a tab’s mark-all once the server counts nothing unread in it, and not before', () => {
    const store = new NotificationStore(false);
    store.noteReadThrough('2026-10-11T13:00:00.000Z', 'offers');
    // A first page with no row of the tab is not the server agreeing.
    store.settleTopics(tabs(3, 2, 1));
    expect(store.present([], 3, tabs(3, 2, 1)).topics![1]!.unread).toBe(0);
    store.settleTopics(tabs(1, 0, 1));
    // Forgotten: a row of that tab the server still calls unread reads as unread again.
    expect(store.present([row('o1', 'offers')], 2, tabs(2, 1, 1)).topics![1]!.unread).toBe(1);
  });

  it('draws no tabs where the server sent none', () => {
    expect(new NotificationStore(false).present([row('a', null)], 1, undefined).topics).toBeUndefined();
  });
});

describe('asking the server for a tab', () => {
  let requests: { url: URL; body: Record<string, unknown> | null }[];
  let sdk: TreebarsWeb | null;
  let local: Map<string, string>;

  beforeEach(() => {
    vi.useFakeTimers({ now: Date.parse('2026-10-11T12:30:00.000Z') });
    requests = [];
    sdk = null;
    local = new Map();
    vi.stubGlobal('localStorage', {
      get length() {
        return local.size;
      },
      key: (index: number) => [...local.keys()][index] ?? null,
      getItem: (key: string) => local.get(key) ?? null,
      setItem: (key: string, value: string) => void local.set(key, value),
      removeItem: (key: string) => void local.delete(key),
      clear: () => local.clear(),
    });
    vi.stubGlobal('navigator', { userAgent: 'vitest', language: 'en-GB', sendBeacon: () => true });
    vi.stubGlobal('document', Object.assign(new EventTarget(), { visibilityState: 'visible', title: 'Shop', referrer: '', cookie: '' }));
    vi.stubGlobal(
      'window',
      Object.assign(new EventTarget(), {
        screen: { width: 1280, height: 800 },
        devicePixelRatio: 1,
        location: { href: 'https://shop.test/', pathname: '/', origin: 'https://shop.test', hostname: 'shop.test', protocol: 'https:' },
      }),
    );
    vi.stubGlobal(
      'fetch',
      vi.fn(async (input: string, init?: RequestInit) => {
        const url = new URL(input);
        requests.push({ url, body: typeof init?.body === 'string' && url.pathname.endsWith('/state') ? JSON.parse(init.body) : null });
        if (url.pathname === '/v1/notifications') {
          const topic = url.searchParams.get('topic');
          return Response.json({
            notifications: topic ? [row('o1', 'offers')] : [row('o1', 'offers'), row('n1', 'news')],
            unread_count: 3,
            next_cursor: null,
            ...(url.searchParams.get('cursor') ? {} : { topics: tabs(3, 2, 1) }),
            server_time: '2026-10-11T12:30:00.000Z',
          });
        }
        return Response.json({ accepted: 1, messages: [], unread_count: 1, server_time: '2026-10-11T12:30:00.000Z' });
      }),
    );
  });

  afterEach(() => {
    sdk?.shutdown();
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  function start(): TreebarsWeb {
    sdk = new TreebarsWeb();
    sdk.init({ writeKey: 'pk_live_topics', backendUrl: 'https://ingest.test', autoPageViews: false, flushIntervalMs: 60 * 60 * 1000 });
    return sdk;
  }

  const reads = () => requests.filter((one) => one.url.pathname === '/v1/notifications').map((one) => one.url.searchParams);

  it('sends topic on a list, and never keeps a tab’s page as the first page', async () => {
    const instance = start();
    await vi.runOnlyPendingTimersAsync();
    const all = await instance.notifications.list();
    expect(all.topics?.map((tab) => tab.name)).toEqual(['All', 'Offers', 'News']);
    expect(reads().at(-1)!.has('topic')).toBe(false);

    const offers = await instance.notifications.list({ topic: 'offers' });
    expect(reads().at(-1)!.get('topic')).toBe('offers');
    expect(offers.notifications.map((one) => one.group_id)).toEqual(['o1']);

    // Offline: All still answers with All's page, and a tab with that page's rows of the tab.
    vi.mocked(fetch).mockRejectedValue(new Error('offline'));
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    expect((await instance.notifications.list()).notifications.map((one) => one.group_id)).toEqual(['o1', 'n1']);
    const news = await instance.notifications.list({ topic: 'news' });
    expect(news.notifications.map((one) => one.group_id)).toEqual(['n1']);
    expect(news.fromCache).toBe(true);
  });

  it('answers topics() and a tab’s unread count, and marks one tab read with its topic', async () => {
    const instance = start();
    await vi.runOnlyPendingTimersAsync();
    expect((await instance.notifications.topics()).map((tab) => `${tab.key}:${tab.unread}`)).toEqual(['null:3', 'offers:2', 'news:1']);
    expect(await instance.notifications.unreadCount('offers')).toBe(2);
    expect(await instance.notifications.unreadCount()).toBe(3);

    await instance.notifications.markAllRead('offers');
    const state = requests.find((one) => one.url.pathname === '/v1/notifications/state')!;
    expect(state.body).toMatchObject({ read_through: '2026-10-11T12:30:00.000Z', topic: 'offers' });

    // Until the server agrees, this browser counts that tab as read and takes it off All.
    expect((await instance.notifications.topics()).map((tab) => tab.unread)).toEqual([1, 0, 1]);
    expect(await instance.notifications.unreadCount('offers')).toBe(0);

    await instance.notifications.markAllRead();
    const everything = requests.filter((one) => one.url.pathname === '/v1/notifications/state').at(-1)!;
    expect(everything.body).not.toHaveProperty('topic');
    expect((await instance.notifications.topics())[0]!.unread).toBe(0);
  });
});
