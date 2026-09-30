package com.treebars.sdk

import android.app.Activity
import android.content.Context
import android.os.Looper
import android.os.SystemClock
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import androidx.test.core.app.ApplicationProvider
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.android.controller.ActivityController
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowDialog
import java.io.File

/**
 * An HTML banner leaves the app usable: it is drawn on the Activity's own view tree, only as tall as itself, rather
 * than as a full-window Dialog that would take every touch on the screen — so the app under a banner can still be
 * tapped and scrolled. A modal and a fullscreen are a Dialog, because blocking the app is what they are for. Driven
 * through the real SDK, its HTML host and a Robolectric WebView, with the page's `_ready`
 * and `resize` posted through the bridge as the shim would post them.
 *
 * Robolectric does not route a touch from one window to another, so a Dialog in front of the app would not stop a touch
 * dispatched to the app's decor view here: what pins the banner is where it is attached and how tall it is, and the
 * touches only show that the app answers around it and not through it.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class InAppHtmlBannerTest {

    private val context: Context get() = ApplicationProvider.getApplicationContext()

    private fun message(deliveryId: String, layout: String, event: String = "add_to_cart") = JSONObject()
        .put("delivery_id", deliveryId)
        .put("campaign_id", "cmp_html")
        .put("created_at", "2026-01-01T00:00:00.000Z")
        .put("expires_at", JSONObject.NULL)
        .put(
            "content",
            JSONObject().put("title", "Spring sale").put(
                "in_app",
                JSONObject().put("surface", "overlay").put("layout", layout).put("position", "top").put("body_mode", "html")
                    .put("html", "<p>Spring sale</p>")
                    .put("trigger", JSONObject().put("kind", "event").put("event_name", event)),
            ),
        )

    private val screens = mutableListOf<ActivityController<Activity>>()

    private fun screen(): ActivityController<Activity> = Robolectric.buildActivity(Activity::class.java).setup().also { screens += it }

    /** Initialised first, then the screen: the tracker has to see the Activity resume to know there is one to draw on. */
    private fun start(vararg queue: JSONObject): ActivityController<Activity> {
        context.getSharedPreferences(Treebars.PREFS_NAME, Context.MODE_PRIVATE).edit().clear()
            .putString("in_app_queue", JSONArray().apply { queue.forEach { put(it) } }.toString())
            .commit()
        File(context.filesDir, EventQueue.FILE_NAME).delete()
        Treebars.initialize(context, "pk_test_html_banner", "http://localhost:1", autoTrackSessions = false, inAppPollIntervalMs = 0)
        val built = screen()
        settle()
        return built
    }

    private fun settle(done: () -> Boolean = { false }) {
        val until = System.currentTimeMillis() + 2_000
        while (System.currentTimeMillis() < until) {
            shadowOf(Looper.getMainLooper()).idle()
            if (done()) return
            Thread.sleep(25)
        }
    }

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    private fun queued(name: String): List<JSONObject> {
        val file = File(context.filesDir, EventQueue.FILE_NAME)
        if (!file.exists()) return emptyList()
        val all = JSONArray(file.readText())
        return (0 until all.length()).map { all.getJSONObject(it) }.filter { it.optString("event_name") == name }
    }

    /** Drawn for [event], then run: the page says it is running and how tall it is, and the host shows it. */
    private fun drawn(event: String = "add_to_cart", height: Int = 72): InAppHtmlHost {
        Treebars.track(event)
        settle { Treebars.htmlInAppHost?.webView != null }
        val host = requireNotNull(Treebars.htmlInAppHost) { "nothing was drawn" }
        val web = requireNotNull(host.webView)
        val document = requireNotNull(shadowOf(web).lastLoadDataWithBaseURL?.data)
        val nonce = requireNotNull(Regex("\"nonce\":\"([0-9a-f]+)\"").find(document)) { "no nonce in the document" }.groupValues[1]
        val bridge = shadowOf(web).getJavascriptInterface("TreebarsBridge") as InAppHtmlHost.Bridge
        fun call(id: Int, method: String, vararg args: Any) =
            bridge.postMessage(JSONObject().put("tb", nonce).put("id", id).put("method", method).put("args", JSONArray(args.toList())).toString())
        call(1, "_ready")
        call(2, "resize", height)
        settle { queued("in_app_displayed").isNotEmpty() }
        assertEquals("shown once it ran", 1, queued("in_app_displayed").size)
        return host
    }

    /** The app's own screen: one view filling it that counts the taps it is given. */
    private fun appContent(activity: Activity): MutableList<String> {
        val taps = mutableListOf<String>()
        activity.setContentView(FrameLayout(activity).apply { setOnClickListener { taps += "app" } })
        idle()
        return taps
    }

    /** A tap as a finger makes it, down and up at one point, dispatched to the Activity's window. */
    private fun tap(activity: Activity, x: Float, y: Float) {
        val decor = activity.window.decorView
        val at = SystemClock.uptimeMillis()
        decor.dispatchTouchEvent(MotionEvent.obtain(at, at, MotionEvent.ACTION_DOWN, x, y, 0))
        decor.dispatchTouchEvent(MotionEvent.obtain(at, at + 50, MotionEvent.ACTION_UP, x, y, 0))
        // A click is posted by the view that took the touch.
        idle()
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
        Treebars::class.java.getDeclaredField("writeKey").apply { isAccessible = true }.set(Treebars, null)
    }

    @Test
    fun `a banner is not a Dialog, and every touch outside it is the app's`() {
        val first = start(message("del_banner", "banner"))
        val activity = first.get()
        val taps = appContent(activity)
        val dialogs = ShadowDialog.getShownDialogs().size
        val host = drawn()

        assertNull("a banner has no window of its own", host.window)
        assertEquals("and shows none", dialogs, ShadowDialog.getShownDialogs().size)
        val box = requireNotNull(host.webView?.parent as? View)
        val decor = activity.window.decorView as ViewGroup
        assertTrue("on the Activity's own view tree", box.parent === decor)
        // Only as tall as its content, at its edge — never the whole window a Dialog takes.
        val params = box.layoutParams as FrameLayout.LayoutParams
        assertNotEquals(ViewGroup.LayoutParams.MATCH_PARENT, params.height)
        assertEquals((72 * activity.resources.displayMetrics.density).toInt(), params.height)
        assertEquals(Gravity.TOP, params.gravity and Gravity.VERTICAL_GRAVITY_MASK)
        assertEquals(View.VISIBLE, box.visibility)
        assertTrue("laid out below the top of the screen: ${decor.height}", decor.height > box.height * 2)
        // No window of its own for TalkBack to notice: named as a pane, read out as it turns visible.
        assertEquals("Spring sale", box.accessibilityPaneTitle?.toString())

        // Below the banner the app answers; on the banner it does not, the banner's own.
        tap(activity, decor.width / 2f, decor.height - 10f)
        assertEquals(listOf("app"), taps)
        tap(activity, decor.width / 2f, box.height / 2f)
        assertEquals("a touch on the banner is not passed through to the app", listOf("app"), taps)

        // Back is the app's, as the standard banner's is: the banner stays and nothing is recorded.
        activity.onBackPressed()
        idle()
        assertTrue(Treebars.htmlInAppHost === host)
        assertTrue(box.parent === decor)
        assertTrue(queued("in_app_dismissed").isEmpty())
    }

    @Test
    fun `a modal is still a full-window Dialog that takes every touch`() {
        start(message("del_modal", "modal"))
        val host = drawn()

        val dialog = requireNotNull(host.window) { "a modal is a Dialog" }
        assertTrue(dialog.isShowing)
        val attributes = requireNotNull(dialog.window).attributes
        assertEquals(WindowManager.LayoutParams.MATCH_PARENT, attributes.width)
        assertEquals(WindowManager.LayoutParams.MATCH_PARENT, attributes.height)
        assertEquals("touches outside it are not let through", 0, attributes.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL)
        assertTrue("not on the Activity's view tree", host.webView?.rootView !== screens.single().get().window.decorView)

        // A dismissible modal still closes on back.
        dialog.onBackPressed()
        settle { queued("in_app_dismissed").isNotEmpty() }
        assertEquals(1, queued("in_app_dismissed").size)
        assertNull(Treebars.htmlInAppHost)
    }

    @Test
    fun `a banner goes when the person moves to another screen under it, and the next screen can draw`() {
        val first = start(message("del_banner", "banner"), message("del_next", "modal", event = "checkout"))
        val host = drawn()
        val box = requireNotNull(host.webView?.parent as? View)

        // The app is only sent away and brought back: the banner is still there.
        first.pause()
        first.resume()
        settle()
        assertTrue("backgrounding is not moving on", Treebars.htmlInAppHost === host)

        // The person taps through to another screen under it: it goes, quietly, and frees the screen.
        first.pause()
        val second = screen()
        settle()
        assertNull(Treebars.htmlInAppHost)
        assertNull("off the first screen's view tree", box.parent)
        assertTrue(queued("in_app_dismissed").isEmpty())

        Treebars.track("checkout")
        settle { Treebars.htmlInAppHost != null }
        assertNotNull("the next message is drawn", Treebars.htmlInAppHost)
        assertTrue("on the screen in front", Treebars.htmlInAppHost?.owner === second.get())
    }
}
