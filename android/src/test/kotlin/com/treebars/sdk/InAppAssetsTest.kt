package com.treebars.sdk

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

/**
 * Asset prefetch, with files inlined into the document. The pure half answers every case of the shared
 * `bridge/in-app-assets.json` fixture as the reference implementation does; the cache is driven with a fake network, so
 * what it keeps, what a display gets and what it refuses are checked without one.
 *
 * Under Robolectric for the real `org.json` and `android.util.Base64`.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class InAppAssetsTest {
    @get:Rule val folder = TemporaryFolder()

    private val fixture = JSONObject(
        requireNotNull(javaClass.classLoader?.getResource("bridge/in-app-assets.json")) { "the shared fixture is missing from the test resources" }.readText(),
    )

    private fun JSONArray.strings(): List<String> = (0 until length()).map { getString(it) }
    private fun JSONArray.objects(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }
    private fun JSONObject.stringMap(): Map<String, String> = keys().asSequence().associateWith { getString(it) }
    private fun manifestOf(spec: JSONObject): InAppAssetManifest? = InAppAssetManifest.from(spec.optJSONObject("manifest"))

    @Test
    fun `the bounds are the reference's`() {
        val limits = fixture.getJSONObject("limits")
        assertEquals(limits.getLong("inline_file_max_bytes"), InAppAssetInline.FILE_MAX_BYTES)
        assertEquals(limits.getLong("inline_total_max_bytes"), InAppAssetInline.TOTAL_MAX_BYTES)
        assertEquals(limits.getLong("cache_max_bytes"), InAppAssetInline.CACHE_MAX_BYTES)
        assertEquals(limits.getInt("stylesheet_max_bytes"), InAppAssetInline.STYLESHEET_MAX_BYTES)
    }

    @Test
    fun `plans every case as core does`() {
        val cases = fixture.getJSONArray("plans").objects()
        assertTrue(cases.size >= 5)
        for (spec in cases) {
            val plan = InAppAssetInline.plan(manifestOf(spec))
            val name = spec.getString("name")
            assertEquals(name, spec.getJSONArray("inline").strings(), plan.inline.map { it.sha256 })
            assertEquals(name, spec.getJSONArray("left").strings(), plan.left.map { it.sha256 })
            assertEquals(name, spec.getJSONArray("stylesheets").strings(), plan.stylesheets)
            assertEquals(name, spec.getJSONArray("missing").strings(), plan.missing)
        }
    }

    @Test
    fun `decides every outcome as core does`() {
        for (spec in fixture.getJSONArray("outcomes").objects()) {
            val have = spec.getJSONArray("have").strings()
            val sheets = spec.getJSONArray("have_stylesheets").strings()
            val outcome = InAppAssetInline.outcome(InAppAssetInline.plan(manifestOf(spec)), { it in have }, { it in sheets })
            assertEquals(spec.getString("name"), spec.getString("outcome"), outcome)
        }
    }

    @Test
    fun `writes every document as core does`() {
        val cases = fixture.getJSONArray("documents").objects()
        assertTrue(cases.size >= 6)
        for (spec in cases) {
            val out = InAppAssetInline.inline(spec.getString("html"), spec.getJSONObject("files").stringMap(), spec.getJSONObject("stylesheets").stringMap())
            assertEquals(spec.getString("name"), spec.getString("expected"), out)
        }
    }

    @Test
    fun `keeps only the stylesheets core keeps`() {
        for (spec in fixture.getJSONArray("stylesheet_checks").objects()) {
            val text = if (spec.has("text")) spec.getString("text") else "a".repeat(spec.getInt("text_length"))
            assertEquals(spec.getString("name"), spec.getBoolean("ok"), InAppAssetInline.isInlinableStylesheet(text))
        }
    }

    // The cache, with a network that answers from a map and counts what it was asked.

    private val project = "11111111-1111-4111-8111-111111111111"
    private val png = "png-bytes".toByteArray()
    private val pngSha = InAppAssetCache.sha256Hex(png)
    private val pngUrl = "https://api.treebars.test/assets/$project/$pngSha.png"
    private val sheetUrl = "https://api.treebars.test/assets/$project/font.css?family=Brand&face=$pngSha.png:400:normal"

    private class FakeNetwork(val answers: MutableMap<String, ByteArray>) : InAppAssetFetch {
        val asked = mutableListOf<String>()
        override fun get(url: String, maxBytes: Long): ByteArray? {
            asked += url
            return answers[url]?.takeIf { it.size <= maxBytes }
        }
    }

    private fun manifest(vararg files: InAppAssetFile, stylesheets: List<String> = emptyList(), missing: List<String> = emptyList()) =
        InAppAssetManifest(files.toList(), stylesheets, missing)

    private fun cache(network: FakeNetwork, max: Long = InAppAssetInline.CACHE_MAX_BYTES) = InAppAssetCache(folder.newFolder(), network, max)

    @Test
    fun `a markup body is drawn with its files inlined, from the prefetch, with nothing asked of the network at the draw`() {
        val network = FakeNetwork(mutableMapOf(pngUrl to png))
        val cache = cache(network)
        val held = manifest(InAppAssetFile(pngUrl, pngSha, "image/png", png.size.toLong()))
        cache.prefetch(listOf(held to true))
        assertEquals(listOf(pngUrl), network.asked)

        network.answers.clear()
        val document = cache.prepare(held, "<img src=\"$pngUrl\">")
        assertEquals("<img src=\"data:image/png;base64,${android.util.Base64.encodeToString(png, android.util.Base64.NO_WRAP)}\">", document)
        assertEquals("offline at the draw, and nothing asked", listOf(pngUrl), network.asked)
    }

    @Test
    fun `a file the prefetch has not landed is fetched at the draw`() {
        val network = FakeNetwork(mutableMapOf(pngUrl to png))
        val document = cache(network).prepare(manifest(InAppAssetFile(pngUrl, pngSha, "image/png", png.size.toLong())), "<img src=\"$pngUrl\">")
        assertTrue(document!!.contains("data:image/png;base64,"))
    }

    @Test
    fun `a display waits for what it is missing within its deadline, together, and then fails rather than hold the screen`() {
        val asked = java.util.concurrent.atomic.AtomicInteger()
        // A network that never answers, as a captive portal does.
        val hanging = InAppAssetFetch { _, _ -> asked.incrementAndGet(); Thread.sleep(10_000); null }
        val cache = InAppAssetCache(folder.newFolder(), hanging, drawWaitMs = 300)
        val files = (0 until 6).map { i ->
            val body = "file-$i".toByteArray()
            InAppAssetFile("https://api.treebars.test/assets/$project/${InAppAssetCache.sha256Hex(body)}.png", InAppAssetCache.sha256Hex(body), "image/png", body.size.toLong())
        }
        val started = System.currentTimeMillis()
        assertNull(cache.prepare(InAppAssetManifest(files, emptyList(), emptyList()), "<p>x</p>"))
        val waited = System.currentTimeMillis() - started
        assertTrue("waited $waited ms", waited < 2_000)
        assertTrue("asked together, not one after another: $asked", asked.get() >= 4)
    }

    @Test
    fun `a file that is not its hash is never kept, and a display needing it is not drawn`() {
        val network = FakeNetwork(mutableMapOf(pngUrl to "a proxy's error page".toByteArray()))
        val cache = cache(network)
        val held = manifest(InAppAssetFile(pngUrl, pngSha, "image/png", png.size.toLong()))
        cache.prefetch(listOf(held to true))
        assertFalse(cache.has(pngSha))
        assertNull(cache.prepare(held, "<img src=\"$pngUrl\">"))
    }

    @Test
    fun `a store file that is gone fails the display, and one that cannot be had does too`() {
        val cache = cache(FakeNetwork(mutableMapOf()))
        assertNull(cache.prepare(manifest(missing = listOf(pngUrl)), "<p>hi</p>"))
        assertNull(cache.prepare(manifest(InAppAssetFile(pngUrl, pngSha, "image/png", png.size.toLong())), "<img src=\"$pngUrl\">"))
        assertEquals("nothing to load is drawn as written", "<p>hi</p>", cache.prepare(null, "<p>hi</p>"))
    }

    @Test
    fun `a file past the inline bound keeps its address and is never fetched for a markup body`() {
        val network = FakeNetwork(mutableMapOf())
        val big = InAppAssetFile(pngUrl, pngSha, "image/jpeg", InAppAssetInline.FILE_MAX_BYTES + 1)
        val cache = cache(network)
        cache.prefetch(listOf(manifest(big) to true))
        assertEquals(emptyList<String>(), network.asked)
        assertEquals("<img src=\"$pngUrl\">", cache.prepare(manifest(big), "<img src=\"$pngUrl\">"))
    }

    @Test
    fun `a font stylesheet is kept only when it can be written into a document`() {
        val network = FakeNetwork(mutableMapOf(sheetUrl to "@font-face{src:url($pngUrl)}".toByteArray(), pngUrl to png))
        val cache = cache(network)
        val held = manifest(InAppAssetFile(pngUrl, pngSha, "font/woff2", png.size.toLong()), stylesheets = listOf(sheetUrl))
        val document = cache.prepare(held, "<link rel=\"stylesheet\" href=\"${sheetUrl.replace("&", "&amp;")}\">")!!
        assertTrue(document, document.startsWith("<style>@font-face{src:url(data:font/woff2;base64,"))

        val hostile = FakeNetwork(mutableMapOf(sheetUrl to "</style><script>1</script>".toByteArray(), pngUrl to png))
        assertNull(cache(hostile).prepare(held, "<link rel=\"stylesheet\" href=\"$sheetUrl\">"))
    }

    @Test
    fun `a standard body's picture is read from the cache when the address is a store file it holds`() {
        val network = FakeNetwork(mutableMapOf(pngUrl to png))
        val cache = cache(network)
        cache.prefetch(listOf(manifest(InAppAssetFile(pngUrl, pngSha, "image/png", png.size.toLong())) to false))
        assertTrue(cache.pictureBytes(pngUrl)!!.contentEquals(png))
        assertNull("another address is not this file", cache.pictureBytes("$pngUrl?v=2"))
        assertNull(cache.pictureBytes("https://cdn.example.com/$pngSha.png"))
    }

    @Test
    fun `the files no held message names go, and past the bound the longest unused go`() {
        val dir = folder.newFolder()
        val cache = InAppAssetCache(dir, FakeNetwork(mutableMapOf()), maxBytes = 10)
        val old = File(dir, "a".repeat(64)).apply { writeBytes(ByteArray(6)); setLastModified(1_000) }
        val used = File(dir, "b".repeat(64)).apply { writeBytes(ByteArray(6)); setLastModified(2_000) }
        val gone = File(dir, "c".repeat(64)).apply { writeBytes(ByteArray(1)); setLastModified(1_000) }
        cache.evict(setOf(old.name, used.name), now = 1_000_000)
        assertFalse("named by no held message", gone.exists())
        assertFalse("the longest unused, past the bound", old.exists())
        assertTrue(used.exists())
    }

    @Test
    fun `a manifest is read as the sync hands it over, and nothing unreadable in it throws`() {
        val json = JSONObject()
            .put("files", JSONArray().put(JSONObject().put("url", pngUrl).put("sha256", pngSha).put("type", "image/png").put("bytes", 9)).put(JSONObject().put("url", "x").put("sha256", "nope")))
            .put("stylesheets", JSONArray().put(sheetUrl))
            .put("missing", JSONArray().put(pngUrl))
        val read = InAppAssetManifest.from(json)!!
        assertEquals(listOf(InAppAssetFile(pngUrl, pngSha, "image/png", 9)), read.files)
        assertEquals(listOf(sheetUrl), read.stylesheets)
        assertEquals(listOf(pngUrl), read.missing)
        assertNull(InAppAssetManifest.from(null))
    }
}
