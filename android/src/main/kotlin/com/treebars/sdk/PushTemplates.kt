package com.treebars.sdk

import android.app.AlarmManager
import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.os.Build
import android.os.SystemClock
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject

/**
 * A push template as the server sent it: the layout, its colours, and — for a timer — the two moments it counts
 * between, already resolved for this person. The authored end ("90 minutes", "18:00 on their clock") never reaches the
 * device; the server decided it.
 *
 * `PushTemplatesTest` pins this reading: it parses every case of a shared wire-format fixture and checks what came out.
 */
internal data class PushTemplateSpec(
    val kind: String,
    val background: Int?,
    val title: Int?,
    val body: Int?,
    val appName: Int?,
    /** Light or dark text where the author set no colour — so it stays legible on the background chosen. */
    val controlsLight: Boolean,
    val controlsSet: Boolean,
    val textOverlay: Boolean,
    val collapsedImage: String?,
    val fit: Boolean,
    val timerColor: Int?,
    val startsAt: Long?,
    val endsAt: Long?,
) {
    val isTimer: Boolean get() = kind == "timer" || kind == "timer_progress"

    companion object {
        private val KINDS = setOf("stylized", "image_banner", "timer", "timer_progress")
        private val HEX = Regex("^#[0-9a-fA-F]{6}$")

        /** `#RRGGBB` as an opaque ARGB integer; null for anything else, which then draws in the system's own colour. */
        fun colour(value: String?): Int? =
            value?.takeIf { HEX.matches(it) }?.let { (0xFF000000L or it.substring(1).toLong(16)).toInt() }

        /**
         * The template, or null when there is none this SDK can draw — an unknown kind, or a timer without its two
         * moments. Null draws the basic push from the same title and body: the backup.
         */
        fun parse(raw: String?): PushTemplateSpec? {
            val json = raw?.takeIf { it.isNotEmpty() }?.let { runCatching { JSONObject(it) }.getOrNull() } ?: return null
            val kind = json.optString("kind")
            if (kind !in KINDS) return null
            val startsAt = if (json.has("starts_at")) json.optLong("starts_at") else null
            val endsAt = if (json.has("ends_at")) json.optLong("ends_at") else null
            val timer = kind == "timer" || kind == "timer_progress"
            if (timer && (startsAt == null || endsAt == null || endsAt <= startsAt)) return null
            fun text(key: String) = json.optString(key).takeIf { it.isNotEmpty() }
            return PushTemplateSpec(
                kind = kind,
                background = colour(text("background_color")),
                title = colour(text("title_color")),
                body = colour(text("body_color")),
                appName = colour(text("app_name_color")),
                controlsLight = text("controls") == "light",
                controlsSet = text("controls") != null,
                textOverlay = json.optBoolean("text_overlay", false),
                collapsedImage = text("collapsed_image_url"),
                fit = text("image_scale") == "fit",
                timerColor = colour(text("timer_color")),
                startsAt = if (timer) startsAt else null,
                endsAt = if (timer) endsAt else null,
            )
        }
    }
}

/**
 * Draws a push template as custom views inside the system's own decoration.
 *
 * `Notification.DecoratedCustomViewStyle`, not a bare custom view: from Android 12 the system decorates every custom
 * notification whatever an app asks, and on earlier versions the decoration is what gives it the app's icon, name, time
 * and expand arrow. So the template owns the content area — its background, its words and their colours, a countdown,
 * a progress bar, an image — and the header is the system's, tinted by `setColor` where the version allows.
 *
 * Platform APIs only, like the rest of the push renderer: no androidx-core for `NotificationCompat`.
 */
internal object PushTemplates {
    /** How often a progress bar moves: about a hundred times over the timer, never more than once a minute. */
    internal const val MIN_TICK_MS = 60_000L
    private const val TICK_STEPS = 100L

    private const val LIGHT_TITLE = 0xFFFFFFFF.toInt()
    private const val LIGHT_BODY = 0xE6FFFFFF.toInt()
    private const val DARK_TITLE = 0xFF111827.toInt()
    private const val DARK_BODY = 0xFF374151.toInt()

