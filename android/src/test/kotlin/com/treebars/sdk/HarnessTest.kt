package com.treebars.sdk

import androidx.test.core.app.ApplicationProvider
import android.content.Context
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Proves the test harness, not the SDK: that Robolectric can hand a `SharedPreferences` to an
 * `internal` class from a unit test.
 *
 * It asserts on `SessionManager` rather than on `2 + 2`, because a harness that only proves it can
 * run an empty test proves nothing about the classes that actually need a preferences store.
 */
@RunWith(RobolectricTestRunner::class)
class HarnessTest {

    private fun prefs() = ApplicationProvider.getApplicationContext<Context>()
        .getSharedPreferences("treebars.prefs", Context.MODE_PRIVATE)

    @Test
    fun `robolectric supplies a real SharedPreferences to an internal class`() {
        val sessions = SessionManager(prefs())

        val first = sessions.touch()
        assertTrue("the first touch opens a session", first.isNew)
        assertTrue("and it is the first one this install has had", first.isFirstSession)

        val second = sessions.touch()
        assertFalse("a touch inside the timeout continues it", second.isNew)
        assertEquals("and keeps the same id", first.sessionId, second.sessionId)
    }

    @Test
    fun `the store really persists across instances, which is the point of using it`() {
        val opened = SessionManager(prefs()).touch().sessionId
        // A second manager over the same preferences is what a process restart looks like.
        assertEquals(opened, SessionManager(prefs()).touch().sessionId)
    }
}
