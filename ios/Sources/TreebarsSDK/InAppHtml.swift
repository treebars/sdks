import Foundation
#if canImport(UIKit)
import StoreKit
import UIKit
import WebKit
#endif

/*
 * An HTML in-app message, drawn by this SDK in a WKWebView with the `treebars` bridge.
 *
 * Standard bodies are the app's to draw, through its renderer; a markup body is this SDK's — the page needs the
 * bridge, and a bridge an app had to wire by hand would be a bridge most apps got
 * subtly wrong. Three pieces, each the Swift spelling of the web SDK's (`sdks/web/src/bridge-host.ts`,
 * `bridge-calls.ts`) and of Android's (`InAppHtml.kt`), held to them by the same golden documents and the same
 * conformance cases, in `Tests/TreebarsSDKTests/Fixtures`:
 *
 * - `BridgeDocument`: what the WebView is handed — the frame policy and the page-side shim before anything of the
 *   message's, byte for byte what the web SDK builds.
 * - `BridgeDisplay`: what each call means — one display's state and a handler for every method the bridge table gives
 *   iOS.
 * - `InAppHtmlHost`: the window and the WebView, the container spec, the safe-area insets, and who may call.
 */

/// Safe-area insets in CSS pixels, which in a WKWebView are points.
struct BridgeInsets: Equatable {
    let top: Int
    let right: Int
    let bottom: Int
    let left: Int
}

#if canImport(UIKit)
extension BridgeInsets {
    /// Rounded up, never to the nearest: an inset that rounds down puts a line of the page under the bar (as Android).
    init(_ safe: UIEdgeInsets) {
        self.init(top: Int(safe.top.rounded(.up)), right: Int(safe.right.rounded(.up)),
                  bottom: Int(safe.bottom.rounded(.up)), left: Int(safe.left.rounded(.up)))
    }
}
#endif

private func pattern(_ source: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
    // Every pattern here is a literal; one that does not compile is a bug the first test run reports.
    try! NSRegularExpression(pattern: source, options: options) // swiftlint:disable:this force_try
}

private extension NSRegularExpression {
    /// JavaScript's `test`. Note ICU's `\w` and `\d` are Unicode where JavaScript's are ASCII, so the patterns below
    /// spell the classes out rather than borrow them.
    func test(_ text: String) -> Bool {
        firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }
}

enum BridgeDocument {
    private static let doctype = pattern("^\\s*<!doctype[^>]*>", .caseInsensitive)
    private static let isDocument = pattern("^\\s*(<!doctype\\b|<html\\b)", .caseInsensitive)
    private static let authorDirection = pattern("<(html|body)\\b[^>]*\\sdir\\s*=", .caseInsensitive)

    /**
     The document a message's WebView is handed: the web SDK's `bridgeDocument`, spelled in Swift. A fragment is framed
     as the preview frames it, with a viewport WebKit will not zoom into a focused field; a whole document stays one, the
     policy and shim straight after its doctype. The environment is in it from the first byte — the insets, keyboard and
     text scale as CSS variables in `<style id="tb-env">`, because a page written against them reads the same on every
     host, and the host, device, orientation, theme and states as `<html>` attributes, placed before an author's own
     `<html>` so the parser keeps ours. The device class hides every `data-tb-show` element not listed for it, and the
     orientation every `data-tb-orientation` element not for the way the device is held, in rules the shim rewrites as
     the environment changes.
     */
    static func build(_ html: String, nonce: String, direction: String?, env: InAppEnv) -> String {
        let policy = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(escapeAttribute(InAppBridge.frameCSP))\">"
        let shim = "<script>\(InAppBridge.shim)({\"host\":\"\(env.host)\",\"nonce\":\"\(nonce)\"})</script>"
        let environment = "<style id=\"tb-env\">\(InAppHostEnv.style(env))</style>"
        let showClass = env.device == "phone" ? "mobile" : env.device
        let shown = "<style>[data-tb-show]:not([data-tb-show~=\"\(showClass)\"]){display:none!important}</style>"
        let held = "<style id=\"tb-orientation\">\(orientationRule(env.orientation))</style>"
        let dir = direction == "rtl" && !authorDirection.test(html) ? " dir=\"rtl\"" : ""
        let root = "<html\(InAppHostEnv.attributes(env))\(dir)>"
        if isDocument.test(html) {
            // In UTF-16 units, as JavaScript's `slice` cuts, so a document opening with an emoji is cut where the web's is.
            let text = html as NSString
            let found = doctype.firstMatch(in: html, range: NSRange(location: 0, length: text.length))
            let head = found.map { text.substring(with: $0.range) } ?? "<!doctype html>"
            return "\(head)\(root)\(policy)\(environment)\(shown)\(held)\(shim)\(text.substring(from: found?.range.length ?? 0))"
        }
        return "<!doctype html>\(root)<meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1,maximum-scale=1,viewport-fit=cover\">"
            + "\(policy)<style>\(InAppBridge.frameRules)</style>\(environment)\(shown)\(held)\(shim)\(html)"
    }

    /// What hides the elements not for this orientation — Android's `orientationRule` too; the shim writes it again on a turn.
    static func orientationRule(_ orientation: String) -> String {
        "[data-tb-orientation]:not([data-tb-orientation~=\"\(orientation)\"]){display:none!important}"
    }

    private static func escapeAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
    }

    /// A nonce for one display: unguessable (the system generator is cryptographic), and in nothing but the document.
    static func nonce() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }
}

/// What a display may ask of the SDK: the few things a bridge call needs, and nothing else.
protocol BridgeSdk: AnyObject {
    func track(_ name: String, _ properties: [String: Any])
    /// Traits on the person: through `identify` when somebody is signed in, on the anonymous person otherwise, who
    /// carries them into the account at sign-in. The page cannot tell the two apart, by design.
    func setTraits(_ traits: [String: Any]) -> [String: Any]
    func requestPushPermission(_ answer: @escaping (String) -> Void)
    /// The app's delegate, told what was pressed.
    func clicked(action: String, values: [String: Any], fields: [String: Any])
    /// Spent, the screen freed and the message closed: a press that leads somewhere.
    func spent()
    /// Dismissed: spent, the screen freed, the app told. Recording is the display's.
    func dismissed()
    func flush()
    /// The queued message's own copy of a stored value, so a later display of it reads what this one wrote. Android
    /// and the web write into the message they hold; a Swift message is a value, so the store is told instead.
    func keep(key: String, value: Any?)
    /**
     Somewhere a press leads, and which call asked — `openDeepLink`, `openWebURL`, `openRichLanding`, `_link`, or
     `_link_new` for a link with `target="_blank"` — the web SDK's names, so the conformance cases read one way.
     */
    func open(_ url: String, via: String) -> Bool
    func copy(_ text: String, toast: String?) -> Bool
    func dial(_ number: String) -> Bool
    func sms(_ number: String, body: String?) -> Bool
    func share(_ text: String) -> Bool
    func settings(notifications: Bool) -> Bool
    func storeReview() -> Bool
    func alert(_ message: String)
    /// `getContext()`'s device half: locale, theme, insets.
    func context() -> [String: Any]
    func log(_ line: String)
    /// The server's answer to `claimReward(pool)` for this message: `{ won, prize?, code?, empty? }`, or
    /// a refusal — `not_available` for a pool the message does not name or that is gone, `offline` when it could not ask.
    func claimReward(_ pool: String, deliveryID: String, _ answer: @escaping ([String: Any]) -> Void)
    /// An app action from this message, for the app's `onAction` handlers: once its click has been recorded.
    func appAction(_ name: String, payload: [String: Any])
}

// MARK: - JSON as the page sends it

