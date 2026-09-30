package com.treebars.sdk

import android.app.Activity
import android.app.Dialog
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Rect
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.LruCache
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import android.view.Window
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.FrameLayout
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import java.util.Locale
import java.util.concurrent.Executors

/*
 * A standard in-app message, drawn by this SDK. Kotlin and Swift draw every shape; React Native wraps them.
 *
 * The HTML host ([InAppHtmlHost]) draws a markup body in a WebView. This draws every other overlay, from the render
 * contract ([inAppRenderPlan]), in plain Android views — no Compose and no image library, because this module
 * carries neither and an SDK that adds one adds it to every app. It draws the plan and decides nothing the plan already
 * decided: the shape, the tokens, the lines, which buttons and where each goes, the form's controls and how the message
 * closes all arrive in [InAppRenderPlan.Overlay]. `InAppNativeViews.kt` turns the plan into views; this file puts them
 * on the screen, reports what the person did, and takes them down.
 *
 * With no app renderer registered this is what the SDK draws; `Treebars.setInAppRenderer` stays the override, and a
 * registered renderer is called as it always is while this draws nothing. Cards (`InAppRenderPlan.Card`) are not drawn
 * here.
 */

/**
 * What a drawn message tells the core. Intents only: every receipt, every spend and the presentation slot stay the
 * core's, as the HTML host's do, and the core takes the host down ([InAppNativeHost.destroy]) when the message ends.
 */
internal interface InAppNativeCore {
    /** Attached and on screen: counted as displayed now, and not before — a window that could not attach is no display. */
    fun shown()

    /** A button whose action is not `dismiss`: recorded with its index, then the message closes, then the core acts. */
    fun pressed(button: InAppPlanButton)

    /** The ✕, a tap on the dim, back, the timer or a `dismiss` button: a dismissal, however it came. */
    fun dismissed()

    /** The form passed [inAppFormProblem]; these are its [inAppFormAnswers]. The thanks stay up, and [answered] follows. */
    fun submitted(answers: Map<String, Any>)

    /** The thanks have been up for [InAppStandardLayout.FORM_THANKS_MS]: the message goes, and nothing more is recorded. */
    fun answered()
}

/**
 * The environment a plan is made in, read as the message is drawn from the screen it is drawn on — never cached, so a
 * phone switched to dark between two messages draws the second one dark. Night mode from the Activity's own
 * configuration, as [InAppStore.tokensFor] reads it (an app that forces dark through AppCompat changes its Activity's
 * configuration, and the application's keeps saying light); a tablet at 600dp across the narrow side, the same line
 * `data-tb-show` uses; the sync's project tokens as the fallback for a message queued before messages carried their own.
 *
 * `large` text from a font scale of 1.3, the line that sits beside iOS's accessibility sizes: at a large scale a
 * banner's words would be cut to "…", and the people who chose a scale that large are exactly the ones a cut message
 * fails.
 */
