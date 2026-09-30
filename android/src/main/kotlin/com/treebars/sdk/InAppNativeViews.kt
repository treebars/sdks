package com.treebars.sdk

import android.app.Activity
import android.app.DatePickerDialog
import android.app.Dialog
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.InsetDrawable
import android.graphics.drawable.RippleDrawable
import android.os.Build
import android.os.Handler
import android.text.Editable
import android.text.InputType
import android.text.TextUtils
import android.text.TextWatcher
import android.util.TypedValue
import android.view.Gravity
import android.view.Menu
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.accessibility.AccessibilityNodeInfo
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.PopupMenu
import android.widget.RadioButton
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import java.util.Calendar
import java.util.Locale
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

/*
 * The views a standard in-app message is drawn with, built from its plan. [InAppNativeHost] puts them on the screen;
 * this only turns an [InAppRenderPlan.Overlay] into views, in the contract's order — picture, title, body, carousel,
 * countdown, form, buttons — with the contract's numbers ([InAppStandardLayout], pinned to the fixture's `layout` block).
 *
 * Every size of text is in sp, so the person's text size applies; every other length is dp. Right to left is mirrored
 * here, by hand, from the plan's `direction`, and the whole message is laid out left to right underneath: an app that
 * does not declare `android:supportsRtl` has every `layoutDirection` ignored, so relying on it would draw an Arabic
 * message the right way round in one app and the wrong way round in the next, and mixing the two would reverse a row
 * twice in the apps that do.
 */

/** What the drawn parts are found by — this SDK's tests, and an app's own UI tests. */
internal object InAppNativeTags {
    const val DIM = "treebars:dim"
    const val CARD = "treebars:card"
    const val BANNER = "treebars:banner"
    const val FULLSCREEN = "treebars:fullscreen"
    const val PICTURE = "treebars:picture"
    const val TITLE = "treebars:title"
    const val BODY = "treebars:body"
    const val CAROUSEL = "treebars:carousel"
    const val PREVIOUS = "treebars:previous"
    const val NEXT = "treebars:next"
    const val SLIDE_COUNT = "treebars:slide-count"
    const val COUNTDOWN = "treebars:countdown"
    const val FORM = "treebars:form"
    const val PROBLEM = "treebars:problem"
    const val SEND = "treebars:send"
    const val THANKS = "treebars:thanks"
    const val BUTTONS = "treebars:buttons"
    const val CLOSE = "treebars:close"
    fun button(index: Int) = "treebars:button:$index"
    fun field(id: String) = "treebars:field:$id"
    fun option(id: String, value: String) = "treebars:field:$id:$value"
}

