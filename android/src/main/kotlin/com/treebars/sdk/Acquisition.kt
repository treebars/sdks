package com.treebars.sdk

import android.content.Context
import android.content.SharedPreferences
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import com.treebars.sdk.generated.TreebarsConstants
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume
import java.net.URLDecoder

/*
 * How this install arrived, as the Play Store tells it.
 *
 * A tap on a Treebars tracking link sends somebody to the Play Store with a `referrer` the link
 * wrote — a click id and the campaign parameters. Play keeps that string through the install and
 * hands it to the app, once asked, through the Install Referrer service. This file asks, once per
 * install, and forwards what it gets as `install_referrer`, essentially unread: the encoding is
 * read in one place, on the server, so a second reading here can never drift from it.
 *
 * **One key is the exception.** `tbrs_deep_link` carries the screen the link was for, and it has
 * to reach the host app on THIS launch — before any batch has flushed and any server has answered
 * — or the person is already looking at the home screen. So that one value is read here, checked
 * here, and handed over here. Nothing else is.
 *
 * Three rules shape it:
 *
 *  - **Only for a new install.** The latch is set when `first_seen_at` is minted and never on an
 *    install that already existed, so an app update that adds this SDK does not report every
 *    existing install as if it had just arrived.
 *  - **Only with consent**, which defaults to no. The host app owns whatever prompt that takes;
 *    this never shows one. Without consent the latch simply waits, so consent given three
 *    launches later still sends the referrer, which Play keeps for ninety days.
 *  - **Nothing on this path may throw** into the host app. Every failure is an answer.
 */

/** What the service said, in the three shapes the latch acts on. */
internal sealed class ReferrerAnswer {
    data class Found(val properties: Map<String, Any?>) : ReferrerAnswer()

    /** It never will: no Play on this device, or a caller the service refuses outright. */
    object Never : ReferrerAnswer()

    /** Not this time — busy, disconnected, or slow. The latch stays for the next launch. */
    object NotNow : ReferrerAnswer()
}

internal fun interface ReferrerSource {
    suspend fun read(): ReferrerAnswer
}

/**
 * The event's properties, from the values `ReferrerDetails` exposes.
 *
 * Taken as values rather than as the `ReferrerDetails` itself so the shape can be tested without
 * the Play service, and so the one place that names these properties is this one. The four
 * timestamps are the click and the install start, each by the device's clock and by Google's,
 * forwarded as Play reports them.
 */
internal fun referrerProperties(
    referrer: String?,
    clickSeconds: Long,
    installBeginSeconds: Long,
    clickServerSeconds: Long,
    installBeginServerSeconds: Long,
    installVersion: String?,
    googlePlayInstant: Boolean,
): Map<String, Any?> = mapOf(
    "referrer" to referrer.orEmpty(),
    "referrer_click_timestamp_seconds" to clickSeconds,
    "install_begin_timestamp_seconds" to installBeginSeconds,
    "referrer_click_timestamp_server_seconds" to clickServerSeconds,
    "install_begin_timestamp_server_seconds" to installBeginServerSeconds,
    "install_version" to installVersion,
    "google_play_instant" to googlePlayInstant,
)

/**
 * The Play Install Referrer service, reduced to one suspending read.
 *
 * The connection is opened, read and closed every time rather than held: this runs at most once
 * per install that has not yet been answered, and a held binder is a resource the host app pays
 * for on every launch after it.
 */
