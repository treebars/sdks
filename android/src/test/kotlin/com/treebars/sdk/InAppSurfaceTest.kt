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
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf

/**
 * An in-app message is recorded as displayed only when it has a screen to appear on.
 *
 * Recording the display — sending `in_app_displayed`, stamping `displayed_at`, spending the message — before the
 * renderer has somewhere to draw would count a modal nobody saw: a React Native renderer whose React context has no
 * current Activity, for one. These drive the real SDK, through the real Activity tracker, with Robolectric's Activity
 * lifecycle standing in for the screen.
 */
@RunWith(RobolectricTestRunner::class)
class InAppSurfaceTest {

    private val context: Context get() = ApplicationProvider.getApplicationContext()

    /** What the renderer was handed, in order. */
    private val shown = mutableListOf<String>()
    private val dismissals = mutableListOf<() -> Unit>()

    /** A renderer that can say it cannot attach, as the React Native bridge's does. */
    private var attachable = true
    private val renderer = object : Treebars.InAppRenderer, Treebars.InAppSurfaceCheck {
        override fun canPresent() = attachable
        override fun show(message: InAppMessage, tokens: InAppTokens?, onClick: (InAppButton) -> Unit, onDismiss: () -> Unit) {
            shown += message.deliveryId
            dismissals += onDismiss
        }
    }

    private fun message(deliveryId: String, trigger: JSONObject) = JSONObject()
        .put("delivery_id", deliveryId)
        .put("campaign_id", "cmp_1")
        .put("created_at", "2026-01-01T00:00:00.000Z")
        .put("expires_at", JSONObject.NULL)
        .put(
            "content",
            JSONObject().put("title", "Hello").put(
                "in_app",
                JSONObject().put("surface", "overlay").put("layout", "modal").put("trigger", trigger).put("max_displays", 1),
            ),
        )

    /** Whether the device's own ledger has spent the message: `max_displays` 1, so one recorded display is done. */
    private fun spent(deliveryId: String): Boolean {
        val store = InAppStore(context, Treebars.PREFS_NAME)
        return store.blockedBy(store.list().first { it.deliveryId == deliveryId }) == "done"
    }

    /**
     * Runs the main looper, and waits for the SDK's background coroutines, until [done] or two seconds pass. The
     * launch's `app_open` is considered on a coroutine and its presentation posted from there.
     */
    private fun settle(done: () -> Boolean = { false }) {
        val until = System.currentTimeMillis() + 2_000
        while (System.currentTimeMillis() < until) {
            shadowOf(Looper.getMainLooper()).idle()
            if (done()) return
            Thread.sleep(25)
        }
    }

    /*
     * `Treebars` is a process singleton and Robolectric keeps one per sandbox, shared by every test class on the same
     * SDK level — and `PushReceiptsTest` asserts on an SDK that was never initialised. Putting the one field that
     * means "initialised" back is what lets this test live beside it; everything else is re-set by `initialize`.
     */
    @After
    fun forgetInitialize() {
        Treebars::class.java.getDeclaredField("writeKey").apply { isAccessible = true }.set(Treebars, null)
        Treebars.setInAppRenderer(null)
        TreebarsPush.processResumed = {
            runCatching {
                androidx.lifecycle.ProcessLifecycleOwner.get().lifecycle.currentState
                    .isAtLeast(androidx.lifecycle.Lifecycle.State.RESUMED)
            }.getOrDefault(true)
        }
    }

    @Test
    fun `a message with no screen is held unspent, and shown and recorded on the next resume`() {
        /*
         * A host initialised from `Application.onCreate`, before any Activity exists. The queue from the last
         * launch is already on the device, holding an "app is opened" message; the launch's own sync cannot reach a
         * backend here, so that is what `app_open` is offered against.
         */
        context.getSharedPreferences(Treebars.PREFS_NAME, Context.MODE_PRIVATE).edit().clear()
            .putString(
                "in_app_queue",
                JSONArray()
                    .put(message("del_open", JSONObject().put("kind", "session_start")))
                    .put(message("del_cart", JSONObject().put("kind", "event").put("event_name", "add_to_cart")))
                    .toString(),
            )
            .commit()
        TreebarsPush.processResumed = { false }
        Treebars.setInAppRenderer(renderer)
        Treebars.initialize(context, "pk_test_surface", "http://localhost:1", autoTrackSessions = false, inAppPollIntervalMs = 0)

        settle()
        assertTrue("nothing drawn with no Activity in front", shown.isEmpty())
        assertFalse("and nothing spent: the display is not recorded", spent("del_open"))

        // The first screen arrives: the held `app_open` is answered, once.
        val activity = Robolectric.buildActivity(Activity::class.java).setup()
        settle { shown.isNotEmpty() }
        assertEquals(listOf("del_open"), shown)
        assertTrue("recorded now that it was drawn", spent("del_open"))

        /*
         * The React Native case: an Activity is in front, but the renderer cannot attach to it — its React context's
         * current Activity is null, and a Modal drawn there appears nowhere. Held again, unspent, until a resume finds
         * the renderer able.
         */
        dismissals.single()()
        attachable = false
        Treebars.track("add_to_cart")
        settle()
        assertEquals("not drawn where it cannot appear", listOf("del_open"), shown)
        assertFalse(spent("del_cart"))

        attachable = true
        activity.pause().resume()
        settle { shown.size == 2 }
        assertEquals(listOf("del_open", "del_cart"), shown)
        assertTrue(spent("del_cart"))
    }

    @Test
    fun `the tracker answers for the screen in front, over whatever the process says`() {
        val app = context as android.app.Application
        app.registerActivityLifecycleCallbacks(TreebarsPush.activityTracker)
        try {
            val activity = Robolectric.buildActivity(Activity::class.java).setup()
            assertTrue(TreebarsPush.hasResumedActivity())
            activity.pause()
            TreebarsPush.processResumed = { true }
            assertFalse("paused: the app is on its way out, whatever the process says", TreebarsPush.hasResumedActivity())
            activity.resume()
            assertTrue(TreebarsPush.hasResumedActivity())
            activity.pause().stop().destroy()
            assertFalse("gone: Back finished it", TreebarsPush.hasResumedActivity())
        } finally {
            app.unregisterActivityLifecycleCallbacks(TreebarsPush.activityTracker)
        }
    }
}