internal class InAppNativeViews(
    private val context: Activity,
    private val plan: InAppRenderPlan.Overlay,
    private val events: Events,
    private val pictures: InAppPictureLoader,
    private val now: () -> Long,
    private val handler: Handler,
) {
    /** What a person did. The host decides what each means; nothing here records or spends anything. */
    interface Events {
        fun press(button: InAppPlanButton)
        fun dismiss()
        fun submit(answers: Map<String, Any>)
    }

    private val density = context.resources.displayMetrics.density

    fun dp(value: Int): Int = (value * density).roundToInt()
    private fun dp(value: Double): Float = (value * density).toFloat()

    private val rtl = plan.direction == "rtl"
    private val startSide = if (rtl) Gravity.RIGHT else Gravity.LEFT
    private val endSide = if (rtl) Gravity.LEFT else Gravity.RIGHT

    private val accent = inAppPlanColourInt(plan.tokens.accent)
    private val onAccent = inAppPlanColourInt(plan.tokens.onAccent)
    private val surface = inAppPlanColourInt(plan.tokens.surface)
    private val onSurface = inAppPlanColourInt(plan.tokens.onSurface)
    private val muted = inAppPlanColourInt(plan.tokens.onSurfaceMuted)
    private val backdrop = inAppPlanColourInt(plan.tokens.backdrop)
    private val problemColour = inAppPlanColourInt(InAppStandardLayout.FORM_PROBLEM_COLOUR)
    /** Where a picture will be, until it is: the muted words' colour, faint. */
    private val placeholder = withAlpha(muted, 0x1F)

    private val family = InAppFonts.family(context, plan.tokens.fontFamily)
    private val regular = InAppFonts.weight(family, 400)
    private val semibold = InAppFonts.weight(family, InAppStandardLayout.BUTTON_WEIGHT)
    private val bold = InAppFonts.weight(family, InAppStandardLayout.TITLE_WEIGHT)

    /*
     * Declared before [root], which assigns them while it is built: Kotlin initialises properties in declaration order,
     * and one declared after with `= null` would be put back to null the moment the builder had set it.
     */
    private var stopped = false
    private var countdown: Countdown? = null
    /** The platform's date picker or menu, opened from a form field, which goes when the message does. */
    private var picker: Any? = null

    /** The message: the dim holding a card, the banner's card, or the fullscreen's window. */
    val root: View = when (plan.shape) {
        "banner" -> banner()
        "fullscreen" -> fullscreen()
        else -> modal()
    }.also { root ->
        root.layoutDirection = View.LAYOUT_DIRECTION_LTR
        // A pane's title is read out as it appears — the banner's, which has no window of its own to be named by.
        if (Build.VERSION.SDK_INT >= 28) plan.title?.let { root.accessibilityPaneTitle = it.text }
    }

    /** It is on screen: the countdown starts counting. */
    fun start() {
        countdown?.start()
    }

    /** It is going: nothing it started goes on without it. The host's handler drops the ticks. */
    fun stop() {
        stopped = true
        when (val open = picker) {
            is Dialog -> runCatching { open.dismiss() }
            is PopupMenu -> runCatching { open.dismiss() }
        }
        picker = null
    }

    // ---- The three shapes ------------------------------------------------------------------------------------------

    /**
     * A card centred on the dim, at most 320 wide with 16 either side, scrolling inside itself when it is taller than the
     * window. The ✕ sits over the card rather than in the scroll, so it is there however far somebody has scrolled.
     */
    private fun modal(): View {
        val content = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        plan.image?.let { content.addView(picture(it, 0f), matchWrap()) }
        // With no picture above it, the title would run under the ✕: it keeps clear of the corner instead.
        val clear = if (plan.image == null && plan.dismiss.control) TOUCH_TARGET + CLOSE_INSET - PADDING else 0
        content.addView(column(PADDING, PADDING, PADDING, clear), matchWrap())
        val card = CappedFrame(context, dp(InAppStandardLayout.MODAL_MAX_WIDTH)).apply {
            tag = InAppNativeTags.CARD
            background = RoundedFill(surface, dp(plan.tokens.radius))
            clipToOutline = true
            // A tap on the card is not a tap on the dim behind it.
            isClickable = true
            addView(ScrollView(context).apply { addView(content, matchWrap()) }, FrameLayout.LayoutParams(MATCH, WRAP))
            if (plan.dismiss.control) addView(close(over = plan.image != null), corner(plan.dismiss.corner))
        }
        return FrameLayout(context).apply {
            tag = InAppNativeTags.DIM
            setBackgroundColor(backdrop)
            // The dim is not a thing to read; the ✕ and back are how a screen reader closes the message.
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            if (plan.dismiss.backdropTap) setOnClickListener { events.dismiss() }
            insetBySafeArea(this)
            val margin = dp(InAppStandardLayout.MODAL_MARGIN)
            addView(card, FrameLayout.LayoutParams(MATCH, WRAP, Gravity.CENTER).apply { setMargins(margin, margin, margin, margin) })
        }
    }

    /**
     * One row: the thumbnail leading, the words taking what is left, the one button trailing, and the ✕ at the end.
     * The ✕ is a member of the row rather than laid over it, so a trailing button is never under it.
     *
     * The words scroll, and the row stops at half the screen: at a large text size the plan cuts them nowhere and puts
     * the button under them (the render fixture's `text-scale` decision), and a banner grown to fit would cover the app
     * it exists to leave usable. The thumbnail and the ✕ are outside the scroll, so the way out never scrolls away.
     */
    private fun banner(): View {
        val row = InAppBannerRow(context, context.resources.displayMetrics.heightPixels / 2).apply {
            tag = InAppNativeTags.BANNER
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = RoundedFill(surface, dp(plan.tokens.radius))
            clipToOutline = true
            // Touches on the banner are the banner's; everywhere else they are the app's.
            isClickable = true
            setPadding(dp(BANNER_PADDING), dp(BANNER_PADDING), dp(BANNER_PADDING), dp(BANNER_PADDING))
        }
        val parts = mutableListOf<Pair<View, LinearLayout.LayoutParams>>()
        plan.image?.let {
            val side = dp(InAppStandardLayout.BANNER_THUMBNAIL)
            parts += picture(it, minOf(dp(plan.tokens.radius), side / 4f)) to LinearLayout.LayoutParams(side, side)
        }
        val words = ScrollView(context).apply { addView(column(BANNER_WORDS_ACROSS, BANNER_WORDS_DOWN, BANNER_WORDS_DOWN, 0), matchWrap()) }
        parts += words to LinearLayout.LayoutParams(0, WRAP, 1f)
        if (plan.buttonsAt == "trailing") plan.buttons.firstOrNull()?.let { parts += button(it) to LinearLayout.LayoutParams(WRAP, WRAP) }
        if (plan.dismiss.control) {
            parts += close(over = false) to LinearLayout.LayoutParams(dp(TOUCH_TARGET), dp(TOUCH_TARGET)).apply {
                gravity = Gravity.TOP
                // Tucked into the corner, where the row's own padding would hold it off.
                topMargin = -dp(CLOSE_TUCK)
                if (rtl) leftMargin = -dp(CLOSE_TUCK) else rightMargin = -dp(CLOSE_TUCK)
            }
        }
        (if (rtl) parts.reversed() else parts).forEach { (view, params) -> row.addView(view, params) }
        return row
    }

    /**
     * The whole window in `surface`, the content inside the safe area — held to `content_max_width` and centred on a
     * tablet — the picture across the content, the words scrolling, and the buttons pinned to the bottom rather than
     * after the words, so they are where a thumb is however long the words run.
     */
    private fun fullscreen(): View {
        val content = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        plan.image?.let { content.addView(picture(it, 0f), matchWrap()) }
        // With no picture, the words start below the ✕ rather than under it.
        val top = if (plan.image == null && plan.dismiss.control) TOUCH_TARGET + CLOSE_INSET * 2 else PADDING
        content.addView(column(PADDING, top, PADDING, 0), matchWrap())
        val column = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            addView(ScrollView(context).apply { addView(content, matchWrap()) }, LinearLayout.LayoutParams(MATCH, 0, 1f))
            if (plan.buttonsAt == "bottom" && plan.buttons.isNotEmpty()) {
                addView(buttons().apply { setPadding(dp(PADDING), dp(PADDING / 2), dp(PADDING), dp(PADDING)) }, matchWrap())
            }
        }
        val holder: ViewGroup = plan.contentMaxWidth?.let { CappedFrame(context, dp(it)) } ?: FrameLayout(context)
        holder.addView(column, FrameLayout.LayoutParams(MATCH, MATCH))
        return FrameLayout(context).apply {
            tag = InAppNativeTags.FULLSCREEN
            setBackgroundColor(surface)
            insetBySafeArea(this)
            addView(holder, FrameLayout.LayoutParams(MATCH, MATCH, Gravity.CENTER_HORIZONTAL))
            if (plan.dismiss.control) addView(close(over = plan.image != null), corner(plan.dismiss.corner))
        }
    }

    /**
     * Pads a full-window view by the bars, the cutout and the keyboard, as the window reports them — the keyboard's
     * height included, which is what keeps a form's field above it.
     */
    private fun insetBySafeArea(view: View) {
        view.setOnApplyWindowInsetsListener { target, insets ->
            if (Build.VERSION.SDK_INT >= 30) {
                val safe = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout() or WindowInsets.Type.ime())
                target.setPadding(safe.left, safe.top, safe.right, safe.bottom)
                WindowInsets.CONSUMED
            } else {
                @Suppress("DEPRECATION")
                target.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop, insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
                @Suppress("DEPRECATION")
                insets.consumeSystemWindowInsets()
            }
        }
    }

    // ---- The words, in the contract's order ------------------------------------------------------------------------

    /** Title, body, carousel, countdown, form — and the buttons, where the plan puts them after the words. */
    private fun column(across: Int, top: Int, bottom: Int, clearTitleEnd: Int): LinearLayout {
        val blocks = mutableListOf<View>()
        plan.title?.let { blocks += title(it, clearTitleEnd) }
        plan.body?.let { blocks += body(it) }
        plan.slides?.let { blocks += carousel(it) }
        plan.countdownToMs?.takeIf { inAppCountdownText(it, now()).isNotEmpty() }?.let { blocks += Countdown(it).also { part -> countdown = part }.view }
        plan.form?.let { blocks += Form(it).view }
        if (plan.buttonsAt == "content" && plan.buttons.isNotEmpty()) blocks += buttons()
        return stack(blocks, GAP).apply { setPadding(dp(across), dp(top), dp(across), dp(bottom)) }
    }

    private fun title(text: InAppPlanText, clearEnd: Int): TextView =
        words(text.text, InAppStandardLayout.TITLE_SIZE, bold, onSurface, text.maxLines).apply {
            tag = InAppNativeTags.TITLE
            if (Build.VERSION.SDK_INT >= 28) isAccessibilityHeading = true
            if (clearEnd > 0) if (rtl) setPadding(dp(clearEnd), 0, 0, 0) else setPadding(0, 0, dp(clearEnd), 0)
        }

    private fun body(text: InAppPlanText): TextView =
        words(text.text, InAppStandardLayout.BODY_SIZE, regular, muted, text.maxLines).apply {
            tag = InAppNativeTags.BODY
            lineHeight(InAppStandardLayout.BODY_LINE_HEIGHT)
        }

    /** Words in sp, from the message's start, cut at [lines] with an ellipsis when the plan cuts them. */
    private fun words(value: String, sizeSp: Int, face: Typeface, colour: Int, lines: Int?): TextView = TextView(context).apply {
        text = value
        setTextSize(TypedValue.COMPLEX_UNIT_SP, sizeSp.toFloat())
        typeface = face
        setTextColor(colour)
        gravity = startSide
        textDirection = if (rtl) View.TEXT_DIRECTION_RTL else View.TEXT_DIRECTION_LTR
        if (lines != null) {
            maxLines = lines
            ellipsize = TextUtils.TruncateAt.END
        }
    }

    /** A line height in sp: `setLineHeight` is API 28, and below it the difference is added as spacing, as AndroidX does. */
    private fun TextView.lineHeight(sp: Int) {
        val target = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, sp.toFloat(), resources.displayMetrics).roundToInt()
        if (Build.VERSION.SDK_INT >= 28) {
            lineHeight = target
        } else {
            val natural = paint.getFontMetricsInt(null)
            if (target != natural) setLineSpacing((target - natural).toFloat(), 1f)
        }
    }

    /**
     * A picture at its final size before it arrives — the placeholder is shaped like it, and stays if the fetch fails —
     * named by its `alt` to a screen reader, or hidden from one when the author said it is a decoration (a null `alt`).
     */
    private fun picture(image: InAppPlanImage, corner: Float): AspectFrame {
        val view = ImageView(context).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP
            describe(this, image.alt)
        }
        pictures.load(image.url) { bitmap -> if (!stopped && bitmap != null) view.setImageBitmap(bitmap) }
        return AspectFrame(context, ratio(image.aspect)).apply {
            tag = InAppNativeTags.PICTURE
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            background = RoundedFill(placeholder, corner)
            if (corner > 0f) clipToOutline = true
            addView(view, FrameLayout.LayoutParams(MATCH, MATCH))
        }
    }

    private fun describe(view: ImageView, alt: String?) {
        view.contentDescription = alt
        view.importantForAccessibility = if (alt != null) View.IMPORTANT_FOR_ACCESSIBILITY_YES else View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    private fun ratio(aspect: String): Float {
        val (wide, tall) = aspect.split(':').mapNotNull { it.toFloatOrNull() }.takeIf { it.size == 2 && it[1] > 0f } ?: listOf(2f, 1f)
        return wide / tall
    }

    // ---- The carousel ----------------------------------------------------------------------------------------------

    /**
     * One card at a time: its picture 2:1 with its `image_alt`, its title and its body; previous and next with "n / N"
     * between them when there is more than one, wrapping round. It never moves by itself — somebody reading the second
     * card does not have it taken away.
     */
    private fun carousel(slides: List<InAppPlanSlide>): View {
        var index = 0
        var showing: String? = null
        val image = ImageView(context).apply { scaleType = ImageView.ScaleType.CENTER_CROP }
        val frame = AspectFrame(context, 2f).apply {
            tag = InAppNativeTags.PICTURE
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            background = RoundedFill(placeholder, 0f)
            addView(image, FrameLayout.LayoutParams(MATCH, MATCH))
        }
        val title = words("", InAppStandardLayout.TITLE_SIZE, bold, onSurface, null)
        val body = words("", InAppStandardLayout.BODY_SIZE, regular, muted, null).apply { lineHeight(InAppStandardLayout.BODY_LINE_HEIGHT) }
        val count = words("", InAppStandardLayout.BODY_SIZE, regular, muted, null).apply {
            tag = InAppNativeTags.SLIDE_COUNT
            gravity = Gravity.CENTER
            // Read out when it changes, so a screen reader hears which card it moved to.
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        fun draw() {
            val slide = slides[index]
            describe(image, slide.imageAlt)
            if (showing != slide.imageUrl) {
                val wanted = slide.imageUrl
                showing = wanted
                image.setImageDrawable(null)
                // A card fetched slowly must not land on the card somebody has moved on to.
                pictures.load(wanted) { bitmap -> if (!stopped && showing == wanted && bitmap != null) image.setImageBitmap(bitmap) }
            }
            title.text = slide.title.orEmpty()
            title.visibility = if (slide.title == null) View.GONE else View.VISIBLE
            body.text = slide.body.orEmpty()
            body.visibility = if (slide.body == null) View.GONE else View.VISIBLE
            count.text = String.format(Locale.US, "%d / %d", index + 1, slides.size)
        }
        val blocks = mutableListOf<View>(frame, title, body)
        if (slides.size > 1) {
            val previous = arrow(if (rtl) "›" else "‹", "Previous", InAppNativeTags.PREVIOUS) {
                index = (index - 1 + slides.size) % slides.size
                draw()
            }
            val next = arrow(if (rtl) "‹" else "›", "Next", InAppNativeTags.NEXT) {
                index = (index + 1) % slides.size
                draw()
            }
            val controls = LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                val target = dp(TOUCH_TARGET)
                val row = listOf(previous to LinearLayout.LayoutParams(target, target), count to LinearLayout.LayoutParams(0, WRAP, 1f), next to LinearLayout.LayoutParams(target, target))
                (if (rtl) row.reversed() else row).forEach { (view, params) -> addView(view, params) }
            }
            blocks += controls
        }
        draw()
        return stack(blocks, GAP).apply { tag = InAppNativeTags.CAROUSEL }
    }

    private fun arrow(glyph: String, label: String, name: String, onPress: () -> Unit): TextView =
        words(glyph, ARROW_SIZE, regular, onSurface, null).apply {
            tag = name
            gravity = Gravity.CENTER
            contentDescription = label
            isClickable = true
            isFocusable = true
            background = RippleDrawable(ColorStateList.valueOf(withAlpha(onSurface, 0x22)), null, null)
            setOnClickListener { onPress() }
            accessibilityDelegate = role(Button::class.java.name)
        }

    // ---- The countdown ---------------------------------------------------------------------------------------------

    /**
     * 22 at weight 600 with tabular digits, so the clock does not shuffle sideways as it counts, redrawn from
     * [inAppCountdownText] each time its words change — timed to the change rather than every thousand milliseconds
     * from when it happened to start — and gone when they are `""`.
     */
    private inner class Countdown(private val to: Long) {
        val view: TextView = words(inAppCountdownText(to, now()), InAppStandardLayout.COUNTDOWN_SIZE, semibold, onSurface, null).apply {
            tag = InAppNativeTags.COUNTDOWN
            fontFeatureSettings = "tnum"
        }

        fun start() = tick()

        private fun tick() {
            if (stopped) return
            val at = now()
            val shown = inAppCountdownText(to, at)
            if (shown.isEmpty()) {
                view.visibility = View.GONE
                return
            }
            view.text = shown
            // The words change when the time left drops below a whole second: `left % 1000` later, and one more.
            handler.postDelayed({ tick() }, (to - at) % 1000 + 1)
        }
    }

    // ---- The form --------------------------------------------------------------------------------------------------

    /**
     * Each field's label, with " *" when it is required, then its control: a text box with the keyboard its kind wants,
     * chips, several chips, the platform's own menu and date picker, or a scale — five stars filled to the pick, or the
     * numbers. On send, [inAppFormProblem]'s words under the fields when there is anything to say; otherwise
     * [inAppFormAnswers] go to the core and the thanks take the form's place.
     */
    private inner class Form(private val form: InAppPlanForm) {
        /** Typed text, a picked option or number, or a multiple choice's picks as a list — what [inAppFormProblem] reads. */
        private val answers = LinkedHashMap<String, Any?>()
        private val problem = words("", InAppStandardLayout.BODY_SIZE, regular, problemColour, null).apply {
            tag = InAppNativeTags.PROBLEM
            visibility = View.GONE
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        val view: LinearLayout = stack(
            form.fields.map(::field) + problem + actionButton(form.submitLabel, primary = true) { send() }.apply { tag = InAppNativeTags.SEND },
            FORM_GAP,
        ).apply { tag = InAppNativeTags.FORM }

        private fun field(field: InAppPlanField): View {
            val label = words(if (field.required) "${field.label} *" else field.label, InAppStandardLayout.BODY_SIZE, regular, onSurface, null)
            val control = when (field.control) {
                "chips" -> choices(field, field.options.orEmpty(), many = false)
                "multi_chips" -> choices(field, field.options.orEmpty(), many = true)
                "menu" -> menu(field)
                "date" -> date(field)
                "scale" -> if (field.glyph == "star") stars(field) else choices(field, field.scale.orEmpty(), many = false)
                else -> input(field)
            }
            control.id = View.generateViewId()
            label.labelFor = control.id
            return stack(listOf(label, control), FIELD_GAP).apply { tag = InAppNativeTags.field(field.id) }
        }

        private fun input(field: InAppPlanField): EditText = EditText(context).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, INPUT_SIZE.toFloat())
            typeface = regular
            setTextColor(onSurface)
            setHintTextColor(muted)
            hint = field.placeholder
            background = RoundedFill(Color.TRANSPARENT, dp(INPUT_RADIUS.toDouble()), dp(1), muted)
            setPadding(dp(10), dp(8), dp(10), dp(8))
            /*
             * The view's own minimum as well as the text's: `inputType` below makes a single-line box, and single-line
             * mode resets a TextView's `minHeight` to one line. So the box would never be the height it asked for — about
             * 30dp — and `minimumHeight` is the one single-line mode leaves alone.
             */
            minHeight = dp(CONTROL_MIN_HEIGHT)
            minimumHeight = dp(CONTROL_MIN_HEIGHT)
            textDirection = if (rtl) View.TEXT_DIRECTION_RTL else View.TEXT_DIRECTION_LTR
            // The keyboard the kind wants; an email box never capitalises its first letter.
            inputType = when (field.keyboard) {
                "email" -> InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS
                "phone" -> InputType.TYPE_CLASS_PHONE
                "decimal" -> InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL or InputType.TYPE_NUMBER_FLAG_SIGNED
                else -> InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES or (if (field.multiline) InputType.TYPE_TEXT_FLAG_MULTI_LINE else 0)
            }
            if (field.multiline) {
                minLines = 3
                gravity = Gravity.TOP or startSide
            } else {
                gravity = Gravity.CENTER_VERTICAL or startSide
                imeOptions = EditorInfo.IME_ACTION_NEXT
            }
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(text: CharSequence?, start: Int, count: Int, after: Int) = Unit
                override fun onTextChanged(text: CharSequence?, start: Int, before: Int, count: Int) = Unit
                override fun afterTextChanged(text: Editable?) {
                    answers[field.id] = text?.toString()
                }
            })
        }

        /** Chips for one choice or several, or the numbers of a scale; laid from the message's start, and wrapping. */
        private fun choices(field: InAppPlanField, values: List<Any>, many: Boolean): View {
            val flow = InAppFlow(context, dp(CHIP_GAP), rtl)
            fun picked(value: Any): Boolean = if (many) (answers[field.id] as? List<*>)?.contains(value) == true else answers[field.id] == value
            val chips = values.map { value ->
                words(value.toString(), INPUT_SIZE, regular, accent, null).apply {
                    tag = InAppNativeTags.option(field.id, value.toString())
                    gravity = Gravity.CENTER
                    // A 48 target around a pill that looks 32 high: the chip is as easy to hit as Android asks without
                    // looking like a button.
                    minHeight = dp(TOUCH_TARGET)
                    minWidth = dp(TOUCH_TARGET)
                    setPadding(dp(CHIP_PADDING), 0, dp(CHIP_PADDING), 0)
                    isClickable = true
                    isFocusable = true
                    accessibilityDelegate = role(if (many) CheckBox::class.java.name else RadioButton::class.java.name) { picked(value) }
                }
            }
            fun paint() = chips.forEachIndexed { index, chip ->
                val on = picked(values[index])
                val inset = dp((TOUCH_TARGET - CHIP_HEIGHT) / 2)
                chip.background = InsetDrawable(RoundedFill(if (on) accent else Color.TRANSPARENT, dp(999.0), dp(1), accent), 0, inset, 0, inset)
                // Setting a background with insets hands the view the drawable's padding, which has no sides, and the
                // words would run into the pill's edge. The chip's own padding, again.
                chip.setPadding(dp(CHIP_PADDING), 0, dp(CHIP_PADDING), 0)
                chip.setTextColor(if (on) onAccent else accent)
            }
            chips.forEachIndexed { index, chip ->
                val value = values[index]
                chip.setOnClickListener {
                    if (many) {
                        val now = (answers[field.id] as? List<*>).orEmpty().filterNotNull()
                        answers[field.id] = if (value in now) now - value else now + value
                    } else {
                        answers[field.id] = value
                    }
                    paint()
                }
                flow.addView(chip)
            }
            paint()
            return flow
        }

        /** Five stars, filled up to the pick in `accent` and outlined past it: a rating answers the number of the star. */
        private fun stars(field: InAppPlanField): View {
            val values = field.scale.orEmpty()
            val size = dp(STAR_SIZE)
            val stars = values.map { value ->
                ImageView(context).apply {
                    tag = InAppNativeTags.option(field.id, value.toString())
                    scaleType = ImageView.ScaleType.CENTER
                    contentDescription = if (value == 1) "1 star" else "$value stars"
                    isClickable = true
                    isFocusable = true
                    accessibilityDelegate = role(RadioButton::class.java.name) { answers[field.id] == value }
                }
            }
            fun paint() {
                val pick = answers[field.id] as? Int ?: 0
                stars.forEachIndexed { index, star ->
                    val filled = values[index] <= pick
                    star.setImageDrawable(StarGlyph(if (filled) accent else muted, size.toFloat(), filled, dp(1.5)))
                }
            }
            stars.forEachIndexed { index, star ->
                star.setOnClickListener {
                    answers[field.id] = values[index]
                    paint()
                }
            }
            paint()
            return LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = startSide
                val target = dp(TOUCH_TARGET)
                (if (rtl) stars.reversed() else stars).forEach { addView(it, LinearLayout.LayoutParams(target, target)) }
            }
        }

        /** The platform's own dropdown menu, saying its placeholder until something is chosen. */
        private fun menu(field: InAppPlanField): TextView = box(field.placeholder ?: InAppStandardLayout.WORD_CHOOSE).apply {
            accessibilityDelegate = role(Spinner::class.java.name)
            setOnClickListener { anchor ->
                val options = field.options.orEmpty()
                val popup = PopupMenu(context, anchor)
                options.forEachIndexed { index, option -> popup.menu.add(Menu.NONE, index, index, option) }
                popup.setOnMenuItemClickListener { item ->
                    options.getOrNull(item.itemId)?.let { option ->
                        answers[field.id] = option
                        fill(this, option)
                    }
                    true
                }
                popup.setOnDismissListener { if (picker === popup) picker = null }
                picker = popup
                popup.show()
            }
        }

        /**
         * The platform's own date picker, answering `YYYY-MM-DD` — written with `Locale.US`, because an Arabic locale's
         * `%04d` is Arabic-Indic digits and [inAppIsDay] reads `[0-9]`.
         */
        private fun date(field: InAppPlanField): TextView = box(DATE_HINT).apply {
            setOnClickListener {
                val today = Calendar.getInstance()
                val chosen = (answers[field.id] as? String)?.takeIf(::inAppIsDay)?.split('-')?.map(String::toInt)
                val dialog = DatePickerDialog(
                    context,
                    { _, year, month, day ->
                        // The picker's months count from nought.
                        val value = String.format(Locale.US, "%04d-%02d-%02d", year, month + 1, day)
                        answers[field.id] = value
                        fill(this, value)
                    },
                    chosen?.get(0) ?: today.get(Calendar.YEAR),
                    (chosen?.get(1) ?: (today.get(Calendar.MONTH) + 1)) - 1,
                    chosen?.get(2) ?: today.get(Calendar.DAY_OF_MONTH),
                )
                dialog.setOnDismissListener { if (picker === dialog) picker = null }
                picker = dialog
                dialog.show()
            }
        }

        /** A field that opens something rather than being typed in: drawn as a text box, saying its placeholder. */
        private fun box(placeholder: String): TextView = words(placeholder, INPUT_SIZE, regular, muted, 1).apply {
            background = RoundedFill(Color.TRANSPARENT, dp(INPUT_RADIUS.toDouble()), dp(1), muted)
            setPadding(dp(10), dp(8), dp(10), dp(8))
            // Both minimums, as on a typed box: one line of text must not decide how tall a thing to tap is.
            minHeight = dp(CONTROL_MIN_HEIGHT)
            minimumHeight = dp(CONTROL_MIN_HEIGHT)
            gravity = Gravity.CENTER_VERTICAL or startSide
            val chevron = ChevronGlyph(muted, dp(10.0), dp(1.5))
            if (rtl) setCompoundDrawablesWithIntrinsicBounds(chevron, null, null, null) else setCompoundDrawablesWithIntrinsicBounds(null, null, chevron, null)
            compoundDrawablePadding = dp(8)
            isClickable = true
            isFocusable = true
        }

        private fun fill(box: TextView, value: String) {
            box.text = value
            box.setTextColor(onSurface)
        }

        private fun send() {
            (context.getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager)?.hideSoftInputFromWindow(view.windowToken, 0)
            val wrong = inAppFormProblem(form.fields, answers)
            if (wrong != null) {
                problem.text = wrong
                problem.visibility = View.VISIBLE
                return
            }
            events.submit(inAppFormAnswers(form.fields, answers))
            view.removeAllViews()
            view.addView(
                words(form.thanks, InAppStandardLayout.BODY_SIZE, regular, onSurface, null).apply {
                    tag = InAppNativeTags.THANKS
                    lineHeight(InAppStandardLayout.BODY_LINE_HEIGHT)
                    accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
                },
                matchWrap(),
            )
        }
    }

    // ---- Buttons and the ✕ -----------------------------------------------------------------------------------------

    private fun buttons(): LinearLayout = stack(plan.buttons.map(::button), GAP).apply { tag = InAppNativeTags.BUTTONS }

    /** What the button says and where it goes are the plan's; a press is reported, and the host decides what it means. */
    private fun button(button: InAppPlanButton): TextView =
        actionButton(button.label, button.style == "primary") { events.press(button) }.apply { tag = InAppNativeTags.button(button.index) }

    /**
     * At least 48 high ([CONTROL_MIN_HEIGHT]), weight 600, `button_radius`: a primary one filled with `accent` and its
     * words in `on_accent`, a secondary one `accent` words on nothing. A plain text view rather than a `Button`, whose theme brings capitals, an
     * elevation and a background of the app's own.
     */
    private fun actionButton(label: String, primary: Boolean, onPress: () -> Unit): TextView =
        words(label, BUTTON_SIZE, semibold, if (primary) onAccent else accent, null).apply {
            gravity = Gravity.CENTER
            minHeight = dp(CONTROL_MIN_HEIGHT)
            minimumHeight = dp(CONTROL_MIN_HEIGHT)
            setPadding(dp(16), dp(12), dp(16), dp(12))
            val shape = { colour: Int -> RoundedFill(colour, dp(plan.tokens.buttonRadius)) }
            background = RippleDrawable(
                ColorStateList.valueOf(withAlpha(if (primary) onAccent else accent, 0x33)),
                if (primary) shape(accent) else null,
                shape(Color.WHITE),
            )
            isClickable = true
            isFocusable = true
            setOnClickListener { onPress() }
            accessibilityDelegate = role(Button::class.java.name)
        }

    /**
     * The ✕: a 48dp target — Android's, not the contract's 44, which is iOS's points — in `on_surface_muted`, "Close" to
     * a screen reader. Drawn rather than typed — the preview's is an SVG, and a brand font should not restyle the one
     * control the composer never does. Over a picture it sits on a disc of the surface, or it would vanish into a dark
     * photograph.
     */
    private fun close(over: Boolean): ImageView = ImageView(context).apply {
        tag = InAppNativeTags.CLOSE
        setImageDrawable(CloseGlyph(muted, dp(14.0), dp(2.0)))
        scaleType = ImageView.ScaleType.CENTER
        background = if (over) {
            InsetDrawable(GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(withAlpha(surface, 0xCC)) }, dp((TOUCH_TARGET - CLOSE_DISC) / 2))
        } else {
            RippleDrawable(ColorStateList.valueOf(withAlpha(muted, 0x33)), null, null)
        }
        contentDescription = "Close"
        isClickable = true
        isFocusable = true
        setOnClickListener { events.dismiss() }
        accessibilityDelegate = role(Button::class.java.name)
    }

    /** The ✕'s place: its logical corner made physical — `top_end` is the left of a right-to-left message. */
    private fun corner(name: String): FrameLayout.LayoutParams {
        val side = if (name == "top_start") startSide else endSide
        val inset = dp(CLOSE_INSET)
        return FrameLayout.LayoutParams(dp(TOUCH_TARGET), dp(TOUCH_TARGET), Gravity.TOP or side).apply {
            setMargins(inset, inset, inset, inset)
        }
    }

    // ---- Small things ----------------------------------------------------------------------------------------------

    private fun stack(children: List<View>, gap: Int): LinearLayout = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        children.forEachIndexed { index, child -> addView(child, LinearLayout.LayoutParams(MATCH, WRAP).apply { if (index > 0) topMargin = dp(gap) }) }
    }

    private fun role(className: String, checked: (() -> Boolean)? = null) = object : View.AccessibilityDelegate() {
        override fun onInitializeAccessibilityNodeInfo(host: View, info: AccessibilityNodeInfo) {
            super.onInitializeAccessibilityNodeInfo(host, info)
            info.className = className
            if (checked != null) {
                info.isCheckable = true
                // A boolean until API 36 made it a tri-state; the boolean is what 24 to 35 read.
                @Suppress("DEPRECATION")
                info.isChecked = checked()
            }
        }
    }

    private fun matchWrap() = LinearLayout.LayoutParams(MATCH, WRAP)

    private companion object {
        const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
        const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT
        /** Around the words of a modal and a fullscreen, and between the words' blocks: 16 and 8. */
        const val PADDING = 16
        const val GAP = 8
        /** The banner's row and its words: 12, and 8 across by 4 down. */
        const val BANNER_PADDING = 12
        const val BANNER_WORDS_ACROSS = 8
        const val BANNER_WORDS_DOWN = 4
        /**
         * Android's smallest touch target, 48dp — Material's, and what Accessibility Scanner checks — where the contract's
         * `dismiss.target` is iOS's 44 points. At 44dp a ✕, a star, a carousel arrow or a chip is 132px at 480dpi, under
         * the 144 Android asks for. Only the touch area grows: what is drawn inside it keeps its size.
         */
        const val TOUCH_TARGET = 48
        /**
         * A button's and a form box's least height on Android: the contract's `button.min_height` is 44, iOS's points,
         * and a full-width control 44dp tall is under the 48 Android asks of anything tapped — Accessibility Scanner
         * flags it. The larger of the two, so a contract that asks for more still gets it.
         */
        val CONTROL_MIN_HEIGHT = maxOf(InAppStandardLayout.BUTTON_MIN_HEIGHT, TOUCH_TARGET)
        /** The disc behind a ✕ over a picture, and a chip's pill: drawn at these heights inside a 48 target. */
        const val CLOSE_DISC = 32
        const val CHIP_HEIGHT = 32
        /** How far the ✕ sits in from its corner, and how far a banner's reaches back into its padding. */
        const val CLOSE_INSET = 4
        const val CLOSE_TUCK = 8
        const val BUTTON_SIZE = 14
        const val INPUT_SIZE = 14
        const val INPUT_RADIUS = 6
        const val ARROW_SIZE = 22
        const val STAR_SIZE = 26
        const val FORM_GAP = 12
        const val FIELD_GAP = 4
        const val CHIP_GAP = 6
        const val CHIP_PADDING = 14
        const val DATE_HINT = "YYYY-MM-DD"
    }
}

