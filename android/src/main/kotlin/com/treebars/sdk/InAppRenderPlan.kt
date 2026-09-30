package com.treebars.sdk

import com.treebars.sdk.generated.TreebarsConstants
import org.json.JSONArray
import org.json.JSONObject

/*
 * The render contract. Kotlin and Swift draw every shape; React Native wraps them.
 *
 * What a standard in-app message looks like on a device is decided here, as data, before anything is drawn: the shape,
 * the resolved tokens, the words and how many lines they may take, the picture and its description, the buttons and
 * where each sends somebody, the form's controls, the carousel, the countdown, and how the message closes. The renderer
 * draws the plan and decides nothing the plan already decided — so the Swift renderer cannot come out different.
 *
 * `inAppRenderPlan` matches Treebars' reference implementation and the Swift SDK's line for line, and all three answer
 * the shared fixture `in-app-render.json` in this module's test resources (`InAppRenderPlanTest` runs every case). The
 * fixture's `decisions` record each choice where two reasonable renderers could differ, and which one this follows.
 *
 * It reads the server's own JSON — [InAppMessage.raw] or [TreebarsNotification.raw] — rather than the parsed classes,
 * which do not carry the form, the carousel or the countdown. A field of the wrong type is absent, as every reader of the
 * wire here treats it.
 */

/** The numbers every plan shares, which a plan does not repeat. `InAppRenderPlanTest` pins these to the fixture's `layout`. */
internal object InAppStandardLayout {
    const val MODAL_MAX_WIDTH = 320
    const val MODAL_MARGIN = 16
    const val BANNER_MARGIN = 16
    const val BANNER_THUMBNAIL = 48
    const val FULLSCREEN_TABLET_CONTENT_MAX_WIDTH = 560
    const val CARD_ICON = 40
    const val TITLE_SIZE = 16
    const val TITLE_WEIGHT = 700
    const val BODY_SIZE = 13
    const val BODY_LINE_HEIGHT = 18
    const val BUTTON_MIN_HEIGHT = 44
    const val BUTTON_WEIGHT = 600
    const val COUNTDOWN_SIZE = 22
    const val COUNTDOWN_WEIGHT = 600
    const val DISMISS_TARGET = 44
    const val FORM_THANKS_MS = 2500
    const val FORM_PROBLEM_COLOUR = "#B42318FF"
    const val WORD_SEND = "Send"
    const val WORD_THANKS = "Thank you."
    const val WORD_CHOOSE = "Choose…"

    fun toJson(): JSONObject = JSONObject()
        .put("modal", JSONObject().put("max_width", MODAL_MAX_WIDTH).put("margin", MODAL_MARGIN))
        .put("banner", JSONObject().put("margin", BANNER_MARGIN).put("thumbnail", BANNER_THUMBNAIL))
        .put("fullscreen", JSONObject().put("tablet_content_max_width", FULLSCREEN_TABLET_CONTENT_MAX_WIDTH))
        .put("card", JSONObject().put("icon", CARD_ICON))
        .put("title", JSONObject().put("size", TITLE_SIZE).put("weight", TITLE_WEIGHT))
        .put("body", JSONObject().put("size", BODY_SIZE).put("line_height", BODY_LINE_HEIGHT))
        .put("button", JSONObject().put("min_height", BUTTON_MIN_HEIGHT).put("weight", BUTTON_WEIGHT))
        .put("countdown", JSONObject().put("size", COUNTDOWN_SIZE).put("weight", COUNTDOWN_WEIGHT))
        .put("dismiss", JSONObject().put("target", DISMISS_TARGET))
        .put("form", JSONObject().put("thanks_ms", FORM_THANKS_MS).put("problem_colour", FORM_PROBLEM_COLOUR))
        .put("words", JSONObject().put("send", WORD_SEND).put("thanks", WORD_THANKS).put("choose", WORD_CHOOSE))
}

/**
 * What the device says about itself as a message is drawn — read then, never cached. `platform` changes nothing (the
 * fixture proves it). Sizes stay at scale 1 and Android scales them as sp; [textSize] only says whether the line caps
 * can hold the words at the size the person reads.
 */
