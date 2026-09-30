import { describe, expect, it } from 'vitest';

import { BridgeDisplay, type BridgeSdk } from '../src/bridge-calls';
import type { InAppMessage } from '../src/in-app';

/**
 * What each `treebars` call means on the web, against a fake SDK. The frame, the policy and a real browser's messages
 * are an end-to-end check's to cover; this pins the meanings.
 */

function message(declared = { events: ['day_completed', 'offer_claimed'], traits: ['streak'] }): InAppMessage {
  return {
    delivery_id: 'd-1',
    campaign_id: 'c-1',
    content: { in_app: { surface: 'overlay', layout: 'modal', body_mode: 'html', html: '<p>x</p>', trigger: { kind: 'immediate' }, declared } },
    created_at: '2026-09-27T10:00:00.000Z',
    expires_at: null,
  };
}

function sdk() {
  const tracked: Array<[string, Record<string, unknown>]> = [];
  const traits: Record<string, unknown>[] = [];
  const said = { spent: 0, dismissed: 0, flushed: 0, announced: [] as Record<string, unknown>[], opened: [] as string[], asked: [] as string[] };
  const fake: BridgeSdk = {
    track: (name, properties) => tracked.push([name, properties]),
    // Where a trait goes — `identify()` or the anonymous person — is the SDK's, and the page cannot tell.
    setTraits: (next) => {
      traits.push(next);
      return { ok: true };
    },
    requestPushPermission: async () => 'granted',
    announceClicked: (data) => said.announced.push(data),
    open: (url, via) => said.opened.push(`${via} ${url}`),
    spent: () => (said.spent += 1),
    dismissed: () => (said.dismissed += 1),
    flush: () => (said.flushed += 1),
    log: () => {},
    claimReward: async (pool, deliveryId) => {
      said.asked.push(`${pool} ${deliveryId}`);
      return pool === 'wheel' ? { won: true, prize: '10% off', prize_id: 'off', code: 'AUTUMN-7' } : { ok: false, reason: 'not_available' };
    },
  };
  return { fake, tracked, traits, said };
}

const turn = () => new Promise((resolve) => setTimeout(resolve, 0));
const close = () => {};

