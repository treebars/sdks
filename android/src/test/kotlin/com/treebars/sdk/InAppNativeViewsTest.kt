package com.treebars.sdk

import android.app.Activity
import android.app.DatePickerDialog
import android.content.DialogInterface
import android.graphics.Bitmap
import android.os.Looper
import android.os.SystemClock
import android.text.InputType
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowDialog
import org.robolectric.shadows.ShadowPopupMenu
import java.time.Duration

/**
 * What Android draws from a plan: the shared fixture's rows planned as every SDK plans them, then drawn here by
 * [InAppNativeHost] over a real Activity, with a core that only writes down what it was told. The order of the parts,
 * the counts, the lines, the accessibility names, how each shape closes, the countdown's ticks and the form's wiring —
 * everything a JVM can see. What a person sees is for a run on a device to show.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class InAppNativeViewsTest {
    private val fixture = JSONObject(
        requireNotNull(javaClass.classLoader?.getResource("bridge/in-app-render.json")) { "the shared fixture is missing from the test resources" }.readText(),
    )

    private val activity: Activity = Robolectric.buildActivity(Activity::class.java).setup().get()
    private var host: InAppNativeHost? = null

    /** Everything the host told the core, in order. */
    private val told = mutableListOf<String>()
    private val pressed = mutableListOf<InAppPlanButton>()
    private val sent = mutableListOf<Map<String, Any>>()
    private val core = object : InAppNativeCore {
        override fun shown() {
            told += "shown"
        }
        override fun pressed(button: InAppPlanButton) {
            told += "pressed"
            pressed += button
        }
        override fun dismissed() {
            told += "dismissed"
        }
        override fun submitted(answers: Map<String, Any>) {
            told += "submitted"
            sent += answers
        }
        override fun answered() {
            told += "answered"
        }
    }

    private val fetched = mutableListOf<String>()
    private val pictures = InAppPictureLoader { url, done ->
        fetched += url
        done(Bitmap.createBitmap(4, 2, Bitmap.Config.ARGB_8888))
    }
    /**
     * The wall clock the countdown reads, moving with the looper's: drawing a message runs its entrance, which moves
     * Robolectric's clock on by itself, and a clock of the test's own would fall behind the handler's.
     */
    private var offset = 1_000_000L
    private fun now() = offset + SystemClock.uptimeMillis()

    @After
    fun takeDown() {
        host?.destroy()
    }

    private fun row(id: String): JSONObject {
        val plans = fixture.getJSONArray("plans")
        for (i in 0 until plans.length()) if (plans.getJSONObject(i).getString("id") == id) return plans.getJSONObject(i).getJSONObject("row")
        error("no fixture row $id")
    }

    private fun env(id: String): InAppRenderEnv {
        val plans = fixture.getJSONArray("plans")
        for (i in 0 until plans.length()) {
            val case = plans.getJSONObject(i)
            if (case.getString("id") != id) continue
            val env = case.getJSONObject("env")
            return InAppRenderEnv(
                env.getString("appearance"),
                env.getString("platform"),
                env.getString("device_class"),
                (env.opt("fallback_tokens") as? JSONObject)?.let(::parseInAppTokens),
                env.optString("text_size").takeIf { it.isNotEmpty() },
            )
        }
        error("no fixture row $id")
    }

    private fun plan(id: String): InAppRenderPlan.Overlay = inAppRenderPlan(row(id), env(id)) as InAppRenderPlan.Overlay

    private fun show(plan: InAppRenderPlan.Overlay): InAppNativeHost {
        val drawn = InAppNativeHost(activity, plan, core, pictures, ::now)
        host = drawn
        assertTrue("attached", drawn.show())
        idle()
        return drawn
    }

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    private fun later(ms: Long) = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms))

    /** Runs the looper until the wall clock reads [instant]. */
    private fun until(instant: Long) {
        val left = instant - now()
        if (left > 0) later(left)
    }

    private fun InAppNativeHost.find(tag: String): View = requireNotNull(views.root.findViewWithTag<View>(tag)) { "no $tag drawn" }
    private fun InAppNativeHost.has(tag: String): Boolean = views.root.findViewWithTag<View>(tag) != null

    /** The parts in the order they are drawn, depth first: what the contract's "order" is about. */
    private fun order(view: View, into: MutableList<String> = mutableListOf()): List<String> {
        (view.tag as? String)?.takeIf { it in PARTS || it.startsWith("treebars:button:") }?.let { into += it }
        if (view is ViewGroup) for (i in 0 until view.childCount) order(view.getChildAt(i), into)
        return into
    }

    private fun sp(value: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, value, activity.resources.displayMetrics)
    private fun dp(value: Int) = (value * activity.resources.displayMetrics.density).toInt()

    @Test
    fun aModalIsACardOnTheDimWithItsPartsInTheContractsOrder() {
        val drawn = show(plan("RP-001"))
        assertEquals(listOf("shown"), told)
        val dialog = requireNotNull(drawn.window) { "a modal is a Dialog" }
        assertTrue(dialog.isShowing)
        assertEquals(InAppNativeTags.DIM, drawn.views.root.tag)
        assertEquals(
            listOf(InAppNativeTags.PICTURE, InAppNativeTags.TITLE, InAppNativeTags.BODY, InAppNativeTags.BUTTONS, "treebars:button:1", "treebars:button:2", InAppNativeTags.CLOSE),
            order(drawn.views.root),
        )
        val title = drawn.find(InAppNativeTags.TITLE) as TextView
        val body = drawn.find(InAppNativeTags.BODY) as TextView
        assertEquals("Spring sale", title.text.toString())
        assertEquals(2, title.maxLines)
        assertEquals(4, body.maxLines)
        assertEquals(sp(16f), title.textSize, 0.01f)
        assertEquals(sp(13f), body.textSize, 0.01f)
        // The words' colours are the plan's, read as `#RRGGBBAA` rather than through `parseColor`.
        assertEquals(inAppPlanColourInt("#111827FF"), title.currentTextColor)
        assertEquals(inAppPlanColourInt("#6B7280FF"), body.currentTextColor)
        // The first button filled, its words `on_accent`; the second `accent` words on nothing.
        assertEquals(inAppPlanColourInt("#FFFFFFFF"), (drawn.find("treebars:button:1") as TextView).currentTextColor)
        assertEquals(inAppPlanColourInt("#0A7A5AFF"), (drawn.find("treebars:button:2") as TextView).currentTextColor)
        assertTrue((drawn.find("treebars:button:1") as TextView).minHeight >= dp(44))
        // The picture named by its alt; the ✕ by "Close"; the dialog by its title.
        val picture = (drawn.find(InAppNativeTags.PICTURE) as ViewGroup).getChildAt(0) as ImageView
        assertEquals("A red winter coat on a model", picture.contentDescription)
        assertEquals(listOf("https://cdn.example/spring.jpg"), fetched)
        assertEquals("Close", drawn.find(InAppNativeTags.CLOSE).contentDescription)
        assertEquals("Spring sale", shadowOf(dialog).title?.toString())
        // At most 320 wide.
        val card = drawn.find(InAppNativeTags.CARD)
        assertTrue("${card.width} wide", card.width in 1..dp(320))
    }

    @Test
    fun aModalClosesByBackAndByTheDimWhenItMayBeClosed() {
        val byBack = show(plan("RP-001"))
        byBack.window!!.onBackPressed()
        idle()
        assertEquals(listOf("shown", "dismissed"), told)
        byBack.destroy()

        told.clear()
        val byDim = show(plan("RP-001"))
        byDim.find(InAppNativeTags.DIM).performClick()
        // Once: a second tap before the core takes it down is not a second answer.
        byDim.find(InAppNativeTags.DIM).performClick()
        assertEquals(listOf("shown", "dismissed"), told)
    }

    @Test
    fun aModalOnlyItsButtonClosesHasNoCloseAndIgnoresBackAndTheDim() {
        val drawn = show(plan("RP-004"))
        assertFalse("no ✕ on an undismissable message", drawn.has(InAppNativeTags.CLOSE))
        assertFalse(shadowOf(drawn.window!!).isCancelable)
        drawn.window!!.onBackPressed()
        idle()
        drawn.find(InAppNativeTags.DIM).performClick()
        assertEquals(listOf("shown"), told)
        drawn.find("treebars:button:1").performClick()
        assertEquals(listOf("shown", "pressed"), told)
    }

    @Test
    fun aPressIsReportedWithItsIndexAndDestinationAndADismissButtonIsADismissal() {
        val link = show(plan("RP-001"))
        link.find("treebars:button:1").performClick()
        link.find("treebars:button:1").performClick()
        assertEquals(listOf("shown", "pressed"), told)
        assertEquals(1, pressed.single().index)
        assertEquals("shop://sale", pressed.single().destination)
        link.destroy()

        told.clear()
        val later = show(plan("RP-001"))
        later.find("treebars:button:2").performClick()
        assertEquals("`Later` is a dismissal, not a click", listOf("shown", "dismissed"), told)
    }

    @Test
    fun aBannerIsNotADialogAndLeavesTheRestOfTheScreenToTheApp() {
        val before = ShadowDialog.getShownDialogs().size
        val drawn = show(plan("RP-006"))
        assertNull("a banner has no window of its own", drawn.window)
        assertEquals(before, ShadowDialog.getShownDialogs().size)
        val root = drawn.views.root
        assertEquals(InAppNativeTags.BANNER, root.tag)
        assertTrue("on the Activity's own view tree", root.parent === activity.window.decorView)
        // Only as tall as itself, at its edge: every touch outside it reaches the app.
        val params = root.layoutParams as FrameLayout.LayoutParams
        assertEquals(ViewGroup.LayoutParams.WRAP_CONTENT, params.height)
        assertEquals(Gravity.TOP, params.gravity and Gravity.VERTICAL_GRAVITY_MASK)
        assertEquals(dp(16), params.leftMargin)
        assertEquals(
            listOf(InAppNativeTags.PICTURE, InAppNativeTags.TITLE, InAppNativeTags.BODY, "treebars:button:1", InAppNativeTags.CLOSE),
            order(root),
        )
        assertEquals(dp(48), drawn.find(InAppNativeTags.PICTURE).layoutParams.width)
        assertEquals(1, (drawn.find(InAppNativeTags.TITLE) as TextView).maxLines)
        assertEquals(2, (drawn.find(InAppNativeTags.BODY) as TextView).maxLines)
        // Back is the app's, never the banner's.
        activity.onBackPressed()
        assertEquals(listOf("shown"), told)
        drawn.destroy()
        assertNull("taken down with nothing left behind", root.parent)
    }

    @Test
    fun aBannerClosesItselfAfterItsTimeAndNotBefore() {
        val drawnAt = now()
        show(plan("RP-050"))
        until(drawnAt + 4_900)
        assertEquals(listOf("shown"), told)
        until(drawnAt + 5_100)
        assertEquals(listOf("shown", "dismissed"), told)
    }

    @Test
    fun aFullscreenPinsItsButtonsAndPutsTheCloseAtTheTopStart() {
        val drawn = show(plan("RP-009"))
        assertEquals(InAppNativeTags.FULLSCREEN, drawn.views.root.tag)
        val buttons = drawn.find(InAppNativeTags.BUTTONS)
        var inside: View? = buttons.parent as? View
        while (inside != null && inside !is ScrollView) inside = inside.parent as? View
        assertNull("the buttons are pinned below the scrolling words, not in them", inside)
        val close = drawn.find(InAppNativeTags.CLOSE).layoutParams as FrameLayout.LayoutParams
        assertEquals(Gravity.TOP or Gravity.LEFT, close.gravity)
        assertNull("words never cut on a fullscreen", (drawn.find(InAppNativeTags.TITLE) as TextView).maxLines.takeIf { it != Int.MAX_VALUE })
    }

    @Test
    fun aTabletFullscreenHoldsItsContentToTheReadingWidth() {
        val drawn = show(plan("RP-010"))
        var capped = false
        fun walk(view: View) {
            if (view is CappedFrame) capped = true
            if (view is ViewGroup) for (i in 0 until view.childCount) walk(view.getChildAt(i))
        }
        walk(drawn.views.root)
        assertTrue("a 560 column", capped)
    }

    @Test
    fun rightToLeftMirrorsTheCloseTheWordsAndTheBannerRow() {
        val drawn = show(plan("RP-030"))
        val close = drawn.find(InAppNativeTags.CLOSE).layoutParams as FrameLayout.LayoutParams
        assertEquals("top_end is the left of a right-to-left message", Gravity.TOP or Gravity.LEFT, close.gravity)
        assertEquals(Gravity.RIGHT, (drawn.find(InAppNativeTags.TITLE) as TextView).gravity and Gravity.HORIZONTAL_GRAVITY_MASK)
        drawn.destroy()

        val banner = plan("RP-006").copy(direction = "rtl")
        val row = show(banner).views.root as ViewGroup
        assertEquals("the ✕ first and the thumbnail last, reading from the right", InAppNativeTags.CLOSE, row.getChildAt(0).tag)
        assertEquals(InAppNativeTags.PICTURE, row.getChildAt(row.childCount - 1).tag)
    }

    // ---- The largest text size (font scale 2.0) ---------------------------------------------------------------------

    /** The scroll view [view] is drawn in, or null when nothing it is in scrolls. */
    private fun scrollAround(view: View): ScrollView? {
        var inside: View? = view.parent as? View
        while (inside != null && inside !is ScrollView) inside = inside.parent as? View
        return inside as? ScrollView
    }

    /** Where [view] is on the screen, top and bottom, as the person sees it — after whatever it is in has scrolled. */
    private fun onScreen(view: View): IntRange {
        val at = IntArray(2)
        view.getLocationInWindow(at)
        return at[1] until at[1] + view.height
    }

    /** Scrolls to the end, and says what the scroll view shows of the screen once it has. */
    private fun scrollToEnd(scroll: ScrollView): IntRange {
        scroll.scrollTo(0, scroll.getChildAt(0).height - scroll.height)
        idle()
        return onScreen(scroll)
    }

    /** A plan made as the host makes one, from this Activity's own configuration — not the fixture's `env`. */
    private fun planHere(id: String): InAppRenderPlan.Overlay =
        inAppRenderPlan(row(id), inAppRenderEnvFor(activity.resources.configuration, null)) as InAppRenderPlan.Overlay

    @Test
    @Config(fontScale = 2.0f)
    @GraphicsMode(GraphicsMode.Mode.NATIVE)
    fun atTheLargestTextSizeAModalOnlyItsButtonClosesKeepsTheButtonWithinReach() {
        val plan = planHere("RP-083")
        assertNull("its title is not cut at 2.0", plan.title?.maxLines)
        assertNull("nor its body", plan.body?.maxLines)
        val drawn = show(plan)
        assertFalse("the button is the only way out", drawn.has(InAppNativeTags.CLOSE))
        val body = drawn.find(InAppNativeTags.BODY) as TextView
        val atScaleOne = 13f * activity.resources.displayMetrics.density
        assertTrue("the words are at the person's size: ${body.textSize} against $atScaleOne", body.textSize > atScaleOne * 1.5f)
        assertEquals("never cut", Int.MAX_VALUE, body.maxLines)

        val button = drawn.find("treebars:button:1")
        val scroll = requireNotNull(scrollAround(button)) { "the button scrolls with the words, so it is below them however long they are" }
        val content = scroll.getChildAt(0)
        assertTrue("the words outgrew the card, or this proves nothing: ${content.height} in ${scroll.height}", content.height > scroll.height)
        // The card itself stays on the screen: it is the words inside it that scroll.
        val dim = drawn.views.root
        val card = drawn.find(InAppNativeTags.CARD)
        assertTrue("${card.top}..${card.bottom} inside ${dim.height}", card.top >= dim.paddingTop && card.bottom <= dim.height - dim.paddingBottom)
        val shows = scrollToEnd(scroll)
        val reached = onScreen(button)
        assertTrue("scrolled to the end, the button at $reached is inside what shows, $shows", reached.first >= shows.first && reached.last <= shows.last)
        button.performClick()
        assertEquals(listOf("shown", "pressed"), told)
    }

    @Test
    @Config(fontScale = 2.0f)
    @GraphicsMode(GraphicsMode.Mode.NATIVE)
    fun atTheLargestTextSizeABannersWordsAreWholeItsButtonUnderThemAndItStopsAtHalfTheScreen() {
        val plan = planHere("RP-082")
        assertEquals("content", plan.buttonsAt)
        val drawn = show(plan)
        val root = drawn.views.root
        assertEquals(
            "the button under the words, not beside them",
            listOf(InAppNativeTags.PICTURE, InAppNativeTags.TITLE, InAppNativeTags.BODY, InAppNativeTags.BUTTONS, "treebars:button:1", InAppNativeTags.CLOSE),
            order(root),
        )
        assertEquals(Int.MAX_VALUE, (drawn.find(InAppNativeTags.TITLE) as TextView).maxLines)
        assertEquals(Int.MAX_VALUE, (drawn.find(InAppNativeTags.BODY) as TextView).maxLines)
        val half = activity.resources.displayMetrics.heightPixels / 2
        assertTrue("no taller than half the screen: ${root.height} against $half", root.height in 1..half)
        val scroll = requireNotNull(scrollAround(drawn.find(InAppNativeTags.TITLE))) { "a banner's words scroll" }
        assertTrue("the words outgrew half the screen, or this proves nothing", scroll.getChildAt(0).height > scroll.height)
        assertNull("the ✕ never scrolls away", scrollAround(drawn.find(InAppNativeTags.CLOSE)))
        val button = drawn.find("treebars:button:1")
        val shows = scrollToEnd(scroll)
        val reached = onScreen(button)
        assertTrue("scrolled to the end, the button at $reached is inside what shows, $shows", reached.first >= shows.first && reached.last <= shows.last)
    }

    /**
     * Android asks for 48dp touch targets — 144px at the Pixel's 480dpi — and the ✕, a star, an arrow and a chip are each
     * held to it. The contract's 44 is iOS's points, right for iOS, and stays the contract's number.
     */
    @Test
    @Config(qualifiers = "xxhdpi")
    fun everySmallControlIsAsBigATargetAsAndroidAsksFor() {
        val target = dp(48)
        assertEquals("480dpi, or this is not the Pixel's arithmetic", 144, target)
        fun assertTarget(view: View, name: String) = assertTrue("$name is ${view.width}x${view.height}px", view.width >= target && view.height >= target)

        val modal = show(plan("RP-001"))
        assertTarget(modal.find(InAppNativeTags.CLOSE), "the ✕")
        modal.destroy()

        val form = show(plan("RP-060"))
        assertTarget(form.find(InAppNativeTags.option("stars", "1")), "a star")
        val chip = form.find(InAppNativeTags.option("likes", "Bags"))
        assertTarget(chip, "a chip")
        // Only the touch area grew: the pill drawn inside a chip no taller than its words need is still 32 high.
        assertEquals(dp(48), chip.height)
        val pill = chip.background as android.graphics.drawable.InsetDrawable
        // What `View.draw` does before it paints a background, which nothing draws here.
        pill.setBounds(0, 0, chip.width, chip.height)
        assertEquals(dp(32), requireNotNull(pill.drawable).bounds.height())
        form.destroy()

        val carousel = show(plan("RP-051"))
        assertTarget(carousel.find(InAppNativeTags.PREVIOUS), "the previous arrow")
        assertTarget(carousel.find(InAppNativeTags.NEXT), "the next arrow")
    }

    /*
     * The full-width controls are Android's 48dp high, as the small controls are, rather than the contract's 44 (iOS's
     * points): at 480dpi 44dp is under 144px, a height Accessibility Scanner flags on anything tapped.
     */
    @Test
    @Config(qualifiers = "xxhdpi")
    fun everyButtonAndFormBoxIsAtLeastAndroidsTargetHigh() {
        val target = dp(48)
        fun assertHigh(view: View, name: String) = assertTrue("$name is ${view.height}px high", view.height >= target)

        val modal = show(plan("RP-001"))
        // A button's index is the one `in_app_clicked` records, counted from 1.
        assertHigh(modal.find(InAppNativeTags.button(1)), "the first button")
        assertHigh(modal.find(InAppNativeTags.button(2)), "the second button")
        modal.destroy()

        val form = show(plan("RP-060"))
        // A field's tag is on its label and box together; the box is the second of the two.
        fun box(id: String) = (form.find(InAppNativeTags.field(id)) as ViewGroup).getChildAt(1)
        assertHigh(box("name"), "a text box")
        assertHigh(box("birthday"), "a date box")
        assertHigh(box("plan"), "a dropdown box")
        assertHigh(form.find(InAppNativeTags.SEND), "Send")
    }

    @Test
    fun aPictureWithNoAltIsHiddenFromAScreenReader() {
        val plain = plan("RP-001").let { it.copy(image = it.image!!.copy(alt = null)) }
        val picture = (show(plain).find(InAppNativeTags.PICTURE) as ViewGroup).getChildAt(0) as ImageView
        assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_NO, picture.importantForAccessibility)
        assertNull(picture.contentDescription)
    }

    @Test
    fun aCarouselMovesOnlyWhenAskedAndGoesRound() {
        val drawn = show(plan("RP-051"))
        assertEquals(
            listOf(InAppNativeTags.PICTURE, InAppNativeTags.TITLE, InAppNativeTags.BODY, InAppNativeTags.CAROUSEL, InAppNativeTags.PICTURE, InAppNativeTags.PREVIOUS, InAppNativeTags.SLIDE_COUNT, InAppNativeTags.NEXT),
            order(drawn.views.root).filter { it != InAppNativeTags.CLOSE },
        )
        val count = drawn.find(InAppNativeTags.SLIDE_COUNT) as TextView
        assertEquals("1 / 3", count.text.toString())
        later(10_000)
        assertEquals("never moves by itself", "1 / 3", count.text.toString())
        drawn.find(InAppNativeTags.NEXT).performClick()
        assertEquals("2 / 3", count.text.toString())
        drawn.find(InAppNativeTags.PREVIOUS).performClick()
        drawn.find(InAppNativeTags.PREVIOUS).performClick()
        assertEquals("wraps round", "3 / 3", count.text.toString())
        assertEquals("Next", drawn.find(InAppNativeTags.NEXT).contentDescription)
    }

    @Test
    fun oneCardIsNotACarouselToMove() {
        val drawn = show(plan("RP-052"))
        assertTrue(drawn.has(InAppNativeTags.CAROUSEL))
        assertFalse("no arrows and no count", drawn.has(InAppNativeTags.NEXT) || drawn.has(InAppNativeTags.SLIDE_COUNT))
    }

    @Test
    fun aCountdownTicksWithTheWordsAndIsGoneAtZero() {
        val base = plan("RP-053")
        val to = requireNotNull(base.countdownToMs)
        offset = to - 3_500 - SystemClock.uptimeMillis()
        val drawn = show(base)
        val shown = drawn.find(InAppNativeTags.COUNTDOWN) as TextView
        assertEquals("00:00:03", shown.text.toString())
        assertEquals(sp(22f), shown.textSize, 0.01f)
        assertEquals("tnum", shown.fontFeatureSettings)
        until(to - 3_000)
        assertEquals("00:00:03", shown.text.toString())
        until(to - 2_999)
        assertEquals("redrawn as the words change", "00:00:02", shown.text.toString())
        until(to - 1_999)
        assertEquals("00:00:01", shown.text.toString())
        until(to - 1)
        assertEquals("00:00:00", shown.text.toString())
        assertEquals(View.VISIBLE, shown.visibility)
        until(to + 1)
        assertEquals("gone once it has passed", View.GONE, shown.visibility)
    }

    @Test
    fun aCountdownAlreadyOverIsNotDrawn() {
        val base = plan("RP-053")
        offset = requireNotNull(base.countdownToMs) + 1 - SystemClock.uptimeMillis()
        assertFalse(show(base).has(InAppNativeTags.COUNTDOWN))
    }

    @Test
    fun aFormSaysTheFirstProblemThenSendsTheAnswersAndThanksThenCloses() {
        val drawn = show(plan("RP-060"))
        fun field(id: String): View = drawn.find(InAppNativeTags.field(id))
        fun input(id: String): EditText = (field(id) as ViewGroup).getChildAt(1) as EditText
        fun tap(id: String, value: String) = drawn.find(InAppNativeTags.option(id, value)).performClick()
        val problem = drawn.find(InAppNativeTags.PROBLEM) as TextView

        // A chip keeps room either side of its words, painted and picked: its inset background must not take the
        // padding away, or the words run into the pill's edge.
        val chip = drawn.find(InAppNativeTags.option("likes", "Bags"))
        assertTrue(chip.paddingLeft > 0 && chip.paddingRight > 0)
        tap("likes", "Bags")
        assertTrue(chip.paddingLeft > 0 && chip.paddingRight > 0)
        tap("likes", "Bags")

        // Required marks, and the keyboard each kind wants.
        assertEquals("Name *", ((field("name") as ViewGroup).getChildAt(0) as TextView).text.toString())
        assertEquals("Phone", ((field("phone") as ViewGroup).getChildAt(0) as TextView).text.toString())
        assertEquals(InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS, input("email").inputType and InputType.TYPE_MASK_VARIATION)
        assertEquals("an email box never capitalises", 0, input("email").inputType and InputType.TYPE_TEXT_FLAG_CAP_SENTENCES)
        assertEquals(InputType.TYPE_CLASS_PHONE, input("phone").inputType and InputType.TYPE_MASK_CLASS)
        assertEquals(InputType.TYPE_CLASS_NUMBER, input("age").inputType and InputType.TYPE_MASK_CLASS)
        assertTrue(input("age").inputType and InputType.TYPE_NUMBER_FLAG_DECIMAL != 0)
        assertTrue(input("about").inputType and InputType.TYPE_TEXT_FLAG_MULTI_LINE != 0)
        assertEquals("Your name", input("name").hint.toString())

        drawn.find(InAppNativeTags.SEND).performClick()
        assertEquals(View.VISIBLE, problem.visibility)
        assertEquals("Name is required.", problem.text.toString())
        assertEquals(inAppPlanColourInt("#B42318FF"), problem.currentTextColor)

        input("name").setText("Ada")
        input("email").setText("not an address")
        drawn.find(InAppNativeTags.SEND).performClick()
        assertEquals("Email is not an email address.", problem.text.toString())

        input("email").setText("ada@example.com")
        drawn.find(InAppNativeTags.SEND).performClick()
        assertEquals("How was it? is required.", problem.text.toString())
        assertTrue("nothing sent while there is a problem", sent.isEmpty())

        input("age").setText("34")
        tap("size", "M")
        tap("likes", "Outdoors")
        tap("likes", "Bags")
        tap("likes", "Shoes")
        tap("likes", "Bags")
        tap("stars", "4")
        tap("nps", "9")
        // Four stars filled, the fifth outlined.
        val filled = (1..5).map { ((drawn.find(InAppNativeTags.option("stars", "$it")) as ImageView).drawable as StarGlyph).isFilled }
        assertEquals(listOf(true, true, true, true, false), filled)

        // The platform's own menu, saying its placeholder until something is chosen.
        val plan = (field("plan") as ViewGroup).getChildAt(1) as TextView
        assertEquals("Pick a plan", plan.text.toString())
        plan.performClick()
        val menu = ShadowPopupMenu.getLatestPopupMenu()
        assertNotNull(menu)
        shadowOf(menu).onMenuItemClickListener.onMenuItemClick(menu.menu.getItem(1))
        assertEquals("Pro", plan.text.toString())

        // The platform's own date picker, answering YYYY-MM-DD.
        val birthday = (field("birthday") as ViewGroup).getChildAt(1) as TextView
        birthday.performClick()
        val picker = ShadowDialog.getLatestDialog() as DatePickerDialog
        picker.updateDate(1990, 4, 1)
        picker.getButton(DialogInterface.BUTTON_POSITIVE).performClick()
        idle()
        assertEquals("1990-05-01", birthday.text.toString())

        val sentAt = now()
        drawn.find(InAppNativeTags.SEND).performClick()
        assertEquals(listOf("shown", "submitted"), told)
        assertEquals(
            mapOf<String, Any>(
                "name" to "Ada", "email" to "ada@example.com", "age" to 34.0, "birthday" to "1990-05-01", "size" to "M",
                "plan" to "Pro", "likes" to "Shoes,Outdoors", "stars" to 4, "nps" to 9,
            ),
            sent.single(),
        )
        assertEquals("Welcome aboard.", (drawn.find(InAppNativeTags.THANKS) as TextView).text.toString())
        assertFalse("the thanks take the form's place", drawn.has(InAppNativeTags.SEND))

        until(sentAt + 2_400)
        assertEquals(listOf("shown", "submitted"), told)
        until(sentAt + 2_600)
        assertEquals("closed 2.5 s after the thanks", listOf("shown", "submitted", "answered"), told)
    }

    @Test
    fun theDefaultFormWordsAndAnUnknownKindAsATextBox() {
        val drawn = show(plan("RP-061"))
        assertEquals("Send", (drawn.find(InAppNativeTags.SEND) as TextView).text.toString())
    }

    @Test
    fun aPlanColourIsReadInCssOrderNeverAlphaFirst() {
        assertEquals(android.graphics.Color.argb(0x99, 0x0F, 0x17, 0x2A), inAppPlanColourInt("#0F172A99"))
        assertEquals(android.graphics.Color.argb(0xFF, 0x0A, 0x7A, 0x5A), inAppPlanColourInt("#0A7A5AFF"))
    }

    @Test
    fun theEnvironmentIsReadFromTheScreenItIsDrawnOn() {
        val configuration = android.content.res.Configuration(activity.resources.configuration)
        configuration.uiMode = android.content.res.Configuration.UI_MODE_NIGHT_YES or android.content.res.Configuration.UI_MODE_TYPE_NORMAL
        configuration.smallestScreenWidthDp = 600
        val env = inAppRenderEnvFor(configuration, null)
        assertEquals("dark", env.appearance)
        assertEquals("tablet", env.deviceClass)
        assertEquals("android", env.platform)
        configuration.uiMode = android.content.res.Configuration.UI_MODE_NIGHT_NO
        configuration.smallestScreenWidthDp = 599
        assertEquals("light", inAppRenderEnvFor(configuration, null).appearance)
        assertEquals("mobile", inAppRenderEnvFor(configuration, null).deviceClass)
        // Large text from a font scale of 1.3: at the larger sizes the plan is what keeps a banner's words whole.
        for ((scale, size) in listOf(1.0f to "default", 1.15f to "default", 1.29f to "default", 1.3f to "large", 2.0f to "large")) {
            configuration.fontScale = scale
            assertEquals("at $scale", size, inAppRenderEnvFor(configuration, null).textSize)
        }
    }

    private companion object {
        val PARTS = setOf(
            InAppNativeTags.PICTURE, InAppNativeTags.TITLE, InAppNativeTags.BODY, InAppNativeTags.CAROUSEL, InAppNativeTags.PREVIOUS,
            InAppNativeTags.SLIDE_COUNT, InAppNativeTags.NEXT, InAppNativeTags.COUNTDOWN, InAppNativeTags.FORM, InAppNativeTags.BUTTONS,
            InAppNativeTags.CLOSE,
        )
    }
}
