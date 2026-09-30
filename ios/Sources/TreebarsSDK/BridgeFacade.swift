import Foundation

/*
 * The @objc face of this core, and it exists for exactly one caller.
 *
 * `sdks/react-native/ios/TreebarsNative.mm` is the TurboModule, and a `.mm` cannot see any of
 * the surface below it: `Treebars` is a Swift-only type with no `@objc` anywhere, its renderer
 * is a closure taking two more closures, and `InAppMessage`, `InAppTokens` and
 * `NotificationPage` are Swift structs. None of those are representable in Objective-C.
 *
 * The alternative to this file is a `.mm` reaching into Swift through generated headers it
 * cannot get — so what crosses is narrowed to strings, blocks and one boxed handle, and the
 * narrowing happens here rather than in the bridge. That keeps `JSONEncoder`, `JSONDecoder`
 * and every type they touch on this side of the language boundary, which is the whole point:
 * the wrapper marshals, and marshalling a Swift struct is Swift's job.
 *
 * **Nothing here swallows.** Every function that can fail says how, as a
 * `TreebarsBridgeFailure` the bridge turns into a promise rejection. A parse that fails does
 * not return an empty dictionary and a page that will not encode does not return `{}` — the
 * React Native SDK's own spec calls out why: `markRead`'s promise is documented to mean the
 * write landed, and a bridge that answered cheerfully on a transport failure would make an
 * erasure indistinguishable from a completed one.
 *
 * A file of its own rather than additions to the ones around it, so that everything the wrapper
 * needs is in one place and `Treebars.swift` stays a description of the SDK rather than of its bridge.
 */

/// A failure the bridge can hand to `reject(code, message, error)` without inventing either half.
///
/// Two strings and no `NSError`: the codes are a contract with the JavaScript side
/// (`bad_payload`, `bad_config`, `not_initialized`), not domains anybody catches on, and an
/// `NSError` would invite a caller to read `domain` and `code` instead.
@objc(TreebarsBridgeFailure)
public final class TreebarsBridgeFailure: NSObject {
    @objc public let code: String
    @objc public let message: String

    init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}

private enum BridgeCode {
    static let badPayload = "bad_payload"
    static let badConfig = "bad_config"
}

/**
 One live overlay, boxed so that Objective-C can hold what it cannot express.

 `Treebars.InAppRenderer` hands the app two closures — report a click, and dismiss — and a
 TurboModule cannot pass a closure to JavaScript. So the pair is held here against an id the
 bridge emits, and JavaScript calls back with that id. This box is the "held" half.

 **A click does not end the presentation**, which is why the two calls are separate and why
 neither clears anything: `InAppHost` reports a `treebars://click/<n>` and deliberately keeps
 the overlay up, and a markup body fires click and then dismiss on the same presentation. The
 bridge above must therefore leave its slot live across `click` — this box makes that possible
 by never invalidating itself.
 */
@objc(TreebarsPresentation)
public final class TreebarsPresentation: NSObject {
    private let onClick: (InAppButton) -> Void
    private let onDismiss: () -> Void

    fileprivate init(onClick: @escaping (InAppButton) -> Void, onDismiss: @escaping () -> Void) {
        self.onClick = onClick
        self.onDismiss = onDismiss
    }

    /// Reports a press. Safe to call repeatedly; the presentation stays up.
    ///
    /// The button is decoded rather than trusted, and a body that will not decode is a
    /// rejection instead of an inert click: `InAppButton` tolerates a missing `label` or
    /// `action` by design, so anything that still fails here is not a button at all.
    @objc(clickWithButtonJson:)
    public func click(buttonJson: String) -> TreebarsBridgeFailure? {
        guard let data = buttonJson.data(using: .utf8),
              let button = try? JSONDecoder().decode(InAppButton.self, from: data)
        else {
            return TreebarsBridgeFailure(
                BridgeCode.badPayload,
                "in-app click: the button could not be read as JSON"
            )
        }

        onClick(button)
        return nil
    }

    /// Ends the presentation: marks the message done and reports `in_app_dismissed`.
    @objc(dismiss)
    public func dismiss() {
        onDismiss()
    }
}

/**
 What the wrapper calls, in the only shapes Objective-C can name.

 Every method here is a thin translation of something on `Treebars`. The two places where it
 is more than that are documented where they happen: `start` maps a JSON config onto
 `initialize`'s parameters, and `setInAppRenderer` mints the presentation id.
 */
