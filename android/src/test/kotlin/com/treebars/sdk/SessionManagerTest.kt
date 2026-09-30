package com.treebars.sdk

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.treebars.sdk.generated.TreebarsConstants
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/*
 * Sessionisation: a run of activity with no gap longer than the timeout.
 *
 * Nothing below can be written without the injectable clock — a thirty-minute timeout cannot
 * be exercised in thirty minutes. Everything the timeout is FOR is behind a clock: the gap
 * that closes a session, the `session_end` backdated to the real last activity, and the
 * relaunch that resumes rather than restarts.
 *
 * A session boundary is not a local opinion. The server decides its own from when it last
 * saw the person, so a device that disagrees with these rules does not produce an error
 * anywhere — it produces two `session_start`s where the server counted one session, and
 * nobody finds out until someone compares two numbers that should have matched.
 */
@RunWith(RobolectricTestRunner::class)
class SessionManagerTest {

    private companion object {
        const val TIMEOUT_MS = TreebarsConstants.SESSION_TIMEOUT_MS
        // The same wall-clock instant the other SDKs' suites start from, so a divergence
        // between platforms shows up as different assertions rather than different arithmetic.
        const val T0 = 1787475600000L // 2026-08-23T09:00:00.000Z
    }

    /** Distinct per test: a shared preferences file would let one test's session decide another's. */
    private fun prefs(name: String) = ApplicationProvider.getApplicationContext<Context>()
        .getSharedPreferences("treebars.session.$name", Context.MODE_PRIVATE)

    private var now = T0
    private val clock: () -> Long = { now }

    @Test
    fun `activity inside the timeout continues the same session`() {
        val sessions = SessionManager(prefs("continues"), clock)

        val first = sessions.touch()
        val second = sessions.touch()

        assertTrue("the first touch opens a session", first.isNew)
        assertTrue("and this install has had none before", first.isFirstSession)
        assertFalse("a touch inside the timeout does not open another", second.isNew)
        assertEquals(first.sessionId, second.sessionId)
        assertNull("nothing has ended, so there is nothing to report", second.expired)
    }

    /*
     * The retroactive end. A session cannot be closed at the moment the app is backgrounded —
     * the user may be back in ten seconds, and the timeout says that is the same session — so
     * the close is only recognisable once the next activity turns out to be past the gap. By
     * then "now" is the wrong timestamp for it, which is what the backdating is.
     */
    @Test
    fun `a gap past the timeout ends the old session and backdates the end`() {
        val sessions = SessionManager(prefs("backdates"), clock)

        val first = sessions.touch()
        now += 60_000
        sessions.touch()

        val lastActivity = now
        now += TIMEOUT_MS + 1
        val reopened = sessions.touch()

        assertTrue(reopened.isNew)
        assertNotEquals(first.sessionId, reopened.sessionId)
        assertFalse("the install has been used before", reopened.isFirstSession)

        val expired = requireNotNull(reopened.expired) { "the gap closed a session" }
        assertEquals(first.sessionId, expired.id)
        assertEquals(2, expired.eventCount)
        assertEquals(60_000L, expired.durationMs)
        // The session's own last moment, not the moment the app came back.
        assertEquals(lastActivity, expired.endedAt)
    }

    /*
     * Why the record is persisted rather than held in a field, and the case Android makes
     * routine: the OS reclaims a backgrounded process whenever it likes, so "the app was
     * killed and reopened four minutes later" is ordinary rather than exceptional. The
     * server sees one uninterrupted session across that, and so must the device.
     *
     * A second manager over the same preferences file is what a relaunch looks like from here.
     */
    @Test
    fun `a relaunch inside the timeout resumes the previous process session`() {
        val store = prefs("relaunch-inside")

        val original = SessionManager(store, clock).touch()
        now += 5 * 60 * 1000

        val resumed = SessionManager(store, clock).touch()

        assertEquals(original.sessionId, resumed.sessionId)
        assertFalse(resumed.isNew)
        assertNull(resumed.expired)
    }

    @Test
    fun `a relaunch past the timeout is a new session, and not a first one`() {
        val store = prefs("relaunch-outside")

        val original = SessionManager(store, clock).touch()
        now += TIMEOUT_MS + 1

        val next = SessionManager(store, clock).touch()

        assertNotEquals(original.sessionId, next.sessionId)
        assertTrue(next.isNew)
        // The install has been used before, so this is not the first session on it — which is
        // the half a fresh process cannot know from memory and has to read back.
        assertFalse(next.isFirstSession)
        assertEquals(original.sessionId, requireNotNull(next.expired).id)
    }

    /*
     * Logout has to take the stored record with it. Leaving it would hand the next person to
     * sign in on this device the previous one's session id, stitching two people's activity
     * into a single session.
     */
    @Test
    fun `reset clears the persisted session so the next sign-in starts clean`() {
        val store = prefs("reset")
        val sessions = SessionManager(store, clock)
        val first = sessions.touch()

        sessions.reset()

        val next = sessions.touch()
        assertNotEquals(first.sessionId, next.sessionId)
        // This manager holds no state of its own, so a null `expired` is the assertion that
        // the record is really gone from the store rather than merely forgotten in memory.
        assertNull(next.expired)
        // `EVER_STARTED` deliberately survives a reset: signing out does not make the handset
        // new, and a second `is_first_session` from one install is a lie the funnel cannot see
        // through.
        assertFalse(next.isFirstSession)
    }

    /*
     * A record written by a version that shaped the store differently. It has to be
     * survivable, because the alternative is an SDK that throws on the first event after an
     * upgrade — and `touch()` is on the path of every single event.
     *
     * Two shapes it has to survive:
     *
     *  - **A partial record.** An id with no timestamps must not leave `lastActivity` on its
     *    typed default of 0: the gap would read as fifty-odd years, the session would
     *    "expire", and the caller would emit a `session_end` dated 1970 with zero events for
     *    a session nobody had.
     *  - **A wrong-typed value.** `SharedPreferences` typed getters THROW on a mismatch
     *    rather than falling back, so a String under a `Long` key would be a
     *    `ClassCastException` out of `touch()` — a crash, on every event.
     *
     * Five separate keys need five checks, which is what `readOrNull` is.
     */
    @Test
    fun `a partial record is no record, rather than a session that ended in 1970`() {
        val store = prefs("partial")
        store.edit().putString("session_id", "sess_from_a_shape_we_no_longer_write").commit()

        val touched = SessionManager(store, clock).touch()

        assertTrue("a fresh session, rather than a resumed unreadable one", touched.isNew)
        assertNotEquals("sess_from_a_shape_we_no_longer_write", touched.sessionId)
        assertNull(
            "half a record is not a session, so there is nothing to report the end of",
            touched.expired,
        )
    }

    @Test
    fun `a wrong-typed stored value is survivable rather than a crash on every event`() {
        val store = prefs("mistyped")
        store.edit()
            .putString("session_id", "sess_old")
            .putString("session_last_activity_at", "not a long")
            .commit()

        val touched = SessionManager(store, clock).touch()

        assertTrue(touched.isNew)
        assertNull(touched.expired)
    }

    @Test
    fun `and the same when the id itself is the wrong type`() {
        val store = prefs("mistyped-id")
        store.edit().putLong("session_id", 12).putLong("session_last_activity_at", 1_000).commit()

        val touched = SessionManager(store, clock).touch()

        assertTrue(touched.isNew)
        assertNull(touched.expired)
    }
}
