import Foundation
#if canImport(UIKit)
import CoreText
import UIKit
#endif

/*
 The SDK's own drawing of a standard in-app message. Kotlin and Swift draw every shape; React Native wraps them.

 A standard body with no app renderer registered is drawn here: the core chooses which message and when, and this draws
 the plan `inAppRenderPlan` makes (`InAppRenderPlan.swift`), deciding nothing the plan already decided, so the Kotlin
 renderer cannot come out different. `setInAppRenderer` is the override: an app that registers one is handed every
 standard message, and nothing here runs. A markup body is the WebView host's (`InAppHtml.swift`); a card is the
 inbox's, and this draws none.

 Three pieces:
 - `inAppDrawer`: who draws a message. Pure, and the one answer every branch in `Treebars` asks — the immediate path, the
   replay, a delayed message — so the hook is proved by `swift test` on a Mac.
 - `InAppNativeController`: the plan as UIKit views, reporting what the person did and nothing else, so a test builds and
   inspects it without a window.
 - `InAppNativeHost`: a window of its own, the entrance, the key window and the auto-dismiss timer.
 */

/// Who draws an overlay message on this device.
enum InAppDrawer: Equatable {
    /// A markup body: the core's WebView host, whatever the app registered.
    case markup
    /// The app's renderer (`setInAppRenderer`), which overrides the core's: nothing of the core's is drawn.
    case app
    /// The core itself, from the plan: a standard body, and no renderer registered.
    case native
    /// Nothing here draws it — an inbox row, or a build without UIKit — so the trigger is held for a renderer.
    case none
}

/**
 The hook. `coreDraws` is whether this build has UIKit to draw with (`Treebars.coreDraws`), taken as a parameter so the
 choice can be tested where it has none. A self-handled message is decided before this is asked, and unchanged by it.
 */
func inAppDrawer(_ content: InAppContent, hasRenderer: Bool, coreDraws: Bool) -> InAppDrawer {
    guard content.surface == "overlay" else { return .none }
    // A legacy `layout: "html"` with no body mode is a fullscreen markup body.
    let markup = content.body_mode == "html" || (content.body_mode == nil && content.layout == "html")
    if markup, coreDraws { return .markup }
    if hasRenderer { return .app }
    // Never a markup body: the plan says `markup` for one and this renderer draws only overlays.
    return coreDraws && !markup ? .native : .none
}

/// A plan colour's channels from 0 to 1. A plan holds one spelling, `#RRGGBBAA` with the alpha LAST — read any
/// other way, a translucent dim would come out a different colour — so anything else is nil.
func inAppPlanRGBA(_ hex: String) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
    let digits = hex.dropFirst()
    guard hex.first == "#", digits.count == 8, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
    let channel = { (shift: UInt32) in Double((value >> shift) & 0xFF) / 255 }
    return (channel(24), channel(16), channel(8), channel(0))
}

/// A picked day as `YYYY-MM-DD` in the Gregorian calendar — what `inAppFormProblem` and the server read — whatever
/// calendar the person's picker shows it in. Arithmetic, not a `DateFormatter`, whose locale would decide the digits.
func inAppDayText(_ date: Date, in zone: TimeZone) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let day = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
}

#if canImport(UIKit)

/**
 The plan's `text_size` for the size the person reads at: `large` in the accessibility content-size categories, the
 sizes past the ordinary slider, where a capped modal's words would be cut to "…" and a banner's button squeezed to a
 letter a line (the render fixture's `text-scale` decision). The plan uncaps the words and moves the button; the sizes
 are still Dynamic Type's.
 */
func inAppTextSize(_ category: UIContentSizeCategory) -> String {
    category.isAccessibilityCategory ? "large" : "default"
}

/// A plan colour as UIKit draws it; a plan never holds anything else, so the fallback is never seen.
func inAppUIColour(_ hex: String) -> UIColor {
    guard let rgba = inAppPlanRGBA(hex) else { return .clear }
    return UIColor(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
}

/// What the person did, as a display reports it to its host. Nothing is recorded here: the core does that.
struct InAppNativeActions {
    /// A button other than `dismiss`: the core records the click, the message closes, then the core opens its destination.
    var pressed: (InAppPlanButton) -> Void = { _ in }
    /// The ✕, the dim, VoiceOver's escape, the timer or a `dismiss` button, while the form (if any) is unsent.
    var dismissed: () -> Void = {}
    /// The form's answers, checked by `inAppFormProblem` and shaped by `inAppFormAnswers`.
    var submitted: ([String: Any]) -> Void = { _ in }
    /// Closed after the form was sent — its thanks read, or put away — with nothing more recorded: the answers are the
    /// record.
    var answered: () -> Void = {}
    /// A field began editing: a banner's window has to become key for the keyboard to come up.
    var editing: () -> Void = {}
}

/// Loads a picture and answers on the main thread; a test hands one that answers at once and never reaches a network.
typealias InAppImageLoader = (URL, @escaping (UIImage?) -> Void) -> Void

/// Runs something on the main thread after a while; a test keeps the work and runs it when it chooses.
typealias InAppLater = (TimeInterval, @escaping () -> Void) -> Void

enum InAppNativeDefaults {
    /// A store file the sync's prefetch kept is read from disk, so the picture is there offline;
    /// anything else is fetched as it is drawn, with nothing cached beyond what `URLSession.shared` caches.
    static let loadImage: InAppImageLoader = { url, done in
        DispatchQueue.global(qos: .userInitiated).async {
            if let held = InAppAssetCache.shared?.pictureBytes(url.absoluteString), let image = UIImage(data: held) {
                DispatchQueue.main.async { done(image) }
                return
            }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                let image = data.flatMap(UIImage.init(data:))
                DispatchQueue.main.async { done(image) }
            }.resume()
        }
    }

    static let later: InAppLater = { seconds, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: DispatchWorkItem(block: work))
    }

    static func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }
}

/// A CSS weight from the layout numbers, as UIKit names it.
private func uiWeight(_ css: Int) -> UIFont.Weight {
    switch css {
    case 700...: return .bold
    case 600..<700: return .semibold
    case 500..<600: return .medium
    default: return .regular
    }
}

/// One kind of words: a size and weight at scale 1, and the text style whose curve Dynamic Type scales it along.
struct InAppTextStyle {
    let size: CGFloat
    let weight: UIFont.Weight
    var lineHeight: CGFloat? = nil
    let textStyle: UIFont.TextStyle
    var monospacedDigits = false

    // Each takes the text style whose default size is nearest its own, so it grows at the rate the system's own words do.
    static let title = InAppTextStyle(size: CGFloat(InAppStandardLayout.titleSize), weight: uiWeight(InAppStandardLayout.titleWeight), textStyle: .callout)
    static let body = InAppTextStyle(
        size: CGFloat(InAppStandardLayout.bodySize), weight: .regular, lineHeight: CGFloat(InAppStandardLayout.bodyLineHeight), textStyle: .footnote
    )
    /// A button's words: the plan fixes their weight and not their size, so 14, React Native's default.
    static let button = InAppTextStyle(size: 14, weight: uiWeight(InAppStandardLayout.buttonWeight), textStyle: .subheadline)
    static let field = InAppTextStyle(size: 14, weight: .regular, textStyle: .subheadline)
    static let countdown = InAppTextStyle(
        size: CGFloat(InAppStandardLayout.countdownSize), weight: uiWeight(InAppStandardLayout.countdownWeight), textStyle: .title2,
        monospacedDigits: true
    )
}