@objc(TreebarsBridge)
public final class TreebarsBridge: NSObject {
    /// Whether `start` has been through. The bridge rejects `not_initialized` on this.
    ///
    /// Held here rather than asked of `Treebars`, which has no such reader: `writeKey` is
    /// private and `initialize` returns nothing. Every core method below tolerates being
    /// called first — by doing nothing, quietly — and the bridge would rather reject than
    /// be quiet.
    @objc public private(set) static var isStarted = false

    private static var notificationsUnsubscribe: (() -> Void)?

    // ------------------------------------------------------------------------------------
    // Lifecycle
    // ------------------------------------------------------------------------------------

    /**
     The deferred deep link, for React Native's emitter.

     `Treebars.onDeferredDeepLink` takes a Swift closure, which Objective-C cannot pass, so the
     bridge hands a block and this adapts it — the same shape as the notification watcher `start`
     installs, and for the same reason.
     */
    @objc(setDeferredDeepLinkSink:)
    public static func setDeferredDeepLinkSink(_ sink: (@Sendable (String) -> Void)?) {
        guard let sink else {
            Treebars.onDeferredDeepLink(nil)
            return
        }
        Treebars.onDeferredDeepLink { path in sink(path) }
    }

    /**
     `initialize`, plus the two listeners that have to be installed in the same breath.

     The upload listener is the reason this takes sinks rather than being three calls.
     `Treebars.setUploadListener` writes through `shared.uploader`, which does not exist until
     `initialize` has built it — so a bridge that installed the listener first would install it
     into nothing and report no upload ever, with the listener demonstrably set. Taking both
     sinks here removes the ordering from the caller entirely.

     The notification watcher is installed unconditionally and stays. `setNotificationsSubscribed`
     gates the EMIT rather than the watch: a page that changed while nobody was looking is still
     the current page, and dropping it would leave a re-subscribing bell stale until the next
     write. Nothing is spent by holding it, which is what makes that safe — unlike the in-app
     renderer, where being installed is what spends the message.
     */
    @objc(startWithConfigJson:uploadSink:notificationsSink:)
    public static func start(
        configJson: String,
        uploadSink: @escaping @Sendable (String) -> Void,
        notificationsSink: @escaping @Sendable (String) -> Void
    ) -> TreebarsBridgeFailure? {
        guard let config = dictionary(configJson) else {
            return TreebarsBridgeFailure(
                BridgeCode.badPayload,
                "initialize: the configuration could not be read as JSON"
            )
        }

        guard let writeKey = config["write_key"] as? String, !writeKey.isEmpty else {
            return TreebarsBridgeFailure(
                BridgeCode.badConfig,
                "initialize: `write_key` is missing. Without it nothing can be sent."
            )
        }

        /*
         * Validated rather than defaulted, because the wrapper already defaults it.
         * `Treebars.ts` falls back to `DEFAULT_BACKEND_URL` before it gets here, so an absent
         * or unparseable value at this point means the wrapper was bypassed or the constant
         * is wrong — and quietly substituting Treebars's own host would send a self-hosted
         * customer's events to us.
         */
        guard let backend = config["backend_url"] as? String,
              let backendURL = URL(string: backend),
              backendURL.scheme != nil, backendURL.host != nil
        else {
            return TreebarsBridgeFailure(
                BridgeCode.badConfig,
                "initialize: `backend_url` is missing or is not an absolute URL"
            )
        }
        /*
         * Refused here as well as in the core, so `init()` rejects and says why. The core alone would
         * stay off and print a warning, and the promise would resolve on an SDK that sends nothing.
         */
        guard BackendURL.allows(backendURL) else {
            return TreebarsBridgeFailure(
                BridgeCode.badConfig,
                "initialize: \(backend) is not https. Plain http is accepted only for a local stack "
                    + "(localhost, a .local name or a private address)."
            )
        }

        /*
         * Milliseconds on the wire and seconds on this core, and a non-positive interval is
         * not passed through: it would arm a timer that fires continuously.
         *
         * An absent key takes the generated default. The call below has to name a value either
         * way — Swift cannot leave an argument out conditionally, and the wrapper sends the key
         * as `undefined` when the integrator omitted it — and naming `TreebarsConstants` rather
         * than a literal keeps one copy of the default, which moves when the core's does.
         */
        let configuredFlush = (config["flush_interval_ms"] as? NSNumber)
            .map { $0.doubleValue / 1000 } ?? TreebarsConstants.defaultFlushInterval
        let flushInterval =
            configuredFlush > 0 ? configuredFlush : TreebarsConstants.defaultFlushInterval

        /*
         * `in_app_enabled: false` has no parameter of its own on this core, so it is expressed
         * as the one lever that does: the poll is turned off, and `disableInApps` below stops what the core draws
         * by itself. What remains is the single sync `initialize` runs on the way up, which fills
         * the inbox and draws nothing.
         */
        let inAppEnabled = (config["in_app_enabled"] as? Bool) ?? true
        let configuredPoll = (config["in_app_poll_interval_ms"] as? NSNumber)
            .map { $0.doubleValue / 1000 } ?? TreebarsConstants.defaultInAppPollInterval
        let pollInterval = inAppEnabled ? max(0, configuredPoll) : 0

        let adopt = config["adopt"] as? [String: Any] ?? [:]

        Treebars.initialize(
            writeKey: writeKey,
            backendURL: backendURL,
            env: (config["env"] as? String).flatMap(TreebarsEnv.init(rawValue:)) ?? .production,
            flushInterval: flushInterval,
            debug: (config["debug"] as? Bool) ?? false,
            autoTrackLifecycle: (config["auto_track_lifecycle"] as? Bool) ?? true,
            autoTrackSessions: (config["auto_track_sessions"] as? Bool) ?? true,
            inAppPollInterval: pollInterval,
            adopt: Adoption(
                deviceId: adopt["deviceId"] as? String,
                fetchSecret: adopt["fetchSecret"] as? String,
                firstSeenAt: adopt["firstSeenAt"] as? String,
                signedInUser: adopt["signedInUser"] as? String,
                identifiedUser: adopt["identifiedUser"] as? String,
                inAppLedgerJson: adopt["inAppLedgerJson"] as? String,
                sdkName: adopt["sdkName"] as? String
            ),
            // Absent is false, the core's own default: consent is never assumed on anybody's behalf.
            acquisitionConsent: (config["acquisition_consent"] as? Bool) ?? false,
            deferredHandoff: (config["deferred_handoff"] as? Bool) ?? false,
            // The app's own associated domains; absent asks nothing, the core's own default.
            linkHosts: (config["link_hosts"] as? [String]) ?? []
        )

        // The core draws an HTML message itself, and a standard one too when no renderer is registered, so no renderer
        // does not mean nothing is drawn: `in_app_enabled: false` has to say so to the core as well.
        if !inAppEnabled { Treebars.disableInApps() }

        Treebars.setUploadListener { log in
            guard let json = encode(UploadLogWire(log)) else { return }
            uploadSink(json)
        }

        // Replaced rather than added to, so a second `initialize` — which Metro fast-refresh
        // produces, and which the core itself ignores — does not leave two watchers emitting
        // the same page twice.
        notificationsUnsubscribe?()
        notificationsUnsubscribe = Treebars.onNotificationsChange { page in
            guard let json = encode(NotificationPageWire(page)) else { return }
            notificationsSink(json)
        }

        isStarted = true
        return nil
    }

