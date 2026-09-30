package com.treebars.sdk

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.util.UUID

/**
 * An inbox card's button and its "after seen" days, as an app reads them off the card: the server
 * decides when a seen card is gone; the app draws the button.
 */
@RunWith(RobolectricTestRunner::class)
class InAppCardTest {

    private val context: Context get() = ApplicationProvider.getApplicationContext()

    @Test
    fun readsTheCardsButtonAndItsDaysAfterSeen() {
        val store = InAppStore(context, "treebars.inapp.${UUID.randomUUID()}")
        val card = JSONObject()
            .put("template", "basic")
            .put("cta", JSONObject().put("label", "Shop the sale").put("action", JSONObject().put("type", "deep_link").put("value", "app://sale")))
            .put("expires_after_seen_days", 7)
        val message = { id: String, withCard: JSONObject? ->
            JSONObject()
                .put("delivery_id", id).put("campaign_id", "cmp_1").put("created_at", "2026-01-01T00:00:00.000Z").put("expires_at", JSONObject.NULL)
                .put("content", JSONObject().put("title", "Hi").put("in_app", JSONObject().put("surface", "inbox").put("layout", "modal").put("trigger", JSONObject().put("kind", "immediate")).apply { withCard?.let { put("card", it) } }))
        }
        store.accept(JSONObject().put("messages", JSONArray().put(message("with", card)).put(message("plain", JSONObject().put("template", "basic")))).put("server_time", Iso8601.now()))

        val read = store.list().first { it.deliveryId == "with" }.content?.card
        assertEquals("Shop the sale", read?.ctaLabel)
        assertEquals("deep_link", read?.ctaType)
        assertEquals("app://sale", read?.ctaValue)
        assertEquals(7, read?.expiresAfterSeenDays)

        val plain = store.list().first { it.deliveryId == "plain" }.content?.card
        assertNull(plain?.ctaLabel)
        assertNull(plain?.expiresAfterSeenDays)
    }
}