/** [colour] with its alpha replaced. */
internal fun withAlpha(colour: Int, alpha: Int): Int = (colour and 0x00FFFFFF) or (alpha shl 24)

/**
 * The family a message names, found the way React Native's font manager finds one: the app's own `res/font/<name>`,
 * then `assets/fonts/<Family>.ttf` or `.otf`, then a family the system knows ("serif", "sans-serif-condensed"). A family
 * the app has not linked falls back to the system font — never to no words.
 */
internal object InAppFonts {
    private val families = HashMap<String, Typeface>()

    fun family(context: Context, name: String?): Typeface {
        if (name == null) return Typeface.DEFAULT
        families[name]?.let { return it }
        val found = fromResources(context, name) ?: fromAssets(context, name) ?: Typeface.create(name, Typeface.NORMAL)
        families[name] = found
        return found
    }

    /** A weight on [base]: exact from API 28, and bold from 600 below it, which is all a pre-28 typeface can say. */
    fun weight(base: Typeface, weight: Int): Typeface =
        if (Build.VERSION.SDK_INT >= 28) Typeface.create(base, weight, false) else Typeface.create(base, if (weight >= 600) Typeface.BOLD else Typeface.NORMAL)

    @Suppress("DiscouragedApi")
    private fun fromResources(context: Context, name: String): Typeface? {
        if (Build.VERSION.SDK_INT < 26) return null
        val resource = name.lowercase(Locale.ROOT).replace(Regex("[^a-z0-9_]"), "_")
        val id = context.resources.getIdentifier(resource, "font", context.packageName)
        return if (id == 0) null else runCatching { context.resources.getFont(id) }.getOrNull()
    }

