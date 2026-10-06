package com.treebars.sdk

import android.content.Context
import android.content.ContextWrapper
import android.content.pm.PackageManager
import android.os.Looper
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.ProcessLifecycleOwner
import androidx.test.core.app.ApplicationProvider
import com.treebars.sdk.generated.TreebarsConstants
import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf

/**
 * `app_open`, `app_foreground` and `app_background` say which app: each carries the app's display
 * name as `name`, beside the property it always had. Every app sends these three, so in a list of
 * events the name is the only thing that tells one row of them from the next.
 *
 * The last test drives the real SDK through a launch, a trip to the background and a return, and
 * reads the three events as they were recorded. The process lifecycle is moved by hand: a unit test
 * has no manifest to start it, and it is the same registry the SDK's observer sits on. `Treebars`
 * is one object per sandbox and earlier suites leave their observers on that registry, so a
 * transition can be recorded more than once here: what is asserted is that each event exists and
 * that every copy of it carries the name.
 */
@RunWith(RobolectricTestRunner::class)
class LifecycleEventNameTest {

    private val context: Context get() = ApplicationProvider.getApplicationContext()

    @After
    fun forgetInitialize() {
        Treebars::class.java.getDeclaredField("writeKey").apply { isAccessible = true }.set(Treebars, null)
    }

    @Test
    fun `the name sits beside the event's own properties, and is left out when there is none`() {
        assertEquals(
            mapOf("name" to "Acme Shop", "is_first_launch" to true),
            lifecycleEventProperties("Acme Shop", "is_first_launch" to true),
        )
        assertEquals(
            mapOf("name" to "Acme Shop", "background_ms" to 1_200L),
            lifecycleEventProperties("Acme Shop", "background_ms" to 1_200L),
        )
        val unnamed = lifecycleEventProperties(null, "foreground_ms" to 900L)
        assertEquals(mapOf("foreground_ms" to 900L), unnamed)
        assertFalse("omitted, not sent as null", unnamed.containsKey("name"))
    }

    @Test
    fun `the name is the app's label, trimmed, and nothing when it is blank or cannot be read`() {
        context.applicationInfo.nonLocalizedLabel = "  Acme Shop "
        assertEquals("Acme Shop", DeviceInfo.appName(context))

        context.applicationInfo.nonLocalizedLabel = "   "
        assertNull(DeviceInfo.appName(context))

        val unreadable = object : ContextWrapper(context) {
            override fun getPackageManager(): PackageManager = throw IllegalStateException("no package manager")
        }
        assertNull(DeviceInfo.appName(unreadable))
    }

    /** Every event this install has recorded: still on the queue, or sealed into a batch that could not be sent. */
    private fun recorded(name: String): List<JSONObject> {
        fun array(file: File): JSONArray? = file.takeIf { it.exists() }?.let { runCatching { JSONArray(it.readText()) }.getOrNull() }
        fun objects(array: JSONArray?) = if (array == null) emptyList() else (0 until array.length()).map { array.getJSONObject(it) }

        val queued = objects(array(File(context.filesDir, EventQueue.FILE_NAME)))
        val sealed = File(context.filesDir, TreebarsConstants.UPLOADER_FILE).takeIf { it.exists() }
            ?.let { runCatching { JSONObject(it.readText()).optJSONArray("pending") }.getOrNull() }
            .let(::objects)
            .flatMap { objects(it.optJSONArray("events")) }
        return (queued + sealed).distinctBy { it.getString("event_id") }.filter { it.optString("event_name") == name }
    }

    /** Runs the main looper, and waits for the SDK's background coroutines, until [done] or five seconds pass. */
    private fun settle(done: () -> Boolean): Boolean {
        val until = System.currentTimeMillis() + 5_000
        while (System.currentTimeMillis() < until) {
            shadowOf(Looper.getMainLooper()).idle()
            if (done()) return true
            Thread.sleep(25)
        }
        return false
    }

    @Test
    fun `a launch, a trip to the background and a return each record the app's name`() {
        context.applicationInfo.nonLocalizedLabel = "Acme Shop"
        File(context.filesDir, EventQueue.FILE_NAME).delete()
        File(context.filesDir, TreebarsConstants.UPLOADER_FILE).delete()

        // Nothing answers on this port: the events stay on the device, where this reads them.
        Treebars.initialize(context, "pk_test_lifecycle_name", "http://localhost:1", inAppPollIntervalMs = 0)
        assertTrue("app_open was never recorded", settle { recorded(Treebars.EVENT_APP_OPEN).isNotEmpty() })
        for (opened in recorded(Treebars.EVENT_APP_OPEN)) {
            val properties = opened.getJSONObject("properties")
            assertEquals("Acme Shop", properties.getString("name"))
            assertTrue("and still says whether this was the first launch", properties.has("is_first_launch"))
        }

        val process = ProcessLifecycleOwner.get().lifecycle as LifecycleRegistry
        try {
            // In front, which records nothing: the launch's `app_open` already said so.
            process.handleLifecycleEvent(Lifecycle.Event.ON_START)

            process.handleLifecycleEvent(Lifecycle.Event.ON_STOP)
            assertTrue("app_background was never recorded", settle { recorded(Treebars.EVENT_APP_BACKGROUND).isNotEmpty() })
            for (left in recorded(Treebars.EVENT_APP_BACKGROUND)) {
                val properties = left.getJSONObject("properties")
                assertEquals("Acme Shop", properties.getString("name"))
                assertTrue(properties.has("foreground_ms"))
            }

            process.handleLifecycleEvent(Lifecycle.Event.ON_START)
            assertTrue("app_foreground was never recorded", settle { recorded(Treebars.EVENT_APP_FOREGROUND).isNotEmpty() })
            for (back in recorded(Treebars.EVENT_APP_FOREGROUND)) {
                val properties = back.getJSONObject("properties")
                assertEquals("Acme Shop", properties.getString("name"))
                assertTrue(properties.has("background_ms"))
            }
        } finally {
            // Behind again, so the next suite starts with an app that is not in front.
            process.handleLifecycleEvent(Lifecycle.Event.ON_STOP)
        }
    }
}
