package com.treebars.sdk

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Looper
import android.view.View
import androidx.test.core.app.ApplicationProvider
import com.treebars.sdk.generated.TreebarsConstants
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.android.controller.ActivityController
import java.io.File

/**
 * Where the native renderer is hooked in. With no app renderer registered, the SDK draws a standard message itself; a
 * registered renderer is the override, and then the SDK draws nothing. Driven through the real SDK and the real
 * Activity tracker, as `InAppSurfaceTest` is.
 */
@RunWith(RobolectricTestRunner::class)
class InAppNativeHookTest {

    private val context: Context get() = ApplicationProvider.getApplicationContext()

    private val lifecycle = mutableListOf<String>()
    private val listener = object : InAppLifeCycleListener {
        override fun onShown(message: InAppMessage) {
            lifecycle += "shown ${message.deliveryId}"
        }
        override fun onDismiss(message: InAppMessage) {
            lifecycle += "dismissed ${message.deliveryId}"
        }
    }

    private fun message(deliveryId: String, layout: String = "modal", event: String = "add_to_cart") = JSONObject()
        .put("delivery_id", deliveryId)
        .put("campaign_id", "cmp_native")
        .put("created_at", "2026-01-01T00:00:00.000Z")
        .put("expires_at", JSONObject.NULL)
        .put(
            "content",
            JSONObject().put("title", "Spring sale").put("body", "Thirty percent off.").put(
                "in_app",
                JSONObject().put("surface", "overlay").put("layout", layout).put("max_displays", 1)
                    .put("trigger", JSONObject().put("kind", "event").put("event_name", event))
                    .put(
                        "buttons",
                        JSONArray()
                            .put(JSONObject().put("label", "Shop now").put("action", "deep_link").put("value", "shop://sale"))
                            .put(JSONObject().put("label", "Later").put("action", "dismiss")),
                    ),
            ),
        )

    private fun spent(deliveryId: String): Boolean {
        val store = InAppStore(context, Treebars.PREFS_NAME)
        return store.blockedBy(store.list().first { it.deliveryId == deliveryId }) == "done"
    }

    private fun settle(done: () -> Boolean = { false }) {
        val until = System.currentTimeMillis() + 2_000
        while (System.currentTimeMillis() < until) {
            shadowOf(Looper.getMainLooper()).idle()
            if (done()) return
            Thread.sleep(25)
        }
    }

    /** The events the SDK queued, by name, read from its queue file once they have landed. */
    private fun queued(name: String): List<JSONObject> {
        val file = File(context.filesDir, EventQueue.FILE_NAME)
        if (!file.exists()) return emptyList()
        val all = JSONArray(file.readText())
        return (0 until all.length()).map { all.getJSONObject(it) }.filter { it.optString("event_name") == name }
    }

    /**
     * Every screen a test built, taken down after it: the Activity tracker is a process singleton, and a screen left
     * resumed is the one `InAppStore.tokensFor` reads its night mode from in every test class after this one.
     */
    private val screens = mutableListOf<ActivityController<Activity>>()

    private fun screen(): ActivityController<Activity> = Robolectric.buildActivity(Activity::class.java).setup().also { screens += it }

    /** Initialised first, then the screen: the tracker has to see the Activity resume to know there is one to draw on. */
    private fun start(vararg queue: JSONObject = arrayOf(message("del_native"))): ActivityController<Activity> {
        context.getSharedPreferences(Treebars.PREFS_NAME, Context.MODE_PRIVATE).edit().clear()
            .putString("in_app_queue", JSONArray().apply { queue.forEach { put(it) } }.toString())
            .commit()
        File(context.filesDir, EventQueue.FILE_NAME).delete()
        Treebars.addInAppLifeCycleListener(listener)
        Treebars.initialize(context, "pk_test_native", "http://localhost:1", autoTrackSessions = false, inAppPollIntervalMs = 0)
        val built = screen()
        settle()
        return built
    }

    @After
    fun forgetInitialize() {
        shadowOf(Looper.getMainLooper()).idle()
        for (built in screens) {
            runCatching { built.pause() }
            runCatching { built.stop() }
            runCatching { built.destroy() }
        }
        Treebars.takeDownInAppForTest()
        Treebars.removeInAppLifeCycleListener(listener)
        Treebars.setClickActionListener(null)
        Treebars.setInAppRenderer(null)
        Treebars::class.java.getDeclaredField("writeKey").apply { isAccessible = true }.set(Treebars, null)
    }

