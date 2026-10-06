import { beforeEach, describe, expect, it, vi } from 'vitest';

import { DRAIN_MAX_BATCHES } from '../src/generated/constants';
import { EventStore } from '../src/storage';
import type { QueuedEvent } from '../src/types';
import { Uploader, UploaderStore, type UploadResponse } from '../src/uploader';

/**
 * What the uploader says when a flush leaves events behind.
 *
 * A flush sends a bounded number of batches and ends on the first answer that is not progress, so
 * it can end with events still waiting. For a closed gate the uploader arms its own wake, or the
 * write key waits out its refusal. For anything else nothing would send the rest until the page
 * logged another event, so the uploader says so (`backlogLeft`) and the pace arms the next upload.
 * Saying it through a closed gate would be worse than not saying it: the upload armed for it would
 * send nothing, be told again, and be armed again, for as long as the gate stayed closed.
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
  device_id: 'dev_backlog',
  event_name: 'screen_view',
  properties: {},
  timestamp: '2026-09-15T12:00:00.000Z',
  sdk_version: '0.0.0',
  sdk_name: 'treebars-web',
  env: 'test',
  platform_type: 'web',
});

describe('the uploader, with events left after a flush', () => {
  beforeEach(() => vi.stubGlobal('localStorage', memoryStorage()));

  /** An uploader of one event per batch over `queued` events, answering each upload with the next of `answers`. */
  const build = (queued: number, answers: Array<Partial<UploadResponse> | 'network'>) => {
    const queue = new EventStore(true);
    for (let index = 0; index < queued; index += 1) queue.add(event(`e${index}`));
    const backlogLeft = vi.fn();
    let sent = 0;
    const uploader = new Uploader({
      queue,
      store: new UploaderStore(true),
      transport: async () => {
        sent += 1;
        const next = answers.shift() ?? { status: 200 };
        if (next === 'network') throw new TypeError('Failed to fetch');
        return { status: 200, retryAfter: null, ...next };
      },
      writeKey: 'pk_live_backlog',
      batchSize: 1,
      now: () => 0,
      random: () => 0.5,
      wake: () => {},
      backlogLeft,
    });
    return { uploader, backlogLeft, sent: () => sent };
  };

  it('says nothing when the flush sent everything', async () => {
    const { uploader, backlogLeft, sent } = build(DRAIN_MAX_BATCHES, []);
    await uploader.flush();
    expect(sent()).toBe(DRAIN_MAX_BATCHES);
    expect(backlogLeft).not.toHaveBeenCalled();
  });

  it('says so when a flush sent all it may and more is waiting, once per flush', async () => {
    const { uploader, backlogLeft, sent } = build(DRAIN_MAX_BATCHES + 1, []);
    await uploader.flush();
    expect(sent()).toBe(DRAIN_MAX_BATCHES);
    expect(backlogLeft).toHaveBeenCalledTimes(1);

    await uploader.flush();
    expect(sent()).toBe(DRAIN_MAX_BATCHES + 1);
    expect(backlogLeft).toHaveBeenCalledTimes(1);
  });

  it('says so when the server refused a batch for good and more is waiting', async () => {
    const { uploader, backlogLeft, sent } = build(3, [{ status: 400 }]);
    await uploader.flush();
    expect(sent()).toBe(1);
    expect(backlogLeft).toHaveBeenCalledTimes(1);
  });

  it.each([
    ['a Retry-After', { status: 503, retryAfter: '30' }],
    ['a backoff', 'network'],
    ['a refused write key', { status: 401 }],
  ] as const)('says nothing through %s: the gate decides when the rest may go', async (_, refusal) => {
    const { uploader, backlogLeft, sent } = build(3, [refusal]);
    await uploader.flush();
    expect(sent()).toBe(1);
    expect(backlogLeft).not.toHaveBeenCalled();

    // Nor from a flush that the closed gate turned away without a request.
    await uploader.flush();
    expect(sent()).toBe(1);
    expect(backlogLeft).not.toHaveBeenCalled();
  });

  it('is said by the flush that ran, not by one turned away while it was running', async () => {
    let release!: () => void;
    const queue = new EventStore(true);
    for (let index = 0; index < 2; index += 1) queue.add(event(`e${index}`));
    const backlogLeft = vi.fn();
    const uploader = new Uploader({
      queue,
      store: new UploaderStore(true),
      // The first upload is refused for good, but not until the test lets it answer.
      transport: () => new Promise<UploadResponse>((resolve) => (release = () => resolve({ status: 400, retryAfter: null }))),
      writeKey: 'pk_live_backlog',
      batchSize: 1,
      now: () => 0,
      backlogLeft,
    });

    const running = uploader.flush();
    await uploader.flush();
    expect(backlogLeft).not.toHaveBeenCalled();

    release();
    await running;
    expect(backlogLeft).toHaveBeenCalledTimes(1);
  });
});
