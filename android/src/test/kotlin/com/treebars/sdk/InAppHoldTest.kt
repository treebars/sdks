package com.treebars.sdk

import android.app.Activity
import android.content.Context
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.android.controller.ActivityController
import java.io.File
import java.time.Duration
import java.util.concurrent.atomic.AtomicBoolean

/**
 * [Treebars.holdInApp] holds every message, the ones already waiting out a display delay included, and the ones
 * already chosen and on their way to the screen.
 *
 * An app holds the screen while it shows something no message may cover — a lock screen, a passcode — and that can
 * begin after a delayed message's trigger fired and before its delay ends, or after a message was chosen and before
 * it is drawn: while a markup body's files are fetched, say. The message must keep waiting, unspent, and be drawn once
 * the app releases the screen. These drive the real SDK, with Robolectric's main looper as the clock the delay runs
 * on, and for a markup body its HTML host, a Robolectric WebView, and a fake network in the SDK's asset cache.
 */
@RunWith(RobolectricTestRunner::class)
class InAppHoldTest {
    @get:Rule val folder = TemporaryFolder()

    private val context: Context get() = ApplicationProvider.getApplicationContext()

    /** What the renderer was handed, in order. */
    private val shown = mutableListOf<String>()

    private val renderer = object : Treebars.InAppRenderer {
        override fun show(message: InAppMessage, tokens: InAppTokens?, onClick: (InAppButton) -> Unit, onDismiss: () -> Unit) {
            shown += message.deliveryId
        }
    }

    private val screens = mutableListOf<ActivityController<Activity>>()

    private fun message(deliveryId: String, eventName: String, delaySeconds: Int? = null, html: String? = null) = JSONObject()
        .put("delivery_id", deliveryId)
        .put("campaign_id", "cmp_1")
        .put("created_at", "2026-01-01T00:00:00.000Z")
        .put("expires_at", JSONObject.NULL)
        .put(
            "content",
            JSONObject().put("title", "Hello").put(
                "in_app",
                JSONObject().put("surface", "overlay").put("layout", "modal")
                    .put("trigger", JSONObject().put("kind", "event").put("event_name", eventName))
                    .apply { if (delaySeconds != null) put("display", JSONObject().put("on", "delay").put("delay_seconds", delaySeconds)) }
                    .apply { if (html != null) put("body_mode", "html").put("html", html) }
                    .put("max_displays", 1),
            ),
        )

    private fun delayedMessage(deliveryId: String, eventName: String, delaySeconds: Int) = message(deliveryId, eventName, delaySeconds)

    /** Whether the device's own ledger has spent the message: `max_displays` 1, so one recorded display is done. */
    private fun spent(deliveryId: String): Boolean {
        val store = InAppStore(context, Treebars.PREFS_NAME)
        return store.blockedBy(store.list().first { it.deliveryId == deliveryId }) == "done"
    }

    private fun start(queue: JSONObject) {
        context.getSharedPreferences(Treebars.PREFS_NAME, Context.MODE_PRIVATE).edit().clear()
            .putString("in_app_queue", JSONArray().put(queue).toString())
            .commit()
        File(context.filesDir, EventQueue.FILE_NAME).delete()
        Treebars.initialize(context, "pk_test_hold", "http://localhost:1", autoTrackSessions = false, inAppPollIntervalMs = 0)
    }

    private fun showScreen() {
        screens += Robolectric.buildActivity(Activity::class.java).setup()
        settle()
    }

    /*
     * A markup body naming one picture, which the display fetches: nothing prefetched it, because the sync this
     * initialise starts cannot reach its host. [onFetch] runs on the fetching thread, as the network would.
     */
    private val png = "png-bytes".toByteArray()
    private val sha = InAppAssetCache.sha256Hex(png)
    private val url = "https://api.treebars.test/assets/11111111-1111-4111-8111-111111111111/$sha.png"

    private fun startMarkup(deliveryId: String, eventName: String, delaySeconds: Int? = null, onFetch: () -> Unit) {
        val queued = message(deliveryId, eventName, delaySeconds, html = "<img src=\"$url\" alt=\"sale\">")
            .put("assets", JSONObject().put("files", JSONArray().put(JSONObject().put("url", url).put("sha256", sha).put("type", "image/png").put("bytes", png.size))))
        start(queued)
        val network = InAppAssetFetch { address, max ->
            onFetch()
            png.takeIf { address == url && it.size <= max }
        }
        Treebars::class.java.getDeclaredField("assetCache").apply { isAccessible = true }.set(Treebars, InAppAssetCache(folder.newFolder(), network))
        showScreen()
    }

    private fun queued(name: String): List<JSONObject> {
        val file = File(context.filesDir, EventQueue.FILE_NAME)
        if (!file.exists()) return emptyList()
        val all = JSONArray(file.readText())
        return (0 until all.length()).map { all.getJSONObject(it) }.filter { it.optString("event_name") == name }
    }

    /** Runs what is due on the main looper, and waits for the SDK's background work, until [done] or two seconds pass. */
    private fun settle(done: () -> Boolean = { false }) {
        val until = System.currentTimeMillis() + 2_000
        while (System.currentTimeMillis() < until) {
            shadowOf(Looper.getMainLooper()).idle()
            if (done()) return
            Thread.sleep(25)
        }
    }

