package com.treebars.sdk

import android.content.Context
import com.treebars.sdk.generated.TreebarsBridge
import com.treebars.sdk.generated.TreebarsConstants
import org.json.JSONArray
import org.json.JSONObject

/*
 * In-app messages on the device.
 *
 * Most of this SDK posts events and forgets them; this pulls a queue, holds it, and decides
 * locally when each message may be shown — which the server cannot decide for a screen view
 * or a custom event, because only the device knows those happened.
 *
 * The rules are the same as the iOS and web SDKs', deliberately: a message capped at three a
 * day has to mean the same thing on every platform, and a divergence would go unnoticed
 * until somebody compared two screenshots.
 */

/**
 * An inbox row drawn as a card. `basic` is an icon beside the words, `illustration` a wide image above them;
 * `actionValue` is where a tap goes, `imageAlt` is read aloud for the image, `pinned` keeps it first, `showFrom` hides it
 * until then, `category` groups cards into a centre's tabs.
 */
data class InAppCard(
    val template: String,
    val iconUrl: String?,
    val imageAlt: String?,
    val actionType: String?,
    val actionValue: String?,
    val pinned: Boolean,
    val showFrom: Long?,
    val category: String?,
    /** A button on the card apart from a tap on it: its words, and where it goes. */
    val ctaLabel: String? = null,
    val ctaType: String? = null,
    val ctaValue: String? = null,
    /** Gone this many days after it was first seen; the server leaves it out of the next sync after that. */
    val expiresAfterSeenDays: Int? = null,
)

/**
 * What was pressed in a message, as the app's click listener receives it: the button's action —
 * `url`, `deep_link`, `track_event`, `set_attribute`, `custom`, or `click` for a markup body's `treebars://click/<n>` —
 * and its values: a `custom` button's keys, or `{ "value": … }` for the rest. The button itself rides along.
 */
data class InAppClickAction(
    val type: String,
    val values: Map<String, String>,
    val button: InAppButton,
)

/**
 * Named as common engagement SDKs name it on Android, so a migration keeps its call sites: every
 * press in a message is handed to the app after it is recorded, and a `custom` button's keys arrive only here.
 * Return true when the app handled it.
 */
fun interface ClickActionListener {
    fun onClick(action: InAppClickAction, message: InAppMessage): Boolean
}

/** Named as common engagement SDKs name it: a message was shown, or went away. */
interface InAppLifeCycleListener {
    fun onShown(message: InAppMessage) {}
    fun onDismiss(message: InAppMessage) {}
}

/**
 * A message marked self-handled is the app's to draw, and arrives here rather
 * than at the renderer; the app then reports `selfHandledShown`, `selfHandledClicked` and `selfHandledDismissed`. Null
 * when nothing is eligible — `getSelfHandledInApp` answers that way.
 */
fun interface SelfHandledListener {
    fun onSelfHandledAvailable(message: InAppMessage?)
}

/** Every self-handled message eligible now (`getSelfHandledInApps`). */
fun interface SelfHandledListListener {
    fun onSelfHandledAvailable(messages: List<InAppMessage>)
}

data class InAppTokens(
    val accent: String,
    val onAccent: String,
    val surface: String,
    val onSurface: String,
    val onSurfaceMuted: String,
    val backdrop: String,
    val radius: Double,
    val fontFamily: String,
    val buttonShape: String,
)

/**
 * A button in a message. Its `action` is `dismiss`, `deep_link`, `url`, `track_event` (`eventName`), `set_attribute`
 * (`key` and `value`, on the signed-in person), `custom` (`data`, handed to the app's action handler), one of the
 * device actions `call`, `copy`, `share` and `store_review`, or `click` for a press in a markup body.
 */
data class InAppButton(
    val label: String,
    val action: String,
    val value: String?,
    val eventName: String? = null,
    val key: String? = null,
    val data: Map<String, String>? = null,
    /**
     * Which element this is, counting from 1: a typed button's position, or the `<n>` of a markup body's
     * `treebars://click/<n>`. Reported on `in_app_clicked` as `button_index`, so a message with two buttons says which
     * one was pressed.
     */
    val index: Int? = null,
)

/**
 * What every in-app receipt carries: the delivery, and the campaign when there is one.
 *
 * One function for `in_app_displayed`, `in_app_failed`, `in_app_form_submitted`, `in_app_clicked` and
 * `in_app_dismissed` alike, so a report of clicks by campaign reads as whole as one of displays — and the same
 * function in Swift and on the web.
 */
internal fun inAppReceipt(message: InAppMessage): MutableMap<String, Any?> = mutableMapOf<String, Any?>(
    TreebarsConstants.DELIVERY_ID_KEY to message.deliveryId,
).apply { message.campaignId?.let { put(TreebarsConstants.CAMPAIGN_ID_KEY, it) } }

/** The actions whose value is a place a person is sent. Only those are a click's `destination`. */
private val DESTINATION_ACTIONS = setOf("url", "deep_link")

/**
 * `in_app_clicked`'s properties. `destination` only for a button that sends somebody somewhere: a "set a trait"
 * button's value is the trait's value, and reporting `yes` as where the click went would pollute every
 * click-by-destination report — and an app reading it back could route `yes` as a link.
 */
internal fun inAppClickProperties(message: InAppMessage, button: InAppButton): Map<String, Any?> =
    inAppReceipt(message).apply {
        val value = button.value
        if (button.action in DESTINATION_ACTIONS && !value.isNullOrEmpty()) put("destination", value)
        // What was pressed: the element's number, and a typed button's label when it has one.
        button.index?.let { put(TreebarsConstants.IN_APP_BUTTON_INDEX_KEY, it) }
        button.label.takeIf { it.isNotEmpty() }?.let { put(TreebarsConstants.IN_APP_BUTTON_LABEL_KEY, it) }
    }

/**
 * The actions a call to action takes: every one a renderer draws as a button that does something and closes — push's
 * device actions among them.
 */
private val SPENDING_ACTIONS = setOf("url", "deep_link", "track_event", "set_attribute", "custom", "call", "copy", "share", "store_review")

/**
 * Whether a button press ends the message on this device, as a dismissal does.
 *
 * A press whose action does something — a link, a page, an event, a trait, the app's keys — marks the message done and
 * frees the screen. A call to action that only closed the overlay would spend nothing: unless the trigger was
 * `immediate` or `max_displays` was set, the next matching event would draw the same message again, and the screen
 * would stay claimed until a dismissal released it.
 *
 * `dismiss` is not one: its own dismissal follows and does both. Nor is an action this SDK does not know, which is
 * what a React Native markup body's `treebars://click/<n>` sends (`click`): that is "record that this was pressed" on
 * a message still on screen, and freeing the screen under it would let a second overlay draw on top.
 */
/*
 * The SDK's own reports that the app is going away, which are never a moment to draw. An `immediate` trigger matches
 * every event, and a message drawn on `app_background` would land over an app that has just left the screen. This SDK
 * records lifecycle events past `considerInApp`, so here the guard is for a caller who tracks one by name — the rule is
 * the same in all three SDKs. `session_end` is history, sent for a session that has already ended.
 */
internal fun isLeavingEvent(eventName: String): Boolean =
    eventName == Treebars.EVENT_APP_BACKGROUND || eventName == Treebars.EVENT_SESSION_END

internal fun inAppClickEndsMessage(button: InAppButton): Boolean = button.action in SPENDING_ACTIONS

/**
 * What a press hands the app's click listener: a `custom` button's keys, and for every other button its `value` — with a
 * link's key-values beside it, never in place of it, so an app routing on `values["value"]` still finds the link when
 * somebody adds a UTM. The web's `clickValues` and Swift's, the same rule.
 */
internal fun clickValues(button: InAppButton): Map<String, String> {
    if (button.action == "custom") return button.data ?: button.value?.let { mapOf("value" to it) } ?: emptyMap()
    return (button.data ?: emptyMap()) + (button.value?.let { mapOf("value" to it) } ?: emptyMap())
}

/**
 * When and how a message may be drawn beyond its trigger. An app reads `delay` and treats the web's other
 * on-site moments as at once; page and session rules are the web's alone. `autoDismissSeconds`, and a form, a
 * carousel or a countdown in [InAppMessage.raw], are the renderer's to draw — the app's own renderer, on Android.
 */