/// The message's font family, when the app has linked it.
struct InAppFonts {
    /**
     A family the app has not linked is the system font, as React Native's renderer falls back (`RCTFontUtils`): a
     `UIFontDescriptor` naming a family nobody bundled answers with some other face rather than none, and which one is
     not ours to guess.
     */
    let family: String?

    @MainActor
    init(_ family: String?) {
        self.family = family.flatMap { UIFont.fontNames(forFamilyName: $0).isEmpty ? nil : $0 }
    }

    /// Scaled by Dynamic Type from the size at scale 1 — the plan's sizes are all at scale 1 and the OS scales them.
    @MainActor
    func font(_ style: InAppTextStyle, compatibleWith traits: UITraitCollection?) -> UIFont {
        let base: UIFont
        if let family {
            var descriptor = UIFontDescriptor(fontAttributes: [
                .family: family,
                .traits: [UIFontDescriptor.TraitKey.weight: style.weight.rawValue],
            ])
            if style.monospacedDigits {
                descriptor = descriptor.addingAttributes([.featureSettings: [[
                    UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                    UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
                ]]])
            }
            base = UIFont(descriptor: descriptor, size: style.size)
        } else if style.monospacedDigits {
            base = .monospacedDigitSystemFont(ofSize: style.size, weight: style.weight)
        } else {
            base = .systemFont(ofSize: style.size, weight: style.weight)
        }
        return UIFontMetrics(forTextStyle: style.textStyle).scaledFont(for: base, compatibleWith: traits)
    }
}

/// The plan's tokens as colours, and the few measures every part shares.
@MainActor
struct InAppKit {
    let fonts: InAppFonts
    let accent: UIColor
    let onAccent: UIColor
    let surface: UIColor
    let onSurface: UIColor
    let muted: UIColor
    let backdrop: UIColor
    let problem: UIColor
    let buttonRadius: CGFloat
    let rtl: Bool

    init(_ plan: InAppOverlayPlan) {
        fonts = InAppFonts(plan.tokens.font_family)
        accent = inAppUIColour(plan.tokens.accent)
        onAccent = inAppUIColour(plan.tokens.on_accent)
        surface = inAppUIColour(plan.tokens.surface)
        onSurface = inAppUIColour(plan.tokens.on_surface)
        muted = inAppUIColour(plan.tokens.on_surface_muted)
        backdrop = inAppUIColour(plan.tokens.backdrop)
        problem = inAppUIColour(InAppStandardLayout.formProblemColour)
        buttonRadius = CGFloat(plan.tokens.button_radius)
        rtl = plan.direction == "rtl"
    }

    /// Words run from the side the message's language starts on, whatever the app's own language is.
    var align: NSTextAlignment { rtl ? .right : .left }

    func text(_ words: String, _ style: InAppTextStyle, _ colour: UIColor, lines: Int? = nil, align: NSTextAlignment? = nil) -> InAppTextLabel {
        InAppTextLabel(words, style: style, fonts: fonts, colour: colour, align: align ?? self.align, lines: lines)
    }

    /// A message's button: `primary` filled with the accent, `secondary` accent words on nothing.
    func button(_ title: String, primary: Bool) -> InAppNativeButton {
        let fill = primary ? accent : .clear
        let words = primary ? onAccent : accent
        return InAppNativeButton(
            title: title, kit: self, radius: buttonRadius, minHeight: CGFloat(InAppStandardLayout.buttonMinHeight),
            insets: NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16),
            look: { _ in (fill: fill, text: words, border: nil) }
        )
    }

    /// A choice: accent-outlined, filled when picked. Drawn 32 high with its touch area grown to 44.
    func chip(_ title: String) -> InAppNativeButton {
        let accent = accent
        let onAccent = onAccent
        let chip = InAppNativeButton(
            title: title, kit: self, radius: 999, minHeight: 32,
            insets: NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12),
            look: { on in (fill: on ? accent : .clear, text: on ? onAccent : accent, border: Optional(accent)) }
        )
        chip.outset = 6
        return chip
    }
}

/// Words in one of the message's styles, drawn again when the text size changes — an attributed string's font and line
/// height do not follow Dynamic Type by themselves, and a body's 18-point line is only right if it grows with the letters.
final class InAppTextLabel: UILabel {
    private let style: InAppTextStyle
    private let fonts: InAppFonts
    private let align: NSTextAlignment
    var colour: UIColor { didSet { render() } }
    var content: String { didSet { render() } }

    init(_ content: String, style: InAppTextStyle, fonts: InAppFonts, colour: UIColor, align: NSTextAlignment, lines: Int?) {
        self.content = content
        self.style = style
        self.fonts = fonts
        self.colour = colour
        self.align = align
        super.init(frame: .zero)
        // Cut at the plan's lines with an ellipsis; none means never cut, and the message scrolls instead.
        numberOfLines = lines ?? 0
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func render() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = align
        if let height = style.lineHeight {
            let scaled = UIFontMetrics(forTextStyle: style.textStyle).scaledValue(for: height, compatibleWith: traitCollection)
            paragraph.minimumLineHeight = scaled
            paragraph.maximumLineHeight = scaled
        }
        attributedText = NSAttributedString(string: content, attributes: [
            .font: fonts.font(style, compatibleWith: traitCollection), .foregroundColor: colour, .paragraphStyle: paragraph,
        ])
        // After the text, and not in the paragraph style: a truncating break mode there cuts a multi-line label to one line.
        lineBreakMode = .byTruncatingTail
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory { render() }
    }
}

/// A button, a chip or a menu's box: words in a shape, at least `minHeight` high, its corners clamped to a capsule.
final class InAppNativeButton: UIControl {
    let label: InAppTextLabel
    private let radius: CGFloat
    private let look: (Bool) -> (fill: UIColor, text: UIColor, border: UIColor?)
    /// Points the touch area reaches past the drawing, so a 32-point chip is still a 44-point target.
    var outset: CGFloat = 0

    init(
        title: String, kit: InAppKit, radius: CGFloat, minHeight: CGFloat, insets: NSDirectionalEdgeInsets,
        look: @escaping (Bool) -> (fill: UIColor, text: UIColor, border: UIColor?)
    ) {
        self.radius = radius
        self.look = look
        label = kit.text(title, .button, look(false).text, align: .center)
        super.init(frame: .zero)
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.leading),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.trailing),
            heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight),
        ])
        isAccessibilityElement = true
        accessibilityLabel = title
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isSelected: Bool { didSet { paint() } }
    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.6 : 1 } }

    private func paint() {
        let now = look(isSelected)
        backgroundColor = now.fill
        label.colour = now.text
        layer.borderWidth = now.border == nil ? 0 : 1
        layer.borderColor = now.border?.cgColor
        accessibilityTraits = isSelected ? [.button, .selected] : .button
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // `pill` is 999 in the plan, and a layer does not clamp its own radius: past half the height it draws a lozenge.
        layer.cornerRadius = min(radius, bounds.height / 2)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -outset, dy: -outset).contains(point)
    }
}

