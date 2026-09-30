import { beforeEach, describe, expect, it, vi } from 'vitest';
import { EventStore, getDeviceId } from '../src/storage';
import { SessionManager } from '../src/session';
import type { QueuedEvent } from '../src/types';
import { QUEUE_CAP } from '../src/generated/constants';

/** Minimal Storage stand-in; the browser API is not available under Node. */
function memoryStorage() {
  const map = new Map<string, string>();
  return {
    getItem: (k: string) => map.get(k) ?? null,
    setItem: (k: string, v: string) => void map.set(k, v),
    removeItem: (k: string) => void map.delete(k),
    clear: () => map.clear(),
    map,
  };
}

/** Reproduces Safari private mode and a full quota, both of which throw on write. */
function throwingStorage() {
  return {
    getItem: () => {
      throw new Error('SecurityError');
    },
    setItem: () => {
      throw new Error('QuotaExceededError');
    },
    removeItem: () => {
      throw new Error('SecurityError');
    },
  };
}

function event(name: string): QueuedEvent {
  return {
    event_id: `id_${name}`,
    event_name: name,
    device_id: 'device',
    session_id: 'session',
    timestamp: new Date().toISOString(),
    properties: {},
  } as QueuedEvent;
}

beforeEach(() => {
  vi.unstubAllGlobals();
  vi.stubGlobal('localStorage', memoryStorage());
  vi.stubGlobal('sessionStorage', memoryStorage());
});

describe('event store', () => {
  it('preserves order across a page load, which is the reason it persists at all', () => {
    const first = new EventStore(true);
    first.add(event('a'));
    first.add(event('b'));

    const reloaded = new EventStore(true);
    expect(reloaded.all().map((e) => e.event_name)).toEqual(['a', 'b']);
  });

  it('removes only what was successfully sent', () => {
    const store = new EventStore(true);
    store.add(event('a'));
    store.add(event('b'));
    store.add(event('c'));

    expect(store.peek(2).map((e) => e.event_name)).toEqual(['a', 'b']);
    store.remove(2);
    expect(store.all().map((e) => e.event_name)).toEqual(['c']);
  });

  /*
   * Against the generated cap, not a literal. Every SDK shares one queue cap, and a literal
   * here would go on passing however far the SDKs drifted apart, because it would agree only
   * with itself.
   */
  it('drops the oldest events when full, keeping recent behaviour', () => {
    const store = new EventStore(false);
    const overflow = 20;
    for (let i = 0; i < QUEUE_CAP + overflow; i += 1) store.add(event(String(i)));

    expect(store.size).toBe(QUEUE_CAP);
    expect(store.all()[0]!.event_name).toBe(String(overflow));
    expect(store.all().at(-1)!.event_name).toBe(String(QUEUE_CAP + overflow - 1));
  });

  it('keeps working in memory when storage throws, rather than breaking the page', () => {
    vi.stubGlobal('localStorage', throwingStorage());

    const store = new EventStore(true);
    expect(() => store.add(event('a'))).not.toThrow();
    expect(store.size).toBe(1);
  });

  it('recovers from a corrupted queue instead of throwing on load', () => {
    localStorage.setItem('treebars.queue.v1', 'not json');
    expect(new EventStore(true).all()).toEqual([]);

    localStorage.setItem('treebars.queue.v1', '{"not":"an array"}');
    expect(new EventStore(true).all()).toEqual([]);
  });
});

describe('device id', () => {
  it('stays stable across page loads', () => {
    expect(getDeviceId(true)).toBe(getDeviceId(true));
  });

  it('resets when site data is cleared', () => {
    const before = getDeviceId(true);
    localStorage.clear();
    expect(getDeviceId(true)).not.toBe(before);
  });

  it('does not persist when the caller opts out', () => {
    const id = getDeviceId(false);
    expect(localStorage.getItem('treebars.device.v1')).toBeNull();
    expect(getDeviceId(false)).not.toBe(id);
  });
});

describe('session manager', () => {
  it('keeps one session id across continuous activity', () => {
    const manager = new SessionManager(true);
    const first = manager.touch();
    const second = manager.touch();

    expect(second.sessionId).toBe(first.sessionId);
    expect(second.isNew).toBe(false);
  });

  it('opens a new session after the inactivity timeout', () => {
    vi.useFakeTimers();
    try {
      const manager = new SessionManager(true);
      const first = manager.touch();

      vi.advanceTimersByTime(31 * 60 * 1000);
      const second = manager.touch();

      expect(second.isNew).toBe(true);
      expect(second.sessionId).not.toBe(first.sessionId);
    } finally {
      vi.useRealTimers();
    }
  });

  it('holds the session below the timeout boundary', () => {
    vi.useFakeTimers();
    try {
      const manager = new SessionManager(true);
      const first = manager.touch();

      vi.advanceTimersByTime(29 * 60 * 1000);
      expect(manager.touch().sessionId).toBe(first.sessionId);
    } finally {
      vi.useRealTimers();
    }
  });

  it('resumes the stored session on the next page load', () => {
    const first = new SessionManager(true).touch();
    expect(new SessionManager(true).touch().sessionId).toBe(first.sessionId);
  });

  it('starts a fresh session after reset, which is what identity change requires', () => {
    const manager = new SessionManager(true);
    const first = manager.touch();
    manager.reset();

    expect(manager.touch().sessionId).not.toBe(first.sessionId);
  });

  /*
   * The retroactive end. A session cannot be closed when the tab is hidden — the visitor
   * may be back in ten seconds, and the timeout says that is the same session — so the
   * close is only recognisable once the next activity turns out to be past the gap.
   */
  it('reports the session it displaced, ended at that session own last moment', () => {
    vi.useFakeTimers();
    try {
      const manager = new SessionManager(true);
      const first = manager.touch();

      vi.advanceTimersByTime(60_000);
      manager.touch();
      const lastActivity = Date.now();

      vi.advanceTimersByTime(31 * 60 * 1000);
      const reopened = manager.touch();

      expect(reopened.expired).not.toBeNull();
      expect(reopened.expired!.id).toBe(first.sessionId);
      expect(reopened.expired!.eventCount).toBe(2);
      expect(reopened.expired!.durationMs).toBe(60_000);
      // Not the moment the visitor came back.
      expect(reopened.expired!.endedAt).toBe(lastActivity);
    } finally {
      vi.useRealTimers();
    }
  });

  it('reports nothing displaced while a session merely continues', () => {
    const manager = new SessionManager(true);
    manager.touch();
    expect(manager.touch().expired).toBeNull();
  });
});

/**
 * No WebCrypto, no SDK. The device secret proves this browser on its in-app and inbox reads, so it
 * comes only from `crypto.getRandomValues` and never from `Math.random` — a generator whose state its
 * own outputs give away. Every browser the SDK otherwise runs in has `crypto.getRandomValues`; one
 * without it gets an SDK that stays off and says so, rather than a secret somebody else could
 * reproduce.
 */
describe('a browser that cannot mint a secret', () => {
  it('gets no SDK, and never a secret from Math.random', async () => {
    const { TreebarsWeb } = await import('../src/index');
    const random = vi.spyOn(Math, 'random');
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => undefined);
    vi.stubGlobal('crypto', undefined);
    try {
      const sdk = new TreebarsWeb();
      sdk.init({ writeKey: 'pk_test_x' });
      sdk.track('anything');
      expect(warn).toHaveBeenCalledWith(expect.stringContaining('crypto.getRandomValues'));
      expect(random).not.toHaveBeenCalled();
    } finally {
      vi.unstubAllGlobals();
      random.mockRestore();
      warn.mockRestore();
    }
  });
});
