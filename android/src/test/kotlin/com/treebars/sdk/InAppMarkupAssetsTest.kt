package com.treebars.sdk

import android.app.Activity
import android.content.Context
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
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

/**
 * A markup body drawn with its prefetched files inlined, through the real SDK, its HTML host and a
 * Robolectric WebView — so what is checked is the document the WebView was actually handed. The network is a fake the
 * test puts in the SDK's asset cache: the sync's prefetch and the display's own fetch both go through it.
 */
@RunWith(RobolectricTestRunner::class)
class InAppMarkupAssetsTest {
    @get:Rule val folder = TemporaryFolder()

    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val png = "png-bytes".toByteArray()
    private val sha = InAppAssetCache.sha256Hex(png)
    private val url = "https://api.treebars.test/assets/11111111-1111-4111-8111-111111111111/$sha.png"

    private fun message(assets: JSONObject) = JSONObject()
        .put("delivery_id", "del_markup")
        .put("campaign_id", "cmp_markup")
        .put("created_at", "2026-01-01T00:00:00.000Z")
        .put("expires_at", JSONObject.NULL)
        .put(
            "content",
            JSONObject().put(
                "in_app",
                JSONObject().put("surface", "overlay").put("layout", "modal").put("body_mode", "html")
                    .put("html", "<img src=\"$url\" alt=\"sale\">")
                    .put("trigger", JSONObject().put("kind", "event").put("event_name", "add_to_cart")),
            ),
        )
        .put("assets", assets)

    private val screens = mutableListOf<ActivityController<Activity>>()

    private fun start(message: JSONObject, network: Map<String, ByteArray>) {
        context.getSharedPreferences(Treebars.PREFS_NAME, Context.MODE_PRIVATE).edit().clear()
            .putString("in_app_queue", JSONArray().put(message).toString())
            .commit()
        File(context.filesDir, EventQueue.FILE_NAME).delete()
        Treebars.initialize(context, "pk_test_assets", "http://localhost:1", autoTrackSessions = false, inAppPollIntervalMs = 0)
        val fake = InAppAssetFetch { address, max -> network[address]?.takeIf { it.size <= max } }
        Treebars::class.java.getDeclaredField("assetCache").apply { isAccessible = true }.set(Treebars, InAppAssetCache(folder.newFolder(), fake))
        screens += Robolectric.buildActivity(Activity::class.java).setup()
        settle()
    }

    private fun settle(done: () -> Boolean = { false }) {
        val until = System.currentTimeMillis() + 2_000
        while (System.currentTimeMillis() < until) {
            shadowOf(Looper.getMainLooper()).idle()
            if (done()) return
            Thread.sleep(25)
        }
    }

    private fun queued(name: String): List<JSONObject> {
        val file = File(context.filesDir, EventQueue.FILE_NAME)
        if (!file.exists()) return emptyList()
        val all = JSONArray(file.readText())
        return (0 until all.length()).map { all.getJSONObject(it) }.filter { it.optString("event_name") == name }
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
    fun `the WebView is handed the document with the store file inlined, not its address`() {
        val manifest = JSONObject().put("files", JSONArray().put(JSONObject().put("url", url).put("sha256", sha).put("type", "image/png").put("bytes", png.size)))
        start(message(manifest), mapOf(url to png))
        Treebars.track("add_to_cart")
        settle { Treebars.htmlInAppHost?.webView != null }

        val web = requireNotNull(Treebars.htmlInAppHost?.webView) { "nothing was drawn" }
        val document = requireNotNull(shadowOf(web).lastLoadDataWithBaseURL?.data)
        assertTrue(document, document.contains("<img src=\"data:image/png;base64,${android.util.Base64.encodeToString(png, android.util.Base64.NO_WRAP)}\" alt=\"sale\">"))
        assertTrue("the address itself is gone from the document", !document.contains(url))
    }

    @Test
    fun `a store file that is gone is a failed display with its reason, and nothing is drawn`() {
        start(message(JSONObject().put("files", JSONArray()).put("missing", JSONArray().put(url))), emptyMap())
        Treebars.track("add_to_cart")
        settle { queued("in_app_failed").isNotEmpty() }

        assertNull(Treebars.htmlInAppHost)
        val failed = queued("in_app_failed").single().getJSONObject("properties")
        assertEquals("asset_download", failed.getString("reason"))
        assertEquals("del_markup", failed.getString("treebars_delivery_id"))
        assertTrue(queued("in_app_displayed").isEmpty())
    }

    @Test
    fun `a file that cannot be had is the same, never a broken image`() {
        val manifest = JSONObject().put("files", JSONArray().put(JSONObject().put("url", url).put("sha256", sha).put("type", "image/png").put("bytes", png.size)))
        start(message(manifest), emptyMap())
        Treebars.track("add_to_cart")
        settle { queued("in_app_failed").isNotEmpty() }

        assertNull(Treebars.htmlInAppHost)
        assertNotNull(queued("in_app_failed").singleOrNull { it.getJSONObject("properties").getString("reason") == "asset_download" })
    }
}
