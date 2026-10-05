import Foundation

/*
 * In-app messages on the device.
 *
 * The part of this SDK that reads. Everything else posts events and forgets them;
 * this pulls a queue, holds it, and decides locally when each message may be shown —
 * which the server cannot decide for a screen view or a custom event, because only the
 * device knows those happened.
 *
 * The rules here are the same as the React Native and web SDKs, deliberately: a message
 * capped at three a day has to mean the same thing on every platform, and the failure
 * mode of a divergence is that nobody notices until two screenshots are compared.
 */

/*
 * Every type below decodes tolerantly.
 *
 * Swift's synthesized `Codable` throws the moment a non-optional field's key is missing, and
 * nothing here is ever decoded on its own: the sync decodes an ARRAY of messages, and the
 * notification centre a whole page, in one call each. So a throw is never "one bad message",
 * it is the whole document — one absent key would empty in-app and the notification centre
 * together, with nothing to look at but two empty lists.
 *
 * `InAppTokens` shows why. `style` is optional on both `InAppMessage` and
 * `TreebarsNotification`, so a message with NO style is fine — while a style carrying eight of
 * its nine tokens would, decoded strictly, be fatal to every other message beside it. A server
 * that stops sending one token, or a theme rolled back mid-flight, does exactly that.
 *
 * So a missing, null or wrong-typed field costs that field and nothing else. The default is
 * the empty one for its type, except where the Android SDK, which parses this JSON by hand,
 * makes the same decision — `radius` 8, `button_shape` "rounded" and `device_count` 1 — because
 * a theme that degrades differently on two platforms is the divergence nobody notices until two
 * screenshots are compared.
 *
 * Identity is the exception. `InAppMessage.delivery_id`, `TreebarsNotification.group_id` and
 * `CachedFeed.owner` stay required, because a default for any of them is a lie about which
 * message, which send, or whose feed — each says so where it is decoded. Requiring them is
 * only safe because the lists are decoded element by element, so a row with no id is dropped
 * and everything beside it still arrives.
 */

/**
 A value that can fail to decode without taking its container down with it.

 `[T]` stops at the first element that throws and yields nothing at all; `[Tolerated<T>]`
 cannot throw per element, so an unreadable row becomes `nil` and is dropped. Android does the
 same — every list there is a `mapNotNull` over rows — and it is the half that lets an identity field stay required without one id-less row costing a
 whole page.
 */
struct Tolerated<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// A missing key, an explicit `null` and a wrong-typed value all cost this one field.
    func tolerant<T: Decodable>(_ key: Key, or fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }

    /// The same, for a field whose absence the type already models.
    func tolerant<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    /// A list that drops the rows it cannot read, rather than becoming no list at all.
    func tolerantList<T: Decodable>(_ key: Key, of type: T.Type) -> [T] {
        tolerant(key, or: [Tolerated<T>]()).compactMap(\.value)
    }
}

public struct InAppTokens: Codable, Sendable {
    public let accent: String
    public let on_accent: String
    public let surface: String
    public let on_surface: String
    public let on_surface_muted: String
    public let backdrop: String
    public let radius: Double
    public let font_family: String
    public let button_shape: String
}

/*
 * The decoders live in extensions rather than in the type bodies, and that is not a style
 * choice: an initializer declared in a struct's own body suppresses the synthesized
 * memberwise one, which is the cost `InAppTrigger` below already pays deliberately. Written
 * here, every `InAppMessage(delivery_id:...)` in this SDK and in a host app's tests goes on
 * compiling untouched.
 */
extension InAppTokens {
    /**
     Nine tokens, all non-optional, decoded as part of `style` on a message — the shape in which
     one absent token would otherwise empty the whole sync.

     An empty colour is what a renderer already reads as "you decide", which is the honest
     answer when the server did not say. `radius` and `button_shape` are the two with a real
     default rather than an absent one, and both match `parseInAppTokens` in the Android SDK
     exactly, because these tokens describe the same card on both platforms.
     */
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accent = container.tolerant(.accent, or: "")
        on_accent = container.tolerant(.on_accent, or: "")
        surface = container.tolerant(.surface, or: "")
        on_surface = container.tolerant(.on_surface, or: "")
        on_surface_muted = container.tolerant(.on_surface_muted, or: "")
        backdrop = container.tolerant(.backdrop, or: "")
        radius = container.tolerant(.radius, or: 8)
        font_family = container.tolerant(.font_family, or: "")
        button_shape = container.tolerant(.button_shape, or: "rounded")
    }
}

/// A button's action is `dismiss`, `deep_link`, `url`, `track_event` (`event_name`), `set_attribute` (`key` and
/// `value`, on the signed-in person) or `custom` (`data`, handed to the app's action handler).
/// What was pressed in a message, as the app's delegate receives it: the button's action —
/// `url`, `deep_link`, `track_event`, `set_attribute`, `custom`, or `click` for a markup body's `treebars://click/<n>` —
/// and its values: a `custom` button's keys, or `["value": …]` for the rest.
public struct InAppClickAction: Sendable {
    public let type: String
    public let values: [String: String]
    public let button: InAppButton
}

/**
 The in-app delegate, its methods named as engagement SDKs commonly name them on iOS, so an app moving over keeps its
 call sites: a message shown, dismissed or pressed, and a self-handled message for
 the app to draw. Every method has a default, so an app implements the ones it wants. Called on the main actor.
 */
@MainActor
public protocol TreebarsInAppDelegate: AnyObject {
    func inAppShown(_ message: InAppMessage)
    func inAppDismissed(_ message: InAppMessage)
    /// Every press, after it is recorded; a `custom` button's keys arrive only here.
    func inAppClicked(_ message: InAppMessage, action: InAppClickAction)
    /// A message marked self-handled: the app draws it, and reports `selfHandledShown`, `selfHandledClicked` and
    /// `selfHandledDismissed`.
    func selfHandledInAppTriggered(_ message: InAppMessage)
    /// Whether self-handled messages come here instead of the renderer. True by default, so they are the
    /// delegate's; a delegate set only to hear presses answers false, and they are drawn like any other.
    var handlesSelfHandledInApps: Bool { get }
}

public extension TreebarsInAppDelegate {
    var handlesSelfHandledInApps: Bool { true }
    func inAppShown(_ message: InAppMessage) {}
    func inAppDismissed(_ message: InAppMessage) {}
    func inAppClicked(_ message: InAppMessage, action: InAppClickAction) {}
    func selfHandledInAppTriggered(_ message: InAppMessage) {}
}

public struct InAppButton: Codable, Sendable {
    public let label: String
    public let action: String
    public let value: String?
    public var event_name: String? = nil
    public var key: String? = nil
    public var data: [String: String]? = nil
    /// Which element this is, counting from 1: a typed button's position, or the `<n>` of a markup body's
    /// `treebars://click/<n>`. Reported on `in_app_clicked` as `button_index`, so the presses on a message with two
    /// buttons can be told apart.
    public var index: Int? = nil
}

/// When and how a message may be drawn beyond its trigger. An app reads `delay` and treats the web's other
/// on-site moments as at once; page and session rules are the web's alone. `auto_dismiss_seconds`, a form, a
/// carousel and a countdown are the app's renderer's to draw.
public struct InAppDisplay: Codable, Sendable {
    public var on: String? = nil
    public var delay_seconds: Int? = nil
    public var contexts: [String]? = nil
    public var priority: Int? = nil
    public var auto_dismiss_seconds: Int? = nil
    public var self_handled: Bool? = nil
    /// Shown only to people the app can still ask for push: see `pushAskableBlock`.
    public var only_when_push_askable: Bool? = nil
}

/// A nudge: drawn in a slot of its own beside the one a modal takes, at most
/// `InAppBridge.nudgeMaxOnScreen` on screen, and outside the channel's caps — it neither waits on them nor spends them, so
/// a nudge never holds back the modal the caps were set for. Its own `max_displays`, expiry and dismissal end it.
func isNudge(_ message: InAppMessage) -> Bool { message.content.in_app?.layout == "nudge" }

/// The nudges on screen, by delivery: `PresentationSlot` for up to three at once, claimed and
/// released under one lock for the reason that slot is.
final class NudgeSlots: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var held: [String] = []
    /// Of those, the ones drawn and not yet on screen: a nudge is counted when shown, and three drawn by one
    /// event are three before any of them reports, so the nudge caps count these too. Every release clears one.
    private var unshown: Set<String> = []

    init(capacity: Int) { self.capacity = capacity }

    func claim(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !held.contains(id), held.count < capacity else { return false }
        held.append(id)
        unshown.insert(id)
        return true
    }

    func shown(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        unshown.remove(id)
    }

    var inFlight: Int {
        lock.lock(); defer { lock.unlock() }
        return unshown.count
    }

    func release(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        held.removeAll { $0 == id }
        unshown.remove(id)
    }

    func holds(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return held.contains(id)
    }

    var hasRoom: Bool {
        lock.lock(); defer { lock.unlock() }
        return held.count < capacity
    }

    @discardableResult
    func clear() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let all = held
        held = []
        unshown = []
        return all
    }
}