    /**
     * Whether a timer's progress bar can be moved on: an exact alarm, which from Android 12 needs the app's own
     * `SCHEDULE_EXACT_ALARM` (asked of the person from Android 14). Declared by the app, never by this library — a
     * permission in a library's manifest is forced onto every app that uses it. Without it the timer draws with no
     * progress bar.
     */
    internal var canTick: (Context) -> Boolean = { context ->
        if (Build.VERSION.SDK_INT < 31) true
        else (context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager)?.canScheduleExactAlarms() == true
    }

    /** The collapsed and the expanded view for one template, at `now`. */
    fun views(
        context: Context,
        spec: PushTemplateSpec,
        title: String,
        body: String,
        picture: Bitmap?,
        collapsedPicture: Bitmap?,
        now: Long,
        progress: Boolean,
    ): Pair<RemoteViews, RemoteViews> {
        if (spec.kind == "image_banner") {
            val expanded = RemoteViews(context.packageName, R.layout.treebars_push_banner)
            spec.background?.let { expanded.setInt(R.id.treebars_push_root, "setBackgroundColor", it) }
            image(expanded, picture, spec.fit)
            if (spec.textOverlay) {
                expanded.setViewVisibility(R.id.treebars_push_below, View.GONE)
                expanded.setViewVisibility(R.id.treebars_push_overlay, View.VISIBLE)
                words(expanded, spec, title, body, R.id.treebars_push_overlay_title, R.id.treebars_push_overlay_body, overImage = true)
            } else {
                words(expanded, spec, title, body, R.id.treebars_push_title, R.id.treebars_push_body, overImage = false)
            }
            val collapsed = if (collapsedPicture != null) {
                RemoteViews(context.packageName, R.layout.treebars_push_banner_collapsed).also { image(it, collapsedPicture, spec.fit) }
            } else {
                // No image of its own for the collapsed view: the words, the same as the backup.
                textViews(context, spec, title, body, null, now, progress = false)
            }
            return collapsed to expanded
        }
        return textViews(context, spec, title, body, null, now, progress) to textViews(context, spec, title, body, picture, now, progress)
    }