data class InAppDisplay(
    val on: String?,
    val delaySeconds: Int?,
    val contexts: List<String>,
    val priority: Int,
    val autoDismissSeconds: Int?,
    val selfHandled: Boolean,
    /** Shown only to people the app can still ask for push: see [pushAskableBlock]. */
    val onlyWhenPushAskable: Boolean = false,
)

/**
 * A nudge: drawn in a slot of its own beside the one a modal takes, at most
 * `TreebarsBridge.NUDGE_MAX_ON_SCREEN` on screen, and outside the channel's caps — it neither waits on them nor spends
 * them, so a nudge never holds back the modal the caps were set for. Its own `max_displays`, expiry and dismissal end it.
 */
internal fun isNudge(message: InAppMessage): Boolean = message.content?.layout == "nudge"

/**
 * The nudges on screen, by delivery: the modal slot's [PresentationSlot] for up to three at once.
 * Claimed and released under one lock for the reason that slot is — two considerations can run on two threads.
 */
internal class NudgeSlots(private val capacity: Int) {
    private val held = linkedSetOf<String>()
    /**
     * Of those, the ones drawn and not yet on screen: a nudge is counted when shown, and three drawn by one
     * event are three before any of them reports, so the nudge caps count these too. Every release clears one.
     */
    private val unshown = mutableSetOf<String>()

    @Synchronized
    fun claim(deliveryId: String): Boolean {
        if (deliveryId in held || held.size >= capacity) return false
        held.add(deliveryId)
        unshown.add(deliveryId)
        return true
    }

    @Synchronized
    fun shown(deliveryId: String) {
        unshown.remove(deliveryId)
    }

    @Synchronized
    fun inFlight(): Int = unshown.size

    @Synchronized
    fun release(deliveryId: String) {
        held.remove(deliveryId)
        unshown.remove(deliveryId)
    }

    @Synchronized
    fun holds(deliveryId: String): Boolean = deliveryId in held

    @Synchronized
    fun hasRoom(): Boolean = held.size < capacity

    @Synchronized
    fun clear(): List<String> = held.toList().also {
        held.clear()
        unshown.clear()
    }
}

/**
 * Where the app said nudges may appear (`showNudge`): the screen in front then — the Activity, and the
 * screen name a single-Activity app such as React Native reports — until either changes. A nudge is shown only there.
 */
internal data class NudgePlace(val activity: Int, val screen: String?)

/** The place an Activity and a screen name make: what [Treebars.showNudge] records and what the screen in front is. */
internal fun nudgePlaceFor(activity: android.app.Activity?, screen: String?): NudgePlace = NudgePlace(System.identityHashCode(activity), screen)

/**
 * Why a message shown only to people who can still be asked for push is held back from this person, or null.
 * [status] is the shared vocabulary every SDK maps its platform to (`androidPushStatus` here);
 * which of its words can still be asked is `PUSH_ASKABLE_STATUSES`, generated from one list for all three SDKs. Held
 * back, never spent: permission can be revoked in Settings, so the next look asks again.
 */
internal fun pushAskableBlock(display: InAppDisplay?, status: String?): String? =
    if (display?.onlyWhenPushAskable == true && status !in TreebarsConstants.PUSH_ASKABLE_STATUSES) "push_answered" else null

/**
 * Android's push state in the shared vocabulary. Below 13 there is no prompt: notifications start on, and off means
 * somebody turned them off in Settings, where only they can turn them back. From 13, a refusal the OS will still ask
 * after is the rationale case; never asked and refused for good look the same to Android — the rationale is false in
 * both — so this SDK remembers that it asked ([TreebarsPush.requestPermission]). An app that asked with its own code
 * reads as never asked here, and its primer's button then asks nothing and closes.
 */
internal fun androidPushStatus(sdkInt: Int, enabled: Boolean, asked: Boolean, rationale: Boolean): String = when {
    enabled -> "authorized"
    sdkInt < 33 -> "denied"
    rationale -> "denied_askable"
    asked -> "denied"
    else -> "not_determined"
}

/**
 * One clause of an `event` trigger's filter. `value` is whatever the JSON held.
 *
 * `type` and `source` are kept as the row carried them: absent is null, and anything but a string —
 * `null` included — is `""`, a tag no reader knows, which answers false under every operator.
 * `malformed` stands for an element this SDK could not read as a row at all: it fails the WHOLE trigger,
 * as the server reads it.
 */
data class InAppFilter(
    val key: String,
    val op: String,
    val value: Any?,
    val type: String? = null,
    val source: String? = null,
    val malformed: Boolean = false,
) {
    internal companion object {
        /** The element that stands for one this SDK could not read. */
        val MALFORMED = InAppFilter(key = "", op = "", value = null, malformed = true)
    }
}

data class InAppTrigger(
    val kind: String,
    val screenName: String?,
    val eventName: String?,
    /**
     * Empty means "no filter", which is not the same as "no match".
     *
     * Evaluated here as on every other SDK: a trigger matched on the event name alone would
     * show its message to everybody who fired the event, people who do not qualify included,
     * which is the failure the matcher's own comment calls worse than showing it to nobody.
     */
    val filters: List<InAppFilter> = emptyList(),
    /** `push_click` only: the campaign whose push opened the app, or null for any push. */
    val campaignId: String? = null,
)

data class InAppContent(
    val surface: String,
    val layout: String,
    val html: String?,
    /**
     * Who writes the body — `standard` (the typed fields, drawn by the app's renderer) or `html` (markup, drawn by this
     * SDK in a WebView with the `treebars` bridge). A legacy `layout: "html"` is `html`.
     */
    val bodyMode: String = "standard",
    /** `fullscreen` only: nothing of the SDK's behind the markup, so a page that draws its own overlay shows the app. */
    val transparent: Boolean = false,
    /** A body over 64 KiB, by its SHA-256, until the sync's second request fetched it into [html]. */
    val htmlRef: String? = null,
    val position: String?,
    val dismissible: Boolean,
    val buttons: List<InAppButton>,
    val trigger: InAppTrigger,
    val maxDisplays: Int?,
    /** Drawn however recently another message was: the channel's minimum gap does not apply. */
    val ignoreMinGap: Boolean = false,
    /** When and how it may be drawn beyond its trigger; null when the message sets none. */
    val display: InAppDisplay? = null,
    /** An inbox row drawn as a card; null when it is not one. */
    val card: InAppCard? = null,
    /**
     * Which way the message's language reads — `rtl` or `ltr` — as the server resolved it from the
     * locale it rendered, passed through untouched for the app's renderer: Arabic copy
     * drawn left-aligned reads as broken. Null on a message from a server older than the field,
     * which a renderer draws as it always has.
     */
    val direction: String? = null,
)

data class InAppMessage(
    val deliveryId: String,
    val campaignId: String?,
    val title: String?,
    val body: String?,
    val imageUrl: String?,
    val content: InAppContent?,
    val expiresAt: Long?,
    /** This message's own resolved tokens; null on one queued before they existed. */
    val style: InAppTokens?,
    /** Kept so the queue can be persisted without re-encoding what the server sent. */
    val raw: JSONObject,
    /**
     * A test send: drawn past every frequency cap — day, session, trigger kind and minimum gap — because a test held
     * back by a cap would read as a broken message. Expiry and "done" still apply.
     */
    val test: Boolean = false,
    /** Its tokens in dark mode, when the message has a dark variant; null otherwise. */
    val styleDark: InAppTokens? = null,
)

data class InAppPolicy(
    val maxPerDay: Int?,
    val minGapSeconds: Int?,
    /** What every one of this person's devices has shown today, as of the last sync. */
    val messagesShownToday: Int,
    val lastShownAt: Long?,
    /** Draws in one session, counted on this device. Null for no cap. */
    val maxPerSession: Int? = null,
    /** Distinct messages a day per trigger kind — session_start, screen_view, event — in this device's day. */
    val triggerMaxPerDay: Map<String, Int> = emptyMap(),
    /** Nudges' own, counted on this device outside every cap above: a session's, and a gap. */
    val nudgeMaxPerSession: Int? = null,
    val nudgeMinGapSeconds: Int? = null,
)