/*
 Arguments arrive through `JSONSerialization`, where a boolean is an `NSNumber` too — so `as? NSNumber` alone would
 read `true` as 1 and let `setUserAttribute('streak', true)` through as a number, and `trackRating(true)` as a rating.
 Every read below asks which one it is.
 */

private func isJSONBool(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
}

func jsonNumber(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, !isJSONBool(number) else { return nil }
    return number.doubleValue
}

/// A whole number as Kotlin's `toInt()` reads one, without the trap Swift's `Int(_:)` springs past `Int.max`.
private func jsonInt(_ value: Any?) -> Int? {
    guard let number = jsonNumber(value), number.isFinite else { return nil }
    return Int(max(Double(Int32.min), min(Double(Int32.max), number.rounded(.towardZero))))
}

private func jsonTrue(_ value: Any?) -> Bool {
    isJSONBool(value) && (value as? NSNumber)?.boolValue == true
}

/// `String(value)` as JavaScript writes it, for the calls that take text and are handed something else.
func jsText(_ value: Any?) -> String {
    switch value {
    case nil, is NSNull: return ""
    case let text as String: return text
    case let number as NSNumber where isJSONBool(number): return number.boolValue ? "true" : "false"
    case let number as NSNumber: return jsNumberText(number.doubleValue)
    default:
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

private let runsInPlace = pattern("^(?:javascript|vbscript|data|blob|file|filesystem):", .caseInsensitive)
private let controlOrSpace = pattern("[\\u0000- ]")

/// Whether a URL would run where it is opened, read as a browser reads one: control characters and spaces ignored.
private func runsWhereOpened(_ target: String) -> Bool {
    let squeezed = controlOrSpace.stringByReplacingMatches(
        in: target, range: NSRange(location: 0, length: (target as NSString).length), withTemplate: ""
    )
    return runsInPlace.test(squeezed)
}

/**
 One display of one HTML message: its bridge state and an answer for every call — `BridgeDisplay` in the web and
 Android SDKs, held to them by `bridge-conformance.json`. Every answer arrives through `call`'s `answer`, and every one
 is a value; a refusal is `{ ok: false, reason }`, never a thrown error, because a template's script cannot be
 counted on to catch one.

 Main thread only: the host receives every call there.
 */
final class BridgeDisplay {
    typealias Answer = (Any?) -> Void
    private typealias Handler = (BridgeDisplay, [Any], () -> Void, @escaping Answer) -> Void

    /// How long a press waits for the rest of its handler's calls before it is recorded, in milliseconds.
    static let clickWindowMs = 60.0
    static let ok: [String: Any] = ["ok": true]
    static func refuse(_ reason: String) -> [String: Any] { ["ok": false, "reason": reason] }

    private static let storedMaxKeys = 32
    private static let storedMaxBytes = 1024
    private static let name = pattern("^[A-Za-z_][A-Za-z0-9_.:-]{0,127}$")
    private static let storedKey = pattern("^[A-Za-z_][A-Za-z0-9_.:-]{0,63}$")
    private static let whole = pattern("^[1-9][0-9]*$")
    private static let email = pattern("^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$")
    private static let phone = pattern("^\\+?[0-9\\s().-]{6,20}$")
    /// An ISO 8601 date, with or without a time: what `setBirthDate` and `setUserAttributeDate` take.
    private static let isoDate = pattern("^[0-9]{4}-[0-9]{2}-[0-9]{2}([T ][0-9:.]+(Z|[+-][0-9]{2}:?[0-9]{2})?)?$")

    private let message: InAppMessage
    private let sdk: BridgeSdk
    /// How the press folding waits for the rest of a handler's calls: the main queue in the app, by hand in a test.
    private let later: (Double, @escaping () -> Void) -> Void
    private let declaredEvents: Set<String>
    private let declaredTraits: Set<String>
    private var dismissRecorded = false
    private(set) var screen: String?
    private var events = 0
    private var lastEvent: [String: Double] = [:]
    private var pending: PendingClick?
    /// What the campaign kept for the person, as synced, with this display's writes laid over it.
    private(set) var stored: [String: Any]

    private final class PendingClick {
        var fields: [String: Any]
        /// Handed to the app's click listener and never recorded: an app action's payload.
        var toldValues: [String: Any]?
        var then: [() -> Void] = []
        var leads = false

        init(fields: [String: Any]) {
            self.fields = fields
        }
    }

    init(message: InAppMessage, sdk: BridgeSdk, later: @escaping (Double, @escaping () -> Void) -> Void) {
        self.message = message
        self.sdk = sdk
        self.later = later
        let declared = message.content.in_app?.declared
        declaredEvents = Set((declared?.events ?? []).filter { !$0.isEmpty })
        declaredTraits = Set((declared?.traits ?? []).filter { !$0.isEmpty })
        stored = (message.stored ?? [:]).mapValues(\.any)
    }

    private func receipt() -> [String: Any] {
        var out = inAppReceipt(message)
        if let screen { out[InAppBridge.keyScreen] = screen }
        return out
    }

    /**
     A dismissal from anywhere — the page, the dim, the timer — recorded once per display.

     A press still waiting in its window is recorded, and handed to the app, first. A page that closes in the same tap
     it acts on — `customAction(…)` then `dismissMessage()`, as the Fawazeer message's Chat and purchase buttons do —
     used to lose the press here: the window's timer holds the display weakly, the display goes with the message, and
     the click and the custom action the app was waiting for went with it (2026-09-30).
     */
    func dismiss(element: String? = nil) {
        flushClick()
        recordDismiss(element)
        sdk.dismissed()
    }

    private func recordDismiss(_ element: String?) {
        guard !dismissRecorded else { return }
        dismissRecorded = true
        var properties = receipt()
        if let element { properties[InAppBridge.keyElement] = element }
        sdk.track("in_app_dismissed", properties)
    }

    /**
     A press, recorded once however many calls said so: `trackClick(1)` and `openWebURL(url)` from one handler are one
     press, folded into one `in_app_clicked` with the element, the destination and the screen it was pressed on. A
     handler's calls cross the bridge one after another within a millisecond or two; `clickWindowMs` waits for the rest.
     What the press leads to runs after it is recorded and flushed.
     */
    private func click(_ fields: [String: Any], then: (() -> Void)? = nil, leads: Bool = false, toldValues: [String: Any]? = nil) {
        let current: PendingClick
        if let pending {
            current = pending
        } else {
            var opening: [String: Any] = [:]
            if let screen { opening[InAppBridge.keyScreen] = screen }
            current = PendingClick(fields: opening)
            pending = current
            later(Self.clickWindowMs) { [weak self] in self?.flushClick() }
        }
        current.fields.merge(fields) { _, new in new }
        if let toldValues { current.toldValues = toldValues }
        if let then { current.then.append(then) }
        if leads { current.leads = true }
    }

    func flushClick() {
        guard let done = pending else { return }
        pending = nil
        let properties = inAppReceipt(message).merging(done.fields) { _, new in new }
        sdk.track("in_app_clicked", properties)
        let action = done.fields["action"] as? String ?? "click"
        let values = done.fields["values"] as? [String: Any] ?? done.toldValues ?? [:]
        sdk.clicked(action: action, values: values, fields: done.fields)
        if done.leads { sdk.spent() }
        if !done.then.isEmpty { sdk.flush() }
        done.then.forEach { $0() }
    }

    private func event(_ args: [Any]) -> [String: Any] {
        guard let name = arg(args, 0) as? String, Self.name.test(name), name != "undefined", name != "null" else {
            return Self.refuse("invalid_name")
        }
        if name.hasPrefix("in_app_") || TreebarsConstants.reservedEventNames.contains(name) { return Self.refuse("reserved") }
        guard declaredEvents.contains(name) else {
            sdk.log("in-app event \"\(name)\" is not declared in the message, so it was not recorded")
            return Self.refuse("undeclared")
        }
        let now = Date().timeIntervalSince1970 * 1000
        if let last = lastEvent[name], now - last < InAppBridge.repeatWindowMs { return Self.refuse("repeat") }
        guard events < InAppBridge.eventsPerDisplay else { return Self.refuse("limit") }
        events += 1
        lastEvent[name] = now
        // Location and date objects are properties like any other; the campaign is always attached.
        var properties: [String: Any] = [:]
        for index in [3, 2, 1] { properties.merge(Self.object(arg(args, index))) { _, new in new } }
        properties.merge(receipt()) { _, new in new }
        sdk.track(name, properties)
        return Self.ok
    }

    private func trait(_ name: String, _ value: Any?) -> [String: Any] {
        guard let value, !(value is NSNull) else { return Self.refuse("invalid_value") }
        return sdk.setTraits([name: value])
    }

    private func declaredTrait(_ name: Any?, _ value: Any?) -> [String: Any] {
        guard let name = name as? String, Self.name.test(name) else { return Self.refuse("invalid_name") }
        if InAppBridge.reservedTraits.contains(name) { return Self.refuse("reserved") }
        guard declaredTraits.contains(name) else { return Self.refuse("undeclared") }
        return trait(name, value)
    }

    private func optIn(_ kind: String, _ value: Any?) -> [String: Any] {
        let address = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard (kind == "email" ? Self.email : Self.phone).test(address) else { return Self.refuse("invalid_value") }
        var properties = receipt()
        properties[kind] = address
        sdk.track(InAppBridge.eventOptedIn, properties)
        return Self.ok
    }

    private static func url(_ value: Any?) -> String? {
        let target = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !target.isEmpty, !runsWhereOpened(target) else { return nil }
        return target
    }

    private static func location(_ latitude: Any?, _ longitude: Any?) -> [String: Any]? {
        guard let lat = jsonNumber(latitude), let lng = jsonNumber(longitude),
              lat.isFinite, lng.isFinite, abs(lat) <= 90, abs(lng) <= 180 else { return nil }
        return ["latitude": lat, "longitude": lng]
    }

    private func open(_ args: [Any], via: String, leads: Bool, answer: Answer) {
        guard let target = Self.url(arg(args, 0)) else { return answer(Self.refuse("invalid_url")) }
        click([InAppBridge.keyDestination: target], then: { [sdk] in _ = sdk.open(target, via: via) }, leads: leads)
        answer(Self.ok)
    }

    private func storeValue(_ key: Any?, _ value: Any?) -> [String: Any] {
        guard let key = key as? String, Self.storedKey.test(key) else { return Self.refuse("invalid_name") }
        let clean: Any? = value is NSNull ? nil : value
        if let clean {
            let scalar = clean is String || isJSONBool(clean) || (jsonNumber(clean)?.isFinite ?? false)
            guard scalar, jsText(Self.json(clean)).utf16.count <= Self.storedMaxBytes else { return Self.refuse("invalid_value") }
            if stored[key] == nil, stored.count >= Self.storedMaxKeys { return Self.refuse("limit") }
            stored[key] = clean
        } else {
            stored[key] = nil
        }
        sdk.keep(key: key, value: clean)
        // Kept on the server per campaign; a test send or a journey step has none, so it lasts this display only.
        guard message.campaign_id != nil else { return Self.refuse("no_campaign") }
        var properties = inAppReceipt(message)
        properties["key"] = key
        properties["value"] = clean ?? NSNull()
        sdk.track(InAppBridge.eventValueStored, properties)
        return Self.ok
    }

    /// A value's JSON text, which is what the server's size limit counts: `"abc"` with its quotes.
    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static let handlers: [String: Handler] = {
        var table: [String: Handler] = [:]
        // Said by the shim, and answered by the host before they arrive here.
        table["_ready"] = { _, _, _, answer in answer(ok) }
        table["resize"] = { _, _, _, answer in answer(ok) }
        table["_layout"] = { _, _, _, answer in answer(ok) }

        table["dismissMessage"] = { display, _, close, answer in
            close()
            display.dismiss()
            answer(ok)
        }
        table["trackDismiss"] = { display, args, _, answer in
            display.recordDismiss(widget(arg(args, 0)))
            answer(ok)
        }
        table["trackClick"] = { display, args, _, answer in
            let element = widget(arg(args, 0))
            var fields: [String: Any] = [:]
            if let element {
                fields[InAppBridge.keyElement] = element
                if whole.test(element), let index = Int(element) { fields[TreebarsConstants.inAppButtonIndexKey] = index }
            }
            display.click(fields)
            answer(ok)
        }
        table["trackRating"] = { display, args, _, answer in
            guard let rating = jsonNumber(arg(args, 0)), rating.isFinite else { return answer(refuse("invalid_value")) }
            var properties = display.receipt()
            properties["rating"] = rating
            display.sdk.track(InAppBridge.eventRated, properties)
            answer(ok)
        }
        table["trackEvent"] = { display, args, _, answer in answer(display.event(args)) }

        for method in ["identifyUser", "setUniqueId", "setAlias"] {
            table[method] = { _, _, _, answer in answer(refuse("identity_from_message")) }
        }

        table["setEmailId"] = { display, args, _, answer in answer(display.optIn("email", arg(args, 0))) }
        table["setMobileNumber"] = { display, args, _, answer in answer(display.optIn("phone", arg(args, 0))) }
        for (method, key) in [("setUserName", "name"), ("setFirstName", "first_name"), ("setLastName", "last_name")] {
            table[method] = { display, args, _, answer in answer(display.trait(key, arg(args, 0) as? String)) }
        }
        table["setGender"] = { display, args, _, answer in
            let value = arg(args, 0) as? String
            answer(["male", "female", "other"].contains(value ?? "") ? display.trait("gender", value) : refuse("invalid_value"))
        }
        table["setBirthDate"] = { display, args, _, answer in
            guard let value = arg(args, 0) as? String, isoDate.test(value) else { return answer(refuse("invalid_value")) }
            answer(display.trait("birth_date", value))
        }
        table["setUserLocation"] = { display, args, _, answer in
            guard let place = location(arg(args, 0), arg(args, 1)) else { return answer(refuse("invalid_value")) }
            answer(display.trait("location", place))
        }
        table["setUserAttribute"] = { display, args, _, answer in
            let value = arg(args, 1)
            guard value is String || value is NSNumber else { return answer(refuse("invalid_value")) }
            answer(display.declaredTrait(arg(args, 0), value))
        }
        table["setUserAttributeDate"] = { display, args, _, answer in
            guard let value = arg(args, 1) as? String, isoDate.test(value) else { return answer(refuse("invalid_value")) }
            answer(display.declaredTrait(arg(args, 0), value))
        }
        table["setUserAttributeLocation"] = { display, args, _, answer in
            guard let place = location(arg(args, 1), arg(args, 2)) else { return answer(refuse("invalid_value")) }
            answer(display.declaredTrait(arg(args, 0), place))
        }

        table["navigateToScreen"] = { display, args, _, answer in
            let screen = (arg(args, 0) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !screen.isEmpty else { return answer(refuse("invalid_value")) }
            let props = object(arg(args, 1))
            var values = props
            values["screen"] = screen
            display.click([InAppBridge.keyDestination: screen, "action": "navigate", "values": values], then: { [weak display] in
                display?.sdk.appAction(TreebarsConstants.appActionNavigate, payload: ["screen": screen, "props": props])
            })
            answer(ok)
        }
        table["appAction"] = { display, args, _, answer in
            guard let name = arg(args, 0) as? String, AppActions.isName(name) else { return answer(refuse("invalid_name")) }
            guard let payload = BridgeDisplay.appActionPayload(arg(args, 1)) else { return answer(refuse("invalid_value")) }
            guard payload.bytes <= TreebarsConstants.appActionPayloadMaxBytes else { return answer(refuse("too_large")) }
            // Recorded with its name and never its payload, which can carry a person's own ids; the delegate hears both.
            var told = payload.object
            told[TreebarsConstants.appActionNameKey] = name
            display.click(["action": "app_action", TreebarsConstants.appActionNameKey: name], then: { [weak display] in
                display?.sdk.appAction(name, payload: payload.object)
            }, toldValues: told)
            answer(ok)
        }
        table["openDeepLink"] = { display, args, _, answer in display.open(args, via: "openDeepLink", leads: true, answer: answer) }
        table["openRichLanding"] = { display, args, _, answer in display.open(args, via: "openRichLanding", leads: false, answer: answer) }
        table["openWebURL"] = { display, args, _, answer in display.open(args, via: "openWebURL", leads: true, answer: answer) }

        table["copyText"] = { display, args, _, answer in
            let toast = (arg(args, 1) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let done = display.sdk.copy(jsText(arg(args, 0)), toast: toast?.isEmpty == false ? toast : nil)
            answer(done ? ok : refuse("not_allowed"))
        }
        table["call"] = { display, args, _, answer in
            let number = (arg(args, 0) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            answer(!number.isEmpty && display.sdk.dial(number) ? ok : refuse("invalid_value"))
        }
        table["sms"] = { display, args, _, answer in
            let number = (arg(args, 0) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            answer(!number.isEmpty && display.sdk.sms(number, body: arg(args, 1) as? String) ? ok : refuse("invalid_value"))
        }
        table["share"] = { display, args, _, answer in answer(display.sdk.share(jsText(arg(args, 0))) ? ok : refuse("unsupported")) }
        table["customAction"] = { display, args, _, answer in
            display.click(["action": "custom", "values": object(arg(args, 0))])
            answer(ok)
        }
        for method in ["requestNotificationPermission", "showPushOptIn", "handleNotificationPopUp"] {
            table[method] = { display, _, _, answer in display.sdk.requestPushPermission { answer($0) } }
        }
        table["navigateToNotificationSettings"] = { display, _, _, answer in
            answer(display.sdk.settings(notifications: true) ? ok : refuse("unsupported"))
        }
        table["navigateToSettings"] = { display, _, _, answer in answer(display.sdk.settings(notifications: false) ? ok : refuse("unsupported")) }
        table["requestStoreReview"] = { display, _, _, answer in answer(display.sdk.storeReview() ? ok : refuse("unsupported")) }

        table["getContext"] = { display, _, _, answer in
            let direction = display.message.content.in_app?.direction
            var context = display.sdk.context()
            context["direction"] = direction == "rtl" || direction == "ltr" ? direction : "ltr"
            context["platform"] = "ios"
            context["screen"] = display.screen ?? NSNull()
            context["deliveryId"] = display.message.delivery_id
            context["campaignId"] = display.message.campaign_id ?? NSNull()
            context["bridgeVersion"] = InAppBridge.version
            context["preview"] = false
            answer(context)
        }
        table["claimReward"] = { display, args, _, answer in
            // A reward pool's name, in the one spelling a pool's name may take.
            guard let pool = arg(args, 0) as? String, pool.range(of: "^[a-z0-9]([a-z0-9_]{0,58}[a-z0-9])?$", options: .regularExpression) != nil else {
                return answer(refuse("invalid_name"))
            }
            display.sdk.claimReward(pool, deliveryID: display.message.delivery_id) { result in
                // Recorded as the page is told, so the report and the person agree; a refusal is not a play.
                if let won = result["won"] as? Bool {
                    var properties = display.receipt()
                    properties["pool"] = pool
                    properties["won"] = won
                    if let prize = result["prize"] as? String { properties["prize"] = prize }
                    display.sdk.track(InAppBridge.eventRewardClaimed, properties)
                }
                answer(result)
            }
        }
        table["getStoredValue"] = { display, args, _, answer in
            answer((arg(args, 0) as? String).flatMap { display.stored[$0] })
        }
        table["setStoredValue"] = { display, args, _, answer in answer(display.storeValue(arg(args, 0), arg(args, 1))) }

        table["_screen"] = { display, args, _, answer in
            guard let name = arg(args, 0) as? String else { return answer(refuse("invalid_value")) }
            display.screen = utf16Prefix(name, 128)
            var properties = display.receipt()
            properties["index"] = jsonInt(arg(args, 1)) ?? 0
            if let from = arg(args, 2) as? String { properties["from"] = from }
            properties["how"] = arg(args, 3) as? String ?? "jump"
            display.sdk.track(InAppBridge.eventScreenViewed, properties)
            answer(ok)
        }
        table["_complete"] = { display, args, _, answer in
            var properties = display.receipt()
            properties["screens_seen"] = jsonInt(arg(args, 0)) ?? 0
            display.sdk.track(InAppBridge.eventCompleted, properties)
            answer(ok)
        }
        // A quiz reached its result: its score, recorded here as every other `in_app_*` is.
        table["_quiz"] = { display, args, _, answer in
            var properties = display.receipt()
            properties["quiz"] = (arg(args, 0) as? String).map { String($0.prefix(64)) } ?? "quiz"
            properties["score"] = jsonNumber(arg(args, 1)) ?? 0
            properties["total"] = jsonNumber(arg(args, 2)) ?? 0
            display.sdk.track(InAppBridge.eventQuizCompleted, properties)
            answer(ok)
        }
        table["_submit"] = { display, args, _, answer in
            // Answers as a typed form sends them, text or a number, so a group of ticked boxes is kept.
            let answers = object(arg(args, 0)).mapValues { value -> Any in
                if let list = value as? [Any] { return list.map(jsText).joined(separator: ",") }
                if isJSONBool(value) { return jsText(value) }
                return value
            }
            let save = object(arg(args, 1))
            var properties = display.receipt()
            properties["responses"] = answers
            for kind in ["email", "phone"] {
                if let address = save[kind] as? String, !address.isEmpty { properties[kind] = address }
            }
            display.sdk.track("in_app_form_submitted", properties)
            let traits = save.filter { key, _ in
                key != "email" && key != "phone" && display.declaredTraits.contains(key) && !InAppBridge.reservedTraits.contains(key)
            }
            if !traits.isEmpty { _ = display.sdk.setTraits(traits) }
            display.sdk.flush()
            answer(ok)
        }
        table["_link"] = { display, args, close, answer in
            guard let action = (arg(args, 0) as? String).flatMap(readInAppHtmlAction) else { return answer(refuse("invalid_url")) }
            switch action {
            case .dismiss:
                close()
                display.dismiss()
            case .click(let index):
                display.click([InAppBridge.keyElement: String(index), TreebarsConstants.inAppButtonIndexKey: index])
            case .link(let url):
                let outside = jsonTrue(arg(args, 1))
                display.click(
                    [InAppBridge.keyDestination: url],
                    then: { [sdk = display.sdk] in _ = sdk.open(url, via: outside ? "_link_new" : "_link") },
                    leads: !outside
                )
            }
            answer(ok)
        }
        table["_alert"] = { display, args, _, answer in
            display.sdk.alert(jsText(arg(args, 0)))
            answer(ok)
        }
        return table
    }()

    /// The methods this display answers — held to the generated list for iOS by a test.
    static var methods: Set<String> { Set(handlers.keys) }

    /// One call from the page.
    func call(_ method: String, _ args: [Any], close: () -> Void, answer: @escaping Answer) {
        guard let handler = Self.handlers[method] else { return answer(Self.refuse("unsupported")) }
        handler(self, args, close, answer)
    }

    /// A widget id as a string: `0` stays `"0"`, nothing stays nothing.
    static func widget(_ value: Any?) -> String? {
        if let number = jsonNumber(value) { return number.isFinite ? jsNumberText(number) : nil }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return utf16Prefix(text, 128)
    }

    /**
     An app action's payload as the page sent it, with its size as JSON: nothing is empty, a JSON string is parsed, and
     anything but an object — a list, a number, text that is not JSON — is nil, which the call refuses.
     */
    static func appActionPayload(_ value: Any?) -> (object: [String: Any], bytes: Int)? {
        let object: [String: Any]
        switch value {
        case nil, is NSNull: object = [:]
        case let dictionary as [String: Any]: object = dictionary
        case let text as String:
            guard let data = text.data(using: .utf8), let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            object = parsed
        default: return nil
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return nil }
        return (object, data.count)
    }

    /// An object from a bridge argument: an object as it is, a JSON string parsed, anything else nothing.
    static func object(_ value: Any?) -> [String: Any] {
        if let object = value as? [String: Any] { return object }
        guard let text = value as? String, let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return parsed
    }
}

/// An argument, with JSON `null` read as nothing, as `args[i]` is on the web and `opt(i)` on Android.
private func arg(_ args: [Any], _ index: Int) -> Any? {
    guard index < args.count, !(args[index] is NSNull) else { return nil }
    return args[index]
}

/*
 * What a navigation out of a markup body means — `readInAppHtmlAction` in the web, Android and React Native SDKs, the
 * contract `treebars://` carries: the two verbs, or somewhere to go. A URL that would run where it is opened is
 * nothing.
 */
enum InAppHtmlAction: Equatable {
    case dismiss
    case click(Int)
    case link(String)
}

private let clickLink = pattern("^treebars://click/([0-9]+)$")

func readInAppHtmlAction(_ url: String) -> InAppHtmlAction? {
    let target = url.trimmingCharacters(in: .whitespacesAndNewlines)
    if target.isEmpty || target.hasPrefix("about:blank") || target == "#" { return nil }
    if runsWhereOpened(target) { return nil }
    if target == "treebars://dismiss" { return .dismiss }
    let text = target as NSString
    if let found = clickLink.firstMatch(in: target, range: NSRange(location: 0, length: text.length)),
       let index = Int(text.substring(with: found.range(at: 1))) {
        return .click(index)
    }
    return .link(target)
}

#if canImport(UIKit)

/**
 The window and the WKWebView for one HTML message, the iOS half of `bridge-host.ts`.

 - **A window of its own**, above the app's at `.normal + 1`, rather than a view controller presented over the app's:
   a presentation of ours would make the app's own `present` calls fail for as long as the message was up, and the
   app's navigation is not ours to hold.
 - **It paints nothing.** A stage message — a modal, a sheet, a full screen, a canvas — is a transparent WebView over
   the whole window, under the bars: the page draws its own scrim, card, corners and shadow, and closes itself from its
   own scrim. A strip — a banner, a nudge — is a transparent WebView at its edge, placed by `InAppHostEnv.stripBox`, and
   a touch outside the container's box (`_layout`) goes on to the app, so its shadow never blocks what is under it.
 - **The truth about the screen.** The environment (`InAppHostEnv`) is in the document and sent again on every layout —
   a rotation, a split view, the text size — and on every keyboard change, with the keyboard's own duration, so the page
   can move with it. The text scale is the body style's size against its default of 17.
 - **The document does not scroll; screens do.** The outer scroll view is off and held at zero, so WebKit revealing a
   focused field cannot slide the stage out from under the page's own keyboard handling.
 - **Hidden until laid out.** Drawn invisible, and shown — a stage on its first `_layout` or a second after `_ready`, a
   strip once its height is known — with `shown: true`, which starts the page's own entrance. Only then is it counted
   as displayed (`onShown`). While hidden every touch passes through to the app.
 - **Who may call.** One script message handler, `treebars`, held weakly and removed when the message closes; a call is
   taken only from the main frame and with this display's nonce.
 - **The WebView.** JavaScript on, a non-persistent data store (nothing of the app's, nothing kept), no second window,
   sound only on a tap (a muted video plays by itself), and every navigation after the first refused — links come
   through the shim, which the SDK opens. Loaded with no base URL, so the page has no origin of the app's.
 - **Closing.** The page carries its own way out. A dismissible message also closes on the accessibility escape gesture.
 */
@MainActor
final class InAppHtmlHost: NSObject, WKNavigationDelegate, WKUIDelegate {
    private static let readyTimeout: TimeInterval = 8
    /// How long a shown page has to lay itself out (a stage) or measure itself (a strip) before it is shown anyway.
    private static let layoutWait: TimeInterval = 1

    /**
     One non-persistent store for every message this process draws: nothing on disk, gone with the process. A store per
     display would cost a web content process per display — on the simulator, about 450 ms from draw to on screen for a
     message drawn right after another, against 40 on Android — because WebKit reuses and prewarms processes per store.
     Sharing it shares nothing a message can read: its document has no origin (no base URL), so it has no storage or
     cookies, and it may not fetch. What it does share is the image cache, which is the point of a warm one.
     */
    private static let dataStore = WKWebsiteDataStore.nonPersistent()

    /**
     A WebView made ahead of the display that will use it, while an HTML message is queued (`warm()`). On the simulator
     with the shared store, a new view takes about 590 ms from draw to on screen for the first message in a process and
     240 for the next, most of it WebKit starting a web content process; one made beforehand has started it. Android
     takes about 140 ms cold and 40 warm, and makes none.
     */
    private static var spare: WKWebView?
    /// The spare's own blank page has loaded. Until it has, the spare is not handed out: its navigation would be the
    /// first one the host's policy sees, allowed in place of the message's — which then never loads, and times out as
    /// `render_error`. A spare made a moment before the first draw at launch is the case this guards.
    private static let spareWatch = SpareWatch()

    private static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.allowsInlineMediaPlayback = true
        /*
         A muted video may play by itself; sound still waits for a tap. `.all` would leave a muted `autoplay` video on
         its first frame until touched, where Android's WebView plays it, so the same message would differ between the
         two. `.audio` holds back only what makes a noise, which is the part a person did not ask for.
         */
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        configuration.dataDetectorTypes = []
        return WKWebView(frame: .zero, configuration: configuration)
    }

    /// Makes the spare, once: called when a sync leaves an HTML message queued and after a display ends while one is.
    static func warm() {
        guard spare == nil else { return }
        let view = makeWebView()
        spareWatch.loaded = false
        view.navigationDelegate = spareWatch
        view.loadHTMLString("<!doctype html><title></title>", baseURL: nil)
        spare = view
    }

    /// The spare, if it is ready to be handed out; one still loading is let go, and the display makes its own.
    private static func takeSpare() -> WKWebView? {
        defer { spare = nil }
        guard let view = spare, spareWatch.loaded else { return nil }
        view.navigationDelegate = nil
        return view
    }

    /// Lets the spare go: nothing left to draw, in-app messages off, or memory short.
    static func cool() {
        spare = nil
    }

    private let message: InAppMessage
    private let content: InAppContent
    private let display: BridgeDisplay
    private let onShown: () -> Void
    private let onFailed: (String) -> Void
    /// The timer or the escape gesture closed it: recorded by the display.
    private let onPersonClosed: () -> Void
    private let customizer: ((WKWebView) -> Void)?
    /// The markup to draw: the body with its prefetched files inlined as `data:` URIs, prepared
    /// before the display was drawn (`InAppAssetCache.prepare`); the body as it came, otherwise.
    private let html: String
    private let nonce = BridgeDocument.nonce()
    /// Over the whole window (a modal, a sheet, a full screen, a canvas), or a strip at an edge (a banner, a nudge).
    private let stage: Bool
    /// A strip's edge.
    private let edge: String
    /// A strip inside the safe area — a nudge — rather than flush with its edge.
    private let floating: Bool
    private let dismissible: Bool
    private let statusBar: String?

    private var window: InAppHtmlWindow?
    private weak var previousKey: UIWindow?
    private var controller: InAppHtmlController?
    private var web: WKWebView?
    private var loaded = false
    private var ready = false
    private var shown = false
    private(set) var closed = false
    /// A strip's height as the page reported it, its shadow room included.
    private var height: CGFloat?
    /// The container's box in the WebView, as the page last reported it (`_layout`).
    private var container: CGRect?
    /// How far the keyboard reaches up from the window's bottom edge, and how long its last move took.
    private var keyboard: (height: CGFloat, ms: Double) = (0, 0)
    /// The environment the page holds: the document's, then the last one sent. Sent again only when it differs.
    private var sentEnv: String?
    private var lastEnv: InAppEnv?
    private var timers: [DispatchWorkItem] = []
    private var observers: [NSObjectProtocol] = []
    private var pin: NSKeyValueObservation?

    init(
        message: InAppMessage,
        content: InAppContent,
        tokens: InAppTokens?,
        display: BridgeDisplay,
        onShown: @escaping () -> Void,
        onFailed: @escaping (String) -> Void,
        onPersonClosed: @escaping () -> Void,
        customizer: ((WKWebView) -> Void)?,
        html: String? = nil
    ) {
        self.message = message
        self.content = content
        self.html = html ?? content.html ?? ""
        self.display = display
        self.onShown = onShown
        self.onFailed = onFailed
        self.onPersonClosed = onPersonClosed
        self.customizer = customizer
        // The presentation Treebars wrote beside the markup; a message without one is read from its layout.
        let presentation = content.presentation
        let strip = content.layout == "banner" || content.layout == "nudge"
        if let mode = presentation?.mode, mode == "stage" || mode == "strip" {
            stage = mode == "stage"
        } else {
            stage = !strip
        }
        floating = presentation?.floating ?? (content.layout == "nudge")
        edge = presentation?.edge ?? (content.position == "top" ? "top" : "bottom")
        dismissible = presentation?.dismissible ?? (content.dismissible != false)
        statusBar = presentation?.status_bar
    }

    /// The scene the app is showing, or nil when it is showing none.
    static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first { $0.activationState == .foregroundInactive }
    }

    /// A nudge: a strip that floats inside the safe area and stacks with the others at its edge.
    private var isNudge: Bool { !stage && floating }

    func show(in scene: UIWindowScene) {
        let appWindow = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
        previousKey = appWindow
        let bounds = appWindow?.bounds ?? scene.coordinateSpace.bounds
        let safe = appWindow?.safeAreaInsets ?? .zero
        // The document carries the screen as it is now; the first layout of the window sends any difference.
        let first = environment(in: bounds, safe: safe, frame: stage ? nil : frame(in: bounds, safe: safe), traits: appWindow?.traitCollection ?? scene.traitCollection)
        sentEnv = InAppHostEnv.json(first)
        lastEnv = first
        let document = BridgeDocument.build(html, nonce: nonce, direction: content.direction, env: first)

        let view = Self.takeSpare() ?? Self.makeWebView()
        // Live on the view's controller, which the spare's configuration shares: added now, for this display's nonce.
        view.configuration.userContentController.add(WeakScriptHandler(self), name: "treebars")
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        // The page lays itself out under the bars, with the insets to pad by; WebKit adding its own would count twice.
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.bounces = false
        view.scrollView.isScrollEnabled = false
        view.scrollView.showsVerticalScrollIndicator = false
        view.scrollView.showsHorizontalScrollIndicator = false
        /*
         Held at the top. WebKit scrolls the document itself to reveal a focused field, whatever `isScrollEnabled` says,
         and a stage that slides under the keyboard's own handling in the page ends up twice as far up as it should be.
         */
        pin = view.scrollView.observe(\.contentOffset, options: [.new]) { scroll, _ in
            MainActor.assumeIsolated {
                if scroll.contentOffset != .zero { scroll.contentOffset = .zero }
            }
        }
        view.navigationDelegate = self
        view.uiDelegate = self
        web = view

        let controller = InAppHtmlController(web: view, host: self)
        self.controller = controller
        controller.view.alpha = 0

        let window = InAppHtmlWindow(windowScene: scene)
        /*
         A nudge sits a half level lower than a modal, so a modal is drawn over nudges; it
         stacks at its edge with the others (`nudges`), inside the safe area.
         */
        window.windowLevel = isNudge ? UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 0.5) : .normal + 1
        if isNudge { Self.nudges.append(self) }
        window.backgroundColor = .clear
        window.rootViewController = controller
        window.passes = { [weak self] hit, point in self?.passes(hit, at: point) ?? true }
        // VoiceOver stays in a stage message, as it stays in any modal; a strip leaves the app readable around it.
        window.accessibilityViewIsModal = stage
        self.window = window

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.keyboardMoved(note, hiding: false) }
            },
            center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.keyboardMoved(note, hiding: true) }
            },
            center.addObserver(forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.laidOut() }
            },
        ]

        runCustomizer(view)
        view.loadHTMLString(document, baseURL: nil)
        window.isHidden = false
        // A page that never says it is running is taken down unseen, as a render failure.
        after(Self.readyTimeout) { [weak self] in
            guard let self, !self.ready, !self.closed else { return }
            self.destroy()
            self.onFailed("render_error")
        }
    }

    private func runCustomizer(_ view: WKWebView) {
        guard let customizer else { return }
        customizer(view)
        // The app may change the WebView; the bridge, who may navigate and the scrolling stay this SDK's.
        view.navigationDelegate = self
        view.uiDelegate = self
        view.scrollView.isScrollEnabled = false
    }

    /// Whether a touch at this point of the window goes on to the app: every one while the message is hidden, none on a
    /// stage, and on a strip every one outside the container's box — its shadow room and the window around it.
    private func passes(_ hit: UIView, at point: CGPoint) -> Bool {
        if !shown || closed { return true }
        if stage { return false }
        guard let web, let window else { return true }
        let local = web.convert(point, from: window)
        guard web.bounds.contains(local) else { return true }
        guard let container else { return false }
        return !container.contains(local)
    }

    /// The nudges drawn, oldest first: where each sits in its edge's stack comes from the ones before it.
    private static var nudges: [InAppHtmlHost] = []

    /// The window's safe area: the window covers the scene, so these are the scene's.
    private var windowSafe: UIEdgeInsets {
        (window ?? previousKey)?.safeAreaInsets ?? .zero
    }

    /// This strip's box in a window of this size, after the nudges shown before it at its edge.
    private func frame(in bounds: CGRect, safe: UIEdgeInsets) -> CGRect {
        if stage { return bounds }
        let offset = isNudge
            ? Self.nudges.prefix { $0 !== self }.filter { $0.shown && !$0.closed && $0.edge == edge }.reduce(0.0) { $0 + $1.ownHeight(in: bounds, safe: safe) }
            : 0
        let box = InAppHostEnv.stripBox(width: bounds.width, height: bounds.height, safe: HostInsets(safe), edge: edge, floating: floating,
                                        contentHeight: height.map(Double.init), offset: offset)
        return CGRect(x: box.x, y: box.y, width: box.w, height: box.h)
    }

    /// This strip's height as laid out: what the page reported, up to its cap.
    private func ownHeight(in bounds: CGRect, safe: UIEdgeInsets) -> Double {
        InAppHostEnv.stripBox(width: bounds.width, height: bounds.height, safe: HostInsets(safe), edge: edge, floating: floating,
                              contentHeight: height.map(Double.init)).h
    }

    /// Where the WebView goes, asked by the controller on every layout.
    fileprivate func webFrame(in bounds: CGRect) -> CGRect {
        frame(in: bounds, safe: windowSafe)
    }

    private func environment(in bounds: CGRect, safe: UIEdgeInsets, frame: CGRect?, traits: UITraitCollection) -> InAppEnv {
        InAppHostEnv.env(
            host: "ios",
            device: UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "phone",
            theme: traits.userInterfaceStyle == .dark ? "dark" : "light",
            textScale: Double(UIFontMetrics.default.scaledValue(for: 17, compatibleWith: traits) / 17),
            shown: shown,
            width: bounds.width,
            height: bounds.height,
            safe: HostInsets(safe),
            frame: frame.map { HostRect(x: $0.minX, y: $0.minY, w: $0.width, h: $0.height) },
            keyboardHeight: keyboard.height,
            keyboardMs: keyboard.ms
        )
    }

    /// The window was laid out again — a turn, a split view, a strip's new height — or the text size changed: the page
    /// is told the screen as it is now.
    fileprivate func laidOut() {
        guard !closed, let controller, let web else { return }
        let bounds = controller.view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let env = environment(in: bounds, safe: windowSafe, frame: stage ? nil : web.frame, traits: controller.traitCollection)
        lastEnv = env
        send(env)
    }

    private func send(_ env: InAppEnv) {
        // Before the page says it is running there is no shim to tell: `_ready` sends whatever changed meanwhile.
        guard ready, !closed else { return }
        let text = InAppHostEnv.json(env)
        guard text != sentEnv, let quoted = try? JSONEncoder().encode(text) else { return }
        sentEnv = text
        evaluate("window.__treebarsEnv&&window.__treebarsEnv(\(String(decoding: quoted, as: UTF8.self)))")
    }

    /**
     The keyboard moved. What the page is told is how far it reaches up from the bottom of the window, and only when it
     is docked there: a floating or split iPad keyboard covers nothing the page should move for, and a hardware keyboard
     leaves only its shortcut bar, which is what it covers.
     */
    private func keyboardMoved(_ note: Notification, hiding: Bool) {
        guard !closed, let view = controller?.view, let space = view.window?.screen.coordinateSpace else { return }
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0
        var overlap: CGFloat = 0
        if !hiding, let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue {
            let frame = view.convert(end, from: space)
            let bounds = view.bounds
            if frame.maxY >= bounds.maxY - 1, frame.width >= bounds.width - 1, frame.minY < bounds.maxY {
                overlap = bounds.maxY - frame.minY
            }
        }
        keyboard = (overlap, duration * 1000)
        laidOut()
    }

    fileprivate func receive(_ body: Any, isMainFrame: Bool) {
        guard !closed, isMainFrame, let text = body as? String, let data = text.data(using: .utf8),
              let call = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              call["tb"] as? String == nonce, let id = jsonNumber(call["id"]) else { return }
        let method = call["method"] as? String ?? ""
        let args = call["args"] as? [Any] ?? []
        switch method {
        case "_ready":
            if !ready {
                ready = true
                // A turn, a keyboard or a new size while the page was loading reached no shim: said now.
                if let lastEnv { send(lastEnv) }
                after(Self.layoutWait) { [weak self] in self?.reveal() }
            }
            reply(id, BridgeDisplay.ok)
        case "_layout":
            if let box = (args.first as? [String: Any])?["container"] as? [String: Any],
               let x = jsonNumber(box["x"]), let y = jsonNumber(box["y"]), let w = jsonNumber(box["w"]), let h = jsonNumber(box["h"]),
               [x, y, w, h].allSatisfy(\.isFinite), w >= 0, h >= 0 {
                container = CGRect(x: x, y: y, width: w, height: h)
                // A stage is laid out once the page says where its container is.
                if stage, ready { reveal() }
            }
            reply(id, BridgeDisplay.ok)
        case "resize":
            if let value = jsonNumber(args.first), value.isFinite, value >= 0, !stage {
                height = CGFloat(value)
                controller?.view.setNeedsLayout()
                // A nudge's height moves the ones stacked after it.
                if isNudge { for other in Self.nudges where other !== self { other.controller?.view.setNeedsLayout() } }
                if ready { reveal() }
            }
            reply(id, BridgeDisplay.ok)
        default:
            guard InAppBridge.hostMethods.contains(method) else { return reply(id, BridgeDisplay.refuse("unsupported")) }
            display.call(method, args, close: { [weak self] in self?.destroy() }) { [weak self] result in self?.reply(id, result) }
        }
    }

    private func reply(_ id: Double, _ result: Any?) {
        var payload: [String: Any] = ["tb": nonce, "reply": id, "result": result ?? NSNull()]
        if !JSONSerialization.isValidJSONObject(payload) { payload["result"] = BridgeDisplay.refuse("error") }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let quoted = try? JSONEncoder().encode(String(decoding: data, as: UTF8.self)) else { return }
        evaluate("window.__treebarsReply(\(String(decoding: quoted, as: UTF8.self)))")
    }

    private func evaluate(_ script: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            self.web?.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    private func reveal() {
        guard !shown, !closed, let window, let controller else { return }
        if isNudge {
            // One that would take its edge past its share of the window waits instead, taken down unspent.
            let bounds = window.bounds
            let safe = windowSafe
            let taken = Self.nudges.filter { $0 !== self && $0.shown && !$0.closed && $0.edge == edge }.reduce(0.0) { $0 + $1.ownHeight(in: bounds, safe: safe) }
            if taken + ownHeight(in: bounds, safe: safe) > Double(bounds.height) * InAppBridge.nudgeStackShare {
                destroy()
                onFailed("no_room")
                return
            }
        }
        shown = true
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        // `shown` in the environment starts the page's own entrance; nothing of ours fades.
        laidOut()
        controller.view.alpha = 1
        controller.setNeedsStatusBarAppearanceUpdate()
        // A strip leaves the keyboard with the app; a stage takes it, so its own fields can type.
        if stage { window.makeKey() }
        onShown()
        if let seconds = content.display?.auto_dismiss_seconds, seconds > 0 {
            after(TimeInterval(seconds)) { [weak self] in self?.personClosed() }
        }
    }

    private func personClosed() {
        guard !closed else { return }
        destroy()
        onPersonClosed()
    }

    /// The accessibility escape gesture: a dismissible message closes, as the person asked.
    fileprivate func escape() -> Bool {
        guard dismissible, shown, !closed else { return false }
        personClosed()
        return true
    }

    /// The status bar's text and icons over the message: as the message says, or as the app has them.
    fileprivate func statusBarStyle() -> UIStatusBarStyle {
        switch statusBar {
        case "light": return .lightContent
        case "dark": return .darkContent
        default:
            var front = previousKey?.rootViewController
            while let next = front?.presentedViewController { front = next }
            while let child = front?.childForStatusBarStyle { front = child }
            return front?.preferredStatusBarStyle ?? .default
        }
    }

    private func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        let item = DispatchWorkItem(block: work)
        timers.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// The insets the page holds now, for `getContext()`.
    func currentInsets() -> BridgeInsets {
        lastEnv?.safe ?? BridgeInsets(windowSafe)
    }

    func isNight() -> Bool {
        (window ?? previousKey)?.traitCollection.userInterfaceStyle == .dark
    }

    /// Where a sheet or an alert the page asked for is presented from: the message while it is up, else the app.
    func presenter() -> UIViewController? {
        if let controller, !closed {
            var front: UIViewController = controller
            while let next = front.presentedViewController { front = next }
            return front
        }
        return nil
    }

    /// Takes it all down, quietly: whoever called says what it meant.
    func destroy() {
        guard !closed else { return }
        closed = true
        timers.forEach { $0.cancel() }
        timers = []
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        pin?.invalidate()
        pin = nil
        if let web {
            web.configuration.userContentController.removeScriptMessageHandler(forName: "treebars")
            web.stopLoading()
            web.navigationDelegate = nil
            web.uiDelegate = nil
        }
        web = nil
        let wasKey = window?.isKeyWindow == true
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        controller = nil
        if wasKey { previousKey?.makeKey() }
        // The nudges after it at its edge close the gap it leaves.
        if isNudge {
            Self.nudges.removeAll { $0 === self }
            for other in Self.nudges { other.controller?.view.setNeedsLayout() }
        }
    }

    // MARK: WKNavigationDelegate, WKUIDelegate

    /// The document this host loaded, and nothing after it: every later navigation is the page trying to leave.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if !loaded, navigationAction.targetFrame?.isMainFrame == true {
            loaded = true
            return decisionHandler(.allow)
        }
        TreebarsLogger.log("in-app: \(message.delivery_id) tried to navigate; refused")
        decisionHandler(.cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !closed else { return }
        destroy()
        onFailed("render_error")
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        // The shim routes `alert()` to `_alert`; one that reached WebKit anyway is answered rather than left hanging.
        completionHandler()
    }
}

