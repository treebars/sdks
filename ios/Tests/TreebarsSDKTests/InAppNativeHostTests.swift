import XCTest
@testable import TreebarsSDK
#if canImport(UIKit)
import UIKit
#endif

/*
 The iOS native renderer: the hook that decides who draws a message, and the views drawn from a
 plan. The hook is pure and runs on a Mac (`swift test --filter InAppNativeHookTests`); the views need UIKit, so they
 compile everywhere and run on a simulator. Neither needs a window or a scene: the host that puts a message on screen is
 the device run's to prove.

 Plans are built from `in-app-render.json` rows the way `InAppRenderPlanTests` builds them, so a view is tested against
 the plan the three cores agree on rather than one written for the test.
 */

private func renderFixture() throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/in-app-render.json")
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], "the shared fixture is missing or malformed")
}

private func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
    try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
}

private func renderEnv(_ spec: [String: Any]) throws -> InAppRenderEnv {
    let env = try XCTUnwrap(spec["env"] as? [String: Any])
    return InAppRenderEnv(
        appearance: env["appearance"] as? String ?? "",
        platform: env["platform"] as? String ?? "",
        device_class: env["device_class"] as? String ?? "",
        fallback_tokens: try (env["fallback_tokens"] as? [String: Any]).map { try decode(InAppTokens.self, $0) },
        text_size: env["text_size"] as? String
    )
}

final class InAppNativeHookTests: XCTestCase {

    private func content(_ fields: [String: Any]) throws -> InAppContent {
        var json: [String: Any] = ["surface": "overlay", "layout": "modal", "trigger": ["kind": "immediate"]]
        json.merge(fields) { _, new in new }
        return try decode(InAppContent.self, json)
    }

    func testWithNoRendererTheCoreDrawsAStandardBody() throws {
        XCTAssertEqual(inAppDrawer(try content([:]), hasRenderer: false, coreDraws: true), .native)
        XCTAssertEqual(inAppDrawer(try content(["body_mode": "standard", "layout": "banner"]), hasRenderer: false, coreDraws: true), .native)
    }

    func testARegisteredRendererIsTheOverrideAndTheCoreDrawsNothing() throws {
        XCTAssertEqual(inAppDrawer(try content([:]), hasRenderer: true, coreDraws: true), .app)
        XCTAssertEqual(inAppDrawer(try content(["layout": "fullscreen"]), hasRenderer: true, coreDraws: true), .app)
    }

    func testAMarkupBodyIsTheWebViewHostsWhateverIsRegistered() throws {
        for markup in [try content(["body_mode": "html", "html": "<p>Hi</p>"]), try content(["layout": "html", "html": "<p>Hi</p>"])] {
            XCTAssertEqual(inAppDrawer(markup, hasRenderer: false, coreDraws: true), .markup)
            XCTAssertEqual(inAppDrawer(markup, hasRenderer: true, coreDraws: true), .markup)
        }
    }

    func testAnInboxRowIsNotAnOverlayAnybodyDraws() throws {
        let inbox = try content(["surface": "inbox"])
        XCTAssertEqual(inAppDrawer(inbox, hasRenderer: false, coreDraws: true), .none)
        XCTAssertEqual(inAppDrawer(inbox, hasRenderer: true, coreDraws: true), .none)
    }

    /// Without UIKit there is nothing to draw with: a standard body waits for a renderer.
    func testWithoutUIKitOnlyARendererDraws() throws {
        XCTAssertEqual(inAppDrawer(try content([:]), hasRenderer: false, coreDraws: false), .none)
        XCTAssertEqual(inAppDrawer(try content([:]), hasRenderer: true, coreDraws: false), .app)
        XCTAssertEqual(inAppDrawer(try content(["body_mode": "html"]), hasRenderer: false, coreDraws: false), .none)
    }

    /// `drawsItself` — the WebView host's share of the hook, which the nudges and the spare WebView still ask — is the
    /// hook's own markup answer on this build, so the two cannot drift.
    func testDrawsItselfIsTheHooksMarkupAnswer() throws {
        XCTAssertEqual(Treebars.drawsItself(try content(["body_mode": "html"])), Treebars.coreDraws)
        XCTAssertFalse(Treebars.drawsItself(try content([:])))
        XCTAssertFalse(Treebars.drawsItself(try content(["body_mode": "html", "surface": "inbox"])))
    }