    private fun fromAssets(context: Context, name: String): Typeface? =
        listOf("ttf", "otf").firstNotNullOfOrNull { extension -> runCatching { Typeface.createFromAsset(context.assets, "fonts/$name.$extension") }.getOrNull() }
}

/**
 * A rounded rectangle whose radius is at most half its shorter side, so `button_shape: pill`'s 999 draws a pill rather
 * than whatever a platform version makes of a radius larger than the button. The outline follows, and clips with it.
 */
internal class RoundedFill(colour: Int, private val radius: Float, stroke: Int = 0, strokeColour: Int = Color.TRANSPARENT) : GradientDrawable() {
    init {
        shape = RECTANGLE
        setColor(colour)
        if (stroke > 0) setStroke(stroke, strokeColour)
        cornerRadius = radius
    }

    override fun onBoundsChange(r: Rect) {
        super.onBoundsChange(r)
        cornerRadius = minOf(radius, minOf(r.width(), r.height()) / 2f)
    }
}

/** A frame as tall as its width divided by [ratio]: a picture's box at its final size, drawn before the picture arrives. */
internal class AspectFrame(context: Context, private val ratio: Float) : FrameLayout(context) {
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val height = if (MeasureSpec.getMode(heightMeasureSpec) == MeasureSpec.EXACTLY) MeasureSpec.getSize(heightMeasureSpec) else (width / ratio).roundToInt()
        super.onMeasure(MeasureSpec.makeMeasureSpec(width, MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(height, MeasureSpec.EXACTLY))
    }
}