/// Where a screen allowed nudges (`showNudge(atPosition:)`), in the words engagement SDKs commonly use on iOS.
@objc public enum TreebarsNudgePosition: Int, Sendable {
    case any, top, bottom

    /// Whether a nudge set to `edge` may show where this was allowed.
    func admits(_ edge: String?) -> Bool {
        switch self {
        case .any: return true
        case .top: return edge == "top"
        case .bottom: return edge != "top"
        }
    }
}

/// Why a message shown only to people who can still be asked for push is held back from this person, or nil.
/// `status` is the vocabulary every core shares — here `DeviceInfo`'s read of
/// `UNNotificationSettings`, refreshed just before the look; which of its words can still be asked is
/// `pushAskableStatuses`, generated from one list for all three cores. `.provisional` can: it delivers quietly and the
/// app may still ask for alerts. `.denied` cannot: iOS never shows its prompt twice, so a primer there asks nothing.
/// Held back, never spent — permission changes in Settings, so the next look asks again.
func pushAskableBlock(_ display: InAppDisplay?, status: String?) -> String? {
    guard display?.only_when_push_askable == true else { return nil }
    guard let status, TreebarsConstants.pushAskableStatuses.contains(status) else { return "push_answered" }
    return nil
}

extension InAppDisplay {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        on = container.tolerant(.on)
        delay_seconds = container.tolerant(.delay_seconds)
        contexts = container.tolerant(.contexts)
        priority = container.tolerant(.priority)
        auto_dismiss_seconds = container.tolerant(.auto_dismiss_seconds)
        self_handled = container.tolerant(.self_handled)
        only_when_push_askable = container.tolerant(.only_when_push_askable)
    }
}

/// A field of an in-app form. `kind` is text, textarea, email, phone, number, date (YYYY-MM-DD), choice,
/// dropdown, multi_choice (the picks joined by commas), rating or nps; `placeholder` is what an empty box says, and
/// `trait` keeps the answer on the signed-in person when the message declares it. Declared here
/// because the store and the React Native bridge re-encode this struct, and a key it does not name is dropped.
public struct InAppFormField: Codable, Sendable {
    public var id: String = ""
    public var kind: String = "text"
    public var label: String = ""
    public var required: Bool? = nil
    public var options: [String]? = nil
    public var placeholder: String? = nil
    public var save_as: String? = nil
    public var trait: String? = nil
}

/**
 What a sent form keeps beyond its answers: an email or phone field marked `save_as`, as the address the server attaches
 as an opt-in; and an answer kept as a trait — only a trait the message declares, and never one of the SDK's reserved
 traits (`InAppBridge.reservedTraits`). The web's and Kotlin's `formKeeps`, and the rule a markup form's `data-tb-save`
 is held to (`_submit`).
 */
func formKeeps(_ content: InAppContent?, responses: [String: Any]) -> (addresses: [String: String], traits: [String: Any]) {
    let declared = Set(content?.declared?.traits ?? [])
    var addresses: [String: String] = [:]
    var traits: [String: Any] = [:]
    for field in content?.form?.fields ?? [] {
        guard let answer = responses[field.id], (answer as? String) != "" else { continue }
        if let saveAs = field.save_as, saveAs == "email" || saveAs == "phone", let value = answer as? String { addresses[saveAs] = value }
        if let trait = field.trait, declared.contains(trait), !InAppBridge.reservedTraits.contains(trait) { traits[trait] = answer }
    }
    return (addresses, traits)
}

public struct InAppForm: Codable, Sendable {
    public var fields: [InAppFormField] = []
    public var submit_label: String? = nil
    public var thanks: String? = nil
}

/// An inbox row drawn as a card. `basic` is an icon beside the words, `illustration` a wide image above them;
/// `action` is where a tap goes, `image_alt` is read aloud for the image, `pinned` keeps it first, `show_from` hides it
/// until then, `category` groups cards into a centre's tabs.
public struct InAppCard: Codable, Sendable {
    public struct Action: Codable, Sendable {
        public var type: String = ""
        public var value: String = ""
    }
    public var template: String = "basic"
    public var icon_url: String? = nil
    public var image_alt: String? = nil
    public var action: Action? = nil
    public var pinned: Bool? = nil
    public var show_from: String? = nil
    public var category: String? = nil
    /// A button on the card apart from a tap on it: its words, and where it goes.
    public struct Cta: Codable, Sendable {
        public var label: String = ""
        public var action: Action = Action()
    }
    public var cta: Cta? = nil
    /// Gone this many days after it was first seen; the server leaves it out of the next sync after that.
    public var expires_after_seen_days: Int? = nil
}

/// One card of an in-app carousel.
public struct InAppSlide: Codable, Sendable {
    public var image_url: String = ""
    /// What the image shows, for VoiceOver: the app's renderer reads it as the image's label.
    public var image_alt: String? = nil
    public var title: String? = nil
    public var body: String? = nil
}

extension InAppButton {
    /// A button that lost its `action` draws and does nothing when tapped. One inert button
    /// is a smaller loss than every message in the sync, which is what a throw here would cost.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = container.tolerant(.label, or: "")
        action = container.tolerant(.action, or: "")
        value = container.tolerant(.value)
        event_name = container.tolerant(.event_name)
        key = container.tolerant(.key)
        data = container.tolerant(.data)
        index = container.tolerant(.index)
    }
}

/**
 A filter value, as far as `Codable` can carry one.

 The wire value is whatever the author typed in the composer, which JSON allows to be a
 string, a number, a boolean or null. Swift's synthesized decoding cannot hold `Any`, so the
 shape has to be spelled out — and an unrecognised shape never throws, because one odd filter
 value must not take down the decode of every message in the sync.

 **An unrecognised shape is `.unsupported`, and it fails closed.** Decoded as `.null`, the
 completeness check would read it as an unfinished row and DROP it — so a filter this SDK could
 not read would be ignored, and the message would draw for everybody who fired the event.
 `.unsupported` is a complete row that matches nobody.

 It has to survive a relaunch, because the queue is saved by re-encoding what was decoded
 (`InAppStore.save`, read back in `init`). A marker that encoded as `null` would come back as
 `.null` and the fail-open would return one launch later, so it encodes as `{"unsupported": true}`
 — an object, which decodes back to `.unsupported` like any other shape this cannot read.

 One unreadable shape is not `.unsupported`: a list whose JavaScript text is empty — `[]`, `[null]`,
 `[""]` — which the web SDK's `isCompleteFilter` reads through `String(value)` as an unfinished row and
 drops. It decodes as `.string("")`, which this SDK drops for the same reason and which survives a
 relaunch as itself.
 */
public enum InAppFilterValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case unsupported

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let blank = try? container.decode(BlankText.self), blank.isBlank { self = .string("") }
        else { self = .unsupported }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .unsupported: try container.encode(["unsupported": true])
        }
    }

    /**
     The value as JavaScript's `String(filter.value ?? '')` reads it, which is what a text comparison compares.

     A number is JavaScript's text for it (`jsNumberText`), not Swift's: `100` rather than `100.0`. Not
     `String(Int(value))` for a whole number, which traps past `Int.max` — a filter value of `1e20` would
     crash the app on the first event it was asked about.
     */
    var text: String {
        switch self {
        case .string(let value): return value
        case .number(let value): return jsNumberText(value)
        case .bool(let value): return value ? "true" : "false"
        case .null, .unsupported: return ""
        }
    }
}

/// Whether JavaScript's `String(value)` of a list is empty: `[]`, and a list of one element whose own text is.
private struct BlankText: Decodable {
    let isBlank: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { isBlank = true }
        else if let text = try? container.decode(String.self) { isBlank = text.isEmpty }
        else if let items = try? container.decode([BlankText].self) { isBlank = items.isEmpty || (items.count == 1 && items[0].isBlank) }
        else { isBlank = false }
    }
}

/// One clause of an `event` trigger's filter.
public struct InAppFilter: Codable, Sendable {
    public let key: String
    public let op: String
    public let value: InAppFilterValue?
    /**
     How the row compares — `string`, `number`, `boolean`, `version` — or nil to read the value's own JSON
     type, as the web SDK does. Anything else, `null` included, is kept as `""`: a type no reader
     knows, which answers false under every operator, and which a relaunch keeps as one.
     */
    public let type: String?
    /**
     Which side the key names: nil or `property` for the event's properties. A `dimension` row names a
     device dimension, read from the ones this SDK stamped on the event; anything else is kept as `""`, a
     side no reader knows, false under every operator.
     */
    public let source: String?
    /**
     An element this SDK could not read as a filter at all — `null`, a string, an object with no
     string key. One such element fails the WHOLE trigger, as the web SDK reads it: dropped,
     `[{plan eq pro}, "x"]` against `{plan: "pro"}` would still draw. It encodes as `null`, which
     decodes back to a malformed element, so the saved queue keeps it across a relaunch.
     */
    public let malformed: Bool

    public init(key: String, op: String, value: InAppFilterValue? = nil, type: String? = nil, source: String? = nil) {
        self.key = key
        self.op = op
        self.value = value
        self.type = type
        self.source = source
        self.malformed = false
    }