describe('a display’s bridge on the web', () => {

  it('records one dismissal however it is asked for, and closes only on dismissMessage', () => {
    const { fake, tracked, said } = sdk();
    const display = new BridgeDisplay(message(), fake);
    let closed = 0;
    display.call('trackDismiss', ['close-btn'], () => (closed += 1));
    display.call('dismissMessage', [], () => (closed += 1));
    display.dismiss();
    expect(tracked.filter(([name]) => name === 'in_app_dismissed')).toEqual([
      ['in_app_dismissed', { treebars_delivery_id: 'd-1', treebars_campaign_id: 'c-1', element: 'close-btn' }],
    ]);
    expect(closed).toBe(1);
    expect(said.dismissed).toBe(2);
  });

  it('folds a click and the navigation asked in the same turn into one, then goes there', async () => {
    const { fake, tracked, said } = sdk();
    const display = new BridgeDisplay(message(), fake);
    display.call('openWebURL', ['https://shop.example/sale'], close);
    display.call('trackClick', [1], close);
    expect(said.opened).toEqual([]);
    await turn();
    expect(tracked).toEqual([
      ['in_app_clicked', { treebars_delivery_id: 'd-1', treebars_campaign_id: 'c-1', destination: 'https://shop.example/sale', element: '1', button_index: 1 }],
    ]);
    expect(said.opened).toEqual(['openWebURL https://shop.example/sale']);
    expect(said.spent).toBe(1);
    expect(said.flushed).toBe(1);
  });

  it('keeps trackClick(0) as "0", and refuses a URL that would run', async () => {
    const { fake, tracked } = sdk();
    const display = new BridgeDisplay(message(), fake);
    display.call('trackClick', [0], close);
    await turn();
    expect(tracked[0]![1]).toMatchObject({ element: '0' });
    expect(tracked[0]![1]).not.toHaveProperty('button_index');
    expect(display.call('openDeepLink', ['javascript:alert(1)'], close)).toEqual({ ok: false, reason: 'invalid_url' });
  });

  it('records a declared event with the campaign attached, and refuses the rest', () => {
    const { fake, tracked } = sdk();
    const display = new BridgeDisplay(message(), fake);
    expect(display.call('trackEvent', ['day_completed', { day: 3 }, {}, {}, false, false], close)).toEqual({ ok: true });
    expect(tracked.at(-1)).toEqual(['day_completed', { day: 3, treebars_delivery_id: 'd-1', treebars_campaign_id: 'c-1' }]);
    expect(display.call('trackEvent', ['made_up'], close)).toEqual({ ok: false, reason: 'undeclared' });
    expect(display.call('trackEvent', ['in_app_clicked'], close)).toEqual({ ok: false, reason: 'reserved' });
    expect(display.call('trackEvent', ['undefined'], close)).toEqual({ ok: false, reason: 'invalid_name' });
    // A repeat inside 250 ms is dropped.
    expect(display.call('trackEvent', ['day_completed', '{"day":4}'], close)).toEqual({ ok: false, reason: 'repeat' });
  });

  it('stops at twenty events a display', () => {
    const { fake } = sdk();
    const display = new BridgeDisplay(message({ events: Array.from({ length: 25 }, (_, i) => `e${i}`), traits: [] }), fake);
    const answers = Array.from({ length: 25 }, (_, i) => display.call('trackEvent', [`e${i}`], close));
    expect(answers.filter((answer) => (answer as { ok: boolean }).ok)).toHaveLength(20);
    expect(answers.at(-1)).toEqual({ ok: false, reason: 'limit' });
  });

  it('refuses identity, and sets only declared traits', () => {
    const signed = sdk();
    const display = new BridgeDisplay(message(), signed.fake);
    expect(display.call('identifyUser', ['u_2'], close)).toEqual({ ok: false, reason: 'identity_from_message' });
    expect(display.call('setUserAttribute', ['streak', 3], close)).toEqual({ ok: true });
    expect(display.call('setUserAttribute', ['vip', true], close)).toEqual({ ok: false, reason: 'undeclared' });
    expect(display.call('setUserAttribute', ['email', 'a@b.co'], close)).toEqual({ ok: false, reason: 'reserved' });
    expect(display.call('setFirstName', ['Ada'], close)).toEqual({ ok: true });
    expect(signed.traits).toEqual([{ streak: 3 }, { first_name: 'Ada' }]);
  });

  it('keeps an address as an opt-in, never as who somebody is', () => {
    const { fake, tracked } = sdk();
    const display = new BridgeDisplay(message(), fake);
    expect(display.call('setEmailId', ['ada@example.com'], close)).toEqual({ ok: true });
    expect(tracked.at(-1)).toEqual(['in_app_opted_in', { treebars_delivery_id: 'd-1', treebars_campaign_id: 'c-1', email: 'ada@example.com' }]);
    expect(display.call('setEmailId', ['not an address'], close)).toEqual({ ok: false, reason: 'invalid_value' });
  });

  it('reports screens, completion and a form from the runtime, the screen riding on what follows', async () => {
    const { fake, tracked, traits } = sdk();
    const display = new BridgeDisplay(message(), fake);
    display.call('_screen', ['welcome', 0, null, 'start'], close);
    display.call('_screen', ['interests', 1, 'welcome', 'next'], close);
    display.call('_submit', [{ interests: ['tech'] }, { email: 'ada@example.com', streak: '2', vip: 'yes' }], close);
    display.call('_complete', [2], close);
    display.call('trackClick', ['done'], close);
    await turn();
    // A press that moves the flow on is filed under the screen it was pressed on.
    display.call('trackClick', ['next'], close);
    display.call('_screen', ['thanks', 2, 'interests', 'next'], close);
    await turn();
    expect(tracked.at(-1)!).toEqual(['in_app_clicked', expect.objectContaining({ element: 'next', screen: 'interests' })]);
    expect(tracked.slice(0, 5).map(([name]) => name)).toEqual(['in_app_screen_viewed', 'in_app_screen_viewed', 'in_app_form_submitted', 'in_app_completed', 'in_app_clicked']);
    expect(tracked[1]![1]).toMatchObject({ screen: 'interests', index: 1, from: 'welcome', how: 'next' });
    expect(tracked[2]![1]).toMatchObject({ responses: { interests: 'tech' }, email: 'ada@example.com', screen: 'interests' });
    expect(tracked[4]![1]).toMatchObject({ element: 'done', screen: 'interests' });
    // Only a declared trait is kept.
    expect(traits).toEqual([{ streak: '2' }]);
  });

  it('keeps a value for the person in the campaign, reads it back, and forgets it', () => {
    const { fake, tracked } = sdk();
    const synced = { ...message(), stored: { streak: 2 } };
    const display = new BridgeDisplay(synced, fake);
    expect(display.call('getStoredValue', ['streak'], close)).toBe(2);
    expect(display.call('setStoredValue', ['streak', 3], close)).toEqual({ ok: true });
    expect(tracked.at(-1)).toEqual(['in_app_value_stored', { treebars_delivery_id: 'd-1', treebars_campaign_id: 'c-1', key: 'streak', value: 3 }]);
    // A later display of the same message in this page reads the write.
    expect(new BridgeDisplay(synced, fake).call('getStoredValue', ['streak'], close)).toBe(3);
    expect(display.call('setStoredValue', ['streak', null], close)).toEqual({ ok: true });
    expect(display.call('getStoredValue', ['streak'], close)).toBeNull();
    expect(display.call('setStoredValue', ['bad key', 1], close)).toEqual({ ok: false, reason: 'invalid_name' });
    expect(display.call('setStoredValue', ['big', 'x'.repeat(2000)], close)).toEqual({ ok: false, reason: 'invalid_value' });
  });

  it('keeps a test send’s value for the display only', () => {
    const { fake, tracked } = sdk();
    const display = new BridgeDisplay({ ...message(), campaign_id: null }, fake);
    expect(display.call('setStoredValue', ['streak', 1], close)).toEqual({ ok: false, reason: 'no_campaign' });
    expect(display.call('getStoredValue', ['streak'], close)).toBe(1);
    expect(tracked).toEqual([]);
  });

  it('reads a link as every renderer does: the two verbs, or a destination', async () => {
    const { fake, tracked, said } = sdk();
    const display = new BridgeDisplay(message(), fake);
    let closed = 0;
    display.call('_link', ['treebars://click/2', false], close);
    await turn();
    expect(tracked.at(-1)![1]).toMatchObject({ element: '2', button_index: 2 });
    display.call('_link', ['https://shop.example/terms', true], close);
    await turn();
    expect(said.opened).toEqual(['_link_new https://shop.example/terms']);
    display.call('_link', ['treebars://dismiss', false], () => (closed += 1));
    expect(closed).toBe(1);
    expect(tracked.at(-1)![0]).toBe('in_app_dismissed');
  });
});