    /// The hook sends to the native renderer exactly what the plan plans as an overlay, and to the WebView host exactly
    /// what it plans as markup: the two readings of a message cannot disagree about any row the cores are held to.
    func testTheHookAgreesWithThePlanOnEverySyncedRow() throws {
        let plans = try XCTUnwrap(try renderFixture()["plans"] as? [[String: Any]])
        var asked = 0
        for spec in plans where spec["from"] as? String != "feed" {
            let name = "\(spec["id"] as? String ?? "")"
            let message = try decode(InAppMessage.self, try XCTUnwrap(spec["row"]))
            let content = try XCTUnwrap(message.content.in_app, name)
            let kind = inAppRenderPlan(InAppRenderInput(message), env: try renderEnv(spec)).json["kind"] as? String
            let drawer = inAppDrawer(content, hasRenderer: false, coreDraws: true)
            switch kind {
            case "overlay": XCTAssertEqual(drawer, .native, name)
            case "markup": XCTAssertEqual(drawer, .markup, name)
            default: XCTAssertEqual(drawer, .none, name)
            }
            asked += 1
        }
        XCTAssertGreaterThan(asked, 40)
    }

    /// `#RRGGBBAA`, alpha last — the plan's one spelling. Read alpha-first, the default dim would be a pale blue.
    func testAPlanColourIsReadWithItsAlphaLast() throws {
        let dim = try XCTUnwrap(inAppPlanRGBA("#0F172A99"))
        XCTAssertEqual(dim.red, 15.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(dim.green, 23.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(dim.blue, 42.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(dim.alpha, 153.0 / 255, accuracy: 0.0001)
        for other in ["#0F172A", "#FFF", "0F172A99", "#0F172A9", "#GGGGGGGG", "#+F172A99"] {
            XCTAssertNil(inAppPlanRGBA(other), other)
        }
    }

    /// A picked day is written as the server reads one, in the Gregorian calendar whatever the phone's own calendar is.
    func testAPickedDayIsWrittenAsYearMonthDay() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(inAppDayText(Date(timeIntervalSince1970: 1_770_076_800), in: utc), "2026-02-03")
        // Late in a UTC day is the next day in Tokyo.
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        XCTAssertEqual(inAppDayText(Date(timeIntervalSince1970: 1_770_159_600), in: tokyo), "2026-02-04")
        XCTAssertTrue(inAppIsDay(inAppDayText(Date(), in: .current)))
    }
}

#if canImport(UIKit)

@MainActor
final class InAppNativeViewTests: XCTestCase {

    /// What the person did, as the host would be told.
    private final class Told {
        var pressed: [InAppPlanButton] = []
        var dismissed = 0
        var submitted: [[String: Any]] = []
        var answered = 0
        var editing = 0
    }

    // XCTest makes a new instance for every test, so each starts from these.
    private var told = Told()
    private var clock: Int64 = 0
    private var scheduled: [(TimeInterval, () -> Void)] = []
    private var loaded: [URL] = []

    /// A fixture row's plan; `textSize` plans it for that size instead of the case's own, as a host reading another
    /// screen would.
    private func plan(_ id: String, textSize: String? = nil, edit: (inout [String: Any]) -> Void = { _ in }) throws -> InAppOverlayPlan {
        let plans = try XCTUnwrap(try renderFixture()["plans"] as? [[String: Any]])
        let spec = try XCTUnwrap(plans.first { $0["id"] as? String == id }, id)
        var row = try XCTUnwrap(spec["row"] as? [String: Any])
        edit(&row)
        var env = try renderEnv(spec)
        if let textSize { env.text_size = textSize }
        guard case .overlay(let plan) = inAppRenderPlan(InAppRenderInput(try decode(InAppMessage.self, row)), env: env) else {
            throw XCTSkip("\(id) is not an overlay")
        }
        return plan
    }

    /**
     `textSize` draws the message at that content-size category — in a window, through a parent's trait override, so the
     simulator's own setting is never touched and every test starts from the same size.
     */
    private func draw(_ plan: InAppOverlayPlan, inWindow: Bool = false, textSize: UIContentSizeCategory? = nil) -> InAppNativeController {
        let told = told
        let controller = InAppNativeController(
            plan: plan,
            actions: InAppNativeActions(
                pressed: { told.pressed.append($0) },
                dismissed: { told.dismissed += 1 },
                submitted: { told.submitted.append($0) },
                answered: { told.answered += 1 },
                editing: { told.editing += 1 }
            ),
            loadImage: { [unowned self] url, done in
                self.loaded.append(url)
                done(nil)
            },
            now: { [unowned self] in self.clock },
            later: { [unowned self] seconds, work in self.scheduled.append((seconds, work)) }
        )
        /*
         In a window when a test measures layout against the screen, as the host draws it. Laid out bare, the view has no
         keyboard layout guide or safe area to pin to, so a fullscreen's buttons would sit under its words rather than at the
         foot of the screen — a test measuring its own hosting, not the renderer.
         */
        if inWindow || textSize != nil {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            if let textSize {
                let parent = UIViewController()
                parent.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: textSize), forChild: controller)
                parent.addChild(controller)
                controller.view.frame = parent.view.bounds
                controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                parent.view.addSubview(controller.view)
                controller.didMove(toParent: parent)
                window.rootViewController = parent
            } else {
                window.rootViewController = controller
            }
            window.isHidden = false
            windows.append(window)
        } else {
            controller.loadViewIfNeeded()
            controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        }
        // A third pass for a new text size: the words are drawn again at it, and only then measured at it.
        for _ in 0..<3 { controller.view.layoutIfNeeded() }
        return controller
    }