internal data class InAppRenderEnv(
    val appearance: String,
    val platform: String,
    /** `tablet` at 600dp across the narrow side — the same line a markup body's `data-tb-show` draws — else `mobile`. */
    val deviceClass: String,
    /** The project's tokens from the last sync ([InAppStore.tokens]), for a message queued before messages carried their own. */
    val fallbackTokens: InAppTokens? = null,
    /**
     * `large` at a font scale of 1.3 or more ([inAppRenderEnvFor]), else `default` — and null is `default`. At the
     * largest size a modal's and a banner's words would end in "…", so a large plan uncaps a modal and a banner and puts
     * a banner's button under its words (the fixture's `text-scale` decision).
     */
    val textSize: String? = null,
)

/** Every colour `#RRGGBBAA` in CSS order — [android.graphics.Color.parseColor] reads the alpha FIRST, so convert, never pass through. */
internal data class InAppPlanTokens(
    val accent: String,
    val onAccent: String,
    val surface: String,
    val onSurface: String,
    val onSurfaceMuted: String,
    val backdrop: String,
    val radius: Double,
    val buttonRadius: Double,
    val fontFamily: String?,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("accent", accent).put("on_accent", onAccent).put("surface", surface).put("on_surface", onSurface)
        .put("on_surface_muted", onSurfaceMuted).put("backdrop", backdrop).put("radius", radius)
        .put("button_radius", buttonRadius).put("font_family", fontFamily ?: JSONObject.NULL)
}

internal data class InAppPlanImage(val url: String, val alt: String?, val placement: String, val aspect: String) {
    fun toJson(): JSONObject = JSONObject().put("url", url).put("alt", alt ?: JSONObject.NULL).put("placement", placement).put("aspect", aspect)
}

internal data class InAppPlanText(val text: String, val maxLines: Int?) {
    fun toJson(): JSONObject = JSONObject().put("text", text).put("max_lines", maxLines ?: JSONObject.NULL)
}

internal data class InAppPlanSlide(val imageUrl: String, val imageAlt: String?, val title: String?, val body: String?) {
    fun toJson(): JSONObject = JSONObject().put("image_url", imageUrl).put("image_alt", imageAlt ?: JSONObject.NULL)
        .put("title", title ?: JSONObject.NULL).put("body", body ?: JSONObject.NULL)
}

internal data class InAppPlanField(
    val id: String,
    val kind: String,
    val label: String,
    val required: Boolean,
    /** `text`, `chips`, `multi_chips`, `menu` (the platform's picker), `date` (its date picker, answered YYYY-MM-DD) or `scale`. */
    val control: String,
    /** For `text`: `text`, `email` (no auto-capitalisation), `phone` or `decimal`. */
    val keyboard: String? = null,
    val multiline: Boolean = false,
    val placeholder: String? = null,
    val options: List<String>? = null,
    val scale: List<Int>? = null,
    val glyph: String? = null,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("id", id).put("kind", kind).put("label", label).put("required", required).put("control", control)
        .put("keyboard", keyboard ?: JSONObject.NULL).put("multiline", multiline).put("placeholder", placeholder ?: JSONObject.NULL)
        .put("options", options?.let { JSONArray(it) } ?: JSONObject.NULL)
        .put("scale", scale?.let { JSONArray(it) } ?: JSONObject.NULL)
        .put("glyph", glyph ?: JSONObject.NULL)
}

internal data class InAppPlanForm(val fields: List<InAppPlanField>, val submitLabel: String, val thanks: String) {
    fun toJson(): JSONObject = JSONObject().put("fields", JSONArray(fields.map { it.toJson() })).put("submit_label", submitLabel).put("thanks", thanks)
}

