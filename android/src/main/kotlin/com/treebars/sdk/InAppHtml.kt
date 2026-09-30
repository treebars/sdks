package com.treebars.sdk

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Dialog
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.view.WindowInsets
import android.view.WindowManager
import android.webkit.JavascriptInterface
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.LinearLayout
import com.treebars.sdk.generated.TreebarsBridge
import com.treebars.sdk.generated.TreebarsConstants
import org.json.JSONArray
import org.json.JSONObject
import java.security.SecureRandom
import java.util.Locale

/*
 * An HTML in-app message, drawn by this SDK in a WebView with the `treebars` bridge.
 *
 * Standard bodies are drawn natively ([InAppNativeHost]) or by an app's own renderer; a markup body is this SDK's — the
 * page needs the bridge, and a bridge an app had to wire by hand would be a bridge most apps got
 * subtly wrong. Three pieces, each the Android spelling of the web SDK's (`sdks/web/src/bridge-host.ts`,
 * `bridge-calls.ts`), and held to it by the same golden documents and the same conformance cases, in
 * `src/test/resources`:
 *
 * - [BridgeDocument]: what the WebView is handed — the frame policy and the page-side shim before anything of the
 *   message's, byte for byte what the web SDK builds.
 * - [BridgeDisplay]: what each call means — one display's state and a handler for every method the bridge table gives
 *   Android.
 * - [InAppHtmlHost]: the window and the WebView, the container spec, the safe-area insets, and who may call.
 */

/** Safe-area insets in CSS pixels, which on Android are dp. */
internal data class BridgeInsets(val top: Int, val right: Int, val bottom: Int, val left: Int)

internal object BridgeDocument {
    private val DOCTYPE = Regex("^\\s*<!doctype[^>]*>", RegexOption.IGNORE_CASE)
    private val IS_DOCUMENT = Regex("^\\s*(<!doctype\\b|<html\\b)", RegexOption.IGNORE_CASE)
    private val AUTHOR_DIRECTION = Regex("<(html|body)\\b[^>]*\\sdir\\s*=", RegexOption.IGNORE_CASE)
    /** The device classes `data-tb-show` names, as the session rules do. */
    private val DEVICE_CLASSES = setOf("mobile", "tablet", "desktop")
    /** The ways a device is held that `data-tb-orientation` names. */
    private val ORIENTATIONS = setOf("portrait", "landscape")

    /** What hides the elements not for this orientation; the shim writes it again on a turn. */
    fun orientationRule(orientation: String): String = "[data-tb-orientation]:not([data-tb-orientation~=\"$orientation\"]){display:none!important}"

    /**
     * The document a message's WebView is handed: the web SDK's document, spelled in Kotlin. A fragment is framed as the
     * preview frames it; a whole document stays one, the policy and shim straight after its doctype. The insets ride as
     * CSS variables (`--tb-safe-top` …) because `env(safe-area-inset-*)` is not something every Android WebView answers.
     * The device class hides every `data-tb-show` element not listed for it — a rule in the document, so it holds with
     * scripts off and nothing is drawn and taken back. The orientation hides every `data-tb-orientation` element not for
     * the way the device is held, in a rule of its own that
     * [InAppHtmlHost] has the shim rewrite when the device turns.
     */
    fun build(html: String, host: String, nonce: String, direction: String?, insets: BridgeInsets?, device: String? = null, orientation: String? = null): String {
        val policy = "<meta http-equiv=\"Content-Security-Policy\" content=\"${escapeAttribute(TreebarsBridge.FRAME_CSP)}\">"
        val shim = "<script>${TreebarsBridge.SHIM}({\"host\":\"$host\",\"nonce\":\"$nonce\"})</script>"
        val safe = insets?.let {
            "<style>:root{--tb-safe-top:${it.top}px;--tb-safe-right:${it.right}px;--tb-safe-bottom:${it.bottom}px;--tb-safe-left:${it.left}px}</style>"
        } ?: ""
        val shown = if (device != null && device in DEVICE_CLASSES) "<style>[data-tb-show]:not([data-tb-show~=\"$device\"]){display:none!important}</style>" else ""
        val held = if (orientation != null && orientation in ORIENTATIONS) "<style id=\"tb-orientation\">${orientationRule(orientation)}</style>" else ""
        val dir = if (direction == "rtl" && !AUTHOR_DIRECTION.containsMatchIn(html)) "<html dir=\"rtl\">" else ""
        if (IS_DOCUMENT.containsMatchIn(html)) {
            val found = DOCTYPE.find(html)?.value
            return "${found ?: "<!doctype html>"}$dir$policy$safe$shown$held$shim${html.substring(found?.length ?: 0)}"
        }
        return "<!doctype html>$dir<meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1,viewport-fit=cover\">" +
            "$policy<style>${TreebarsBridge.FRAME_RULES}</style>$safe$shown$held$shim$html"
    }

    private fun escapeAttribute(value: String): String = value.replace("&", "&amp;").replace("\"", "&quot;").replace("<", "&lt;")

    /** A nonce for one display: unguessable, and in nothing but the document the WebView is handed. */
    fun nonce(): String {
        val bytes = ByteArray(16)
        SecureRandom().nextBytes(bytes)
        return bytes.joinToString("") { "%02x".format(it) }
    }
}

/** What a display may ask of the SDK: the few things a bridge call needs, and nothing else. */
internal interface BridgeSdk {
    fun track(name: String, properties: Map<String, Any?>)
    /**
     * Traits on the person: through `identify` when somebody is signed in, on the anonymous person otherwise, who
     * carries them into the account at sign-in. The page cannot tell the two apart, by design.
     */
    fun setTraits(traits: Map<String, Any?>): Map<String, Any?>
    fun requestPushPermission(answer: (String) -> Unit)
    /** The app's click listener, told what was pressed. */
    fun clicked(action: String, values: Map<String, Any?>, fields: Map<String, Any?>)
    /** Spent, the screen freed and the message closed: a press that leads somewhere. */
    fun spent()
    /** Dismissed: spent, the screen freed, the app told. Recording is the display's. */
    fun dismissed()
    fun flush()
    /**
     * Somewhere a press leads, and which call asked — `openDeepLink`, `openWebURL`, `openRichLanding`, `_link`, or
     * `_link_new` for a link with `target="_blank"` — the web SDK's names, so the conformance cases read one way.
     */
    fun open(url: String, via: String): Boolean
    fun copy(text: String, toast: String?): Boolean
    fun dial(number: String): Boolean
    fun sms(number: String, body: String?): Boolean
    fun share(text: String): Boolean
    fun settings(notifications: Boolean): Boolean
    fun storeReview(): Boolean
    fun alert(message: String)
    /** `getContext()`'s device half: locale, theme, insets. */
    fun context(): Map<String, Any?>
    fun log(line: String)
    /**
     * The server's answer to `claimReward(pool)` for this message: `{ won, prize?, code?, empty? }`, or
     * a refusal — `not_available` for a pool the message does not name or that is gone, `offline` when it could not ask.
     */
    fun claimReward(pool: String, deliveryId: String, answer: (Map<String, Any?>) -> Unit)
}