    private init(malformed: Bool) {
        self.key = ""
        self.op = ""
        self.value = nil
        self.type = nil
        self.source = nil
        self.malformed = malformed
    }

    /// The element that stands for one this SDK could not read.
    static let malformedRow = InAppFilter(malformed: true)

    enum CodingKeys: String, CodingKey {
        case key, op, value, type, source
    }

    public func encode(to encoder: Encoder) throws {
        if malformed {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(op, forKey: .op)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(source, forKey: .source)
    }
}

/// One element of a stored `filters` list, which never throws: what it cannot read is a malformed row.
private struct FilterSlot: Decodable {
    let filter: InAppFilter

    init(from decoder: Decoder) throws {
        filter = (try? InAppFilter(from: decoder)) ?? .malformedRow
    }
}

extension InAppFilter {
    /**
     Whether this filter has been authored far enough to mean anything.

     Mirrors the web SDK's `isCompleteFilter`, and exists for the same reason: the composer's
     filter builder appends `{key: "", op: "eq", value: ""}` the moment "Add filter" is clicked
     and autosaves it. Read literally that row asks for a property named `""`, which nothing has,
     so the whole trigger would match nobody.

     Without this the failure would be silent and total: a working campaign would stop reaching
     any handset the moment somebody clicked Add filter and did not fill it in, while still
     looking correct in the composer. An incomplete row is dropped instead, and the rows beside
     it decide.
     */
    var isComplete: Bool {
        // A malformed element is never dropped as unfinished; `matchesFilters` fails the trigger on it.
        if malformed { return true }
        if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        // `exists` is complete on its key alone; every other operator needs something to compare
        // against.
        if op == "exists" { return true }
        switch value {
        case nil, .null?: return false
        // A value this SDK cannot read is complete, so it is evaluated — and fails closed — rather
        // than dropped as unfinished, which would read it as "no filter".
        case .unsupported?: return true
        case .string(let text)?: return !text.isEmpty
        case .number?, .bool?: return true
        }
    }

    /// An empty `op` on a row that has a value falls to `matchesFilters`' default branch, which
    /// fails closed. That is the answer this file already gives an operator it does not recognise,
    /// for the same reason: showing a message to people who do not qualify is worse than showing it
    /// to nobody. A row with no value as well is unfinished. `isComplete` drops it before that
    /// branch is reached, as the web SDK does.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A key that is missing or not a string makes the element malformed, as the web SDK reads
        // it (`isWellFormed`), rather than an unfinished row with an empty key that is dropped.
        guard let key = try? container.decode(String.self, forKey: .key) else {
            self = .malformedRow
            return
        }
        self.key = key
        op = container.tolerant(.op, or: "")
        value = container.tolerant(.value)
        type = Self.tag(container, .type)
        source = Self.tag(container, .source)
        malformed = false
    }

    /// Absent is nil; present and not a string — `null` included, which `decodeIfPresent` would read as
    /// absent — is `""`, which no reader knows.
    private static func tag(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        guard container.contains(key) else { return nil }
        return (try? container.decode(String.self, forKey: key)) ?? ""
    }
}

public struct InAppTrigger: Codable, Sendable {
    public let kind: String
    public let screen_name: String?
    public let event_name: String?
    /**
     Absent means "no filter", which is not the same as "no match".

     Without it the event branch would compare the event name alone, and a filtered trigger would
     show its message to everybody who fired the event, filter ignored: people who do not
     qualify, which is the failure the matcher's own comment calls worse than showing it to
     nobody.
     */
    public let filters: [InAppFilter]?
    /// `push_click` only: the campaign whose push opened the app, or nil for any push.
    public var campaign_id: String? = nil

    /*
     * Spelled out rather than synthesized, so that adding a field does not break every
     * caller that constructs one. The synthesized memberwise initializer requires every
     * stored property, so a new field such as `filters` would make
     * `InAppTrigger(kind:screen_name:event_name:)` stop compiling everywhere — which is the wrong cost for a field whose absence is the
     * ordinary case. Decoding is spelled out too, in the extension below.
     */
    public init(
        kind: String,
        screen_name: String? = nil,
        event_name: String? = nil,
        filters: [InAppFilter]? = nil,
        campaign_id: String? = nil
    ) {
        self.kind = kind
        self.screen_name = screen_name
        self.event_name = event_name
        self.filters = filters
        self.campaign_id = campaign_id
    }
}

extension InAppTrigger {
    /// An empty `kind` matches nothing — `inAppTriggerMatches` fails closed on a kind it does
    /// not recognise — so a message whose trigger arrived incomplete stays silent instead of
    /// showing to everybody, and the messages around it still decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = container.tolerant(.kind, or: "")
        screen_name = container.tolerant(.screen_name)
        event_name = container.tolerant(.event_name)
        campaign_id = container.tolerant(.campaign_id)
        /*
         * Absent or null is "no filter". Present and not a list is not "no filter" — it is a list this SDK
         * cannot read, and it matches nobody; decoded as nil it would draw the message for everybody.
         * It is kept as one malformed element, which encodes as `[null]` and
         * decodes back the same, so a relaunch cannot turn it back into "no filter".
         */
        if container.contains(.filters), (try? container.decodeNil(forKey: .filters)) == false {
            if let slots = try? container.decode([FilterSlot].self, forKey: .filters) {
                filters = slots.map(\.filter)
            } else {
                filters = [.malformedRow]
            }
        } else {
            filters = nil
        }
    }
}

public struct InAppContent: Codable, Sendable {
    public let surface: String
    public let layout: String
    /// Who writes the body — `standard` (the typed fields) or `html` (markup). Absent means standard, and a legacy
    /// `layout: "html"` means a fullscreen HTML body.
    ///
    /// Declared because the store and the React Native bridge re-encode this struct, and a key it does not declare is
    /// dropped on the way: an HTML modal would reach the app as a standard card with an empty body, where Android —
    /// which keeps the server's JSON — draws the markup. `testEveryDeviceKeySurvivesTheRoundTrip` holds this struct to
    /// every key a device must keep.
    public var body_mode: String? = nil
    public let html: String?
    /// The events and traits the markup's script may record, read out of `html` by the server. Kept for the WebView
    /// host, which refuses the rest without parsing the markup; nil on a message without markup.
    public var declared: InAppDeclared? = nil
    /// `fullscreen` only: nothing of ours behind the markup, so a page that draws its own overlay shows the app.
    public var transparent: Bool? = nil
    /// In place of `html` for a body over 64 KiB: its SHA-256 and size. The WebView host
    /// fetches the body from `/v1/in-app/body`; kept here so the store and the React Native bridge do not drop it.
    public var html_ref: InAppHtmlRef? = nil
    public let position: String?
    public let dismissible: Bool?
    public let buttons: [InAppButton]?
    public let trigger: InAppTrigger
    /// Declared because the server sends it, and deliberately NOT acted on here.
    ///
    /// The server reads this at queue time and turns it into the delivery's own
    /// `expires_at`, which `InAppStore.allows`
    /// already checks. Computing an expiry from this as well would be a second, independent
    /// answer to a question already answered — and the two would disagree the moment a
    /// device's clock did.
    public let expires_after_seconds: Double?
    public let max_displays: Int?
    /// Drawn however recently another message was: the channel's minimum gap does not apply.
    public var ignore_min_gap: Bool? = nil
    /// Contexts, a delay, priority, auto-dismiss, self-handled — and a form, a carousel, a countdown and a font
    /// for the app's renderer to draw.
    public var display: InAppDisplay? = nil
    public var form: InAppForm? = nil
    public var slides: [InAppSlide]? = nil
    public var countdown_to: String? = nil
    public var font_url: String? = nil
    /// An inbox row drawn as a card; nil when it is not one.
    public var card: InAppCard? = nil
    /// Which way the message's language reads — `rtl` or `ltr` — as the server resolved it from the locale it
    /// rendered, passed through untouched for the app's renderer: Arabic copy drawn left-aligned reads as
    /// broken. Declared, not merely tolerated, because the store and the React Native bridge re-encode this struct,
    /// and a key it does not declare is dropped on the way. Nil on a message from a server older than the field.
    public var direction: String? = nil
    /// What the message's image shows, for VoiceOver. Declared for the same reason `direction` is.
    public var image_alt: String? = nil
}