/// A 44-point target holding one symbol: the ✕, a carousel's arrows, a star.
final class InAppIconButton: UIControl {
    private let image = UIImageView()
    private let size: CGFloat

    var symbol: String { didSet { image.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)) } }

    init(symbol: String, tint: UIColor, label: String, size: CGFloat = 15, backdrop: UIColor? = nil) {
        self.symbol = symbol
        self.size = size
        super.init(frame: .zero)
        let target = CGFloat(InAppStandardLayout.dismissTarget)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: target), heightAnchor.constraint(equalToConstant: target)])
        if let backdrop {
            // Behind the ✕ so it reads over a picture as well as over the surface.
            let disc = UIView()
            disc.backgroundColor = backdrop
            disc.layer.cornerRadius = 14
            disc.isUserInteractionEnabled = false
            disc.translatesAutoresizingMaskIntoConstraints = false
            addSubview(disc)
            NSLayoutConstraint.activate([
                disc.widthAnchor.constraint(equalToConstant: 28), disc.heightAnchor.constraint(equalToConstant: 28),
                disc.centerXAnchor.constraint(equalTo: centerXAnchor), disc.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        image.tintColor = tint
        image.contentMode = .center
        image.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold))
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        NSLayoutConstraint.activate([image.centerXAnchor.constraint(equalTo: centerXAnchor), image.centerYAnchor.constraint(equalTo: centerYAnchor)])
        isAccessibilityElement = true
        accessibilityLabel = label
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.5 : 1 } }
}

/// Chips in rows that wrap, from the side the message starts on. A stack view cannot wrap, and a form's eleven NPS
/// numbers or five long options do not fit one row on a phone.
final class InAppFlowView: UIView {
    private let spacing: CGFloat = 6
    private var measured: CGFloat = 0

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: measured) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let width = bounds.width
        var x: CGFloat = 0
        var y: CGFloat = 0
        var row: CGFloat = 0
        for view in subviews {
            let fitted = view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            let wide = min(fitted.width, width)
            if x > 0, x + wide > width {
                x = 0
                y += row + spacing
                row = 0
            }
            view.frame = CGRect(x: rtl ? width - x - wide : x, y: y, width: wide, height: fitted.height)
            x += wide + spacing
            row = max(row, fitted.height)
        }
        let height = subviews.isEmpty ? 0 : y + row
        // Its height depends on its width, which it only learns here: ask for another pass when the rows changed.
        if height != measured {
            measured = height
            invalidateIntrinsicContentSize()
        }
    }
}

/// The root of the message's window: VoiceOver's escape (the two-finger scrub) closes it only when the plan says `back`.
final class InAppNativeRootView: UIView {
    var escape: () -> Bool = { false }

    override func accessibilityPerformEscape() -> Bool { escape() }
}

// MARK: - The carousel

/// One card at a time — its picture 2:1, its title and body — with previous and next and "n / N" between them, wrapping
/// round and never moving by itself.
final class InAppCarouselView: UIStackView {
    private let slides: [InAppPlanSlide]
    private let kit: InAppKit
    private let loadImage: InAppImageLoader
    let picture = UIImageView()
    private let title: InAppTextLabel
    private let words: InAppTextLabel
    private(set) var counter: InAppTextLabel?
    private(set) var index = 0
    private var loading: URL?

    init(_ slides: [InAppPlanSlide], kit: InAppKit, loadImage: @escaping InAppImageLoader) {
        self.slides = slides
        self.kit = kit
        self.loadImage = loadImage
        title = kit.text("", .title, kit.onSurface)
        words = kit.text("", .body, kit.muted)
        super.init(frame: .zero)
        axis = .vertical
        spacing = 8
        accessibilityIdentifier = "tb.in_app.carousel"
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.layer.cornerRadius = 8
        picture.backgroundColor = kit.muted.withAlphaComponent(0.12)
        picture.heightAnchor.constraint(equalTo: picture.widthAnchor, multiplier: 0.5).isActive = true
        addArrangedSubview(picture)
        addArrangedSubview(title)
        addArrangedSubview(words)
        if slides.count > 1 {
            let back = InAppIconButton(symbol: "chevron.backward", tint: kit.onSurface, label: "Previous")
            let next = InAppIconButton(symbol: "chevron.forward", tint: kit.onSurface, label: "Next")
            back.addAction(UIAction { [weak self] _ in self?.move(-1) }, for: .touchUpInside)
            next.addAction(UIAction { [weak self] _ in self?.move(1) }, for: .touchUpInside)
            let counter = kit.text("", .body, kit.muted, align: .center)
            self.counter = counter
            let row = UIStackView(arrangedSubviews: [back, counter, next])
            row.axis = .horizontal
            row.alignment = .center
            row.distribution = .equalCentering
            addArrangedSubview(row)
        }
        show(0)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("unavailable") }

    func move(_ step: Int) {
        show((index + step + slides.count) % slides.count)
    }

    private func show(_ at: Int) {
        guard slides.indices.contains(at) else { return }
        index = at
        let slide = slides[at]
        title.content = slide.title ?? ""
        title.isHidden = slide.title == nil
        words.content = slide.body ?? ""
        words.isHidden = slide.body == nil
        // What it shows, read aloud; a slide with no description is a decoration VoiceOver skips.
        picture.isAccessibilityElement = slide.image_alt != nil
        picture.accessibilityLabel = slide.image_alt
        picture.accessibilityTraits = .image
        counter?.content = "\(at + 1) / \(slides.count)"
        counter?.accessibilityLabel = "\(at + 1) of \(slides.count)"
        picture.image = nil
        guard let url = URL(string: slide.image_url) else { return }
        loading = url
        loadImage(url) { [weak self] image in
            MainActor.assumeIsolated {
                // A slide moved past while its picture loaded keeps the picture it moved to.
                guard let self, self.loading == url else { return }
                self.picture.image = image
            }
        }
    }
}

// MARK: - The form

/// A text field that knows which of the form's fields it answers.
private final class InAppFieldText: UITextField {
    var fieldID = ""
    var isDate = false
}

/// A multi-line field, with the placeholder a `UITextView` does not have.
private final class InAppFieldTextView: UITextView {
    var fieldID = ""
    let placeholder = UILabel()
}

/**
 The form's fields as the plan says to draw them: each label with " *" when required, then its control — a text
 box with the keyboard its kind wants, chips, several chips, the platform's own menu for a dropdown, a date picker for a
 date (answered `YYYY-MM-DD`), stars filled up to the pick or a row of numbers. On send, `inAppFormProblem` in its red
 under the fields, or the answers handed on and the thanks in their place.
 */
final class InAppFormView: UIStackView, UITextFieldDelegate, UITextViewDelegate {
    let form: InAppPlanForm
    private let kit: InAppKit
    private(set) var answers: [String: Any] = [:]
    private(set) var problem: InAppTextLabel
    private(set) var send: InAppNativeButton
    private(set) var thanks: InAppTextLabel?
    private(set) var sent = false
    /// Repaints a control after its answer changed, by field id.
    private var repaint: [String: () -> Void] = [:]
    var onSend: ([String: Any]) -> Void = { _ in }
    var onEditing: () -> Void = {}

