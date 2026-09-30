package com.treebars.sdk

import android.Manifest
import android.app.Activity
import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ProcessLifecycleOwner
import com.treebars.sdk.generated.TreebarsConstants
import org.json.JSONArray
import org.json.JSONObject
import java.lang.ref.WeakReference
import java.net.HttpURLConnection
import java.net.URI

/**
 * Draws a push the server sent for the SDK to draw, and performs what its buttons do.
 *
 * A push with buttons, a carousel, media, a large icon, a group or a coupon arrives DATA-ONLY — Firebase hands a data
 * message to the app even in the background, where a notification message it would have drawn itself, without any
 * of those. So the app calls [handle] from its `FirebaseMessagingService.onMessageReceived` with `remoteMessage.data`,
 * and turns the channel's "draws them with the Treebars SDK" on. A plain push is not the SDK's to draw: [handle]
 * returns false and the app does what it always did.
 *
 * Platform APIs only — `Notification.Builder`, not `NotificationCompat` — because the SDK takes no androidx-core or
 * Firebase dependency; every app that integrates it would carry that whether or not it sends pushes.
 */
object TreebarsPush {
    /** The app's answer to "open screen X" and to a `custom` action, which only it can know how to do. */
    fun interface ActionListener {
        fun onAction(type: String, values: Map<String, String>)
    }

    private const val DEFAULT_CHANNEL = "treebars_default"
    private const val FETCH_TIMEOUT_MS = 8_000
    internal const val EXTRA_DATA = "treebars_push_data"
    internal const val EXTRA_BUTTON = "treebars_push_button"
    internal const val EXTRA_CARD = "treebars_push_card"
    internal const val EXTRA_KIND = "treebars_push_kind"
    private const val PERMISSION_REQUEST = 7_411

    @Volatile private var listener: ActionListener? = null
    @Volatile private var resumed: WeakReference<Activity>? = null

    /**
     * A `navigate` or `custom` action that arrived while nobody was listening, handed to the next listener.
     *
     * A tap from a dead process runs [TreebarsPushActivity] before the app has built whatever listens — always, under
     * React Native, whose listener is registered from JavaScript once the bridge is up, and which never reads the launch
     * intent's extras. One slot, not a queue: it is the tap that opened the app.
     */
    @Volatile private var pendingAction: Pair<String, Map<String, String>>? = null

    /**
     * Where `navigate` and `custom` go. Without one, `navigate` opens the app with the screen in the launch intent — and
     * the action is also held, so a listener set a moment later (in the launched screen's `onCreate`, or by a bridge)
     * still receives the tap that opened the app.
     */
    @JvmStatic
    fun setActionListener(listener: ActionListener?) {
        this.listener = listener
        if (listener == null) return
        val held = pendingAction ?: return
        pendingAction = null
        runCatching { listener.onAction(held.first, held.second) }
            .onFailure { TreebarsLogger.log("push: action listener threw: $it") }
    }

    /**
     * Draws the push if it is one the SDK draws, and says whether it did. Call it from `onMessageReceived`, which runs
     * off the main thread: the images are fetched here, before the notification is posted.
     */
    @JvmStatic
    fun handle(context: Context, data: Map<String, String>): Boolean {
        /*
         * A background update shows nothing: its data goes to the app's listener, which is the whole point of sending
         * one. With no listener set it is not the SDK's — false, and the app's own messaging service does
         * with the data message what it always did. It never carries `render`, so an SDK older than this draws nothing.
         */
        if (data[TreebarsConstants.RICH_PUSH_BACKGROUND_KEY] == "1") {
            val listener = backgroundListener ?: return false
            val payload = data.filterKeys { it != TreebarsConstants.RICH_PUSH_BACKGROUND_KEY }
            runCatching { listener.onBackgroundUpdate(payload) }.onFailure { TreebarsLogger.log("push: background listener threw: $it") }
            return true
        }
        if (data[TreebarsConstants.RICH_PUSH_RENDER_KEY] != "1") return false
        post(context.applicationContext, data, card = 0)
        return true
    }

    /** What a background update hands the app: its data, the delivery's attribution keys included. */
    fun interface BackgroundUpdateListener {
        fun onBackgroundUpdate(data: Map<String, String>)
    }

    @Volatile private var backgroundListener: BackgroundUpdateListener? = null