    /// Drops everything that reaches back into a runtime that may be going away.
    ///
    /// Called from the module's `invalidate`. The listeners above are held by a singleton that
    /// outlives every reload, so without this a torn-down bridge goes on being handed pages
    /// and upload logs it can only forward into a dead JavaScript runtime.
    @objc(detach)
    public static func detach() {
        Treebars.setInAppRenderer(nil)
        Treebars.setUploadListener(nil)
        _ = setEventsSubscribed("[]", sink: nil)
        notificationsUnsubscribe?()
        notificationsUnsubscribe = nil
    }

    @objc(reset)
    public static func reset() {
        Treebars.reset()
    }

    @objc(flush)
    public static func flush() {
        Treebars.flush()
    }

    /// Not gated on the bridge having started: the core keeps an opt-out made before `initialize`.
    @objc(optOut)
    public static func optOut() {
        Treebars.optOut()
    }

    @objc(optIn)
    public static func optIn() {
        Treebars.optIn()
    }

    @objc(isOptedOut)
    public static func isOptedOut() -> Bool {
        Treebars.isOptedOut
    }

    /// `Treebars.contextToken()`, lower-case, which is how every consumer but StoreKit takes it and how the server mints
    /// it — and JavaScript hands StoreKit a string anyway. Nil in every case the core says nil: the purchase goes ahead.
    @objc(contextToken:)
    public static func contextToken(_ completion: @escaping @Sendable (String?) -> Void) {
        Task { completion(await Treebars.contextToken()?.uuidString.lowercased()) }
    }

    @objc(wipeLocalData)
    public static func wipeLocalData() {
        Treebars.wipeLocalData()
    }