internal data class InAppPlanButton(
    /** Its place in the message's own list, from 1: what `in_app_clicked` reports as `button_index`. */
    val index: Int,
    val label: String,
    val action: String,
    /** `primary` (filled with accent) for the first drawn, `secondary` (accent words on nothing) for the second. */
    val style: String,
    val value: String?,
    val eventName: String?,
    val key: String?,
    val data: Map<String, String>?,
    /** Where a press sends somebody, opened by the SDK after the click is recorded — a link or a page, never a trait's value. */
    val destination: String?,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("index", index).put("label", label).put("action", action).put("style", style)
        .put("value", value ?: JSONObject.NULL).put("event_name", eventName ?: JSONObject.NULL).put("key", key ?: JSONObject.NULL)
        .put("data", data?.let { JSONObject(it as Map<*, *>) } ?: JSONObject.NULL)
        .put("destination", destination ?: JSONObject.NULL)
}

internal data class InAppPlanDismiss(
    val control: Boolean,
    /** Logical: `top_end` is the right of a left-to-right message and the left of a right-to-left one. */
    val corner: String,
    val backdropTap: Boolean,
    /** Android's back: only what interrupts, and only when it may be closed. */
    val back: Boolean,
    val afterMs: Long?,
) {
    fun toJson(): JSONObject = JSONObject().put("control", control).put("corner", corner).put("backdrop_tap", backdropTap)
        .put("back", back).put("after_ms", afterMs ?: JSONObject.NULL)
}

internal sealed class InAppRenderPlan {
    abstract fun toJson(): JSONObject

    /** An HTML body: [InAppHtmlHost] draws it, never a renderer. */
    object Markup : InAppRenderPlan() {
        override fun toJson(): JSONObject = JSONObject().put("kind", "markup")
    }

    /** No in-app content at all — a push in the feed, which the card inbox view decides for itself. */
    object None : InAppRenderPlan() {
        override fun toJson(): JSONObject = JSONObject().put("kind", "none")
    }

    data class Overlay(
        val shape: String,
        val edge: String?,
        val appearance: String,
        val direction: String,
        val tokens: InAppPlanTokens,
        val backdrop: Boolean,
        val contentMaxWidth: Int?,
        val animation: String,
        val image: InAppPlanImage?,
        val title: InAppPlanText?,
        val body: InAppPlanText?,
        val slides: List<InAppPlanSlide>?,
        val countdownToMs: Long?,
        val form: InAppPlanForm?,
        val buttons: List<InAppPlanButton>,
        /**
         * `content` after the words, `trailing` beside them on a banner (`content` on one at a large text size),
         * `bottom` pinned above the safe area.
         */
        val buttonsAt: String,
        val dismiss: InAppPlanDismiss,
    ) : InAppRenderPlan() {
        override fun toJson(): JSONObject = JSONObject()
            .put("kind", "overlay").put("shape", shape).put("edge", edge ?: JSONObject.NULL).put("appearance", appearance)
            .put("direction", direction).put("tokens", tokens.toJson()).put("backdrop", backdrop)
            .put("content_max_width", contentMaxWidth ?: JSONObject.NULL).put("animation", animation)
            .put("image", image?.toJson() ?: JSONObject.NULL).put("title", title?.toJson() ?: JSONObject.NULL)
            .put("body", body?.toJson() ?: JSONObject.NULL)
            .put(
                "slides",
                slides?.let { JSONObject().put("items", JSONArray(it.map(InAppPlanSlide::toJson))).put("controls", it.size > 1) } ?: JSONObject.NULL,
            )
            .put("countdown", countdownToMs?.let { JSONObject().put("to_ms", it) } ?: JSONObject.NULL)
            .put("form", form?.toJson() ?: JSONObject.NULL)
            .put("buttons", JSONArray(buttons.map(InAppPlanButton::toJson))).put("buttons_at", buttonsAt)
            .put("dismiss", dismiss.toJson())
    }

