import { SESSION_TIMEOUT_MS as SESSION_TIMEOUT_MS_GENERATED } from './generated/constants';

/**
 * Session tracking.
 *
 * A session is a run of activity with no gap longer than the timeout. It is held in
 * sessionStorage rather than localStorage so that two tabs are not forced to share
 * one session id, and so it ends naturally when the tab does.
 */

const SESSION_KEY = 'treebars.session.v1';
/*
 * localStorage, not sessionStorage, and that is the whole point of it.
 *
 * The session itself lives in sessionStorage so two tabs are not forced to share an id and
 * so it ends with the tab. "Has this browser ever started a session" is the opposite kind of
 * fact — it has to outlive the tab, or every new tab would report itself as a first session.
 */
const EVER_STARTED_KEY = 'treebars.session_ever_started.v1';
const SESSION_TIMEOUT_MS = SESSION_TIMEOUT_MS_GENERATED;

interface SessionRecord {
  id: string;
  lastActivity: number;
  startedAt: number;
  eventCount: number;
}

/** A session that has aged out, described well enough to emit `session_end` for it. */
export interface ExpiredSession {
  id: string;
  endedAt: number;
  durationMs: number;
  eventCount: number;
}

export interface SessionTouch {
  sessionId: string;
  isNew: boolean;
  /** The session this one displaced, if any. Null while a session is merely continuing. */
  expired: ExpiredSession | null;
}

function read(): SessionRecord | null {
  try {
    const raw = globalThis.sessionStorage?.getItem(SESSION_KEY);
    return raw ? (JSON.parse(raw) as SessionRecord) : null;
  } catch {
    return null;
  }
}

function write(record: SessionRecord): void {
  try {
    globalThis.sessionStorage?.setItem(SESSION_KEY, JSON.stringify(record));
  } catch {
    // Storage unavailable; the in-memory fallback in SessionManager still applies.
  }
}

export class SessionManager {
  private current: SessionRecord | null = null;

  constructor(private readonly persist: boolean) {
    if (persist) this.current = read();
  }

  /**
   * Returns the active session id, opening a new one if the previous has expired.
   *
   * The `expired` half is what makes `session_end` honest. A session does not end when
   * the tab is hidden — the visitor may be back in ten seconds, and the timeout says that
   * is the same session — so the end is only recognisable retroactively, once the next
   * activity turns out to be past the gap. The caller emits `session_end` backdated to
   * `endedAt`, the real last moment of that session rather than whenever the visitor
   * happened to come back.
   *
   * `at` is for an event recorded after the moment it happened — an `app_background`, which waits to see that the
   * page stayed hidden: the session is asked about as of that moment, so the event lands in the session it happened
   * in and counts as that session's activity then, however much later it is recorded.
   */
  touch(counts = true, at?: number): SessionTouch {
    const now = at ?? Date.now();
    const existing = this.current ?? (this.persist ? read() : null);
    // `counts` is false for `contextToken()`: asking for a token is activity — it keeps the session open, since the
    // purchase it is for is about to happen in it — but it is not an event, and `session_end`'s count is of events.
    const step = counts ? 1 : 0;

    if (existing && now - existing.lastActivity < SESSION_TIMEOUT_MS) {
      // An earlier moment never moves the last activity back: something may have been recorded since.
      const lastActivity = at === undefined ? now : Math.max(existing.lastActivity, now);
      const updated = { ...existing, lastActivity, eventCount: (existing.eventCount ?? 0) + step };
      this.current = updated;
      if (this.persist) write(updated);
      return { sessionId: updated.id, isNew: false, expired: null };
    }

    const expired: ExpiredSession | null = existing
      ? {
          id: existing.id,
          endedAt: existing.lastActivity,
          durationMs: Math.max(0, existing.lastActivity - existing.startedAt),
          eventCount: existing.eventCount ?? 0,
        }
      : null;

    const created: SessionRecord = {
      id:
        typeof crypto !== 'undefined' && 'randomUUID' in crypto
          ? crypto.randomUUID()
          : `s_${now.toString(36)}_${Math.random().toString(36).slice(2, 8)}`,
      lastActivity: now,
      startedAt: now,
      eventCount: step,
    };

    this.current = created;
    if (this.persist) write(created);
    return { sessionId: created.id, isNew: true, expired };
  }

  /**
   * The id of the session this tab holds, still open or not, or null when it holds none. Read without touching it:
   * asking is not activity.
   */
  held(): string | null {
    return (this.current ?? (this.persist ? read() : null))?.id ?? null;
  }

  /**
   * Whether the session just started is the first this browser has ever had.
   *
   * Read-then-latch, and it answers true exactly once per browser, as in the other Treebars
   * SDKs, so a returning visitor's first session of the day can be told apart from their
   * very first ever.
   *
   * Independent of `disableStorage`: with persistence off there is nothing to latch, so
   * every session is reported as a first one, which is the honest answer for a browser
   * that is not allowed to remember anything.
   */
  claimFirstSession(): boolean {
    if (!this.persist) return true;
    try {
      if (globalThis.localStorage?.getItem(EVER_STARTED_KEY)) return false;
      globalThis.localStorage?.setItem(EVER_STARTED_KEY, '1');
      return true;
    } catch {
      return true;
    }
  }

  reset(): void {
    this.current = null;
    try {
      globalThis.sessionStorage?.removeItem(SESSION_KEY);
    } catch {
      // Nothing to clear.
    }
  }
}