    /// Forwarded as-is. The core holds a grant made before `initialize`, so this is not gated on
    /// the bridge having started — refusing would make the bridge stricter than the core.
    /// The completion carries the link's deep-link path when a Universal Link was asked about, else nil.
    @objc(handleLink:completion:)
    public static func handleLink(_ url: String, completion: @escaping (String?) -> Void) {
        Treebars.handleLink(URL(string: url), completion: completion)
    }

    @objc(setAcquisitionConsent:)
    public static func setAcquisitionConsent(_ granted: Bool) {
        Treebars.setAcquisitionConsent(granted)
    }

    // ------------------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------------------

    @objc(track:propertiesJson:)
    public static func track(_ eventName: String, propertiesJson: String) -> TreebarsBridgeFailure? {
        guard let properties = dictionary(propertiesJson) else {
            return badProperties("track")
        }
        Treebars.log(eventName, properties: properties)
        return nil
    }

    @objc(screen:propertiesJson:)
    public static func screen(_ name: String, propertiesJson: String) -> TreebarsBridgeFailure? {
        guard let properties = dictionary(propertiesJson) else {
            return badProperties("screen")
        }
        Treebars.screen(name, properties: properties)
        return nil
    }

    @objc(identify:attributesJson:signature:)
    public static func identify(_ userId: String, attributesJson: String, signature: String?) -> TreebarsBridgeFailure? {
        guard let attributes = dictionary(attributesJson) else {
            return badProperties("identify")
        }
        Treebars.identify(userId, attributes: attributes, signature: signature)
        return nil
    }

    @objc(registerPushToken:provider:)
    public static func registerPushToken(_ token: String, provider: String) -> TreebarsBridgeFailure? {
        guard let kind = PushProvider(rawValue: provider) else {
            return TreebarsBridgeFailure(
                BridgeCode.badPayload,
                "registerPushToken: `\(provider)` is not a push provider this SDK knows"
            )
        }

        guard Treebars.registerPushToken(hex: token, provider: kind) else {
            return TreebarsBridgeFailure(
                BridgeCode.badPayload,
                "registerPushToken: an APNs token must be hexadecimal, and this one is not"
            )
        }
        return nil
    }

    @objc(trackNotificationOpened:)
    public static func trackNotificationOpened(_ payloadJson: String) -> TreebarsBridgeFailure? {
        guard let payload = dictionary(payloadJson) else {
            return TreebarsBridgeFailure(
                BridgeCode.badPayload,
                "trackNotificationOpened: the payload could not be read as JSON"
            )
        }
        // Straight through, unread: the core picks out `delivery_id` and `campaign_id` at the
        // root and does nothing when they are absent, which is what makes it safe to call for
        // every notification an app handles including ones we did not send.
        Treebars.trackNotificationOpened(userInfo: payload)
        return nil
    }

    /// A swipe-away, for an app whose own notification library sees one: `push_dismissed`.
    @objc(trackNotificationDismissed:)
    public static func trackNotificationDismissed(_ payloadJson: String) -> TreebarsBridgeFailure? {
        guard let payload = dictionary(payloadJson) else {
            return TreebarsBridgeFailure(
                BridgeCode.badPayload,
                "trackNotificationDismissed: the payload could not be read as JSON"
            )
        }
        Treebars.trackNotificationDismissed(userInfo: payload)
        return nil
    }

    /*
     React Native's `setEventListener` events, forwarded from the core's delegate and push action
     handler and nothing more: the core decides what happened, this marshals it. Each event kind is subscribed on its
     own, because one of them changes behaviour — while JavaScript listens to `inAppCampaignSelfHandled`, a self-handled
     message goes there instead of the renderer. A push action that arrived before anybody listened is held by the core
     and delivered on subscribing.
     */
    @MainActor
    private final class BridgeInAppDelegate: TreebarsInAppDelegate {
        var names: Set<String> = []
        var emit: (String, Any) -> Void = { _, _ in }
        var handlesSelfHandledInApps: Bool { names.contains("inAppCampaignSelfHandled") }

        private func ref(_ message: InAppMessage) -> [String: Any] {
            var ref: [String: Any] = ["delivery_id": message.delivery_id]
            if let campaign = message.campaign_id { ref["campaign_id"] = campaign }
            return ref
        }

        func inAppShown(_ message: InAppMessage) {
            if names.contains("inAppCampaignShown") { emit("inAppCampaignShown", ref(message)) }
        }

        func inAppDismissed(_ message: InAppMessage) {
            if names.contains("inAppCampaignDismissed") { emit("inAppCampaignDismissed", ref(message)) }
        }

