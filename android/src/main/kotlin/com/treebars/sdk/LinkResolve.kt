package com.treebars.sdk

import com.treebars.sdk.generated.TreebarsConstants
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL

/**
 * What a link host said about a link that opened the app: this tap's click id, and where the link
 * wanted the person to land.
 */
internal data class ResolvedLink(val clickId: String, val deepLinkPath: String?)

/**
 * A Universal Link or App Link opened the app, holding only the link's own address.
 *
 * The operating system hands the link to the app before the tap reaches the link host, so the app
 * has no click id and no deep-link path yet. Asking the address itself — with the
 * `X-Treebars-Resolve` header — gets both back. Without it the app would open on its home screen,
 * with no click to attribute the open to.
 */
internal object LinkResolve {
    /**
     * `/<slug>`: the one shape a link host serves a tap on. `/p/<slug>` is not asked about — both
     * association files exclude it, so an app is never opened with one.
     */
    private val SLUG_PATH = Regex("^/[A-Za-z0-9_-]{1,64}/?$")

    /**
     * The address worth asking about, or null.
     *
     * An app is opened by its own website's addresses too, and a question sent to every one of them
     * would be a request to somebody's web server per tap. Only https with a single path segment is
     * asked — what a link looks like — and the host decides the rest: an address it does not know
     * answers with a redirect or a page, which is not the JSON [parse] reads.
     *
     * **And only on one of [hosts]**, the link domains the app gave `initialize` as `linkHosts` —
     * the ones it declares for App Links. On Android another app can hand this one an intent
     * carrying any URL, so asking any https host would send the question wherever that app pointed
     * it, and bring back a click id and a path to be credited and routed on. A link host is always
     * one of the project's own custom domains (the shared host serves no association file), so the
     * app already knows the whole list.
     */
    fun candidate(url: String?, hosts: Set<String>): String? {
        val raw = url?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val uri = runCatching { URI(raw) }.getOrNull() ?: return null
        if (!"https".equals(uri.scheme, ignoreCase = true)) return null
        val host = uri.host?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
        if (host !in hosts) return null
        return if (SLUG_PATH.matches(uri.rawPath ?: "")) raw else null
    }

    /**
     * A host as `linkHosts` may give it — `open.example.com`, or pasted with its scheme or a path —
     * reduced to the bare lowercase name [candidate] compares against.
     */
    fun normalizeHost(value: String): String =
        value.trim().substringAfter("://").substringBefore('/').substringBefore(':').lowercase().trimEnd('.')

    /**
     * The link host's answer. The path is held to [isDeepLinkPath], the rule every Treebars SDK holds
     * a deep-link path to: it is handed to the app to route on, and a value that is not a
     * path inside the app — `https://…`, `//host/…` — would make a link an open redirect out of it.
     * The click id stands without it; the tap was real.
     */
    fun parse(body: String): ResolvedLink? = runCatching {
        val answer = JSONObject(body)
        val clickId = answer.optString("click_id").takeIf { it.isNotBlank() } ?: return null
        val path = if (answer.isNull("deep_link_path")) null else answer.optString("deep_link_path").takeIf { isDeepLinkPath(it) }
        ResolvedLink(clickId, path)
    }.getOrNull()

    /**
     * Asks the link's address what it means. Blocking; null on any refusal, redirect or failure.
     *
     * Redirects are NOT followed. A host that does not know the header redirects as it would for a
     * browser, and following that would fetch a store page or the customer's website for nothing.
     */
    fun ask(url: String): ResolvedLink? {
        val connection = runCatching { URL(url).openConnection() as HttpURLConnection }.getOrNull() ?: return null
        return try {
            connection.requestMethod = "GET"
            connection.instanceFollowRedirects = false
            // Somebody is looking at a launching app; a slow answer is worse than none.
            connection.connectTimeout = 5_000
            connection.readTimeout = 5_000
            connection.setRequestProperty(TreebarsConstants.LINK_RESOLVE_HEADER, "android")
            connection.setRequestProperty("Accept", "application/json")
            if (connection.responseCode != 200) null
            else parse(connection.inputStream.bufferedReader().use { it.readText() })
        } catch (error: Exception) {
            TreebarsLogger.log("link resolve failed for $url: $error")
            null
        } finally {
            connection.disconnect()
        }
    }
}
