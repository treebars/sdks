import Foundation

/*
 The render contract. Kotlin and Swift draw every shape; React Native wraps them.

 What a standard in-app message looks like on a device is decided here, as data, before anything is drawn: the shape,
 the resolved tokens, the words and how many lines they may take, the picture and its description, the buttons and where
 each sends somebody, the form's controls, the carousel, the countdown, and how the message closes. The renderer draws
 the plan and decides nothing the plan already decided — so the Kotlin renderer cannot come out different.

 `inAppRenderPlan` matches Treebars' reference implementation and the Kotlin SDK's line for line, and all three answer
 the shared fixture `Fixtures/in-app-render.json` (`InAppRenderPlanTests`). The fixture's `decisions` record each choice
 where two reasonable renderers could differ, and which one this follows.

 Foundation only, so it compiles in both build paths (`swift build` on macOS and `xcodebuild` for iOS) and its test runs
 without a simulator. It reads the decoded structs, which the store and the React Native bridge already keep whole; a
 field of the wrong type was dropped when it was decoded, as everywhere in this SDK.
 */

/// The numbers every plan shares, which a plan does not repeat. `InAppRenderPlanTests` pins these to the fixture's `layout`.
enum InAppStandardLayout {
    static let modalMaxWidth = 320
    static let modalMargin = 16
    static let bannerMargin = 16
    static let bannerThumbnail = 48
    static let fullscreenTabletContentMaxWidth = 560
    static let cardIcon = 40
    static let titleSize = 16
    static let titleWeight = 700
    static let bodySize = 13
    static let bodyLineHeight = 18
    static let buttonMinHeight = 44
    static let buttonWeight = 600
    static let countdownSize = 22
    static let countdownWeight = 600
    static let dismissTarget = 44
    static let formThanksMs = 2500
    static let formProblemColour = "#B42318FF"
    static let wordSend = "Send"
    static let wordThanks = "Thank you."
    static let wordChoose = "Choose…"

    static var json: [String: Any] {
        [
            "modal": ["max_width": modalMaxWidth, "margin": modalMargin],
            "banner": ["margin": bannerMargin, "thumbnail": bannerThumbnail],
            "fullscreen": ["tablet_content_max_width": fullscreenTabletContentMaxWidth],
            "card": ["icon": cardIcon],
            "title": ["size": titleSize, "weight": titleWeight],
            "body": ["size": bodySize, "line_height": bodyLineHeight],
            "button": ["min_height": buttonMinHeight, "weight": buttonWeight],
            "countdown": ["size": countdownSize, "weight": countdownWeight],
            "dismiss": ["target": dismissTarget],
            "form": ["thanks_ms": formThanksMs, "problem_colour": formProblemColour],
            "words": ["send": wordSend, "thanks": wordThanks, "choose": wordChoose],
        ]
    }
}

/// What the device says about itself as a message is drawn — read then, never cached. `platform` changes nothing (the
/// fixture proves it). Sizes stay at scale 1 and Dynamic Type scales them; `text_size` only says whether the line caps
/// can hold the words at the size the person reads.
struct InAppRenderEnv {
    var appearance: String
    var platform: String
    /// `tablet` for the pad idiom — the same line a markup body's `data-tb-show` draws — else `mobile`.
    var device_class: String
    /// The project's tokens from the last sync, for a message queued before messages carried their own.
    var fallback_tokens: InAppTokens? = nil
    /// `large` in an accessibility content-size category, else `default` — and nil is `default`. At the largest sizes a
    /// capped modal's words would end in "…" and a banner's button beside its words would be squeezed to a letter a
    /// line; a large plan uncaps a modal and a banner and puts a banner's button under its words (the fixture's
    /// `text-scale` decision).
    var text_size: String? = nil
}

/// A synced message or a feed row: both carry the words, the in-app block and the tokens the server resolved.
struct InAppRenderInput {
    var title: String?
    var body: String?
    var image_url: String?
    var deep_link: String?
    var in_app: InAppContent?
    var style: InAppTokens?
    var style_dark: InAppTokens?

    init(_ message: InAppMessage) {
        title = message.content.title
        body = message.content.body
        image_url = message.content.image_url
        deep_link = message.content.deep_link
        in_app = message.content.in_app
        style = message.style
        style_dark = message.style_dark
    }

