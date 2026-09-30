package com.treebars.sdk

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import java.util.UUID

/**
 * A message's dark variant: the sync ships `style_dark` beside `style` when it has one, and the store
 * hands the renderer the dark tokens while the device is in dark mode — the light ones otherwise, and always for a
 * message with no dark variant.
 */
@RunWith(RobolectricTestRunner::class)
class InAppDarkTokensTest {

    private val context: Context get() = ApplicationProvider.getApplicationContext()

    private fun tokens(surface: String) = JSONObject()
        .put("accent", "#5B4DF5").put("on_accent", "#FFFFFF").put("surface", surface).put("on_surface", "#111827")
        .put("on_surface_muted", "#6B7280").put("backdrop", "#0F172A99").put("radius", 8).put("font_family", "").put("button_shape", "rounded")

    private fun store(): InAppStore {
        val store = InAppStore(context, "treebars.inapp.${UUID.randomUUID()}")
        val message = { id: String, dark: Boolean ->
            JSONObject()
                .put("delivery_id", id).put("campaign_id", "cmp_1").put("created_at", "2026-01-01T00:00:00.000Z").put("expires_at", JSONObject.NULL)
                .put("content", JSONObject().put("title", "Hi").put("in_app", JSONObject().put("surface", "overlay").put("layout", "modal").put("trigger", JSONObject().put("kind", "immediate"))))
                .put("style", tokens("#FFFFFF"))
                .apply { if (dark) put("style_dark", tokens("#16161D")) }
        }
        store.accept(JSONObject().put("messages", JSONArray().put(message("both", true)).put(message("light", false))).put("server_time", Iso8601.now()))
        return store
    }

    @Test
    fun handsTheLightTokensInLightModeAndTheDarkOnesInDarkMode() {
        val light = store()
        assertEquals("#FFFFFF", light.tokensFor(light.list().first { it.deliveryId == "both" })?.surface)
        RuntimeEnvironment.setQualifiers("+night")
        val dark = store()
        assertEquals("#16161D", dark.tokensFor(dark.list().first { it.deliveryId == "both" })?.surface)
        // A message with no dark variant is drawn as it always was.
        assertEquals("#FFFFFF", dark.tokensFor(dark.list().first { it.deliveryId == "light" })?.surface)
    }
}
