import { describe, expect, it } from 'vitest';
import { InAppStore, type InAppMessage, type InAppPolicy } from '../src/in-app';

/*
 * The display caps the browser counts itself: per session, per trigger kind a day, and a message that ignores the
 * minimum gap. The same rules as the Android and iOS SDKs' `allows`.
 */

const T = new Date(2026, 8, 23, 12, 0).getTime();
const message = (id: string, kind: 'session_start' | 'screen_view' | 'event' | 'immediate', extra: Record<string, unknown> = {}): InAppMessage => ({
  delivery_id: id,
  campaign_id: null,
  content: {
    in_app: { surface: 'overlay', trigger: kind === 'event' ? { kind, event_name: 'purchase' } : { kind }, ...extra } as never,
  },
  created_at: new Date(T).toISOString(),
  expires_at: null,
});
const policy = (extra: Partial<InAppPolicy>): InAppPolicy => ({
  max_per_day: null,
  min_gap_seconds: null,
  messages_shown_today: 0,
  last_shown_at: null,
  ...extra,
});
const storeWith = (messages: InAppMessage[], p: InAppPolicy) => {
  const store = new InAppStore(false);
  store.accept({ messages, policy: p, server_time: new Date(T).toISOString() });
  return store;
};

describe('in-app caps the device counts', () => {
  it('stops at the session’s cap, and a new session starts again', () => {
    const [a, b] = [message('a', 'screen_view'), message('b', 'screen_view')];
    const store = storeWith([a, b], policy({ max_per_session: 1 }));
    expect(store.allows(a, 's1', T)).toBe(true);
    store.recordDisplay(a, 's1', T);
    expect(store.allows(b, 's1', T)).toBe(false);
    expect(store.allows(b, 's2', T)).toBe(true);
  });

  it('caps one trigger kind a day, leaves the others alone, and starts again tomorrow', () => {
    const [a, b, c] = [message('a', 'event'), message('b', 'event'), message('c', 'session_start')];
    const store = storeWith([a, b, c], policy({ trigger_max_per_day: { event: 1 } }));
    store.recordDisplay(a, 's1', T);
    expect(store.allows(b, 's1', T)).toBe(false);
    // Seeing the same one again spends nothing more.
    expect(store.allows(a, 's1', T)).toBe(true);
    expect(store.allows(c, 's1', T)).toBe(true);
    expect(store.allows(b, 's1', T + 24 * 3_600_000)).toBe(true);
  });

  it('lets a message that ignores the minimum gap through it, and only that one', () => {
    const [a, b, urgent] = [message('a', 'immediate'), message('b', 'immediate'), message('u', 'immediate', { ignore_min_gap: true })];
    const store = storeWith([a, b, urgent], policy({ min_gap_seconds: 600 }));
    store.recordDisplay(a, 's1', Date.now());
    expect(store.allows(b, 's1', Date.now())).toBe(false);
    expect(store.allows(urgent, 's1', Date.now())).toBe(true);
  });

  it('draws a test send past every cap, and still not once it is done or expired', () => {
    const [a, test] = [message('a', 'immediate'), { ...message('t', 'immediate'), test: true }];
    const store = storeWith([a, test], policy({ max_per_day: 1, max_per_session: 1, min_gap_seconds: 600, trigger_max_per_day: { immediate: 1 } }));
    store.recordDisplay(a, 's1', Date.now());
    expect(store.blockedBy({ ...message('b', 'immediate') }, 's1', Date.now())).not.toBeNull();
    expect(store.blockedBy(test, 's1', Date.now())).toBeNull();
    expect(store.blockedBy({ ...test, expires_at: new Date(Date.now() - 1000).toISOString() }, 's1', Date.now())).toBe('expired');
    store.markDone('t');
    expect(store.blockedBy(test, 's1', Date.now())).toBe('done');
  });
});
