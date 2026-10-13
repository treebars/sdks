package com.treebars.sdk

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/*
 * The two ways an app reads a remote config value, where nothing is held for the key.
 *
 * `getConfig(key, fallback)` reads as the kind its fallback is, so one name serves a flag, text and a number — and
 * each of those is its own overload, which this pins by calling them the way an app does: a call that stopped
 * choosing the overload it should, or stopped compiling, fails here. A kind named with no fallback answers null,
 * never a value made up for it. What a read answers once values are held is the shared scenarios'.
 */
@RunWith(RobolectricTestRunner::class)
class ConfigReadTest {

    @Test
    fun `a read answers the fallback it was given, as the kind the fallback is`() {
        val flag: Boolean = Treebars.getConfig("new_checkout", false)
        val text: String = Treebars.getConfig("home_headline", "Welcome")
        val whole: Int = Treebars.getConfig("upload_limit_mb", 25)
        val decimal: Double = Treebars.getConfig("ratio", 2.5)
        val large: Long = Treebars.getConfig("quota_bytes", 9_000_000_000L)
        val empty: String = Treebars.getConfig("home_headline", "")

        assertEquals(false, flag)
        assertEquals("Welcome", text)
        assertEquals(25, whole)
        assertEquals(2.5, decimal, 0.0)
        assertEquals(9_000_000_000L, large)
        // Empty text is still text: a fallback for "nothing to show yet".
        assertEquals("", empty)
    }

    @Test
    fun `a kind named with no fallback answers null until a value is held`() {
        assertNull(Treebars.getConfigBoolean("new_checkout"))
        assertNull(Treebars.getConfigString("home_headline"))
        assertNull(Treebars.getConfigNumber("upload_limit_mb"))
        assertNull(Treebars.getConfigJson("home_layout"))
        // And with one, the fallback, as before.
        assertEquals(true, Treebars.getConfigBoolean("new_checkout", true))
        assertEquals("x", Treebars.getConfigString("home_headline", "x"))
        assertEquals(1.5, Treebars.getConfigNumber("upload_limit_mb", 1.5), 0.0)
        assertEquals("{}", Treebars.getConfigJson("home_layout", "{}"))
    }
}