/** A frame no wider than [maxWidth]: a modal's 320, a tablet fullscreen's 560 — and narrower on a narrower window. */
internal class CappedFrame(context: Context, private val maxWidth: Int) : FrameLayout(context) {
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val size = MeasureSpec.getSize(widthMeasureSpec)
        val width = if (MeasureSpec.getMode(widthMeasureSpec) == MeasureSpec.UNSPECIFIED) maxWidth else minOf(size, maxWidth)
        super.onMeasure(MeasureSpec.makeMeasureSpec(width, MeasureSpec.EXACTLY), heightMeasureSpec)
    }
}

/**
 * A banner's row, no taller than [maxHeight] — half the screen. A child as tall as it is let have gets that much and no
 * more, which is what makes the words' scroll view scroll rather than grow the banner down over the app.
 */
internal class InAppBannerRow(context: Context, private val maxHeight: Int) : LinearLayout(context) {
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val given = MeasureSpec.getSize(heightMeasureSpec)
        val height = if (MeasureSpec.getMode(heightMeasureSpec) == MeasureSpec.UNSPECIFIED) maxHeight else minOf(given, maxHeight)
        super.onMeasure(widthMeasureSpec, MeasureSpec.makeMeasureSpec(height, MeasureSpec.AT_MOST))
    }
}