internal class PlayReferrerSource(private val context: Context) : ReferrerSource {
    override suspend fun read(): ReferrerAnswer {
        val client = runCatching { InstallReferrerClient.newBuilder(context).build() }
            .getOrElse { return ReferrerAnswer.Never }
        try {
            /*
             * Bounded, because the callback is the service's to make and a service that never
             * makes it would otherwise hold this coroutine — and with it the latch's lock — for
             * the life of the process. Ten seconds is far past a healthy bind.
             */
            val code = withTimeoutOrNull(CONNECT_TIMEOUT_MS) { connect(client) }
                ?: return ReferrerAnswer.NotNow
            return when (code) {
                InstallReferrerClient.InstallReferrerResponse.OK -> {
                    // A binder call, so off whatever thread the callback resumed us on.
                    val details = withContext(Dispatchers.IO) { runCatching { client.installReferrer }.getOrNull() }
                        ?: return ReferrerAnswer.NotNow
                    ReferrerAnswer.Found(
                        referrerProperties(
                            referrer = details.installReferrer,
                            clickSeconds = details.referrerClickTimestampSeconds,
                            installBeginSeconds = details.installBeginTimestampSeconds,
                            clickServerSeconds = details.referrerClickTimestampServerSeconds,
                            installBeginServerSeconds = details.installBeginTimestampServerSeconds,
                            installVersion = details.installVersion,
                            googlePlayInstant = details.googlePlayInstantParam,
                        ),
                    )
                }
                /*
                 * Answers that a relaunch will not change: a device without the Play Store, an
                 * integration the service rejects, or one it will not let bind. Retrying those
                 * would cost a bind on every launch forever, for nothing.
                 */
                InstallReferrerClient.InstallReferrerResponse.FEATURE_NOT_SUPPORTED,
                InstallReferrerClient.InstallReferrerResponse.DEVELOPER_ERROR,
                InstallReferrerClient.InstallReferrerResponse.PERMISSION_ERROR,
                -> ReferrerAnswer.Never
                // SERVICE_UNAVAILABLE is the store updating itself; the next launch asks again.
                else -> ReferrerAnswer.NotNow
            }
        } finally {
            runCatching { client.endConnection() }
        }
    }

    private suspend fun connect(client: InstallReferrerClient): Int =
        suspendCancellableCoroutine { continuation ->
            val listener = object : InstallReferrerStateListener {
                override fun onInstallReferrerSetupFinished(responseCode: Int) {
                    if (continuation.isActive) continuation.resume(responseCode)
                }

                override fun onInstallReferrerServiceDisconnected() {
                    if (continuation.isActive) {
                        continuation.resume(InstallReferrerClient.InstallReferrerResponse.SERVICE_DISCONNECTED)
                    }
                }
            }
            // A bind that throws — no Play Store package to bind to — is the service's
            // FEATURE_NOT_SUPPORTED by another route, and is answered as one.
            runCatching { client.startConnection(listener) }.onFailure {
                if (continuation.isActive) {
                    continuation.resume(InstallReferrerClient.InstallReferrerResponse.FEATURE_NOT_SUPPORTED)
                }
            }
        }

    private companion object {
        const val CONNECT_TIMEOUT_MS = 10_000L
    }
}

/**
 * The link's destination, out of the referrer, on the device.
 *
 * **The one thing this file parses**, against the rule at the top of the file that it parses nothing.
 * The exception is the point of the feature: a deferred deep link has to reach the host app on
 * this launch, before any batch has flushed and any server has answered, or the person is already
 * looking at the home screen. Everything else in the referrer still travels raw and is read once,
 * server side.
 *
 * `java.net.URLDecoder` rather than `android.net.Uri`, for two reasons that both matter: it is
 * plain JVM, so this is testable without an emulator, and it decodes exactly what
 * `URLSearchParams.toString()` encoded — `+` as a space included, which `Uri.getQueryParameter`
 * gets wrong for a value the link wrote.
 */
internal fun deepLinkPathFrom(referrer: String?): String? {
    if (referrer.isNullOrEmpty()) return null
    for (pair in referrer.split('&')) {
        val equals = pair.indexOf('=')
        if (equals <= 0) continue
        if (decodeFormValue(pair.substring(0, equals)) != TreebarsConstants.DEEP_LINK_PARAM) continue
        val value = decodeFormValue(pair.substring(equals + 1))
        return if (isDeepLinkPath(value)) value else null
    }
    return null
}

private fun decodeFormValue(raw: String): String =
    // A malformed escape is not a crash in somebody else's app: it is a pair we did not write.
    runCatching { URLDecoder.decode(raw, "UTF-8") }.getOrDefault("")

/**
 * Whether this is a path this SDK will hand to the host app.
 *
 * **A path, never a URL, and this is a safety check rather than tidiness.** The app routes on
 * whatever it is given, and one that does `startActivity(Intent(ACTION_VIEW, Uri.parse(path)))`
 * would open whatever it named — so a referrer saying `https://…` or `intent://…` would leave the
 * app for somewhere else, on every install from that link. `//evil.example/x` is refused for the
 * same reason: a leading `//` is a scheme-relative URL wherever it is parsed, however much it
 * looks like a path. A backslash goes too, because several routers fold it to `/`.
 *
 * Treebars applies the same rule when a link is saved. This is the second half rather than a
 * duplicate: the referrer reaches this SDK from the Play service on a device the app does not
 * control, which is not the same trust as a value the server stored.
 */
