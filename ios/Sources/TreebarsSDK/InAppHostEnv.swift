import Foundation

/*
 What the host tells an HTML message about the screen it is on, and where a strip goes.

 The host paints nothing. A stage message — a modal, a sheet, a full screen, a canvas — is a transparent WebView over the
 whole window, and the page draws its own scrim, card and shadow; a strip — a banner, a nudge — is a transparent WebView
 fitted at an edge. Either way the page can only place itself right if it is told the truth about the screen: the
 insets, the keyboard, which way the device is held, the text size. It is told when the document is built and again on
 every change, so a rotation or a keyboard is never answered with what was true a moment ago.

 Pure, so it runs in the unit tests on any platform; Android's `InAppHostEnv` and the web SDK's `host-env.ts` compute the
 same answers, and `in-app-host.json` holds all three to them — the box to the point, and the text a page reads byte for
 byte.
 */

/// A box in the window, in points.
struct HostRect: Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

/// Insets in points, before they are rounded for the page.
struct HostInsets: Equatable {
    var top: Double
    var right: Double
    var bottom: Double
    var left: Double

    static let zero = HostInsets(top: 0, right: 0, bottom: 0, left: 0)
}

/// What the page is told. Points, rounded up; `textScale` to the hundredth.
struct InAppEnv: Equatable {
    var host: String
    /// `phone`, `tablet` or `desktop`.
    var device: String
    var orientation: String
    var theme: String
    var safe: BridgeInsets
    var keyboardHeight: Int
    var keyboardMs: Int
    var textScale: Double
    var shown: Bool
}

enum InAppHostEnv {
    /**
     Where a strip's WebView goes. Its height is what the page reported — the container and the shadow room it pads
     itself by — up to a share of the window: 30% for a banner, 20% for a nudge; before the page has reported, the cap. A
     banner spans the window at its edge, under the bars, and its page pads by the inset; a nudge sits inside the safe
     area on every side, after the nudges already at its edge.
     */
    static func stripBox(width: Double, height: Double, safe: HostInsets, edge: String, floating: Bool, contentHeight: Double?, offset: Double = 0) -> HostRect {
        let cap = height * (floating ? InAppBridge.nudgeMaxHeightShare : InAppBridge.bannerMaxHeightShare)
        let tall = max(0, min(contentHeight ?? cap, cap))
        if !floating { return HostRect(x: 0, y: edge == "top" ? 0 : height - tall, w: width, h: tall) }
        let wide = max(0, width - safe.left - safe.right)
        return HostRect(x: safe.left, y: edge == "top" ? safe.top + offset : height - safe.bottom - offset - tall, w: wide, h: tall)
    }

    /// Up to the next whole point, forgiving the noise a division leaves: 59.0000001 is 59.
    private static func up(_ value: Double) -> Int {
        max(0, Int((value - 0.001).rounded(.up)))
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }

    /// The text scale as the page reads it: to the hundredth, and 1 for anything that is not a positive number.
    static func textScale(_ value: Double) -> Double {
        value.isFinite && value > 0 ? (value * 100).rounded() / 100 : 1
    }

    /**
     The environment for a WebView at `frame` in a window of this size: the part of the window's unsafe area, and of the
     keyboard, that lies over the WebView. A stage passes no frame, because it is the window.
     */
    static func env(
        host: String, device: String, theme: String, textScale scale: Double, shown: Bool,
        width: Double, height: Double, safe: HostInsets, frame: HostRect? = nil, keyboardHeight: Double, keyboardMs: Double
    ) -> InAppEnv {
        let box = frame ?? HostRect(x: 0, y: 0, w: width, h: height)
        let keyboardTop = height - clamp(keyboardHeight, 0, height)
        return InAppEnv(
            host: host,
            device: device,
            orientation: width > height ? "landscape" : "portrait",
            theme: theme,
            safe: BridgeInsets(
                top: up(clamp(safe.top - box.y, 0, box.h)),
                right: up(clamp(box.x + box.w - (width - safe.right), 0, box.w)),
                bottom: up(clamp(box.y + box.h - (height - safe.bottom), 0, box.h)),
                left: up(clamp(safe.left - box.x, 0, box.w))
            ),
            keyboardHeight: up(clamp(box.y + box.h - keyboardTop, 0, box.h)),
            keyboardMs: max(0, Int(keyboardMs.rounded())),
            textScale: textScale(scale),
            shown: shown
        )
    }

    /// `1`, `1.3`, `1.15`: a scale to the hundredth, written as JavaScript writes the number.
    static func scaleText(_ value: Double) -> String {
        let hundredths = Int((textScale(value) * 100).rounded())
        let whole = hundredths / 100
        let rest = hundredths % 100
        if rest == 0 { return String(whole) }
        return rest % 10 == 0 ? "\(whole).\(rest / 10)" : "\(whole).\(rest < 10 ? "0" : "")\(rest)"
    }

    /// The text `__treebarsEnv` is called with: one key order and one way to write each number, on every host.
    static func json(_ env: InAppEnv) -> String {
        "{\"host\":\"\(env.host)\",\"device\":\"\(env.device)\",\"orientation\":\"\(env.orientation)\",\"theme\":\"\(env.theme)\","
            + "\"safe\":{\"top\":\(env.safe.top),\"right\":\(env.safe.right),\"bottom\":\(env.safe.bottom),\"left\":\(env.safe.left)},"
            + "\"keyboard\":{\"height\":\(env.keyboardHeight),\"ms\":\(env.keyboardMs)},\"textScale\":\(scaleText(env.textScale)),\"shown\":\(env.shown)}"
    }

    /// The `<style id="tb-env">` the page reads its environment from, as the shim rewrites it.
    static func style(_ env: InAppEnv) -> String {
        ":root{color-scheme:normal;--tb-safe-top:\(env.safe.top)px;--tb-safe-right:\(env.safe.right)px;--tb-safe-bottom:\(env.safe.bottom)px;"
            + "--tb-safe-left:\(env.safe.left)px;--tb-keyboard:\(env.keyboardHeight)px;--tb-keyboard-ms:\(env.keyboardMs)ms;--tb-text-scale:\(scaleText(env.textScale))}"
    }

    /// `<html>`'s attributes, with a leading space: the keyboard and shown states present or absent.
    static func attributes(_ env: InAppEnv) -> String {
        " data-tb-host=\"\(env.host)\" data-tb-device=\"\(env.device)\" data-tb-orientation=\"\(env.orientation)\" data-tb-theme=\"\(env.theme)\""
            + (env.keyboardHeight > 0 ? " data-tb-keyboard" : "") + (env.shown ? " data-tb-shown" : "")
    }
}
