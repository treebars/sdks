import { describe, expect, it } from 'vitest';

import { forgetAdoption, readAdoption } from '../src/adoption';

/**
 * The hand-down of an install's identity from an earlier version of this package to the native
 * SDK, and its end: the copy in AsyncStorage — in every backup, on both platforms — goes once the
 * native SDK has taken it, so a backup restored onto another phone has no device id and secret
 * left to hand down to it.
 */

function memoryStore(initial: Record<string, string>, failing: string[] = []) {
  const items = new Map(Object.entries(initial));
  return {
    items,
    getItem: async (key: string) => items.get(key) ?? null,
    removeItem: async (key: string) => {
      if (failing.includes(key)) throw new Error(`cannot remove ${key}`);
      items.delete(key);
    },
  };
}

const HELD = {
  '@treebars/device_id': 'dev_from_js',
  '@treebars/fetch_secret': 'secret_from_js',
  '@treebars/first_seen_at': '2020-01-01T00:00:00.000Z',
  '@treebars/signed_in_user': 'user_9',
  '@treebars/identified_user': 'user_9',
  '@treebars/in_app_ledger': '{"done":{}}',
};

describe('the hand-down', () => {
  it('reads everything the core can take', async () => {
    expect(await readAdoption(memoryStore(HELD))).toEqual({
      deviceId: 'dev_from_js',
      fetchSecret: 'secret_from_js',
      firstSeenAt: '2020-01-01T00:00:00.000Z',
      signedInUser: 'user_9',
      identifiedUser: 'user_9',
      inAppLedgerJson: '{"done":{}}',
    });
  });

  it('is deleted, every key of it, once the core has it', async () => {
    const store = memoryStore({ ...HELD, '@someone-else/key': 'kept' });
    await forgetAdoption(store);
    expect([...store.items.keys()]).toEqual(['@someone-else/key']);
    // So the next launch — and the next backup — hands down nothing.
    expect(await readAdoption(store)).toEqual({});
  });

  it('keeps a key that will not delete, for the next launch to try', async () => {
    const store = memoryStore(HELD, ['@treebars/fetch_secret']);
    await expect(forgetAdoption(store)).resolves.toBeUndefined();
    expect([...store.items.keys()]).toEqual(['@treebars/fetch_secret']);
  });

  it('does nothing where AsyncStorage was never installed', async () => {
    await expect(forgetAdoption(null)).resolves.toBeUndefined();
    expect(await readAdoption(null)).toEqual({});
  });
});