extension InAppContent {
    /// `trigger` is the only non-optional struct on the wire, and a content block that
    /// arrives without one gets a kind nothing matches — see `InAppTrigger` above.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        surface = container.tolerant(.surface, or: "")
        layout = container.tolerant(.layout, or: "")
        body_mode = container.tolerant(.body_mode)
        html = container.tolerant(.html)
        declared = container.tolerant(.declared)
        transparent = container.tolerant(.transparent)
        html_ref = container.tolerant(.html_ref)
        position = container.tolerant(.position)
        dismissible = container.tolerant(.dismissible)
        // Numbered from 1 as they arrive, as `treebars://click/<n>` is, so a report reads one way for either body.
        let typed: [InAppButton]? = container.tolerant(.buttons)
        buttons = typed.map { list in
            list.enumerated().map { position, button in
                var numbered = button
                if numbered.index == nil { numbered.index = position + 1 }
                return numbered
            }
        }
        trigger = container.tolerant(.trigger, or: InAppTrigger(kind: ""))
        expires_after_seconds = container.tolerant(.expires_after_seconds)
        max_displays = container.tolerant(.max_displays)
        ignore_min_gap = container.tolerant(.ignore_min_gap)
        display = container.tolerant(.display)
        form = container.tolerant(.form)
        slides = container.tolerant(.slides)
        countdown_to = container.tolerant(.countdown_to)
        font_url = container.tolerant(.font_url)
        card = container.tolerant(.card)
        direction = container.tolerant(.direction)
        image_alt = container.tolerant(.image_alt)
    }
}

/// A body over 64 KiB, by its SHA-256 and size.
public struct InAppHtmlRef: Codable, Sendable {
    public let sha256: String
    public let bytes: Int
}

/// What an HTML body lets its script record: `trackEvent` names and `setUserAttribute` traits.
public struct InAppDeclared: Codable, Sendable {
    public var events: [String] = []
    public var traits: [String] = []

    public init(events: [String] = [], traits: [String] = []) {
        self.events = events
        self.traits = traits
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        events = container.tolerant(.events, or: [])
        traits = container.tolerant(.traits, or: [])
    }
}

public struct InAppBody: Codable, Sendable {
    public let title: String?
    public let body: String?
    public let image_url: String?
    public let in_app: InAppContent?
    /// Where an inbox card with no action of its own goes when tapped, as the feed row's does.
    /// Declared because the store re-encodes this struct: Android keeps the server's JSON, so a key dropped here is an
    /// iPhone's card going nowhere where the same card on Android opens the link.
    public var deep_link: String? = nil
}

extension InAppBody {
    /// Nothing here is required, so the synthesized decoder would survive a missing key —
    /// but not a wrong-typed one, and a title sent as a number would empty the sync.
    /// Spelled out so that no field in this file is the exception.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = container.tolerant(.title)
        body = container.tolerant(.body)
        image_url = container.tolerant(.image_url)
        in_app = container.tolerant(.in_app)
        deep_link = container.tolerant(.deep_link)
    }
}

public struct InAppMessage: Codable, Sendable {
    public let delivery_id: String
    public let campaign_id: String?
    public let content: InAppBody
    public let expires_at: String?
    /// This message's own resolved tokens; absent on one queued before they existed.
    public let style: InAppTokens?
    /// A test send: drawn past every frequency cap — day, session, trigger kind and minimum gap. A test held back by a
    /// cap would read as a broken message. Expiry and "done" still apply.
    public var test: Bool? = nil
    /// What the campaign keeps for this person: an HTML message's `getStoredValue`, as of the sync, with what a
    /// display wrote since laid over it. Nil on a message whose markup reads none.
    public var stored: [String: InAppStoredValue]? = nil
    /// Its tokens in dark mode, when the message has a dark variant; nil otherwise. Declared, as every key the store
    /// re-encodes must be, or a queue kept across a launch would lose it.
    public var style_dark: InAppTokens? = nil
    /// The files it loads, computed at sync: what this core prefetches and inlines. Declared for the same reason as `style_dark` — a queue kept across a launch would otherwise draw offline
    /// only until the app was next opened.
    public var assets: InAppAssetManifest? = nil
}

/// One value an HTML message kept for the person: text, a number or a flag, as the server keeps them.
public enum InAppStoredValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }

    /// From what the page handed the bridge; nil for anything that is not one of the three.
    init?(_ value: Any) {
        if let text = value as? String { self = .string(text) }
        else if let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() { self = .bool(flag.boolValue) }
        else if let number = jsonNumber(value) { self = .number(number) }
        else { return nil }
    }

    /// As the page reads it back.
    var any: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        }
    }
}

extension InAppMessage {
    /**
     `delivery_id` is the one field here left required, and deliberately.

     It is the ledger key, the id `in_app_clicked` and `in_app_dismissed` report, and what
     `accept` prunes the ledger against. Defaulted to "", every message that lost its id would
     share one ledger entry: mark one done and they all go, dismiss one and the server is sent
     a delivery it cannot file. A row without an id is not a message, so it is dropped — and
     only it, because `InAppSyncResponse` decodes the list row by row.
     */
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        delivery_id = try container.decode(String.self, forKey: .delivery_id)
        campaign_id = container.tolerant(.campaign_id)
        content = container.tolerant(
            .content,
            or: InAppBody(title: nil, body: nil, image_url: nil, in_app: nil)
        )
        expires_at = container.tolerant(.expires_at)
        style = container.tolerant(.style)
        style_dark = container.tolerant(.style_dark)
        test = container.tolerant(.test)
        // Value by value: one the server sent as something else costs that key, not the rest.
        let kept: [String: Tolerated<InAppStoredValue>]? = container.tolerant(.stored)
        stored = kept?.compactMapValues(\.value)
        // Named here as well as declared: this decoder reads only what it names, and left out, the manifest the sync
        // handed over would be dropped at the door and no file prefetched.
        assets = container.tolerant(.assets)
    }
}

public struct InAppPolicy: Codable, Sendable {
    public let max_per_day: Int?
    public let min_gap_seconds: Int?
    /// What every one of this person's devices has shown today, as of the last sync.
    public let messages_shown_today: Int
    public let last_shown_at: String?
    /// Draws in one session, counted on this device. Nil for no cap.
    public var max_per_session: Int? = nil
    /// Distinct messages a day per trigger kind — session_start, screen_view, event — in this device's day.
    public var trigger_max_per_day: [String: Int]? = nil
    /// Nudges' own, counted on this device outside every cap above: a session's, and a gap.
    public var nudge_max_per_session: Int? = nil
    public var nudge_min_gap_seconds: Int? = nil
}

/// The trigger kinds a day cap can be set for. `immediate` is a send-now, and has none.
private let cappedTriggerKinds: Set<String> = ["session_start", "screen_view", "event"]

/// This device's local calendar day, which is what "a day" means for a count the device keeps.
private func localDay(_ at: Date) -> String {
    let parts = Calendar.current.dateComponents([.year, .month, .day], from: at)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
}

extension InAppPolicy {
    /// A count nobody sent reads as nothing shown yet, which errs towards showing a message
    /// rather than withholding one — and `ledger.sinceSync` still counts what this device did,
    /// so the cap is loosened for one sync rather than switched off.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        max_per_day = container.tolerant(.max_per_day)
        min_gap_seconds = container.tolerant(.min_gap_seconds)
        messages_shown_today = container.tolerant(.messages_shown_today, or: 0)
        last_shown_at = container.tolerant(.last_shown_at)
        max_per_session = container.tolerant(.max_per_session)
        // A kind the server left null is no cap: only the ones with a number are kept.
        let caps: [String: Int?]? = container.tolerant(.trigger_max_per_day)
        trigger_max_per_day = caps?.compactMapValues { $0 }.filter { $0.value > 0 }
        let nudges: Int? = container.tolerant(.nudge_max_per_session)
        nudge_max_per_session = nudges.flatMap { $0 > 0 ? $0 : nil }
        let nudgeGap: Int? = container.tolerant(.nudge_min_gap_seconds)
        nudge_min_gap_seconds = nudgeGap.flatMap { $0 > 0 ? $0 : nil }
    }
}

struct InAppSyncResponse: Codable {
    let messages: [InAppMessage]
    let policy: InAppPolicy?
    let style: InAppTokens?
    let claim_required: Bool?
    let signature_required: Bool?
}

extension InAppSyncResponse {
    /// Row by row: one message the server sent without a `delivery_id` costs that message,
    /// not the queue, the policy and the project's tokens with it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messages = container.tolerantList(.messages, of: InAppMessage.self)
        policy = container.tolerant(.policy)
        style = container.tolerant(.style)
        claim_required = container.tolerant(.claim_required)
        signature_required = container.tolerant(.signature_required)
    }
}

/// What this device has done with each message, which the server does not know.
private struct Ledger: Codable {
    var shown: [String: Int] = [:]
    var done: [String: Bool] = [:]
    var lastShownAt: Double?
    /// Displays since the last sync, so the server's count is added to rather than replaced.
    var sinceSync: Int = 0
    /// Draws in the current session, keyed by its id so a new session starts at zero by itself.
    var sessionID: String?
    var sessionShown: Int = 0
    /// Distinct messages first drawn today per trigger kind, in this device's day.
    var triggerDay: String?
    var triggerCounts: [String: Int] = [:]
    /// Nudges' own: drawn in the current session, and when the last one was — apart from the modals' above.
    var nudgeSessionID: String?
    var nudgeSessionShown: Int = 0
    var nudgeLastShownAt: Double?
    /// The last sync's caps, kept with the counts they are read against, so a cold start drawing from the stored queue
    /// is capped before its own sync comes back. Here and not under a key of their own, so `reset()` and every path
    /// that clears the ledger cover them already.
    var policy: InAppPolicy?
}

