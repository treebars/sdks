import { beforeEach, describe, expect, it, vi } from 'vitest';

import { EventStore } from '../src/storage';
import type { QueuedEvent } from '../src/types';
import { Uploader, UploaderStore } from '../src/uploader';

/**
 * The one wake, when the wall clock and the timer disagree.
 *
 * A timer runs on a monotonic clock and the uploader reads `Date.now()`, so a wake can fire while
 * `now()` is still a moment short of the time it was armed for. So the uploader does not decide
 * from the clock whether its wake is still asleep: a wake that looked asleep would not arm the next
 * one, and a retry refused again at that instant would have nothing left to send it until the page
 * logged another event. The host says the wake fired (`woken`), and this pins that it is believed.
 */

function memoryStorage() {
  const map = new Map<string, string>();
  return {
    getItem: (key: string) => map.get(key) ?? null,
    setItem: (key: string, value: string) => void map.set(key, value),
    removeItem: (key: string) => void map.delete(key),
    clear: () => map.clear(),
  };
}

const event = (id: string): QueuedEvent => ({
  event_id: id,
  session_id: 's1',
  device_id: 'dev_wake',
  event_name: 'screen_view',
  properties: {},
  timestamp: '2026-09-15T12:00:00.000Z',
  sdk_version: '0.0.0',
  sdk_name: 'treebars-web',
  env: 'test',
  platform_type: 'web',
});

describe('the uploader’s wake', () => {
  beforeEach(() => vi.stubGlobal('localStorage', memoryStorage()));

  it('arms the next wake even when it fires a moment before the wall clock reaches it', async () => {
    let now = 0;
    const armed: number[] = [];
    const queue = new EventStore(true);
    queue.add(event('e1'));

    const uploader = new Uploader({
      queue,
      store: new UploaderStore(true),
      // Every answer asks for thirty seconds, so each flush leaves the gate closed.
      transport: async () => ({ status: 429, retryAfter: '30' }),
      writeKey: 'pk_test_wake',
      now: () => now,
      wake: (at) => void armed.push(at),
    });

    await uploader.flush();
    expect(armed).toEqual([30_000]);

    // The timer fires; the wall clock says a millisecond to go. The gate is still closed, so the
    // flush sends nothing — and it must still leave a wake armed for when it opens.
    now = 29_999;
    await uploader.woken();
    expect(armed).toEqual([30_000, 30_000]);
  });
});