        func inAppClicked(_ message: InAppMessage, action: InAppClickAction) {
            var payload: [String: Any] = ["source": "in_app", "type": action.type, "values": action.values, "delivery_id": message.delivery_id]
            if let index = action.button.index { payload["button_index"] = index }
            if names.contains("inAppCampaignClicked") { emit("inAppCampaignClicked", payload) }
            if action.type == "custom", names.contains("inAppCampaignCustomAction") { emit("inAppCampaignCustomAction", payload) }
        }

        func selfHandledInAppTriggered(_ message: InAppMessage) {
            TreebarsBridge.remember(message)
            if let object = TreebarsBridge.jsonObject(message) { emit("inAppCampaignSelfHandled", object) }
        }
    }

    @MainActor private static let bridgeDelegate = BridgeInAppDelegate()

    /// Self-handled messages handed to JavaScript, by delivery id, so its reports can name them. Bounded.
    nonisolated(unsafe) private static var selfHandledMessages: [String: InAppMessage] = [:]
    private static let selfHandledLock = NSLock()

    fileprivate static func remember(_ message: InAppMessage) {
        selfHandledLock.lock()
        defer { selfHandledLock.unlock() }
        if selfHandledMessages.count >= 32 { selfHandledMessages.removeAll() }
        selfHandledMessages[message.delivery_id] = message
    }

    private static func remembered(_ deliveryId: String) -> InAppMessage? {
        selfHandledLock.lock()
        defer { selfHandledLock.unlock() }
        return selfHandledMessages[deliveryId]
    }

