import { describe, expect, it, vi } from 'vitest';

import { TreebarsSDK } from '../src/Treebars';

/*
 * Remote config across the bridge. The rules — when to ask, what a key answers and for how long — are the native
 * SDKs' and are tested there. What is this layer's is small and all of it is here: a read carries its fallback down
 * and never throws, a JSON value is decoded, a change is passed on to whoever listens, and a call made after
 * `init()` waits for it.
 */

function fakeNative(held: Record<string, unknown> = {}) {
  const calls: string[] = [];
  let emitChange: (payload: string) => void = () => undefined;
  const emitter = () => () => undefined;
  const read = <T>(kind: string) => (key: string, fallback: T): T => (typeof held[key] === kind ? (held[key] as T) : fallback);
  const native = {
    initialize: vi.fn(async () => void calls.push('initialize')),
    onInAppPresent: emitter,
    onNotificationsChange: emitter,
    onUploadLog: emitter,
    onDeferredDeepLink: emitter,
    onTreebarsEvent: emitter,
    onConfigChange: (handler: (payload: string) => void) => {
      emitChange = handler;
      return () => undefined;
    },
    configBoolean: read<boolean>('boolean'),
    configString: read<string>('string'),
    configNumber: read<number>('number'),
    configJson: (key: string) => (key in held ? (held[key] as string) : null),
    // What the native side answers a read with no fallback: the value as JSON text when it is that kind, or null.
    configValue: (key: string, kind: string) => {
      if (!(key in held)) return null;
      if (kind === 'json') return held[key] as string;
      return typeof held[key] === kind ? JSON.stringify(held[key]) : null;
    },
    allConfig: () => JSON.stringify(held),
    activateConfig: () => true,
    fetchConfig: vi.fn(async () => {
      calls.push('fetchConfig');
      return true;
    }),
    configReady: vi.fn(async (timeoutMs: number) => {
      calls.push(`configReady:${timeoutMs}`);
      return true;
    }),
    setConfigAttributes: vi.fn(async (attributes: string) => void calls.push(`attributes:${attributes}`)),
    setConfigOverride: vi.fn(async (key: string, value: string | null) => void calls.push(`override:${key}=${value}`)),
  };
  return { native, calls, emitChange: () => emitChange('') };
}

const withNative = (native: unknown) => {
  const sdk = new TreebarsSDK();
  (sdk as unknown as { native: unknown }).native = native;
  return sdk;
};