/** The trigger kinds a day cap can be set for. `immediate` is a send-now, and has none. */
private val CAPPED_TRIGGER_KINDS = setOf("session_start", "screen_view", "event")

/** This device's local calendar day, which is what "a day" means for a count the device keeps. */
private fun localDay(at: Long): String =
    java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).format(java.util.Date(at))

class InAppStore(private val context: Context, private val prefsName: String) {
    private var messages: List<InAppMessage> = emptyList()
    private var policy: InAppPolicy? = null
    /**
     * The last sync's caps as the server sent them, kept in the ledger with the counts they are read against, so a cold
     * start draws from the stored queue under the last caps rather than none until its own sync comes back. In the
     * ledger and not under a key of their own, so [reset] and every path that clears it cover them already.
     */
    private var policyRaw: JSONObject? = null
    var tokens: InAppTokens? = null
        private set

    /**
     * A message's own tokens when it has them, else the project default from the sync — its dark ones while the device is
     * in dark mode, when it has a dark variant. Read as it is drawn, from the app's own configuration,
     * so the renderer is handed the right colours for the first frame rather than corrected after it.
     */
    fun tokensFor(message: InAppMessage): InAppTokens? {
        // The screen in front first: an app that forces dark through AppCompat changes its Activity's configuration, and
        // the application's keeps saying light.
        val configuration = (TreebarsPush.resumedActivity() ?: context).resources.configuration
        val night = (configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK) == android.content.res.Configuration.UI_MODE_NIGHT_YES
        if (night && message.styleDark != null) return message.styleDark
        return message.style ?: tokens
    }

    /** delivery id -> how many times this device drew it. */
    private val shown = mutableMapOf<String, Int>()
    private val done = mutableSetOf<String>()
    private var lastShownAt: Long? = null

    /** Displays since the last sync, so the server's count is added to, not replaced. */
    private var sinceSync = 0

    /** Draws in the current session, keyed by its id so a new session starts at zero by itself. */
    private var sessionId: String? = null
    private var sessionShown = 0

    /** Distinct messages first drawn today per trigger kind, in this device's day. */
    private var triggerDay: String? = null
    private val triggerCounts = mutableMapOf<String, Int>()

    /** Nudges' own: drawn in the current session, and when the last one was — apart from the modals' above. */
    private var nudgeSessionId: String? = null
    private var nudgeSessionShown = 0
    private var nudgeLastShownAt: Long? = null

    /**
     * Which sign-in a sync belongs to: moved on by [reset] and by [supersede].
     *
     * A sync is a network round trip, and a sign-out can land inside it. Without this, the previous person's sync could
     * come back after `reset()` had emptied this store, put their queue back without the ledger that would have held it
     * back, and have it drawn on the signed-out screen. Read before the request and handed to [accept], which drops an
     * answer whose generation has passed.
     */
    @Volatile
    var generation = 0
        private set

    init {
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        runCatching {
            prefs.getString("in_app_queue", null)?.let { messages = parseMessages(JSONArray(it)) }
            prefs.getString("in_app_ledger", null)?.let { restoreLedger(JSONObject(it)) }
        }
        // A corrupt store is an empty store: losing a queue costs one sync, while throwing
        // here would take the SDK down on a path every launch runs.
    }

    /**
     * The server is authoritative about what is queued; the ledger about what this device did.
     *
     * Returns false, and changes nothing, for an answer asked before the signed-in person last changed.
     */
    @Synchronized
    fun accept(response: JSONObject, askedAt: Int = generation): Boolean {
        if (askedAt != generation) return false
        messages = parseMessages(response.optJSONArray("messages") ?: JSONArray())

        response.optJSONObject("policy")?.let {
            policyRaw = it
            policy = parsePolicy(it)
            // The server's count is as of now, so anything shown before it is included.
            sinceSync = 0
        }
        response.optJSONObject("style")?.let { tokens = parseInAppTokens(it) }

        val live = messages.map { it.deliveryId }.toSet()
        shown.keys.retainAll(live)
        done.retainAll(live)
        persist()
        return true
    }

    private fun parsePolicy(it: JSONObject): InAppPolicy = InAppPolicy(
        maxPerDay = if (it.isNull("max_per_day")) null else it.optInt("max_per_day"),
        minGapSeconds = if (it.isNull("min_gap_seconds")) null else it.optInt("min_gap_seconds"),
        messagesShownToday = it.optInt("messages_shown_today", 0),
        lastShownAt = Iso8601.parseOrNull(it.optString("last_shown_at", "")),
        maxPerSession = if (it.isNull("max_per_session") || it.optInt("max_per_session") <= 0) null else it.optInt("max_per_session"),
        triggerMaxPerDay = it.optJSONObject("trigger_max_per_day")?.let { caps ->
            CAPPED_TRIGGER_KINDS.mapNotNull { kind ->
                if (caps.isNull(kind)) null else caps.optInt(kind).takeIf { n -> n > 0 }?.let { n -> kind to n }
            }.toMap()
        } ?: emptyMap(),
        nudgeMaxPerSession = if (it.isNull("nudge_max_per_session") || it.optInt("nudge_max_per_session") <= 0) null else it.optInt("nudge_max_per_session"),
        nudgeMinGapSeconds = if (it.isNull("nudge_min_gap_seconds") || it.optInt("nudge_min_gap_seconds") <= 0) null else it.optInt("nudge_min_gap_seconds"),
    )

    /**
     * Somebody else is signed in now, without a sign-out between. The queue is the last person's, and so are the ledger
     * of what they were shown and a sync in flight for them: all of it goes here, as at a sign-out, so nothing of
     * theirs is left to be drawn for the person signing in.
     */
    @Synchronized
    fun supersede() {
        reset()
    }

    fun list(): List<InAppMessage> = messages

    /**
     * The inbox rows, pinned cards first and newest first within each — a card whose `showFrom` has not come yet
     * left out, as the server leaves it out of the notification feed.
     */
    fun inbox(now: Long = System.currentTimeMillis()): List<InAppMessage> {
        val rows = messages.filter { it.content?.surface == "inbox" && (it.content.card?.showFrom ?: 0L) <= now }
        return rows.filter { it.content?.card?.pinned == true } + rows.filter { it.content?.card?.pinned != true }
    }

    @Synchronized
    fun recordDisplay(message: InAppMessage, currentSession: String? = null, now: Long = System.currentTimeMillis()) {
        // A nudge spends only its own ledger ([isNudge]): the day, session, trigger and gap ledgers are the modals'.
        if (isNudge(message)) {
            if (currentSession != null) {
                if (nudgeSessionId != currentSession) {
                    nudgeSessionId = currentSession
                    nudgeSessionShown = 0
                }
                nudgeSessionShown += 1
            }
            nudgeLastShownAt = now
            val count = (shown[message.deliveryId] ?: 0) + 1
            shown[message.deliveryId] = count
            val max = message.content?.maxDisplays
            if (max != null && max > 0 && count >= max) done.add(message.deliveryId)
            persist()
            return
        }
        val firstTime = (shown[message.deliveryId] ?: 0) == 0
        if (currentSession != null) {
            if (sessionId != currentSession) {
                sessionId = currentSession
                sessionShown = 0
            }
            sessionShown += 1
        }
        val kind = message.content?.trigger?.kind
        if (kind != null && kind in CAPPED_TRIGGER_KINDS && firstTime) {
            val day = localDay(now)
            if (triggerDay != day) {
                triggerDay = day
                triggerCounts.clear()
            }
            triggerCounts[kind] = (triggerCounts[kind] ?: 0) + 1
        }
        val count = (shown[message.deliveryId] ?: 0) + 1
        shown[message.deliveryId] = count
        // [now], as every ledger in this call is stamped: the gap is measured against the clock that counted the day.
        lastShownAt = now
        sinceSync += 1
        val max = message.content?.maxDisplays
        if (max != null && max > 0 && count >= max) done.add(message.deliveryId)
        persist()
    }

    @Synchronized
    fun markDone(deliveryId: String) {
        done.add(deliveryId)
        persist()
    }