internal fun isDeepLinkPath(value: String): Boolean {
    if (value.isEmpty() || value.length > TreebarsConstants.MAX_DEEP_LINK_PATH_LENGTH) return false
    if (!value.startsWith("/") || value.startsWith("//")) return false
    return value.none { it == '\\' || it.isWhitespace() || it.code < 0x20 || it.code == 0x7f }
}

/**
 * The destination a link carried, held until the host app takes it — once, ever.
 *
 * Persisted rather than handed straight over, because the two halves race and neither ordering is
 * wrong: the referrer read finishes whenever the Play service answers, and the app registers its
 * listener whenever it reaches that line of `onCreate`. Holding it in memory would lose the link
 * for whichever app happened to be slower, which is the one job this feature has.
 *
 * **Delivered once and then gone**, and bounded by the install's own age. Both halves are load
 * bearing. Without "once", every launch reopens the sale somebody bought from three weeks ago;
 * without the window, an app that adds a listener in a later version throws its entire installed
 * base into that sale on the day it ships.
 */
internal class DeferredDeepLink(private val prefs: SharedPreferences) {

    /** Remember a path the referrer carried. Never overwrites one already waiting. */
    fun remember(path: String) {
        if (prefs.contains(TreebarsConstants.KEY_DEFERRED_DEEP_LINK)) return
        prefs.edit().putString(TreebarsConstants.KEY_DEFERRED_DEEP_LINK, path).apply()
    }

    /**
     * The path, if one is owed and still worth opening — and it is gone afterwards either way.
     *
     * Taking it clears it even when the window has passed, because a path nobody may open again
     * is not something to keep: leaving it would mean re-deciding the same expiry on every launch
     * for the life of the install.
     */
    fun take(installedAtMs: Long?, nowMs: Long): String? {
        val path = prefs.getString(TreebarsConstants.KEY_DEFERRED_DEEP_LINK, null) ?: return null
        prefs.edit().remove(TreebarsConstants.KEY_DEFERRED_DEEP_LINK).apply()
        // An install with no first-seen moment cannot be inside any window; it also cannot exist,
        // since the same edit writes both. Refusing rather than assuming is the cheap side.
        if (installedAtMs == null) return null
        val age = nowMs - installedAtMs
        if (age < 0 || age > TreebarsConstants.DEFERRED_DEEP_LINK_WINDOW_MS) return null
        return path.takeIf { isDeepLinkPath(it) }
    }
}

/**
 * The latch, and the one decision it makes: ask, and what to do with the answer.
 *
 * Serialised, because two callers can arrive together — `initialize` settling on the way up and
 * the host app granting consent a moment later — and two reads would send two events.
 */
internal class AcquisitionCapture(
    private val prefs: SharedPreferences,
    private val source: ReferrerSource,
    private val send: suspend (Map<String, Any?>) -> Unit,
    /**
     * Called with the destination the referrer carried, if it carried one, BEFORE the event is
     * queued. Before, because this is the half the person is waiting on and the event is not —
     * and a `send` that threw must not be what decides whether they land on the right screen.
     */
    private val carried: (String) -> Unit = {},
) {
    private val lock = Mutex()

    fun pending(): Boolean = prefs.getBoolean(TreebarsConstants.KEY_ACQUISITION_PENDING, false)

    /** True when it queued an event, so the caller knows a flush has something to carry. */
    suspend fun settle(consented: Boolean): Boolean {
        if (!consented) return false
        return lock.withLock {
            if (!pending()) return@withLock false
            when (val answer = source.read()) {
                is ReferrerAnswer.Found -> {
                    // What the link was for, if it said. Read here and nowhere else.
                    deepLinkPathFrom(answer.properties["referrer"] as? String)?.let(carried)
                    /*
                     * Queued before the latch is cleared, so a process killed between the two
                     * asks again on the next launch rather than never — a duplicate the server
                     * can recognise, where a loss is something nothing could recover.
                     */
                    send(answer.properties)
                    clear()
                    TreebarsLogger.log("Install referrer sent")
                    true
                }
                ReferrerAnswer.Never -> {
                    clear()
                    TreebarsLogger.log("No install referrer on this device; not asking again")
                    false
                }
                ReferrerAnswer.NotNow -> {
                    TreebarsLogger.log("Install referrer not available yet; will ask next launch")
                    false
                }
            }
        }
    }

    private fun clear() {
        prefs.edit().remove(TreebarsConstants.KEY_ACQUISITION_PENDING).commit()
    }
}