describe('remote config across the bridge', () => {
  it('answers a read with what the native side holds, and the fallback where it holds nothing', () => {
    const { native } = fakeNative({ new_checkout: true, greeting: 'hello', page_size: 20 });
    const sdk = withNative(native);

    expect(sdk.getConfigBoolean('new_checkout', false)).toBe(true);
    expect(sdk.getConfigString('greeting', 'hi')).toBe('hello');
    expect(sdk.getConfigNumber('page_size', 10)).toBe(20);
    expect(sdk.getConfigBoolean('absent', false)).toBe(false);
    expect(sdk.getConfigString('absent', 'hi')).toBe('hi');
    expect(sdk.getConfigNumber('absent', 10)).toBe(10);
    expect(sdk.allConfig()).toEqual({ new_checkout: true, greeting: 'hello', page_size: 20 });
  });

  it('decodes a JSON value, and answers the fallback for none held or one that cannot be decoded', () => {
    const { native } = fakeNative({ layout: '{"columns":2,"tiles":["a","b"]}', nothing: 'null', broken: '{"columns":' });
    const sdk = withNative(native);

    expect(sdk.getConfigJson('layout', { columns: 1 })).toEqual({ columns: 2, tiles: ['a', 'b'] });
    // A published JSON null is a value, not an absence.
    expect(sdk.getConfigJson('nothing', 'fallback')).toBeNull();
    expect(sdk.getConfigJson('absent', { columns: 1 })).toEqual({ columns: 1 });
    expect(sdk.getConfigJson('broken', { columns: 1 })).toEqual({ columns: 1 });
  });

  it('reads a value as the kind its fallback is, through the typed read for that kind', () => {
    const { native } = fakeNative({ new_checkout: true, greeting: 'hello', page_size: 20, layout: '{"columns":2}', texted: 'false' });
    const sdk = withNative(native);

    expect(sdk.getConfig('new_checkout', false)).toBe(true);
    expect(sdk.getConfig('greeting', 'hi')).toBe('hello');
    expect(sdk.getConfig('page_size', 10)).toBe(20);
    expect(sdk.getConfig('layout', { columns: 1 })).toEqual({ columns: 2 });
    // A flag somebody published as text reads as the fallback, never as "on".
    expect(sdk.getConfig('texted', true)).toBe(true);
    expect(sdk.getConfig('greeting', 0)).toBe(0);
    expect(sdk.getConfig('absent', '')).toBe('');
    // Nothing at all is no kind to read as.
    expect((sdk.getConfig as (key: string, fallback: unknown) => unknown)('greeting', null)).toBeNull();
    expect((sdk.getConfig as (key: string, fallback: unknown) => unknown)('greeting', undefined)).toBeNull();
  });

  it('answers null for a kind named with no fallback, where nothing of that kind is held', () => {
    const { native } = fakeNative({ new_checkout: true, greeting: 'hello', page_size: 20, layout: '[1,2]', broken: '{"columns":' });
    const sdk = withNative(native);

    expect(sdk.getConfigBoolean('new_checkout')).toBe(true);
    expect(sdk.getConfigString('greeting')).toBe('hello');
    expect(sdk.getConfigNumber('page_size')).toBe(20);
    expect(sdk.getConfigJson<number[]>('layout')).toEqual([1, 2]);
    expect(sdk.getConfigBoolean('absent')).toBeNull();
    expect(sdk.getConfigString('page_size')).toBeNull();
    expect(sdk.getConfigNumber('greeting')).toBeNull();
    // Text that cannot be decoded is nothing held, and a read does not throw into the screen being drawn.
    expect(sdk.getConfigJson('broken')).toBeNull();
    // With the module not linked there is nothing to hold anything.
    expect(withNative(null).getConfigString('greeting')).toBeNull();
    expect(withNative(null).getConfig('greeting', 'hi')).toBe('hi');
  });

  it('reads the fallback, and never throws, when the native module is not linked', () => {
    const sdk = withNative(null);

    expect(sdk.getConfigBoolean('new_checkout', true)).toBe(true);
    expect(sdk.getConfigString('greeting', 'hi')).toBe('hi');
    expect(sdk.getConfigNumber('page_size', 10)).toBe(10);
    expect(sdk.getConfigJson('layout', [1])).toEqual([1]);
    expect(sdk.allConfig()).toEqual({});
    expect(sdk.activateConfig()).toBe(false);
  });

  it('tells every listener of a change, including one that listened before init(), and stops when asked', async () => {
    const { native, emitChange } = fakeNative();
    const sdk = withNative(native);

    let early = 0;
    let late = 0;
    const stop = sdk.onConfigChange(() => {
      early += 1;
    });
    await sdk.init({ write_key: 'pk_test_config' } as never);
    sdk.onConfigChange(() => {
      late += 1;
    });

    emitChange();
    expect([early, late]).toEqual([1, 1]);
    stop();
    emitChange();
    expect([early, late]).toEqual([1, 2]);
  });

  it('holds a call made after init() until the native side is up', async () => {
    const { native, calls } = fakeNative();
    const sdk = withNative(native);

    const started = sdk.init({ write_key: 'pk_test_config' } as never);
    const ready = sdk.configReady();
    const fetched = sdk.fetchConfig();
    await Promise.all([started, ready, fetched]);

    expect(calls[0]).toBe('initialize');
    expect(calls).toContain('configReady:2000');
    expect(calls).toContain('fetchConfig');
    await expect(sdk.configReady(500)).resolves.toBe(true);
    expect(calls).toContain('configReady:500');
  });

  it('sends attributes as one JSON object and an override as a JSON value, null to take it back', async () => {
    const { native, calls } = fakeNative();
    const sdk = withNative(native);

    await sdk.setConfigAttributes({ plan: 'pro', seats: 5, trial: false });
    await sdk.setConfigOverride('new_checkout', true);
    await sdk.setConfigOverride('greeting', 'hello');
    await sdk.setConfigOverride('layout', { columns: 2 });
    await sdk.setConfigOverride('new_checkout', undefined);
    await sdk.setConfigOverride('greeting', null);

    expect(calls).toEqual([
      'attributes:{"plan":"pro","seats":5,"trial":false}',
      'override:new_checkout=true',
      'override:greeting="hello"',
      'override:layout={"columns":2}',
      'override:new_checkout=null',
      'override:greeting=null',
    ]);
  });
});