    @Synchronized
    fun reset() {
        generation += 1
        messages = emptyList()
        shown.clear()
        done.clear()
        lastShownAt = null
        sinceSync = 0
        sessionId = null
        sessionShown = 0
        triggerDay = null
        triggerCounts.clear()
        nudgeSessionId = null
        nudgeSessionShown = 0
        nudgeLastShownAt = null
        policy = null
        policyRaw = null
        persist()
    }

    /** Whether this device may draw this message now. Same three questions as every SDK. */
    fun allows(message: InAppMessage, currentSession: String? = null, now: Long = System.currentTimeMillis()): Boolean =
        blockedBy(message, currentSession, now) == null

    /**
     * Why this device may not draw this message now, or null when it may — the reason an `in_app_failed` names.
     * `done` is not a failure: a message shown as often as it may be, or dismissed, is finished rather than held back.
     */
    @Synchronized
    fun blockedBy(message: InAppMessage, currentSession: String? = null, now: Long = System.currentTimeMillis(), nudgesInFlight: Int = 0): String? {
        if (done.contains(message.deliveryId)) return "done"
        // One clock per call: expiry is read against [now], as the caps below are.
        message.expiresAt?.let { if (it <= now) return "expired" }

        val current = policy ?: return null
        // A test send is drawn past every cap below.
        if (message.test) return null
        // A nudge is outside them ([isNudge]), under two of its own. [nudgesInFlight] are drawn and not yet on
        // screen, counted as shown now ([NudgeSlots.inFlight]).
        if (isNudge(message)) {
            current.nudgeMaxPerSession?.let { cap ->
                val shownHere = if (currentSession != null && nudgeSessionId == currentSession) nudgeSessionShown else 0
                if (shownHere + nudgesInFlight >= cap) return "max_per_session"
            }
            current.nudgeMinGapSeconds?.let { gap ->
                val last = nudgeLastShownAt
                if (nudgesInFlight > 0 || (last != null && now - last < gap * 1000L)) return "min_gap"
            }
            return null
        }

        // The cap counts distinct messages, matching the server, so seeing one again does
        // not spend another unit of the allowance — maxDisplays governs repeats.
        val alreadySeen = (shown[message.deliveryId] ?: 0) > 0
        current.maxPerDay?.let {
            if (!alreadySeen && current.messagesShownToday + sinceSync >= it) return "max_per_day"
        }

        // Per session: every draw counts, a repeat of the same message included — each one interrupted somebody.
        current.maxPerSession?.let { cap ->
            if (currentSession != null && sessionId == currentSession && sessionShown >= cap) return "max_per_session"
        }

        // Per trigger kind a day: distinct messages, like the day cap, so a repeat spends nothing more.
        val kind = message.content?.trigger?.kind
        val kindCap = kind?.let { current.triggerMaxPerDay[it] }
        if (kind != null && kindCap != null && !alreadySeen) {
            val drawn = if (triggerDay == localDay(now)) triggerCounts[kind] ?: 0 else 0
            if (drawn >= kindCap) return "trigger_cap"
        }

        if (message.content?.ignoreMinGap != true) {
            current.minGapSeconds?.let { gap ->
                val last = maxOf(current.lastShownAt ?: 0L, lastShownAt ?: 0L)
                if (last > 0 && now - last < gap * 1000L) return "min_gap"
            }
        }

        return null
    }

    /**
     * Whether a held-back message should be reported now: once per message, reason and day, so the campaign's
     * failure counts are messages rather than every event that asked. Remembered across launches.
     */
    @Synchronized
    fun claimFailureReport(deliveryId: String, reason: String, now: Long = System.currentTimeMillis()): Boolean {
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        val today = localDay(now)
        val seen = runCatching { JSONObject(prefs.getString("in_app_failed", null) ?: "{}") }.getOrElse { JSONObject() }
        val key = "$deliveryId:$reason"
        if (seen.optString(key) == today) return false
        val kept = JSONObject()
        seen.keys().forEach { name -> if (seen.optString(name) == today) kept.put(name, today) }
        kept.put(key, today)
        prefs.edit().putString("in_app_failed", kept.toString()).apply()
        return true
    }

    private fun persist() {
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        val queue = JSONArray().apply { messages.forEach { put(it.raw) } }
        val ledger = JSONObject().apply {
            put("shown", JSONObject(shown as Map<*, *>))
            /*
             * An object map, `{id: true}`, and NOT a `JSONArray`, though `done` is a `Set` in
             * here and an array is the obvious encoding: the web SDK, the iOS SDK and the ledger
             * the React Native wrapper hands down to this SDK on upgrade all keep `done` as a map
             * keyed by delivery id. A reader expecting the other shape would find nothing, and
             * every message the person had already dismissed would be drawn again — to somebody
             * who said no. `InAppLedgerShapeTest` pins both halves.
             */
            put("done", JSONObject().apply { done.forEach { put(it, true) } })
            put("last_shown_at", lastShownAt ?: JSONObject.NULL)
            put("since_sync", sinceSync)
            // The same keys the web SDK persists.
            sessionId?.let { put("session", JSONObject().put("id", it).put("shown", sessionShown)) }
            triggerDay?.let { day ->
                put("by_trigger", JSONObject().put("day", day).put("counts", JSONObject(triggerCounts as Map<*, *>)))
            }
            // The web SDK's keys for nudges' own ledger.
            nudgeSessionId?.let { put("nudge_session", JSONObject().put("id", it).put("shown", nudgeSessionShown)) }
            nudgeLastShownAt?.let { put("nudge_last_shown_at", it) }
            // The web SDK's key, in the server's shape.
            policyRaw?.let { put("policy", it) }
        }
        prefs.edit()
            .putString("in_app_queue", queue.toString())
            .putString("in_app_ledger", ledger.toString())
            .apply()
    }

    private fun restoreLedger(json: JSONObject) {
        json.optJSONObject("shown")?.let { obj ->
            obj.keys().forEach { key -> shown[key] = obj.optInt(key) }
        }
        /*
         * Both shapes. The map is what every SDK writes; the array is what earlier versions of
         * this SDK wrote, and reading it keeps an upgrading install's dismissal history.
         */
        val doneMap = json.optJSONObject("done")
        if (doneMap != null) {
            doneMap.keys().forEach { key -> if (doneMap.optBoolean(key, true)) done.add(key) }
        } else {
            json.optJSONArray("done")?.let { arr ->
                for (i in 0 until arr.length()) done.add(arr.optString(i))
            }
        }
        lastShownAt = if (json.isNull("last_shown_at")) null else json.optLong("last_shown_at")
        sinceSync = json.optInt("since_sync", 0)
        // A ledger written by an earlier version has no policy, and waits for the sync as that version did.
        json.optJSONObject("policy")?.let { raw ->
            runCatching { parsePolicy(raw) }.getOrNull()?.let {
                policyRaw = raw
                policy = it
            }
        }
        json.optJSONObject("session")?.let {
            sessionId = it.optString("id").takeIf { id -> id.isNotEmpty() }
            sessionShown = it.optInt("shown", 0)
        }
        json.optJSONObject("by_trigger")?.let {
            triggerDay = it.optString("day").takeIf { day -> day.isNotEmpty() }
            it.optJSONObject("counts")?.let { counts -> counts.keys().forEach { key -> triggerCounts[key] = counts.optInt(key) } }
        }
        json.optJSONObject("nudge_session")?.let {
            nudgeSessionId = it.optString("id").takeIf { id -> id.isNotEmpty() }
            nudgeSessionShown = it.optInt("shown", 0)
        }
        nudgeLastShownAt = if (json.has("nudge_last_shown_at") && !json.isNull("nudge_last_shown_at")) json.optLong("nudge_last_shown_at") else null
    }

    private fun parseMessages(array: JSONArray): List<InAppMessage> =
        (0 until array.length()).mapNotNull { index ->
            val row = array.optJSONObject(index) ?: return@mapNotNull null
            val content = row.optJSONObject("content") ?: JSONObject()
            InAppMessage(
                deliveryId = row.optString("delivery_id"),
                campaignId = row.optString("campaign_id").takeIf { it.isNotEmpty() && it != "null" },
                title = content.optString("title").takeIf { it.isNotEmpty() },
                body = content.optString("body").takeIf { it.isNotEmpty() },
                imageUrl = content.optString("image_url").takeIf { it.isNotEmpty() },
                content = content.optJSONObject("in_app")?.let(::parseInAppContent),
                expiresAt = Iso8601.parseOrNull(row.optString("expires_at", "")),
                style = row.optJSONObject("style")?.let(::parseInAppTokens),
                raw = row,
                test = row.optBoolean("test", false),
                styleDark = row.optJSONObject("style_dark")?.let(::parseInAppTokens),
            )
        }

}