    init(_ notification: TreebarsNotification) {
        title = notification.content.title
        body = notification.content.body
        image_url = notification.content.image_url
        deep_link = notification.content.deep_link
        in_app = notification.content.in_app
        style = notification.style
        style_dark = notification.style_dark
    }
}

private func nullable<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }

/// Every colour `#RRGGBBAA` in CSS order, the one spelling a renderer converts from.
struct InAppPlanTokens: Equatable {
    let accent: String
    let on_accent: String
    let surface: String
    let on_surface: String
    let on_surface_muted: String
    let backdrop: String
    let radius: Double
    let button_radius: Double
    let font_family: String?

    var json: [String: Any] {
        [
            "accent": accent, "on_accent": on_accent, "surface": surface, "on_surface": on_surface,
            "on_surface_muted": on_surface_muted, "backdrop": backdrop, "radius": radius, "button_radius": button_radius,
            "font_family": nullable(font_family),
        ]
    }
}

struct InAppPlanImage: Equatable {
    let url: String
    /// Read aloud as the image's label; nil is a decoration, hidden from VoiceOver.
    let alt: String?
    let placement: String
    let aspect: String

    var json: [String: Any] { ["url": url, "alt": nullable(alt), "placement": placement, "aspect": aspect] }
}

struct InAppPlanText: Equatable {
    let text: String
    /// Truncated past this many lines; nil never truncates (the content scrolls instead).
    let max_lines: Int?

    var json: [String: Any] { ["text": text, "max_lines": nullable(max_lines)] }
}

struct InAppPlanSlide: Equatable {
    let image_url: String
    let image_alt: String?
    let title: String?
    let body: String?

    var json: [String: Any] { ["image_url": image_url, "image_alt": nullable(image_alt), "title": nullable(title), "body": nullable(body)] }
}

struct InAppPlanField: Equatable {
    var id: String
    var kind: String
    var label: String
    var required: Bool
    /// `text`, `chips`, `multi_chips`, `menu` (the platform's picker), `date` (its date picker, answered YYYY-MM-DD) or `scale`.
    var control: String
    /// For `text`: `text`, `email` (no auto-capitalisation), `phone` or `decimal`.
    var keyboard: String? = nil
    var multiline = false
    var placeholder: String? = nil
    var options: [String]? = nil
    var scale: [Int]? = nil
    var glyph: String? = nil

    var json: [String: Any] {
        [
            "id": id, "kind": kind, "label": label, "required": required, "control": control, "keyboard": nullable(keyboard),
            "multiline": multiline, "placeholder": nullable(placeholder), "options": nullable(options), "scale": nullable(scale),
            "glyph": nullable(glyph),
        ]
    }
}

struct InAppPlanForm: Equatable {
    let fields: [InAppPlanField]
    let submit_label: String
    let thanks: String

    var json: [String: Any] { ["fields": fields.map(\.json), "submit_label": submit_label, "thanks": thanks] }
}

struct InAppPlanButton: Equatable {
    /// Its place in the message's own list, from 1: what `in_app_clicked` reports as `button_index`.
    let index: Int
    let label: String
    let action: String
    /// `primary` (filled with accent) for the first drawn, `secondary` (accent words on nothing) for the second.
    let style: String
    let value: String?
    let event_name: String?
    let key: String?
    let data: [String: String]?
    /// Where a press sends somebody, opened by the core after the click is recorded — a link or a page, never a trait's value.
    let destination: String?

    var json: [String: Any] {
        [
            "index": index, "label": label, "action": action, "style": style, "value": nullable(value),
            "event_name": nullable(event_name), "key": nullable(key), "data": nullable(data), "destination": nullable(destination),
        ]
    }
}

struct InAppPlanDismiss: Equatable {
    let control: Bool
    /// Logical: `top_end` is the right of a left-to-right message and the left of a right-to-left one.
    let corner: String
    let backdrop_tap: Bool
    /// VoiceOver's escape (and Android's back): only what interrupts, and only when it may be closed.
    let back: Bool
    let after_ms: Int64?

    var json: [String: Any] {
        ["control": control, "corner": corner, "backdrop_tap": backdrop_tap, "back": back, "after_ms": nullable(after_ms)]
    }
}

