package com.treebars.sdk

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.treebars.sdk.generated.TreebarsConstants
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File
import java.nio.file.Files

/*
 * An app rebuilt with another write key. What the previous key left — the unsent queue, a sealed
 * batch, the session whose `session_end` is owed at the next launch — belongs to the previous
 * project, and is dropped rather than sent into the new one the moment the app starts.
 */
@RunWith(RobolectricTestRunner::class)
class WriteKeyStampTest {

    private val t0 = 1787475600000L // 2026-08-23T09:00:00.000Z

    private fun prefs(name: String) = ApplicationProvider.getApplicationContext<Context>()
        .getSharedPreferences("treebars.stamp.$name", Context.MODE_PRIVATE)

    private fun directory(): File = Files.createTempDirectory("treebars-stamp").toFile()

    /** What a launch under key A leaves: a queued event, a sealed batch, and a session that will have aged out. */
    private fun leftBy(name: String, key: String): Pair<android.content.SharedPreferences, File> {
        val prefs = prefs(name)
        val dir = directory()
        assertFalse("a first launch adopts its key", WriteKeyStamp.claim(prefs, dir, key))
        runBlocking { EventQueue(dir).append(JSONObject().put("event_id", "old-1").put("event_name", "viewed")) }
        UploaderStore(dir).save(UploaderState(pending = listOf(PendingBatch("b1", "2026-08-23T09:00:00.000Z", listOf(JSONObject().put("event_id", "old-0"))))))
        SessionManager(prefs) { t0 }.touch()
        prefs.edit().putString("device_context_hash", "aaaa:$t0").commit()
        return prefs to dir
    }

    /** The next launch, three hours later: the session it finds has expired, and would be closed. */
    private fun nextLaunch(prefs: android.content.SharedPreferences) = SessionManager(prefs) { t0 + 3 * 60 * 60 * 1000L }.touch()

    @Test
    fun `a different key drops the previous key's queue, batches and session before anything reads them`() {
        val (prefs, dir) = leftBy("switch", "pk_live_before")

        assertTrue(WriteKeyStamp.claim(prefs, dir, "pk_live_after"))

        assertEquals(0, runBlocking { EventQueue(dir).size() })
        assertTrue(UploaderStore(dir).load().pending.isEmpty())
        val launch = nextLaunch(prefs)
        assertNull("no session_end is owed to the new project for the old one's session", launch.expired)
        assertFalse("the install has still been used: not a first session", launch.isFirstSession)
        assertNull("the new project hears about the device again", prefs.getString("device_context_hash", null))
        assertEquals("pk_live_after", prefs.getString(WriteKeyStamp.KEY, null))
        assertFalse(File(dir, TreebarsConstants.TRIGGERS_FILE).exists())
    }

    @Test
    fun `the same key keeps all of it, and the aged-out session is still closed`() {
        val (prefs, dir) = leftBy("same", "pk_live_before")

        assertFalse(WriteKeyStamp.claim(prefs, dir, "pk_live_before"))

        assertEquals(1, runBlocking { EventQueue(dir).size() })
        assertEquals(1, UploaderStore(dir).load().pending.size)
        assertNotNull(nextLaunch(prefs).expired)
        assertNotNull(prefs.getString("device_context_hash", null))
    }

    @Test
    fun `an install from before the stamp adopts the key and drops nothing`() {
        val prefs = prefs("legacy")
        val dir = directory()
        runBlocking { EventQueue(dir).append(JSONObject().put("event_id", "old-1")) }
        SessionManager(prefs) { t0 }.touch()

        assertFalse(WriteKeyStamp.claim(prefs, dir, "pk_live_after"))

        assertEquals(1, runBlocking { EventQueue(dir).size() })
        assertNotNull(nextLaunch(prefs).expired)
        assertEquals("pk_live_after", prefs.getString(WriteKeyStamp.KEY, null))
    }
}