extension Ledger {
    /// This one is read off disk rather than off the wire, and the defaults above do not reach
    /// the synthesized decoder — Swift ignores them. So a build that adds a field to the
    /// ledger would throw on every ledger written before it and silently forget what this
    /// device has already shown, which is how a capped message gets shown again to real people.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shown = container.tolerant(.shown, or: [:])
        done = container.tolerant(.done, or: [:])
        lastShownAt = container.tolerant(.lastShownAt)
        sinceSync = container.tolerant(.sinceSync, or: 0)
        sessionID = container.tolerant(.sessionID)
        sessionShown = container.tolerant(.sessionShown, or: 0)
        triggerDay = container.tolerant(.triggerDay)
        triggerCounts = container.tolerant(.triggerCounts, or: [:])
        nudgeSessionID = container.tolerant(.nudgeSessionID)
        nudgeSessionShown = container.tolerant(.nudgeSessionShown, or: 0)
        nudgeLastShownAt = container.tolerant(.nudgeLastShownAt)
        // A ledger stored without a policy has none until the next sync brings one.
        policy = container.tolerant(.policy)
    }
}

final class InAppStore {
    /*
     Every read and write under one lock, as Kotlin's store is `@Synchronized` throughout. Three nudges shown at once
     mark themselves done from three tasks, and without it would mutate the ledger's dictionary concurrently inside
     `markDone`. Recursive, because the store's own methods call each other.
     */
    private let lock = NSRecursiveLock()
    private let queueKey = "treebars.in_app_queue"
    private let ledgerKey = "treebars.in_app_ledger"

    private var messages: [InAppMessage] = []
    private var ledger = Ledger()
    private var policy: InAppPolicy? { ledger.policy }
    private(set) var tokens: InAppTokens?

    /**
     Which sign-in a sync belongs to: moved on by `reset()` and by `supersede()`.

     A sync is a network round trip, and a sign-out can land inside it. Without this, the previous person's sync could
     come back after `reset()` had emptied this store and put their queue back — with the ledger that would have held
     it back already gone — to be drawn after sign-out. Read before the request and handed to `accept`, which drops an
     answer whose generation has passed.
     */
    private(set) var generation = 0

    /// A message's own tokens when it has them, else the project default from the sync — its dark ones while the app is
    /// drawn dark, when it has a dark variant. The caller says which, read on the main thread as the
    /// message is drawn, so the renderer is handed the right colours for the first frame.
    func tokensFor(_ message: InAppMessage, dark: Bool = false) -> InAppTokens? {
        lock.lock(); defer { lock.unlock() }
        if dark, let night = message.style_dark { return night }
        return message.style ?? tokens
    }