struct InAppOverlayPlan: Equatable {
    let shape: String
    let edge: String?
    let appearance: String
    let direction: String
    let tokens: InAppPlanTokens
    let backdrop: Bool
    let content_max_width: Int?
    let animation: String
    let image: InAppPlanImage?
    let title: InAppPlanText?
    let body: InAppPlanText?
    let slides: [InAppPlanSlide]?
    let countdown_to_ms: Int64?
    let form: InAppPlanForm?
    let buttons: [InAppPlanButton]
    /// `content` after the words, `trailing` beside them on a banner (`content` on one at a large text size), `bottom`
    /// pinned above the safe area.
    let buttons_at: String
    let dismiss: InAppPlanDismiss

    var json: [String: Any] {
        [
            "kind": "overlay", "shape": shape, "edge": nullable(edge), "appearance": appearance, "direction": direction,
            "tokens": tokens.json, "backdrop": backdrop, "content_max_width": nullable(content_max_width), "animation": animation,
            "image": nullable(image?.json), "title": nullable(title?.json), "body": nullable(body?.json),
            "slides": nullable(slides.map { items in ["items": items.map(\.json), "controls": items.count > 1] as [String: Any] }),
            "countdown": nullable(countdown_to_ms.map { ["to_ms": $0] as [String: Any] }),
            "form": nullable(form?.json), "buttons": buttons.map(\.json), "buttons_at": buttons_at, "dismiss": dismiss.json,
        ]
    }
}

struct InAppCardPlan: Equatable {
    let template: String
    let appearance: String
    let direction: String
    let tokens: InAppPlanTokens
    let image: InAppPlanImage?
    let title: InAppPlanText?
    let body: InAppPlanText?
    /// Where a tap on the card goes: its own action, else the row's deep link.
    let destination: String?
    let cta_label: String?
    let cta_destination: String?
    let pinned: Bool
    let category: String?

    var json: [String: Any] {
        let cta: Any = (cta_label != nil && cta_destination != nil) ? ["label": cta_label!, "destination": cta_destination!] as [String: Any] : NSNull()
        return [
            "kind": "card", "template": template, "appearance": appearance, "direction": direction, "tokens": tokens.json,
            "image": nullable(image?.json), "title": nullable(title?.json), "body": nullable(body?.json),
            "destination": nullable(destination), "cta": cta, "pinned": pinned, "category": nullable(category),
        ]
    }
}

/// What to draw. `markup` is an HTML body, which the SDK's WebView host draws and a renderer never sees; `none` is a row
/// with no in-app content — a push in the feed, which whatever draws the feed decides for itself.
enum InAppRenderPlan: Equatable {
    case overlay(InAppOverlayPlan)
    case card(InAppCardPlan)
    case markup
    case none

    var json: [String: Any] {
        switch self {
        case .overlay(let plan): return plan.json
        case .card(let plan): return plan.json
        case .markup: return ["kind": "markup"]
        case .none: return ["kind": "none"]
        }
    }
}

/// A string with something in it, or nil: a title of `""` is no title.
private func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

/*
 Whole-string matching. `NSRegularExpression`'s `$` also matches before a final newline, so a match counts only when
 it covers the input — as `NUMBER_GRAMMAR`'s reader in `InApp.swift` does. `[0-9]` rather than `\d` throughout: ICU's
 `\d` takes Arabic-Indic digits, where JavaScript's and Java's do not.
 */
private func wholeMatch(_ regex: NSRegularExpression, _ text: String) -> NSTextCheckingResult? {
    let whole = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: whole), match.range == whole else { return nil }
    return match
}

private func group(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
    let range = match.range(at: index)
    guard range.location != NSNotFound, let bounds = Range(range, in: text) else { return nil }
    return String(text[bounds])
}

private let hexColour = try! NSRegularExpression(pattern: "^#([0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$")
private let rgbColour = try! NSRegularExpression(
    pattern: #"^rgba?\(\s*([0-9]{1,3})\s*,\s*([0-9]{1,3})\s*,\s*([0-9]{1,3})\s*(?:,\s*([0-9]*\.?[0-9]+)\s*)?\)$"#,
    options: [.caseInsensitive]
)

private func hex2(_ value: Int) -> String { String(format: "%02X", value) }