    data class Card(
        val template: String,
        val appearance: String,
        val direction: String,
        val tokens: InAppPlanTokens,
        val image: InAppPlanImage?,
        val title: InAppPlanText?,
        val body: InAppPlanText?,
        /** Where a tap on the card goes: its own action, else the row's deep link. */
        val destination: String?,
        val ctaLabel: String?,
        val ctaDestination: String?,
        val pinned: Boolean,
        val category: String?,
    ) : InAppRenderPlan() {
        override fun toJson(): JSONObject = JSONObject()
            .put("kind", "card").put("template", template).put("appearance", appearance).put("direction", direction)
            .put("tokens", tokens.toJson()).put("image", image?.toJson() ?: JSONObject.NULL)
            .put("title", title?.toJson() ?: JSONObject.NULL).put("body", body?.toJson() ?: JSONObject.NULL)
            .put("destination", destination ?: JSONObject.NULL)
            .put(
                "cta",
                if (ctaLabel != null && ctaDestination != null) JSONObject().put("label", ctaLabel).put("destination", ctaDestination) else JSONObject.NULL,
            )
            .put("pinned", pinned).put("category", category ?: JSONObject.NULL)
    }
}

/*
 * Reading the wire: `opt` hands back `JSONObject.NULL` for a null and the value itself otherwise, so a cast is the
 * type check — `optString` would turn a null into the string "null" and a number into its digits.
 */
private fun JSONObject?.obj(key: String): JSONObject? = this?.opt(key) as? JSONObject
private fun JSONObject?.list(key: String): JSONArray? = this?.opt(key) as? JSONArray
private fun JSONObject?.text(key: String): String? = (this?.opt(key) as? String)?.takeIf { it.isNotEmpty() }
private fun JSONObject?.flag(key: String): Boolean? = this?.opt(key) as? Boolean

/*
 * Colours, in the grammar every Treebars SDK shares: `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA`, `rgb()` and `rgba()`. `[0-9]`
 * rather than `\d`, as in Swift, where `\d` takes Arabic-Indic digits too.
 */
private val HEX = Regex("^#([0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$")
private val RGB = Regex(
    "^rgba?\\(\\s*([0-9]{1,3})\\s*,\\s*([0-9]{1,3})\\s*,\\s*([0-9]{1,3})\\s*(?:,\\s*([0-9]*\\.?[0-9]+)\\s*)?\\)$",
    RegexOption.IGNORE_CASE,
)

private fun hex2(value: Int): String = value.toString(16).uppercase().padStart(2, '0')

/** `#RRGGBBAA`, upper case, or null for a colour outside the grammar. */
internal fun inAppPlanColour(value: String?): String? {
    val text = value?.trim() ?: return null
    HEX.matchEntire(text)?.let { match ->
        val raw = match.groupValues[1]
        val digits = if (raw.length <= 4) raw.map { "$it$it" }.joinToString("") else raw
        return "#${digits.uppercase()}${if (digits.length == 6) "FF" else ""}"
    }
    val rgb = RGB.matchEntire(text) ?: return null
    val channel = { index: Int -> hex2(minOf(255, rgb.groupValues[index].toInt())) }
    val alpha = rgb.groupValues[4].takeIf { it.isNotEmpty() }?.toDouble()?.coerceIn(0.0, 1.0) ?: 1.0
    return "#${channel(1)}${channel(2)}${channel(3)}${hex2(Math.round(alpha * 255).toInt())}"
}

/** The default preset (`minimal`), which the server resolves an unstyled message to. */
private val PRESET_COLOURS = mapOf(
    "accent" to "#5B4DF5", "on_accent" to "#FFFFFF", "surface" to "#FFFFFF", "on_surface" to "#111827",
    "on_surface_muted" to "#6B7280", "backdrop" to "#0F172A99",
)
private const val PRESET_RADIUS = 8.0

/** The sync's parsed project tokens, back in the wire's shape, so one reader serves them and a message's own. */
private fun InAppTokens.wire(): JSONObject = JSONObject()
    .put("accent", accent).put("on_accent", onAccent).put("surface", surface).put("on_surface", onSurface)
    .put("on_surface_muted", onSurfaceMuted).put("backdrop", backdrop).put("radius", radius)
    .put("font_family", fontFamily).put("button_shape", buttonShape)

/**
 * Its own dark set while the device is dark and it has one; else its own; else the project's from the sync; else
 * the default preset. Each colour outside the grammar is the preset's, so a renderer never guesses at a string. Read off
 * the JSON rather than through [parseInAppTokens], whose `optString` turns a null font into the family "null".
 */