/*
 * The wire shape of an in-app message's content and its tokens.
 *
 * Top-level rather than private to `InAppStore`, because the notification centre reads the
 * same two objects out of its own rows — an `in_app` row in the feed carries exactly the
 * content and style the sync would have handed over. One parser, so a field added to the
 * server's shape cannot reach one reader and not the other.
 */
internal fun parseInAppContent(json: JSONObject): InAppContent {
    val trigger = json.optJSONObject("trigger") ?: JSONObject()
    val buttons = json.optJSONArray("buttons") ?: JSONArray()
    return InAppContent(
        surface = json.optString("surface", "overlay"),
        layout = json.optString("layout", "modal"),
        html = json.optString("html").takeIf { it.isNotEmpty() },
        bodyMode = json.optString("body_mode").takeIf { it.isNotEmpty() } ?: if (json.optString("layout") == "html") "html" else "standard",
        transparent = json.optBoolean("transparent", false),
        htmlRef = json.optJSONObject("html_ref")?.optString("sha256")?.takeIf { it.isNotEmpty() },
        position = json.optString("position").takeIf { it.isNotEmpty() },
        dismissible = json.optBoolean("dismissible", true),
        buttons = (0 until buttons.length()).mapNotNull { position ->
            buttons.optJSONObject(position)?.let {
                InAppButton(
                    it.optString("label"),
                    it.optString("action", "dismiss"),
                    it.optString("value").takeIf { value -> value.isNotEmpty() },
                    eventName = it.optString("event_name").takeIf { value -> value.isNotEmpty() },
                    key = it.optString("key").takeIf { value -> value.isNotEmpty() },
                    data = it.optJSONObject("data")?.let { data -> data.keys().asSequence().associateWith { name -> data.optString(name) } },
                    // Counting from 1, as `treebars://click/<n>` does, so a report reads one way for either body.
                    index = position + 1,
                )
            }
        },
        trigger = InAppTrigger(
            kind = trigger.optString("kind", "immediate"),
            screenName = trigger.optString("screen_name").takeIf { it.isNotEmpty() },
            eventName = trigger.optString("event_name").takeIf { it.isNotEmpty() },
            filters = parseFilters(trigger),
            campaignId = trigger.optString("campaign_id").takeIf { it.isNotEmpty() },
        ),
        // `isNull` first: org.json hands back the string "null" for a JSON null.
        direction = if (json.isNull("direction")) null else json.optString("direction").takeIf { it.isNotEmpty() },
        maxDisplays = if (json.isNull("max_displays")) null else json.optInt("max_displays"),
        ignoreMinGap = json.optBoolean("ignore_min_gap", false),
        display = json.optJSONObject("display")?.let { display ->
            val contexts = display.optJSONArray("contexts") ?: JSONArray()
            InAppDisplay(
                on = display.optString("on").takeIf { it.isNotEmpty() },
                delaySeconds = if (display.has("delay_seconds")) display.optInt("delay_seconds") else null,
                contexts = (0 until contexts.length()).mapNotNull { contexts.optString(it).takeIf { name -> name.isNotEmpty() } },
                priority = display.optInt("priority", 5),
                autoDismissSeconds = if (display.has("auto_dismiss_seconds")) display.optInt("auto_dismiss_seconds") else null,
                selfHandled = display.optBoolean("self_handled", false),
                onlyWhenPushAskable = display.optBoolean("only_when_push_askable", false),
            )
        },
        card = json.optJSONObject("card")?.let { card ->
            val action = card.optJSONObject("action")
            InAppCard(
                template = card.optString("template", "basic"),
                iconUrl = card.optString("icon_url").takeIf { it.isNotEmpty() },
                imageAlt = card.optString("image_alt").takeIf { it.isNotEmpty() },
                actionType = action?.optString("type")?.takeIf { it.isNotEmpty() },
                actionValue = action?.optString("value")?.takeIf { it.isNotEmpty() },
                pinned = card.optBoolean("pinned", false),
                showFrom = card.optString("show_from").takeIf { it.isNotEmpty() }?.let { Iso8601.parseOrNull(it) },
                category = card.optString("category").takeIf { it.isNotEmpty() },
                ctaLabel = card.optJSONObject("cta")?.optString("label")?.takeIf { it.isNotEmpty() },
                ctaType = card.optJSONObject("cta")?.optJSONObject("action")?.optString("type")?.takeIf { it.isNotEmpty() },
                ctaValue = card.optJSONObject("cta")?.optJSONObject("action")?.optString("value")?.takeIf { it.isNotEmpty() },
                expiresAfterSeenDays = if (card.has("expires_after_seen_days")) card.optInt("expires_after_seen_days") else null,
            )
        },
    )
}

/**
 * A trigger's `filters`, element by element. Absent or null is no filter. Present and not a list, or an
 * element that is not an object with a string key, is a malformed element, which fails the trigger rather
 * than being dropped — dropped, it would leave the rows beside it to draw the message for people no rule
 * described. The queue is saved as the server's JSON and parsed again on launch, so a relaunch reads the
 * same shape.
 */
private fun parseFilters(trigger: JSONObject): List<InAppFilter> {
    if (!trigger.has("filters") || trigger.isNull("filters")) return emptyList()
    val array = trigger.opt("filters") as? JSONArray ?: return listOf(InAppFilter.MALFORMED)
    return (0 until array.length()).map { index ->
        val row = array.opt(index) as? JSONObject ?: return@map InAppFilter.MALFORMED
        val key = row.opt("key") as? String ?: return@map InAppFilter.MALFORMED
        InAppFilter(
            key = key,
            op = row.opt("op") as? String ?: "",
            // `opt` rather than a typed read: the value is whatever the author put in the composer, and
            // comparing it is the matcher's job rather than the parser's.
            value = if (row.isNull("value")) null else row.opt("value"),
            type = tag(row, "type"),
            source = tag(row, "source"),
        )
    }
}

private fun tag(row: JSONObject, name: String): String? =
    if (!row.has(name)) null else row.opt(name) as? String ?: ""

internal fun parseInAppTokens(json: JSONObject) = InAppTokens(
    accent = json.optString("accent"),
    onAccent = json.optString("on_accent"),
    surface = json.optString("surface"),
    onSurface = json.optString("on_surface"),
    onSurfaceMuted = json.optString("on_surface_muted"),
    backdrop = json.optString("backdrop"),
    radius = json.optDouble("radius", 8.0),
    fontFamily = json.optString("font_family"),
    buttonShape = json.optString("button_shape", "rounded"),
)

/**
 * Whether a message's trigger matches what just happened.
 *
 * Mirrors `triggerMatches` in the web SDK and `inAppTriggerMatches` in the iOS SDK, which take the same
 * two things beside the event: `screenName`, the live screen the draw loop passes, which a
 * `screen_view` trigger reads ahead of `properties["screen_name"]`; and `dimensions`, the dimension map
 * this SDK stamped on THIS event — the same values, never a second read of the device — which a dimension
 * row reads. Without it a dimension row is false. screenName is compared case-sensitively because it is
 * the host app's own vocabulary and we are in no position to normalise it.
 */
fun inAppTriggerMatches(
    trigger: InAppTrigger,
    eventName: String,
    properties: Map<String, Any?>,
    screenName: String?,
    dimensions: Map<String, Any?>? = null,
): Boolean = when (trigger.kind) {
    "immediate" -> true
    "session_start" -> eventName == "session_start" || eventName == "app_open"
    "screen_view" ->
        eventName == "screen_view" &&
            (screenName ?: properties["screen_name"] as? String) == trigger.screenName
    "event" -> eventName == trigger.eventName && matchesFilters(properties, trigger.filters, dimensions)
    // The app opened from a push — any push, or one campaign's.
    "push_click" -> eventName == "notification_opened" &&
        (trigger.campaignId == null || properties[TreebarsConstants.CAMPAIGN_ID_KEY] == trigger.campaignId)
    // An unrecognised kind fails closed: showing a message to people who do not qualify is
    // worse than showing it to nobody.
    else -> false
}