    fileprivate static func jsonObject(_ message: InAppMessage) -> Any? {
        guard let data = try? JSONEncoder().encode(message) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    @objc(setEventsSubscribed:sink:)
    public static func setEventsSubscribed(_ namesJson: String, sink: (@Sendable (String) -> Void)?) -> TreebarsBridgeFailure? {
        guard let data = namesJson.data(using: .utf8), let list = try? JSONDecoder().decode([String].self, from: data) else {
            return TreebarsBridgeFailure(BridgeCode.badPayload, "setEventsSubscribed: the event names are not a JSON list")
        }
        let names = sink == nil ? [] : Set(list)
        let emit: @Sendable (String, Any) -> Void = { name, payload in
            guard let sink,
                  let data = try? JSONSerialization.data(withJSONObject: ["name": name, "data": payload]),
                  let text = String(data: data, encoding: .utf8) else { return }
            sink(text)
        }
        Task { @MainActor in
            bridgeDelegate.names = names
            bridgeDelegate.emit = emit
            Treebars.setInAppDelegate(names.isEmpty ? nil : bridgeDelegate)
        }
        if names.contains("pushClicked") {
            Treebars.setPushActionHandler { type, values in
                emit("pushClicked", ["source": "push", "type": type, "values": values])
            }
        } else {
            Treebars.setPushActionHandler(nil)
        }
        return nil
    }

    /// The app's contexts, as a JSON list of names.
    @objc(setInAppContext:)
    public static func setInAppContext(_ contextsJson: String) -> TreebarsBridgeFailure? {
        guard let data = contextsJson.data(using: .utf8),
              let contexts = try? JSONDecoder().decode([String].self, from: data)
        else {
            return TreebarsBridgeFailure(BridgeCode.badPayload, "setInAppContext: the contexts are not a JSON list of names")
        }
        Treebars.setCurrentInAppContexts(contexts)
        return nil
    }

    @objc(resetInAppContext)
    public static func resetInAppContext() {
        Treebars.invalidateInAppContexts()
    }

    @objc(showInApp)
    public static func showInApp() {
        Treebars.showInApp()
    }

    /// Nudges may appear on this screen: `top`, `bottom`, or anything else for any edge.
    @objc(showNudge:)
    public static func showNudge(_ position: String) {
        Treebars.showNudge(atPosition: position == "top" ? .top : position == "bottom" ? .bottom : .any)
    }

    /// Every self-handled message eligible now, as a JSON list, to `completion`.
    @objc(getSelfHandledInApps:)
    public static func getSelfHandledInApps(_ completion: @escaping @Sendable (String) -> Void) {
        Treebars.getSelfHandledInApps { messages in
            messages.forEach(remember)
            let list = messages.compactMap(jsonObject)
            let data = (try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8)
            completion(String(data: data, encoding: .utf8) ?? "[]")
        }
    }

    @objc(selfHandledShown:)
    public static func selfHandledShown(_ deliveryId: String) -> TreebarsBridgeFailure? {
        guard let message = remembered(deliveryId) else { return unknownSelfHandled(deliveryId) }
        Treebars.selfHandledShown(campaignInfo: message)
        return nil
    }

    @objc(selfHandledClicked:buttonJson:)
    public static func selfHandledClicked(_ deliveryId: String, buttonJson: String) -> TreebarsBridgeFailure? {
        guard let message = remembered(deliveryId) else { return unknownSelfHandled(deliveryId) }
        let button = buttonJson.isEmpty ? nil : buttonJson.data(using: .utf8).flatMap { try? JSONDecoder().decode(InAppButton.self, from: $0) }
        Treebars.selfHandledClicked(campaignInfo: message, button: button)
        return nil
    }

    @objc(selfHandledDismissed:)
    public static func selfHandledDismissed(_ deliveryId: String) -> TreebarsBridgeFailure? {
        guard let message = remembered(deliveryId) else { return unknownSelfHandled(deliveryId) }
        Treebars.selfHandledDismissed(campaignInfo: message)
        return nil
    }

    private static func unknownSelfHandled(_ deliveryId: String) -> TreebarsBridgeFailure {
        TreebarsBridgeFailure(BridgeCode.badPayload, "no self-handled message \(deliveryId) was handed to JavaScript")
    }

    /// A form's answers, as a JSON object by field id, for the message with this delivery id.
    @objc(submitInAppForm:responsesJson:)
    public static func submitInAppForm(_ deliveryId: String, responsesJson: String) -> TreebarsBridgeFailure? {
        guard let responses = dictionary(responsesJson) else {
            return TreebarsBridgeFailure(BridgeCode.badPayload, "submitInAppForm: the answers could not be read as JSON")
        }
        Treebars.submitInAppForm(deliveryID: deliveryId, responses: responses)
        return nil
    }

    /// The core's own prompt, provisional when asked. The completion runs once the person has answered.
    @objc(requestPushPermission:completion:)
    public static func requestPushPermission(_ provisional: Bool, completion: @escaping @Sendable (Bool) -> Void) {
        Task { completion(await Treebars.requestPushPermission(provisional: provisional)) }
    }

    // ------------------------------------------------------------------------------------
    // Telemetry: what is waiting, and when it goes
    // ------------------------------------------------------------------------------------

    @objc(pendingCountWithCompletion:)
    public static func pendingCount(completion: @escaping @Sendable (Int) -> Void) {
        Task { completion(await Treebars.pendingCount()) }
    }

    /// Milliseconds, or `-1` when no flush is scheduled.
    ///
    /// `-1` rather than a nullable number because codegen has none, and rather than zero
    /// because "nothing is scheduled" and "a flush is due now" are different sentences — the
    /// wrapper maps it back to null.
    @objc(msUntilNextFlush)
    public static func msUntilNextFlush() -> Int {
        guard let seconds = Treebars.secondsUntilNextFlush() else { return -1 }
        return Int((seconds * 1000).rounded())
    }

    // ------------------------------------------------------------------------------------
    // In-app
    // ------------------------------------------------------------------------------------

    @objc(syncInAppMessages)
    public static func syncInAppMessages() {
        Treebars.syncInAppMessages()
    }

    @objc(inboxList)
    public static func inboxList() -> String? {
        encode(Treebars.inbox())
    }

    @objc(inboxDismiss:)
    public static func inboxDismiss(_ deliveryId: String) {
        Treebars.dismissInboxMessage(deliveryId)
    }

    /// A card came into view, or was tapped (an empty destination is none), and a centre row was opened.
    @objc(inboxViewed:)
    public static func inboxViewed(_ deliveryId: String) {
        Treebars.inboxMessageViewed(deliveryId)
    }

    @objc(inboxClicked:destination:)
    public static func inboxClicked(_ deliveryId: String, destination: String) {
        Treebars.inboxMessageClicked(deliveryId, destination: destination.isEmpty ? nil : destination)
    }

    @objc(notificationsMarkOpened:)
    public static func notificationsMarkOpened(_ groupId: String) {
        Treebars.markNotificationOpened(groupId)
    }

    /**
     Install a renderer that reports presentations to `sink`, or clear it.

     Clearing is not a cosmetic difference. The core draws a standard message itself when no
     renderer is registered (`InAppNativeHost`), so cleared means the native renderer draws: an app
     that registers no JavaScript renderer gets the native one. Until it registers, it has the native one
     too: a trigger answered at launch, or while `detach()` has cleared the renderer for a reload,
     is drawn natively rather than held for the JavaScript host. `in_app_enabled: false` is what
     draws nothing (`disableInApps`).

     The presentation id is minted here rather than in the bridge, so that the id, the JSON
     naming it and the closures it stands for are all produced in one place. Handing them out
     separately would make it possible for a slot to hold an id that does not match its own
     payload.
     */
    @objc(setInAppRendererWithSink:reattaching:)
    public static func setInAppRenderer(
        _ sink: (@Sendable (String, String, TreebarsPresentation) -> Void)?,
        reattaching: Bool
    ) {
        guard let sink else {
            Treebars.setInAppRenderer(nil)
            return
        }

        // `reattaching`: this module installed a renderer before and still holds its presentation.
        let renderer: Treebars.InAppRenderer = { message, tokens, onClick, onDismiss in
            let presentationId = UUID().uuidString
            guard let json = encode(
                PresentationWire(presentationId: presentationId, message: message, tokens: tokens)
            ) else {
                /*
                 * The display has already been recorded and reported by the time a renderer
                 * runs, so there is nothing to hand back and no promise to reject into — the
                 * only honest action left is to say so. Reaching this means a message decoded
                 * from the server will not re-encode, which no wire value should be able to
                 * produce; if it ever appears in a log it is a bug in this file, not in a send.
                 */
                TreebarsLogger.log(
                    "in-app: a message could not be encoded for the bridge",
                    message.delivery_id
                )
                return
            }

            sink(
                presentationId,
                json,
                TreebarsPresentation(onClick: onClick, onDismiss: onDismiss)
            )
        }
        Treebars.setInAppRenderer(renderer, reattaching: reattaching)
    }

    // ------------------------------------------------------------------------------------
    // The notification centre
    // ------------------------------------------------------------------------------------

    @objc(notificationsList:completion:)
    public static func notificationsList(
        _ optionsJson: String,
        completion: @escaping @Sendable (String?, TreebarsBridgeFailure?) -> Void
    ) {
        guard let options = dictionary(optionsJson) else {
            completion(
                nil,
                TreebarsBridgeFailure(
                    BridgeCode.badPayload,
                    "notifications.list: the options could not be read as JSON"
                )
            )
            return
        }

        let limit = (options["limit"] as? NSNumber)?.intValue
        let cursor = options["cursor"] as? String
        let channels = options["channels"] as? [String]

        Task {
            let page = await Treebars.notifications(limit: limit, cursor: cursor, channels: channels)
            guard let json = encode(NotificationPageWire(page)) else {
                completion(
                    nil,
                    TreebarsBridgeFailure(
                        BridgeCode.badPayload,
                        "notifications.list: the page could not be encoded"
                    )
                )
                return
            }
            completion(json, nil)
        }
    }

    @objc(notificationsMarkRead:)
    public static func notificationsMarkRead(_ groupId: String) {
        Treebars.markNotificationRead(groupId)
    }

    @objc(notificationsMarkAllRead)
    public static func notificationsMarkAllRead() {
        Treebars.markAllNotificationsRead()
    }

    @objc(notificationsDismiss:)
    public static func notificationsDismiss(_ groupId: String) {
        Treebars.dismissNotification(groupId)
    }

    // ------------------------------------------------------------------------------------
    // Marshalling
    // ------------------------------------------------------------------------------------

    /// A JSON object, or nil. Never an empty dictionary standing in for a failed parse.
    private static func dictionary(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any]
        else { return nil }
        return object
    }