    /// The project's tokens from the last sync, under the lock a sync writes them under: the render plan's fallback for a
    /// message that carries none of its own, which the plan itself chooses between.
    func projectTokens() -> InAppTokens? {
        lock.lock(); defer { lock.unlock() }
        return tokens
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: queueKey),
           let decoded = try? JSONDecoder().decode([InAppMessage].self, from: data) {
            messages = decoded
        }
        if let data = UserDefaults.standard.data(forKey: ledgerKey),
           let decoded = try? JSONDecoder().decode(Ledger.self, from: data) {
            ledger = decoded
        }
    }

    /// The server is authoritative about what is queued; the ledger about what this device did.
    ///
    /// Returns false, and changes nothing, for an answer asked before the signed-in person last changed.
    @discardableResult
    func accept(_ response: InAppSyncResponse, askedAt: Int? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let askedAt, askedAt != generation { return false }
        messages = response.messages
        if let policy = response.policy {
            ledger.policy = policy
            // The server's count is as of now, so anything shown before it is included.
            ledger.sinceSync = 0
        }
        if let style = response.style { tokens = style }

        let live = Set(messages.map(\.delivery_id))
        ledger.shown = ledger.shown.filter { live.contains($0.key) }
        ledger.done = ledger.done.filter { live.contains($0.key) }
        save()
        return true
    }

    /**
     Somebody else is signed in now, without a sign-out between. The queue is the last person's, and so are the ledger
     of what they were shown and a sync in flight for them: all of it goes here, as at a sign-out, so nothing of theirs
     is left to be drawn for the person signing in.
     */
    func supersede() {
        reset()
    }

    func list() -> [InAppMessage] {
        lock.lock(); defer { lock.unlock() }
        return messages
    }

    /// The inbox rows, pinned cards first and newest first within each — a card whose `show_from` has not come
    /// yet left out, as the server leaves it out of the notification feed.
    func inbox(now: Date = Date()) -> [InAppMessage] {
        lock.lock(); defer { lock.unlock() }
        let rows = messages.filter { message in
            guard message.content.in_app?.surface == "inbox" else { return false }
            guard let from = message.content.in_app?.card?.show_from, let at = InAppStore.parse(from) else { return true }
            return at <= now
        }
        return rows.filter { $0.content.in_app?.card?.pinned == true } + rows.filter { $0.content.in_app?.card?.pinned != true }
    }

    func recordDisplay(_ message: InAppMessage, session: String? = nil, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let id = message.delivery_id
        // A nudge spends only its own ledger (`isNudge`): the day, session, trigger and gap ledgers are the modals'.
        if isNudge(message) {
            if let session {
                if ledger.nudgeSessionID != session {
                    ledger.nudgeSessionID = session
                    ledger.nudgeSessionShown = 0
                }
                ledger.nudgeSessionShown += 1
            }
            ledger.nudgeLastShownAt = now.timeIntervalSince1970
            let shown = (ledger.shown[id] ?? 0) + 1
            ledger.shown[id] = shown
            if let max = message.content.in_app?.max_displays, max > 0, shown >= max { ledger.done[id] = true }
            save()
            return
        }
        let firstTime = (ledger.shown[id] ?? 0) == 0
        if let session {
            if ledger.sessionID != session {
                ledger.sessionID = session
                ledger.sessionShown = 0
            }
            ledger.sessionShown += 1
        }
        if let kind = message.content.in_app?.trigger.kind, cappedTriggerKinds.contains(kind), firstTime {
            let day = localDay(now)
            if ledger.triggerDay != day {
                ledger.triggerDay = day
                ledger.triggerCounts = [:]
            }
            ledger.triggerCounts[kind, default: 0] += 1
        }
        let shown = (ledger.shown[id] ?? 0) + 1
        ledger.shown[id] = shown
        ledger.lastShownAt = Date().timeIntervalSince1970
        ledger.sinceSync += 1
        if let max = message.content.in_app?.max_displays, max > 0, shown >= max {
            ledger.done[id] = true
        }
        save()
    }

    func markDone(_ deliveryID: String) {
        lock.lock(); defer { lock.unlock() }
        ledger.done[deliveryID] = true
        save()
    }

    /// Answered or spent on this device: never drawn again.
    func isDone(_ deliveryID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ledger.done[deliveryID] == true
    }

    /// A value an HTML display kept, written into the queued message so its next display reads it
    /// before the next sync brings the server's copy. Nil forgets the key.
    func setStored(_ deliveryID: String, key: String, value: InAppStoredValue?) {
        lock.lock(); defer { lock.unlock() }
        guard let index = messages.firstIndex(where: { $0.delivery_id == deliveryID }) else { return }
        var stored = messages[index].stored ?? [:]
        stored[key] = value
        messages[index].stored = stored
        save()
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        messages = []
        ledger = Ledger()
        save()
    }

    /// Whether this device may draw this message now. Same three questions as every SDK.
    func allows(_ message: InAppMessage, session: String? = nil, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return blockedBy(message, session: session, now: now) == nil
    }

    /// Why this device may not draw this message now, or nil when it may — the reason an `in_app_failed`
    /// names. `done` is not a failure: a message shown as often as it may be, or dismissed, is finished.
    func blockedBy(_ message: InAppMessage, session: String? = nil, now: Date = Date(), nudgesInFlight: Int = 0) -> String? {
        lock.lock(); defer { lock.unlock() }
        let id = message.delivery_id
        if ledger.done[id] == true { return "done" }

        if let expires = message.expires_at, let at = InAppStore.parse(expires), at <= Date() {
            return "expired"
        }

        guard let policy else { return nil }
        // A test send is drawn past every cap below.
        if message.test == true { return nil }
        // A nudge is outside them (`isNudge`), under two of its own. `nudgesInFlight` are drawn and not yet on
        // screen, counted as shown now (`NudgeSlots.inFlight`).
        if isNudge(message) {
            if let cap = policy.nudge_max_per_session {
                let shownHere = session != nil && ledger.nudgeSessionID == session ? ledger.nudgeSessionShown : 0
                if shownHere + nudgesInFlight >= cap { return "max_per_session" }
            }
            if let gap = policy.nudge_min_gap_seconds {
                if nudgesInFlight > 0 { return "min_gap" }
                if let last = ledger.nudgeLastShownAt, now.timeIntervalSince1970 - last < Double(gap) { return "min_gap" }
            }
            return nil
        }

        // The cap counts distinct messages, matching the server, so seeing one again does
        // not spend another unit of the allowance — max_displays governs repeats.
        let alreadySeen = (ledger.shown[id] ?? 0) > 0
        if let max = policy.max_per_day, !alreadySeen,
           policy.messages_shown_today + ledger.sinceSync >= max {
            return "max_per_day"
        }

        // Per session: every draw counts, a repeat of the same message included — each one interrupted somebody.
        if let cap = policy.max_per_session, let session, ledger.sessionID == session, ledger.sessionShown >= cap {
            return "max_per_session"
        }

        // Per trigger kind a day: distinct messages, like the day cap, so a repeat spends nothing more.
        if let kind = message.content.in_app?.trigger.kind, let cap = policy.trigger_max_per_day?[kind], !alreadySeen {
            let drawn = ledger.triggerDay == localDay(now) ? ledger.triggerCounts[kind] ?? 0 : 0
            if drawn >= cap { return "trigger_cap" }
        }

        if let gap = policy.min_gap_seconds, message.content.in_app?.ignore_min_gap != true {
            let serverLast = policy.last_shown_at.flatMap(InAppStore.parse)?.timeIntervalSince1970 ?? 0
            let last = max(serverLast, ledger.lastShownAt ?? 0)
            if last > 0, now.timeIntervalSince1970 - last < Double(gap) { return "min_gap" }
        }

        return nil
    }

    /// Whether a held-back message should be reported now: once per message, reason and day, remembered
    /// across launches, so the campaign's failure counts are messages rather than every event that asked.
    func claimFailureReport(_ deliveryID: String, reason: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let storeKey = "treebars.in_app_failed.v1"
        let today = localDay(now)
        let seen = UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String] ?? [:]
        let key = "\(deliveryID):\(reason)"
        if seen[key] == today { return false }
        var kept = seen.filter { $0.value == today }
        kept[key] = today
        UserDefaults.standard.set(kept, forKey: storeKey)
        return true
    }

    private func save() {
        lock.lock(); defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(messages) {
            UserDefaults.standard.set(data, forKey: queueKey)
        }
        if let data = try? JSONEncoder().encode(ledger) {
            UserDefaults.standard.set(data, forKey: ledgerKey)
        }
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parse(_ value: String) -> Date? {
        formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

/**
 Whether a message's trigger matches what just happened.

 Mirrors `triggerMatches` in the web SDK and `inAppTriggerMatches` in the Android core, which take the
 same two things beside the event: `screenName`, the live screen the draw loop passes,
 which a `screen_view` trigger reads ahead of `properties["screen_name"]`; and `dimensions`, the
 dimension map this SDK stamped on THIS event — the same values, never a second read of the device —
 which a dimension row reads. Without it a dimension row is false. `screen_name` is compared
 case-sensitively because it is the host app's own vocabulary and we are in no position to decide that
 "cart" meant "Cart".
 */
func inAppTriggerMatches(
    _ trigger: InAppTrigger,
    eventName: String,
    properties: [String: Any],
    screenName: String?,
    dimensions: [String: Any]? = nil
) -> Bool {
    switch trigger.kind {
    case "immediate":
        return true
    case "session_start":
        return eventName == "session_start" || eventName == "app_open"
    case "screen_view":
        guard eventName == "screen_view", let want = trigger.screen_name else { return false }
        let actual = screenName ?? properties["screen_name"] as? String
        return actual == want
    case "event":
        return eventName == trigger.event_name && matchesFilters(properties, trigger.filters, dimensions)
    case "push_click":
        // The app opened from a push — any push, or one campaign's.
        guard eventName == "notification_opened" else { return false }
        guard let want = trigger.campaign_id else { return true }
        return properties[TreebarsConstants.campaignIdKey] as? String == want
    default:
        // An unrecognised kind fails closed: showing a message to people who do not
        // qualify is worse than showing it to nobody.
        return false
    }
}

/**
 The trigger's filters against one event, as every SDK reads them on a device. `sdks/web/src/in-app.ts`
 is the same rule in TypeScript, and the easier one to read against this.

 All fourteen operators, from the generated `filterOperatorCodes`; one this build does not know fails
 closed, because showing a message to people who do not qualify is worse than showing it to nobody.

 A malformed element fails the WHOLE trigger, not just its row: dropped, `[{plan eq pro}, "x"]` against
 `{plan: "pro"}` would still draw. Incomplete rows are dropped before the conjunction rather than failed
 inside it — an unfinished row beside a real one must leave the real one deciding.
 */
func matchesFilters(_ properties: [String: Any], _ filters: [InAppFilter]?, _ dimensions: [String: Any]? = nil) -> Bool {
    guard let filters, !filters.isEmpty else { return true }
    if filters.contains(where: \.malformed) { return false }
    return filters.filter(\.isComplete).allSatisfy { matchesFilter(properties, $0, dimensions) }
}

private let knownCodes: Set<String> = Set(TreebarsConstants.filterOperatorCodes)
/// The codes that match a value that is not set.
private let negatedCodes: Set<String> = ["neq", "not_contains", "not_in", "not_exists"]
private let textCodes: Set<String> = ["contains", "not_contains", "starts_with", "ends_with"]
private let filterTypes: Set<String> = ["string", "number", "boolean", "version"]
private let inAppDimensions: Set<String> = Set(TreebarsConstants.inAppDimensions)

private func matchesFilter(_ properties: [String: Any], _ filter: InAppFilter, _ dimensions: [String: Any]?) -> Bool {
    // A side or a type this SDK does not read, and a code it does not know, fail closed.
    if let source = filter.source, source != "property", source != "dimension" { return false }
    if let type = filter.type, !filterTypes.contains(type) { return false }
    if !knownCodes.contains(filter.op) { return false }

    /*
     A dimension row reads the event's own map, never a property of the same name — and is false, not
     "not set", without one, or for a name an in-app trigger may not read: geo, which a device cannot know,
     and anything outside `inAppDimensions`. Read as not set it would pass `neq`. A dimension is stored as
     text, so the row compares as text unless it is a version row.
     */
    if filter.source == "dimension" {
        guard let dimensions, inAppDimensions.contains(filter.key) else { return false }
        let row = filter.type == "version"
            ? filter
            : InAppFilter(key: filter.key, op: filter.op, value: filter.value, type: "string", source: filter.source)
        return compareValue(storedDimension(filter.key, dimensions[filter.key]), row)
    }
    // By its literal key.
    return compareValue(properties[filter.key], filter)
}

/// One row's comparison, over a value already found by whichever side the row names.
private func compareValue(_ actual: Any?, _ filter: InAppFilter) -> Bool {
    // Not set is missing, null or "": "is set" is false for all three, and every negated code
    // matches them.
    let unset = actual == nil || actual is NSNull || (actual as? String) == ""
    switch filter.op {
    case "exists": return !unset
    case "not_exists": return unset
    default: break
    }
    // A row that cannot say anything matches nobody, and that comes BEFORE the not-set reading: "is not one
    // of []" must never read as "everyone without the property".
    if saysNothing(filter) { return false }
    if unset { return negatedCodes.contains(filter.op) }
    // A property that is not a scalar — a list, a dictionary — fails closed, the negated codes included.
    guard let value = scalar(actual) else { return false }

    if filter.op == "in" || filter.op == "not_in" {
        let items = decodeList(filter.value)!
        let listType = filter.type ?? (items.numbers != nil ? "number" : "string")
        let hit: Bool
        if listType == "version" {
            // Every item parses — `saysNothing` refused the row otherwise; a present value that does not is false.
            guard let left = parseVersion(actual) else { return false }
            hit = items.texts.contains { compareVersion(left, parseVersion($0)!) == 0 }
        } else if listType == "number" {
            guard let left = asNumber(value, readText: filter.type == "number") else { return false }
            hit = items.numbers!.contains(left)
        } else {
            hit = items.texts.contains { sameText(value.text, $0) }
        }
        return filter.op == "in" ? hit : !hit
    }

    let rowType = filter.type ?? inferredType(filter.value)
    if rowType == "version" {
        // Part by part: 2.10 is after 2.9.1, and 2.3 = 2.3.0. A present value that does not
        // parse — a JSON number, 2.4.0-beta — is false under every code here, `neq` included; a text code has
        // no version reading.
        guard let left = parseVersion(actual), case .string(let authored)? = filter.value,
              let right = parseVersion(authored) else { return false }
        let order = compareVersion(left, right)
        switch filter.op {
        case "eq": return order == 0
        case "neq": return order != 0
        case "gt": return order > 0
        case "gte": return order >= 0
        case "lt": return order < 0
        case "lte": return order <= 0
        default: return false
        }
    }
    if rowType == "number" {
        // With no `type` only a JSON number; under `type: 'number'`, text through the one grammar too.
        guard let left = asNumber(value, readText: filter.type == "number"),
              case .number(let right)? = filter.value else { return false }
        switch filter.op {
        case "eq": return left == right
        case "neq": return left != right
        case "gt": return left > right
        case "gte": return left >= right
        case "lt": return left < right
        case "lte": return left <= right
        default: return false
        }
    }

    // `string` and `boolean` compare text — "150" is 150 here, and true is "true".
    let left = value.text
    let right = filter.value?.text ?? ""
    let orders = filter.type != "boolean"
    switch filter.op {
    case "eq": return sameText(left, right)
    case "neq": return !sameText(left, right)
    case "contains": return containsText(left, right)
    case "not_contains": return !containsText(left, right)
    case "starts_with": return left.utf16.starts(with: right.utf16)
    case "ends_with": return left.utf16.reversed().starts(with: right.utf16.reversed())
    case "gt": return orders && precedes(right, left)
    case "gte": return orders && !precedes(left, right)
    case "lt": return orders && precedes(left, right)
    case "lte": return orders && !precedes(right, left)
    default: return false
    }
}

/**
 Whether a row says nothing: a value that is not a scalar, a list that does not decode, a number row holding text
 or under a text code, and a version row whose value or any item does not parse. It runs before the
 not-set reading, so "app version is not 2.4.0-beta" never matches every device that sends no app version.
 */
private func saysNothing(_ filter: InAppFilter) -> Bool {
    if case .unsupported? = filter.value { return true }
    if filter.op == "in" || filter.op == "not_in" {
        guard let items = decodeList(filter.value) else { return true }
        let listType = filter.type ?? (items.numbers != nil ? "number" : "string")
        if listType == "number" { return items.numbers == nil }
        // A number item is never a version, whatever its text: only a string parses.
        if listType == "version" { return items.numbers != nil || items.texts.contains { parseVersion($0) == nil } }
        return false
    }
    let rowType = filter.type ?? inferredType(filter.value)
    if rowType == "number" {
        if case .number? = filter.value { return textCodes.contains(filter.op) }
        return true
    }
    if rowType == "version" {
        guard case .string(let authored)? = filter.value else { return true }
        return parseVersion(authored) == nil
    }
    return false
}

/**
 A version's parts, as every SDK reads one: a string of one to four
 dot-separated parts of one to ten ASCII digits, with an optional leading `v`. A character loop rather
 than a pattern: `NSRegularExpression`'s `$` matches before a final newline, `Character.isNumber` and
 `\d` accept digits from every script, and `Int64("+1")` is 1. Only a `String` parses — the number 2.3
 is not a version.
 */
func parseVersion(_ value: Any?) -> [Int64]? {
    guard let text = value as? String else { return nil }
    var scalars = Substring(text).unicodeScalars[...]
    if let first = scalars.first, first == "v" || first == "V" { scalars = scalars.dropFirst() }
    var parts: [Int64] = []
    var current: Int64 = 0
    var digits = 0
    for scalar in scalars {
        if scalar == "." {
            guard digits > 0 else { return nil }
            parts.append(current)
            current = 0
            digits = 0
        } else if scalar.value >= 48, scalar.value <= 57, digits < 10 {
            current = current * 10 + Int64(scalar.value - 48)
            digits += 1
        } else {
            return nil
        }
    }
    guard digits > 0 else { return nil }
    parts.append(current)
    return parts.count <= 4 ? parts : nil
}

/// Part by part, both sides padded with zeros to four parts, so 2.3 = 2.3.0 = 2.3.0.0.
func compareVersion(_ a: [Int64], _ b: [Int64]) -> Int {
    for index in 0..<4 {
        let left = index < a.count ? a[index] : 0
        let right = index < b.count ? b[index] : 0
        if left != right { return left < right ? -1 : 1 }
    }
    return 0
}

/**
 JavaScript's `trim()`, which the server trims a device field with: its WhiteSpace and LineTerminator code
 points, written out. Foundation's `.whitespacesAndNewlines` is a different set — it adds U+0085 and has no
 U+FEFF — so a value padded with a byte-order mark would compare untrimmed here and trimmed in the store.
 */
private let jsWhitespace: Set<UInt32> = [
    0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680,
    0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
    0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF,
]

func jsTrim(_ text: String) -> String {
    let scalars = text.unicodeScalars
    guard let start = scalars.firstIndex(where: { !jsWhitespace.contains($0.value) }),
          let end = scalars.lastIndex(where: { !jsWhitespace.contains($0.value) }) else { return "" }
    return String(scalars[start...end])
}

/// The first `count` UTF-16 code units, as JavaScript's `slice` cuts. A cut through a surrogate pair keeps
/// no half of it, where JavaScript keeps a lone surrogate no condition could name.
func utf16Prefix(_ text: String, _ count: Int) -> String {
    let units = text.utf16
    guard units.count > count else { return text }
    return String(decoding: units.prefix(count), as: UTF16.self)
}

/**
 A dimension as the stored event will hold it, from the value this SDK stamped, as the server stores it.
 A device field is trimmed as JavaScript trims and cut at the
 generated `deviceFieldLength`; a screen name is not trimmed and is cut at `stringValueLength`; anything
 empty or not a string is missing.
 */
func storedDimension(_ name: String, _ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    if name == "screen_name" { return text.isEmpty ? nil : utf16Prefix(text, TreebarsConstants.stringValueLength) }
    let trimmed = jsTrim(text)
    return trimmed.isEmpty ? nil : utf16Prefix(trimmed, TreebarsConstants.deviceFieldLength)
}

private func inferredType(_ value: InAppFilterValue?) -> String {
    switch value {
    case .number?: return "number"
    case .bool?: return "boolean"
    default: return "string"
    }
}

/// A property value as JavaScript's `typeof` would sort it; nil for anything that is not a scalar.
private enum Scalar {
    case text(String)
    case number(Double)
    case bool(Bool)

    /// JavaScript's `String(value)`, which a text comparison compares.
    var text: String {
        switch self {
        case .text(let value): return value
        case .number(let value): return jsNumberText(value)
        case .bool(let value): return value ? "true" : "false"
        }
    }
}

/**
 A JSON boolean arrives as an `NSNumber`, and `NSNumber(1) as? Bool` is `true` — so asking Swift whether a
 value is a `Bool` cannot tell `1` from `true`, and neither can asking whether it is a number. The
 `CFBoolean` type is the one question that can: `true` from `JSONSerialization` and a Swift `Bool` bridge
 to it, and no number does.
 */
private func scalar(_ value: Any?) -> Scalar? {
    if let text = value as? String { return .text(text) }
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
        return .number(number.doubleValue)
    }
    return nil
}

private let numberGrammar = try! NSRegularExpression(pattern: TreebarsConstants.numberGrammar)

/**
 A number, as every SDK reads one: a JSON number (never NaN), or — under `type: 'number'` — text
 the one grammar accepts WHOLE. ICU's `$` matches before a final newline where JavaScript's does not, so
 `"42\n"` matches the pattern's `{0, 2}` and would read as 42 here and as nothing in JavaScript; the
 match has to cover every character. `Double` then reads what the grammar admits as `Number` does,
 `1e400` as infinity included.
 */
private func asNumber(_ value: Scalar, readText: Bool) -> Double? {
    switch value {
    case .number(let number): return number.isNaN ? nil : number
    case .text(let text) where readText:
        let whole = NSRange(location: 0, length: (text as NSString).length)
        guard numberGrammar.firstMatch(in: text, range: whole)?.range == whole else { return nil }
        return Double(text)
    default: return nil
    }
}

/// A stored list, decoded once: a JSON array as a string, of non-empty strings or finite numbers, at most
/// `listMax`. `numbers` is set when every item is a number; `texts` is always each item's text.
private struct ListItems {
    let texts: [String]
    let numbers: [Double]?
}

private func decodeList(_ value: InAppFilterValue?) -> ListItems? {
    guard case .string(let json)? = value,
          let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) as? [Any],
          !parsed.isEmpty, parsed.count <= TreebarsConstants.listMax else { return nil }
    if let texts = parsed as? [String], texts.allSatisfy({ !$0.isEmpty }) {
        return ListItems(texts: texts, numbers: nil)
    }
    let numbers = parsed.compactMap { item -> Double? in
        guard case .number(let number)? = scalar(item), number.isFinite else { return nil }
        return number
    }
    guard numbers.count == parsed.count else { return nil }
    return ListItems(texts: numbers.map(jsNumberText), numbers: numbers)
}

