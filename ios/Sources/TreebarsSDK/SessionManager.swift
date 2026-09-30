import Foundation

/// A session that has aged out, described well enough to emit `session_end` for it.
struct ExpiredSession {
    let id: String
    let endedAt: TimeInterval
    let durationMs: Int
    let eventCount: Int
}

struct SessionTouch {
    let sessionId: String
    let isNew: Bool
    let isFirstSession: Bool
    /// The session this one displaced, if any. Nil while a session is merely continuing.
    let expired: ExpiredSession?
}

/// Session tracking: a run of activity with no gap longer than the timeout.
///
/// Persisted to `UserDefaults` — where the device id already lives — rather than held in
/// memory, which is not a detail. The server measures sessions by the same gap since the
/// person's last activity, and that clock does not care that the process was suspended and
/// discarded. An in-memory session id would disagree with the server every time somebody
/// force-quit and reopened the app inside the timeout: the SDK would count two sessions and
/// emit two `session_start`s where the server counts one.
///
/// An `actor` for the same reason `EventQueue` is one: `log` is called from any thread and
/// two overlapping touches would otherwise both decide they were opening a new session.
actor SessionManager {
    private enum Key {
        static let id = "treebars.session.id"
        static let startedAt = "treebars.session.started_at"
        static let lastActivity = "treebars.session.last_activity"
        static let eventCount = "treebars.session.event_count"
        static let everStarted = "treebars.session.ever_started"
    }

    private let timeout: TimeInterval = TreebarsConstants.sessionTimeout
    private let defaults: UserDefaults

    /**
     The clock, and only a test ever passes one.

     A thirty-minute timeout cannot be exercised in thirty minutes, so without this the only
     reachable assertions are "a session opens" and "a second touch continues it" — the two
     cases that were never going to break. Everything the timeout exists for needs to move
     time: the gap that ends a session, the `session_end` backdated to the real last activity
     rather than to whenever the app reopened, and a relaunch inside the window resuming
     rather than starting fresh.
     */
    private let clock: () -> TimeInterval

    /**
     The store is injectable for a plainer reason: without it, isolating the session from a
     test would mean reaching into the process-wide `UserDefaults.standard` and putting it
     back afterwards.

     Both default, so nothing outside a test knows either exists. Kotlin takes its
     preferences store as a constructor argument too.
     */
    init(
        defaults: UserDefaults = .standard,
        clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.defaults = defaults
        self.clock = clock
    }

    /// The session in progress, without extending it: in-app's per-session cap reads it. Nil before the first.
    func currentID() -> String? {
        defaults.string(forKey: Key.id)
    }

    /// Registers activity and reports what that did to the session.
    ///
    /// The `expired` half is what makes `session_end` honest. A session does not end when
    /// the app is backgrounded — the user may be back in ten seconds, and the timeout says
    /// that is the same session — so the end is only recognisable retroactively, once the
    /// next activity turns out to be past the gap. The caller emits `session_end` backdated
    /// to `endedAt`, the real last moment of that session rather than whenever the app
    /// happened to be reopened.
    ///
    /// - Parameter countsAsEvent: false for activity that is not an event — a context token,
    ///   asked for as a purchase begins. It holds the session open, because the purchase it
    ///   stands for happens in it, but `session_end` reports `event_count`, and a token counted
    ///   there is an event the store never received. A session a token opens starts at zero,
    ///   where one an event opens starts at the one that opened it.
    func touch(countsAsEvent: Bool = true) -> SessionTouch {
        let now = clock()
        let existing = defaults.string(forKey: Key.id)
        let lastActivity = defaults.double(forKey: Key.lastActivity)

        if let existing, now - lastActivity <= timeout {
            defaults.set(now, forKey: Key.lastActivity)
            if countsAsEvent {
                defaults.set(defaults.integer(forKey: Key.eventCount) + 1, forKey: Key.eventCount)
            }
            return SessionTouch(sessionId: existing, isNew: false, isFirstSession: false, expired: nil)
        }

        var expired: ExpiredSession?
        if let existing {
            let startedAt = defaults.double(forKey: Key.startedAt)
            expired = ExpiredSession(
                id: existing,
                endedAt: lastActivity,
                durationMs: Int(max(0, (lastActivity - startedAt) * 1000)),
                eventCount: defaults.integer(forKey: Key.eventCount)
            )
        }

        let isFirstSession = !defaults.bool(forKey: Key.everStarted)
        let created = "sess_\(UUID().uuidString.prefix(12))"

        defaults.set(created, forKey: Key.id)
        defaults.set(now, forKey: Key.startedAt)
        defaults.set(now, forKey: Key.lastActivity)
        defaults.set(countsAsEvent ? 1 : 0, forKey: Key.eventCount)
        defaults.set(true, forKey: Key.everStarted)

        return SessionTouch(
            sessionId: created,
            isNew: true,
            isFirstSession: isFirstSession,
            expired: expired
        )
    }

    /// The stored session removed without an instance — `ever_started` kept — for `WriteKeyStamp`, which runs
    /// before anything could touch the session and has to finish before anything does.
    nonisolated static func forgetRecord(in defaults: UserDefaults = .standard) {
        for key in [Key.id, Key.startedAt, Key.lastActivity, Key.eventCount] { defaults.removeObject(forKey: key) }
    }

    /// Ends the session on logout.
    ///
    /// The stored record goes too. Leaving it would hand the next person to sign in on this
    /// device the previous one's session id, stitching two people's activity into a single
    /// session. `everStarted` deliberately survives: the install has still been
    /// used before, so the next session is not a first one.
    func reset() {
        defaults.removeObject(forKey: Key.id)
        defaults.removeObject(forKey: Key.startedAt)
        defaults.removeObject(forKey: Key.lastActivity)
        defaults.removeObject(forKey: Key.eventCount)
    }
}