/**
 * Whether a filter has been authored far enough to mean anything.
 *
 * The dashboard's filter builder saves `{key: "", op: "eq", value: ""}` the moment "Add filter" is
 * clicked. Read literally that row asks for a property named `""`, which nothing has, so the whole
 * trigger would match nobody — a working campaign would stop reaching every device because of a row
 * nobody finished. An incomplete row is dropped instead, as every Treebars SDK drops it, and the rows
 * beside it decide.
 *
 * "Something to compare against" is JavaScript's `String(value) !== ''`, so it reads the value's
 * JavaScript text: `[]` and `[null]` are unfinished rows on the web and here, where Kotlin's
 * `toString()` would call them `"[]"` and `"[null]"`. A malformed element is never dropped as
 * unfinished; `matchesFilters` fails the trigger on it.
 */
internal fun InAppFilter.isComplete(): Boolean {
    if (malformed) return true
    if (key.isBlank()) return false
    // `exists` is complete on its key alone; every other operator needs something to compare
    // against — `not_exists` included, which carries a marker.
    if (op == "exists") return true
    return value != null && value != JSONObject.NULL && jsText(value).isNotEmpty()
}

/**
 * The trigger's filters against one event, read in DEVICE mode — the same reading every Treebars SDK
 * gives them, so a trigger reaches the same people on every platform. `sdks/web/src/in-app.ts` is the
 * same rule in TypeScript.
 *
 * All fourteen operators, from the generated `FILTER_OPERATOR_CODES`; one this build does not know fails
 * closed, because showing a message to people who do not qualify is worse than showing it to nobody.
 * Incomplete rows are dropped before the conjunction rather than failed inside it — an unfinished row
 * beside a real one must leave the real one deciding.
 */
internal fun matchesFilters(
    properties: Map<String, Any?>,
    filters: List<InAppFilter>,
    dimensions: Map<String, Any?>? = null,
): Boolean {
    if (filters.isEmpty()) return true
    if (filters.any { it.malformed }) return false
    return filters.filter { it.isComplete() }.all { matchesFilter(properties, it, dimensions) }
}

private val KNOWN_CODES: Set<String> = TreebarsConstants.FILTER_OPERATOR_CODES.toSet()

/** The codes that match a value that is not set. */
private val NEGATED_CODES = setOf("neq", "not_contains", "not_in", "not_exists")
private val TEXT_CODES = setOf("contains", "not_contains", "starts_with", "ends_with")
private val FILTER_TYPES = setOf("string", "number", "boolean", "version")
private val IN_APP_DIMENSIONS: Set<String> = TreebarsConstants.IN_APP_DIMENSIONS.toSet()

private fun matchesFilter(properties: Map<String, Any?>, filter: InAppFilter, dimensions: Map<String, Any?>?): Boolean {
    // A side or a type this SDK does not read, and a code it does not know, fail closed.
    if (filter.source != null && filter.source != "property" && filter.source != "dimension") return false
    if (filter.type != null && filter.type !in FILTER_TYPES) return false
    if (filter.op !in KNOWN_CODES) return false

    /*
     * A dimension row reads the event's own map, never a property of the same name — and is false, not
     * "not set", without one, or for a name an in-app trigger may not read: geo, which a device cannot
     * know, and anything outside `IN_APP_DIMENSIONS`. Read as not set it would pass `neq`. A dimension
     * holds text, so the row compares as text unless it is a version row.
     */
    if (filter.source == "dimension") {
        if (dimensions == null || filter.key !in IN_APP_DIMENSIONS) return false
        val row = if (filter.type == "version") filter else filter.copy(type = "string")
        return compareValue(storedDimension(filter.key, dimensions[filter.key]), row)
    }
    // By its literal key.
    return compareValue(properties[filter.key], filter)
}

/** One row's comparison in device mode, over a value already found by whichever side the row names. */
private fun compareValue(actual: Any?, filter: InAppFilter): Boolean {
    // Not set is missing, null or "": "is set" is false for all three, and every negated code
    // matches them.
    val unset = actual == null || actual == JSONObject.NULL || actual == ""
    when (filter.op) {
        "exists" -> return !unset
        "not_exists" -> return unset
    }
    // A row that cannot say anything matches nobody, and that comes BEFORE the not-set reading: "is not
    // one of []" must never read as "everyone without the property".
    if (saysNothing(filter)) return false
    if (unset) return filter.op in NEGATED_CODES
    // A property that is not a scalar — a list, a map — fails closed, the negated codes included.
    val value = scalar(actual) ?: return false

    if (filter.op == "in" || filter.op == "not_in") {
        val items = decodeList(filter.value)!!
        val listType = filter.type ?: if (items.numbers != null) "number" else "string"
        val hit = if (listType == "version") {
            // Every item parses — `saysNothing` refused the row otherwise; a present value that does not is false.
            val left = parseVersion(value) ?: return false
            items.texts.any { compareVersion(left, parseVersion(it)!!) == 0 }
        } else if (listType == "number") {
            val left = asNumber(value, readText = filter.type == "number") ?: return false
            // `==` on two Doubles, not `contains`: boxed `equals` calls -0.0 and 0.0 different.
            items.numbers!!.any { it == left }
        } else {
            val left = jsText(value)
            items.texts.any { it == left }
        }
        return if (filter.op == "in") hit else !hit
    }

    val rowType = filter.type ?: inferredType(filter.value)
    if (rowType == "version") {
        // Part by part: 2.10 is after 2.9.1, and 2.3 = 2.3.0. A present value that does
        // not parse — a JSON number, 2.4.0-beta — is false under every code here, `neq` included; a text
        // code has no version reading.
        val left = parseVersion(value) ?: return false
        val order = compareVersion(left, parseVersion(filter.value)!!)
        return when (filter.op) {
            "eq" -> order == 0
            "neq" -> order != 0
            "gt" -> order > 0
            "gte" -> order >= 0
            "lt" -> order < 0
            "lte" -> order <= 0
            else -> false
        }
    }
    if (rowType == "number") {
        // With no `type` only a JSON number; under `type: 'number'`, text through the one grammar
        // too — never `toDoubleOrNull`, which trims whitespace and reads "42\n" as 42.
        val left = asNumber(value, readText = filter.type == "number") ?: return false
        val right = (filter.value as Number).toDouble()
        return when (filter.op) {
            "eq" -> left == right
            "neq" -> left != right
            "gt" -> left > right
            "gte" -> left >= right
            "lt" -> left < right
            "lte" -> left <= right
            else -> false
        }
    }

    // `string` and `boolean` compare text, as every Treebars SDK does — "150" is 150 here, and true is "true".
    // Kotlin's String already compares by UTF-16 code unit, as JavaScript does.
    val left = jsText(value)
    val right = jsText(filter.value)
    val orders = filter.type != "boolean"
    return when (filter.op) {
        "eq" -> left == right
        "neq" -> left != right
        "contains" -> left.contains(right)
        "not_contains" -> !left.contains(right)
        "starts_with" -> left.startsWith(right)
        "ends_with" -> left.endsWith(right)
        "gt" -> orders && left > right
        "gte" -> orders && left >= right
        "lt" -> orders && left < right
        "lte" -> orders && left <= right
        else -> false
    }
}

/**
 * Whether a row cannot say anything: a value that is not a scalar, a list that does not decode, a number row holding
 * text or under a text code.
 */
private fun saysNothing(filter: InAppFilter): Boolean {
    val value = filter.value
    if (value is JSONArray || value is JSONObject || value is Collection<*> || value is Map<*, *>) return true
    if (filter.op == "in" || filter.op == "not_in") {
        val items = decodeList(value) ?: return true
        val listType = filter.type ?: if (items.numbers != null) "number" else "string"
        if (listType == "number") return items.numbers == null
        // A number item is never a version, whatever its text: only a string parses.
        if (listType == "version") return items.numbers != null || items.texts.any { parseVersion(it) == null }
        return false
    }
    val rowType = filter.type ?: inferredType(value)
    if (rowType == "number") return value !is Number || filter.op in TEXT_CODES
    if (rowType == "version") return parseVersion(value) == null
    return false
}

