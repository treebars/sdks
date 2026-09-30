import { describe, expect, it } from 'vitest';

import { InAppStore, type InAppMessage } from '../src/in-app';
import { categoriesOf, ctaOf, destinationOf, orderForCenter } from '../src/notification-center';
import type { TreebarsNotification } from '../src/notifications';

/* Cards: pinned first, held until show_from, grouped by category, and where a tap goes. */

const row = (id: string, card?: Record<string, unknown>, deep_link?: string): TreebarsNotification =>
  ({
    group_id: id,
    campaign_id: null,
    channel_type: 'in_app',
    device_count: 1,
    content: { title: id, ...(deep_link ? { deep_link } : {}), in_app: { surface: 'inbox', layout: 'modal', trigger: { kind: 'immediate' }, ...(card ? { card } : {}) } },
    created_at: '2026-09-23T00:00:00Z',
    read_at: null,
    opened_at: null,
    expires_at: null,
  }) as TreebarsNotification;

describe('the notification centre', () => {
  it('puts pinned cards first and keeps the rest newest first', () => {
    const rows = [row('a'), row('b', { template: 'basic', pinned: true }), row('c')];
    expect(orderForCenter(rows).map((one) => one.group_id)).toEqual(['b', 'a', 'c']);
  });

  it('names the categories in the order they are first seen', () => {
    expect(categoriesOf([row('a', { template: 'basic', category: 'Offers' }), row('b'), row('c', { template: 'basic', category: 'News' }), row('d', { template: 'basic', category: 'Offers' })])).toEqual(['Offers', 'News']);
  });

  // A button on the card, apart from a tap on it, drawn only when it has words and somewhere to go.
  it('offers the card’s own button only when it is whole', () => {
    const cta = { label: 'Shop the sale', action: { type: 'deep_link', value: 'app://sale' } };
    expect(ctaOf(row('a', { template: 'basic', cta }))).toEqual(cta);
    expect(ctaOf(row('a', { template: 'basic', cta: { ...cta, label: '' } }))).toBeUndefined();
    expect(ctaOf(row('a', { template: 'basic', cta: { ...cta, action: { type: 'url', value: '' } } }))).toBeUndefined();
    expect(ctaOf(row('a'))).toBeUndefined();
    // The tap still goes where the card's own action says, not where its button does.
    expect(destinationOf(row('a', { template: 'basic', cta }, 'app://b'))).toBe('app://b');
  });

  it('goes where the card says, else where the push said', () => {
    expect(destinationOf(row('a', { template: 'basic', action: { type: 'url', value: 'https://x.example/a' } }, 'app://b'))).toBe('https://x.example/a');
    expect(destinationOf(row('a', undefined, 'app://b'))).toBe('app://b');
    expect(destinationOf(row('a'))).toBeUndefined();
  });
});

describe('the in-app inbox', () => {
  it('leaves out a card before its show_from, and lists pinned cards first', () => {
    const message = (id: string, card?: Record<string, unknown>): InAppMessage =>
      ({ delivery_id: id, campaign_id: null, created_at: '', expires_at: null, content: { in_app: { surface: 'inbox', layout: 'modal', trigger: { kind: 'immediate' }, ...(card ? { card } : {}) } } }) as InAppMessage;
    const store = new InAppStore(false);
    store.accept({
      messages: [message('a'), message('later', { template: 'basic', show_from: '2026-10-01T00:00:00Z' }), message('pinned', { template: 'basic', pinned: true })],
      policy: null,
      server_time: '',
    });
    expect(store.inbox(Date.parse('2026-09-23T00:00:00Z')).map((m) => m.delivery_id)).toEqual(['pinned', 'a']);
    expect(store.inbox(Date.parse('2026-10-02T00:00:00Z')).map((m) => m.delivery_id)).toEqual(['pinned', 'a', 'later']);
  });
});