/**
 * One display of one HTML message: its bridge state and an answer for every call — `BridgeDisplay` in the web SDK,
 * held to it by `bridge-conformance.json`. Every answer arrives through [call]'s `answer`, and every one is a value; a
 * refusal is `{ ok: false, reason }`, never an exception, because a template's script is not written to catch one.
 *
 * Main thread only: the host posts every call there before it arrives.
 */
internal class BridgeDisplay(
    private val message: InAppMessage,
    private val sdk: BridgeSdk,
    /** How the press folding waits for the rest of a handler's calls: the main looper in the app, by hand in a test. */
    private val later: (Long, () -> Unit) -> Unit,
) {
    private var dismissRecorded = false
    internal var screen: String? = null
        private set
    private var events = 0
    private val lastEvent = HashMap<String, Long>()
    private var pending: PendingClick? = null
    private val content: JSONObject? = message.raw.optJSONObject("content")?.optJSONObject("in_app")
    private val declaredEvents: Set<String> = names(content?.optJSONObject("declared")?.optJSONArray("events"))
    private val declaredTraits: Set<String> = names(content?.optJSONObject("declared")?.optJSONArray("traits"))

    /** What the campaign kept for the person, as synced, with this display's writes laid over it. */
    internal val stored: MutableMap<String, Any?> = run {
        val synced = message.raw.optJSONObject("stored") ?: JSONObject().also { message.raw.put("stored", it) }
        synced.keys().asSequence().associateWith { synced.opt(it) }.toMutableMap()
    }

    private class PendingClick(val fields: LinkedHashMap<String, Any?>, val then: MutableList<() -> Unit>, var leads: Boolean)

    private fun names(array: JSONArray?): Set<String> = (0 until (array?.length() ?: 0)).mapNotNull { array!!.optString(it).takeIf { name -> name.isNotEmpty() } }.toSet()

    private fun receipt(): MutableMap<String, Any?> {
        val out = inAppReceipt(message)
        screen?.let { out[TreebarsBridge.KEY_SCREEN] = it }
        return out
    }

    /** A dismissal from anywhere — the page, the back button, the timer — recorded once per display. */
    fun dismiss(element: String? = null) {
        recordDismiss(element)
        sdk.dismissed()
    }

    private fun recordDismiss(element: String?) {
        if (dismissRecorded) return
        dismissRecorded = true
        sdk.track("in_app_dismissed", receipt().apply { element?.let { put(TreebarsBridge.KEY_ELEMENT, it) } })
    }

    /**
     * A press, recorded once however many calls said so: `trackClick(1)` and `openWebURL(url)` from one handler are one
     * press, folded into one `in_app_clicked` with the element, the destination and the screen it was pressed on. A
     * handler's calls cross the bridge one after another within a millisecond or two; [CLICK_WINDOW_MS] waits for the
     * rest. What the press leads to runs after it is recorded and flushed.
     */
    private fun click(fields: Map<String, Any?>, then: (() -> Unit)? = null, leads: Boolean = false) {
        val current = pending ?: PendingClick(LinkedHashMap<String, Any?>().apply { screen?.let { put(TreebarsBridge.KEY_SCREEN, it) } }, mutableListOf(), false).also {
            pending = it
            later(CLICK_WINDOW_MS) { flushClick() }
        }
        current.fields.putAll(fields)
        then?.let { current.then.add(it) }
        if (leads) current.leads = true
    }

    internal fun flushClick() {
        val done = pending ?: return
        pending = null
        val properties = inAppReceipt(message).apply { putAll(done.fields) }
        sdk.track("in_app_clicked", properties)
        val action = done.fields["action"] as? String ?: "click"
        @Suppress("UNCHECKED_CAST")
        val values = done.fields["values"] as? Map<String, Any?> ?: emptyMap()
        sdk.clicked(action, values, done.fields)
        if (done.leads) sdk.spent()
        if (done.then.isNotEmpty()) sdk.flush()
        done.then.forEach { it() }
    }

    private fun event(args: JSONArray): Map<String, Any?> {
        val name = args.opt(0) as? String ?: return refuse("invalid_name")
        if (!NAME.matches(name) || name == "undefined" || name == "null") return refuse("invalid_name")
        if (name.startsWith("in_app_") || name in TreebarsConstants.RESERVED_EVENT_NAMES) return refuse("reserved")
        if (name !in declaredEvents) {
            sdk.log("in-app event \"$name\" is not declared in the message, so it was not recorded")
            return refuse("undeclared")
        }
        val now = System.currentTimeMillis()
        if (now - (lastEvent[name] ?: Long.MIN_VALUE / 2) < TreebarsBridge.REPEAT_WINDOW_MS) return refuse("repeat")
        if (events >= TreebarsBridge.EVENTS_PER_DISPLAY) return refuse("limit")
        events += 1
        lastEvent[name] = now
        // Location and date objects are properties like any other; the campaign is always attached.
        val properties = LinkedHashMap<String, Any?>()
        properties.putAll(objectFrom(args.opt(3)))
        properties.putAll(objectFrom(args.opt(2)))
        properties.putAll(objectFrom(args.opt(1)))
        properties.putAll(receipt())
        sdk.track(name, properties)
        return OK
    }

    private fun trait(name: String, value: Any?): Map<String, Any?> = if (value == null || value == JSONObject.NULL) refuse("invalid_value") else sdk.setTraits(mapOf(name to value))

    private fun declaredTrait(name: Any?, value: Any?): Map<String, Any?> {
        if (name !is String || !NAME.matches(name)) return refuse("invalid_name")
        if (name in TreebarsBridge.RESERVED_TRAITS) return refuse("reserved")
        if (name !in declaredTraits) return refuse("undeclared")
        return trait(name, value)
    }

    private fun optIn(kind: String, value: Any?): Map<String, Any?> {
        val address = (value as? String)?.trim().orEmpty()
        val valid = if (kind == "email") EMAIL.matches(address) else PHONE.matches(address)
        if (!valid) return refuse("invalid_value")
        sdk.track(TreebarsBridge.EVENT_OPTED_IN, receipt().apply { put(kind, address) })
        return OK
    }

    private fun url(value: Any?): String? {
        val target = (value as? String)?.trim().orEmpty()
        if (target.isEmpty() || RUNS_IN_PLACE.containsMatchIn(target.replace(Regex("[\\u0000- ]"), ""))) return null
        return target
    }

    private fun location(latitude: Any?, longitude: Any?): Map<String, Any?>? {
        val lat = (latitude as? Number)?.toDouble() ?: return null
        val lng = (longitude as? Number)?.toDouble() ?: return null
        if (!lat.isFinite() || !lng.isFinite() || kotlin.math.abs(lat) > 90 || kotlin.math.abs(lng) > 180) return null
        return mapOf("latitude" to lat, "longitude" to lng)
    }

    private val handlers: Map<String, (JSONArray, () -> Unit, (Any?) -> Unit) -> Unit> = mapOf(
        // Said by the shim, and answered by the host before it arrives here.
        "_ready" to { _, _, answer -> answer(OK) },
        "resize" to { _, _, answer -> answer(OK) },

        "dismissMessage" to { _, close, answer ->
            close()
            dismiss()
            answer(OK)
        },
        "trackDismiss" to { args, _, answer ->
            recordDismiss(widget(args.opt(0)))
            answer(OK)
        },
        "trackClick" to { args, _, answer ->
            val element = widget(args.opt(0))
            val fields = LinkedHashMap<String, Any?>()
            element?.let { fields[TreebarsBridge.KEY_ELEMENT] = it }
            element?.takeIf { WHOLE.matches(it) }?.let { fields[TreebarsConstants.IN_APP_BUTTON_INDEX_KEY] = it.toInt() }
            click(fields)
            answer(OK)
        },
        "trackRating" to { args, _, answer ->
            val rating = (args.opt(0) as? Number)?.toDouble()
            if (rating == null || !rating.isFinite()) answer(refuse("invalid_value"))
            else {
                sdk.track(TreebarsBridge.EVENT_RATED, receipt().apply { put("rating", rating) })
                answer(OK)
            }
        },
        "trackEvent" to { args, _, answer -> answer(event(args)) },

        "identifyUser" to { _, _, answer -> answer(refuse("identity_from_message")) },
        "setUniqueId" to { _, _, answer -> answer(refuse("identity_from_message")) },
        "setAlias" to { _, _, answer -> answer(refuse("identity_from_message")) },

        "setEmailId" to { args, _, answer -> answer(optIn("email", args.opt(0))) },
        "setMobileNumber" to { args, _, answer -> answer(optIn("phone", args.opt(0))) },
        "setUserName" to { args, _, answer -> answer(trait("name", args.opt(0) as? String)) },
        "setFirstName" to { args, _, answer -> answer(trait("first_name", args.opt(0) as? String)) },
        "setLastName" to { args, _, answer -> answer(trait("last_name", args.opt(0) as? String)) },
        "setGender" to { args, _, answer ->
            val value = args.opt(0) as? String
            answer(if (value in setOf("male", "female", "other")) trait("gender", value) else refuse("invalid_value"))
        },
        "setBirthDate" to { args, _, answer ->
            val value = args.opt(0) as? String
            answer(if (value != null && ISO_DATE.matches(value)) trait("birth_date", value) else refuse("invalid_value"))
        },
        "setUserLocation" to { args, _, answer -> answer(location(args.opt(0), args.opt(1))?.let { trait("location", it) } ?: refuse("invalid_value")) },
        "setUserAttribute" to { args, _, answer ->
            val value = args.opt(1)
            answer(if (value is String || value is Number || value is Boolean) declaredTrait(args.opt(0), value) else refuse("invalid_value"))
        },
        "setUserAttributeDate" to { args, _, answer ->
            val value = args.opt(1) as? String
            answer(if (value != null && ISO_DATE.matches(value)) declaredTrait(args.opt(0), value) else refuse("invalid_value"))
        },
        "setUserAttributeLocation" to { args, _, answer ->
            answer(location(args.opt(1), args.opt(2))?.let { declaredTrait(args.opt(0), it) } ?: refuse("invalid_value"))
        },

        "navigateToScreen" to { args, _, answer ->
            val screenName = (args.opt(0) as? String)?.trim().orEmpty()
            if (screenName.isEmpty()) answer(refuse("invalid_value"))
            else {
                click(mapOf(TreebarsBridge.KEY_DESTINATION to screenName, "action" to "navigate", "values" to objectFrom(args.opt(1)) + ("screen" to screenName)))
                answer(OK)
            }
        },
        "openDeepLink" to { args, _, answer ->
            val target = url(args.opt(0))
            if (target == null) answer(refuse("invalid_url"))
            else {
                click(mapOf(TreebarsBridge.KEY_DESTINATION to target), { sdk.open(target, "openDeepLink") }, leads = true)
                answer(OK)
            }
        },
        "openRichLanding" to { args, _, answer ->
            val target = url(args.opt(0))
            if (target == null) answer(refuse("invalid_url"))
            else {
                click(mapOf(TreebarsBridge.KEY_DESTINATION to target), { sdk.open(target, "openRichLanding") })
                answer(OK)
            }
        },
        "openWebURL" to { args, _, answer ->
            val target = url(args.opt(0))
            if (target == null) answer(refuse("invalid_url"))
            else {
                click(mapOf(TreebarsBridge.KEY_DESTINATION to target), { sdk.open(target, "openWebURL") }, leads = true)
                answer(OK)
            }
        },

        "copyText" to { args, _, answer ->
            val done = sdk.copy((args.opt(0) as? String) ?: args.opt(0)?.toString().orEmpty(), (args.opt(1) as? String)?.trim()?.takeIf { it.isNotEmpty() })
            answer(if (done) OK else refuse("not_allowed"))
        },
        "call" to { args, _, answer ->
            val number = (args.opt(0) as? String)?.trim().orEmpty()
            answer(if (number.isNotEmpty() && sdk.dial(number)) OK else refuse("invalid_value"))
        },
        "sms" to { args, _, answer ->
            val number = (args.opt(0) as? String)?.trim().orEmpty()
            answer(if (number.isNotEmpty() && sdk.sms(number, args.opt(1) as? String)) OK else refuse("invalid_value"))
        },
        "share" to { args, _, answer -> answer(if (sdk.share(args.opt(0)?.toString().orEmpty())) OK else refuse("unsupported")) },
        "customAction" to { args, _, answer ->
            click(mapOf("action" to "custom", "values" to objectFrom(args.opt(0))))
            answer(OK)
        },
        "requestNotificationPermission" to { _, _, answer -> sdk.requestPushPermission { answer(it) } },
        "showPushOptIn" to { _, _, answer -> sdk.requestPushPermission { answer(it) } },
        "handleNotificationPopUp" to { _, _, answer -> sdk.requestPushPermission { answer(it) } },
        "navigateToNotificationSettings" to { _, _, answer -> answer(if (sdk.settings(notifications = true)) OK else refuse("unsupported")) },
        "navigateToSettings" to { _, _, answer -> answer(if (sdk.settings(notifications = false)) OK else refuse("unsupported")) },
        "requestStoreReview" to { _, _, answer -> answer(if (sdk.storeReview()) OK else refuse("unsupported")) },

        "getContext" to { _, _, answer ->
            answer(
                sdk.context() + mapOf(
                    "direction" to (content?.optString("direction")?.takeIf { it == "rtl" || it == "ltr" } ?: "ltr"),
                    "platform" to "android",
                    "screen" to screen,
                    "deliveryId" to message.deliveryId,
                    "campaignId" to message.campaignId,
                    "bridgeVersion" to TreebarsBridge.VERSION,
                    "preview" to false,
                ),
            )
        },
        "claimReward" to { args, _, answer ->
            val pool = args.opt(0) as? String
            if (pool == null || !POOL.matches(pool)) answer(refuse("invalid_name"))
            else sdk.claimReward(pool, message.deliveryId) { result ->
                // Recorded as the page is told, so the report and the person agree; a refusal is not a play.
                (result["won"] as? Boolean)?.let { won ->
                    sdk.track(
                        TreebarsBridge.EVENT_REWARD_CLAIMED,
                        receipt().apply {
                            put("pool", pool)
                            put("won", won)
                            (result["prize"] as? String)?.let { put("prize", it) }
                        },
                    )
                }
                answer(result)
            }
        },
        "getStoredValue" to { args, _, answer ->
            val key = args.opt(0) as? String
            answer(if (key != null && stored.containsKey(key)) stored[key] else null)
        },
        "setStoredValue" to { args, _, answer -> answer(storeValue(args.opt(0), args.opt(1))) },

        "_screen" to { args, _, answer ->
            val name = args.opt(0) as? String
            if (name == null) answer(refuse("invalid_value"))
            else {
                screen = name.take(128)
                sdk.track(
                    TreebarsBridge.EVENT_SCREEN_VIEWED,
                    receipt().apply {
                        put("index", (args.opt(1) as? Number)?.toInt() ?: 0)
                        (args.opt(2) as? String)?.let { put("from", it) }
                        put("how", args.opt(3) as? String ?: "jump")
                    },
                )
                answer(OK)
            }
        },
        "_complete" to { args, _, answer ->
            sdk.track(TreebarsBridge.EVENT_COMPLETED, receipt().apply { put("screens_seen", (args.opt(0) as? Number)?.toInt() ?: 0) })
            answer(OK)
        },
        // A quiz reached its result: its score, recorded here as every other `in_app_*` is.
        "_quiz" to { args, _, answer ->
            sdk.track(
                TreebarsBridge.EVENT_QUIZ_COMPLETED,
                receipt().apply {
                    put("quiz", (args.opt(0) as? String)?.take(64) ?: "quiz")
                    put("score", (args.opt(1) as? Number)?.toDouble() ?: 0.0)
                    put("total", (args.opt(2) as? Number)?.toDouble() ?: 0.0)
                },
            )
            answer(OK)
        },
        "_submit" to { args, _, answer ->
            // Answers as a typed form sends them, text or a number, so a group of ticked boxes is kept.
            val answers = objectFrom(args.opt(0)).mapValues { (_, value) ->
                when (value) {
                    is List<*> -> value.joinToString(",")
                    is Boolean -> value.toString()
                    else -> value
                }
            }
            val save = objectFrom(args.opt(1))
            val properties = receipt().apply { put("responses", answers) }
            for (kind in listOf("email", "phone")) (save[kind] as? String)?.takeIf { it.isNotEmpty() }?.let { properties[kind] = it }
            sdk.track("in_app_form_submitted", properties)
            val traits = save.filterKeys { it != "email" && it != "phone" && it in declaredTraits && it !in TreebarsBridge.RESERVED_TRAITS }
            if (traits.isNotEmpty()) sdk.setTraits(traits)
            sdk.flush()
            answer(OK)
        },
        "_link" to { args, close, answer ->
            val action = (args.opt(0) as? String)?.let { readInAppHtmlAction(it) }
            when {
                action == null -> answer(refuse("invalid_url"))
                action is InAppHtmlAction.Dismiss -> {
                    close()
                    dismiss()
                    answer(OK)
                }
                action is InAppHtmlAction.Click -> {
                    click(mapOf(TreebarsBridge.KEY_ELEMENT to action.index.toString(), TreebarsConstants.IN_APP_BUTTON_INDEX_KEY to action.index))
                    answer(OK)
                }
                action is InAppHtmlAction.Link -> {
                    val outside = args.opt(1) == true
                    click(mapOf(TreebarsBridge.KEY_DESTINATION to action.url), { sdk.open(action.url, if (outside) "_link_new" else "_link") }, leads = !outside)
                    answer(OK)
                }
            }
        },
        "_alert" to { args, _, answer ->
            sdk.alert(args.opt(0)?.toString().orEmpty())
            answer(OK)
        },
    )

    private fun storeValue(key: Any?, value: Any?): Map<String, Any?> {
        if (key !is String || !STORED_KEY.matches(key)) return refuse("invalid_name")
        val clean = if (value == JSONObject.NULL) null else value
        val valid = clean == null || clean is String || clean is Boolean || (clean is Number && clean.toDouble().isFinite())
        if (!valid || JSONObject.wrap(clean).toString().length > STORED_MAX_BYTES) return refuse("invalid_value")
        if (clean != null && !stored.containsKey(key) && stored.size >= STORED_MAX_KEYS) return refuse("limit")
        if (clean == null) stored.remove(key) else stored[key] = clean
        // The message's own copy, so a later display of it reads what this one wrote.
        message.raw.optJSONObject("stored")?.let { if (clean == null) it.remove(key) else it.put(key, clean) }
        // Kept on the server per campaign; a test send or a journey step has none, so it lasts this display only.
        if (message.campaignId == null) return refuse("no_campaign")
        sdk.track(TreebarsBridge.EVENT_VALUE_STORED, inAppReceipt(message).apply {
            put("key", key)
            put("value", clean)
        })
        return OK
    }

    /** The methods this display answers — held to the generated list for Android by a test. */
    internal val methods: Set<String> get() = handlers.keys

    /** One call from the page. */
    fun call(method: String, args: JSONArray, close: () -> Unit, answer: (Any?) -> Unit) {
        val handler = handlers[method] ?: return answer(refuse("unsupported"))
        runCatching { handler(args, close, answer) }.onFailure {
            sdk.log("in-app bridge: $method threw: $it")
            answer(refuse("error"))
        }
    }

    companion object {
        /** How long a press waits for the rest of its handler's calls before it is recorded. */
        const val CLICK_WINDOW_MS = 60L
        private const val STORED_MAX_KEYS = 32
        private const val STORED_MAX_BYTES = 1024
        private val NAME = Regex("^[A-Za-z_][\\w.:-]{0,127}$")
        private val STORED_KEY = Regex("^[A-Za-z_][A-Za-z0-9_.:-]{0,63}$")
        /** A reward pool's name, as the server spells it. */
        private val POOL = Regex("^[a-z0-9]([a-z0-9_]{0,58}[a-z0-9])?$")
        private val WHOLE = Regex("^[1-9]\\d*$")
        private val EMAIL = Regex("^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$")
        private val PHONE = Regex("^\\+?[\\d\\s().-]{6,20}$")
        /** An ISO 8601 date, with or without a time: what `setBirthDate` and `setUserAttributeDate` take. */
        private val ISO_DATE = Regex("^\\d{4}-\\d{2}-\\d{2}([T ][0-9:.]+(Z|[+-]\\d{2}:?\\d{2})?)?$")
        private val RUNS_IN_PLACE = Regex("^(?:javascript|vbscript|data|blob|file|filesystem):", RegexOption.IGNORE_CASE)
        val OK: Map<String, Any?> = mapOf("ok" to true)
        fun refuse(reason: String): Map<String, Any?> = mapOf("ok" to false, "reason" to reason)

        /** An element id as a string: `0` stays `"0"`, nothing stays nothing. */
        fun widget(value: Any?): String? = when (value) {
            is Number -> if (value.toDouble().isFinite()) (if (value.toDouble() % 1.0 == 0.0) value.toLong().toString() else value.toString()) else null
            is String -> value.trim().takeIf { it.isNotEmpty() }?.take(128)
            else -> null
        }

        /** An object from a bridge argument: an object as it is, a JSON string parsed, anything else nothing. */
        fun objectFrom(value: Any?): Map<String, Any?> = when (value) {
            is JSONObject -> toMap(value)
            is String -> runCatching { toMap(JSONObject(value)) }.getOrDefault(emptyMap())
            else -> emptyMap()
        }

        fun toMap(json: JSONObject): Map<String, Any?> = json.keys().asSequence().associateWith { plain(json.opt(it)) }

        private fun plain(value: Any?): Any? = when (value) {
            JSONObject.NULL -> null
            is JSONObject -> toMap(value)
            is JSONArray -> (0 until value.length()).map { plain(value.opt(it)) }
            else -> value
        }
    }
}