extension HostInsets {
    init(_ safe: UIEdgeInsets) {
        self.init(top: Double(safe.top), right: Double(safe.right), bottom: Double(safe.bottom), left: Double(safe.left))
    }
}

/**
 What a press can ask of the device beyond a link: dial a number, copy a text, share one, and ask
 for the store's review sheet. One place for the HTML bridge's `call`, `copyText`, `share` and `requestStoreReview` and a
 typed button's `call`, `copy`, `share` and `store_review` — the same act, so it is written once. Kotlin's
 `DeviceActions` is the Android half.
 */
@MainActor
enum DeviceActions {
    nonisolated static func encoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    @discardableResult
    static func dial(_ number: String) -> Bool {
        guard let url = URL(string: "tel:\(encoded(number.filter { !$0.isWhitespace }))") else { return false }
        UIApplication.shared.open(url)
        return true
    }

    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }

    static func share(_ text: String, from: UIViewController) {
        let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = from.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: from.view.bounds.midX, y: from.view.bounds.midY, width: 0, height: 0)
        from.present(sheet, animated: true)
    }

    private static var shareWindow: UIWindow?

    /**
     The share sheet in a window of its own, for a typed button's `share`. That message is drawn by the app's own
     renderer — in React Native, a `Modal`, which is a presented controller — and it closes as its press arrives here: a
     sheet presented on the front controller would be presented on the closing modal and go down with it, so the press
     would record a click and show nothing. Its own window is outside whatever the app is dismissing, as `InAppToast`'s
     is; it goes when the sheet does, and the app's window is key again.
     */
    @discardableResult
    static func shareInOwnWindow(_ text: String) -> Bool {
        guard let scene = InAppHtmlHost.activeScene() else { return false }
        let previous = scene.windows.first(where: \.isKeyWindow)
        shareWindow?.isHidden = true
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert
        window.backgroundColor = .clear
        let root = UIViewController()
        root.view.backgroundColor = .clear
        window.rootViewController = root
        window.makeKeyAndVisible()
        shareWindow = window
        let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = root.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 0, height: 0)
        sheet.completionWithItemsHandler = { _, _, _, _ in
            guard shareWindow === window else { return }
            window.isHidden = true
            shareWindow = nil
            previous?.makeKey()
        }
        root.present(sheet, animated: true)
        return true
    }

    /// The App Store's own review sheet. iOS decides whether it shows at all (at most three times a year per app), and
    /// says nothing either way; a request that reached it counts as done.
    @discardableResult
    static func storeReview() -> Bool {
        guard let scene = InAppHtmlHost.activeScene() else { return false }
        if #available(iOS 16.0, *) {
            AppStore.requestReview(in: scene)
        } else {
            SKStoreReviewController.requestReview(in: scene)
        }
        return true
    }
}