/**
 * A version's parts: a string of one to four
 * dot-separated parts of one to ten ASCII digits, with an optional leading `v`. A character loop rather
 * than a pattern: `Pattern.find()` lets `$` match before a final newline, `Char.isDigit()` and `\d` accept
 * digits from every script, and `"+1".toLong()` is 1. Only a `String` parses — the number 2.3 is not a
 * version.
 */
internal fun parseVersion(value: Any?): List<Long>? {
    val text = value as? String ?: return null
    val body = if (text.startsWith("v") || text.startsWith("V")) text.substring(1) else text
    val parts = mutableListOf<Long>()
    var current = 0L
    var digits = 0
    for (c in body) {
        when {
            c == '.' -> {
                if (digits == 0) return null
                parts += current
                current = 0L
                digits = 0
            }
            c in '0'..'9' && digits < 10 -> {
                current = current * 10 + (c - '0')
                digits++
            }
            else -> return null
        }
    }
    if (digits == 0) return null
    parts += current
    return if (parts.size <= 4) parts else null
}

/** Part by part, both sides padded with zeros to four parts, so 2.3 = 2.3.0 = 2.3.0.0. */
internal fun compareVersion(a: List<Long>, b: List<Long>): Int {
    for (index in 0 until 4) {
        val left = a.getOrElse(index) { 0L }
        val right = b.getOrElse(index) { 0L }
        if (left != right) return if (left < right) -1 else 1
    }
    return 0
}

/**
 * JavaScript's `trim()`, which Treebars trims a device field with: its WhiteSpace and LineTerminator code
 * points, written out. Kotlin's `trim()` is a different set — it trims U+001C to U+001F and keeps U+FEFF —
 * so a value padded with a byte-order mark would compare untrimmed here and trimmed in the store.
 */
private val JS_WHITESPACE: Set<Int> = setOf(
    0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680,
    0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
    0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF,
)

internal fun jsTrim(text: String): String = text.trim { it.code in JS_WHITESPACE }

/**
 * A dimension as Treebars will store it, from the value this SDK stamped. A device field is trimmed as JavaScript trims and cut at the
 * generated `DEVICE_FIELD_LENGTH`; a screen name is not trimmed and is cut at `STRING_VALUE_LENGTH`;
 * anything empty or not a string is missing. `take` counts UTF-16 code units, as JavaScript's `slice` does.
 */
internal fun storedDimension(name: String, value: Any?): String? {
    val text = value as? String ?: return null
    if (name == "screen_name") return if (text.isEmpty()) null else text.take(TreebarsConstants.STRING_VALUE_LENGTH)
    val trimmed = jsTrim(text)
    return if (trimmed.isEmpty()) null else trimmed.take(TreebarsConstants.DEVICE_FIELD_LENGTH)
}

private fun inferredType(value: Any?): String = when (value) {
    is Number -> "number"
    is Boolean -> "boolean"
    else -> "string"
}

/** A property value as JavaScript's `typeof` sorts it: a String, a Boolean or a Double; null for anything else. */
private fun scalar(value: Any?): Any? = when (value) {
    is String, is Boolean -> value
    is Number -> value.toDouble()
    else -> null
}

private val NUMBER_GRAMMAR = Regex(TreebarsConstants.NUMBER_GRAMMAR)

/**
 * A number, as every Treebars SDK reads one: a JSON number (never NaN), or — under `type: 'number'` —
 * text the one grammar accepts. `Regex.matches` is whole-input, so `$` cannot stop before a final
 * newline; `toDouble` then reads what the grammar admits as `Number` does, `1e400` as infinity included.
 */
private fun asNumber(value: Any, readText: Boolean): Double? = when {
    value is Double -> if (value.isNaN()) null else value
    readText && value is String && NUMBER_GRAMMAR.matches(value) -> value.toDouble()
    else -> null
}

/**
 * JavaScript's `String(value)` for anything a JSON value or a host app's map can hold — `null` as `""`,
 * which is what JavaScript's `String(value ?? '')` and an array's join both make of it.
 */
internal fun jsText(value: Any?): String = when (value) {
    null -> ""
    JSONObject.NULL -> ""
    is String -> value
    is Boolean -> value.toString()
    is Number -> jsNumberText(value.toDouble())
    is JSONArray -> (0 until value.length()).joinToString(",") { jsText(value.opt(it)) }
    is Collection<*> -> value.joinToString(",") { jsText(it) }
    else -> "[object Object]"
}

/**
 * JavaScript's `String(number)`, which a filter's text reading compares a number by on every Treebars SDK.
 *
 * Java writes `100.0` for 100 and `1.0E16` for 10000000000000000, and older runtimes' `Double.toString`
 * did not always find the shortest digits. So the shortest digits are found here — the fewest that round
 * back to the same double, rounded correctly, which is the closest candidate as ECMAScript asks — and laid
 * out by its Number::toString: plain between 1e-7 and 1e21, exponential outside, `-0` as "0".
 */
internal fun jsNumberText(value: Double): String {
    if (value.isNaN()) return "NaN"
    if (value.isInfinite()) return if (value < 0) "-Infinity" else "Infinity"
    if (value == 0.0) return "0"

    val magnitude = kotlin.math.abs(value)
    val exact = java.math.BigDecimal(magnitude)
    var shortest = exact
    for (precision in 1..17) {
        val rounded = exact.round(java.math.MathContext(precision, java.math.RoundingMode.HALF_EVEN))
        if (rounded.toDouble() == magnitude) {
            shortest = rounded
            break
        }
    }
    val stripped = shortest.stripTrailingZeros()
    val digits = stripped.unscaledValue().toString()
    val k = digits.length
    val n = k - stripped.scale()

    val text = when {
        n in k..21 -> digits + "0".repeat(n - k)
        n in 1..21 -> digits.substring(0, n) + "." + digits.substring(n)
        n in -5..0 -> "0." + "0".repeat(-n) + digits
        else -> {
            val e = n - 1
            val sign = if (e < 0) "-" else "+"
            val lead = if (k == 1) digits else digits[0] + "." + digits.substring(1)
            lead + "e" + sign + kotlin.math.abs(e)
        }
    }
    return if (value < 0) "-$text" else text
}

/** A stored list, decoded once. `numbers` is set when every item is a number; `texts` is always each item's text. */
private class ListItems(val texts: List<String>, val numbers: List<Double>?)

/**
 * A stored list: a JSON array as a string, of non-empty strings or finite numbers, at most `LIST_MAX` —
 * as `JSON.parse` reads it, which is STRICT. `JSONArray(text)` is not: org.json reads `[pro]` and
 * `['pro']` as a list of one, where `JSON.parse` finds a list that does not decode and the row matches
 * nobody. So this reads the one shape a list can have and refuses everything else.
 */
private fun decodeList(value: Any?): ListItems? {
    val json = value as? String ?: return null
    val items = StrictJsonList(json).read() ?: return null
    if (items.isEmpty() || items.size > TreebarsConstants.LIST_MAX) return null
    if (items.all { it is String && it.isNotEmpty() }) return ListItems(items.map { it as String }, null)
    if (items.all { it is Double && it.isFinite() }) {
        val numbers = items.map { it as Double }
        return ListItems(numbers.map(::jsNumberText), numbers)
    }
    return null
}

/**
 * Just enough of RFC 8259 to read a JSON array of strings and numbers as `JSON.parse` does, and nothing
 * looser. Any other value inside it — `true`, `null`, a nested list — makes a list that does not decode,
 * which is the answer the other SDKs give it too, so this never needs to read one.
 */
private class StrictJsonList(private val text: String) {
    private var at = 0

    fun read(): List<Any>? {
        space()
        if (!take('[')) return null
        val items = mutableListOf<Any>()
        space()
        if (!take(']')) {
            while (true) {
                space()
                items += (if (peek() == '"') string() else number()) ?: return null
                space()
                if (take(']')) break
                if (!take(',')) return null
            }
        }
        space()
        return if (at == text.length) items else null
    }