private fun planTokens(row: JSONObject, env: InAppRenderEnv): Pair<InAppPlanTokens, String> {
    val dark = if (env.appearance == "dark") row.obj("style_dark") else null
    val chosen = dark ?: row.obj("style") ?: env.fallbackTokens?.wire() ?: JSONObject()
    val colour = { key: String -> inAppPlanColour(chosen.opt(key) as? String) ?: inAppPlanColour(PRESET_COLOURS.getValue(key))!! }
    val radius = (chosen.opt("radius") as? Number)?.toDouble()?.takeIf { it.isFinite() && it >= 0 } ?: PRESET_RADIUS
    // `rounded` is the card's own radius on buttons too, as the preview draws it; the web SDK draws 8 whatever it is.
    val buttonRadius = when (chosen.opt("button_shape")) {
        "pill" -> 999.0
        "square" -> 0.0
        else -> radius
    }
    return InAppPlanTokens(
        accent = colour("accent"),
        onAccent = colour("on_accent"),
        surface = colour("surface"),
        onSurface = colour("on_surface"),
        onSurfaceMuted = colour("on_surface_muted"),
        backdrop = colour("backdrop"),
        radius = radius,
        buttonRadius = buttonRadius,
        fontFamily = (chosen.opt("font_family") as? String)?.trim()?.takeIf { it.isNotEmpty() },
    ) to (if (dark != null) "dark" else "light")
}

/*
 * An instant, read one way in every Treebars SDK: one grammar, converted by arithmetic. `Iso8601.parseOrNull` takes only
 * `Z`, `SimpleDateFormat` would take shapes Swift refuses, and `java.time` is API 26 where this module's floor is 24.
 */
private val INSTANT = Regex(
    "^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2})(?::([0-9]{2})(?:\\.([0-9]{1,6}))?)?(Z|([+-])([0-9]{2}):([0-9]{2}))$",
)

/** Days from 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's `days_from_civil`). */
private fun daysFromCivil(year: Long, month: Long, day: Long): Long {
    val y = if (month <= 2) year - 1 else year
    val era = Math.floorDiv(y, 400L)
    val yoe = y - era * 400
    val doy = (153 * (month + if (month > 2) -3 else 9) + 2) / 5 + day - 1
    val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468
}

private fun daysInMonth(year: Int, month: Int): Int = when (month) {
    2 -> if ((year % 4 == 0 && year % 100 != 0) || year % 400 == 0) 29 else 28
    4, 6, 9, 11 -> 30
    else -> 31
}

/** Epoch milliseconds, or null for anything that is not a real instant in that one grammar. */
internal fun inAppPlanInstant(value: String?): Long? {
    val match = INSTANT.matchEntire(value ?: return null) ?: return null
    val group = match.groupValues
    val (year, month, day, hour, minute) = (1..5).map { group[it].toInt() }
    val second = group[6].takeIf { it.isNotEmpty() }?.toInt() ?: 0
    val millis = group[7].takeIf { it.isNotEmpty() }?.padEnd(3, '0')?.take(3)?.toInt() ?: 0
    if (month !in 1..12 || day < 1 || day > daysInMonth(year, month) || hour > 23 || minute > 59 || second > 59) return null
    var offset = 0L
    if (group[8] != "Z") {
        val (offsetHours, offsetMinutes) = group[10].toInt() to group[11].toInt()
        if (offsetHours > 23 || offsetMinutes > 59) return null
        offset = (if (group[9] == "-") -1L else 1L) * (offsetHours * 60 + offsetMinutes) * 60_000L
    }
    return daysFromCivil(year.toLong(), month.toLong(), day.toLong()) * 86_400_000L + hour * 3_600_000L + minute * 60_000L +
        second * 1000L + millis - offset
}