/**
 A copy's confirmation (`copyText(text, toast)`): a line at the foot of the screen for two seconds, in a window of its
 own above the message, so it outlives a message the same press closed. iOS has no toast; this is the smallest one.
 */
@MainActor
enum InAppToast {
    private static var window: UIWindow?

    static func show(_ text: String) {
        guard let scene = InAppHtmlHost.activeScene() else { return }
        window?.isHidden = true
        let shown = UIWindow(windowScene: scene)
        shown.windowLevel = .alert + 1
        shown.isUserInteractionEnabled = false
        shown.backgroundColor = .clear
        let root = UIViewController()
        root.view.backgroundColor = .clear
        shown.rootViewController = root

        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.numberOfLines = 0
        label.textAlignment = .center
        let pill = UIView()
        pill.backgroundColor = UIColor(white: 0.1, alpha: 0.9)
        pill.layer.cornerRadius = 18
        pill.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        root.view.addSubview(pill)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -9),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -16),
            pill.centerXAnchor.constraint(equalTo: root.view.centerXAnchor),
            pill.widthAnchor.constraint(lessThanOrEqualTo: root.view.widthAnchor, constant: -48),
            pill.bottomAnchor.constraint(equalTo: root.view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
        shown.isHidden = false
        window = shown
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard window === shown else { return }
            UIView.animate(withDuration: 0.2, animations: { pill.alpha = 0 }) { _ in
                shown.isHidden = true
                if window === shown { window = nil }
            }
        }
    }
}