/// `#RRGGBBAA`, upper case, or nil for a colour outside the grammar every core shares.
func inAppPlanColour(_ value: String?) -> String? {
    guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
    if let match = wholeMatch(hexColour, text), let raw = group(match, 1, in: text) {
        let digits = raw.count <= 4 ? raw.map { "\($0)\($0)" }.joined() : raw
        return "#\(digits.uppercased())\(digits.count == 6 ? "FF" : "")"
    }
    guard let match = wholeMatch(rgbColour, text) else { return nil }
    let channel = { (index: Int) in hex2(min(255, Int(group(match, index, in: text) ?? "0") ?? 0)) }
    let alpha = group(match, 4, in: text).flatMap(Double.init).map { min(1, max(0, $0)) } ?? 1
    return "#\(channel(1))\(channel(2))\(channel(3))\(hex2(Int((alpha * 255).rounded())))"
}

/// The default preset (`minimal`), which the server resolves an unstyled message to.
private let presetColours: [String: String] = [
    "accent": "#5B4DF5", "on_accent": "#FFFFFF", "surface": "#FFFFFF", "on_surface": "#111827",
    "on_surface_muted": "#6B7280", "backdrop": "#0F172A99",
]
private let presetRadius = 8.0

/// Its own dark set while the device is dark and it has one; else its own; else the project's from the sync;
/// else the default preset. Each colour outside the grammar is the preset's, so a renderer never guesses at a string.
private func planTokens(_ input: InAppRenderInput, env: InAppRenderEnv) -> (InAppPlanTokens, String) {
    let dark = env.appearance == "dark" ? input.style_dark : nil
    let chosen = dark ?? input.style ?? env.fallback_tokens
    let colour = { (value: String?, key: String) in inAppPlanColour(value) ?? inAppPlanColour(presetColours[key])! }
    let radius = chosen.map(\.radius).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? presetRadius
    // `rounded` is the card's own radius on buttons too, as the dashboard's preview draws it; the web draws 8 whatever it is.
    let buttonRadius: Double = chosen?.button_shape == "pill" ? 999 : chosen?.button_shape == "square" ? 0 : radius
    let font = chosen?.font_family.trimmingCharacters(in: .whitespacesAndNewlines)
    return (
        InAppPlanTokens(
            accent: colour(chosen?.accent, "accent"),
            on_accent: colour(chosen?.on_accent, "on_accent"),
            surface: colour(chosen?.surface, "surface"),
            on_surface: colour(chosen?.on_surface, "on_surface"),
            on_surface_muted: colour(chosen?.on_surface_muted, "on_surface_muted"),
            backdrop: colour(chosen?.backdrop, "backdrop"),
            radius: radius,
            button_radius: buttonRadius,
            font_family: nonEmpty(font)
        ),
        dark != nil ? "dark" : "light"
    )
}

/*
 An instant, one way in every SDK: the one instant grammar they share, converted by arithmetic. `ISO8601DateFormatter` takes
 shapes Android's `SimpleDateFormat` refuses, and JavaScript's `Date.parse` takes more than either.
 */
private let instantPattern = try! NSRegularExpression(
    pattern: #"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2})(?::([0-9]{2})(?:\.([0-9]{1,6}))?)?(Z|([+-])([0-9]{2}):([0-9]{2}))$"#
)

private func floorDiv(_ a: Int64, _ b: Int64) -> Int64 { a >= 0 ? a / b : -((-a + b - 1) / b) }

/// Days from 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's `days_from_civil`).
private func daysFromCivil(_ year: Int64, _ month: Int64, _ day: Int64) -> Int64 {
    let y = month <= 2 ? year - 1 : year
    let era = floorDiv(y, 400)
    let yoe = y - era * 400
    let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146_097 + doe - 719_468
}

private func daysInMonth(_ year: Int, _ month: Int) -> Int {
    switch month {
    case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
    case 4, 6, 9, 11: return 30
    default: return 31
    }
}

