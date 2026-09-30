import { describe, expect, it } from 'vitest';
import { inAppClickProperties, type InAppButton, type InAppMessage } from '../src/in-app';

/*
 * Which element was pressed. `treebars://click/<n>` keeps its number and a typed button its place, so a message with
 * two buttons reports which of them was pressed rather than one undifferentiated count.
 */
const buttons: InAppButton[] = [
  { label: 'Shop now', action: 'url', value: 'https://shop.example.com' },
  { label: 'Later', action: 'dismiss' },
];
const message: InAppMessage = {
  delivery_id: 'del_1',
  campaign_id: 'cmp_1',
  content: { in_app: { surface: 'overlay', layout: 'modal', buttons } as never },
  created_at: '2026-09-27T00:00:00.000Z',
  expires_at: null,
};

describe('in_app_clicked says what was pressed', () => {
  it('numbers a typed button from 1 by its place, with its label', () => {
    expect(inAppClickProperties(message, buttons[0]!)).toEqual({
      treebars_delivery_id: 'del_1',
      treebars_campaign_id: 'cmp_1',
      destination: 'https://shop.example.com',
      button_index: 1,
      button_label: 'Shop now',
    });
  });

  it('keeps a markup body’s own number, and invents no label', () => {
    expect(inAppClickProperties(message, { action: 'click' as never, label: '', index: 2 })).toEqual({
      treebars_delivery_id: 'del_1',
      treebars_campaign_id: 'cmp_1',
      button_index: 2,
    });
  });
});
