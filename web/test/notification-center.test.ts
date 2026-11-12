import { afterEach, describe, expect, it, vi } from 'vitest';

import { categoriesOf, ctaOf, destinationOf, mountNotificationCenter, orderForCenter, type NotificationCenterHost } from '../src/notification-center';
import type { NotificationPage, TreebarsNotification } from '../src/notifications';
import { FakeNode, install } from './fake-dom';

/**
 * The ready-made notification centre: a site that wants the list without writing one mounts it on an element. What a
 * person sees and does in it is pinned here — the order, the category tabs, the unread dot, a tap that marks the row
 * opened and goes where it says, the card's own button, removing a row, and "Show more" while the server has more.
 */

const row = (id: string, over: Partial<TreebarsNotification> & { card?: Record<string, unknown> } = {}): TreebarsNotification => {
  const { card, ...rest } = over;
  return {
    group_id: id,
    campaign_id: null,
    channel_type: card ? 'in_app' : 'push',
    device_count: 1,
    content: { title: `Title ${id}`, body: `Body ${id}`, ...(card ? { in_app: { surface: 'inbox', layout: 'modal', card } as never } : {}) },
    created_at: '2026-10-11T12:00:00.000Z',
    read_at: null,
    opened_at: null,
    expires_at: null,
    ...rest,
  };
};

const page = (notifications: TreebarsNotification[], nextCursor: string | null = null): NotificationPage => ({ notifications, unreadCount: notifications.filter((n) => !n.read_at).length, nextCursor, fromCache: false });

/** A host over fixed pages: the first for no cursor, the rest by cursor; and a way to push a changed first page. */
function hostOf(first: NotificationPage, deeper: Record<string, NotificationPage> = {}) {
  let listener: ((next: NotificationPage) => void) | null = null;
  const calls: string[] = [];
  const host: NotificationCenterHost = {
    list: async ({ cursor }) => (cursor ? deeper[cursor]! : first),
    markOpened: async (id) => void calls.push(`opened ${id}`),
    markAllRead: async () => void calls.push('all read'),
    dismiss: async (id) => void calls.push(`dismissed ${id}`),
    onChange: (callback) => {
      listener = callback;
      return () => {
        listener = null;
        calls.push('stopped');
      };
    },
  };
  return { host, calls, change: (next: NotificationPage) => listener?.(next), listening: () => listener !== null };
}

const settle = async () => {
  for (let turn = 0; turn < 10; turn += 1) await Promise.resolve();
};

/** The titles of the rows on screen, in order. */
const titles = (target: FakeNode) => target.all().filter((node) => node.tagName === 'strong' && node.textContent.startsWith('Title ')).map((node) => node.textContent.slice(6));

describe('the notification centre’s rules', () => {
  it('puts pinned cards first and keeps the server’s order otherwise', () => {
    const rows = [row('a'), row('b', { card: { pinned: true } }), row('c'), row('d', { card: { pinned: true } })];
    expect(orderForCenter(rows).map((r) => r.group_id)).toEqual(['b', 'd', 'a', 'c']);
  });

  it('names each card category once, in first-seen order', () => {
    expect(categoriesOf([row('a', { card: { category: 'Offers' } }), row('b'), row('c', { card: { category: 'News' } }), row('d', { card: { category: 'Offers' } })])).toEqual(['Offers', 'News']);
  });

  it('goes where the card says, else where the push said; and offers a card’s button only with words and a place', () => {
    expect(destinationOf(row('a', { card: { action: { value: 'https://shop.test/sale' } } }))).toBe('https://shop.test/sale');
    expect(destinationOf({ ...row('b'), content: { deep_link: 'shop://cart' } })).toBe('shop://cart');
    expect(destinationOf(row('c'))).toBeUndefined();
    expect(ctaOf(row('d', { card: { cta: { label: 'Claim', action: { value: '/claim' } } } }))?.label).toBe('Claim');
    expect(ctaOf(row('e', { card: { cta: { label: 'Claim' } } }))).toBeUndefined();
    expect(ctaOf(row('f', { card: { cta: { label: '', action: { value: '/x' } } } }))).toBeUndefined();
  });
});