    /**
     * Where a background update's data goes: a silent push
     * for syncing, refreshing or changing the app's state, with no notification. Called on the thread `handle` was —
     * `onMessageReceived`'s, off the main thread.
     */
    @JvmStatic
    fun setBackgroundUpdateListener(listener: BackgroundUpdateListener?) {
        backgroundListener = listener
    }

    /**
     * Asks for push permission — for a two-step opt-in, an in-app message explains and its button asks. Android 13 and
     * later only — earlier versions grant it at install. The answer is reported as `notification_permission_changed`
     * when the dialog closes and the screen that asked resumes (see [activityTracker]).
     */
    @JvmStatic
    fun requestPermission(activity: Activity) {
        if (Build.VERSION.SDK_INT < 33) return
        if (activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        // Remembered, because Android cannot tell never-asked from refused-for-good afterwards (see `androidPushStatus`).
        activity.getSharedPreferences(Treebars.PREFS_NAME, Context.MODE_PRIVATE).edit().putBoolean(PERMISSION_ASKED_KEY, true).apply()
        activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST)
    }

    /**
     * This device's push state in the vocabulary every Treebars SDK shares, read when a message asks rather
     * than kept: somebody can change it in Settings and come back.
     */
    internal fun pushStatus(context: Context): String {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? android.app.NotificationManager
        val asked = context.getSharedPreferences(Treebars.PREFS_NAME, Context.MODE_PRIVATE).getBoolean(PERMISSION_ASKED_KEY, false)
        val rationale = Build.VERSION.SDK_INT >= 33 && resumedActivity()?.shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS) == true
        return androidPushStatus(Build.VERSION.SDK_INT, manager?.areNotificationsEnabled() == true, asked, rationale)
    }

    private const val PERMISSION_ASKED_KEY = "push_permission_asked"

    /**
     * The screen in front when this SDK started after it had already resumed — a React Native host initialises from
     * JavaScript, once its Activity is up — so an HTML in-app message has somewhere to be drawn before the next resume.
     * Ignored once the tracker has seen a screen of its own.
     */
    @JvmStatic
    fun noteResumedActivity(activity: Activity) {
        if (resumed?.get() != null || activity.isFinishing) return
        resumed = WeakReference(activity)
        sawActivity = true
    }

    /** The screen in front, if it is not on its way out: where an HTML in-app message is drawn. */
    internal fun resumedActivity(): Activity? = resumed?.get()?.takeIf { !it.isFinishing && !it.isDestroyed }

    /** From the in-app button whose link is [TreebarsConstants.PUSH_PERMISSION_LINK]: the screen showing it asks. */
    internal fun requestPermissionFromForeground() {
        resumed?.get()?.let { requestPermission(it) }
    }

    /** Whether this tracker has seen any Activity resume or pause since it was registered. */
    @Volatile private var sawActivity = false

    /**
     * Whether the process has a resumed Activity, for the one case the tracker cannot answer: registered after the
     * screen in front had already resumed. A React Native host initialises from JavaScript, which runs only once its
     * Activity is up, so the first resume this tracker could see has already happened. Replaceable for a test, where
     * `ProcessLifecycleOwner` is never attached. A class that will not load means "yes": the message is presented, as
     * it would be without this check. A host that removed App Startup's provider is the other way round:
     * the owner never attaches and reads "no", so a late-initialising host holds its messages until its next resume —
     * the safe side, since a held message is shown later and a spent one never.
     */
    internal var processResumed: () -> Boolean = {
        runCatching { ProcessLifecycleOwner.get().lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) }.getOrDefault(true)
    }

    /**
     * Whether an overlay handed to the app now would have a screen to appear on.
     *
     * Asked before a message is presented, so none is reported displayed — `in_app_displayed`, `displayed_at`, and for
     * an `immediate` one the message spent — with nothing on screen. The tracker's own answer once it has seen an
     * Activity: the one in front, if it is not on its way out. Before that, the process's.
     */
    internal fun hasResumedActivity(): Boolean {
        resumed?.get()?.let { return !it.isFinishing && !it.isDestroyed }
        return !sawActivity && processResumed()
    }

    /** Remembers the screen in front, weakly, so an in-app button can ask for permission on it. */
    internal val activityTracker = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityResumed(activity: Activity) {
            resumed = WeakReference(activity)
            sawActivity = true
            /*
             * The permission dialog pauses the screen that asked and resumes it with the answer, inside one foreground —
             * so an answer read only at the next `onStart` (the process coming back from the background) would reach
             * the server hours late, or never for somebody who stayed in the app. Read here, it is reported
             * the moment the dialog closes, as iOS reports it. A resume with nothing changed costs a preferences read.
             */
            Treebars.notePermissionChange()
            // A standard message the SDK drew on another of the app's screens goes: that screen is behind this one.
            // Before the replay below, so a trigger held for want of a screen can be drawn on this one.
            Treebars.noteScreenInFront(activity)
            // A screen to draw on again: whatever in-app trigger found none is answered now.
            Treebars.noteSurfaceResumed()
            // And the nudges of a screen that allowed them in `onStart`, before it was in front.
            Treebars.noteNudgeScreenResumed()
        }
        override fun onActivityPaused(activity: Activity) {
            sawActivity = true
            if (resumed?.get() === activity) resumed = null
        }
        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
        override fun onActivityStarted(activity: Activity) {}
        override fun onActivityStopped(activity: Activity) {}
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
        // An in-app message this SDK drew belongs to this screen — its Dialog, or a banner on its view tree — and goes
        // with it.
        override fun onActivityDestroyed(activity: Activity) = Treebars.noteActivityDestroyed(activity)
    }

    // ---- Drawing -------------------------------------------------------------------------------------------------

    internal fun post(context: Context, data: Map<String, String>, card: Int) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        if (Build.VERSION.SDK_INT >= 24 && !manager.areNotificationsEnabled()) return
        val options = data[TreebarsConstants.RICH_PUSH_OPTIONS_KEY]?.let { runCatching { JSONObject(it) }.getOrNull() } ?: JSONObject()
        val buttons = data[TreebarsConstants.RICH_PUSH_BUTTONS_KEY]?.let { runCatching { JSONArray(it) }.getOrNull() } ?: JSONArray()
        val cards = data[TreebarsConstants.RICH_PUSH_CAROUSEL_KEY]?.let { runCatching { JSONArray(it) }.getOrNull() } ?: JSONArray()
        val media = data[TreebarsConstants.RICH_PUSH_MEDIA_KEY]?.let { runCatching { JSONObject(it) }.getOrNull() }
        val template = PushTemplateSpec.parse(data[TreebarsConstants.RICH_PUSH_TEMPLATE_KEY])
        val now = System.currentTimeMillis()
        // A countdown that arrives after its end is a notification about nothing.
        if (template?.isTimer == true && template.endsAt!! <= now) return

        val named = options.optString("android_channel_id").ifEmpty { DEFAULT_CHANNEL }
        val headsUp = options.optBoolean("heads_up")
        /*
         * A channel the app never created is not posted on at all from Android 8 — the notification is dropped, and
         * nothing reports it. The composer's channel id is free text, so a typo would mean a campaign that reached
         * nobody on Android; it falls back to the SDK's default channel instead. A channel the app did create is still
         * the app's, with the sound and importance it chose.
         *
         * One the push channel's registry declares is created, with the name and importance declared there — so an app
         * that never made "Offers" still gets an "Offers" channel people can switch off by itself, rather than every
         * campaign landing in one. Android fixes a channel's importance once it exists.
         */
        val declared = options.optString("android_channel_name").takeIf { it.isNotEmpty() }
        val importance = CHANNEL_IMPORTANCE[options.optString("android_channel_importance")]
        if (Build.VERSION.SDK_INT >= 26 && named != DEFAULT_CHANNEL && declared != null && importance != null && manager.getNotificationChannel(named) == null) {
            runCatching { manager.createNotificationChannel(NotificationChannel(named, declared, importance)) }
                .onFailure { TreebarsLogger.log("push: could not create channel $named: $it") }
        }
        val channel =if (Build.VERSION.SDK_INT >= 26 && named != DEFAULT_CHANNEL && manager.getNotificationChannel(named) == null) DEFAULT_CHANNEL else named
        if (Build.VERSION.SDK_INT >= 26 && channel == DEFAULT_CHANNEL && manager.getNotificationChannel(DEFAULT_CHANNEL) == null) {
            manager.createNotificationChannel(
                NotificationChannel(DEFAULT_CHANNEL, "Notifications", if (headsUp) NotificationManager.IMPORTANCE_HIGH else NotificationManager.IMPORTANCE_DEFAULT),
            )
        }

        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, channel) else @Suppress("DEPRECATION") Notification.Builder(context)
        /*
         * The small icon and its colour, from the app's manifest. Android draws the small icon as a silhouette, so the
         * launcher icon — the fallback when none is named — usually comes out as a grey square. An app names a flat
         * white icon and an accent in `<meta-data>` under `<application>`, the way Firebase's default notification icon
         * is named:
         *   com.treebars.sdk.notification_icon  → a drawable
         *   com.treebars.sdk.notification_color → a colour resource
         */
        val appMeta = notificationMeta(context)
        val icon = appMeta?.getInt(NOTIFICATION_ICON_META)?.takeIf { it != 0 }
            ?: context.applicationInfo.icon.takeIf { it != 0 }
            ?: android.R.drawable.ic_dialog_info
        appMeta?.getInt(NOTIFICATION_COLOR_META)?.takeIf { it != 0 }?.let { colour ->
            runCatching { builder.setColor(context.getColor(colour)) }
        }
        val shownCard = cards.optJSONObject(card)
        val title = shownCard?.optString("title")?.takeIf { it.isNotEmpty() } ?: data[TreebarsConstants.RICH_PUSH_TITLE_KEY].orEmpty()
        val body = shownCard?.optString("body")?.takeIf { it.isNotEmpty() } ?: data[TreebarsConstants.RICH_PUSH_BODY_KEY].orEmpty()
        builder.setSmallIcon(icon).setContentTitle(title).setContentText(body).setAutoCancel(!options.optBoolean("sticky"))
        options.optString("subtitle").takeIf { it.isNotEmpty() }?.let { builder.setSubText(it) }
        if (options.optBoolean("sticky")) builder.setOngoing(true)
        if (options.has("badge")) builder.setNumber(options.optInt("badge"))
        options.optString("group_key").takeIf { it.isNotEmpty() }?.let { builder.setGroup(it) }
        if (headsUp && Build.VERSION.SDK_INT < 26) @Suppress("DEPRECATION") builder.setPriority(Notification.PRIORITY_HIGH)
        options.optString("accessibility_text").takeIf { it.isNotEmpty() }?.let { builder.setTicker(it) }
        options.optString("large_icon_url").takeIf { it.isNotEmpty() }?.let { url -> fetch(url)?.let { builder.setLargeIcon(it) } }

        // A card's image, else the push's image, else a GIF's first frame (a notification cannot animate on Android).
        val pictureUrl = shownCard?.optString("image_url")?.takeIf { it.isNotEmpty() }
            ?: data[TreebarsConstants.RICH_PUSH_IMAGE_KEY]
            ?: media?.takeIf { it.optString("kind") == "gif" }?.optString("url")
        val picture = pictureUrl?.takeIf { it.isNotEmpty() }?.let { fetch(it) }
        val tag = options.optString("update_key").ifEmpty { data[TreebarsConstants.DELIVERY_ID_KEY] ?: "treebars" }
        /*
         * A push template draws its own content; anything else is the platform's big picture or
         * big text. The same title and body either way, so an SDK that cannot read the template draws the backup.
         */
        var nextStep: Long? = null
        if (template != null) {
            val collapsed = template.collapsedImage?.let { fetch(it) }
            nextStep = PushTemplates.decorate(context, builder, template, title, body, picture, collapsed, now)
        } else if (picture != null) {
            builder.setStyle(Notification.BigPictureStyle().bigPicture(picture).setSummaryText(body))
        } else {
            builder.setStyle(Notification.BigTextStyle().bigText(body))
        }
        /*
         * Off the tray after its time: the author's auto-dismiss, at most a day, and never later
         * than a timer's own end, which `decorate` has already set.
         */
        val dismissAfter = options.optLong("auto_dismiss_seconds", 0L) * 1000
        if (Build.VERSION.SDK_INT >= 26 && dismissAfter > 0) {
            val timerLeft = template?.endsAt?.let { it - now }
            builder.setTimeoutAfter(if (timerLeft != null) minOf(timerLeft, dismissAfter) else dismissAfter)
        }

        builder.setContentIntent(activityIntent(context, data, kind = "tap", button = -1, card = card, request = tag.hashCode()))
        builder.setDeleteIntent(receiverIntent(context, data, kind = "dismiss", button = -1, card = card, request = tag.hashCode() + 1))

        /*
         * A carousel steps through its cards with two actions; the rest are the push's own buttons, then the coupon —
         * in that order, and no more than Android draws. Three are drawn; past that the system drops actions silently.
         * The composer names what falls past the budget, in the same order, so an author learns it before the send.
         */
        var slot = 2
        var drawn = 0
        val budget = TreebarsConstants.PUSH_ANDROID_ACTION_SLOTS
        if (cards.length() > 1) {
            val previous = (card - 1 + cards.length()) % cards.length()
            val next = (card + 1) % cards.length()
            builder.addAction(action(context, "‹", receiverIntent(context, data, "card", -1, previous, tag.hashCode() + slot++)))
            builder.addAction(action(context, "›", receiverIntent(context, data, "card", -1, next, tag.hashCode() + slot++)))
            drawn += 2
        }
        for (index in 0 until minOf(buttons.length(), 3)) {
            if (drawn >= budget) break
            val button = buttons.optJSONObject(index) ?: continue
            val type = button.optJSONObject("action")?.optString("type").orEmpty()
            // Copying, recording and setting a trait need no screen; the rest open one.
            val intent = if (type in BACKGROUND_ACTIONS) receiverIntent(context, data, "button", index, card, tag.hashCode() + slot++)
            else activityIntent(context, data, "button", index, card, tag.hashCode() + slot++)
            builder.addAction(action(context, button.optString("label"), intent))
            drawn += 1
        }
        options.optString("coupon_code").takeIf { it.isNotEmpty() && drawn < budget }?.let { code ->
            builder.addAction(action(context, "Copy $code", receiverIntent(context, data, "coupon", -1, card, tag.hashCode() + slot++)))
        }

        runCatching { manager.notify(tag, 0, builder.build()) }
        // The progress bar's next step, when the timer has one; `tick` redraws from the clock.
        nextStep?.let { PushTemplates.scheduleTick(context, PushTemplates.tickIntent(context, data, tickRequest(tag)), it) }
    }

    /** The request code a timer's steps are scheduled under, so a redraw replaces the step before it. */
    internal fun tickRequest(tag: String): Int = tag.hashCode() + 99

    /** The registry's importance words as Android's levels: Urgent is Android's HIGH. */
    private val CHANNEL_IMPORTANCE = mapOf(
        "urgent" to NotificationManager.IMPORTANCE_HIGH,
        "high" to NotificationManager.IMPORTANCE_DEFAULT,
        "medium" to NotificationManager.IMPORTANCE_LOW,
        "low" to NotificationManager.IMPORTANCE_MIN,
        "none" to NotificationManager.IMPORTANCE_NONE,
    )

    private val BACKGROUND_ACTIONS = setOf("copy", "track_event", "set_attribute")

    internal const val NOTIFICATION_ICON_META = "com.treebars.sdk.notification_icon"
    internal const val NOTIFICATION_COLOR_META = "com.treebars.sdk.notification_color"

    /** The app's `<application>` meta-data, where the notification icon and colour are named; null when unreadable. */
    private fun notificationMeta(context: Context): Bundle? = runCatching {
        @Suppress("DEPRECATION")
        context.packageManager.getApplicationInfo(context.packageName, android.content.pm.PackageManager.GET_META_DATA).metaData
    }.getOrNull()

    private fun action(context: Context, label: String, intent: PendingIntent): Notification.Action =
        if (Build.VERSION.SDK_INT >= 23) Notification.Action.Builder(null as android.graphics.drawable.Icon?, label, intent).build()
        else @Suppress("DEPRECATION") Notification.Action.Builder(0, label, intent).build()

    private fun extras(intent: Intent, data: Map<String, String>, kind: String, button: Int, card: Int): Intent =
        intent.putExtra(EXTRA_DATA, JSONObject(data as Map<*, *>).toString())
            .putExtra(EXTRA_KIND, kind)
            .putExtra(EXTRA_BUTTON, button)
            .putExtra(EXTRA_CARD, card)

    private fun flags(): Int = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0)

    private fun activityIntent(context: Context, data: Map<String, String>, kind: String, button: Int, card: Int, request: Int): PendingIntent {
        val intent = extras(Intent(context, TreebarsPushActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), data, kind, button, card)
        return PendingIntent.getActivity(context, request, intent, flags())
    }

    private fun receiverIntent(context: Context, data: Map<String, String>, kind: String, button: Int, card: Int, request: Int): PendingIntent {
        val intent = extras(Intent(context, TreebarsPushReceiver::class.java), data, kind, button, card)
        return PendingIntent.getBroadcast(context, request, intent, flags())
    }

    /**
     * The last few images fetched: a timer's progress bar redraws the whole notification every
     * step, and fetching its picture once a minute for twelve hours is a download nobody asked for. Lost with the
     * process, which only costs one fetch again.
     */
    private val pictures = android.util.LruCache<String, Bitmap>(4)

    private fun fetch(url: String): Bitmap? = pictures.get(url) ?: runCatching {
        val connection = URI(url).toURL().openConnection() as HttpURLConnection
        connection.connectTimeout = FETCH_TIMEOUT_MS
        connection.readTimeout = FETCH_TIMEOUT_MS
        try {
            connection.inputStream.use { BitmapFactory.decodeStream(it) }
        } finally {
            connection.disconnect()
        }
    }.getOrNull()?.also { pictures.put(url, it) }

    // ---- Acting ----------------------------------------------------------------------------------------------------

    internal fun dataOf(intent: Intent): Map<String, String> {
        val json = intent.getStringExtra(EXTRA_DATA)?.let { runCatching { JSONObject(it) }.getOrNull() } ?: return emptyMap()
        return json.keys().asSequence().associateWith { json.optString(it) }
    }

    /** The action a tap or a button carries: a button's own, a card's, or the push's deep link. */
    internal fun actionOf(data: Map<String, String>, kind: String, button: Int, card: Int): JSONObject? {
        if (kind == "button") {
            return data[TreebarsConstants.RICH_PUSH_BUTTONS_KEY]?.let { runCatching { JSONArray(it) }.getOrNull() }
                ?.optJSONObject(button)?.optJSONObject("action")
        }
        val cardAction = data[TreebarsConstants.RICH_PUSH_CAROUSEL_KEY]?.let { runCatching { JSONArray(it) }.getOrNull() }
            ?.optJSONObject(card)?.optJSONObject("action")
        if (cardAction != null) return cardAction
        val media = data[TreebarsConstants.RICH_PUSH_MEDIA_KEY]?.let { runCatching { JSONObject(it) }.getOrNull() }
        // A sound or a video cannot play in an Android notification; tapping it plays it.
        if (media != null && media.optString("kind") != "gif") return JSONObject().put("type", "rich_landing").put("url", media.optString("url"))
        return data[TreebarsConstants.RICH_PUSH_DEEP_LINK_KEY]?.takeIf { it.isNotEmpty() }?.let { JSONObject().put("type", "deep_link").put("url", it) }
    }

    /** Reports the tap — the notification opened, and which button — before anything leaves the app. */
    internal fun reportTap(context: Context, data: Map<String, String>, kind: String, button: Int) {
        val opened = data.toMutableMap()
        if (kind == "button") {
            val id = data[TreebarsConstants.RICH_PUSH_BUTTONS_KEY]?.let { runCatching { JSONArray(it) }.getOrNull() }
                ?.optJSONObject(button)?.optString("id")
            if (!id.isNullOrEmpty()) opened[TreebarsConstants.RICH_PUSH_BUTTON_ID_KEY] = id
        }
        Treebars.pushReceipt(context, opened = true, data = opened)
    }

    /** What needs no screen: copy, record an event, set a trait. True when it was one of those. */
    internal fun performInBackground(context: Context, action: JSONObject?): Boolean {
        if (action == null) return false
        when (action.optString("type")) {
            "copy" -> copy(context, action.optString("text"))
            "track_event" -> Treebars.track(action.optString("event_name"), stringMap(action.optJSONObject("properties")))
            "set_attribute" -> Treebars.setAttributeFromPush(action.optString("key"), action.optString("value"))
            else -> return false
        }
        return true
    }

    /** What opens something: a link, a page, the dialler, the share sheet, a screen of the app, or the app's own handler. */
    internal fun performInForeground(activity: Activity, action: JSONObject?) {
        if (action == null) {
            launchIntent(activity)?.let { runCatching { activity.startActivity(it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } }
            return
        }
        val type = action.optString("type")
        val intent: Intent? = when (type) {
            "deep_link", "rich_landing" -> action.optString("url").takeIf { it.isNotEmpty() }?.let { Intent(Intent.ACTION_VIEW, Uri.parse(it)) }
            "call" -> Intent(Intent.ACTION_DIAL, Uri.parse("tel:${action.optString("phone")}"))
            "share" -> Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, action.optString("text")), null)
            "navigate", "custom" -> {
                val values = if (type == "navigate") mapOf("screen" to action.optString("screen")) + stringMap(action.optJSONObject("params"))
                else stringMap(action.optJSONObject("data"))
                val handler = listener
                if (handler != null) {
                    runCatching { handler.onAction(type, values) }
                    null
                } else {
                    pendingAction = type to values
                    launchIntent(activity)?.apply { values.forEach { (key, value) -> putExtra(key, value) } }
                }
            }
            "" -> launchIntent(activity)
            else -> if (performInBackground(activity, action)) null else launchIntent(activity)
        }
        intent?.let { runCatching { activity.startActivity(it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } }
    }

    private fun launchIntent(context: Context): Intent? = context.packageManager.getLaunchIntentForPackage(context.packageName)

    private const val COUPON_COPIED_KEY = "treebars.push.coupon_copied.v1"

    /** Whether this is the first copy of this push's coupon on this device; remembers it if so. Bounded to 50. */
    @Synchronized
    internal fun firstCouponCopy(context: Context, data: Map<String, String>): Boolean {
        val delivery = data[TreebarsConstants.DELIVERY_ID_KEY]?.takeIf { it.isNotEmpty() } ?: return true
        val prefs = context.getSharedPreferences(Treebars.PREFS_NAME, Context.MODE_PRIVATE)
        val seen = prefs.getString(COUPON_COPIED_KEY, "").orEmpty().split(',').filter { it.isNotEmpty() }
        if (delivery in seen) return false
        prefs.edit().putString(COUPON_COPIED_KEY, (seen + delivery).takeLast(50).joinToString(",")).apply()
        return true
    }

    internal fun copy(context: Context, text: String) {
        if (text.isEmpty()) return
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return
        runCatching { clipboard.setPrimaryClip(ClipData.newPlainText("code", text)) }
    }

    private fun stringMap(json: JSONObject?): Map<String, String> =
        json?.keys()?.asSequence()?.associateWith { json.optString(it) } ?: emptyMap()
}