    /// The windows `draw` hosted its controllers in, kept until the test ends so none is released mid-assertion.
    private var windows: [UIWindow] = []

    /// Every part the renderer names, depth first: the order they are drawn in.
    private func parts(_ view: UIView) -> [String] {
        var found: [String] = []
        if let id = view.accessibilityIdentifier, id.hasPrefix("tb.in_app.") { found.append(id) }
        for child in view.subviews { found += parts(child) }
        return found
    }

    private func find<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) -> T? {
        if view.accessibilityIdentifier == id, let hit = view as? T { return hit }
        for child in view.subviews {
            if let hit = find(id, in: child, as: type) { return hit }
        }
        return nil
    }

    private func every(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(every) }

    private func runScheduled() {
        let due = scheduled
        scheduled = []
        due.forEach { $0.1() }
    }

    private func paragraph(_ label: UILabel) -> NSParagraphStyle? {
        label.attributedText?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    }

    // MARK: Shapes and order

    func testAModalDrawsItsPartsInThePlansOrder() throws {
        let plan = try plan("RP-001")
        let controller = draw(plan)
        XCTAssertEqual(parts(controller.view), [
            "tb.in_app.dim", "tb.in_app.card", "tb.in_app.image", "tb.in_app.title", "tb.in_app.body",
            "tb.in_app.button.1", "tb.in_app.button.2", "tb.in_app.close",
        ])
        XCTAssertEqual(controller.titleLabel?.numberOfLines, 2)
        XCTAssertEqual(controller.bodyLabel?.numberOfLines, 4)
        XCTAssertEqual(controller.buttons.count, plan.buttons.count)
        // The first filled with the accent, the second accent words on nothing.
        XCTAssertEqual(controller.buttons[0].backgroundColor, inAppUIColour(plan.tokens.accent))
        XCTAssertEqual(controller.buttons[1].backgroundColor, .clear)
        XCTAssertEqual(controller.dim?.backgroundColor, inAppUIColour(plan.tokens.backdrop))
        XCTAssertEqual(loaded, [URL(string: "https://cdn.example/spring.jpg")!])
        // At most 320 wide, centred.
        XCTAssertLessThanOrEqual(controller.card.frame.width, 320.5)
        XCTAssertEqual(controller.card.frame.midX, 195, accuracy: 1)
        XCTAssertTrue(controller.view.accessibilityViewIsModal)
    }

    func testABannerLeavesTheAppUsableAndPutsItsButtonBesideTheWords() throws {
        let plan = try plan("RP-006")
        let controller = draw(plan)
        XCTAssertNil(controller.dim)
        XCTAssertEqual(parts(controller.view), [
            "tb.in_app.card", "tb.in_app.image", "tb.in_app.title", "tb.in_app.body", "tb.in_app.button.1", "tb.in_app.close",
        ])
        XCTAssertEqual(controller.titleLabel?.numberOfLines, 1)
        XCTAssertEqual(controller.bodyLabel?.numberOfLines, 2)
        // A 48-point leading thumbnail.
        XCTAssertEqual(controller.picture?.frame.width ?? 0, 48, accuracy: 0.5)
        XCTAssertFalse(controller.view.accessibilityViewIsModal)
        // Never closed by the escape: a banner does not interrupt, so there is nothing to back out of.
        XCTAssertFalse(controller.view.accessibilityPerformEscape())
        XCTAssertEqual(told.dismissed, 0)
        // At its edge: a top banner sits near the top.
        XCTAssertLessThan(controller.card.frame.minY, 100)
        // The words give way before the button's label does, and the button never takes more than three fifths of the row.
        let title = try XCTUnwrap(controller.titleLabel)
        XCTAssertGreaterThan(
            controller.buttons[0].label.contentCompressionResistancePriority(for: .horizontal), title.contentCompressionResistancePriority(for: .horizontal)
        )
        XCTAssertLessThanOrEqual(controller.buttons[0].frame.width, controller.card.frame.width * 0.6 + 0.5)
    }

    // MARK: The largest text size

    func testALargeTextSizeIsAnAccessibilityCategory() {
        for category: UIContentSizeCategory in [.accessibilityMedium, .accessibilityLarge, .accessibilityExtraExtraExtraLarge] {
            XCTAssertEqual(inAppTextSize(category), "large", category.rawValue)
        }
        for category: UIContentSizeCategory in [.extraSmall, .large, .extraExtraExtraLarge, .unspecified] {
            XCTAssertEqual(inAppTextSize(category), "default", category.rawValue)
        }
    }

    /// Where `view` is, in the controller's root view's space.
    private func frame(_ view: UIView, in controller: InAppNativeController) -> CGRect {
        view.convert(view.bounds, to: controller.view)
    }

    /**
     The device's banner, drawn beside its words as a default plan draws it, at the largest size: the case a message planned
     before the person turned the size up would still meet. The button keeps its word whole rather than squeezing it into a
     bar a few points wide, one letter a line.
     */
    func testABannersButtonBesideItsWordsKeepsItsWordWholeAtTheLargestTextSize() throws {
        let plan = try plan("RP-081", textSize: "default")
        XCTAssertEqual(plan.buttons_at, "trailing")
        let controller = draw(plan, textSize: .accessibilityExtraExtraExtraLarge)
        let label = try XCTUnwrap(controller.buttons.first?.label)
        let font = try XCTUnwrap(label.font)
        XCTAssertGreaterThan(font.pointSize, 30, "drawn at the largest size, or this proves nothing")
        let oneLine = label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        XCTAssertGreaterThanOrEqual(label.bounds.width, oneLine.width - 1, "the button is as wide as its word")
        XCTAssertLessThan(label.bounds.height, font.lineHeight * 1.5, "on one line: \(label.bounds)")
        // And the words still have a column to wrap in.
        XCTAssertGreaterThan(try XCTUnwrap(controller.titleLabel).bounds.width, 40)
    }

    func testAtTheLargestTextSizeABannersWordsAreWholeItsButtonUnderThemAndItStopsAtHalfTheScreen() throws {
        let plan = try plan("RP-081")
        XCTAssertEqual(plan.buttons_at, "content")
        let controller = draw(plan, textSize: .accessibilityExtraExtraExtraLarge)
        let title = try XCTUnwrap(controller.titleLabel)
        let body = try XCTUnwrap(controller.bodyLabel)
        XCTAssertEqual(title.numberOfLines, 0, "never cut")
        XCTAssertEqual(body.numberOfLines, 0, "never cut")
        let button = try XCTUnwrap(controller.buttons.first)
        XCTAssertGreaterThan(frame(button, in: controller).minY, frame(body, in: controller).maxY - 0.5, "the button under the words")
        XCTAssertLessThanOrEqual(controller.card.frame.height, controller.view.bounds.height / 2 + 0.5, "no taller than half the screen")
        let scroll = controller.scroll
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height + 1, "the words outgrew half the screen, or this proves nothing")
        let close = try XCTUnwrap(controller.close)
        XCTAssertFalse(close.isDescendant(of: scroll), "the ✕ never scrolls away")
        try assertReachedByScrolling(button, in: controller)
    }

    /// Scrolled to the end, `view` is inside what the scroll view shows.
    private func assertReachedByScrolling(_ view: UIView, in controller: InAppNativeController, file: StaticString = #filePath, line: UInt = #line) throws {
        let scroll = controller.scroll
        XCTAssertTrue(view.isDescendant(of: scroll), "it scrolls with the words, so it is below them however long they are", file: file, line: line)
        let end = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
        scroll.setContentOffset(CGPoint(x: 0, y: max(end, -scroll.adjustedContentInset.top)), animated: false)
        controller.view.layoutIfNeeded()
        let shows = frame(scroll, in: controller)
        let reached = frame(view, in: controller)
        XCTAssertGreaterThanOrEqual(reached.minY, shows.minY - 0.5, "\(reached) inside \(shows)", file: file, line: line)
        XCTAssertLessThanOrEqual(reached.maxY, shows.maxY + 0.5, "\(reached) inside \(shows)", file: file, line: line)
    }

    /**
     The trap the uncapped words could have set: a modal only its button closes, whose words at the largest size are taller
     than the screen. Its button must be reachable, or the person is held behind a message they cannot leave.
     */
    func testAtTheLargestTextSizeAModalOnlyItsButtonClosesKeepsTheButtonWithinReach() throws {
        let plan = try plan("RP-083")
        let controller = draw(plan, textSize: .accessibilityExtraExtraExtraLarge)
        XCTAssertNil(controller.close, "the button is the only way out")
        let body = try XCTUnwrap(controller.bodyLabel)
        XCTAssertEqual(body.numberOfLines, 0, "never cut")
        XCTAssertGreaterThan(try XCTUnwrap(body.font).pointSize, 30, "drawn at the largest size, or this proves nothing")
        let scroll = controller.scroll
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height + 1, "the words outgrew the card, or this proves nothing")
        // The card stays on the screen; it is the words inside it that scroll.
        let root = controller.view!
        XCTAssertGreaterThanOrEqual(controller.card.frame.minY, root.safeAreaInsets.top - 0.5)
        XCTAssertLessThanOrEqual(controller.card.frame.maxY, root.bounds.height - root.safeAreaInsets.bottom + 0.5)
        let button = try XCTUnwrap(controller.buttons.first)
        try assertReachedByScrolling(button, in: controller)
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(told.pressed.map(\.index), [1])
    }

    func testAFullscreenPinsItsButtonsAndPutsItsCloseTopStart() throws {
        let plan = try plan("RP-009")
        let controller = draw(plan, inWindow: true)
        let root = controller.view!
        for button in controller.buttons {
            XCTAssertFalse(button.isDescendant(of: controller.scroll), "a fullscreen's buttons do not scroll away")
            XCTAssertGreaterThan(button.convert(button.bounds, to: root).maxY, 700)
        }
        let close = try XCTUnwrap(controller.close)
        let corner = close.convert(close.bounds, to: root)
        XCTAssertLessThan(corner.midX, 60, "top-start is the left of a left-to-right message")
        // Inside the safe area, just below the Dynamic Island or the status bar.
        XCTAssertGreaterThanOrEqual(corner.minY, root.safeAreaInsets.top - 0.5)
        XCTAssertLessThan(corner.midY, root.safeAreaInsets.top + 60)
        XCTAssertEqual(controller.titleLabel?.numberOfLines, 0, "a fullscreen's words are never cut")
        XCTAssertEqual(controller.card.frame, root.bounds)
    }

    // MARK: Closing

    func testAModalThatOnlyItsButtonClosesHasNoOtherWayOut() throws {
        let controller = draw(try plan("RP-004"))
        XCTAssertNil(controller.close)
        XCTAssertEqual(controller.dim?.gestureRecognizers?.count ?? 0, 0)
        XCTAssertFalse(controller.view.accessibilityPerformEscape())
        XCTAssertEqual(told.dismissed, 0)
    }

    func testTheCloseTheDimAndTheEscapeAreEachADismissal() throws {
        let controller = draw(try plan("RP-001"))
        controller.close?.sendActions(for: .touchUpInside)
        XCTAssertEqual(told.dismissed, 1)
        XCTAssertEqual(controller.dim?.gestureRecognizers?.count, 1, "a tap on the dim closes what may be closed")
        XCTAssertTrue(controller.view.accessibilityPerformEscape())
        XCTAssertEqual(told.dismissed, 2)
        XCTAssertEqual(controller.close?.accessibilityLabel, "Close")
    }

    func testAButtonIsAPressAndADismissButtonIsADismissal() throws {
        let controller = draw(try plan("RP-001"))
        controller.buttons[0].sendActions(for: .touchUpInside)
        XCTAssertEqual(told.pressed.map(\.index), [1])
        XCTAssertEqual(told.pressed.first?.destination, "shop://sale")
        controller.buttons[1].sendActions(for: .touchUpInside)
        XCTAssertEqual(told.pressed.count, 1, "`dismiss` is not a click")
        XCTAssertEqual(told.dismissed, 1)
    }

    func testNothingIsReportedOnceTheMessageHasGone() throws {
        let controller = draw(try plan("RP-001"))
        controller.stop()
        controller.close?.sendActions(for: .touchUpInside)
        controller.buttons[0].sendActions(for: .touchUpInside)
        XCTAssertFalse(controller.view.accessibilityPerformEscape())
        XCTAssertEqual(told.dismissed, 0)
        XCTAssertTrue(told.pressed.isEmpty)
    }

    // MARK: Accessibility and direction

    func testAPictureIsReadByItsDescriptionAndADecorationIsNotReadAtAll() throws {
        let described = draw(try plan("RP-001"))
        XCTAssertEqual(described.picture?.isAccessibilityElement, true)
        XCTAssertEqual(described.picture?.accessibilityLabel, "A red winter coat on a model")
        let decoration = draw(try plan("RP-001") { row in
            var content = row["content"] as? [String: Any] ?? [:]
            var inApp = content["in_app"] as? [String: Any] ?? [:]
            inApp["image_alt"] = nil
            content["in_app"] = inApp
            row["content"] = content
        })
        XCTAssertEqual(decoration.picture?.isAccessibilityElement, false)
        XCTAssertEqual(decoration.card.accessibilityLabel, "Spring sale", "the dialog is named by its title")
        XCTAssertTrue((decoration.firstElement as? UIView) === decoration.titleLabel)
    }

    func testARightToLeftMessageRunsRightToLeftThroughout() throws {
        let controller = draw(try plan("RP-030"))
        // UIKit's own private parts (a scroll indicator, made when it is first needed) are not the renderer's to direct.
        for view in every(controller.view) where !String(describing: type(of: view)).hasPrefix("_") {
            XCTAssertEqual(view.semanticContentAttribute, .forceRightToLeft, "\(type(of: view))")
        }
        XCTAssertEqual(paragraph(try XCTUnwrap(controller.titleLabel))?.alignment, .right)
        // `top_end` is the left of a right-to-left message.
        let close = try XCTUnwrap(controller.close)
        XCTAssertLessThan(close.convert(close.bounds, to: controller.view).midX, controller.view.bounds.midX)
    }

    func testTheWordsGrowWithTheTextSize() throws {
        let fonts = InAppFonts(nil)
        let usual = fonts.font(.title, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        let largest = fonts.font(.title, compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge))
        XCTAssertEqual(usual.pointSize, 16, accuracy: 0.5)
        XCTAssertGreaterThan(largest.pointSize, 30)
        XCTAssertEqual(fonts.font(.body, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize, 13, accuracy: 0.5)
        // A family the app has not linked is the system font rather than a guess.
        XCTAssertNil(InAppFonts("No Such Family 1234").family)
    }

    func testAPillIsAPillWhateverItsHeight() throws {
        let kit = InAppKit(try plan("RP-001"))
        let pill = InAppNativeButton(
            title: "Go", kit: kit, radius: 999, minHeight: 44, insets: .zero, look: { _ in (fill: .red, text: .white, border: nil) }
        )
        pill.frame = CGRect(x: 0, y: 0, width: 200, height: 44)
        pill.layoutIfNeeded()
        XCTAssertEqual(pill.layer.cornerRadius, 22)
    }

    // MARK: Carousel and countdown

    func testACarouselMovesByHandAndWrapsRound() throws {
        let controller = draw(try plan("RP-051"))
        XCTAssertEqual(parts(controller.view), [
            "tb.in_app.dim", "tb.in_app.card", "tb.in_app.image", "tb.in_app.title", "tb.in_app.body", "tb.in_app.carousel", "tb.in_app.close",
        ])
        let carousel = try XCTUnwrap(controller.carousel)
        XCTAssertEqual(carousel.counter?.content, "1 / 3")
        XCTAssertTrue(carousel.picture.isAccessibilityElement)
        carousel.move(1)
        XCTAssertEqual(carousel.counter?.content, "2 / 3")
        XCTAssertFalse(carousel.picture.isAccessibilityElement, "the second slide has no description")
        carousel.move(-1)
        carousel.move(-1)
        XCTAssertEqual(carousel.counter?.content, "3 / 3")
        XCTAssertTrue(scheduled.isEmpty, "a carousel never moves by itself")
    }

    func testACountdownTicksOnEachSecondAndGoesAtZero() throws {
        let plan = try plan("RP-053")
        let to = try XCTUnwrap(plan.countdown_to_ms)
        clock = to - 3_723_450
        let controller = draw(plan)
        let words = try XCTUnwrap(controller.countdown)
        XCTAssertEqual(words.content, "01:02:03")
        XCTAssertFalse(words.isHidden)
        // Asked again as the second turns, not a second from now.
        XCTAssertEqual(scheduled.first?.0 ?? 0, 0.451, accuracy: 0.0001)
        clock = to - 500
        runScheduled()
        XCTAssertEqual(words.content, "00:00:00")
        clock = to
        runScheduled()
        XCTAssertTrue(words.isHidden)
        XCTAssertTrue(scheduled.isEmpty, "nothing left to count")
    }

    // MARK: The form

    private func form(_ controller: InAppNativeController) throws -> InAppFormView {
        try XCTUnwrap(controller.form)
    }

    func testEveryFieldIsDrawnWithItsOwnControl() throws {
        let controller = draw(try plan("RP-060"))
        let root = controller.view!
        let name = try XCTUnwrap(find("tb.in_app.field.name", in: root, as: UITextField.self))
        XCTAssertEqual(((name.superview as? UIStackView)?.arrangedSubviews.first as? InAppTextLabel)?.content, "Name *")
        XCTAssertEqual(find("tb.in_app.field.email", in: root, as: UITextField.self)?.keyboardType, .emailAddress)
        XCTAssertEqual(find("tb.in_app.field.email", in: root, as: UITextField.self)?.autocapitalizationType, UITextAutocapitalizationType.none)
        XCTAssertEqual(find("tb.in_app.field.phone", in: root, as: UITextField.self)?.keyboardType, .phonePad)
        XCTAssertEqual(find("tb.in_app.field.age", in: root, as: UITextField.self)?.keyboardType, .decimalPad)
        XCTAssertNotNil(find("tb.in_app.field.about", in: root, as: UITextView.self), "a textarea is many lines")
        let birthday = try XCTUnwrap(find("tb.in_app.field.birthday", in: root, as: UITextField.self))
        XCTAssertEqual((birthday.inputView as? UIDatePicker)?.datePickerMode, .date)
        let menu = try XCTUnwrap(find("tb.in_app.field.plan", in: root, as: UIButton.self))
        XCTAssertTrue(menu.showsMenuAsPrimaryAction)
        XCTAssertEqual(menu.menu?.children.count, 3)
        XCTAssertEqual(menu.configuration?.title, "Pick a plan", "a menu says its placeholder until something is chosen")
        XCTAssertEqual(find("tb.in_app.field.size", in: root)?.subviews.count, 3)
        XCTAssertEqual(find("tb.in_app.field.nps", in: root)?.subviews.count, 11)
        let stars = try XCTUnwrap(find("tb.in_app.field.stars", in: root, as: UIStackView.self))
        XCTAssertEqual(stars.arrangedSubviews.compactMap { $0 as? InAppIconButton }.count, 5)
        XCTAssertEqual(find("tb.in_app.send", in: root, as: InAppNativeButton.self)?.label.content, "Join")
    }

    func testTappingAControlAnswersIt() throws {
        let controller = draw(try plan("RP-060"))
        let root = controller.view!
        let form = try form(controller)
        let sizes = try XCTUnwrap(find("tb.in_app.field.size", in: root)?.subviews.compactMap { $0 as? InAppNativeButton })
        sizes[1].sendActions(for: .touchUpInside)
        XCTAssertEqual(form.answers["size"] as? String, "M")
        XCTAssertTrue(sizes[1].isSelected)
        sizes[0].sendActions(for: .touchUpInside)
        XCTAssertEqual(form.answers["size"] as? String, "S")
        XCTAssertFalse(sizes[1].isSelected, "one pick")

        let likes = try XCTUnwrap(find("tb.in_app.field.likes", in: root)?.subviews.compactMap { $0 as? InAppNativeButton })
        likes[1].sendActions(for: .touchUpInside)
        likes[0].sendActions(for: .touchUpInside)
        XCTAssertEqual(form.answers["likes"] as? [String], ["Bags", "Shoes"])
        XCTAssertEqual(inAppFormAnswers(form.form.fields, answers: form.answers)["likes"] as? String, "Shoes,Bags", "sent in the author's order")

        let stars = try XCTUnwrap(find("tb.in_app.field.stars", in: root, as: UIStackView.self)?.arrangedSubviews.compactMap { $0 as? InAppIconButton })
        stars[2].sendActions(for: .touchUpInside)
        XCTAssertEqual((form.answers["stars"] as? NSNumber)?.intValue, 3)
        XCTAssertEqual(stars.map(\.symbol), ["star.fill", "star.fill", "star.fill", "star", "star"], "filled up to the pick")

        let birthday = try XCTUnwrap(find("tb.in_app.field.birthday", in: root, as: UITextField.self))
        let picker = try XCTUnwrap(birthday.inputView as? UIDatePicker)
        picker.date = Date(timeIntervalSince1970: 1_770_120_000)
        picker.sendActions(for: .valueChanged)
        XCTAssertEqual(form.answers["birthday"] as? String, inAppDayText(picker.date, in: .current))

        form.answer("plan", "Pro")
        let menu = try XCTUnwrap(find("tb.in_app.field.plan", in: root, as: UIButton.self))
        XCTAssertEqual(menu.configuration?.title, "Pro")
        XCTAssertEqual((menu.menu?.children as? [UIAction])?.first { $0.state == .on }?.title, "Pro", "the choice ticked in the menu")

        let name = try XCTUnwrap(find("tb.in_app.field.name", in: root, as: UITextField.self))
        form.textFieldDidBeginEditing(name)
        XCTAssertEqual(told.editing, 1, "the host makes its window key for the keyboard")
    }

    func testSendingSaysTheFirstProblemThenThanksThenCloses() throws {
        let controller = draw(try plan("RP-060"))
        let form = try form(controller)
        form.submit()
        XCTAssertEqual(form.problem.content, "Name is required.")
        XCTAssertFalse(form.problem.isHidden)
        XCTAssertEqual(form.problem.colour, inAppUIColour("#B42318FF"))
        XCTAssertTrue(told.submitted.isEmpty)

        form.answer("name", "  Ada ")
        form.answer("email", "ada@example")
        form.submit()
        XCTAssertEqual(form.problem.content, "Email is not an email address.")

        form.answer("email", "ada@example.com")
        form.answer("stars", NSNumber(value: 4))
        form.answer("age", "34")
        form.submit()
        XCTAssertEqual(told.submitted.count, 1)
        let sent = try XCTUnwrap(told.submitted.first)
        XCTAssertEqual(sent["name"] as? String, "Ada")
        XCTAssertEqual((sent["stars"] as? NSNumber)?.intValue, 4)
        XCTAssertEqual((sent["age"] as? NSNumber)?.doubleValue, 34, "a number as a number")
        XCTAssertEqual(form.thanks?.content, "Welcome aboard.")
        XCTAssertTrue(form.arrangedSubviews.filter { $0 !== form.thanks }.allSatisfy(\.isHidden), "the thanks in the form's place")

        // Closed after the thanks, with nothing more recorded; and a close before then is not a dismissal either.
        XCTAssertEqual(scheduled.map(\.0), [2.5])
        controller.closedByPerson()
        XCTAssertEqual(told.dismissed, 0)
        XCTAssertEqual(told.answered, 1)
        runScheduled()
        XCTAssertEqual(told.answered, 2, "the host takes the first and ignores the second")
        form.submit()
        XCTAssertEqual(told.submitted.count, 1, "sent once")
    }

    func testABannerCarriesAForm() throws {
        let controller = draw(try plan("RP-063"))
        XCTAssertNotNil(controller.form)
        XCTAssertNil(controller.dim)
        XCTAssertTrue(controller.buttons.isEmpty)
        XCTAssertEqual(controller.form?.send.label.content, "Send")
    }
}

#endif
