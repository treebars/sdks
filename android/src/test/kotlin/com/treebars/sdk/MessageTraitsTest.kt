package com.treebars.sdk

import android.content.Context
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import java.io.File

/**
 * Traits a message sets before anybody signs in go on the anonymous person as `traits_set`, which the server carries
 * into the account at sign-in — so an onboarding survey keeps its answers from exactly the people it is shown to. A
 * signed-in person's still go through `identify`. Driven through the real SDK and its queue file.
 */
@RunWith(RobolectricTestRunner::class)
class MessageTraitsTest {

    private val context: Context get() = ApplicationProvider.getApplicationContext()

    private val survey = JSONObject()
        .put("delivery_id", "del_survey")
        .put("campaign_id", "cmp_survey")
        .put("created_at", "2026-01-01T00:00:00.000Z")
        .put("expires_at", JSONObject.NULL)
        .put(
            "content",
            JSONObject().put("title", "Tell us").put(
                "in_app",
                JSONObject().put("surface", "overlay").put("layout", "modal")
                    .put("trigger", JSONObject().put("kind", "event").put("event_name", "never_fired"))
                    .put("declared", JSONObject().put("events", JSONArray()).put("traits", JSONArray().put("goal")))
                    .put(
                        "form",
                        JSONObject().put(
                            "fields",
                            JSONArray()
                                .put(JSONObject().put("id", "goal").put("kind", "text").put("label", "Your goal").put("trait", "goal"))
                                .put(JSONObject().put("id", "size").put("kind", "text").put("label", "Size").put("trait", "size")),
                        ),
                    ),
            ),
        )

    private fun start() {
        context.getSharedPreferences(Treebars.PREFS_NAME, Context.MODE_PRIVATE).edit().clear()
            .putString("in_app_queue", JSONArray().put(survey).toString())
            .commit()
        File(context.filesDir, EventQueue.FILE_NAME).delete()
        Treebars.initialize(context, "pk_test_traits", "http://localhost:1", autoTrackSessions = false, inAppPollIntervalMs = 0)
        // `initialize` finishes on its own coroutine; an event recorded before it has is not what these are about.
        settle { false }
    }

    private fun queued(name: String): List<JSONObject> {
        val file = File(context.filesDir, EventQueue.FILE_NAME)
        if (!file.exists()) return emptyList()
        val all = JSONArray(file.readText())
        return (0 until all.length()).map { all.getJSONObject(it) }.filter { it.optString("event_name") == name }
    }

    private fun settle(done: () -> Boolean) {
        val until = System.currentTimeMillis() + 2_000
        while (System.currentTimeMillis() < until) {
            shadowOf(Looper.getMainLooper()).idle()
            if (done()) return
            Thread.sleep(25)
        }
    }

    @After
    fun forgetInitialize() {
        Treebars.reset()
        Treebars::class.java.getDeclaredField("writeKey").apply { isAccessible = true }.set(Treebars, null)
    }

    @Test
    fun `a message's traits go on the anonymous person, with their names beside them`() {
        start()
        Treebars.setMessageTraits(mapOf("streak" to 3, "first_name" to "Ada"))
        settle { queued("traits_set").isNotEmpty() }

        val properties = queued("traits_set").single().getJSONObject("properties")
        assertEquals(JSONArray(listOf("first_name", "streak")).toString(), properties.getJSONArray("trait_keys").toString())
        assertEquals(3, properties.getJSONObject("traits").getInt("streak"))
        assertEquals("Ada", properties.getJSONObject("traits").getString("first_name"))
    }

    @Test
    fun `a form answered before sign-in keeps only its declared trait, on the anonymous person`() {
        start()
        Treebars.submitInAppForm("del_survey", mapOf("goal" to "run a 10k", "size" to "M"))
        settle { queued("traits_set").isNotEmpty() && queued("in_app_form_submitted").isNotEmpty() }

        val traits = queued("traits_set").single().getJSONObject("properties").getJSONObject("traits")
        assertEquals("run a 10k", traits.getString("goal"))
        assertTrue("an undeclared trait is still refused", !traits.has("size"))
    }

    @Test
    fun `a signed-in person's traits still go through identify, and nothing rides the event queue`() {
        start()
        Treebars.identify("user_42")
        Treebars.setMessageTraits(mapOf("streak" to 3))
        settle { queued("user_identified").isNotEmpty() }
        assertTrue(queued("traits_set").isEmpty())
    }
}
