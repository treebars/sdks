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
});