/*
 * Text is compared as JavaScript compares it, by UTF-16 code unit — not as Swift's `==` and `<` do, by
 * canonical equivalence: Swift calls "é" and "e\u{301}" equal where JavaScript and the server both see two
 * strings, and orders "ｚ" before "😀" where JavaScript orders the surrogate first.
 */
private func sameText(_ left: String, _ right: String) -> Bool {
    left.utf16.elementsEqual(right.utf16)
}

private func precedes(_ left: String, _ right: String) -> Bool {
    left.utf16.lexicographicallyPrecedes(right.utf16)
}

private func containsText(_ haystack: String, _ needle: String) -> Bool {
    let hay = Array(haystack.utf16), pin = Array(needle.utf16)
    if pin.isEmpty { return true }
    if pin.count > hay.count { return false }
    for start in 0...(hay.count - pin.count) where hay[start..<start + pin.count].elementsEqual(pin) {
        return true
    }
    return false
}

/**
 JavaScript's `String(number)`, which a text comparison compares a number by.

 Swift's `description` finds the same shortest digits and places them differently: `100.0` for 100,
 `1e+16` for 10000000000000000, `1e-06` for 0.000001. So the digits are taken from it and laid out by
 ECMAScript's Number::toString — plain between 1e-7 and 1e21, exponential outside, `-0` as "0".
 */