/// Epoch milliseconds, or nil for anything that is not a real instant in that one grammar.
func inAppPlanInstant(_ value: String?) -> Int64? {
    guard let value, let match = wholeMatch(instantPattern, value) else { return nil }
    let number = { (index: Int) in group(match, index, in: value).flatMap { Int($0) } }
    guard let year = number(1), let month = number(2), let day = number(3), let hour = number(4), let minute = number(5) else { return nil }
    let second = number(6) ?? 0
    let millis = group(match, 7, in: value).map { fraction in Int(String((fraction + "000").prefix(3))) ?? 0 } ?? 0
    guard (1...12).contains(month), day >= 1, day <= daysInMonth(year, month), hour <= 23, minute <= 59, second <= 59 else { return nil }
    var offset: Int64 = 0
    if group(match, 8, in: value) != "Z" {
        guard let hours = number(10), let minutes = number(11), hours <= 23, minutes <= 59 else { return nil }
        offset = (group(match, 9, in: value) == "-" ? -1 : 1) * Int64(hours * 60 + minutes) * 60_000
    }
    return daysFromCivil(Int64(year), Int64(month), Int64(day)) * 86_400_000 + Int64(hour) * 3_600_000 + Int64(minute) * 60_000
        + Int64(second) * 1000 + Int64(millis) - offset
}

/// `2d 04:13:09` until the moment, `04:13:09` inside the last day, and `""` once it has passed — the web SDK's words too.
func inAppCountdownText(toMs: Int64, nowMs: Int64) -> String {
    let left = max(0, toMs - nowMs)
    guard left > 0 else { return "" }
    let seconds = left / 1000
    let days = seconds / 86_400
    let pad = { (value: Int64) -> String in value < 10 ? "0\(value)" : "\(value)" }
    let clock = "\(pad((seconds % 86_400) / 3600)):\(pad((seconds % 3600) / 60)):\(pad(seconds % 60))"
    return days > 0 ? "\(days)d \(clock)" : clock
}

private let keyboards = ["email": "email", "phone": "phone", "number": "decimal"]

/// One form field as a renderer draws it. A kind this build does not know is a text box, as both references draw one.
func inAppPlanField(_ field: InAppFormField) -> InAppPlanField {
    var plan = InAppPlanField(id: field.id, kind: field.kind, label: field.label, required: field.required == true, control: "text")
    let options = field.options ?? []
    switch field.kind {
    case "choice":
        plan.control = "chips"
        plan.options = options
    case "multi_choice":
        plan.control = "multi_chips"
        plan.options = options
    case "dropdown":
        plan.control = "menu"
        plan.options = options
        plan.placeholder = nonEmpty(field.placeholder) ?? InAppStandardLayout.wordChoose
    case "date":
        plan.control = "date"
    case "rating":
        plan.control = "scale"
        plan.scale = Array(1...5)
        plan.glyph = "star"
    case "nps":
        plan.control = "scale"
        plan.scale = Array(0...10)
        plan.glyph = "number"
    default:
        plan.keyboard = keyboards[field.kind] ?? "text"
        plan.multiline = field.kind == "textarea"
        plan.placeholder = nonEmpty(field.placeholder)
    }
    return plan
}

/// Every action a typed button has. A button with another is not drawn.
private let buttonActions: Set<String> = ["dismiss", "deep_link", "url", "track_event", "set_attribute", "custom", "call", "copy", "share", "store_review"]

/// A link or a page goes somewhere; a trait's value and the push opt-in link do not.
private func destination(_ action: String, _ value: String?) -> String? {
    guard action == "url" || action == "deep_link", let value, value != TreebarsConstants.pushPermissionLink else { return nil }
    return value
}

private func planButtons(_ buttons: [InAppButton]?, max: Int) -> [InAppPlanButton] {
    var drawn: [InAppPlanButton] = []
    for (position, button) in (buttons ?? []).enumerated() where buttonActions.contains(button.action) && drawn.count < max {
        let value = nonEmpty(button.value)
        drawn.append(InAppPlanButton(
            index: button.index ?? position + 1,
            label: button.label,
            action: button.action,
            style: drawn.isEmpty ? "primary" : "secondary",
            value: value,
            event_name: nonEmpty(button.event_name),
            key: nonEmpty(button.key),
            data: (button.data?.isEmpty ?? true) ? nil : button.data,
            destination: destination(button.action, value)
        ))
    }
    return drawn
}

/// Where it sits, as `inAppShape` answers — but a typed nudge from an older server is the bar it most resembles.
private func planShape(_ layout: String) -> String {
    switch layout {
    case "banner", "nudge": return "banner"
    case "fullscreen", "html": return "fullscreen"
    default: return "modal"
    }
}