/**
 * The window and the WebView for one HTML message, the Android half of the web SDK's `bridge-host.ts`: a Dialog
 * for a modal and a fullscreen, and the Activity's own decor view for a banner and a nudge, which leave the app usable.
 *
 * - **Hidden until it runs.** Drawn invisible and shown when the shim says `_ready` — a fitted shape once its height is
 *   known too — and only then counted as displayed ([onShown]). A WebView that cannot be made is `webview_unavailable`.
 * - **Who may call.** The page reaches Java through one interface, `TreebarsBridge.postMessage`, whose calls arrive on a
 *   binder thread: each is posted to the main looper, and taken only with this display's nonce.
 * - **The frame.** JavaScript on, storage, file and content access off, no mixed content, no second window, and every
 *   navigation after the first refused — links come through the shim, which the SDK opens. Loaded with no base URL,
 *   so the page has no origin of the app's.
 * - **The container spec.** A modal is `min(width − 32, 420)` dp wide and as tall as the content up to the window less
 *   32; a banner is full width and up to 30% tall; a fullscreen is the window, drawing nothing of the SDK's behind a
 *   `transparent` one. No padding of the SDK's and no close control. The back button closes a dismissible modal or
 *   fullscreen; a banner's is the app's.
 */
@SuppressLint("SetJavaScriptEnabled", "JavascriptInterface", "AddJavascriptInterface")
internal class InAppHtmlHost(
    private val activity: Activity,
    private val message: InAppMessage,
    private val content: InAppContent,
    private val tokens: InAppTokens?,
    private val display: BridgeDisplay,
    private val onShown: () -> Unit,
    private val onFailed: (String) -> Unit,
    /** The page, the back button or the dim closed it: recorded by the display. */
    private val onPersonClosed: () -> Unit,
    private val customizer: ((WebView) -> Unit)?,
    /**
     * The markup to draw: the body with its prefetched files inlined as `data:` URIs, prepared off
     * the main thread before the screen was claimed ([InAppAssetCache.prepare]); the body as it came, otherwise.
     */
    private val html: String = content.html.orEmpty(),
) {
    private val main = Handler(Looper.getMainLooper())
    private val nonce = BridgeDocument.nonce()
    private var dialog: Dialog? = null
    private var web: WebView? = null
    private var box: FrameLayout? = null
    private var root: FrameLayout? = null
    private var ready = false
    private var shown = false
    private var closed = false
    private var height: Int? = null
    private val density = activity.resources.displayMetrics.density
    private val boxShape = when (content.layout) {
        "banner", "fullscreen", "modal", "nudge" -> content.layout
        "html" -> "fullscreen"
        else -> "modal"
    }
    private val transparent = boxShape == "fullscreen" && content.transparent
    /** The way the device was held when the document's orientation rule was last written. */
    private var held: String = heldNow()
    /**
     * A turn is heard from the window's own layout, not only from [reconfigure]: that one needs the app to forward
     * `onConfigurationChanged`, and an app that forgets would draw the upright half of a message on a phone held sideways.
     */
    private val turned = View.OnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> restampOrientation() }

    /** The activity this message is drawn over, so the SDK can take it down with it. */
    val owner: Activity get() = activity

    /** A banner: the one shape of these a person can tap through to another screen under, so it goes when they do. */
    val isBanner: Boolean get() = boxShape == "banner"

    /** The Dialog a modal or a fullscreen is in, for a test; null for a banner and a nudge. */
    internal val window: Dialog? get() = dialog

    /** The WebView the document went into, for a test. */
    internal val webView: WebView? get() = web

    /** Landscape when the window is wider than it is tall, as the platform's own configuration says. */
    private fun heldNow(): String =
        if (activity.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE) "landscape" else "portrait"

    /** The device turned: the shim rewrites the rule, so `data-tb-orientation` follows the phone rather than the draw. */
    private fun restampOrientation() {
        // Before the page says it is running there is no shim to tell: `_ready` asks again.
        if (closed || !ready) return
        val now = heldNow()
        if (now == held) return
        held = now
        val view = web ?: return
        main.post { if (!closed) view.evaluateJavascript("window.__treebarsOrientation&&window.__treebarsOrientation(${JSONObject.quote(now)})", null) }
    }

    fun show() {
        val view = try {
            WebView(activity)
        } catch (error: Throwable) {
            // No WebView provider, or one updating: the message cannot be drawn on this device right now.
            TreebarsLogger.log("in-app: no WebView to draw ${message.deliveryId}: $error")
            onFailed("webview_unavailable")
            return
        }
        web = view
        configure(view)
        val insets = insets()
        // A tablet by the platform's own line, 600dp at the narrowest side: what `data-tb-show` is matched against.
        val device = if (activity.resources.configuration.smallestScreenWidthDp >= 600) "tablet" else "mobile"
        held = heldNow()
        val document = BridgeDocument.build(html, "android", nonce, content.direction, insets, device, held)
        runCatching { activity.window.decorView.addOnLayoutChangeListener(turned) }

        val dim = tokens?.backdrop?.let { cssColor(it) } ?: Color.argb(128, 0, 0, 0)
        val frame = FrameLayout(activity).apply {
            setBackgroundColor(if (boxShape == "banner" || transparent) Color.TRANSPARENT else dim)
            visibility = View.INVISIBLE
            if (content.dismissible && boxShape != "banner" && !transparent) setOnClickListener { personClosed() }
        }
        root = frame
        val holder = FrameLayout(activity).apply {
            isClickable = true
            val surface = tokens?.surface?.let { cssColor(it) } ?: Color.WHITE
            background = GradientDrawable().apply {
                setColor(if (transparent) Color.TRANSPARENT else surface)
                cornerRadius = if (boxShape == "modal") ((tokens?.radius ?: 16.0) * density).toFloat() else 0f
            }
            clipToOutline = true
            addView(view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        }
        box = holder
        /*
         * A nudge is not a Dialog: a Dialog's window takes every touch on the screen, which is what a
         * modal wants and a nudge must not do. It joins its edge's column on the Activity's own view tree, which lets every
         * touch through to the app except on a nudge itself; a modal's Dialog window is drawn over it.
         */
        if (boxShape == "nudge") {
            root = null
            holder.visibility = View.INVISIBLE
            val column = nudgeColumn(insets)
            // The newest nearest the middle of the screen: last at the top edge, first at the bottom one.
            if (content.position == "top") column.addView(holder, nudgeParams(null)) else column.addView(holder, 0, nudgeParams(null))
            view.loadDataWithBaseURL(null, document, "text/html", "utf-8", null)
            main.postDelayed({ if (!ready && !closed) { destroy(); onFailed("render_error") } }, READY_TIMEOUT_MS)
            return
        }
        /*
         * Nor is a banner, for the same reason: a Dialog is the whole screen whatever the box inside it measures, so the
         * app under a banner could be neither tapped nor scrolled — and a banner is the one shape meant to leave it
         * usable, as the standard banner and iOS's window, which passes every touch around the box, both do. It goes
         * straight onto the decor view at its edge, only as tall as itself, and reaching under the bars, since the page
         * pads by the insets itself. Invisible until it runs, so a touch meanwhile is the app's too. Back is the app's: a
         * banner never takes focus from the app, and neither does the standard one.
         */
        if (boxShape == "banner") {
            root = holder
            holder.visibility = View.INVISIBLE
            /*
             * A Dialog is a window TalkBack notices appearing; a view on the app's own tree is not. So it is named as a
             * pane, which is read out when it turns visible — the standard banner's way, and the title the web's box is
             * labelled with. A message with no title is not announced, rather than announced by a made-up name.
             */
            if (Build.VERSION.SDK_INT >= 28) message.title?.let { holder.accessibilityPaneTitle = it }
            try {
                (activity.window.decorView as ViewGroup).addView(holder, layoutFor(null))
            } catch (error: Throwable) {
                TreebarsLogger.log("in-app: could not attach ${message.deliveryId}: $error")
                destroy()
                onFailed("render_error")
                return
            }
            view.loadDataWithBaseURL(null, document, "text/html", "utf-8", null)
            main.postDelayed({ if (!ready && !closed) { destroy(); onFailed("render_error") } }, READY_TIMEOUT_MS)
            return
        }
        frame.addView(holder, layoutFor(null))

        val created = Dialog(activity, android.R.style.Theme_Translucent_NoTitleBar).apply {
            requestWindowFeature(Window.FEATURE_NO_TITLE)
            setContentView(frame)
            setCancelable(content.dismissible)
            setOnCancelListener { personClosed() }
            window?.apply {
                setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
                setLayout(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT)
                // Drawn under the bars, so a fullscreen message is the whole window and the insets are the page's to use.
                addFlags(WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS)
            }
        }
        dialog = created
        view.loadDataWithBaseURL(null, document, "text/html", "utf-8", null)
        try {
            created.show()
        } catch (error: Throwable) {
            TreebarsLogger.log("in-app: could not attach ${message.deliveryId}: $error")
            destroy()
            onFailed("render_error")
            return
        }
        // A page that never says it is running is taken down unseen, as a render failure.
        main.postDelayed({ if (!ready && !closed) { destroy(); onFailed("render_error") } }, READY_TIMEOUT_MS)
    }

    private fun configure(view: WebView) {
        view.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = false
            allowFileAccess = false
            allowContentAccess = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            setSupportMultipleWindows(false)
            javaScriptCanOpenWindowsAutomatically = false
            mediaPlaybackRequiresUserGesture = true
        }
        view.setBackgroundColor(Color.TRANSPARENT)
        view.webViewClient = object : WebViewClient() {
            // Every navigation after the first is the page trying to leave; links come through the shim instead.
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean = true

            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                if (!closed) {
                    destroy()
                    onFailed("render_error")
                }
                return true
            }
        }
        view.addJavascriptInterface(Bridge(), "TreebarsBridge")
        runCatching { customizer?.invoke(view) }.onFailure { TreebarsLogger.log("in-app: WebView customizer threw: $it") }
    }

    /** The one thing the page may call. Kept by name in `consumer-rules.pro`, or R8 removes it from release builds. */
    inner class Bridge {
        @JavascriptInterface
        fun postMessage(text: String) {
            main.post { receive(text) }
        }
    }

    private fun receive(text: String) {
        if (closed) return
        val call = runCatching { JSONObject(text) }.getOrNull() ?: return
        if (call.optString("tb") != nonce) return
        val id = call.opt("id") as? Number ?: return
        val method = call.optString("method")
        val args = call.optJSONArray("args") ?: JSONArray()
        when {
            method == "_ready" -> {
                if (!ready) {
                    ready = true
                    // A turn while the page was loading reached no shim: say it now, if the device is held the other way.
                    restampOrientation()
                    if (boxShape == "fullscreen") reveal() else main.postDelayed({ if (height == null) resize(null); reveal() }, HEIGHT_WAIT_MS)
                }
                reply(id, BridgeDisplay.OK)
            }
            method == "resize" -> {
                val value = (args.opt(0) as? Number)?.toInt()
                if (value != null && value >= 0 && boxShape != "fullscreen") {
                    resize(value)
                    if (ready) reveal()
                }
                reply(id, BridgeDisplay.OK)
            }
            method !in TreebarsBridge.HOST_METHODS -> reply(id, BridgeDisplay.refuse("unsupported"))
            else -> display.call(method, args, { destroy() }) { reply(id, it) }
        }
    }

    private fun reply(id: Number, result: Any?) {
        val view = web ?: return
        val json = JSONObject().put("tb", nonce).put("reply", id).put("result", JSONObject.wrap(result) ?: JSONObject.NULL).toString()
        main.post { if (!closed) view.evaluateJavascript("window.__treebarsReply(${JSONObject.quote(json)})", null) }
    }

    private fun reveal() {
        if (shown || closed) return
        if (boxShape == "nudge") {
            /*
             * One that would take its edge past its share of the window waits instead: taken down unspent, and asked
             * again at the next moment — by when another may have closed. Three at a fifth each would be most of a phone.
             */
            val holder = box ?: return
            val column = holder.parent as? ViewGroup
            val others = column?.let { c -> (0 until c.childCount).map { c.getChildAt(it) }.filter { it !== holder && it.visibility == View.VISIBLE }.sumOf { it.height } } ?: 0
            if (others + (holder.layoutParams?.height ?: 0) > TreebarsBridge.NUDGE_STACK_SHARE * activity.resources.displayMetrics.heightPixels) {
                destroy()
                onFailed("no_room")
                return
            }
            holder.visibility = View.VISIBLE
        }
        shown = true
        root?.visibility = View.VISIBLE
        onShown()
        content.display?.autoDismissSeconds?.takeIf { it > 0 }?.let { seconds -> main.postDelayed({ if (!closed) personClosed() }, seconds * 1000L) }
    }

    private fun resize(value: Int?) {
        height = value
        box?.layoutParams = if (boxShape == "nudge") nudgeParams(value) else layoutFor(value)
    }

    /**
     * A nudge's edge column: one per edge on the Activity's decor view, inside the safe area — a
     * nudge is a small card, not a bar that runs under the status bar — and neither clickable nor focusable, so a touch
     * anywhere but on a nudge reaches the app.
     */
    private fun nudgeColumn(insets: BridgeInsets): LinearLayout {
        val decor = activity.window.decorView as ViewGroup
        val tag = if (content.position == "top") "treebars-nudges-top" else "treebars-nudges-bottom"
        (decor.findViewWithTag<View>(tag) as? LinearLayout)?.let { return it }
        return LinearLayout(activity).apply {
            this.tag = tag
            orientation = LinearLayout.VERTICAL
            isClickable = false
            isFocusable = false
            val top = content.position == "top"
            decor.addView(
                this,
                FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, if (top) Gravity.TOP else Gravity.BOTTOM).apply {
                    if (top) topMargin = (insets.top * density).toInt() else bottomMargin = (insets.bottom * density).toInt()
                },
            )
        }
    }

    /** Full width, as tall as the content up to a fifth of the window (`NUDGE_MAX_HEIGHT_SHARE`). */
    private fun nudgeParams(contentHeight: Int?): LinearLayout.LayoutParams {
        val cap = activity.resources.displayMetrics.heightPixels / density * TreebarsBridge.NUDGE_MAX_HEIGHT_SHARE
        val tall = contentHeight?.toFloat()?.coerceAtMost(cap.toFloat()) ?: cap.toFloat()
        return LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (tall * density).toInt())
    }

    /** The container spec for this boxShape, with the content's height where it is fitted. */
    private fun layoutFor(contentHeight: Int?): FrameLayout.LayoutParams {
        val metrics = activity.resources.displayMetrics
        val widthDp = metrics.widthPixels / density
        val heightDp = metrics.heightPixels / density
        return when (boxShape) {
            "fullscreen" -> FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
            "banner" -> {
                val cap = heightDp * TreebarsBridge.BANNER_MAX_HEIGHT_SHARE
                val tall = contentHeight?.toFloat()?.coerceAtMost(cap.toFloat()) ?: cap.toFloat()
                FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (tall * density).toInt(), if (content.position == "top") Gravity.TOP else Gravity.BOTTOM)
            }
            else -> {
                val gutter = TreebarsBridge.MODAL_GUTTER
                val wide = minOf(widthDp - gutter * 2, TreebarsBridge.MODAL_MAX_WIDTH.toFloat())
                val cap = heightDp - gutter * 2
                val tall = contentHeight?.toFloat()?.coerceAtMost(cap) ?: cap
                FrameLayout.LayoutParams((wide * density).toInt(), (tall * density).toInt(), Gravity.CENTER)
            }
        }
    }

    /** The screen's safe area in dp: the bars and the cutout, from the platform's own insets (no androidx.core here). */
    private fun insets(): BridgeInsets {
        val decor = activity.window?.decorView ?: return BridgeInsets(0, 0, 0, 0)
        val raw = decor.rootWindowInsets ?: return BridgeInsets(0, 0, 0, 0)
        // Up, never to the nearest: an inset that rounds down puts a line of the page under the bar. At 2.625 (a Pixel
        // 8's density), nearest gives 52 where the WebView's own env(safe-area-inset-top) gives 53.
        fun dp(px: Int) = kotlin.math.ceil(px / density.toDouble()).toInt()
        return if (Build.VERSION.SDK_INT >= 30) {
            val bars = raw.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            BridgeInsets(dp(bars.top), dp(bars.right), dp(bars.bottom), dp(bars.left))
        } else {
            @Suppress("DEPRECATION")
            BridgeInsets(dp(raw.systemWindowInsetTop), dp(raw.systemWindowInsetRight), dp(raw.systemWindowInsetBottom), dp(raw.systemWindowInsetLeft))
        }
    }

    /** The insets this display was drawn with, for `getContext()`. */
    fun currentInsets(): BridgeInsets = insets()

    fun isNight(): Boolean = (activity.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES

    private fun personClosed() {
        if (closed) return
        destroy()
        onPersonClosed()
    }

    /** `onConfigurationChanged`: the window changed under the message; its box is measured again. */
    fun reconfigure() {
        if (closed) return
        box?.layoutParams = if (boxShape == "nudge") nudgeParams(height) else layoutFor(height)
        restampOrientation()
    }

    /** Takes it all down, quietly: whoever called says what it meant. */
    fun destroy() {
        if (closed) return
        closed = true
        main.removeCallbacksAndMessages(null)
        runCatching { activity.window.decorView.removeOnLayoutChangeListener(turned) }
        runCatching { dialog?.dismiss() }
        // A nudge leaves its column, and the last one at an edge takes the empty column with it.
        if (boxShape == "nudge") {
            runCatching {
                val column = box?.parent as? ViewGroup
                column?.removeView(box)
                if (column != null && column.childCount == 0) (column.parent as? ViewGroup)?.removeView(column)
            }
        }
        // A banner has no Dialog to take it down with: it leaves the decor view itself.
        if (boxShape == "banner") runCatching { (box?.parent as? ViewGroup)?.removeView(box) }
        web?.let { view ->
            runCatching {
                view.removeJavascriptInterface("TreebarsBridge")
                view.stopLoading()
                view.destroy()
            }
        }
        web = null
        dialog = null
    }

    companion object {
        private const val READY_TIMEOUT_MS = 8_000L
        private const val HEIGHT_WAIT_MS = 1_000L

        private val RGBA = Regex("^rgba?\\(\\s*(\\d{1,3})\\s*,\\s*(\\d{1,3})\\s*,\\s*(\\d{1,3})\\s*(?:,\\s*([0-9.]+)\\s*)?\\)$", RegexOption.IGNORE_CASE)

        /** A token's colour as the web writes it — `#rrggbb`, `#rrggbbaa` or `rgba(r, g, b, a)` — or null otherwise. */
        fun cssColor(value: String): Int? {
            val text = value.trim()
            if (Regex("^#[0-9a-fA-F]{6}$").matches(text)) return Color.parseColor(text)
            // CSS writes the alpha last (`#0F172A99`); Android reads it first.
            if (Regex("^#[0-9a-fA-F]{8}$").matches(text)) return Color.parseColor("#${text.substring(7, 9)}${text.substring(1, 7)}")
            val match = RGBA.find(text) ?: return null
            val (r, g, b) = match.groupValues.subList(1, 4).map { it.toInt().coerceIn(0, 255) }
            val alpha = match.groupValues[4].takeIf { it.isNotEmpty() }?.toFloatOrNull() ?: 1f
            return Color.argb((alpha.coerceIn(0f, 1f) * 255).toInt(), r, g, b)
        }
    }
}