/** `2d 04:13:09` until the moment, `04:13:09` inside the last day, and `""` once it has passed — the web SDK's words too. */
internal fun inAppCountdownText(toMs: Long, nowMs: Long): String {
    val left = maxOf(0L, toMs - nowMs)
    if (left == 0L) return ""
    val seconds = left / 1000
    val days = seconds / 86_400
    val pad = { value: Long -> value.toString().padStart(2, '0') }
    val clock = "${pad((seconds % 86_400) / 3600)}:${pad((seconds % 3600) / 60)}:${pad(seconds % 60)}"
    return if (days > 0) "${days}d $clock" else clock
}

private val KEYBOARDS = mapOf("email" to "email", "phone" to "phone", "number" to "decimal")

/** One form field as a renderer draws it. A kind this build does not know is a text box, as the other SDKs draw one. */
internal fun inAppPlanField(field: JSONObject): InAppPlanField {
    val kind = field.opt("kind") as? String ?: ""
    val options = field.list("options")?.let { list -> (0 until list.length()).mapNotNull { list.opt(it) as? String } } ?: emptyList()
    val placeholder = field.text("placeholder")
    val base = InAppPlanField(
        id = field.opt("id") as? String ?: "",
        kind = kind,
        label = field.opt("label") as? String ?: "",
        required = field.flag("required") == true,
        control = "text",
    )
    return when (kind) {
        "choice" -> base.copy(control = "chips", options = options)
        "multi_choice" -> base.copy(control = "multi_chips", options = options)
        "dropdown" -> base.copy(control = "menu", options = options, placeholder = placeholder ?: InAppStandardLayout.WORD_CHOOSE)
        "date" -> base.copy(control = "date")
        "rating" -> base.copy(control = "scale", scale = (1..5).toList(), glyph = "star")
        "nps" -> base.copy(control = "scale", scale = (0..10).toList(), glyph = "number")
        else -> base.copy(keyboard = KEYBOARDS[kind] ?: "text", multiline = kind == "textarea", placeholder = placeholder)
    }
}

private fun planForm(form: JSONObject?): InAppPlanForm? {
    val list = form.list("fields") ?: return null
    val fields = (0 until list.length()).mapNotNull { (list.opt(it) as? JSONObject)?.let(::inAppPlanField) }
    if (fields.isEmpty()) return null
    return InAppPlanForm(fields, form.text("submit_label") ?: InAppStandardLayout.WORD_SEND, form.text("thanks") ?: InAppStandardLayout.WORD_THANKS)
}

/** Every action a typed button has. A button with another is not drawn. */
private val ACTIONS = setOf("dismiss", "deep_link", "url", "track_event", "set_attribute", "custom", "call", "copy", "share", "store_review")

/** A link or a page goes somewhere; a trait's value and the push opt-in link do not. */
private fun destinationOf(action: String, value: String?): String? =
    if ((action == "url" || action == "deep_link") && value != null && value != TreebarsConstants.PUSH_PERMISSION_LINK) value else null

private fun planButtons(list: JSONArray?, max: Int): List<InAppPlanButton> {
    val drawn = mutableListOf<InAppPlanButton>()
    for (position in 0 until (list?.length() ?: 0)) {
        val button = list!!.opt(position) as? JSONObject ?: continue
        val action = button.opt("action") as? String ?: continue
        if (action !in ACTIONS || drawn.size >= max) continue
        val data = button.obj("data")?.let { data -> data.keys().asSequence().mapNotNull { key -> (data.opt(key) as? String)?.let { key to it } }.toMap() }
        drawn += InAppPlanButton(
            index = position + 1,
            label = button.opt("label") as? String ?: "",
            action = action,
            style = if (drawn.isEmpty()) "primary" else "secondary",
            value = button.text("value"),
            eventName = button.text("event_name"),
            key = button.text("key"),
            data = data?.takeIf { it.isNotEmpty() },
            destination = destinationOf(action, button.text("value")),
        )
    }
    return drawn
}

private fun planSlides(list: JSONArray?): List<InAppPlanSlide>? {
    val items = (0 until (list?.length() ?: 0)).mapNotNull { index ->
        val slide = list!!.opt(index) as? JSONObject ?: return@mapNotNull null
        val url = slide.text("image_url") ?: return@mapNotNull null
        InAppPlanSlide(url, slide.text("image_alt"), slide.text("title"), slide.text("body"))
    }
    return items.takeIf { it.isNotEmpty() }
}