func jsNumberText(_ value: Double) -> String {
    if value.isNaN { return "NaN" }
    if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
    if value == 0 { return "0" }

    let shortest = abs(value).description
    var mantissa = Substring(shortest)
    var exponent = 0
    if let e = shortest.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        exponent = Int(shortest[shortest.index(after: e)...]) ?? 0
        mantissa = shortest[..<e]
    }
    let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
    let whole = parts[0]
    let fraction = parts.count > 1 ? parts[1] : ""
    var digits = Array(whole + fraction)
    var point = whole.count + exponent
    while digits.first == "0" { digits.removeFirst(); point -= 1 }
    while digits.last == "0" { digits.removeLast() }

    let k = digits.count, n = point
    let text: String
    if k <= n && n <= 21 {
        text = String(digits) + String(repeating: "0", count: n - k)
    } else if 0 < n && n <= 21 {
        text = String(digits[..<n]) + "." + String(digits[n...])
    } else if -6 < n && n <= 0 {
        text = "0." + String(repeating: "0", count: -n) + String(digits)
    } else {
        let e = n - 1
        let sign = e < 0 ? "-" : "+"
        let lead = k == 1 ? String(digits) : String(digits[0]) + "." + String(digits[1...])
        text = lead + "e" + sign + String(abs(e))
    }
    return value < 0 ? "-" + text : text
}

/// How often a delayed message that found the screen taken looks again.
let delayedInAppRetryNanoseconds: UInt64 = 1_000_000_000

/// What a delayed in-app message does when it looks: show now, wait for the screen, or stop.
enum DelayedInApp: Equatable {
    case present
    case wait
    /// Stopped; the `in_app_failed` reason, or nil when there is nothing to report (`done`).
    case drop(String?)
}

/**
 The decision, apart from the task that runs it. The screen is asked first, so a message waiting behind
 another is judged by the caps as they stand once the screen is free rather than while the other is still
 up; then the caps, as the immediate path asks them; then the renderer.
 */
func delayedInAppStep(blocked: String?, hasRenderer: Bool, screenHeld: Bool) -> DelayedInApp {
    if screenHeld { return .wait }
    if let blocked { return .drop(blocked == "done" ? nil : blocked) }
    if !hasRenderer { return .drop("no_renderer") }
    return .present
}

/**
 The loop a delayed message runs once its delay is up, apart from `Treebars` and `Task.sleep`, so a test can
 drive it with a clock of its own.

 Each pass looks once: gone when the message is no longer the one waiting (`stillWaiting` — `reset()`, or a new
 person); otherwise `look` decides (`delayedInAppStep`). A wait, or a `present` that lost the slot to another
 consideration between the look and the claim, `sleep`s and looks again; a drop, or a present that took the screen,
 `finish`es — and a drop with a reason is `report`ed as `in_app_failed`. The loop is testable as well as the decision,
 because a message dropped without a word would be dropped here.
 */
func runDelayedInApp(
    stillWaiting: () async -> Bool,
    look: () async -> DelayedInApp,
    present: () async -> Bool,
    finish: () async -> Void,
    report: (String) async -> Void,
    sleep: () async -> Void
) async {
    while await stillWaiting() {
        switch await look() {
        case .wait:
            break
        case .drop(let reason):
            await finish()
            if let reason { await report(reason) }
            return
        case .present:
            if await present() {
                await finish()
                return
            }
        }
        await sleep()
    }
}

/**
 Whether an overlay is on screen, claimed and read under one lock.

 `Treebars` is a plain class, and every event hands `considerInApp` to its own `Task` on the
 cooperative pool — so two events of one burst are considered on two threads at once. With
 the check ("nothing is on screen") and the claim ("now something is") on either side of two
 suspension points, the session read and the `in_app_displayed` enqueue, a tab change that
 fires `tab_selected` and `screen_view` together would pass the check twice: one modal on
 screen, two `in_app_displayed` reports a millisecond apart. Claimed in one step, the second
 consideration finds the slot taken and leaves the message alone.

 A duration (`TreebarsConstants.inAppPresentationHold`) rather than a flag the host clears, so a
 renderer that never says its message ended cannot hold the screen for good.
 */
final class PresentationSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var claimedAt: Date?
    /// Claimed by this SDK's own HTML host, which says when its message ends on every path: held until `release`, not
    /// for `hold`. The hold is a ceiling for renderers that never say, and a person thirty seconds into a three-screen
    /// message must not have the next message drawn over it.
    private var pinned = false
    private let hold: TimeInterval

    init(hold: TimeInterval = TreebarsConstants.inAppPresentationHold) {
        self.hold = hold
    }

    /// Takes the slot if nothing holds it, and says whether this caller got it. `untilReleased` for a host that
    /// reports every ending itself.
    func claim(now: Date = Date(), untilReleased: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if heldLocked(now) { return false }
        claimedAt = now
        pinned = untilReleased
        return true
    }

    /// Whether something is on screen and unanswered. Advisory: only `claim` decides.
    func isHeld(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return heldLocked(now)
    }

    private func heldLocked(_ now: Date) -> Bool {
        guard let at = claimedAt else { return false }
        return pinned || now.timeIntervalSince(at) < hold
    }

    /// The person answered, or the host that drew it went away.
    func release() {
        lock.lock()
        claimedAt = nil
        pinned = false
        lock.unlock()
    }

    /// The same, from the app's renderer, which never holds a claim made until released: a late answer from it, or a
    /// renderer attaching, must not free the screen under a message this SDK is drawing.
    func releaseUnpinned() {
        lock.lock()
        if !pinned { claimedAt = nil }
        lock.unlock()
    }
}

// MARK: - Receipts

/// What every in-app receipt carries: the delivery, and the campaign when there is one.
///
/// Every receipt — displayed, failed, form submitted, clicked, dismissed — goes through this, so a report of clicks by
/// campaign reads as whole as one of displays. The same function in Kotlin (`inAppReceipt`) and on the web.
func inAppReceipt(_ message: InAppMessage) -> [String: Any] {
    var properties: [String: Any] = [TreebarsConstants.deliveryIdKey: message.delivery_id]
    if let campaign = message.campaign_id { properties[TreebarsConstants.campaignIdKey] = campaign }
    return properties
}

/// `in_app_clicked`'s properties: `destination` only for a button that sends somebody somewhere. A "set a trait"
/// button's value is the trait's value, and reporting `yes` as where the click went would pollute every click report —
/// and a host reading it back would route `yes` as a link.
func inAppClickProperties(_ message: InAppMessage, button: InAppButton) -> [String: Any] {
    var properties = inAppReceipt(message)
    if ["url", "deep_link"].contains(button.action), let value = button.value, !value.isEmpty {
        properties["destination"] = value
    }
    // What was pressed: the element's number, and a typed button's label when it has one.
    if let index = button.index { properties[TreebarsConstants.inAppButtonIndexKey] = index }
    if !button.label.isEmpty { properties[TreebarsConstants.inAppButtonLabelKey] = button.label }
    return properties
}

/**
 Our own reports that the app is going away, which are never a moment to draw. An `immediate` trigger matches every
 event, and `app_background` is enqueued on the way out — so without this the next queued message would be drawn over
 an app that had just left the screen, reported displayed, and spent. The web SDK guards the same moment on every link
 click; Android records its lifecycle past the matcher and carries the same guard for a caller who tracks one by name.
 `session_end` is history, sent for a session that has already ended.
 */
func isLeavingEvent(_ eventName: String) -> Bool {
    eventName == Treebars.DefaultEvent.appBackground || eventName == Treebars.DefaultEvent.sessionEnd
}

/// Whether a button press ends the message on this device, as a dismissal does.
///
/// A call to action that closed the overlay and spent nothing would, unless the trigger was `immediate` or
/// `max_displays` was set, have the next matching event draw the same message again, with the screen claimed for the
/// whole hold. So a press whose action does something marks the message done and frees the screen. `dismiss` is not one — its own dismissal
/// follows — and neither is an action this core does not know, such as a React Native markup body's `click`: that is
/// "record that this was pressed" on a message still on screen.
/// What a press hands the app's delegate: a `custom` button's keys, and for every other button its `value` — with a
/// link's key-values beside it, never in place of it, so an app routing on `values["value"]` still finds the link when
/// somebody adds a UTM. The web's `clickValues` and Kotlin's, the same rule.
func clickValues(_ button: InAppButton) -> [String: String] {
    if button.action == "custom" { return button.data ?? button.value.map { ["value": $0] } ?? [:] }
    var values = button.data ?? [:]
    if let value = button.value { values["value"] = value }
    return values
}

func inAppClickEndsMessage(_ button: InAppButton) -> Bool {
    // Push's device actions among them: a call, a copy, a share, a store review.
    ["url", "deep_link", "track_event", "set_attribute", "custom", "call", "copy", "share", "store_review"].contains(button.action)
}