    init(_ form: InAppPlanForm, kit: InAppKit) {
        self.form = form
        self.kit = kit
        problem = kit.text("", .body, kit.problem)
        send = kit.button(form.submit_label, primary: true)
        super.init(frame: .zero)
        axis = .vertical
        spacing = 12
        accessibilityIdentifier = "tb.in_app.form"
        for field in form.fields { addArrangedSubview(row(field)) }
        problem.accessibilityIdentifier = "tb.in_app.problem"
        problem.isHidden = true
        addArrangedSubview(problem)
        send.accessibilityIdentifier = "tb.in_app.send"
        send.addAction(UIAction { [weak self] _ in self?.submit() }, for: .touchUpInside)
        addArrangedSubview(send)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("unavailable") }

    private func row(_ field: InAppPlanField) -> UIView {
        let label = kit.text(field.label + (field.required ? " *" : ""), .body, kit.onSurface)
        let control: UIView
        switch field.control {
        case "chips", "multi_chips": control = chips(field)
        case "menu": control = menu(field)
        case "date": control = date(field)
        case "scale": control = field.glyph == "star" ? stars(field) : numbers(field)
        default: control = field.multiline ? paragraph(field) : line(field)
        }
        control.accessibilityIdentifier = "tb.in_app.field.\(field.id)"
        let stack = UIStackView(arrangedSubviews: [label, control])
        stack.axis = .vertical
        stack.spacing = 6
        return stack
    }

    /// The box every typed field is drawn in.
    private func box(_ view: UIView) {
        view.layer.borderWidth = 1
        view.layer.borderColor = kit.muted.cgColor
        view.layer.cornerRadius = 6
    }

    private func line(_ field: InAppPlanField) -> UIView {
        let input = InAppFieldText()
        input.fieldID = field.id
        input.delegate = self
        style(input, field)
        switch field.keyboard {
        case "email":
            input.keyboardType = .emailAddress
            input.autocapitalizationType = .none
            input.autocorrectionType = .no
            input.textContentType = .emailAddress
        case "phone":
            input.keyboardType = .phonePad
            input.textContentType = .telephoneNumber
            input.inputAccessoryView = doneBar { [weak input] in input?.resignFirstResponder() }
        case "decimal":
            input.keyboardType = .decimalPad
            input.inputAccessoryView = doneBar { [weak input] in input?.resignFirstResponder() }
        default:
            input.keyboardType = .default
        }
        input.returnKeyType = .done
        input.addAction(UIAction { [weak self, weak input] _ in
            guard let self, let input else { return }
            self.answers[field.id] = input.text ?? ""
        }, for: .editingChanged)
        return input
    }

