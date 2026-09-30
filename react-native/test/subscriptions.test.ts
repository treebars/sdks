import { describe, expect, it, vi } from 'vitest';

import { TreebarsSDK } from '../src/Treebars';

/*
 * A subscription made before `init()` reaches the native side once `init()` has run.
 *
 * React runs a child's effects before its parent's, so a provider subscribing at mount does so while `init()` — in the
 * app's own effect — has not started. Unless `init()` sends it, the push action or deferred deep link the native SDK
 * is holding has nobody to go to.
 */

function fakeNative() {
  const calls: string[] = [];
  const emitter = () => () => undefined;
  const native = new Proxy(
    {
      initialize: vi.fn(async () => undefined),
      setInAppRendererEnabled: vi.fn(async () => undefined),
      setEventsSubscribed: vi.fn(async (names: string) => void calls.push(`events:${names}`)),
      setDeferredDeepLinkSubscribed: vi.fn(async (on: boolean) => void calls.push(`deepLink:${on}`)),
      onInAppPresent: emitter,
      onNotificationsChange: emitter,
      onUploadLog: emitter,
      onDeferredDeepLink: emitter,
      onTreebarsEvent: emitter,
    } as Record<string, unknown>,
    { get: (target, key: string) => target[key] ?? vi.fn(async () => undefined) },
  );
  return { native, calls };
}

describe('a subscription made before init()', () => {
  it('is sent to the native side once init() has run', async () => {
    const sdk = new TreebarsSDK();
    const { native, calls } = fakeNative();
    (sdk as unknown as { native: unknown }).native = native;

    sdk.setEventListener('pushClicked', () => undefined);
    sdk.onDeferredDeepLink(() => undefined);
    expect(calls).toEqual([]);

    await sdk.init({ write_key: 'pk_test_subscriptions' } as never);
    expect(calls).toEqual(['events:["pushClicked"]', 'deepLink:true']);
  });
});

describe('setEventListener', () => {
  it('subscribes the native side to exactly the events listened to, and lets go of each', async () => {
    const sdk = new TreebarsSDK();
    const { native, calls } = fakeNative();
    (sdk as unknown as { native: unknown }).native = native;
    await sdk.init({ write_key: 'pk_test_events' } as never);
    const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
    // Each change sends the set as it is when it goes out, so the native side always ends on the current one.
    const stopShown = sdk.setEventListener('inAppCampaignShown', () => undefined);
    await settle();
    expect(calls.at(-1)).toBe('events:["inAppCampaignShown"]');
    const stopSelf = sdk.setEventListener('inAppCampaignSelfHandled', () => undefined);
    await settle();
    expect(calls.at(-1)).toBe('events:["inAppCampaignShown","inAppCampaignSelfHandled"]');
    stopSelf();
    await settle();
    expect(calls.at(-1)).toBe('events:["inAppCampaignShown"]');
    stopShown();
    await settle();
    expect(calls.at(-1)).toBe('events:[]');
  });
});

describe('clearing an in-app renderer', () => {
  it('leaves a newer host registered when an older host cleans up after it', async () => {
    const sdk = new TreebarsSDK();
    const { native } = fakeNative();
    (sdk as unknown as { native: unknown }).native = native;
    await sdk.init({ write_key: 'pk_test_renderer' } as never);
    const renderer = () => (sdk as unknown as { renderer: unknown }).renderer;

    const oldHost = () => undefined;
    const newHost = () => undefined;
    const clearOld = sdk.setInAppRenderer(oldHost);
    sdk.setInAppRenderer(newHost); // the rebuilt Activity's host mounts first…
    clearOld(); // …then the old one unmounts
    expect(renderer()).toBe(newHost);

    const clearNew = sdk.setInAppRenderer(newHost);
    clearNew();
    expect(renderer()).toBeNull();
  });
});