describe('a reward the server decides', () => {
  it('hands the page the server’s answer for this message, and records the play as the page is told', async () => {
    const { fake, tracked, said } = sdk();
    const display = new BridgeDisplay(message(), fake);
    expect(await display.call('claimReward', ['wheel'], close)).toEqual({ won: true, prize: '10% off', prize_id: 'off', code: 'AUTUMN-7' });
    expect(said.asked).toEqual(['wheel d-1']);
    expect(tracked).toEqual([['in_app_reward_claimed', { treebars_delivery_id: 'd-1', treebars_campaign_id: 'c-1', pool: 'wheel', won: true, prize: '10% off' }]]);
  });

  it('asks nothing for a name no pool can have, and records no play for a refusal', async () => {
    const { fake, tracked, said } = sdk();
    const display = new BridgeDisplay(message(), fake);
    expect(await display.call('claimReward', ['Big Wheel!'], close)).toEqual({ ok: false, reason: 'invalid_name' });
    expect(said.asked).toEqual([]);
    expect(await display.call('claimReward', ['gone'], close)).toEqual({ ok: false, reason: 'not_available' });
    expect(tracked).toEqual([]);
  });
});

describe('a preview display', () => {
  it('refuses every method that writes, before its handler runs, and says it is a preview', async () => {
    const { fake, tracked, traits } = sdk();
    const display = new BridgeDisplay({ ...message(), preview: true }, fake);
    for (const [method, args] of [
      ['trackEvent', ['day_completed', {}]],
      ['trackClick', [1]],
      ['setUserAttribute', ['streak', 3]],
      ['identifyUser', ['user_9']],
      ['_submit', [{ email: 'a@b.c' }, { email: 'a@b.c' }]],
      ['claimReward', ['pool']],
      ['setStoredValue', ['k', 1]],
      ['requestNotificationPermission', []],
    ] as const) {
      expect(await display.call(method, [...args], close)).toEqual({ ok: false, reason: 'preview' });
    }
    await turn();
    expect(tracked).toEqual([]);
    expect(traits).toEqual([]);
  });

  it('still answers what an author checks a flow with, and tells the page it is a preview', async () => {
    const { fake, said } = sdk();
    // A direction on the message, so the context reads no document (none here).
    const withDirection = (base: InAppMessage): InAppMessage => ({ ...base, content: { ...base.content, in_app: { ...base.content.in_app!, direction: 'ltr' } } });
    const display = new BridgeDisplay({ ...withDirection(message()), preview: true }, fake);
    expect(await display.call('getContext', [], close)).toMatchObject({ preview: true });
    await display.call('openDeepLink', ['myapp://offers'], close);
    await turn();
    expect(said.opened).toEqual(['openDeepLink myapp://offers']);
    // A real display is not a preview.
    expect(await new BridgeDisplay(withDirection(message()), sdk().fake).call('getContext', [], close)).toMatchObject({ preview: false });
  });
});
