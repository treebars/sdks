package com.treebars.sdk

import com.treebars.sdk.generated.TreebarsBridge
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/*
 * What the host tells an HTML message about the screen it is on, and where a strip goes.
 *
 * The host paints nothing. A stage message — a modal, a sheet, a full screen, a canvas — is a transparent WebView over the
 * whole window, and the page draws its own scrim, card and shadow; a strip — a banner, a nudge — is a transparent WebView
 * fitted at an edge. Either way the page can only place itself right if it is told the truth about the screen: the
 * insets, the keyboard, which way the device is held, the text size. It is told when the document is built and again on
 * every change, so a rotation or a keyboard is never answered with what was true a moment ago.
 *
 * Pure, so the unit tests run it as it is; iOS's `InAppHostEnv` and the web SDK's `host-env.ts` compute the same answers,
 * and `in-app-host.json` holds all three to them — the box to the point, and the text a page reads byte for byte.
 */

/** A box in the window, in dp. */
internal data class HostRect(val x: Double, val y: Double, val w: Double, val h: Double)

/** Insets in dp, before they are rounded for the page. */
internal data class HostInsets(val top: Double, val right: Double, val bottom: Double, val left: Double) {
    companion object {
        val ZERO = HostInsets(0.0, 0.0, 0.0, 0.0)
    }
}

/** What the page is told. dp, rounded up; [textScale] to the hundredth. */
internal data class InAppEnv(
    val host: String,
    /** `phone`, `tablet` or `desktop`. */
    val device: String,
    val orientation: String,
    val theme: String,
    val safe: BridgeInsets,
    val keyboardHeight: Int,
    val keyboardMs: Int,
    val textScale: Double,
    val shown: Boolean,
)

internal object InAppHostEnv {
    /**
     * Where a strip's WebView goes. Its height is what the page reported — the container and the shadow room it pads
     * itself by — up to a share of the window: 30% for a banner, 20% for a nudge; before the page has reported, the cap.
     * A banner spans the window at its edge, under the bars, and its page pads by the inset; a nudge sits inside the safe
     * area on every side, after the nudges already at its edge.
     */
    fun stripBox(width: Double, height: Double, safe: HostInsets, edge: String, floating: Boolean, contentHeight: Double?, offset: Double = 0.0): HostRect {
        val cap = height * if (floating) TreebarsBridge.NUDGE_MAX_HEIGHT_SHARE else TreebarsBridge.BANNER_MAX_HEIGHT_SHARE
        val tall = max(0.0, min(contentHeight ?: cap, cap))
        if (!floating) return HostRect(0.0, if (edge == "top") 0.0 else height - tall, width, tall)
        val wide = max(0.0, width - safe.left - safe.right)
        return HostRect(safe.left, if (edge == "top") safe.top + offset else height - safe.bottom - offset - tall, wide, tall)
    }

    /** Up to the next whole dp, forgiving the noise a division leaves: 59.0000001 is 59. */
    private fun up(value: Double): Int = max(0, ceil(value - 0.001).toInt())

    private fun clamp(value: Double, low: Double, high: Double): Double = min(max(value, low), high)

    /** The text scale as the page reads it: to the hundredth, and 1 for anything that is not a positive number. */
    fun textScale(value: Double): Double = if (value.isFinite() && value > 0) Math.round(value * 100) / 100.0 else 1.0

    /**
     * The environment for a WebView at [frame] in a window of this size: the part of the window's unsafe area, and of the
     * keyboard, that lies over the WebView. A stage passes no frame, because it is the window.
     */
    fun env(
        host: String,
        device: String,
        theme: String,
        textScale: Double,
        shown: Boolean,
        width: Double,
        height: Double,
        safe: HostInsets,
        frame: HostRect? = null,
        keyboardHeight: Double,
        keyboardMs: Double,
    ): InAppEnv {
        val box = frame ?: HostRect(0.0, 0.0, width, height)
        val keyboardTop = height - clamp(keyboardHeight, 0.0, height)
        return InAppEnv(
            host = host,
            device = device,
            orientation = if (width > height) "landscape" else "portrait",
            theme = theme,
            safe = BridgeInsets(
                up(clamp(safe.top - box.y, 0.0, box.h)),
                up(clamp(box.x + box.w - (width - safe.right), 0.0, box.w)),
                up(clamp(box.y + box.h - (height - safe.bottom), 0.0, box.h)),
                up(clamp(safe.left - box.x, 0.0, box.w)),
            ),
            keyboardHeight = up(clamp(box.y + box.h - keyboardTop, 0.0, box.h)),
            keyboardMs = max(0, Math.round(keyboardMs).toInt()),
            textScale = textScale(textScale),
            shown = shown,
        )
    }

    /** `1`, `1.3`, `1.15`: a scale to the hundredth, written as JavaScript writes the number. */
    fun scaleText(value: Double): String {
        val hundredths = Math.round(textScale(value) * 100).toInt()
        val whole = hundredths / 100
        val rest = hundredths % 100
        if (rest == 0) return whole.toString()
        return if (rest % 10 == 0) "$whole.${rest / 10}" else "$whole.${if (rest < 10) "0" else ""}$rest"
    }

    /** The text `__treebarsEnv` is called with: one key order and one way to write each number, on every host. */
    fun json(env: InAppEnv): String =
        "{\"host\":\"${env.host}\",\"device\":\"${env.device}\",\"orientation\":\"${env.orientation}\",\"theme\":\"${env.theme}\"," +
            "\"safe\":{\"top\":${env.safe.top},\"right\":${env.safe.right},\"bottom\":${env.safe.bottom},\"left\":${env.safe.left}}," +
            "\"keyboard\":{\"height\":${env.keyboardHeight},\"ms\":${env.keyboardMs}},\"textScale\":${scaleText(env.textScale)},\"shown\":${env.shown}}"

    /** The `<style id="tb-env">` the page reads its environment from, as the shim rewrites it. */
    fun style(env: InAppEnv): String =
        ":root{color-scheme:normal;--tb-safe-top:${env.safe.top}px;--tb-safe-right:${env.safe.right}px;--tb-safe-bottom:${env.safe.bottom}px;" +
            "--tb-safe-left:${env.safe.left}px;--tb-keyboard:${env.keyboardHeight}px;--tb-keyboard-ms:${env.keyboardMs}ms;--tb-text-scale:${scaleText(env.textScale)}}"

    /** `<html>`'s attributes, with a leading space: the keyboard and shown states present or absent. */
    fun attributes(env: InAppEnv): String =
        " data-tb-host=\"${env.host}\" data-tb-device=\"${env.device}\" data-tb-orientation=\"${env.orientation}\" data-tb-theme=\"${env.theme}\"" +
            (if (env.keyboardHeight > 0) " data-tb-keyboard" else "") + (if (env.shown) " data-tb-shown" else "")
}