/** Chips in rows that wrap, laid from the message's start — the right, for a right-to-left message. */
internal class InAppFlow(context: Context, private val gap: Int, private val rtl: Boolean) : ViewGroup(context) {
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val limit = if (MeasureSpec.getMode(widthMeasureSpec) == MeasureSpec.UNSPECIFIED) Int.MAX_VALUE else MeasureSpec.getSize(widthMeasureSpec) - paddingLeft - paddingRight
        var x = 0
        var y = 0
        var rowHeight = 0
        var widest = 0
        for (index in 0 until childCount) {
            val child = getChildAt(index)
            if (child.visibility == View.GONE) continue
            child.measure(MeasureSpec.makeMeasureSpec(limit, MeasureSpec.AT_MOST), MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED))
            if (x > 0 && x + child.measuredWidth > limit) {
                y += rowHeight + gap
                x = 0
                rowHeight = 0
            }
            x += child.measuredWidth + gap
            rowHeight = maxOf(rowHeight, child.measuredHeight)
            widest = maxOf(widest, x - gap)
        }
        setMeasuredDimension(
            resolveSize(widest + paddingLeft + paddingRight, widthMeasureSpec),
            resolveSize(y + rowHeight + paddingTop + paddingBottom, heightMeasureSpec),
        )
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        val limit = right - left - paddingLeft - paddingRight
        var x = 0
        var y = 0
        var rowHeight = 0
        for (index in 0 until childCount) {
            val child = getChildAt(index)
            if (child.visibility == View.GONE) continue
            if (x > 0 && x + child.measuredWidth > limit) {
                y += rowHeight + gap
                x = 0
                rowHeight = 0
            }
            val from = if (rtl) paddingLeft + limit - x - child.measuredWidth else paddingLeft + x
            child.layout(from, paddingTop + y, from + child.measuredWidth, paddingTop + y + child.measuredHeight)
            x += child.measuredWidth + gap
            rowHeight = maxOf(rowHeight, child.measuredHeight)
        }
    }
}