/// Turns a synced message or a feed row into what to draw. Pure: the same input and environment, the same plan, on every core.
func inAppRenderPlan(_ input: InAppRenderInput, env: InAppRenderEnv) -> InAppRenderPlan {
    guard let inApp = input.in_app else { return .none }
    let bodyMode = inApp.body_mode == "html" || inApp.body_mode == "standard" ? inApp.body_mode! : (inApp.layout == "html" ? "html" : "standard")
    if bodyMode == "html" { return .markup }

    let (tokens, appearance) = planTokens(input, env: env)
    let direction = inApp.direction == "rtl" ? "rtl" : "ltr"
    let title = nonEmpty(input.title)
    let body = nonEmpty(input.body)
    let imageUrl = nonEmpty(input.image_url)

    if inApp.surface == "inbox" {
        let card = inApp.card
        let illustration = card?.template == "illustration"
        // An icon beside the words; the message's own picture above them on an illustration; a row with no card keeps its picture as the icon.
        let source = illustration ? imageUrl : (card != nil ? nonEmpty(card?.icon_url) : imageUrl)
        let ctaLabel = nonEmpty(card?.cta?.label)
        let ctaDestination = nonEmpty(card?.cta?.action.value)
        return .card(InAppCardPlan(
            template: illustration ? "illustration" : "basic",
            appearance: appearance,
            direction: direction,
            tokens: tokens,
            image: source.map { InAppPlanImage(url: $0, alt: nonEmpty(card?.image_alt), placement: illustration ? "top" : "leading", aspect: illustration ? "2:1" : "1:1") },
            title: title.map { InAppPlanText(text: $0, max_lines: 1) },
            body: body.map { InAppPlanText(text: $0, max_lines: 2) },
            destination: nonEmpty(card?.action?.value) ?? nonEmpty(input.deep_link),
            cta_label: ctaDestination == nil ? nil : ctaLabel,
            cta_destination: ctaLabel == nil ? nil : ctaDestination,
            pinned: card?.pinned == true,
            category: nonEmpty(card?.category)
        ))
    }

    let shape = planShape(inApp.layout)
    let edge: String? = shape == "banner" ? (inApp.position == "top" ? "top" : "bottom") : nil
    let dismissible = inApp.dismissible != false
    // At an accessibility text size a cut message has lost its words, and the renderers scroll one taller than its room,
    // so the caps come off; a fullscreen is never capped, and a card keeps its lines (the fixture's `text-scale` decision).
    let large = env.text_size == "large"
    let lines: (Int?, Int?) = large ? (nil, nil) : shape == "modal" ? (2, 4) : shape == "banner" ? (1, 2) : (nil, nil)
    let fields = (inApp.form?.fields ?? []).map(inAppPlanField)
    let slides = (inApp.slides ?? []).compactMap { slide in
        nonEmpty(slide.image_url).map { InAppPlanSlide(image_url: $0, image_alt: nonEmpty(slide.image_alt), title: nonEmpty(slide.title), body: nonEmpty(slide.body)) }
    }
    let auto = inApp.display?.auto_dismiss_seconds
    return .overlay(InAppOverlayPlan(
        shape: shape,
        edge: edge,
        appearance: appearance,
        direction: direction,
        tokens: tokens,
        backdrop: shape == "modal",
        content_max_width: shape == "fullscreen" && env.device_class == "tablet" ? InAppStandardLayout.fullscreenTabletContentMaxWidth : nil,
        animation: edge == "top" ? "slide_top" : edge == "bottom" ? "slide_bottom" : "fade",
        image: imageUrl.map {
            InAppPlanImage(
                url: $0,
                alt: nonEmpty(inApp.image_alt),
                placement: shape == "banner" ? "leading" : "top",
                aspect: shape == "banner" ? "1:1" : shape == "fullscreen" ? "16:9" : "2:1"
            )
        },
        title: title.map { InAppPlanText(text: $0, max_lines: lines.0) },
        body: body.map { InAppPlanText(text: $0, max_lines: lines.1) },
        slides: slides.isEmpty ? nil : slides,
        countdown_to_ms: inAppPlanInstant(inApp.countdown_to),
        form: fields.isEmpty ? nil : InAppPlanForm(
            fields: fields,
            submit_label: nonEmpty(inApp.form?.submit_label) ?? InAppStandardLayout.wordSend,
            thanks: nonEmpty(inApp.form?.thanks) ?? InAppStandardLayout.wordThanks
        ),
        buttons: planButtons(inApp.buttons, max: shape == "banner" ? 1 : 2),
        // Beside the words, a button at the largest size takes the room the words need: under them instead.
        buttons_at: shape == "banner" ? (large ? "content" : "trailing") : shape == "fullscreen" ? "bottom" : "content",
        dismiss: InAppPlanDismiss(
            control: dismissible,
            corner: shape == "fullscreen" ? "top_start" : "top_end",
            backdrop_tap: dismissible && shape == "modal",
            back: dismissible && shape != "banner",
            after_ms: auto.flatMap { $0 > 0 ? Int64($0) * 1000 : nil }
        )
    ))
}