/** Where it sits — and a typed nudge from an older server is the bar it most resembles. */
private fun planShape(layout: Any?): String = when (layout) {
    "banner", "nudge" -> "banner"
    "fullscreen", "html" -> "fullscreen"
    else -> "modal"
}

/** Turns a synced message or a feed row — the server's own JSON — into what to draw. Pure. */
internal fun inAppRenderPlan(row: JSONObject, env: InAppRenderEnv): InAppRenderPlan {
    val content = row.obj("content")
    val inApp = content.obj("in_app") ?: return InAppRenderPlan.None
    val bodyMode = when (val mode = inApp.opt("body_mode")) {
        "html", "standard" -> mode
        else -> if (inApp.opt("layout") == "html") "html" else "standard"
    }
    if (bodyMode == "html") return InAppRenderPlan.Markup

    val (tokens, appearance) = planTokens(row, env)
    val direction = if (inApp.opt("direction") == "rtl") "rtl" else "ltr"
    val title = content.text("title")
    val body = content.text("body")
    val imageUrl = content.text("image_url")

    if (inApp.opt("surface") == "inbox") {
        val card = inApp.obj("card")
        val illustration = card?.opt("template") == "illustration"
        val cta = card.obj("cta")
        // An icon beside the words; the message's own picture above them on an illustration; a row with no card keeps its picture as the icon.
        val source = if (illustration) imageUrl else if (card != null) card.text("icon_url") else imageUrl
        return InAppRenderPlan.Card(
            template = if (illustration) "illustration" else "basic",
            appearance = appearance,
            direction = direction,
            tokens = tokens,
            image = source?.let {
                InAppPlanImage(it, card.text("image_alt"), if (illustration) "top" else "leading", if (illustration) "2:1" else "1:1")
            },
            title = title?.let { InAppPlanText(it, 1) },
            body = body?.let { InAppPlanText(it, 2) },
            destination = card.obj("action").text("value") ?: content.text("deep_link"),
            ctaLabel = cta.text("label")?.takeIf { cta.obj("action").text("value") != null },
            ctaDestination = cta.obj("action").text("value")?.takeIf { cta.text("label") != null },
            pinned = card.flag("pinned") == true,
            category = card.text("category"),
        )
    }

    val shape = planShape(inApp.opt("layout"))
    val edge = if (shape == "banner") (if (inApp.opt("position") == "top") "top" else "bottom") else null
    val dismissible = inApp.flag("dismissible") != false
    val auto = (inApp.obj("display")?.opt("auto_dismiss_seconds") as? Number)?.toDouble()
    // At an accessibility text size a cut message has lost its words, and the renderers scroll one taller than its
    // room, so the caps come off; a fullscreen is never capped, and a card keeps its lines (the fixture's `text-scale`).
    val large = env.textSize == "large"
    val (titleLines, bodyLines) = when {
        large -> null to null
        shape == "modal" -> 2 to 4
        shape == "banner" -> 1 to 2
        else -> null to null
    }
    return InAppRenderPlan.Overlay(
        shape = shape,
        edge = edge,
        appearance = appearance,
        direction = direction,
        tokens = tokens,
        backdrop = shape == "modal",
        contentMaxWidth = if (shape == "fullscreen" && env.deviceClass == "tablet") InAppStandardLayout.FULLSCREEN_TABLET_CONTENT_MAX_WIDTH else null,
        animation = when (edge) {
            "top" -> "slide_top"
            "bottom" -> "slide_bottom"
            else -> "fade"
        },
        image = imageUrl?.let {
            InAppPlanImage(
                url = it,
                alt = inApp.text("image_alt"),
                placement = if (shape == "banner") "leading" else "top",
                aspect = when (shape) {
                    "banner" -> "1:1"
                    "fullscreen" -> "16:9"
                    else -> "2:1"
                },
            )
        },
        title = title?.let { InAppPlanText(it, titleLines) },
        body = body?.let { InAppPlanText(it, bodyLines) },
        slides = planSlides(inApp.list("slides")),
        countdownToMs = inAppPlanInstant(inApp.opt("countdown_to") as? String),
        form = planForm(inApp.obj("form")),
        buttons = planButtons(inApp.list("buttons"), if (shape == "banner") 1 else 2),
        buttonsAt = when (shape) {
            // Beside the words, a button at the largest size takes the room the words need: under them instead.
            "banner" -> if (large) "content" else "trailing"
            "fullscreen" -> "bottom"
            else -> "content"
        },
        dismiss = InAppPlanDismiss(
            control = dismissible,
            corner = if (shape == "fullscreen") "top_start" else "top_end",
            backdropTap = dismissible && shape == "modal",
            back = dismissible && shape != "banner",
            afterMs = auto?.takeIf { it.isFinite() && it > 0 }?.let { Math.round(it * 1000) },
        ),
    )
}