    private func style(_ input: UITextField, _ field: InAppPlanField) {
        input.font = kit.fonts.font(.field, compatibleWith: input.traitCollection)
        input.adjustsFontForContentSizeCategory = true
        input.textColor = kit.onSurface
        input.tintColor = kit.accent
        input.textAlignment = kit.align
        if let placeholder = field.placeholder {
            input.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: kit.muted])
        }
        input.accessibilityLabel = field.label
        box(input)
        // Padding inside the box, on both sides, whichever side the words start on.
        input.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
        input.leftViewMode = .always
        input.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
        input.rightViewMode = .always
        input.heightAnchor.constraint(greaterThanOrEqualToConstant: CGFloat(InAppStandardLayout.buttonMinHeight)).isActive = true
    }

    private func paragraph(_ field: InAppPlanField) -> UIView {
        let input = InAppFieldTextView()
        input.fieldID = field.id
        input.delegate = self
        input.font = kit.fonts.font(.field, compatibleWith: input.traitCollection)
        input.adjustsFontForContentSizeCategory = true
        input.textColor = kit.onSurface
        input.tintColor = kit.accent
        input.backgroundColor = .clear
        input.textAlignment = kit.align
        input.isScrollEnabled = false
        input.textContainerInset = UIEdgeInsets(top: 10, left: 6, bottom: 10, right: 6)
        box(input)
        input.heightAnchor.constraint(greaterThanOrEqualToConstant: 88).isActive = true
        if let placeholder = field.placeholder {
            input.placeholder.text = placeholder
            input.placeholder.font = input.font
            input.placeholder.textColor = kit.muted
            input.placeholder.textAlignment = kit.align
            input.placeholder.numberOfLines = 0
            input.placeholder.isAccessibilityElement = false
            input.placeholder.translatesAutoresizingMaskIntoConstraints = false
            input.addSubview(input.placeholder)
            NSLayoutConstraint.activate([
                input.placeholder.topAnchor.constraint(equalTo: input.topAnchor, constant: 10),
                input.placeholder.leadingAnchor.constraint(equalTo: input.leadingAnchor, constant: 11),
                input.placeholder.widthAnchor.constraint(equalTo: input.widthAnchor, constant: -22),
            ])
        }
        input.accessibilityHint = field.placeholder
        return input
    }

    /// One pick (`chips`) or several (`multi_chips`, answered as the picks — `inAppFormAnswers` puts them in the author's order).
    private func chips(_ field: InAppPlanField) -> UIView {
        let flow = InAppFlowView()
        let several = field.control == "multi_chips"
        var drawn: [(String, InAppNativeButton)] = []
        for option in field.options ?? [] {
            let chip = kit.chip(option)
            chip.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                if several {
                    var picks = self.answers[field.id] as? [String] ?? []
                    if let at = picks.firstIndex(of: option) { picks.remove(at: at) } else { picks.append(option) }
                    self.answers[field.id] = picks
                } else {
                    self.answers[field.id] = option
                }
                self.repaint[field.id]?()
            }, for: .touchUpInside)
            drawn.append((option, chip))
            flow.addSubview(chip)
        }
        repaint[field.id] = { [weak self] in
            let answer = self?.answers[field.id]
            for (option, chip) in drawn {
                chip.isSelected = several ? (answer as? [String] ?? []).contains(option) : (answer as? String) == option
            }
        }
        return flow
    }

    /// The platform's own menu (`UIMenu`), saying the placeholder until something is chosen, the choice ticked in it.
    private func menu(_ field: InAppPlanField) -> UIView {
        let choose = field.placeholder ?? InAppStandardLayout.wordChoose
        var look = UIButton.Configuration.plain()
        look.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 34)
        look.titleAlignment = .leading
        let font = kit.fonts.font(.field, compatibleWith: nil)
        look.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = font
            return outgoing
        }
        let button = UIButton(configuration: look)
        button.showsMenuAsPrimaryAction = true
        button.contentHorizontalAlignment = .leading
        box(button)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: CGFloat(InAppStandardLayout.buttonMinHeight)).isActive = true
        let chevron = UIImageView(image: UIImage(systemName: "chevron.up.chevron.down"))
        chevron.tintColor = kit.muted
        chevron.isUserInteractionEnabled = false
        chevron.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(chevron)
        NSLayoutConstraint.activate([
            chevron.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -10),
        ])
        button.accessibilityLabel = field.label
        repaint[field.id] = { [weak self, weak button] in
            guard let self, let button else { return }
            let chosen = self.answers[field.id] as? String
            button.configuration?.title = chosen ?? choose
            button.configuration?.baseForegroundColor = chosen == nil ? self.kit.muted : self.kit.onSurface
            button.accessibilityValue = chosen ?? choose
            // Built again for each choice, so the one ticked is the one chosen.
            button.menu = UIMenu(children: (field.options ?? []).map { option in
                UIAction(title: option, state: option == chosen ? .on : .off) { [weak self] _ in
                    guard let self else { return }
                    self.answers[field.id] = option
                    self.repaint[field.id]?()
                }
            })
        }
        repaint[field.id]?()
        return button
    }

    /**
     A date picker for a date, rather than a `YYYY-MM-DD` box to type into. The box stays
     empty — it guesses no day — until the person picks one; the wheel starting at today is not an answer until they
     turn it or press Done. Shown in the person's own way of writing a date, answered as `YYYY-MM-DD`.
     */
    private func date(_ field: InAppPlanField) -> UIView {
        let input = InAppFieldText()
        input.fieldID = field.id
        input.isDate = true
        input.delegate = self
        style(input, field)
        // No caret: nothing is typed here, the wheel is the keyboard.
        input.tintColor = .clear
        let picker = UIDatePicker()
        picker.datePickerMode = .date
        picker.preferredDatePickerStyle = .wheels
        input.inputView = picker
        let shown = DateFormatter()
        shown.dateStyle = .medium
        shown.timeStyle = .none
        let pick = { [weak self, weak input, weak picker] in
            guard let self, let input, let picker else { return }
            self.answers[field.id] = inAppDayText(picker.date, in: .current)
            input.text = shown.string(from: picker.date)
        }
        picker.addAction(UIAction { _ in pick() }, for: .valueChanged)
        input.inputAccessoryView = doneBar { [weak input] in
            pick()
            input?.resignFirstResponder()
        }
        let icon = UIImageView(image: UIImage(systemName: "calendar"))
        icon.tintColor = kit.muted
        icon.contentMode = .center
        icon.frame = CGRect(x: 0, y: 0, width: 36, height: 20)
        input.rightView = icon
        return input
    }

    /// Five stars, filled up to the pick.
    private func stars(_ field: InAppPlanField) -> UIView {
        let values = field.scale ?? []
        var drawn: [(Int, InAppIconButton)] = []
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 0
        for value in values {
            let star = InAppIconButton(symbol: "star", tint: kit.accent, label: "\(value) of \(values.last ?? value)", size: 22)
            star.addAction(UIAction { [weak self] _ in
                self?.answers[field.id] = NSNumber(value: value)
                self?.repaint[field.id]?()
            }, for: .touchUpInside)
            drawn.append((value, star))
            row.addArrangedSubview(star)
        }
        row.addArrangedSubview(UIView())
        repaint[field.id] = { [weak self] in
            let pick = (self?.answers[field.id] as? NSNumber)?.intValue
            for (value, star) in drawn {
                let on = pick.map { value <= $0 } ?? false
                star.symbol = on ? "star.fill" : "star"
                star.accessibilityTraits = pick == value ? [.button, .selected] : .button
            }
        }
        return row
    }

    /// Zero to ten, one chip each, the pick filled.
    private func numbers(_ field: InAppPlanField) -> UIView {
        let flow = InAppFlowView()
        var drawn: [(Int, InAppNativeButton)] = []
        for value in field.scale ?? [] {
            let chip = kit.chip(String(value))
            chip.addAction(UIAction { [weak self] _ in
                self?.answers[field.id] = NSNumber(value: value)
                self?.repaint[field.id]?()
            }, for: .touchUpInside)
            drawn.append((value, chip))
            flow.addSubview(chip)
        }
        repaint[field.id] = { [weak self] in
            let pick = (self?.answers[field.id] as? NSNumber)?.intValue
            for (value, chip) in drawn { chip.isSelected = pick == value }
        }
        return flow
    }

    private func doneBar(_ done: @escaping () -> Void) -> UIToolbar {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.items = [
            UIBarButtonItem(systemItem: .flexibleSpace),
            UIBarButtonItem(systemItem: .done, primaryAction: UIAction { _ in done() }),
        ]
        bar.sizeToFit()
        return bar
    }

    /// The send button's press, and a test's.
    func submit() {
        guard !sent else { return }
        endEditing(true)
        if let wrong = inAppFormProblem(form.fields, answers: answers) {
            problem.content = wrong
            problem.isHidden = false
            UIAccessibility.post(notification: .announcement, argument: wrong)
            return
        }
        sent = true
        onSend(inAppFormAnswers(form.fields, answers: answers))
        // The thanks in the form's place, and the message closed a moment later by whoever drew it.
        for view in arrangedSubviews { view.isHidden = true }
        let thanks = kit.text(form.thanks, .body, kit.onSurface)
        thanks.accessibilityIdentifier = "tb.in_app.thanks"
        thanks.semanticContentAttribute = semanticContentAttribute
        addArrangedSubview(thanks)
        self.thanks = thanks
        UIAccessibility.post(notification: .announcement, argument: form.thanks)
    }

    /// A test's way of typing, picking or choosing: what the control would have answered.
    func answer(_ fieldID: String, _ value: Any?) {
        answers[fieldID] = value
        repaint[fieldID]?()
    }

    // MARK: UITextFieldDelegate, UITextViewDelegate

    func textFieldDidBeginEditing(_ textField: UITextField) { onEditing() }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        // A date is picked, never typed: a hardware keyboard would otherwise write into the box.
        !((textField as? InAppFieldText)?.isDate ?? false)
    }

    func textViewDidBeginEditing(_ textView: UITextView) { onEditing() }

    func textViewDidChange(_ textView: UITextView) {
        guard let input = textView as? InAppFieldTextView else { return }
        answers[input.fieldID] = input.text ?? ""
        input.placeholder.isHidden = !(input.text ?? "").isEmpty
    }
}

// MARK: - The message

/**
 A standard message drawn from its plan: a modal, a banner or a fullscreen. Every value comes from the plan — the dim,
 the lines, the ✕'s corner, where the buttons go, the column on a tablet, the entrance and how it may be closed — and what
 the person does goes to `actions`, which is all this knows of the SDK.

 Order: picture (on top, or leading on a banner), title, body, carousel, countdown, form, buttons — after the words
 on a modal, beside them on a banner, pinned to the bottom of a fullscreen.
 */
final class InAppNativeController: UIViewController {
    let plan: InAppOverlayPlan
    let kit: InAppKit
    private let actions: InAppNativeActions
    private let loadImage: InAppImageLoader
    private let now: () -> Int64
    private let later: InAppLater

    private(set) var card = UIView()
    private(set) var dim: UIView?
    private(set) var picture: UIImageView?
    private(set) var titleLabel: InAppTextLabel?
    private(set) var bodyLabel: InAppTextLabel?
    private(set) var carousel: InAppCarouselView?
    private(set) var countdown: InAppTextLabel?
    private(set) var form: InAppFormView?
    private(set) var buttons: [InAppNativeButton] = []
    private(set) var close: InAppIconButton?
    /// What scrolls: the whole card on a modal or a banner, everything but the pinned buttons on a fullscreen.
    let scroll = UIScrollView()
    /// Nothing reported, and nothing scheduled runs, once the message has gone.
    private(set) var stopped = false

