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
     The document a message's WebView is handed: the web SDK's `bridgeDocument`, spelled in Swift. A
     fragment is framed as the preview frames it; a whole document stays one, the policy and shim straight after its
     doctype. The insets ride as CSS variables (`--tb-safe-top` …) as well, because a page written against them reads
     the same on every host, where `env(safe-area-inset-*)` is WebKit's alone. The device class hides every
     `data-tb-show` element not listed for it, in the document so it holds with scripts off. The
     orientation hides every `data-tb-orientation` element not for the way the device is held, in a rule of its own
     the host has the shim rewrite when the device turns.
     */
    static func build(_ html: String, host: String, nonce: String, direction: String?, insets: BridgeInsets?, device: String? = nil, orientation: String? = nil) -> String {
        let policy = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(escapeAttribute(InAppBridge.frameCSP))\">"
        let shim = "<script>\(InAppBridge.shim)({\"host\":\"\(host)\",\"nonce\":\"\(nonce)\"})</script>"
        let safe = insets.map {
            "<style>:root{--tb-safe-top:\($0.top)px;--tb-safe-right:\($0.right)px;--tb-safe-bottom:\($0.bottom)px;--tb-safe-left:\($0.left)px}</style>"
        } ?? ""
        let shown = device.map { ["mobile", "tablet", "desktop"].contains($0) ? "<style>[data-tb-show]:not([data-tb-show~=\"\($0)\"]){display:none!important}</style>" : "" } ?? ""
        let held = orientation.map { ["portrait", "landscape"].contains($0) ? "<style id=\"tb-orientation\">\(orientationRule($0))</style>" : "" } ?? ""
        let dir = direction == "rtl" && !authorDirection.test(html) ? "<html dir=\"rtl\">" : ""
        if isDocument.test(html) {
            // In UTF-16 units, as JavaScript's `slice` cuts, so a document opening with an emoji is cut where the web's is.
            let text = html as NSString
            let found = doctype.firstMatch(in: html, range: NSRange(location: 0, length: text.length))
            let head = found.map { text.substring(with: $0.range) } ?? "<!doctype html>"
            return "\(head)\(dir)\(policy)\(safe)\(shown)\(held)\(shim)\(text.substring(from: found?.range.length ?? 0))"
        }
        return "<!doctype html>\(dir)<meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1,viewport-fit=cover\">"
            + "\(policy)<style>\(InAppBridge.frameRules)</style>\(safe)\(shown)\(held)\(shim)\(html)"
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
    private func click(_ fields: [String: Any], then: (() -> Void)? = nil, leads: Bool = false) {
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
        if let then { current.then.append(then) }
        if leads { current.leads = true }
    }

    func flushClick() {
        guard let done = pending else { return }
        pending = nil
        let properties = inAppReceipt(message).merging(done.fields) { _, new in new }
        sdk.track("in_app_clicked", properties)
        let action = done.fields["action"] as? String ?? "click"
        let values = done.fields["values"] as? [String: Any] ?? [:]
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
            var values = object(arg(args, 1))
            values["screen"] = screen
            display.click([InAppBridge.keyDestination: screen, "action": "navigate", "values": values])
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
 - **Hidden until it runs.** Drawn invisible and shown when the shim says `_ready` — a fitted shape once its height is
   known too — and only then counted as displayed (`onShown`). While hidden, and outside a banner, every touch passes
   through to the app.
 - **Who may call.** One script message handler, `treebars`, held weakly and removed when the message closes; a call is
   taken only from the main frame and with this display's nonce.
 - **The WebView.** JavaScript on, a non-persistent data store (nothing of the app's, nothing kept), no second window,
   sound only on a tap (a muted video plays by itself), and every navigation after the first refused — links come
   through the shim, which the SDK opens. Loaded with no base URL, so the page has no origin of the app's.
 - **The container spec.** A modal is `min(width − 32, 420)` points wide and as tall as the content up to the window
   less 32; a banner is full width and up to 30% tall; a fullscreen is the window, drawing nothing of ours behind a
   `transparent` one. No padding of ours and no close control; a tap on the dim closes a dismissible message.
 */
@MainActor
final class InAppHtmlHost: NSObject, WKNavigationDelegate, WKUIDelegate {
    private static let readyTimeout: TimeInterval = 8
    private static let heightWait: TimeInterval = 1

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
    private let tokens: InAppTokens?
    private let display: BridgeDisplay
    private let onShown: () -> Void
    private let onFailed: (String) -> Void
    /// The dim or the timer closed it: recorded by the display.
    private let onPersonClosed: () -> Void
    private let customizer: ((WKWebView) -> Void)?
    /// The markup to draw: the body with its prefetched files inlined as `data:` URIs, prepared
    /// before the display was drawn (`InAppAssetCache.prepare`); the body as it came, otherwise.
    private let html: String
    private let nonce = BridgeDocument.nonce()
    private let shape: String
    private let transparent: Bool

    private var window: InAppHtmlWindow?
    private weak var previousKey: UIWindow?
    private var controller: InAppHtmlController?
    private var web: WKWebView?
    private var loaded = false
    private var ready = false
    private var shown = false
    private(set) var closed = false
    private var height: CGFloat?
    private var timers: [DispatchWorkItem] = []

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
        self.tokens = tokens
        self.display = display
        self.onShown = onShown
        self.onFailed = onFailed
        self.onPersonClosed = onPersonClosed
        self.customizer = customizer
        switch content.layout {
        case "banner", "fullscreen", "modal", "nudge": shape = content.layout
        case "html": shape = "fullscreen"
        default: shape = "modal"
        }
        transparent = shape == "fullscreen" && content.transparent == true
    }

    /// The scene the app is showing, or nil when it is showing none.
    static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first { $0.activationState == .foregroundInactive }
    }

    func show(in scene: UIWindowScene) {
        let appWindow = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
        previousKey = appWindow
        let safe = appWindow?.safeAreaInsets ?? .zero
        let insets = BridgeInsets(safe)
        // An iPad is a tablet: what `data-tb-show` is matched against.
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "mobile"
        // Landscape when the window is wider than it is tall, and followed as it turns (`windowResized`).
        let bounds = appWindow?.bounds ?? scene.coordinateSpace.bounds
        held = bounds.width > bounds.height ? "landscape" : "portrait"
        let document = BridgeDocument.build(html, host: "ios", nonce: nonce, direction: content.direction, insets: insets, device: device, orientation: held)

        let view = Self.takeSpare() ?? Self.makeWebView()
        // Live on the view's controller, which the spare's configuration shares: added now, for this display's nonce.
        view.configuration.userContentController.add(WeakScriptHandler(self), name: "treebars")
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        // The page lays itself out under the bars, with the insets to pad by; WebKit adding its own would count twice.
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.bounces = false
        view.navigationDelegate = self
        view.uiDelegate = self
        web = view

        let dim = tokens.flatMap { cssColor($0.backdrop) } ?? UIColor(white: 0, alpha: 0.5)
        let surface = tokens.flatMap { cssColor($0.surface) } ?? .white
        let controller = InAppHtmlController(
            web: view,
            dim: shape == "banner" || shape == "nudge" || transparent ? .clear : dim,
            surface: transparent ? .clear : surface,
            radius: shape == "modal" ? CGFloat(tokens?.radius ?? 16) : 0,
            closesOnDim: content.dismissible != false && shape != "banner" && shape != "nudge" && !transparent,
            layout: { [weak self] bounds in
                self?.windowResized(bounds.size)
                return self?.frame(in: bounds) ?? bounds
            },
            dimTapped: { [weak self] in self?.personClosed() }
        )
        self.controller = controller
        controller.view.alpha = 0

        let window = InAppHtmlWindow(windowScene: scene)
        /*
         A nudge sits a half level lower than a modal, so a modal is drawn over nudges; it
         stacks at its edge with the others (`nudges`), inside the safe area.
         */
        window.windowLevel = shape == "nudge" ? UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 0.5) : .normal + 1
        if shape == "nudge" { Self.nudges.append(self) }
        window.backgroundColor = .clear
        window.rootViewController = controller
        window.passes = { [weak self] hit in self?.passes(hit) ?? true }
        self.window = window

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

    /// The way the device was held when the document's orientation rule was last written.
    private var held = "portrait"
    /// The window's last laid-out size: a turn before the page was running is told once it is.
    private var lastSize: CGSize?

    /**
     The window was laid out again, which a turn of the device does: when it now runs the other way, the shim
     rewrites the orientation rule, so `data-tb-orientation` follows the phone rather than the moment it was drawn.
     */
    private func windowResized(_ size: CGSize) {
        guard !closed, size.width > 0, size.height > 0 else { return }
        lastSize = size
        // Before the page says it is running there is no shim to tell: `_ready` looks again (`lastSize`).
        guard ready else { return }
        let now = size.width > size.height ? "landscape" : "portrait"
        guard now != held else { return }
        held = now
        let script = "window.__treebarsOrientation&&window.__treebarsOrientation(\"\(now)\")"
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            self.web?.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    private func runCustomizer(_ view: WKWebView) {
        guard let customizer else { return }
        customizer(view)
        // The app may change the WebView; the bridge and who may navigate stay this SDK's.
        view.navigationDelegate = self
        view.uiDelegate = self
    }

    /// Whether a touch at this view goes on to the app: all of them while the message is hidden, and a banner's
    /// surroundings once it shows.
    private func passes(_ hit: UIView) -> Bool {
        if !shown || closed { return true }
        return (shape == "banner" || shape == "nudge") && (hit === window || hit === controller?.view || hit === controller?.dimView)
    }

    /// The nudges drawn, oldest first: where each sits in its edge's stack comes from the ones before it.
    private static var nudges: [InAppHtmlHost] = []

    /// This nudge's height as laid out: its content, up to a fifth of the window.
    private func nudgeHeight(in bounds: CGRect) -> CGFloat {
        let cap = bounds.height * InAppBridge.nudgeMaxHeightShare
        return min(height ?? cap, cap)
    }

    /// The nudges shown at this one's edge, other than it.
    private func edgeNeighbours() -> [InAppHtmlHost] {
        Self.nudges.filter { $0 !== self && $0.shown && !$0.closed && ($0.content.position == "top") == (content.position == "top") }
    }

    /// The container spec for this shape, in the window's bounds, with the content's height where it is fitted.
    private func frame(in bounds: CGRect) -> CGRect {
        switch shape {
        case "fullscreen":
            return bounds
        case "nudge":
            // Stacked after the ones already shown at its edge, newest nearest the middle, inside the safe area.
            let safe = window?.safeAreaInsets ?? .zero
            let tall = nudgeHeight(in: bounds)
            let before = Self.nudges.prefix { $0 !== self }
            let offset = before.filter { $0.shown && !$0.closed && ($0.content.position == "top") == (content.position == "top") }
                .reduce(CGFloat(0)) { $0 + $1.nudgeHeight(in: bounds) }
            let y = content.position == "top" ? safe.top + offset : bounds.height - safe.bottom - offset - tall
            return CGRect(x: 0, y: y, width: bounds.width, height: tall)
        case "banner":
            let cap = bounds.height * InAppBridge.bannerMaxHeightShare
            let tall = min(height ?? cap, cap)
            return CGRect(x: 0, y: content.position == "top" ? 0 : bounds.height - tall, width: bounds.width, height: tall)
        default:
            let gutter = InAppBridge.modalGutter
            let wide = min(bounds.width - gutter * 2, InAppBridge.modalMaxWidth)
            let cap = bounds.height - gutter * 2
            let tall = min(height ?? cap, cap)
            return CGRect(x: (bounds.width - wide) / 2, y: (bounds.height - tall) / 2, width: wide, height: tall)
        }
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
                // A turn while the page was loading reached no shim: say it now, if the device is held the other way.
                if let size = lastSize { windowResized(size) }
                if shape == "fullscreen" {
                    reveal()
                } else {
                    after(Self.heightWait) { [weak self] in self?.reveal() }
                }
            }
            reply(id, BridgeDisplay.ok)
        case "resize":
            if let value = jsonNumber(args.first), value.isFinite, value >= 0, shape != "fullscreen" {
                height = CGFloat(value)
                controller?.view.setNeedsLayout()
                // A nudge's height moves the ones stacked after it.
                if shape == "nudge" { for other in Self.nudges where other !== self { other.controller?.view.setNeedsLayout() } }
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
        let script = "window.__treebarsReply(\(String(decoding: quoted, as: UTF8.self)))"
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            self.web?.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    private func reveal() {
        guard !shown, !closed, let window, let controller else { return }
        if shape == "nudge" {
            // One that would take its edge past its share of the window waits instead, taken down unspent.
            let bounds = window.bounds
            let taken = edgeNeighbours().reduce(CGFloat(0)) { $0 + $1.nudgeHeight(in: bounds) }
            if taken + nudgeHeight(in: bounds) > bounds.height * InAppBridge.nudgeStackShare {
                destroy()
                onFailed("no_room")
                return
            }
        }
        shown = true
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        UIView.animate(withDuration: 0.2) { controller.view.alpha = 1 }
        // A banner or a nudge leaves the keyboard with the app; anything else takes it, so its own fields can type.
        if shape != "banner" && shape != "nudge" { window.makeKey() }
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

    private func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        let item = DispatchWorkItem(block: work)
        timers.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// The insets this display was drawn under, for `getContext()`.
    func currentInsets() -> BridgeInsets {
        let safe = (previousKey ?? window)?.safeAreaInsets ?? .zero
        return BridgeInsets(safe)
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
        if shape == "nudge" {
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

private let hexColor = pattern("^#([0-9a-fA-F]{6})([0-9a-fA-F]{2})?$")
private let rgbaColor = pattern("^rgba?\\(\\s*([0-9]{1,3})\\s*,\\s*([0-9]{1,3})\\s*,\\s*([0-9]{1,3})\\s*(?:,\\s*([0-9.]+)\\s*)?\\)$", .caseInsensitive)

/// A token's colour as the web writes it — `#rrggbb`, `#rrggbbaa` (alpha last) or `rgba(r, g, b, a)` — or nil.
private func cssColor(_ value: String) -> UIColor? {
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
    let range = NSRange(location: 0, length: text.length)
    if let found = hexColor.firstMatch(in: text as String, range: range) {
        let rgb = UInt32(text.substring(with: found.range(at: 1)), radix: 16) ?? 0
        let alpha = found.range(at: 2).location == NSNotFound ? 255 : UInt32(text.substring(with: found.range(at: 2)), radix: 16) ?? 255
        return UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                       blue: CGFloat(rgb & 0xFF) / 255, alpha: CGFloat(alpha) / 255)
    }
    guard let found = rgbaColor.firstMatch(in: text as String, range: range) else { return nil }
    let channel = { (index: Int) in CGFloat(min(255, Int(text.substring(with: found.range(at: index))) ?? 0)) / 255 }
    let alpha = found.range(at: 4).location == NSNotFound ? 1 : min(1, max(0, Double(text.substring(with: found.range(at: 4))) ?? 1))
    return UIColor(red: channel(1), green: channel(2), blue: channel(3), alpha: CGFloat(alpha))
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
    var passes: (UIView) -> Bool = { _ in false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return passes(hit) ? nil : hit
    }
}

/// The dim, the box with the container spec, and the WebView in it.
private final class InAppHtmlController: UIViewController {
    let dimView = UIView()
    private let box = UIView()
    private let web: WKWebView
    private let layoutBox: (CGRect) -> CGRect
    private let dimTapped: () -> Void

    init(web: WKWebView, dim: UIColor, surface: UIColor, radius: CGFloat, closesOnDim: Bool,
         layout: @escaping (CGRect) -> CGRect, dimTapped: @escaping () -> Void) {
        self.web = web
        layoutBox = layout
        self.dimTapped = dimTapped
        super.init(nibName: nil, bundle: nil)
        dimView.backgroundColor = dim
        box.backgroundColor = surface
        box.layer.cornerRadius = radius
        box.clipsToBounds = true
        if closesOnDim { dimView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped))) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .clear
        root.addSubview(dimView)
        root.addSubview(box)
        box.addSubview(web)
        view = root
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        dimView.frame = view.bounds
        box.frame = layoutBox(view.bounds)
        web.frame = box.bounds
    }

    @objc private func tapped() { dimTapped() }
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