    private static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func badProperties(_ method: String) -> TreebarsBridgeFailure {
        TreebarsBridgeFailure(
            BridgeCode.badPayload,
            "\(method): the properties could not be read as a JSON object"
        )
    }
}

// ----------------------------------------------------------------------------------------
// The wire shapes, which are the React Native SDK's types rather than this core's
// ----------------------------------------------------------------------------------------

/// `{ presentationId, message, tokens }`, as `NativeTreebars.ts` declares it.
private struct PresentationWire: Encodable {
    let presentationId: String
    let message: InAppMessage
    let tokens: InAppTokens?

    enum CodingKeys: String, CodingKey {
        case presentationId, message, tokens
    }

    /// `encode` and not `encodeIfPresent` for the tokens, deliberately.
    ///
    /// The wrapper's type is `InAppTokens | null`, and a synthesized encoder would omit the
    /// key instead — leaving a renderer to tell "the project set no theme" apart from "this
    /// build of the bridge does not send one", which it cannot.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(presentationId, forKey: .presentationId)
        try container.encode(message, forKey: .message)
        try container.encode(tokens, forKey: .tokens)
    }
}

/// `NotificationPage` is the one public type here that is not `Codable`, because nothing in
/// this core sends one anywhere. The bridge does.
private struct NotificationPageWire: Encodable {
    let notifications: [TreebarsNotification]
    let unreadCount: Int
    let nextCursor: String?
    let fromCache: Bool

