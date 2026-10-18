package com.treebars.sdk

import com.treebars.sdk.generated.TreebarsConstants
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.net.URLDecoder

/**
 * What a link host said about a link that opened the app: this tap's click id, and where the link
 * wanted the person to land — a path inside the app, or, for a link that only ever goes to a website,
 * that website ([webUrl], and then [deepLinkPath] is null: the person belongs in the browser).
 */
internal data class ResolvedLink(val clickId: String, val deepLinkPath: String?, val webUrl: String? = null)

/**
 * A Universal Link or App Link opened the app, holding only the link's own address.
 *
 * The operating system hands the link to the app before the tap reaches the link host, so the app
 * has no click id and no deep-link path yet. Asking the address itself — with the
 * `X-Treebars-Resolve` header — gets both back. Without it the app would open on its home screen,
 * with no click to attribute the open to.
 */
internal object LinkResolve {
    /** A link's key: what comes first after the host. */
    private val KEY = Regex("^[A-Za-z0-9_-]{1,64}$")

    /**
     * The address worth asking about, or null.
     *
     * An app is opened by its own website's addresses too, and a question sent to every one of them
     * would be a request to somebody's web server per tap. Only https in a link's shape is asked
     * ([isLinkPath]) — and the host decides the rest: an address it does not know answers with a
     * redirect or a page, which is not the JSON [parse] reads. The whole address is asked, values and
     * query included, because the host fills the link's deep-link path from them.
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
        return if (isLinkPath(uri.rawPath ?: "")) raw else null
    }

    /**
     * Whether a percent-encoded path is a link's: `/<key>`, then up to
     * [TreebarsConstants.MAX_LINK_PATH_VALUES] values — `/spring/u_123/p_9` is the link `spring` carrying
     * two. A key is 1 to 64 letters, digits, `_` or `-`; a value is any segment of 1 to
     * [TreebarsConstants.MAX_LINK_VALUE_LENGTH] characters once decoded, so an encoded `/` stays inside the
     * value it belongs to. One trailing slash is allowed. Both limits are the link host's own.
     *
     * `/p/<key>` is not a link's: it is a page-first link's address, which both association files
     * exclude, so an app is never opened with one.
     */
    fun isLinkPath(path: String): Boolean {
        val segments = path.split('/').toMutableList()
        if (segments.size < 2 || segments[0].isNotEmpty()) return false
        segments.removeAt(0)
        if (segments.size > 1 && segments.last().isEmpty()) segments.removeAt(segments.size - 1)
        val key = segments.removeAt(0)
        if (key == "p" || !KEY.matches(key) || segments.size > TreebarsConstants.MAX_LINK_PATH_VALUES) return false
        return segments.all { segment ->
            val value = decode(segment) ?: return@all false
            value.isNotEmpty() && value.length <= TreebarsConstants.MAX_LINK_VALUE_LENGTH
        }
    }

    /**
     * The part of a path an event may carry: on a link host, `/spring` and never the values after it. A
     * value is often a person's own id, and a link records one only where its author asked; the click id
     * already names the link. A path on any other host comes back unchanged.
     */
    fun openedPath(path: String, host: String?, hosts: Set<String>): String {
        if (host == null || host.lowercase() !in hosts) return path
        val segments = path.split('/').filter { it.isNotEmpty() }
        val key = segments.firstOrNull() ?: return path
        return if (key == "p" && segments.size > 1) "/p/${segments[1]}" else "/$key"
    }

    /** One path segment, percent-decoded as a path is — a `+` stays a `+` — or null when it is malformed. */
    private fun decode(segment: String): String? =
        runCatching { URLDecoder.decode(segment.replace("+", "%2B"), "UTF-8") }.getOrNull()

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
     *
     * **A website-only link answers with `web_url` instead**, and then the app is handed no path at all:
     * the operating system opened the app only because the app claims the link's domain, and the link's
     * author said it goes to a website. The address is taken only when [webAddress] accepts it.
     */
    fun parse(body: String, hosts: Set<String> = emptySet()): ResolvedLink? = runCatching {
        val answer = JSONObject(body)
        val clickId = answer.optString("click_id").takeIf { it.isNotBlank() } ?: return null
        if (answer.has("web_url") && !answer.isNull("web_url")) {
            return ResolvedLink(clickId, null, webAddress(answer.optString("web_url"), hosts))
        }
        val path = if (answer.isNull("deep_link_path")) null else answer.optString("deep_link_path").takeIf { isDeepLinkPath(it) }
        ResolvedLink(clickId, path)
    }.getOrNull()

    /**
     * A website the browser may be sent to, or null: https only, with a host, and never one of [hosts].
     * The app's own link domains open the app, so sending the person to one would bring them straight
     * back here; and anything but https — another app's scheme, `javascript:` — is not a website.
     */
    fun webAddress(value: String, hosts: Set<String>): String? {
        if (value.isEmpty() || value.length > 2048) return null
        val uri = runCatching { URI(value) }.getOrNull() ?: return null
        if (!"https".equals(uri.scheme, ignoreCase = true)) return null
        val host = uri.host?.takeIf { it.isNotEmpty() } ?: return null
        return if (normalizeHost(host) in hosts) null else value
    }

    /**
     * Asks the link's address what it means. Blocking; null on any refusal, redirect or failure.
     *
     * Redirects are NOT followed. A host that does not know the header redirects as it would for a
     * browser, and following that would fetch a store page or the customer's website for nothing.
     */
    fun ask(url: String, hosts: Set<String>): ResolvedLink? {
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
            else parse(connection.inputStream.bufferedReader().use { it.readText() }, hosts)
        } catch (error: Exception) {
            TreebarsLogger.log("link resolve failed for $url: $error")
            null
        } finally {
            connection.disconnect()
        }
    }
}