internal fun inAppRenderEnvFor(configuration: Configuration, fallback: InAppTokens?): InAppRenderEnv = InAppRenderEnv(
    appearance = if ((configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES) "dark" else "light",
    platform = "android",
    deviceClass = if (configuration.smallestScreenWidthDp >= 600) "tablet" else "mobile",
    fallbackTokens = fallback,
    textSize = if (configuration.fontScale >= LARGE_TEXT_FONT_SCALE) "large" else "default",
)

/** The font scale from which a plan is made for large text (the render fixture's `text-scale` decision). */
internal const val LARGE_TEXT_FONT_SCALE = 1.3f

/**
 * A plan colour as an Android colour. The plan writes every colour `#RRGGBBAA`, CSS's order, and [Color.parseColor]
 * reads an eight-digit hex as `#AARRGGBB` — so `#0F172A99`, the default dim, would come out an opaque dark red. Read by
 * hand, never passed through. Anything else is opaque black, which a plan never hands over.
 */
internal fun inAppPlanColourInt(value: String): Int {
    if (value.length != 9 || value[0] != '#') return Color.BLACK
    val bits = value.substring(1).toLongOrNull(16) ?: return Color.BLACK
    return Color.argb((bits and 0xFF).toInt(), ((bits shr 24) and 0xFF).toInt(), ((bits shr 16) and 0xFF).toInt(), ((bits shr 8) and 0xFF).toInt())
}

/**
 * One standard message on one screen: a Dialog for a modal and a fullscreen, and the Activity's own view tree for a
 * banner. Main thread only.
 *
 * - **A banner is not a Dialog.** A Dialog's window takes every touch on the screen, which a modal wants and a banner
 *   must not do: it is the one shape that leaves the app usable. It is added to the decor view in a wrapper only as
 *   tall as itself, as the nudge column is, so a touch anywhere else reaches the app; and back is the app's.
 * - **Back** closes a modal or a fullscreen only when the plan's `dismiss.back` says so, never an undismissable
 *   message; a tap on the dim when `backdrop_tap`; the timer from `after_ms`. Each is a dismissal.
 * - **Drawn under the bars**, the dim and a fullscreen's surface reaching the screen's edges, with the content padded
 *   inside the safe area from the window's own insets — the keyboard's included, so a form is never under it. Not
 *   `FLAG_LAYOUT_NO_LIMITS`, which the HTML host uses: a window laid out past the screen is never resized for the
 *   keyboard, and a form in it types blind.
 */
internal class InAppNativeHost(
    private val activity: Activity,
    private val plan: InAppRenderPlan.Overlay,
    private val core: InAppNativeCore,
    private val pictures: InAppPictureLoader = InAppPictures,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val main = Handler(Looper.getMainLooper())
    private var dialog: Dialog? = null
    private var banner: View? = null
    private var closed = false

    /**
     * A press or a dismissal has been reported, so the message is ending: a second tap in the frame before the core takes
     * it down is not a second answer. A sent form is not settled — its ✕ and its buttons still work through the thanks.
     */
    private var settled = false

    /** The screen this message is drawn over, so the core can take it down with it. */
    val owner: Activity get() = activity

    internal lateinit var views: InAppNativeViews
        private set

    /** The Dialog a modal or a fullscreen is in, for a test; null for a banner. */
    internal val window: Dialog? get() = dialog

    private val events = object : InAppNativeViews.Events {
        override fun press(button: InAppPlanButton) {
            if (closed || settled) return
            settled = true
            // A `dismiss` button is a dismissal, never a click: it records `in_app_dismissed` and spends the message.
            if (button.action == "dismiss") core.dismissed() else core.pressed(button)
        }

        override fun dismiss() {
            if (closed || settled) return
            settled = true
            core.dismissed()
        }

        override fun submit(answers: Map<String, Any>) {
            if (closed || settled) return
            core.submitted(answers)
            main.postDelayed({
                if (closed || settled) return@postDelayed
                settled = true
                core.answered()
            }, InAppStandardLayout.FORM_THANKS_MS.toLong())
        }
    }

    /**
     * Draws it, and says whether it appeared. False when the window could not attach — the Activity's token went, or
     * its decor view is not there — and then nothing is counted and the core keeps the message for the next screen. A
     * plan the views cannot be built from throws, which the core reports as a render failure.
     */
    fun show(): Boolean {
        views = InAppNativeViews(activity, plan, events, pictures, now, main)
        val attached = if (plan.shape == "banner") attachBanner() else attachDialog()
        if (!attached) {
            destroy()
            return false
        }
        core.shown()
        // From the moment it appeared, not from when it was built: a timer is how long somebody could read it.
        plan.dismiss.afterMs?.let { delay -> main.postDelayed({ events.dismiss() }, delay) }
        views.start()
        enter()
        return true
    }

    private fun attachDialog(): Boolean {
        val created = Dialog(activity, android.R.style.Theme_Translucent_NoTitleBar)
        created.requestWindowFeature(Window.FEATURE_NO_TITLE)
        created.setContentView(views.root)
        created.setCancelable(plan.dismiss.back)
        // The dim is ours to answer (`backdrop_tap`); the window fills the screen, so nothing is ever outside it anyway.
        created.setCanceledOnTouchOutside(false)
        created.setOnCancelListener { events.dismiss() }
        // The window's name is what TalkBack reads as it appears: the dialog named by its title.
        plan.title?.text?.let { created.setTitle(it) }
        created.window?.let(::edgeToEdge)
        dialog = created
        return try {
            created.show()
            true
        } catch (error: Throwable) {
            // `BadTokenException`: the Activity was finishing between the look and the draw. Transient, so not a failure.
            TreebarsLogger.log("in-app: could not attach a native message: $error")
            false
        }
    }

    private fun edgeToEdge(window: Window) {
        window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        window.setLayout(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT)
        // Ours is the fade (`plan.animation`); the theme's own window animation on top of it would be a second entrance.
        window.setWindowAnimations(0)
        @Suppress("DEPRECATION")
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        window.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS)
        @Suppress("DEPRECATION")
        run {
            window.statusBarColor = Color.TRANSPARENT
            window.navigationBarColor = Color.TRANSPARENT
        }
        if (Build.VERSION.SDK_INT >= 28) {
            window.attributes = window.attributes.apply { layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES }
        }
        // The bars' icons dark over a light fullscreen surface, where light ones would vanish; light over the dim.
        val lightBars = plan.shape == "fullscreen" && isLight(inAppPlanColourInt(plan.tokens.surface))
        if (Build.VERSION.SDK_INT >= 30) {
            // Deprecated at 35, where every window is edge to edge already; it is the switch on 30 to 34.
            @Suppress("DEPRECATION")
            window.setDecorFitsSystemWindows(false)
            val light = android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS
            window.insetsController?.setSystemBarsAppearance(if (lightBars) light else 0, light)
        } else {
            @Suppress("DEPRECATION")
            var flags = View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            @Suppress("DEPRECATION")
            if (lightBars) flags = flags or View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = flags
        }
    }

    private fun isLight(colour: Int): Boolean =
        (0.299 * Color.red(colour) + 0.587 * Color.green(colour) + 0.114 * Color.blue(colour)) > 160

    private fun attachBanner(): Boolean {
        val decor = activity.window?.decorView as? ViewGroup ?: return false
        val safe = safeInsets(decor)
        val margin = views.dp(InAppStandardLayout.BANNER_MARGIN)
        val top = plan.edge == "top"
        val params = FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, if (top) Gravity.TOP else Gravity.BOTTOM).apply {
            leftMargin = safe.left + margin
            rightMargin = safe.right + margin
            if (top) topMargin = safe.top + margin else bottomMargin = safe.bottom + margin
        }
        return try {
            decor.addView(views.root, params)
            banner = views.root
            true
        } catch (error: Throwable) {
            TreebarsLogger.log("in-app: could not attach a native banner: $error")
            false
        }
    }

    /** The screen's safe area in pixels: the bars and the cutout, from the platform's own insets (no androidx.core here). */
    private fun safeInsets(decor: View): Rect {
        val raw = decor.rootWindowInsets ?: return Rect()
        return if (Build.VERSION.SDK_INT >= 30) {
            val bars = raw.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            Rect(bars.left, bars.top, bars.right, bars.bottom)
        } else {
            @Suppress("DEPRECATION")
            Rect(raw.systemWindowInsetLeft, raw.systemWindowInsetTop, raw.systemWindowInsetRight, raw.systemWindowInsetBottom)
        }
    }

    /** A modal and a fullscreen fade in; a banner slides in from its edge, once it knows how tall it is. */
    private fun enter() {
        val root = views.root
        if (plan.animation == "fade") {
            root.alpha = 0f
            root.animate().alpha(1f).setDuration(ENTRANCE_MS).start()
            return
        }
        root.visibility = View.INVISIBLE
        root.viewTreeObserver.addOnPreDrawListener(object : ViewTreeObserver.OnPreDrawListener {
            override fun onPreDraw(): Boolean {
                root.viewTreeObserver.removeOnPreDrawListener(this)
                if (closed) return true
                val params = root.layoutParams as? ViewGroup.MarginLayoutParams
                val fromTop = plan.animation == "slide_top"
                val away = (root.height + ((if (fromTop) params?.topMargin else params?.bottomMargin) ?: 0)).toFloat()
                root.translationY = if (fromTop) -away else away
                root.visibility = View.VISIBLE
                root.animate().translationY(0f).setDuration(ENTRANCE_MS).start()
                return true
            }
        })
    }

    /** Takes it all down, quietly: whoever called says what it meant. */
    fun destroy() {
        if (closed) return
        closed = true
        main.removeCallbacksAndMessages(null)
        if (::views.isInitialized) views.stop()
        runCatching { dialog?.dismiss() }
        banner?.let { view -> runCatching { (view.parent as? ViewGroup)?.removeView(view) } }
        dialog = null
        banner = null
    }

    private companion object {
        const val ENTRANCE_MS = 200L
    }
}

