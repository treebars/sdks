package com.treebars.sdk

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Dialog
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.RectF
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.view.WindowInsets
import android.view.WindowInsetsAnimation
import android.view.WindowInsetsController
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

    /** What hides the elements not for this orientation; the shim writes it again when the environment changes. */
    fun orientationRule(orientation: String): String = "[data-tb-orientation]:not([data-tb-orientation~=\"$orientation\"]){display:none!important}"

    /**
     * The document a message's WebView is handed: the web SDK's document, spelled in Kotlin. A fragment is framed as the
     * preview frames it, with a viewport that never zooms into a focused field; a whole document stays one, the policy
     * and shim straight after its doctype. The environment is in it from the first byte — the insets, keyboard and text
     * scale as CSS variables in `<style id="tb-env">`, because `env(safe-area-inset-*)` is not something every Android
     * WebView answers, and the host, device, orientation, theme and states as `<html>` attributes, placed before an
     * author's own `<html>` so the parser keeps ours. The device class hides every `data-tb-show` element not listed for
     * it, and the orientation every `data-tb-orientation` element not for the way the device is held, in rules the shim
     * rewrites as the environment changes.
     */
    fun build(html: String, nonce: String, direction: String?, env: InAppEnv): String {
        val policy = "<meta http-equiv=\"Content-Security-Policy\" content=\"${escapeAttribute(TreebarsBridge.FRAME_CSP)}\">"
        val shim = "<script>${TreebarsBridge.SHIM}({\"host\":\"${env.host}\",\"nonce\":\"$nonce\"})</script>"
        val environment = "<style id=\"tb-env\">${InAppHostEnv.style(env)}</style>"
        val showClass = if (env.device == "phone") "mobile" else env.device
        val shown = "<style>[data-tb-show]:not([data-tb-show~=\"$showClass\"]){display:none!important}</style>"
        val held = "<style id=\"tb-orientation\">${orientationRule(env.orientation)}</style>"
        val dir = if (direction == "rtl" && !AUTHOR_DIRECTION.containsMatchIn(html)) " dir=\"rtl\"" else ""
        val root = "<html${InAppHostEnv.attributes(env)}$dir>"
        if (IS_DOCUMENT.containsMatchIn(html)) {
            val found = DOCTYPE.find(html)?.value
            return "${found ?: "<!doctype html>"}$root$policy$environment$shown$held$shim${html.substring(found?.length ?: 0)}"
        }
        return "<!doctype html>$root<meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1,maximum-scale=1,viewport-fit=cover\">" +
            "$policy<style>${TreebarsBridge.FRAME_RULES}</style>$environment$shown$held$shim$html"
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

    /** An app action from this message, for the app's `onAction` handlers: once its click has been recorded. */
    fun appAction(name: String, payload: Map<String, Any?>)
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

    private class PendingClick(val fields: LinkedHashMap<String, Any?>, val then: MutableList<() -> Unit>, var leads: Boolean) {
        /** Handed to the app's click listener and never recorded: an app action's payload. */
        var toldValues: Map<String, Any?>? = null
    }

    private fun names(array: JSONArray?): Set<String> = (0 until (array?.length() ?: 0)).mapNotNull { array!!.optString(it).takeIf { name -> name.isNotEmpty() } }.toSet()

    private fun receipt(): MutableMap<String, Any?> {
        val out = inAppReceipt(message)
        screen?.let { out[TreebarsBridge.KEY_SCREEN] = it }
        return out
    }

    /**
     * A dismissal from anywhere — the page, the back button, the timer — recorded once per display.
     *
     * A press still waiting in its window is recorded, and handed to the app, first: a page that closes in the same tap
     * it acts on (`customAction(…)` then `dismissMessage()`) gets its click before its dismissal, as on iOS and the web,
     * rather than from a timer that outlived the message. On iOS that timer did not outlive it, and the press was lost.
     */
    fun dismiss(element: String? = null) {
        flushClick()
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
    private fun click(fields: Map<String, Any?>, then: (() -> Unit)? = null, leads: Boolean = false, toldValues: Map<String, Any?>? = null) {
        val current = pending ?: PendingClick(LinkedHashMap<String, Any?>().apply { screen?.let { put(TreebarsBridge.KEY_SCREEN, it) } }, mutableListOf(), false).also {
            pending = it
            later(CLICK_WINDOW_MS) { flushClick() }
        }
        current.fields.putAll(fields)
        toldValues?.let { current.toldValues = it }
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
        val values = done.fields["values"] as? Map<String, Any?> ?: done.toldValues ?: emptyMap()
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
        "_layout" to { _, _, answer -> answer(OK) },

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
                val props = objectFrom(args.opt(1))
                click(
                    mapOf(TreebarsBridge.KEY_DESTINATION to screenName, "action" to "navigate", "values" to props + ("screen" to screenName)),
                    then = { sdk.appAction(TreebarsConstants.APP_ACTION_NAVIGATE, mapOf("screen" to screenName, "props" to props)) },
                )
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
        "appAction" to { args, _, answer ->
            val name = args.opt(0) as? String
            val payload = payloadFrom(args.opt(1))
            when {
                name == null || !AppActions.NAME.matches(name) -> answer(refuse("invalid_name"))
                payload == null -> answer(refuse("invalid_value"))
                payload.second > TreebarsConstants.APP_ACTION_PAYLOAD_MAX_BYTES -> answer(refuse("too_large"))
                else -> {
                    // Recorded with its name and never its payload, which can carry a person's own ids; the app's click
                    // listener hears both.
                    click(
                        mapOf("action" to "app_action", TreebarsConstants.APP_ACTION_NAME_KEY to name),
                        then = { sdk.appAction(name, payload.first) },
                        toldValues = mapOf(TreebarsConstants.APP_ACTION_NAME_KEY to name) + payload.first,
                    )
                    answer(OK)
                }
            }
        },
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
        /**
         * An app action's payload as the page sent it, with its size as JSON: nothing is empty, a JSON string is parsed,
         * and anything but an object — a list, a number, text that is not JSON — is null, which the call refuses.
         */
        fun payloadFrom(value: Any?): Pair<Map<String, Any?>, Int>? {
            val json = when (value) {
                null, JSONObject.NULL -> JSONObject()
                is JSONObject -> value
                is String -> runCatching { JSONObject(value) }.getOrNull()?.takeIf { value.trim().startsWith("{") } ?: return null
                else -> return null
            }
            return toMap(json) to json.toString().replace("\\/", "/").toByteArray(Charsets.UTF_8).size
        }

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
 * The window and the WebView for one HTML message, the Android half of the web SDK's `bridge-host.ts`.
 *
 * - **It paints nothing.** A stage message — a modal, a sheet, a full screen, a canvas — is a WebView over the whole
 *   window in a Dialog of its own: transparent, no dim, edge to edge and through the cutout, so the page draws its own
 *   scrim, card, corners and shadow and nothing of ours shows at a rounded corner. A strip — a banner, a nudge — is a
 *   transparent WebView on the Activity's own view tree at its edge, which leave the app usable, and a touch outside the
 *   container's box (`_layout`) goes on to the app.
 * - **The truth about the screen.** The environment ([InAppHostEnv]) is in the document and sent again on every change
 *   of the window's insets — a turn, the bars, the cutout — and of the keyboard, whose height comes from the IME's own
 *   insets and, from Android 11, its animation's duration, so the page moves with it. The WebView never resizes for the
 *   keyboard; the page does. Text is drawn at 100% and the system's font scale is in the environment, where the page caps
 *   it.
 * - **Hidden until laid out.** Drawn invisible and not touchable; a stage shows on its first `_layout` or a second after
 *   `_ready`, a strip once its height is known, with `shown: true`, which starts the page's own entrance. Only then is it
 *   counted as displayed ([onShown]). A WebView that cannot be made is `webview_unavailable`.
 * - **Back asks the page first.** A message with screens goes back one; otherwise a dismissible message closes. A strip's
 *   Back is the app's.
 * - **Who may call.** The page reaches Java through one interface, `TreebarsBridge.postMessage`, whose calls arrive on a
 *   binder thread: each is posted to the main looper, and taken only with this display's nonce.
 * - **The frame.** JavaScript on, storage, file and content access off, no mixed content, no second window, and every
 *   navigation after the first refused — links come through the shim, which the SDK opens. Loaded with no base URL,
 *   so the page has no origin of the app's.
 */
@SuppressLint("SetJavaScriptEnabled", "JavascriptInterface", "AddJavascriptInterface")
internal class InAppHtmlHost(
    private val activity: Activity,
    private val message: InAppMessage,
    private val content: InAppContent,
    @Suppress("UNUSED_PARAMETER") tokens: InAppTokens?,
    private val display: BridgeDisplay,
    private val onShown: () -> Unit,
    private val onFailed: (String) -> Unit,
    /** The page, the back button or the timer closed it: recorded by the display. */
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
    /** What the WebView sits in: the Dialog's whole content for a stage, the strip at its edge. */
    private var box: FrameLayout? = null
    private var ready = false
    private var shown = false
    private var closed = false
    /** A strip's height as the page reported it, its shadow room included, in dp. */
    private var height: Int? = null
    /** The container's box in the WebView, in dp, as the page last reported it (`_layout`). */
    private var container: RectF? = null
    private val density = activity.resources.displayMetrics.density
    /** The window's bars and cutout, in dp, as its insets last said. */
    private var safe: HostInsets? = null
    /** How far the keyboard reaches up from the window's bottom edge, in dp, and how long its last move took. */
    private var imeHeight = 0.0
    private var imeMs = 0.0
    /** The environment the page holds: the document's, then the last one sent. Sent again only when it differs. */
    private var sentEnv: String? = null
    private var lastEnv: InAppEnv? = null

    private val presentation = content.presentation
    /** Over the whole window (a modal, a sheet, a full screen, a canvas), or a strip at an edge (a banner, a nudge). */
    private val stage: Boolean = when (presentation?.mode) {
        "stage" -> true
        "strip" -> false
        else -> content.layout != "banner" && content.layout != "nudge"
    }
    /** A strip inside the safe area — a nudge — rather than flush with its edge. */
    private val floating: Boolean = presentation?.floating ?: (content.layout == "nudge")
    private val edge: String = presentation?.edge ?: if (content.position == "top") "top" else "bottom"
    private val dismissible: Boolean = presentation?.dismissible ?: content.dismissible
    private val backSteps: Boolean = presentation?.backSteps ?: true
    private val isNudge: Boolean get() = !stage && floating

    /** The window was laid out again — a turn, the bars, a new height — and the page is told the screen as it is now. */
    private val relaid = View.OnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> laidOut() }

    /** The activity this message is drawn over, so the SDK can take it down with it. */
    val owner: Activity get() = activity

    /** A banner: the one shape of these a person can tap through to another screen under, so it goes when they do. */
    val isBanner: Boolean get() = !stage && !floating

    /** The Dialog a stage message is in, for a test; null for a strip. */
    internal val window: Dialog? get() = dialog

    /** The WebView the document went into, for a test. */
    internal val webView: WebView? get() = web

    /** The view the WebView sits in, for a test: the Dialog's content for a stage, the strip itself otherwise. */
    internal val holder: FrameLayout? get() = box

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
        safe = decorInsets()
        val first = environment()
        sentEnv = InAppHostEnv.json(first)
        lastEnv = first
        val document = BridgeDocument.build(html, nonce, content.direction, first)
        runCatching { activity.window.decorView.addOnLayoutChangeListener(relaid) }

        if (!stage) {
            showStrip(view, document)
            return
        }
        val frame = FrameLayout(activity).apply {
            setBackgroundColor(Color.TRANSPARENT)
            // Drawn, so the page lays itself out and says so, but not seen until it has.
            alpha = 0f
            addView(view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            // Every change of the window's insets — bars, cutout, keyboard — reaches the page; none pads the WebView.
            setOnApplyWindowInsetsListener { _, insets ->
                readInsets(insets)
                laidOut()
                insets
            }
            if (Build.VERSION.SDK_INT >= 30) {
                // The keyboard's own duration, known before its end state is dispatched, so the page moves in step.
                setWindowInsetsAnimationCallback(object : WindowInsetsAnimation.Callback(DISPATCH_MODE_CONTINUE_ON_SUBTREE) {
                    override fun onPrepare(animation: WindowInsetsAnimation) {
                        if (animation.typeMask and WindowInsets.Type.ime() != 0) imeMs = animation.durationMillis.toDouble()
                    }

                    override fun onProgress(insets: WindowInsets, running: MutableList<WindowInsetsAnimation>): WindowInsets = insets
                })
            }
            addOnLayoutChangeListener(relaid)
        }
        box = frame

        val created = object : Dialog(activity, android.R.style.Theme_Translucent_NoTitleBar) {
            // Called by the system's Back, the predictive one included (the Dialog registers it).
            @Deprecated("Back is asked through the page first")
            @Suppress("OVERRIDE_DEPRECATION")
            override fun onBackPressed() {
                back()
            }
        }.apply {
            requestWindowFeature(Window.FEATURE_NO_TITLE)
            setContentView(frame)
            // Back is the host's to decide (the page first), never the Dialog's own cancel.
            setCancelable(false)
            setCanceledOnTouchOutside(false)
            window?.let { edgeToEdge(it) }
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

    /**
     * The Dialog's window: transparent and undimmed, under the status and navigation bars and through the cutout, with
     * the keyboard reported as insets rather than resizing the WebView. Until the page is revealed it neither takes a
     * touch nor holds focus, so the app under a page that is still loading answers as if nothing were there.
     */
    @Suppress("DEPRECATION")
    private fun edgeToEdge(window: Window) {
        window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        window.setLayout(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT)
        window.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
        window.setDimAmount(0f)
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        window.addFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE)
        window.clearFlags(WindowManager.LayoutParams.FLAG_TRANSLUCENT_STATUS or WindowManager.LayoutParams.FLAG_TRANSLUCENT_NAVIGATION)
        window.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS)
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= 29) {
            // Or the system lays a scrim of its own behind a transparent bar.
            window.isStatusBarContrastEnforced = false
            window.isNavigationBarContrastEnforced = false
        }
        val lightStatus = when (presentation?.statusBar) {
            "dark" -> true
            "light" -> false
            else -> appHasLightBars(status = true)
        }
        val lightNavigation = appHasLightBars(status = false)
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false)
            window.attributes = window.attributes.apply { layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS }
            window.insetsController?.setSystemBarsAppearance(
                (if (lightStatus) WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS else 0) or
                    (if (lightNavigation) WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS else 0),
                WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
            )
        } else {
            if (Build.VERSION.SDK_INT >= 28) {
                window.attributes = window.attributes.apply { layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES }
            }
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or (if (lightStatus) View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR else 0) or
                (if (lightNavigation && Build.VERSION.SDK_INT >= 26) View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR else 0)
        }
    }

    /** Whether the app draws dark icons on its own status (or navigation) bar: what a message that says nothing keeps. */
    @Suppress("DEPRECATION")
    private fun appHasLightBars(status: Boolean): Boolean {
        val window = activity.window ?: return false
        return if (Build.VERSION.SDK_INT >= 30) {
            val flag = if (status) WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS else WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS
            ((window.insetsController?.systemBarsAppearance ?: 0) and flag) != 0
        } else {
            val flag = if (status) View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR else if (Build.VERSION.SDK_INT >= 26) View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR else 0
            flag != 0 && (window.decorView.systemUiVisibility and flag) != 0
        }
    }

    /**
     * A banner or a nudge, on the Activity's own view tree rather than in a Dialog: a Dialog's window takes every touch on
     * the screen, which is what a stage wants and a strip must not do. A banner goes onto the decor view at its edge,
     * reaching under the bars, since the page pads by the insets itself; a nudge joins its edge's column inside the safe
     * area. The strip itself hands every touch outside the container's box to the app ([StripFrame]). Back is the app's.
     */
    private fun showStrip(view: WebView, document: String) {
        val holder = StripFrame().apply {
            setBackgroundColor(Color.TRANSPARENT)
            alpha = 0f
            addView(view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        }
        box = holder
        /*
         * A Dialog is a window TalkBack notices appearing; a view on the app's own tree is not. So it is named as a pane,
         * which is read out when it turns visible — the title the web's box is labelled with. A message with no title is
         * not announced, rather than announced by a made-up name.
         */
        if (Build.VERSION.SDK_INT >= 28) message.title?.let { holder.accessibilityPaneTitle = it }
        try {
            if (isNudge) {
                val column = nudgeColumn()
                // The newest nearest the middle of the screen: last at the top edge, first at the bottom one.
                if (edge == "top") column.addView(holder, nudgeParams()) else column.addView(holder, 0, nudgeParams())
            } else {
                (activity.window.decorView as ViewGroup).addView(holder, bannerParams())
            }
        } catch (error: Throwable) {
            TreebarsLogger.log("in-app: could not attach ${message.deliveryId}: $error")
            destroy()
            onFailed("render_error")
            return
        }
        view.loadDataWithBaseURL(null, document, "text/html", "utf-8", null)
        main.postDelayed({ if (!ready && !closed) { destroy(); onFailed("render_error") } }, READY_TIMEOUT_MS)
    }

    /** A strip's holder: transparent, and passing every touch and hover outside the container's box to the app under it. */
    private inner class StripFrame : FrameLayout(activity) {
        override fun dispatchTouchEvent(event: MotionEvent): Boolean {
            // Refusing the press refuses the gesture: the decor view hands it, and what follows it, to the app's views.
            if (event.actionMasked == MotionEvent.ACTION_DOWN && !takes(event.x, event.y)) return false
            return super.dispatchTouchEvent(event)
        }

        override fun dispatchHoverEvent(event: MotionEvent): Boolean {
            // TalkBack's explore-by-touch arrives as hover: outside the container it reads the app, not an empty strip.
            if (!takes(event.x, event.y)) return false
            return super.dispatchHoverEvent(event)
        }
    }

    /** Whether a touch at this point of the strip, in pixels, is the message's: on its container once it is shown. */
    private fun takes(x: Float, y: Float): Boolean {
        if (!shown || closed) return false
        val rect = container ?: return true
        return rect.contains(x / density, y / density)
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
            // The page scales its own text by the font scale in the environment, capped where its layout survives.
            textZoom = 100
        }
        view.setBackgroundColor(Color.TRANSPARENT)
        view.overScrollMode = View.OVER_SCROLL_NEVER
        view.isVerticalScrollBarEnabled = false
        view.isHorizontalScrollBarEnabled = false
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
                    // A turn, a keyboard or a new size while the page was loading reached no shim: said now.
                    laidOut()
                    main.postDelayed({ reveal() }, LAYOUT_WAIT_MS)
                }
                reply(id, BridgeDisplay.OK)
            }
            method == "_layout" -> {
                val rect = (args.opt(0) as? JSONObject)?.optJSONObject("container")
                val values = rect?.let { listOf("x", "y", "w", "h").map { key -> (it.opt(key) as? Number)?.toFloat() } }
                if (values != null && values.all { it != null && it.isFinite() } && values[2]!! >= 0 && values[3]!! >= 0) {
                    val (x, y, w, h) = values.map { it!! }
                    container = RectF(x, y, x + w, y + h)
                    // A stage is laid out once the page says where its container is.
                    if (stage && ready) reveal()
                }
                reply(id, BridgeDisplay.OK)
            }
            method == "resize" -> {
                val value = (args.opt(0) as? Number)?.toInt()
                if (value != null && value >= 0 && !stage) {
                    height = value
                    relayout()
                    if (ready) reveal()
                }
                reply(id, BridgeDisplay.OK)
            }
            method !in TreebarsBridge.HOST_METHODS -> reply(id, BridgeDisplay.refuse("unsupported"))
            else -> display.call(method, args, { destroy() }) { reply(id, it) }
        }
    }

    private fun reply(id: Number, result: Any?) {
        val json = JSONObject().put("tb", nonce).put("reply", id).put("result", JSONObject.wrap(result) ?: JSONObject.NULL).toString()
        evaluate("window.__treebarsReply(${JSONObject.quote(json)})")
    }

    private fun evaluate(script: String, answer: ((String?) -> Unit)? = null) {
        val view = web ?: return
        main.post { if (!closed) view.evaluateJavascript(script, answer) }
    }

    /** The window this message lies in, in dp: the Dialog's content once laid out, the Activity's window before. */
    private fun windowDp(): Pair<Double, Double> {
        val drawn = if (stage) box else activity.window?.decorView
        val laid = drawn ?: activity.window?.decorView
        if (laid != null && laid.width > 0 && laid.height > 0) return laid.width / density.toDouble() to laid.height / density.toDouble()
        val metrics = activity.resources.displayMetrics
        return metrics.widthPixels / density.toDouble() to metrics.heightPixels / density.toDouble()
    }

    /** Where a strip's WebView is in the window, in dp: as laid out once it has been, as it will be before. */
    private fun stripFrame(width: Double, height: Double): HostRect {
        val holder = box
        val parent = holder?.parent as? View
        if (holder != null && parent != null && holder.width > 0 && holder.height > 0) {
            val (x, y) = if (parent === activity.window?.decorView) 0 to 0 else parent.left to parent.top
            return HostRect((x + holder.left) / density.toDouble(), (y + holder.top) / density.toDouble(), holder.width / density.toDouble(), holder.height / density.toDouble())
        }
        return InAppHostEnv.stripBox(width, height, safe ?: HostInsets.ZERO, edge, floating, this.height?.toDouble())
    }

    private fun environment(): InAppEnv {
        val (width, height) = windowDp()
        val configuration = activity.resources.configuration
        return InAppHostEnv.env(
            host = "android",
            // A tablet by the platform's own line, 600dp at the narrowest side.
            device = if (configuration.smallestScreenWidthDp >= 600) "tablet" else "phone",
            theme = if (isNight()) "dark" else "light",
            textScale = configuration.fontScale.toDouble(),
            shown = shown,
            width = width,
            height = height,
            safe = safe ?: HostInsets.ZERO,
            frame = if (stage) null else stripFrame(width, height),
            keyboardHeight = imeHeight,
            keyboardMs = imeMs,
        )
    }

    /** The window was laid out again, or its insets changed: the page is told the screen as it is now. */
    private fun laidOut() {
        if (closed) return
        if (!stage) {
            safe = decorInsets()
            imeHeight = decorIme()
        }
        val env = environment()
        lastEnv = env
        // Before the page says it is running there is no shim to tell: `_ready` sends whatever changed meanwhile.
        if (!ready) return
        val text = InAppHostEnv.json(env)
        if (text == sentEnv) return
        sentEnv = text
        evaluate("window.__treebarsEnv&&window.__treebarsEnv(${JSONObject.quote(text)})")
    }

    /** A stage's own insets: its bars and cutout, and the keyboard's height above the navigation bar. */
    @Suppress("DEPRECATION")
    private fun readInsets(insets: WindowInsets) {
        fun dp(px: Int) = px / density.toDouble()
        if (Build.VERSION.SDK_INT >= 30) {
            val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            safe = HostInsets(dp(bars.top), dp(bars.right), dp(bars.bottom), dp(bars.left))
            imeHeight = dp(insets.getInsets(WindowInsets.Type.ime()).bottom)
        } else {
            // Below 11 the keyboard is the part of the bottom inset the stable one does not account for.
            val cutout = if (Build.VERSION.SDK_INT >= 28) insets.displayCutout else null
            safe = HostInsets(
                dp(maxOf(insets.systemWindowInsetTop, cutout?.safeInsetTop ?: 0)),
                dp(maxOf(insets.systemWindowInsetRight, cutout?.safeInsetRight ?: 0)),
                dp(maxOf(insets.stableInsetBottom, cutout?.safeInsetBottom ?: 0)),
                dp(maxOf(insets.systemWindowInsetLeft, cutout?.safeInsetLeft ?: 0)),
            )
            imeHeight = dp(maxOf(0, insets.systemWindowInsetBottom - insets.stableInsetBottom))
        }
    }

    /** The Activity's window's bars and cutout in dp, from the platform's own insets (no androidx.core here). */
    @Suppress("DEPRECATION")
    private fun decorInsets(): HostInsets {
        val raw = activity.window?.decorView?.rootWindowInsets ?: return safe ?: HostInsets.ZERO
        fun dp(px: Int) = px / density.toDouble()
        return if (Build.VERSION.SDK_INT >= 30) {
            val bars = raw.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            HostInsets(dp(bars.top), dp(bars.right), dp(bars.bottom), dp(bars.left))
        } else {
            HostInsets(dp(raw.systemWindowInsetTop), dp(raw.systemWindowInsetRight), dp(raw.stableInsetBottom), dp(raw.systemWindowInsetLeft))
        }
    }

    /** The app's keyboard over the Activity's window, in dp: what a bottom strip may be partly under. */
    @Suppress("DEPRECATION")
    private fun decorIme(): Double {
        val raw = activity.window?.decorView?.rootWindowInsets ?: return 0.0
        val px = if (Build.VERSION.SDK_INT >= 30) raw.getInsets(WindowInsets.Type.ime()).bottom else maxOf(0, raw.systemWindowInsetBottom - raw.stableInsetBottom)
        return px / density.toDouble()
    }

    private fun reveal() {
        if (shown || closed) return
        val holder = box ?: return
        if (isNudge) {
            /*
             * One that would take its edge past its share of the window waits instead: taken down unspent, and asked
             * again at the next moment — by when another may have closed. Three at a fifth each would be most of a phone.
             */
            val column = holder.parent as? ViewGroup
            val others = column?.let { c -> (0 until c.childCount).map { c.getChildAt(it) }.filter { it !== holder && it.alpha > 0f }.sumOf { it.height } } ?: 0
            if (others + (holder.layoutParams?.height ?: 0) > TreebarsBridge.NUDGE_STACK_SHARE * windowDp().second * density) {
                destroy()
                onFailed("no_room")
                return
            }
        }
        shown = true
        // `shown` in the environment starts the page's own entrance; nothing of ours fades.
        laidOut()
        holder.alpha = 1f
        dialog?.window?.clearFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE)
        onShown()
        content.display?.autoDismissSeconds?.takeIf { it > 0 }?.let { seconds -> main.postDelayed({ if (!closed) personClosed() }, seconds * 1000L) }
    }

    /**
     * Back, on a stage: the page goes back a screen if it has one to go back to, and otherwise a dismissible message
     * closes. One that cannot be dismissed stays, with its own way out.
     */
    private fun back() {
        if (closed || !shown) return
        if (!backSteps) {
            if (dismissible) personClosed()
            return
        }
        evaluate("window.__treebarsBack?window.__treebarsBack():false") { answer ->
            if (answer != "true" && !closed && dismissible) personClosed()
        }
    }

    /** The strip's box, again: a new height from the page, or a window that changed under it. */
    private fun relayout() {
        val holder = box ?: return
        if (stage) return
        holder.layoutParams = if (isNudge) nudgeParams() else bannerParams()
        (holder.parent as? View)?.let { column -> if (isNudge) nudgeColumnMargins(column) }
    }

    /**
     * A nudge's edge column: one per edge on the Activity's decor view, inside the safe area on every side — a nudge is a
     * small card, not a bar that runs under the status bar — and neither clickable nor focusable, so a touch anywhere but
     * on a nudge's container reaches the app.
     */
    private fun nudgeColumn(): LinearLayout {
        val decor = activity.window.decorView as ViewGroup
        val tag = if (edge == "top") "treebars-nudges-top" else "treebars-nudges-bottom"
        (decor.findViewWithTag<View>(tag) as? LinearLayout)?.let { return it }
        return LinearLayout(activity).apply {
            this.tag = tag
            orientation = LinearLayout.VERTICAL
            isClickable = false
            isFocusable = false
            decor.addView(this, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, if (edge == "top") Gravity.TOP else Gravity.BOTTOM))
            nudgeColumnMargins(this)
        }
    }

    /** The column's place: [InAppHostEnv.stripBox]'s for a nudge, inside the insets on every side. */
    private fun nudgeColumnMargins(column: View) {
        val params = column.layoutParams as? FrameLayout.LayoutParams ?: return
        val insets = safe ?: HostInsets.ZERO
        val (width, height) = windowDp()
        val box = InAppHostEnv.stripBox(width, height, insets, edge, true, 0.0)
        val left = (box.x * density).toInt()
        val right = ((width - box.x - box.w) * density).toInt()
        val top = if (edge == "top") (insets.top * density).toInt() else 0
        val bottom = if (edge == "top") 0 else (insets.bottom * density).toInt()
        if (params.leftMargin == left && params.rightMargin == right && params.topMargin == top && params.bottomMargin == bottom) return
        params.setMargins(left, top, right, bottom)
        column.layoutParams = params
    }

    /** Full width, as tall as the page says up to a fifth of the window. */
    private fun nudgeParams(): LinearLayout.LayoutParams {
        val (width, windowHeight) = windowDp()
        val box = InAppHostEnv.stripBox(width, windowHeight, safe ?: HostInsets.ZERO, edge, true, height?.toDouble())
        return LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (box.h * density).toInt())
    }

    /** Edge to edge at its edge, under the bars, as tall as the page says up to 30% of the window. */
    private fun bannerParams(): FrameLayout.LayoutParams {
        val (width, windowHeight) = windowDp()
        val box = InAppHostEnv.stripBox(width, windowHeight, safe ?: HostInsets.ZERO, edge, false, height?.toDouble())
        return FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (box.h * density).toInt(), if (edge == "top") Gravity.TOP else Gravity.BOTTOM)
    }

    /** The insets the page holds now, for `getContext()`. */
    fun currentInsets(): BridgeInsets = lastEnv?.safe ?: environment().safe

    fun isNight(): Boolean = (activity.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES

    private fun personClosed() {
        if (closed) return
        destroy()
        onPersonClosed()
    }

    /** `onConfigurationChanged`: the window changed under the message; a strip is measured again and the page told. */
    fun reconfigure() {
        if (closed) return
        relayout()
        laidOut()
    }

    /** Takes it all down, quietly: whoever called says what it meant. */
    fun destroy() {
        if (closed) return
        closed = true
        main.removeCallbacksAndMessages(null)
        runCatching { activity.window.decorView.removeOnLayoutChangeListener(relaid) }
        runCatching { dialog?.dismiss() }
        // A nudge leaves its column, and the last one at an edge takes the empty column with it.
        if (isNudge) {
            runCatching {
                val column = box?.parent as? ViewGroup
                column?.removeView(box)
                if (column != null && column.childCount == 0) (column.parent as? ViewGroup)?.removeView(column)
            }
        }
        // A banner has no Dialog to take it down with: it leaves the decor view itself.
        if (isBanner) runCatching { (box?.parent as? ViewGroup)?.removeView(box) }
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
        /** How long a shown page has to lay itself out (a stage) or measure itself (a strip) before it is shown anyway. */
        private const val LAYOUT_WAIT_MS = 1_000L
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