/* The form's two rules, applied before `submitInAppForm`, in words an app can show as they are. */

/** `[^\\s@]` spelled out as any character but `@`, space and the ASCII controls, which Java, ICU and JavaScript read alike. */
private val EMAIL = Regex("^[^@\\x00-\\x20]+@[^@\\x00-\\x20]+\\.[^@\\x00-\\x20]+$")
private val NUMBER = Regex(TreebarsConstants.NUMBER_GRAMMAR)
private val DAY = Regex("^([0-9]{4})-([0-9]{2})-([0-9]{2})$")

/** A calendar day as `YYYY-MM-DD`, and one that exists: `2026-02-30` is not a day. */
internal fun inAppIsDay(value: String): Boolean {
    val match = DAY.matchEntire(value) ?: return false
    val (year, month, day) = (1..3).map { match.groupValues[it].toInt() }
    return month in 1..12 && day >= 1 && day <= daysInMonth(year, month)
}

private fun isEmptyAnswer(answer: Any?): Boolean =
    answer == null || (answer is String && answer.trim().isEmpty()) || (answer is List<*> && answer.isEmpty())

/**
 * Why the form cannot be sent yet — the first problem, top to bottom — or null when it can. An answer is typed text, a
 * picked number, or a multiple choice's picks as a list.
 */
internal fun inAppFormProblem(fields: List<InAppPlanField>, answers: Map<String, Any?>): String? {
    for (field in fields) {
        val answer = answers[field.id]
        if (isEmptyAnswer(answer)) {
            if (field.required) return "${field.label} is required."
            continue
        }
        val typed = if (answer is List<*>) answer.joinToString(",") else answer.toString().trim()
        if (field.kind == "email" && !EMAIL.matches(typed)) return "${field.label} is not an email address."
        if (field.kind == "phone" && typed.count { it in '0'..'9' } < 7) return "${field.label} is not a phone number."
        if (field.kind == "number" && answer !is Number && !NUMBER.matches(typed)) return "${field.label} needs a number."
        if (field.kind == "date" && !inAppIsDay(typed)) return "${field.label} needs a date, as YYYY-MM-DD."
    }
    return null
}

/**
 * The answers as `submitInAppForm` sends them: a number as a number, text trimmed, several choices as one answer in the
 * author's order whatever order they were tapped in, and nothing for a field left empty.
 */
internal fun inAppFormAnswers(fields: List<InAppPlanField>, answers: Map<String, Any?>): Map<String, Any> {
    val out = linkedMapOf<String, Any>()
    for (field in fields) {
        when (val answer = answers[field.id]) {
            null -> continue
            is Number -> out[field.id] = answer
            is List<*> -> {
                val picked = answer.toSet()
                val joined = (field.options ?: emptyList()).filter { it in picked }.joinToString(",")
                if (joined.isNotEmpty()) out[field.id] = joined
            }
            else -> {
                val trimmed = answer.toString().trim()
                if (trimmed.isEmpty()) continue
                out[field.id] = if (field.kind == "number" && NUMBER.matches(trimmed)) trimmed.toDouble() else trimmed
            }
        }
    }
    return out
}