/**
 * Opened by a push's tap or by a button that opens something. Launched straight from the notification — Android 12
 * forbids starting an activity from a receiver a notification started — and finishes at once; it never draws.
 */
class TreebarsPushActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val data = TreebarsPush.dataOf(intent)
        val kind = intent.getStringExtra(TreebarsPush.EXTRA_KIND).orEmpty()
        val button = intent.getIntExtra(TreebarsPush.EXTRA_BUTTON, -1)
        val card = intent.getIntExtra(TreebarsPush.EXTRA_CARD, 0)
        TreebarsPush.reportTap(this, data, kind, button)
        cancel(this, data)
        TreebarsPush.performInForeground(this, TreebarsPush.actionOf(data, kind, button, card))
        finish()
    }
}

/** A button that needs no screen, a carousel's arrows, the coupon, and the notification swiped away. */
class TreebarsPushReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val data = TreebarsPush.dataOf(intent)
        val kind = intent.getStringExtra(TreebarsPush.EXTRA_KIND).orEmpty()
        val button = intent.getIntExtra(TreebarsPush.EXTRA_BUTTON, -1)
        val card = intent.getIntExtra(TreebarsPush.EXTRA_CARD, 0)
        when (kind) {
            "dismiss" -> {
                Treebars.pushReceipt(context, opened = false, data = data)
                cancelSteps(context, data)
            }
            /*
             * A timer's progress bar moves on: redrawn from the clock on the same tag, and only while
             * it is still in the tray — swiped, tapped or timed out, it is gone, and a step must not bring it back.
             */
            "tick" -> {
                if (!PushTemplates.stillShown(context, tagOf(data))) return
                val pending = goAsync()
                Thread {
                    try {
                        TreebarsPush.post(context.applicationContext, data, card)
                    } finally {
                        pending.finish()
                    }
                }.start()
            }
            // Redrawn on the same tag, so the notification changes in place. Fetching the card's image is network work,
            // which a receiver may do off its main thread for as long as `goAsync` allows.
            "card" -> {
                val pending = goAsync()
                Thread {
                    try {
                        TreebarsPush.post(context.applicationContext, data, card)
                    } finally {
                        pending.finish()
                    }
                }.start()
            }
            "coupon" -> {
                val code = data[TreebarsConstants.RICH_PUSH_OPTIONS_KEY]?.let { runCatching { JSONObject(it) }.getOrNull() }?.optString("coupon_code").orEmpty()
                TreebarsPush.copy(context, code)
                // Counted once per push: a person copying the code twice is one open in a report of opens, not two.
                if (TreebarsPush.firstCouponCopy(context, data)) TreebarsPush.reportTap(context, data, kind, button)
            }
            "button" -> {
                TreebarsPush.reportTap(context, data, kind, button)
                TreebarsPush.performInBackground(context, TreebarsPush.actionOf(data, kind, button, card))
                cancel(context, data)
            }
        }
    }
}