    /** The stylised basic and both timers: one layout, the image only when expanded. */
    private fun textViews(context: Context, spec: PushTemplateSpec, title: String, body: String, picture: Bitmap?, now: Long, progress: Boolean): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.treebars_push_template)
        spec.background?.let { views.setInt(R.id.treebars_push_root, "setBackgroundColor", it) }
        words(views, spec, title, body, R.id.treebars_push_title, R.id.treebars_push_body, overImage = false)
        if (spec.isTimer) {
            val left = (spec.endsAt!! - now).coerceAtLeast(0)
            views.setViewVisibility(R.id.treebars_push_timer, View.VISIBLE)
            // The system ticks a chronometer by itself, so a countdown costs no wakeups: its base is when it reaches 0.
            views.setChronometer(R.id.treebars_push_timer, SystemClock.elapsedRealtime() + left, null, true)
            views.setChronometerCountDown(R.id.treebars_push_timer, true)
            (spec.timerColor ?: defaultTitle(spec))?.let { views.setTextColor(R.id.treebars_push_timer, it) }
            if (spec.kind == "timer_progress" && progress) {
                val total = (spec.endsAt - spec.startsAt!!).coerceAtLeast(1)
                val done = ((now - spec.startsAt) * 1000 / total).coerceIn(0, 1000).toInt()
                views.setViewVisibility(R.id.treebars_push_progress, View.VISIBLE)
                views.setProgressBar(R.id.treebars_push_progress, 1000, done, false)
            }
        }
        if (picture != null) {
            views.setViewVisibility(R.id.treebars_push_image, View.VISIBLE)
            views.setImageViewBitmap(R.id.treebars_push_image, picture)
        }
        return views
    }

    private fun image(views: RemoteViews, picture: Bitmap?, fit: Boolean) {
        val shown = if (fit) R.id.treebars_push_image_fit else R.id.treebars_push_image
        val hidden = if (fit) R.id.treebars_push_image else R.id.treebars_push_image_fit
        views.setViewVisibility(hidden, View.GONE)
        views.setViewVisibility(shown, if (picture != null) View.VISIBLE else View.GONE)
        picture?.let { views.setImageViewBitmap(shown, it) }
    }

    private fun words(views: RemoteViews, spec: PushTemplateSpec, title: String, body: String, titleId: Int, bodyId: Int, overImage: Boolean) {
        views.setTextViewText(titleId, title)
        views.setTextViewText(bodyId, body)
        // Words over a picture are white unless the author said otherwise: the picture decides the background.
        (spec.title ?: if (overImage) LIGHT_TITLE else defaultTitle(spec))?.let { views.setTextColor(titleId, it) }
        (spec.body ?: if (overImage) LIGHT_BODY else defaultBody(spec))?.let { views.setTextColor(bodyId, it) }
        if (body.isEmpty()) views.setViewVisibility(bodyId, View.GONE)
    }

    private fun defaultTitle(spec: PushTemplateSpec): Int? = if (!spec.controlsSet) null else if (spec.controlsLight) LIGHT_TITLE else DARK_TITLE
    private fun defaultBody(spec: PushTemplateSpec): Int? = if (!spec.controlsSet) null else if (spec.controlsLight) LIGHT_BODY else DARK_BODY

    /**
     * Puts the template on the builder: the decoration, both views, the header's tint, and for a timer the moment it
     * leaves the tray. Returns when the next progress step is due, or null when there is none to schedule.
     */
    fun decorate(
        context: Context,
        builder: Notification.Builder,
        spec: PushTemplateSpec,
        title: String,
        body: String,
        picture: Bitmap?,
        collapsedPicture: Bitmap?,
        now: Long,
    ): Long? {
        val progress = spec.kind == "timer_progress" && canTick(context)
        val (collapsed, expanded) = views(context, spec, title, body, picture, collapsedPicture, now, progress)
        builder.setStyle(Notification.DecoratedCustomViewStyle())
        builder.setCustomContentView(collapsed)
        builder.setCustomBigContentView(expanded)
        // The header's accent: the small icon and, before Android 12, the app's name.
        spec.appName?.let { builder.setColor(it) }
        if (!spec.isTimer) return null
        // Redrawn as the bar moves; only the first post may make a sound.
        builder.setOnlyAlertOnce(true)
        if (Build.VERSION.SDK_INT >= 26) builder.setTimeoutAfter((spec.endsAt!! - now).coerceAtLeast(1))
        if (!progress) return null
        val step = maxOf(MIN_TICK_MS, (spec.endsAt!! - spec.startsAt!!) / TICK_STEPS)
        val next = now + step
        return if (next < spec.endsAt) next else null
    }

    /**
     * Asks for the next progress step. `RTC`, not `RTC_WAKEUP`: a bar nobody can see need not wake the phone, and the
     * step that is due when the screen comes on draws the right place, because progress is read from the clock.
     */
    fun scheduleTick(context: Context, intent: PendingIntent, at: Long) {
        val alarms = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        runCatching { alarms.setExact(AlarmManager.RTC, at, intent) }.onFailure { TreebarsLogger.log("push: timer step not scheduled: $it") }
    }

    fun cancelTick(context: Context, intent: PendingIntent) {
        (context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager)?.cancel(intent)
    }

    /** Whether the notification under this tag is still in the tray — a step for one that is gone draws nothing. */
    fun stillShown(context: Context, tag: String): Boolean {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? android.app.NotificationManager ?: return false
        return manager.activeNotifications.any { it.tag == tag }
    }

    /** The intent a step arrives on: the push's own data, so a step redraws exactly what was sent. */
    fun tickIntent(context: Context, data: Map<String, String>, request: Int): PendingIntent {
        val intent = Intent(context, TreebarsPushReceiver::class.java)
            .putExtra(TreebarsPush.EXTRA_DATA, JSONObject(data as Map<*, *>).toString())
            .putExtra(TreebarsPush.EXTRA_KIND, "tick")
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getBroadcast(context, request, intent, flags)
    }
}
