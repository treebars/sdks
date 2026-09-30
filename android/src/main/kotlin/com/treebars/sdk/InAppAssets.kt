package com.treebars.sdk

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import java.security.MessageDigest
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/*
 * Asset prefetch.
 *
 * Every in-app message a sync hands over carries a manifest beside its content: the files from the project's asset
 * store it loads, by SHA-256, type and size; the store's font stylesheets; and the store files it names that are gone.
 * This SDK fetches those files after the sync, keeps them on disk by their hash — checked, so a file is only ever the
 * bytes its address names — and draws from them:
 *
 * - **A markup body** is drawn with every file it inlines swapped for a `data:` URI and every store stylesheet written
 *   into the document ([InAppAssetInline]), so it draws offline. A download this SDK makes is invisible to a WebView,
 *   which reads only its own cache; `data:` is what the frame policy already allows for images, fonts and media, so the
 *   policy needs nothing wider. A store file the manifest says is gone, or one it would inline that could not be had, is a
 *   failed display (`asset_download`), never a broken image. A file past the inline bounds keeps its address and the
 *   WebView loads it, online only.
 * - **A standard body's picture** is read from here when it is a store file this device holds ([InAppPictures]), and
 *   fetched as it is drawn otherwise, into the placeholder the render contract draws — which stays if it fails.
 *
 * The same rules run in the web and iOS SDKs; `in-app-assets.json` in the test resources holds this file's pure half to
 * the shared cases (`InAppAssetsTest`).
 */

internal data class InAppAssetFile(val url: String, val sha256: String, val type: String, val bytes: Long)

/** A message's `assets`, as the sync put it beside `content`. Anything unreadable in it is left out, never thrown. */
internal data class InAppAssetManifest(val files: List<InAppAssetFile>, val stylesheets: List<String>, val missing: List<String>) {
    companion object {
        private val SHA = Regex("^[0-9a-f]{64}$")

        fun from(json: JSONObject?): InAppAssetManifest? {
            json ?: return null
            val files = json.optJSONArray("files").objects().mapNotNull { file ->
                val sha = file.optString("sha256")
                val url = file.optString("url")
                if (!SHA.matches(sha) || url.isEmpty()) null
                else InAppAssetFile(url, sha, file.optString("type"), file.optLong("bytes", Long.MAX_VALUE))
            }
            return InAppAssetManifest(files, json.optJSONArray("stylesheets").strings(), json.optJSONArray("missing").strings())
        }

        private fun JSONArray?.objects(): List<JSONObject> = if (this == null) emptyList() else (0 until length()).mapNotNull { optJSONObject(it) }
        private fun JSONArray?.strings(): List<String> = if (this == null) emptyList() else (0 until length()).mapNotNull { optString(it).takeIf { s -> s.isNotEmpty() } }
    }
}

internal data class InAppAssetPlan(
    val inline: List<InAppAssetFile>,
    val left: List<InAppAssetFile>,
    val stylesheets: List<String>,
    val missing: List<String>,
)

/** The pure half: the same answers as the web and iOS SDKs, case for case. */
internal object InAppAssetInline {
    const val FILE_MAX_BYTES = 1024L * 1024
    const val TOTAL_MAX_BYTES = 4L * 1024 * 1024
    const val CACHE_MAX_BYTES = 32L * 1024 * 1024
    const val STYLESHEET_MAX_BYTES = 64 * 1024

    private val STORE_FILE_URL = Regex(
        "https?://[^\\s\"'()<>/]+/assets/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/([0-9a-f]{64})\\.(?:png|jpg|gif|webp|ttf|otf|woff|woff2)(?![A-Za-z0-9?#/._~%-])",
    )
    private val LINK_TAG = Regex("<link\\b[^>]*>", RegexOption.IGNORE_CASE)
    private val HREF = Regex("\\bhref\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", RegexOption.IGNORE_CASE)
    private val REL_STYLESHEET = Regex("\\brel\\s*=\\s*[\"']?[^\"'>]*\\bstylesheet\\b", RegexOption.IGNORE_CASE)
    private val IMPORT = Regex(
        "@import\\s+(?:url\\(\\s*(?:\"([^\"]*)\"|'([^']*)'|([^)\\s]*))\\s*\\)|\"([^\"]*)\"|'([^']*)')\\s*;",
        RegexOption.IGNORE_CASE,
    )