/**
 * A push receipt reported while the SDK is not yet initialised, kept until it can be sent.
 *
 * A tap or a swipe on an SDK-drawn push from a dead process runs [TreebarsPushActivity] or [TreebarsPushReceiver]
 * before anything else — and unless the host initialises in `Application.onCreate`, before `Treebars.initialize`.
 * `track` has no write key yet, so without this the tap would be lost: no `notification_opened`, and a `push_click`
 * in-app message never drawn. Under React Native initialisation always comes from JavaScript, so this is every cold
 * tap. So the receipt waits in preferences and [drain] hands it to `track` from `initialize`.
 *
 * Bounded: a person swiping away a stack of notifications from a device whose app never starts must not grow a
 * preferences file for ever. The newest are kept, because the newest are the ones a `push_click` message is about.
 */
internal object PendingPushReceipts {
    private const val KEY = "treebars.push.pending_receipts.v1"
    private const val MAX = 20

    @Synchronized
    fun add(context: Context, eventName: String, properties: Map<String, Any>) {
        val prefs = context.getSharedPreferences(Treebars.PREFS_NAME, Context.MODE_PRIVATE)
        val list = runCatching { JSONArray(prefs.getString(KEY, "[]")) }.getOrElse { JSONArray() }
        list.put(JSONObject().put("event", eventName).put("properties", JSONObject(properties)))
        val kept = JSONArray()
        for (i in maxOf(0, list.length() - MAX) until list.length()) kept.put(list.get(i))
        prefs.edit().putString(KEY, kept.toString()).apply()
    }