    /** Moves the main looper's clock on, running the delayed work that comes due — the delay, and each look after it. */
    private fun advance(millis: Long) {
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(millis))
        settle()
    }

    /*
     * `Treebars` is a process singleton shared by every test class in the sandbox, so what this test set is put back:
     * the hold, the message waiting out its delay, what is on screen, the screens, and the field that means
     * "initialised" (as `InAppSurfaceTest` does).
     */
    @After
    fun forgetInitialize() {
        shadowOf(Looper.getMainLooper()).idle()
        for (built in screens) {
            runCatching { built.pause() }
            runCatching { built.stop() }
            runCatching { built.destroy() }
        }
        Treebars.takeDownInAppForTest()
        for ((name, value) in listOf("inAppHeld" to false, "delayedDelivery" to null, "writeKey" to null)) {
            Treebars::class.java.getDeclaredField(name).apply { isAccessible = true }.set(Treebars, value)
        }
        Treebars.setInAppRenderer(null)
    }

    @Test
    fun `a delayed message whose trigger fired before the hold is drawn after release, not over the hold`() {
        Treebars.setInAppRenderer(renderer)
        start(delayedMessage("del_later", "add_to_cart", 2))
        showScreen()

        // The trigger fires, and the message starts waiting out its two seconds.
        Treebars.track("add_to_cart")
        settle()
        advance(1_000)
        assertTrue("still waiting out its delay", shown.isEmpty())

        // The app's lock comes up before the delay ends, and stays up well past it.
        Treebars.holdInApp()
        advance(1_500)
        advance(5_000)
        assertEquals("nothing drawn over the hold", emptyList<String>(), shown)
        assertFalse("and nothing spent", spent("del_later"))

        // The lock goes: the message is drawn, once.
        Treebars.releaseInApp()
        settle()
        advance(1_000)
        assertEquals(listOf("del_later"), shown)
        assertTrue("recorded now that it was drawn", spent("del_later"))
        advance(5_000)
        assertEquals("drawn once", listOf("del_later"), shown)
    }

    @Test
    fun `a hold that begins after a message is chosen and before it is drawn holds it, and release draws it`() {
        Treebars.setInAppRenderer(renderer)
        start(message("del_now", "add_to_cart"))
        showScreen()

        // `track` chooses the message and claims the screen on this thread; the draw is posted to the main looper, which
        // runs only when the test lets it — and the app's lock comes up first.
        Treebars.track("add_to_cart")
        Treebars.holdInApp()
        settle()
        assertEquals("nothing drawn over the hold", emptyList<String>(), shown)
        assertFalse("and nothing spent", spent("del_now"))

        // The trigger was kept: release answers it.
        Treebars.releaseInApp()
        settle { shown.isNotEmpty() }
        assertEquals(listOf("del_now"), shown)
        assertTrue("recorded now that it was drawn", spent("del_now"))
    }

    @Test
    fun `a lock screen that comes up while a markup message's files are fetched is not drawn over, and release draws it`() {
        val holdOnFetch = AtomicBoolean(false)
        val heldDuringFetch = AtomicBoolean(false)
        startMarkup("del_page", "add_to_cart") {
            if (holdOnFetch.getAndSet(false)) {
                Treebars.holdInApp()
                heldDuringFetch.set(true)
            }
        }

        holdOnFetch.set(true)
        Treebars.track("add_to_cart")
        settle()
        assertTrue("the hold began during the fetch", heldDuringFetch.get())
        assertNull("nothing drawn over the hold", Treebars.htmlInAppHost)
        assertTrue("nor reported as failed", queued("in_app_failed").isEmpty())

        Treebars.releaseInApp()
        settle { Treebars.htmlInAppHost?.webView != null }
        assertNotNull("drawn once released", Treebars.htmlInAppHost?.webView)
    }

    @Test
    fun `a delayed markup message whose files are fetched as the hold begins waits it out, and is drawn after release`() {
        val holdOnFetch = AtomicBoolean(false)
        val heldDuringFetch = AtomicBoolean(false)
        startMarkup("del_page_later", "add_to_cart", delaySeconds = 1) {
            if (holdOnFetch.getAndSet(false)) {
                Treebars.holdInApp()
                heldDuringFetch.set(true)
            }
        }

        // The delay ends with nothing held, so the look chooses to draw; the lock comes up while the files are fetched.
        Treebars.track("add_to_cart")
        settle()
        holdOnFetch.set(true)
        advance(1_000)
        assertTrue("the hold began during the fetch", heldDuringFetch.get())
        assertNull("nothing drawn over the hold", Treebars.htmlInAppHost)

        // It waits out the hold, look after look.
        advance(5_000)
        assertNull("still nothing drawn over the hold", Treebars.htmlInAppHost)
        assertTrue("nor reported as failed", queued("in_app_failed").isEmpty())

        Treebars.releaseInApp()
        settle()
        advance(1_000)
        settle { Treebars.htmlInAppHost?.webView != null }
        assertNotNull("drawn once released", Treebars.htmlInAppHost?.webView)
    }
}