    private fun peek(): Char? = text.getOrNull(at)

    private fun take(c: Char): Boolean = (peek() == c).also { if (it) at++ }

    private fun space() {
        while (peek() == ' ' || peek() == '\t' || peek() == '\n' || peek() == '\r') at++
    }

    private fun string(): String? {
        at++
        val out = StringBuilder()
        while (at < text.length) {
            val c = text[at++]
            when {
                c == '"' -> return out.toString()
                c < ' ' -> return null
                c != '\\' -> out.append(c)
                else -> when (val escape = text.getOrNull(at++)) {
                    '"', '\\', '/' -> out.append(escape)
                    'b' -> out.append('\b')
                    'f' -> out.append('\u000C')
                    'n' -> out.append('\n')
                    'r' -> out.append('\r')
                    't' -> out.append('\t')
                    'u' -> {
                        val hex = text.substring(at, minOf(at + 4, text.length))
                        if (hex.length != 4 || !hex.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return null
                        out.append(hex.toInt(16).toChar())
                        at += 4
                    }
                    else -> return null
                }
            }
        }
        return null
    }

    private fun number(): Double? {
        val start = at
        take('-')
        when (peek()) {
            '0' -> at++
            in '1'..'9' -> while (peek()?.isAsciiDigit() == true) at++
            else -> return null
        }
        if (take('.')) {
            if (peek()?.isAsciiDigit() != true) return null
            while (peek()?.isAsciiDigit() == true) at++
        }
        if (peek() == 'e' || peek() == 'E') {
            at++
            if (peek() == '+' || peek() == '-') at++
            if (peek()?.isAsciiDigit() != true) return null
            while (peek()?.isAsciiDigit() == true) at++
        }
        return text.substring(start, at).toDouble()
    }

    private fun Char.isAsciiDigit() = this in '0'..'9'
}

/** How often a delayed message that found the screen taken looks again. */
internal const val DELAYED_IN_APP_RETRY_MS = 1_000L

/** What a delayed in-app message does when it looks: show now, wait for the screen, or stop. */
internal sealed class DelayedInApp {
    object Present : DelayedInApp()
    object Wait : DelayedInApp()
    /** Stopped; [report] is the `in_app_failed` reason, or null when there is nothing to report (`done`). */
    data class Drop(val report: String?) : DelayedInApp()
}

/**
 * The decision, apart from the handler that runs it. The screen is asked first, so a message
 * waiting behind another is judged by the caps as they stand once the screen is free rather than
 * while the other is still up; then the caps, as the immediate path asks them; then the renderer.
 */
internal fun delayedInAppStep(blocked: String?, hasRenderer: Boolean, screenHeld: Boolean): DelayedInApp = when {
    screenHeld -> DelayedInApp.Wait
    blocked != null -> DelayedInApp.Drop(blocked.takeIf { it != "done" })
    !hasRenderer -> DelayedInApp.Drop("no_renderer")
    else -> DelayedInApp.Present
}

/**
 * The loop a delayed message runs once its delay is up, apart from the SDK's state and
 * the main-thread handler, so a test can drive it with a scheduler of its own.
 *
 * Each [tick] looks once: gone when the message is no longer the one waiting ([stillWaiting] —
 * `reset`, or a new person); otherwise [delayedInAppStep] decides. A wait, or a [present] that
 * lost the slot to another consideration between the look and the claim, schedules the next look
 * [DELAYED_IN_APP_RETRY_MS] later; a drop, or a present that took the screen, [finish]es — and a
 * drop with a reason is [report]ed as `in_app_failed`, so no message is dropped without a word.
 */
internal class DelayedInAppLoop(
    private val schedule: (delayMs: Long, tick: () -> Unit) -> Unit,
    private val stillWaiting: () -> Boolean,
    private val blockedBy: () -> String?,
    private val hasRenderer: () -> Boolean,
    private val screenHeld: () -> Boolean,
    private val present: () -> Boolean,
    private val finish: () -> Unit,
    private val report: (reason: String) -> Unit,
) {
    fun tick() {
        if (!stillWaiting()) return
        when (val step = delayedInAppStep(blockedBy(), hasRenderer(), screenHeld())) {
            is DelayedInApp.Wait -> schedule(DELAYED_IN_APP_RETRY_MS, ::tick)
            is DelayedInApp.Drop -> {
                finish()
                step.report?.let(report)
            }
            is DelayedInApp.Present -> if (present()) finish() else schedule(DELAYED_IN_APP_RETRY_MS, ::tick)
        }
    }
}

/**
 * Whether an overlay is on screen, claimed and read under one lock.
 *
 * `considerInApp` runs on whichever thread called `track` — the React Native bridge's queue for
 * the app's events, a coroutine for the `session_start` that `record` appends, the sync's
 * coroutine for a replay — so two considerations can run at once. As two separate touches of a
 * plain field, the check ("nothing is on screen") and the claim ("now something is") would leave a
 * gap, with the store reads and the `in_app_displayed` track between them, through which two
 * considerations could both draw. Claimed in one step, the second consideration finds the slot
 * taken and leaves the message alone.
 *
 * A duration (`IN_APP_PRESENTATION_HOLD_MS`) rather than a flag the host clears, so a renderer that
 * never reports an answer cannot hold the screen for good.
 */
internal class PresentationSlot(private val holdMs: Long = TreebarsConstants.IN_APP_PRESENTATION_HOLD_MS) {
    private var claimedAt: Long? = null

    /**
     * Claimed by this SDK's own HTML host, which says when its message ends on every path: held until [release], not for
     * the hold. The hold is a ceiling for renderers that never say; applied here, a person thirty seconds into a
     * three-screen message would have the next message drawn over it.
     */
    private var pinned = false

    /** Takes the slot if nothing holds it, and says whether this caller got it. [untilReleased] for a host that reports every ending itself. */
    @Synchronized
    fun claim(now: Long = System.currentTimeMillis(), untilReleased: Boolean = false): Boolean {
        if (held(now)) return false
        claimedAt = now
        pinned = untilReleased
        return true
    }

    /** Whether something is on screen and unanswered. Advisory: only [claim] decides. */
    @Synchronized
    fun isHeld(now: Long = System.currentTimeMillis()): Boolean = held(now)

    private fun held(now: Long): Boolean {
        val at = claimedAt ?: return false
        return pinned || now - at < holdMs
    }

    /** The person answered, or the host that drew it went away. */
    @Synchronized
    fun release() {
        claimedAt = null
        pinned = false
    }

    /**
     * The same, from the app's renderer, which never holds a claim made until released: a late answer from it, or a
     * renderer attaching, must not free the screen under a message this SDK is drawing.
     */
    @Synchronized
    fun releaseUnpinned() {
        if (!pinned) claimedAt = null
    }
}

/**
 * What a sent form keeps beyond its answers: an email or phone field marked `save_as`, as the address the server attaches
 * as an opt-in; and an answer kept as a trait — only a trait the message declares, which the
 * send path fills from the form beside the markup's, and never one the product keeps. The web's `formKeeps` and Swift's,
 * and the rule a markup form's `data-tb-save` is held to (`_submit`).
 */
internal fun formKeeps(inApp: JSONObject?, responses: Map<String, Any?>): Pair<Map<String, String>, Map<String, Any?>> {
    val fields = inApp?.optJSONObject("form")?.optJSONArray("fields") ?: return emptyMap<String, String>() to emptyMap()
    val declared = inApp.optJSONObject("declared")?.optJSONArray("traits")?.let { list -> (0 until list.length()).map { list.optString(it) }.toSet() } ?: emptySet()
    val addresses = mutableMapOf<String, String>()
    val traits = mutableMapOf<String, Any?>()
    for (index in 0 until fields.length()) {
        val field = fields.optJSONObject(index) ?: continue
        val answer = responses[field.optString("id")]
        if (answer == null || answer == "") continue
        val saveAs = field.optString("save_as")
        if ((saveAs == "email" || saveAs == "phone") && answer is String) addresses[saveAs] = answer
        val trait = field.optString("trait")
        if (trait.isNotEmpty() && trait in declared && trait !in TreebarsBridge.RESERVED_TRAITS) traits[trait] = answer
    }
    return addresses to traits
}