    init(
        plan: InAppOverlayPlan,
        actions: InAppNativeActions,
        loadImage: @escaping InAppImageLoader = InAppNativeDefaults.loadImage,
        now: @escaping () -> Int64 = InAppNativeDefaults.nowMs,
        later: @escaping InAppLater = InAppNativeDefaults.later
    ) {
        self.plan = plan
        kit = InAppKit(plan)
        self.actions = actions
        self.loadImage = loadImage
        self.now = now
        self.later = later
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = InAppNativeRootView()
        root.backgroundColor = .clear
        root.escape = { [weak self] in self?.escape() ?? false }
        view = root
        if plan.backdrop { addDim(root) }
        card.accessibilityIdentifier = "tb.in_app.card"
        card.backgroundColor = kit.surface
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(card)
        switch plan.shape {
        case "banner": drawBanner(root)
        case "fullscreen": drawFullscreen(root)
        default: drawModal(root)
        }
        // The dialog is named by its title; a banner leaves the app around it readable, as it leaves it usable.
        card.accessibilityContainerType = .semanticGroup
        card.accessibilityLabel = plan.title?.text
        root.accessibilityViewIsModal = plan.shape != "banner"
        direct(root)
        tick()
    }

    // MARK: Shapes

    private func addDim(_ root: UIView) {
        let dim = UIView()
        dim.accessibilityIdentifier = "tb.in_app.dim"
        dim.backgroundColor = kit.backdrop
        dim.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(dim)
        pin(dim, to: root)
        // A tap on the dim closes what may be closed; on one that may not, the dim only holds the app back.
        if plan.dismiss.backdrop_tap {
            dim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dimTapped)))
        }
        self.dim = dim
    }

    /// A card centred, at most 320 wide with 16 either side, scrolling inside itself when taller than the window — and
    /// above the keyboard, when its form has brought one up.
    private func drawModal(_ root: UIView) {
        let margin = CGFloat(InAppStandardLayout.modalMargin)
        card.layer.cornerRadius = CGFloat(plan.tokens.radius)
        // After the words (`buttons_at: content`), which is the only place a modal has for them.
        let column = self.column(padded: true, buttons: true)
        fill(card, with: column)
        let safe = root.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: CGFloat(InAppStandardLayout.modalMaxWidth)),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: margin),
            card.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -margin),
            card.topAnchor.constraint(greaterThanOrEqualTo: safe.topAnchor, constant: margin),
            card.bottomAnchor.constraint(lessThanOrEqualTo: root.keyboardLayoutGuide.topAnchor, constant: -margin),
            priority(card.widthAnchor.constraint(equalToConstant: CGFloat(InAppStandardLayout.modalMaxWidth)), .defaultHigh),
            priority(card.centerYAnchor.constraint(equalTo: root.centerYAnchor), UILayoutPriority(500)),
        ])
        placeClose(in: card, reference: card)
    }

    /// Full width less 16 a side, at its edge inside the safe area, no dim: the app goes on being usable around it.
    private func drawBanner(_ root: UIView) {
        let margin = CGFloat(InAppStandardLayout.bannerMargin)
        card.layer.cornerRadius = CGFloat(plan.tokens.radius)
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.isLayoutMarginsRelativeArrangement = true
        // Room at the end for the ✕, which sits in the corner rather than in the row.
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: plan.dismiss.control ? 44 : 12)
        if let image = plan.image, image.placement == "leading" {
            let thumbnail = picture(image)
            thumbnail.layer.cornerRadius = min(CGFloat(plan.tokens.radius), 8)
            let side = CGFloat(InAppStandardLayout.bannerThumbnail)
            NSLayoutConstraint.activate([thumbnail.widthAnchor.constraint(equalToConstant: side), thumbnail.heightAnchor.constraint(equalToConstant: side)])
            row.addArrangedSubview(thumbnail)
        }
        let beside = plan.buttons_at == "trailing"
        let words = self.words(spacing: 4, buttons: !beside)
        row.addArrangedSubview(words)
        if beside {
            /*
             The words give way and the button does not. A button's width is its label's — the control has no size of its
             own, so priorities set on the control say nothing, and left alone the label and the words' labels sit at the
             same default 750. At the largest text size UIKit can settle that tie against the button: "Shop" one letter a
             line in a bar a few points wide. Words can wrap; a button's word cannot be read in pieces.
             */
            for case let label as UILabel in words.arrangedSubviews {
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }
            for button in plan.buttons {
                let drawn = self.button(button)
                drawn.label.setContentHuggingPriority(.required, for: .horizontal)
                drawn.label.setContentCompressionResistancePriority(.required - 1, for: .horizontal)
                row.addArrangedSubview(drawn)
                // Past three fifths of the row even its one line wraps, between its words, so the words keep a column.
                drawn.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, multiplier: 0.6).isActive = true
            }
        }
        fill(card, with: row)
        let safe = root.safeAreaLayoutGuide
        var edges = [
            card.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: margin),
            card.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -margin),
            /*
             Never past half the screen: its words are never cut at a large text size, and a banner that grew to fit them
             would cover the app it exists to leave usable. Past this the row scrolls inside the card, the ✕ staying put.
             */
            card.heightAnchor.constraint(lessThanOrEqualTo: root.heightAnchor, multiplier: 0.5),
        ]
        if plan.edge == "top" {
            edges += [
                card.topAnchor.constraint(equalTo: safe.topAnchor, constant: margin),
                card.bottomAnchor.constraint(lessThanOrEqualTo: root.keyboardLayoutGuide.topAnchor, constant: -margin),
            ]
        } else {
            edges += [
                card.bottomAnchor.constraint(equalTo: root.keyboardLayoutGuide.topAnchor, constant: -margin),
                card.topAnchor.constraint(greaterThanOrEqualTo: safe.topAnchor, constant: margin),
            ]
        }
        NSLayoutConstraint.activate(edges)
        placeClose(in: card, reference: card)
    }

    /// The whole window in `surface`; the content inside the safe area (a centred column on a tablet), the picture edge
    /// to edge, the words scrolling, the buttons pinned to the bottom and the ✕ top-start, clear of the Dynamic Island.
    private func drawFullscreen(_ root: UIView) {
        pin(card, to: root)
        let safe = root.safeAreaLayoutGuide
        let lane = UILayoutGuide()
        root.addLayoutGuide(lane)
        var constraints = [
            lane.topAnchor.constraint(equalTo: safe.topAnchor),
            lane.bottomAnchor.constraint(equalTo: root.keyboardLayoutGuide.topAnchor),
            lane.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            lane.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor),
            priority(lane.widthAnchor.constraint(equalTo: safe.widthAnchor), .defaultHigh),
        ]
        if let wide = plan.content_max_width {
            constraints.append(lane.widthAnchor.constraint(lessThanOrEqualToConstant: CGFloat(wide)))
        }
        let pinned = plan.buttons_at == "bottom" && !plan.buttons.isEmpty
        let column = self.column(padded: true, buttons: !pinned)
        column.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = false
        scroll.addSubview(column)
        card.addSubview(scroll)
        constraints += [
            scroll.topAnchor.constraint(equalTo: lane.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: lane.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: lane.trailingAnchor),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            column.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ]
        if pinned {
            let bar = UIStackView(arrangedSubviews: plan.buttons.map(button))
            bar.axis = .vertical
            bar.spacing = 8
            bar.isLayoutMarginsRelativeArrangement = true
            bar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16)
            bar.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(bar)
            constraints += [
                bar.leadingAnchor.constraint(equalTo: lane.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: lane.trailingAnchor),
                bar.bottomAnchor.constraint(equalTo: lane.bottomAnchor),
                scroll.bottomAnchor.constraint(equalTo: bar.topAnchor),
            ]
        } else {
            constraints.append(scroll.bottomAnchor.constraint(equalTo: lane.bottomAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        placeClose(in: card, reference: lane)
    }

    // MARK: Parts

    /// What scrolls in a modal or a fullscreen: the picture edge to edge, then the words with their padding.
    private func column(padded: Bool, buttons: Bool) -> UIStackView {
        let column = UIStackView()
        column.axis = .vertical
        if let image = plan.image, image.placement == "top" {
            let top = picture(image)
            let ratio = aspect(image.aspect)
            top.heightAnchor.constraint(equalTo: top.widthAnchor, multiplier: 1 / ratio).isActive = true
            column.addArrangedSubview(top)
        }
        let words = self.words(spacing: 8, buttons: buttons)
        words.isLayoutMarginsRelativeArrangement = padded
        let clearOfClose = plan.dismiss.control && plan.image?.placement != "top"
        // With nothing on top, the words start below the ✕ on a fullscreen, and clear of it on a modal.
        words.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: plan.shape == "fullscreen" && clearOfClose ? 52 : 16,
            leading: 16, bottom: 16,
            trailing: plan.shape != "fullscreen" && clearOfClose ? 44 : 16
        )
        column.addArrangedSubview(words)
        return column
    }

    /// Title, body, carousel, countdown, form — and the buttons, when they go after the words.
    private func words(spacing: CGFloat, buttons: Bool) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = spacing
        if let title = plan.title {
            let label = kit.text(title.text, .title, kit.onSurface, lines: title.max_lines)
            label.accessibilityIdentifier = "tb.in_app.title"
            label.accessibilityTraits = .header
            titleLabel = label
            stack.addArrangedSubview(label)
        }
        if let body = plan.body {
            let label = kit.text(body.text, .body, kit.muted, lines: body.max_lines)
            label.accessibilityIdentifier = "tb.in_app.body"
            bodyLabel = label
            stack.addArrangedSubview(label)
        }
        if let slides = plan.slides {
            let view = InAppCarouselView(slides, kit: kit, loadImage: loadImage)
            carousel = view
            stack.addArrangedSubview(view)
        }
        if plan.countdown_to_ms != nil {
            let label = kit.text("", .countdown, kit.onSurface)
            label.accessibilityIdentifier = "tb.in_app.countdown"
            label.accessibilityTraits = .updatesFrequently
            countdown = label
            stack.addArrangedSubview(label)
        }
        if let form = plan.form {
            let view = InAppFormView(form, kit: kit)
            view.onSend = { [weak self] answers in self?.sent(answers) }
            view.onEditing = { [weak self] in self?.actions.editing() }
            self.form = view
            stack.addArrangedSubview(view)
        }
        if buttons, !plan.buttons.isEmpty {
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(16, after: last) }
            for button in plan.buttons { stack.addArrangedSubview(self.button(button)) }
        }
        return stack
    }

    private func picture(_ image: InAppPlanImage) -> UIImageView {
        let view = UIImageView()
        view.accessibilityIdentifier = "tb.in_app.image"
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        // The picture's place is kept at its final size while it loads, so nothing moves when it lands.
        view.backgroundColor = kit.muted.withAlphaComponent(0.12)
        view.translatesAutoresizingMaskIntoConstraints = false
        // What it shows, read aloud; a picture with no description is a decoration VoiceOver skips.
        view.isAccessibilityElement = image.alt != nil
        view.accessibilityLabel = image.alt
        view.accessibilityTraits = .image
        picture = view
        if let url = URL(string: image.url) {
            loadImage(url) { [weak view] loaded in
                MainActor.assumeIsolated { view?.image = loaded }
            }
        }
        return view
    }

    /// `2:1`, `16:9`, `1:1`: width over height.
    private func aspect(_ text: String) -> CGFloat {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return 2 }
        return CGFloat(parts[0] / parts[1])
    }

    private func button(_ planned: InAppPlanButton) -> InAppNativeButton {
        let button = kit.button(planned.label, primary: planned.style == "primary")
        button.accessibilityIdentifier = "tb.in_app.button.\(planned.index)"
        button.addAction(UIAction { [weak self] _ in self?.pressed(planned) }, for: .touchUpInside)
        buttons.append(button)
        return button
    }

    /// The ✕ at the plan's corner (logical: `top_end` is the left of a right-to-left message), 44 points, "Close".
    private func placeClose(in container: UIView, reference: UILayoutGuide) {
        guard plan.dismiss.control else { return }
        let button = InAppIconButton(symbol: "xmark", tint: kit.muted, label: "Close", size: 13, backdrop: kit.surface.withAlphaComponent(0.85))
        button.accessibilityIdentifier = "tb.in_app.close"
        button.addAction(UIAction { [weak self] _ in self?.closedByPerson() }, for: .touchUpInside)
        container.addSubview(button)
        let side = plan.dismiss.corner.hasSuffix("start")
            ? button.leadingAnchor.constraint(equalTo: reference.leadingAnchor, constant: 2)
            : button.trailingAnchor.constraint(equalTo: reference.trailingAnchor, constant: -2)
        NSLayoutConstraint.activate([button.topAnchor.constraint(equalTo: reference.topAnchor, constant: 2), side])
        close = button
    }

    private func placeClose(in container: UIView, reference: UIView) {
        let guide = UILayoutGuide()
        reference.addLayoutGuide(guide)
        pin(guide, to: reference)
        placeClose(in: container, reference: guide)
    }

    /// A column that scrolls inside its container when taller than the room it is given, and is its own height otherwise.
    private func fill(_ container: UIView, with content: UIView) {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = false
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        container.addSubview(scroll)
        pin(scroll, to: container)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            /*
             Just below the words' own resistance to being squeezed (750), so a column too tall for its room scrolls. At an
             equal 750 the two tie, and at the largest text size UIKit can settle it against the words: the column laid
             out exactly as tall as the scroll view, nothing scrolling, and the words losing their last lines — for a
             modal only its button closes, the button with them.
             */
            priority(scroll.heightAnchor.constraint(equalTo: content.heightAnchor), .defaultHigh - 1),
        ])
    }

    private func pin(_ view: UIView, to other: UIView) {
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: other.topAnchor), view.bottomAnchor.constraint(equalTo: other.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: other.leadingAnchor), view.trailingAnchor.constraint(equalTo: other.trailingAnchor),
        ])
    }

    private func pin(_ guide: UILayoutGuide, to view: UIView) {
        NSLayoutConstraint.activate([
            guide.topAnchor.constraint(equalTo: view.topAnchor), guide.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            guide.leadingAnchor.constraint(equalTo: view.leadingAnchor), guide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func priority(_ constraint: NSLayoutConstraint, _ value: UILayoutPriority) -> NSLayoutConstraint {
        constraint.priority = value
        return constraint
    }

    /**
     The message's direction on every view in it. `semanticContentAttribute` is not inherited — each view decides its own
     leading edge — so one set on the root alone flips nothing: stacks, constraints and the flow of chips all read it from
     the view itself. Forced both ways, so an English message in an Arabic app still reads left to right.
     */
    private func direct(_ view: UIView) {
        view.semanticContentAttribute = kit.rtl ? .forceRightToLeft : .forceLeftToRight
        for child in view.subviews { direct(child) }
    }

    // MARK: What the person does

    @objc private func dimTapped() { closedByPerson() }

    /// VoiceOver's escape: only what interrupts, and only when it may be closed (`dismiss.back`); never a banner.
    private func escape() -> Bool {
        guard plan.dismiss.back, !stopped else { return false }
        closedByPerson()
        return true
    }

    /// The ✕, the dim, the escape, a `dismiss` button or the timer: a dismissal — or, once the form is sent, the close
    /// its thanks was waiting for, with nothing more to record.
    func closedByPerson() {
        guard !stopped else { return }
        if form?.sent == true { actions.answered() } else { actions.dismissed() }
    }

    private func pressed(_ button: InAppPlanButton) {
        guard !stopped else { return }
        // A `dismiss` button is a dismissal, not a click: recorded as a click, it would never mark the message done.
        if button.action == "dismiss" { return closedByPerson() }
        actions.pressed(button)
    }

    private func sent(_ answers: [String: Any]) {
        actions.submitted(answers)
        direct(form ?? view)
        later(Double(InAppStandardLayout.formThanksMs) / 1000) { [weak self] in
            guard let self, !self.stopped else { return }
            self.actions.answered()
        }
    }

    /// The countdown's words for now, redrawn on each second's turn, and gone when they say nothing.
    func tick() {
        guard let countdown, let to = plan.countdown_to_ms, !stopped else { return }
        let at = now()
        let words = inAppCountdownText(toMs: to, nowMs: at)
        countdown.content = words
        countdown.isHidden = words.isEmpty
        guard !words.isEmpty else { return }
        // Whole seconds are floored, so the words next change one millisecond past the remainder — not a second from now,
        // which would leave every reading late by up to a second.
        later(Double((to - at) % 1000 + 1) / 1000) { [weak self] in self?.tick() }
    }

    // MARK: The host's

    /// Drawn in as the plan says: a fade, or a slide from its edge — a fade too when the person has asked for less motion.
    func enter() {
        view.layoutIfNeeded()
        let slide = !UIAccessibility.isReduceMotionEnabled && plan.animation.hasPrefix("slide")
        if slide {
            let from = plan.animation == "slide_top" ? -(card.frame.maxY + 8) : view.bounds.height - card.frame.minY + 8
            card.transform = CGAffineTransform(translationX: 0, y: from)
        } else {
            view.alpha = 0
        }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.card.transform = .identity
            self.view.alpha = 1
        }
    }

    /// What VoiceOver should land on first: the title, else the words, else the card.
    var firstElement: Any { titleLabel ?? bodyLabel ?? card }

    func stop() {
        stopped = true
        view.endEditing(true)
    }
}

/**
 A standard message on screen: its window, its entrance, the key window and its timer.

 **A window of its own**, above the app's at `.normal + 1`, as the HTML host's is (`InAppHtmlHost`) and a typed button's
 share sheet (`DeviceActions.shareInOwnWindow`): a message presented on the app's front controller dies with whatever
 the app dismisses, and a presentation of ours would make the
 app's own `present` fail for as long as the message was up. A banner lets every touch around it through to the app and
 leaves the keyboard with it until one of its own fields is tapped; a modal or fullscreen takes the key window, so its
 fields can type, and gives it back when it closes.

 Every ending is reported once and takes the window with it: a press, a dismissal, the close after a sent form's thanks,
 or `destroy` from the core (`disableInApps`). What each ending records is the core's (`Treebars.NativeDisplay`).
 */
@MainActor
final class InAppNativeHost {
    let plan: InAppOverlayPlan
    private let onShown: () -> Void
    private let onPressed: (InAppPlanButton) -> Void
    private let onDismissed: () -> Void
    private let onSubmitted: ([String: Any]) -> Void
    private let onAnswered: () -> Void

    private var window: InAppHtmlWindow?
    private weak var previousKey: UIWindow?
    private(set) var controller: InAppNativeController?
    private var shown = false
    private(set) var closed = false
    private var timers: [DispatchWorkItem] = []

    init(
        plan: InAppOverlayPlan,
        onShown: @escaping () -> Void,
        onPressed: @escaping (InAppPlanButton) -> Void,
        onDismissed: @escaping () -> Void,
        onSubmitted: @escaping ([String: Any]) -> Void,
        onAnswered: @escaping () -> Void
    ) {
        self.plan = plan
        self.onShown = onShown
        self.onPressed = onPressed
        self.onDismissed = onDismissed
        self.onSubmitted = onSubmitted
        self.onAnswered = onAnswered
    }

    func show(in scene: UIWindowScene) {
        previousKey = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
        let controller = InAppNativeController(plan: plan, actions: InAppNativeActions(
            pressed: { [weak self] button in self?.end { $0.onPressed(button) } },
            dismissed: { [weak self] in self?.end { $0.onDismissed() } },
            submitted: { [weak self] answers in self?.onSubmitted(answers) },
            answered: { [weak self] in self?.end { $0.onAnswered() } },
            editing: { [weak self] in
                // A banner's field: the keyboard only comes to a key window.
                guard let window = self?.window, !window.isKeyWindow else { return }
                window.makeKey()
            }
        ))
        self.controller = controller

        let window = InAppHtmlWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        // The system's own parts — the menu, the date wheel, the keyboard — in the appearance the message was drawn in.
        window.overrideUserInterfaceStyle = plan.appearance == "dark" ? .dark : .light
        window.rootViewController = controller
        window.passes = { [weak self] hit in self?.passes(hit) ?? true }
        window.accessibilityViewIsModal = plan.shape != "banner"
        self.window = window
        window.isHidden = false
        if plan.shape != "banner" { window.makeKey() }
        controller.enter()
        shown = true
        onShown()

        if let after = plan.dismiss.after_ms {
            let item = DispatchWorkItem { [weak self] in self?.controller?.closedByPerson() }
            timers.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(after) / 1000, execute: item)
        }
        if plan.shape == "banner" {
            // Said, not focused: a banner leaves the person where they were in the app.
            if let words = plan.title?.text ?? plan.body?.text { UIAccessibility.post(notification: .announcement, argument: words) }
        } else {
            UIAccessibility.post(notification: .screenChanged, argument: controller.firstElement)
        }
    }

    /// Whether a touch goes on to the app: every one before the message is up or after it has gone, and a banner's
    /// surroundings while it shows.
    private func passes(_ hit: UIView) -> Bool {
        if !shown || closed { return true }
        return plan.shape == "banner" && (hit === window || hit === controller?.view)
    }

    private func end(_ report: (InAppNativeHost) -> Void) {
        guard !closed else { return }
        destroy()
        report(self)
    }

    /// Takes it all down, quietly: whoever called says what it meant.
    func destroy() {
        guard !closed else { return }
        closed = true
        timers.forEach { $0.cancel() }
        timers = []
        controller?.stop()
        let wasKey = window?.isKeyWindow == true
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        controller = nil
        if wasKey { previousKey?.makeKey() }
        if plan.shape != "banner" { UIAccessibility.post(notification: .screenChanged, argument: nil) }
    }
}

#endif