/* The form's two rules — required, and the field's own format — applied before `submitInAppForm`. */

/// Any character but `@` and the ASCII controls and space: `[^\s@]`, spelled so ICU, Java and JavaScript read it alike.
private let emailPattern = try! NSRegularExpression(pattern: #"^[^@\x00-\x20]+@[^@\x00-\x20]+\.[^@\x00-\x20]+$"#)
private let numberPattern = try! NSRegularExpression(pattern: TreebarsConstants.numberGrammar)
private let dayPattern = try! NSRegularExpression(pattern: "^([0-9]{4})-([0-9]{2})-([0-9]{2})$")

/// A calendar day as `YYYY-MM-DD`, and one that exists: `2026-02-30` is not a day.
func inAppIsDay(_ value: String) -> Bool {
    guard let match = wholeMatch(dayPattern, value),
          let year = group(match, 1, in: value).flatMap({ Int($0) }),
          let month = group(match, 2, in: value).flatMap({ Int($0) }),
          let day = group(match, 3, in: value).flatMap({ Int($0) }) else { return false }
    return (1...12).contains(month) && day >= 1 && day <= daysInMonth(year, month)
}

private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

/// A picked number, told apart from a flag: `JSONSerialization` hands both back as `NSNumber`.
private func pickedNumber(_ answer: Any?) -> NSNumber? {
    guard let number = answer as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    return number
}

private func isEmptyAnswer(_ answer: Any?) -> Bool {
    guard let answer else { return true }
    if let text = answer as? String { return trimmed(text).isEmpty }
    if let picks = answer as? [String] { return picks.isEmpty }
    return false
}

/// Why the form cannot be sent yet — the first problem, top to bottom — or nil when it can. An answer is typed text, a
/// picked number, or a multiple choice's picks as a list.
func inAppFormProblem(_ fields: [InAppPlanField], answers: [String: Any]) -> String? {
    for field in fields {
        let answer = answers[field.id]
        if isEmptyAnswer(answer) {
            if field.required { return "\(field.label) is required." }
            continue
        }
        let typed: String
        if let picks = answer as? [String] { typed = picks.joined(separator: ",") }
        else if let text = answer as? String { typed = trimmed(text) }
        else { typed = pickedNumber(answer)?.stringValue ?? "" }
        if field.kind == "email", wholeMatch(emailPattern, typed) == nil { return "\(field.label) is not an email address." }
        if field.kind == "phone", typed.unicodeScalars.filter({ ("0"..."9").contains($0) }).count < 7 { return "\(field.label) is not a phone number." }
        if field.kind == "number", pickedNumber(answer) == nil, wholeMatch(numberPattern, typed) == nil { return "\(field.label) needs a number." }
        if field.kind == "date", !inAppIsDay(typed) { return "\(field.label) needs a date, as YYYY-MM-DD." }
    }
    return nil
}

/// The answers as `submitInAppForm` sends them: a number as a number, text trimmed, several choices as one answer in the
/// author's order whatever order they were tapped in, and nothing for a field left empty.
func inAppFormAnswers(_ fields: [InAppPlanField], answers: [String: Any]) -> [String: Any] {
    var out: [String: Any] = [:]
    for field in fields {
        guard let answer = answers[field.id] else { continue }
        if let number = pickedNumber(answer) {
            out[field.id] = number
        } else if let picks = answer as? [String] {
            let picked = Set(picks)
            let joined = (field.options ?? []).filter { picked.contains($0) }.joined(separator: ",")
            if !joined.isEmpty { out[field.id] = joined }
        } else if let text = answer as? String {
            let value = trimmed(text)
            if value.isEmpty { continue }
            if field.kind == "number", wholeMatch(numberPattern, value) != nil, let number = Double(value) { out[field.id] = number }
            else { out[field.id] = value }
        }
    }
    return out
}