    init(_ page: NotificationPage) {
        notifications = page.notifications
        unreadCount = page.unreadCount
        nextCursor = page.nextCursor
        fromCache = page.fromCache
    }

    enum CodingKeys: String, CodingKey {
        case notifications, unreadCount, nextCursor, fromCache
    }

    /// Explicit for `nextCursor` for the reason `PresentationWire` gives: the wrapper declares
    /// `string | null`, and an absent key would read as the end of the list either way — which
    /// is right by accident here and wrong the moment anybody checks for the key itself.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(notifications, forKey: .notifications)
        try container.encode(unreadCount, forKey: .unreadCount)
        try container.encode(nextCursor, forKey: .nextCursor)
        try container.encode(fromCache, forKey: .fromCache)
    }
}

/// `UploadLog`, field for field, as the wrapper's `onUpload` hands it to the app.
///
/// Optionals stay `encodeIfPresent` here, unlike the two above: the wrapper's type declares
/// them optional rather than nullable, so a null would be a value the reader does not expect.
private struct UploadLogWire: Encodable {
    let type: String
    let status: String
    let message: String
    let count: Int?
    let eventNames: [String]?
    let statusCode: Int?

    init(_ log: UploadLog) {
        type = log.type
        status = log.status
        message = log.message
        count = log.count
        eventNames = log.eventNames
        statusCode = log.statusCode
    }
}

extension Treebars {
    /**
     The same registration, from a token that is already a string.

     Every wrapper holds a string — `getAPNSToken()` returns hex, and a `Data` never crosses a
     bridge — and the obvious conversion is the wrong one: `token.data(using: .utf8)` compiles,
     produces a registration twice the correct length, and is invisible until a campaign
     under-delivers to devices that look perfectly healthy. So the conversion lives here, next
     to the entry point it feeds, rather than in each wrapper.

     Returns false when an APNs token is not hexadecimal, which is the only way this can fail.
     Registering it anyway would register a token that APNs answers `BadDeviceToken` for — the
     same answer an uninstalled app gives, so it would read as an audience that had
     churned rather than as a bad string.

     **FCM does not go through the `Data` entry point**, and must not: an FCM token is an opaque
     string rather than bytes, so hex-decoding it fails and hex-encoding it corrupts it. The
     event it reports is the same one, minus the `apns_environment` that entry point attaches —
     which is exactly what it does for `.fcm` anyway, since stamping an Apple entitlement onto a
     Google token would make the value mean nothing.
     */
    @discardableResult
    public static func registerPushToken(hex token: String, provider: PushProvider = .apns) -> Bool {
        switch provider {
        case .apns:
            guard let data = Data(treebarsHex: token) else { return false }
            Treebars.registerPushToken(data, provider: .apns)
            return true
        case .fcm:
            Treebars.log(
                "push_token_registered",
                properties: ["token": token, "provider": provider.rawValue]
            )
            Treebars.flush()
            return true
        }
    }
}

extension Data {
    /// Bytes from an even-length hexadecimal string, or nil.
    ///
    /// Nil rather than a best effort: half a device token is not a device token, and the
    /// server has no way to tell a truncated one from a real one.
    init?(treebarsHex hex: String) {
        let digits = Array(hex.utf8)
        guard !digits.isEmpty, digits.count % 2 == 0 else { return nil }

        // Checked as bytes rather than left to `UInt8(_:radix:)`, which accepts a leading `+`
        // — so a pair like `+f` would parse as a byte and a malformed token would register.
        func value(_ digit: UInt8) -> UInt8? {
            switch digit {
            case 0x30...0x39: return digit - 0x30           // 0-9
            case 0x61...0x66: return digit - 0x61 + 10      // a-f
            case 0x41...0x46: return digit - 0x41 + 10      // A-F
            default: return nil
            }
        }

        var bytes = [UInt8]()
        bytes.reserveCapacity(digits.count / 2)
        for pair in stride(from: 0, to: digits.count, by: 2) {
            guard let high = value(digits[pair]), let low = value(digits[pair + 1]) else {
                return nil
            }
            bytes.append(high << 4 | low)
        }

        self.init(bytes)
    }
}