    /** Which files a display inlines: manifest order, each within the file bound, until the display's bound. */
    fun plan(manifest: InAppAssetManifest?): InAppAssetPlan {
        val inline = mutableListOf<InAppAssetFile>()
        val left = mutableListOf<InAppAssetFile>()
        var total = 0L
        for (file in manifest?.files.orEmpty()) {
            if (file.bytes <= FILE_MAX_BYTES && total + file.bytes <= TOTAL_MAX_BYTES) {
                inline += file
                total += file.bytes
            } else {
                left += file
            }
        }
        return InAppAssetPlan(inline, left, manifest?.stylesheets.orEmpty(), manifest?.missing.orEmpty())
    }

    /** `ready`, or `asset_download` when a store file is gone or one the display inlines is not on the device. */
    fun outcome(plan: InAppAssetPlan, has: (String) -> Boolean, hasStylesheet: (String) -> Boolean): String = when {
        plan.missing.isNotEmpty() -> "asset_download"
        plan.inline.any { !has(it.sha256) } -> "asset_download"
        plan.stylesheets.any { !hasStylesheet(it) } -> "asset_download"
        else -> "ready"
    }

    /** Store stylesheets written in, then every inlined file's address — in the markup and the stylesheets — as `data:`. */
    fun inline(html: String, files: Map<String, String>, stylesheets: Map<String, String>): String {
        var out = LINK_TAG.replace(html) { tag ->
            if (!REL_STYLESHEET.containsMatchIn(tag.value)) return@replace tag.value
            val href = HREF.find(tag.value) ?: return@replace tag.value
            val url = attributeValue(firstGroup(href))
            stylesheets[url]?.let { "<style>$it</style>" } ?: tag.value
        }
        out = IMPORT.replace(out) { statement ->
            val url = attributeValue(firstGroup(statement))
            stylesheets[url] ?: statement.value
        }
        return STORE_FILE_URL.replace(out) { address -> files[address.groupValues[1]] ?: address.value }
    }

    /** The first alternative that took part in the match: JavaScript's `undefined` is Kotlin's null group, not "". */
    private fun firstGroup(match: MatchResult): String = match.groups.drop(1).firstOrNull { it != null }?.value ?: ""

    fun isInlinableStylesheet(text: String): Boolean = text.length <= STYLESHEET_MAX_BYTES && !text.contains('<')

    fun dataUri(type: String, bytes: ByteArray): String = "data:$type;base64," + android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)

    /** A store file's hash, when the address names one — what a picture is looked up by. */
    fun storeHash(url: String): String? = STORE_FILE_URL.find(url)?.takeIf { it.range.first == 0 && it.range.last == url.length - 1 }?.groupValues?.get(1)

    private fun attributeValue(raw: String): String =
        raw.replace("&quot;", "\"").replace(Regex("&#0?39;|&apos;"), "'").replace("&amp;", "&")
}

/** Fetches `url`, at most `maxBytes`; null for anything else. Swapped in tests. */
internal fun interface InAppAssetFetch {
    fun get(url: String, maxBytes: Long): ByteArray?
}

/**
 * The files on disk, by hash, and the stylesheets by their address's hash. Bounded ([InAppAssetInline.CACHE_MAX_BYTES]):
 * after each prefetch the files no held message names go first, then the longest unused.
 */