/// Says when the spare's blank page has finished loading, and nothing else.
@MainActor
private final class SpareWatch: NSObject, WKNavigationDelegate {
    var loaded = false

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
    }
}

/// A window that lets a touch go on to the app when its host says so: the HTML host's, and the native one's.
final class InAppHtmlWindow: UIWindow {
    /// The view the touch landed on and where, in the window's coordinates.
    var passes: (UIView, CGPoint) -> Bool = { _, _ in false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return passes(hit, point) ? nil : hit
    }
}

/// The WebView, at the whole window for a stage and at the strip's box for a strip, and nothing painted around it.
private final class InAppHtmlController: UIViewController {
    private let web: WKWebView
    private weak var host: InAppHtmlHost?

    init(web: WKWebView, host: InAppHtmlHost) {
        self.web = web
        self.host = host
        super.init(nibName: nil, bundle: nil)
        // A theme switched while the message is up reaches the page as the rest of the screen does.
        if #available(iOS 17.0, *) {
            registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self]) { (controller: InAppHtmlController, _) in
                controller.host?.laidOut()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .clear
        root.addSubview(web)
        view = root
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        web.frame = host?.webFrame(in: view.bounds) ?? view.bounds
        // Every layout — a turn, a split view, a strip's new height — tells the page the screen as it is now.
        host?.laidOut()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        host?.statusBarStyle() ?? .default
    }

    override func accessibilityPerformEscape() -> Bool {
        host?.escape() ?? false
    }
}

/// The page's one way in, held weakly: a WKUserContentController keeps its handlers, and a handler that kept the host
/// would keep the WebView that keeps the controller.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    private weak var host: InAppHtmlHost?

    init(_ host: InAppHtmlHost) {
        self.host = host
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        let isMainFrame = message.frameInfo.isMainFrame
        MainActor.assumeIsolated { host?.receive(body, isMainFrame: isMainFrame) }
    }
}

#endif