/** Fetches a picture off the main thread and hands it back on the main thread, or null when it could not be had. */
internal fun interface InAppPictureLoader {
    fun load(url: String, done: (Bitmap?) -> Unit)
}

/**
 * The pictures a standard message draws: read from the asset cache when the address is a store file the sync's prefetch
 * kept, so a message drawn offline still has its picture; fetched as it is drawn otherwise. A
 * placeholder at the picture's final size is drawn meanwhile and stays if the fetch fails — a skeleton shaped like the
 * thing, never a box that collapses and moves everything under it once the answer arrives.
 *
 * No image library: this module carries none. `http` and `https` only — the platform's network security config still
 * decides cleartext — sampled down so a camera-sized upload does not take a phone's memory, and a few kept, so a
 * carousel going round does not fetch its pictures again.
 */
internal object InAppPictures : InAppPictureLoader {
    private const val TIMEOUT_MS = 8_000
    private const val MAX_BYTES = 10 * 1024 * 1024
    private const val MAX_SIDE = 1600
    private val kept = object : LruCache<String, Bitmap>(16 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap): Int = value.byteCount
    }
    private val worker = Executors.newFixedThreadPool(2) { run -> Thread(run, "treebars-in-app-pictures").apply { isDaemon = true } }
    private val main = Handler(Looper.getMainLooper())

    /** The prefetched files, set by `initialize`. */
    @Volatile
    internal var assets: InAppAssetCache? = null

    override fun load(url: String, done: (Bitmap?) -> Unit) {
        kept.get(url)?.let { return done(it) }
        val scheme = runCatching { URI(url).scheme?.lowercase(Locale.ROOT) }.getOrNull()
        if (scheme != "https" && scheme != "http") return done(null)
        worker.execute {
            val picture = runCatching { fetch(url) }.onFailure { TreebarsLogger.log("in-app: picture $url could not be fetched: $it") }.getOrNull()
            picture?.let { kept.put(url, it) }
            main.post { done(picture) }
        }
    }

    private fun fetch(url: String): Bitmap? {
        assets?.pictureBytes(url)?.let { held -> decode(held)?.let { return it } }
        val connection = URI(url).toURL().openConnection() as HttpURLConnection
        connection.connectTimeout = TIMEOUT_MS
        connection.readTimeout = TIMEOUT_MS
        try {
            if (connection.responseCode !in 200..299) return null
            val bytes = connection.inputStream.use(::capped) ?: return null
            return decode(bytes)
        } finally {
            connection.disconnect()
        }
    }

    /** Sampled down so a camera-sized upload does not take a phone's memory. */
    private fun decode(bytes: ByteArray): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > MAX_SIDE) sample *= 2
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
    }

    private fun capped(stream: InputStream): ByteArray? {
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(16 * 1024)
        while (true) {
            val read = stream.read(buffer)
            if (read < 0) return out.toByteArray()
            out.write(buffer, 0, read)
            if (out.size() > MAX_BYTES) return null
        }
    }
}