    /** Everything held, in the order it happened, and forgotten in the same step. */
    @Synchronized
    fun drain(context: Context): List<Pair<String, Map<String, Any>>> {
        val prefs = context.getSharedPreferences(Treebars.PREFS_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY, null) ?: return emptyList()
        prefs.edit().remove(KEY).apply()
        val list = runCatching { JSONArray(raw) }.getOrElse { return emptyList() }
        return (0 until list.length()).mapNotNull { index ->
            val entry = list.optJSONObject(index) ?: return@mapNotNull null
            val event = entry.optString("event").takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            val properties = entry.optJSONObject("properties") ?: JSONObject()
            event to properties.keys().asSequence().associateWith { properties.optString(it) as Any }
        }
    }
}

private fun cancel(context: Context, data: Map<String, String>) {
    val tag = tagOf(data)
    // A sticky push stays until the person acts on it — which this is.
    (context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager)?.cancel(tag, 0)
    cancelSteps(context, data)
}

/** The tag a push is posted under: its update key, else its delivery. */
private fun tagOf(data: Map<String, String>): String {
    val options = data[TreebarsConstants.RICH_PUSH_OPTIONS_KEY]?.let { runCatching { JSONObject(it) }.getOrNull() } ?: JSONObject()
    return options.optString("update_key").ifEmpty { data[TreebarsConstants.DELIVERY_ID_KEY] ?: "treebars" }
}

/** A timer's next progress step, taken back once the notification has gone. */
private fun cancelSteps(context: Context, data: Map<String, String>) {
    if (data[TreebarsConstants.RICH_PUSH_TEMPLATE_KEY] == null) return
    PushTemplates.cancelTick(context, PushTemplates.tickIntent(context, data, TreebarsPush.tickRequest(tagOf(data))))
}