describe('the mounted notification centre', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('draws the rows with an unread dot, says when there is nothing, and marks everything read', async () => {
    const { body } = install();
    const { host, calls } = hostOf(page([row('a'), row('b', { read_at: '2026-10-11T13:00:00.000Z' })]));
    mountNotificationCenter(body as never, host, { title: 'Inbox' });
    await settle();
    expect(body.find((node) => node.getAttribute('role') === 'region')?.getAttribute('aria-label')).toBe('Inbox');
    expect(titles(body)).toEqual(['a', 'b']);
    expect(body.all().filter((node) => node.getAttribute('aria-label') === 'Unread')).toHaveLength(1);
    body.byName('Mark all read')!.click();
    expect(calls).toEqual(['all read']);

    const empty = install();
    mountNotificationCenter(empty.body as never, hostOf(page([])).host, { emptyText: 'All caught up.' });
    await settle();
    expect(empty.body.textContent).toContain('All caught up.');
  });

  it('a tap marks the row opened and goes where it says, unless the page handles it', async () => {
    const { body } = install();
    const assign = vi.fn();
    vi.stubGlobal('location', { assign });
    const { host, calls } = hostOf(page([row('a', { card: { action: { value: '/sale' } } }), row('b', { card: { action: { value: '/news' } } })]));
    const handled: string[] = [];
    mountNotificationCenter(body as never, host, { onOpen: (n) => (n.group_id === 'b' ? (handled.push('b'), false) : undefined) });
    await settle();
    const rowButton = (title: string) => body.find((node) => node.tagName === 'button' && node.textContent.includes(`Title ${title}`))!;
    rowButton('a').click();
    rowButton('b').click();
    expect(calls).toEqual(['opened a', 'opened b']);
    expect(assign.mock.calls).toEqual([['/sale']]);
    expect(handled).toEqual(['b']);
  });

  it('draws a card’s own button beside the card, and it goes where the button says', async () => {
    const { body } = install();
    const assign = vi.fn();
    vi.stubGlobal('location', { assign });
    const { host, calls } = hostOf(page([row('a', { card: { action: { value: '/card' }, cta: { label: 'Claim', action: { value: '/claim' } } } })]));
    mountNotificationCenter(body as never, host);
    await settle();
    const cta = body.byName('Claim')!;
    // A sibling of the row's own control, never inside it: a button in a button is two taps on one press.
    expect(cta.parent!.tagName).toBe('li');
    cta.click();
    expect(calls).toEqual(['opened a']);
    expect(assign.mock.calls).toEqual([['/claim']]);
  });

  it('shows a tab per category when there is more than one, and a tab shows only its own', async () => {
    const { body } = install();
    mountNotificationCenter(body as never, hostOf(page([row('a', { card: { category: 'Offers' } }), row('b', { card: { category: 'News' } }), row('c')])).host);
    await settle();
    const tabs = () => body.all().filter((node) => node.getAttribute('role') === 'tab').map((node) => `${node.textContent}${node.getAttribute('aria-selected') === 'true' ? '*' : ''}`);
    expect(tabs()).toEqual(['All*', 'Offers', 'News']);
    body.find((node) => node.getAttribute('role') === 'tab' && node.textContent === 'News')!.click();
    expect(tabs()).toEqual(['All', 'Offers', 'News*']);
    expect(titles(body)).toEqual(['b']);

    const single = install();
    mountNotificationCenter(single.body as never, hostOf(page([row('a', { card: { category: 'Offers' } }), row('b')])).host);
    await settle();
    expect(single.body.all().filter((node) => node.getAttribute('role') === 'tab')).toHaveLength(0);
  });

  it('removes a row at once, from a deeper page too, and asks the server to dismiss it', async () => {
    const { body } = install();
    const { host, calls } = hostOf(page([row('a')], 'p2'), { p2: page([row('b'), row('c')]) });
    mountNotificationCenter(body as never, host);
    await settle();
    const more = body.byName('Show more')!;
    expect(more.style.display).toBe('block');
    more.click();
    await settle();
    expect(titles(body)).toEqual(['a', 'b', 'c']);
    expect(more.style.display).toBe('none');
    const removeOf = (title: string) => body.find((node) => node.tagName === 'li' && node.textContent.includes(`Title ${title}`))!.byName('Remove')!;
    removeOf('b').click();
    expect(titles(body)).toEqual(['a', 'c']);
    expect(calls).toEqual(['dismissed b']);
  });

  it('a changed first page replaces it and keeps the deeper pages; unmounting stops listening and takes it down', async () => {
    const { body } = install();
    const { host, calls, change, listening } = hostOf(page([row('a')], 'p2'), { p2: page([row('b')]) });
    const unmount = mountNotificationCenter(body as never, host);
    await settle();
    body.byName('Show more')!.click();
    await settle();
    // The first page now carries "b" too: it is shown once.
    change(page([row('z'), row('b')], 'p2'));
    expect(titles(body)).toEqual(['z', 'b']);
    unmount();
    expect(listening()).toBe(false);
    expect(calls).toEqual(['stopped']);
    expect(body.children).toHaveLength(0);
  });

  it('draws the server’s topic tabs with their unread counts, lists a tab from the server, and marks that tab read', async () => {
    const { body } = install();
    const tabsOf = (unread: [number, number, number]) => [
      { key: null, name: 'All', unread: unread[0], total: 5 },
      { key: 'offers', name: 'Offers', unread: unread[1], total: 3 },
      { key: 'news', name: 'News', unread: unread[2], total: 0 },
    ];
    const asked: (string | null)[] = [];
    const calls: string[] = [];
    let listener: ((next: NotificationPage) => void) | null = null;
    const byTopic: Record<string, NotificationPage> = {
      all: { ...page([row('a', { card: { category: 'Ignored' } }), row('b')]), topics: tabsOf([3, 2, 0]) },
      offers: { ...page([row('o1'), row('o2')], 'o-next'), topics: tabsOf([3, 2, 0]) },
      'o-next': page([row('o3')]),
    };
    const host: NotificationCenterHost = {
      list: async ({ cursor, topic }) => {
        asked.push(cursor ? `${topic} ${cursor}` : (topic ?? null));
        return byTopic[cursor ?? topic ?? 'all']!;
      },
      markOpened: async (id) => void calls.push(`opened ${id}`),
      markAllRead: async (topic) => void calls.push(`all read ${topic ?? 'everything'}`),
      dismiss: async (id) => void calls.push(`dismissed ${id}`),
      onChange: (callback) => {
        listener = callback;
        return () => (listener = null);
      },
    };
    mountNotificationCenter(body as never, host);
    await settle();
    const tabs = () => body.all().filter((node) => node.getAttribute('role') === 'tab').map((node) => `${node.textContent}${node.getAttribute('aria-selected') === 'true' ? '*' : ''}`);
    // The server's tabs win over the card categories, and a tab with nothing unread shows no count.
    expect(tabs()).toEqual(['All3*', 'Offers2', 'News']);
    expect(body.byName('Offers, 2 unread')).toBeDefined();
    expect(titles(body)).toEqual(['a', 'b']);

    body.find((node) => node.getAttribute('role') === 'tab' && node.textContent.startsWith('Offers'))!.click();
    await settle();
    expect(tabs()).toEqual(['All3', 'Offers2*', 'News']);
    expect(titles(body)).toEqual(['o1', 'o2']);
    body.byName('Show more')!.click();
    await settle();
    expect(titles(body)).toEqual(['o1', 'o2', 'o3']);
    expect(asked).toEqual([null, 'offers', 'offers o-next']);

    body.byName('Mark all read')!.click();
    expect(calls).toEqual(['all read offers']);

    // A change while a topic tab is in view takes the new counts and asks the server for that tab again.
    byTopic.offers = { ...page([row('o1', { read_at: '2026-10-11T13:00:00.000Z' })]), topics: tabsOf([1, 0, 0]) };
    listener!({ ...page([row('a')]), topics: tabsOf([1, 0, 0]) });
    await settle();
    expect(tabs()).toEqual(['All1', 'Offers*', 'News']);
    // The tab's first page again, and the deeper page kept, as on All.
    expect(titles(body)).toEqual(['o1', 'o3']);
    expect(asked.at(-1)).toBe('offers');

    // A tab the server no longer has goes back to All.
    byTopic.all = { ...page([row('a')]), topics: [{ key: null, name: 'All', unread: 1, total: 1 }, { key: 'news', name: 'News', unread: 0, total: 0 }] };
    listener!(byTopic.all);
    await settle();
    expect(tabs()).toEqual(['All1*', 'News']);
    expect(titles(body)).toEqual(['a']);
    body.byName('Mark all read')!.click();
    expect(calls.at(-1)).toBe('all read everything');
  });

  it('drops a tab’s page that lands after another tab was chosen, and draws no tabs for All alone', async () => {
    const { body } = install();
    let release: (() => void) | null = null;
    const host: NotificationCenterHost = {
      list: ({ topic }) =>
        topic === 'slow'
          ? new Promise((resolve) => (release = () => resolve({ ...page([row('late')]) })))
          : Promise.resolve({
              ...page([row(topic ?? 'all')]),
              topics: [
                { key: null, name: 'All', unread: 0, total: 2 },
                { key: 'slow', name: 'Slow', unread: 0, total: 1 },
                { key: 'fast', name: 'Fast', unread: 0, total: 1 },
              ],
            }),
      markOpened: async () => {},
      markAllRead: async () => {},
      dismiss: async () => {},
      onChange: () => () => {},
    };
    mountNotificationCenter(body as never, host);
    await settle();
    const tab = (name: string) => body.find((node) => node.getAttribute('role') === 'tab' && node.textContent === name)!;
    tab('Slow').click();
    await settle();
    tab('Fast').click();
    await settle();
    expect(titles(body)).toEqual(['fast']);
    release!();
    await settle();
    expect(titles(body)).toEqual(['fast']);

    const lone = install();
    mountNotificationCenter(lone.body as never, hostOf({ ...page([row('a', { card: { category: 'Offers' } }), row('b', { card: { category: 'News' } })]), topics: [{ key: null, name: 'All', unread: 2, total: 2 }] }).host);
    await settle();
    // The server said there are no topics: no tabs, and not the category fallback either.
    expect(lone.body.all().filter((node) => node.getAttribute('role') === 'tab')).toHaveLength(0);
  });
});