/** Shared by the three glyphs: a drawable of a fixed size, drawn with one paint. */
internal abstract class InAppGlyph(colour: Int, private val size: Float) : Drawable() {
    protected val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = colour
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }

    override fun getIntrinsicWidth(): Int = size.roundToInt()
    override fun getIntrinsicHeight(): Int = size.roundToInt()
    override fun setAlpha(alpha: Int) {
        paint.alpha = alpha
    }
    override fun setColorFilter(colorFilter: ColorFilter?) {
        paint.colorFilter = colorFilter
    }
    @Deprecated("Deprecated in Java")
    override fun getOpacity(): Int = PixelFormat.TRANSLUCENT
}

/** The ✕'s two strokes. */
internal class CloseGlyph(colour: Int, private val size: Float, stroke: Float) : InAppGlyph(colour, size) {
    init {
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = stroke
    }

    override fun draw(canvas: Canvas) {
        val x = bounds.exactCenterX()
        val y = bounds.exactCenterY()
        val half = size / 2
        canvas.drawLine(x - half, y - half, x + half, y + half, paint)
        canvas.drawLine(x + half, y - half, x - half, y + half, paint)
    }
}

/** A menu's or a date's chevron, pointing down. */
internal class ChevronGlyph(colour: Int, private val size: Float, stroke: Float) : InAppGlyph(colour, size) {
    init {
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = stroke
    }

