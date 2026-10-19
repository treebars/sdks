package com.treebars.sdk

import com.treebars.sdk.generated.TreebarsConstants
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The app's `onAction`: the dispatcher every SDK runs, held to the shared cases (`app-action-scenarios.json`) — which
 * handlers an action reaches, how long one nothing has subscribed to waits, and what is recorded about each — with a
 * clock the test moves. And a push's own tap action, which reaches the same dispatcher. Robolectric for org.json.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AppActionsTest {

    private fun fixture(): JSONObject =
        JSONObject(requireNotNull(javaClass.classLoader?.getResource("bridge/app-action-scenarios.json")) { "app-action-scenarios.json is missing" }.readText())

    /** A clock and its timers, run when the test moves it. */
    private class Clock {
        var now = 0L
        private class Timer(val at: Long, val work: () -> Unit) {
            var cancelled = false
        }
        private val timers = mutableListOf<Timer>()
        fun later(ms: Long, work: () -> Unit): Any = Timer(now + ms, work).also { timers.add(it) }
        fun cancel(timer: Any) {
            (timer as Timer).cancelled = true
        }
        fun advance(ms: Long) {
            val until = now + ms
            while (true) {
                val next = timers.filter { !it.cancelled && it.at <= until }.minByOrNull { it.at } ?: break
                timers.remove(next)
                now = next.at
                next.work()
            }
            now = until
        }
    }

    @Test
    fun everyCaseMeansWhatItMeansOnTheWeb() {
        val cases = fixture().getJSONArray("cases")
        assertTrue(cases.length() > 0)
        for (i in 0 until cases.length()) run(cases.getJSONObject(i))
    }

    private fun source(json: JSONObject) = AppActionSource(
        json.getString("kind"),
        if (json.isNull("campaign_id")) null else json.optString("campaign_id").takeIf { it.isNotEmpty() },
        if (json.isNull("message_id")) null else json.optString("message_id").takeIf { it.isNotEmpty() },
    )

    private fun run(spec: JSONObject) {
        val name = spec.getString("name")
        val clock = Clock()
        val events = mutableListOf<Pair<String, Map<String, Any?>>>()
        val delivered = mutableListOf<List<Any?>>()
        val actions = AppActions({ event, properties -> events.add(event to properties) }, clock::later, clock::cancel)
        val subscriptions = mutableMapOf<String, AppActionSubscription>()
        val steps = spec.getJSONArray("steps")
        for (i in 0 until steps.length()) {
            val step = steps.getJSONObject(i)
            when {
                step.has("on") -> {
                    val id = step.getString("id")
                    val throws = step.optBoolean("throws", false)
                    val subscribed = if (step.isNull("on")) null else step.getString("on")
                    subscriptions[id] = actions.on(subscribed) { action ->
                        delivered.add(listOf(id, action.name, action.payload))
                        if (throws) throw IllegalStateException("the app's handler threw")
                    }
                }
                step.has("off") -> subscriptions[step.getString("off")]?.cancel()
                step.has("fire") -> {
                    val fire = step.getJSONObject("fire")
                    actions.fire(
                        AppAction(fire.getString("name"), BridgeDisplay.toMap(fire.getJSONObject("payload")), source(fire.getJSONObject("source"))),
                        step.optBoolean("record", true),
                    )
                }
                step.has("advance") -> clock.advance(step.getLong("advance"))
            }
        }
        assertEquals("$name: delivered", plain(spec.getJSONArray("delivered")), plain(delivered))
        assertEquals("$name: events", plain(spec.getJSONArray("events")), plain(events.map { listOf(it.first, it.second) }))
    }

    @Test
    fun aPushsOwnTapActionIsReadBeforeItsDeepLinkAndReachesTheAppAsAnAction() {
        val action = JSONObject().put("type", "app_action").put("name", "open.order").put("payload", JSONObject().put("order", "o-7"))
        val data = mapOf(
            TreebarsConstants.RICH_PUSH_ACTION_KEY to action.toString(),
            TreebarsConstants.RICH_PUSH_DEEP_LINK_KEY to "shop://orders",
            TreebarsConstants.DELIVERY_ID_KEY to "d-9",
            TreebarsConstants.CAMPAIGN_ID_KEY to "c-9",
        )
        assertEquals("open.order", TreebarsPush.actionOf(data, "tap", -1, 0)?.optString("name"))
        // A button's own action still wins over the push's.
        val button = JSONArray().put(JSONObject().put("id", "b").put("label", "B").put("action", JSONObject().put("type", "deep_link").put("url", "shop://b")))
        assertEquals("deep_link", TreebarsPush.actionOf(data + (TreebarsConstants.RICH_PUSH_BUTTONS_KEY to button.toString()), "button", 0, 0)?.optString("type"))
        // A name that is not one is nothing.
        assertEquals(false, TreebarsPush.fireFromPush(JSONObject().put("type", "app_action").put("name", "Open Order"), data))
        assertNull(TreebarsPush.tapAction(emptyMap()))
    }

    /** A JSON value as plain Kotlin, numbers as doubles, so a map and an object compare as JSON does. */
    private fun plain(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> value.keys().asSequence().associateWith { plain(value.opt(it)) }
        is JSONArray -> (0 until value.length()).map { plain(value.opt(it)) }
        is Map<*, *> -> value.entries.associate { (key, item) -> key.toString() to plain(item) }
        is List<*> -> value.map { plain(it) }
        is Number -> value.toDouble()
        else -> value
    }
}
