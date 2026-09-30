package com.treebars.sdk

import com.treebars.sdk.generated.TreebarsConstants

import android.content.SharedPreferences
import java.util.UUID

/** A session that has aged out, described well enough to emit `session_end` for it. */
internal data class ExpiredSession(
    val id: String,
    val endedAt: Long,
    val durationMs: Long,
    val eventCount: Int,
)

internal data class SessionTouch(
    val sessionId: String,
    val isNew: Boolean,
    val isFirstSession: Boolean,
    /** The session this one displaced, if any. Null while a session is merely continuing. */
    val expired: ExpiredSession?,
)

/**
 * Session tracking: a run of activity with no gap longer than the timeout.
 *
 * Persisted to SharedPreferences rather than held in memory, which is not a detail on
 * Android in particular — the OS kills backgrounded processes routinely, and the server
 * measures a session by the gap between activities too, a clock that does not care that
 * the process died. An in-memory session id would disagree with the server every time
 * Android reclaimed the app and the user came back inside the timeout: the SDK would
 * count two sessions where the server counts one.
 *
 * Not internally synchronised. Every call comes from `Treebars.record`, which holds a
 * mutex across the touch and the events it produces, because the ordering of those events
 * is the thing that has to be right.
 */
internal class SessionManager(
    private val prefs: SharedPreferences,
    /**
     * The clock, injectable, and only a test ever passes one.
     *
     * A thirty-minute timeout cannot be exercised in thirty minutes, so without this the
     * only reachable assertions are "a session opens" and "a second touch continues it" —
     * the two cases that were never going to break. Everything the timeout exists for
     * (the gap that ends a session, the `session_end` backdated to the real last activity
     * rather than to whenever the app reopened, a relaunch inside the window resuming
     * rather than starting) needs to move time, and moving it is the only way to test it.
     *
     * `System::currentTimeMillis` by default, so no caller outside a test knows this
     * parameter exists.
     */
    private val clock: () -> Long = System::currentTimeMillis,
) {

    private companion object {
        const val TIMEOUT_MS = TreebarsConstants.SESSION_TIMEOUT_MS
        const val ID = "session_id"
        const val STARTED_AT = "session_started_at"
        const val LAST_ACTIVITY_AT = "session_last_activity_at"
        const val EVENT_COUNT = "session_event_count"
        const val EVER_STARTED = "session_ever_started"
    }

    /**
     * Reads a stored key, treating a value this build cannot read as one that is not there.
     *
     * `SharedPreferences` typed getters THROW on a type mismatch — `getLong` on a key holding
     * a String is a `ClassCastException`, not a fall back to the default. A bare read would let
     * a store reshaped by an older or newer SDK crash `touch()`, which sits on the path of every
     * single event. So each key is read on its own and a value of the wrong type counts as
     * absent, because the record here is five keys rather than one blob.
     */
    private inline fun <T> readOrNull(read: () -> T): T? = runCatching { read() }.getOrNull()

    /** The session in progress, without extending it: in-app's per-session cap reads it. Null before the first. */
    fun currentId(): String? = readOrNull { prefs.getString(ID, null) }

    /**
     * Registers activity and reports what that did to the session.
     *
     * The `expired` half is what makes `session_end` honest. A session does not end when
     * the app is backgrounded — the user may be back in ten seconds, and the timeout says
     * that is the same session — so the end is only recognisable retroactively, once the
     * next activity turns out to be past the gap. The caller emits `session_end` backdated
     * to `endedAt`, the real last moment of that session rather than whenever the app
     * happened to be opened again.
     *
     * @param isEvent false for activity that is not an event — a context token, asked for
     *   before a purchase. It moves the session exactly as an event would, because the sale
     *   it stands for lands in the session it names; but `session_end`'s `event_count` is a
     *   count of events, and a token counted there would be one nobody can find.
     */
    fun touch(isEvent: Boolean = true): SessionTouch {
        val counted = if (isEvent) 1 else 0
        val now = clock()
        val existing = readOrNull { prefs.getString(ID, null) }
        val startedAt = readOrNull { prefs.getLong(STARTED_AT, 0) }
        val lastActivity = readOrNull { prefs.getLong(LAST_ACTIVITY_AT, 0) }
        val eventCount = readOrNull { prefs.getInt(EVENT_COUNT, 0) } ?: 0

        /*
         * A record is an id AND a last-activity stamp; half of one is not a record.
         *
         * With only the id, `lastActivity` would fall back to 0 — a gap of fifty-odd years —
         * the session would "expire", and the caller would emit a `session_end` dated 1970 with
         * zero events for a session nobody ever had. A partial record is treated as none, and
         * reports no expiry.
         */
        val hasRecord = existing != null && lastActivity != null && lastActivity > 0

        if (hasRecord && now - lastActivity!! <= TIMEOUT_MS) {
            val count = eventCount + counted
            prefs.edit().putLong(LAST_ACTIVITY_AT, now).putInt(EVENT_COUNT, count).apply()
            return SessionTouch(existing!!, isNew = false, isFirstSession = false, expired = null)
        }

        val expired = if (hasRecord) {
            ExpiredSession(
                id = existing!!,
                endedAt = lastActivity!!,
                durationMs = (lastActivity - (startedAt ?: lastActivity)).coerceAtLeast(0),
                eventCount = eventCount,
            )
        } else {
            null
        }

        val isFirstSession = !(readOrNull { prefs.getBoolean(EVER_STARTED, false) } ?: false)
        /*
         * `sess_`-prefixed, matching iOS, so a session id in a log or a query can be told
         * apart from every other UUID in the payload — event_id, batch_id, the device id's tail.
         */
        val created = "sess_" + UUID.randomUUID().toString()
        prefs.edit()
            .putString(ID, created)
            .putLong(STARTED_AT, now)
            .putLong(LAST_ACTIVITY_AT, now)
            .putInt(EVENT_COUNT, counted)
            .putBoolean(EVER_STARTED, true)
            .apply()

        return SessionTouch(created, isNew = true, isFirstSession = isFirstSession, expired = expired)
    }

    /**
     * Ends the session on logout.
     *
     * The stored record goes too. Leaving it would hand the next person to sign in on this
     * device the previous one's session id, stitching two people's activity into a single
     * session. `EVER_STARTED` deliberately survives: the install has still been
     * used before, so the next session is not a first one.
     */
    fun reset() {
        prefs.edit()
            .remove(ID)
            .remove(STARTED_AT)
            .remove(LAST_ACTIVITY_AT)
            .remove(EVENT_COUNT)
            .apply()
    }
}