    override fun draw(canvas: Canvas) {
        val x = bounds.exactCenterX()
        val y = bounds.exactCenterY()
        val half = size / 2
        canvas.drawLine(x - half, y - half / 2, x, y + half / 2, paint)
        canvas.drawLine(x, y + half / 2, x + half, y - half / 2, paint)
    }
}

/** A five-pointed star, filled or outlined: a rating's scale. */
internal class StarGlyph(colour: Int, private val size: Float, private val filled: Boolean, stroke: Float) : InAppGlyph(colour, size) {
    init {
        paint.style = if (filled) Paint.Style.FILL else Paint.Style.STROKE
        paint.strokeWidth = stroke
    }

    override fun draw(canvas: Canvas) {
        val x = bounds.exactCenterX()
        val y = bounds.exactCenterY()
        val outer = size / 2 - paint.strokeWidth
        val inner = outer * 0.45f
        val path = Path()
        for (point in 0 until 10) {
            val radius = if (point % 2 == 0) outer else inner
            val angle = Math.toRadians(-90.0 + point * 36.0)
            val px = x + (radius * cos(angle)).toFloat()
            val py = y + (radius * sin(angle)).toFloat()
            if (point == 0) path.moveTo(px, py) else path.lineTo(px, py)
        }
        path.close()
        canvas.drawPath(path, paint)
    }

    /** Whether it is drawn filled: a test reads the pick back through it. */
    internal val isFilled: Boolean get() = filled
}