    @Test
    fun `with no renderer the core draws a standard message itself and records it as any display`() {
        start()
        assertNull(Treebars.nativeInAppHost)
        Treebars.track("add_to_cart")
        settle { Treebars.nativeInAppHost != null }

        val host = requireNotNull(Treebars.nativeInAppHost) { "the core drew nothing" }
        assertTrue("a modal, drawn in its own window", host.window?.isShowing == true)
        assertTrue("spent as a display is", spent("del_native"))
        assertEquals(listOf("shown del_native"), lifecycle)

        // The ✕ is a dismissal: recorded, and the screen freed for the next message.
        host.views.root.findViewWithTag<View>(InAppNativeTags.CLOSE).performClick()
        settle { queued("in_app_dismissed").isNotEmpty() }
        assertNull(Treebars.nativeInAppHost)
        assertFalse(host.window?.isShowing == true)
        assertEquals(listOf("shown del_native", "dismissed del_native"), lifecycle)
        assertEquals(1, queued("in_app_displayed").size)
        assertEquals(1, queued("in_app_dismissed").size)
    }

    @Test
    fun `a press is recorded with its button index, the message closes, then the destination opens`() {
        val activity = start().get()
        val clicks = mutableListOf<InAppClickAction>()
        Treebars.setClickActionListener { action, _ -> clicks += action; true }
        Treebars.track("add_to_cart")
        settle { Treebars.nativeInAppHost != null }
        val host = Treebars.nativeInAppHost!!

        host.views.root.findViewWithTag<View>("treebars:button:1").performClick()
        settle { queued("in_app_clicked").isNotEmpty() }
        assertNull("closed, and the screen free", Treebars.nativeInAppHost)
        val click = queued("in_app_clicked").single().getJSONObject("properties")
        assertEquals(1, click.getInt("button_index"))
        assertEquals("Shop now", click.getString("button_label"))
        assertEquals("shop://sale", click.getString("destination"))
        assertEquals("cmp_native", click.getString(TreebarsConstants.CAMPAIGN_ID_KEY))
        assertEquals(1, clicks.single().button.index)
        val opened = shadowOf(activity).nextStartedActivity
        assertEquals(Intent.ACTION_VIEW, opened?.action)
        assertEquals("shop://sale", opened?.dataString)
        assertTrue(queued("in_app_dismissed").isEmpty())
    }

    @Test
    fun `a registered renderer is still the override, and then the core draws nothing`() {
        val shown = mutableListOf<String>()
        Treebars.setInAppRenderer { message, _, _, _ -> shown += message.deliveryId }
        start()
        Treebars.track("add_to_cart")
        settle { shown.isNotEmpty() }
        assertEquals(listOf("del_native"), shown)
        assertNull("nothing of the core's own on screen", Treebars.nativeInAppHost)
    }

    @Test
    fun `a message with no screen to draw on is held unspent, and drawn on the next resume`() {
        val screen = start()
        screen.pause()
        Treebars.track("add_to_cart")
        settle()
        assertNull("no screen in front: nothing drawn", Treebars.nativeInAppHost)
        assertFalse("and nothing spent", spent("del_native"))

        screen.resume()
        settle { Treebars.nativeInAppHost != null }
        assertNotNull("answered on the resume", Treebars.nativeInAppHost)
        assertTrue(spent("del_native"))
    }

    @Test
    fun `a banner goes when the person moves to another screen under it, and the next screen can draw`() {
        val first = start(message("del_banner", layout = "banner"), message("del_next", event = "checkout"))
        Treebars.track("add_to_cart")
        settle { Treebars.nativeInAppHost != null }
        val banner = requireNotNull(Treebars.nativeInAppHost) { "the banner was not drawn" }
        assertNull("a banner is not a Dialog", banner.window)
        val view = banner.views.root
        assertTrue(view.parent === first.get().window.decorView)

        // The app is only sent away and brought back: the banner is still there.
        first.pause()
        first.resume()
        settle()
        assertTrue("backgrounding is not moving on", Treebars.nativeInAppHost === banner)

        // The person taps through to another screen under it: it goes, quietly, and frees the screen.
        first.pause()
        val second = screen()
        settle()
        assertNull(Treebars.nativeInAppHost)
        assertNull("off the first screen's view tree", view.parent)
        assertTrue(queued("in_app_dismissed").isEmpty())

        Treebars.track("checkout")
        settle { Treebars.nativeInAppHost != null }
        assertTrue("the next message is drawn on the screen in front", Treebars.nativeInAppHost?.owner === second.get())
    }
}