internal class InAppAssetCache(
    private val dir: File,
    private val fetch: InAppAssetFetch = HttpAssetFetch,
    private val maxBytes: Long = InAppAssetInline.CACHE_MAX_BYTES,
    /** How long a display waits, in all, for what the prefetch has not landed ([DRAW_WAIT_MS]). */
    private val drawWaitMs: Long = DRAW_WAIT_MS,
) {
    private fun fileFor(sha: String) = File(dir, sha)
    private fun sheetFor(url: String) = File(dir, "css-" + sha256Hex(url.toByteArray(Charsets.UTF_8)))

    fun has(sha: String): Boolean = fileFor(sha).isFile
    fun hasStylesheet(url: String): Boolean = sheetFor(url).isFile

    fun bytes(sha: String): ByteArray? = runCatching { fileFor(sha).takeIf { it.isFile }?.readBytes() }.getOrNull()
    fun stylesheet(url: String): String? = runCatching { sheetFor(url).takeIf { it.isFile }?.readText() }.getOrNull()

    /** One file, kept only when its bytes are the hash its address names — a proxy's error page is never an image. */
    fun fetch(file: InAppAssetFile, limit: Long): Boolean {
        if (has(file.sha256)) return true
        if (file.bytes > limit) return false
        val body = runCatching { fetch.get(file.url, limit) }.getOrNull() ?: return false
        if (sha256Hex(body) != file.sha256) {
            TreebarsLogger.log("in-app: ${file.url} did not match its hash; not kept")
            return false
        }
        return write(fileFor(file.sha256), body)
    }

    /** A store stylesheet, kept only when it may be written into a document ([InAppAssetInline.isInlinableStylesheet]). */
    fun fetchStylesheet(url: String): Boolean {
        if (hasStylesheet(url)) return true
        val body = runCatching { fetch.get(url, InAppAssetInline.STYLESHEET_MAX_BYTES.toLong()) }.getOrNull() ?: return false
        val text = body.toString(Charsets.UTF_8)
        if (!InAppAssetInline.isInlinableStylesheet(text)) return false
        return write(sheetFor(url), body)
    }

    /**
     * At sync, for every message the device holds: a markup body's inlined files and stylesheets, a standard body's
     * pictures. Then the bound. Blocking; the caller runs it off the main thread.
     */
    fun prefetch(messages: List<Pair<InAppAssetManifest?, Boolean>>) {
        val keep = mutableSetOf<String>()
        for ((manifest, markup) in messages) {
            manifest ?: continue
            if (markup) {
                val plan = InAppAssetInline.plan(manifest)
                for (file in plan.inline) if (fetch(file, InAppAssetInline.FILE_MAX_BYTES)) keep += file.sha256
                for (url in plan.stylesheets) if (fetchStylesheet(url)) keep += sheetFor(url).name
            } else {
                for (file in manifest.files) {
                    if (!file.type.startsWith("image/")) continue
                    if (fetch(file, PICTURE_MAX_BYTES)) keep += file.sha256
                }
            }
        }
        evict(keep)
    }

    /**
     * A markup body's document, its files inlined — or null when the display must not go ahead (`asset_download`). What
     * the prefetch has not landed yet is asked for here, once: a message triggered by the session that synced it is
     * usually drawn before the prefetch it started has finished.
     */
    fun prepare(manifest: InAppAssetManifest?, html: String): String? {
        val plan = InAppAssetInline.plan(manifest)
        if (plan.inline.isEmpty() && plan.stylesheets.isEmpty()) return if (plan.missing.isEmpty()) html else null
        if (plan.missing.isNotEmpty()) return null
        fetchNow(plan)
        if (InAppAssetInline.outcome(plan, ::has, ::hasStylesheet) != "ready") return null
        val files = HashMap<String, String>()
        for (file in plan.inline) {
            val body = bytes(file.sha256) ?: return null
            files[file.sha256] = InAppAssetInline.dataUri(file.type.ifEmpty { "application/octet-stream" }, body)
            touch(fileFor(file.sha256))
        }
        val sheets = HashMap<String, String>()
        for (url in plan.stylesheets) sheets[url] = stylesheet(url) ?: return null
        return InAppAssetInline.inline(html, files, sheets)
    }

    /**
     * What the display is still missing, together and within [drawWaitMs] in all. The screen is claimed while this runs,
     * so every other message waits on it: one after another, forty files each allowed eight seconds on a captive portal
     * would hold the screen for minutes and then fail anyway. What has not landed by the deadline is `asset_download`;
     * a fetch still running carries on and lands in the cache for the next display.
     */
    private fun fetchNow(plan: InAppAssetPlan) {
        val tasks = plan.inline.filter { !has(it.sha256) }.map { file -> Callable { fetch(file, InAppAssetInline.FILE_MAX_BYTES) } } +
            plan.stylesheets.filter { !hasStylesheet(it) }.map { url -> Callable { fetchStylesheet(url) } }
        if (tasks.isEmpty()) return
        runCatching { DRAW_FETCHES.invokeAll(tasks, drawWaitMs, TimeUnit.MILLISECONDS) }
    }

    /** A picture's bytes, when its address is a store file this device holds. */
    fun pictureBytes(url: String): ByteArray? {
        val sha = InAppAssetInline.storeHash(url) ?: return null
        return bytes(sha)?.also { touch(fileFor(sha)) }
    }

    /** Everything, for `wipeLocalData`: what a forgotten device kept is not kept. */
    fun clear() {
        runCatching { dir.listFiles()?.forEach { it.delete() } }
    }

    @Synchronized
    fun evict(keep: Set<String>, now: Long = System.currentTimeMillis()) {
        val held = dir.listFiles()?.filter { it.isFile && !it.name.startsWith(".") } ?: return
        // Not one written in the last minute: a display may have fetched it for a message a later sync brought, which
        // the list this prefetch started from did not have yet.
        for (file in held) if (file.name !in keep && now - file.lastModified() > RECENT_MS) file.delete()
        val left = held.filter { it.exists() }.sortedBy { it.lastModified() }.toMutableList()
        var total = left.sumOf { it.length() }
        while (total > maxBytes && left.isNotEmpty()) {
            val oldest = left.removeAt(0)
            total -= oldest.length()
            oldest.delete()
        }
    }

    private fun write(target: File, body: ByteArray): Boolean = runCatching {
        dir.mkdirs()
        // Beside it and then renamed, so a reader never meets half a file — and a prefetch and a display fetching the
        // same file at once each write a whole one.
        val part = File(dir, ".${target.name}.${Thread.currentThread().id}")
        part.writeBytes(body)
        if (!part.renameTo(target)) {
            part.delete()
            target.isFile
        } else {
            true
        }
    }.getOrDefault(false)

    private fun touch(file: File) {
        runCatching { file.setLastModified(System.currentTimeMillis()) }
    }

    companion object {
        /**
         * A standard body's picture is drawn natively, sampled down, so it is kept up to the store's own upload bound —
         * no display inlines it, and the memory is the decoder's, not a document's.
         */
        const val PICTURE_MAX_BYTES = 5L * 1024 * 1024
        private const val RECENT_MS = 60_000L

        /** Five seconds for everything a display is still missing: a slow network fails the message, never the screen. */
        const val DRAW_WAIT_MS = 5_000L

        /** Four at a time, which is what one host is sensibly asked for at once; daemon threads, so they hold nothing up. */
        private val DRAW_FETCHES = Executors.newFixedThreadPool(4) { run -> Thread(run, "treebars-in-app-assets").apply { isDaemon = true } }

        fun sha256Hex(bytes: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    }
}

/** A plain GET, `http` or `https`, with the picture loader's patience. */
internal object HttpAssetFetch : InAppAssetFetch {
    private const val TIMEOUT_MS = 8_000

    override fun get(url: String, maxBytes: Long): ByteArray? {
        val scheme = runCatching { URI(url).scheme?.lowercase() }.getOrNull()
        if (scheme != "https" && scheme != "http") return null
        val connection = URI(url).toURL().openConnection() as HttpURLConnection
        connection.connectTimeout = TIMEOUT_MS
        connection.readTimeout = TIMEOUT_MS
        return try {
            if (connection.responseCode !in 200..299) null else connection.inputStream.use { capped(it, maxBytes) }
        } finally {
            connection.disconnect()
        }
    }

    private fun capped(stream: InputStream, maxBytes: Long): ByteArray? {
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(16 * 1024)
        while (true) {
            val read = stream.read(buffer)
            if (read < 0) return out.toByteArray()
            out.write(buffer, 0, read)
            if (out.size() > maxBytes) return null
        }
    }
}