/*
 * What a navigation out of a markup body means — `readInAppHtmlAction` in the web and React Native SDKs, the contract
 * `treebars://` has always had: the two verbs, or somewhere to go. A URL that would run where it is opened is nothing.
 */
internal sealed class InAppHtmlAction {
    object Dismiss : InAppHtmlAction()
    data class Click(val index: Int) : InAppHtmlAction()
    data class Link(val url: String) : InAppHtmlAction()
}

private val RUNS_WHERE_OPENED = Regex("^(?:javascript|vbscript|data|blob|file|filesystem):", RegexOption.IGNORE_CASE)
private val CLICK_LINK = Regex("^treebars://click/(\\d+)$")

internal fun readInAppHtmlAction(url: String): InAppHtmlAction? {
    val target = url.trim()
    if (target.isEmpty() || target.startsWith("about:blank") || target == "#") return null
    if (RUNS_WHERE_OPENED.containsMatchIn(target.replace(Regex("[\\u0000- ]"), ""))) return null
    if (target == "treebars://dismiss") return InAppHtmlAction.Dismiss
    CLICK_LINK.find(target)?.let { return InAppHtmlAction.Click(it.groupValues[1].toInt()) }
    return InAppHtmlAction.Link(target)
}

/** `Locale.getDefault()` as a BCP 47 tag, for `getContext().locale`. */
internal fun localeTag(): String = Locale.getDefault().toLanguageTag()
