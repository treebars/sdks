import CryptoKit
import Foundation
#if canImport(UIKit)
import StoreKit
import UIKit
import WebKit
#endif

/**
 What a wrapper hands down from a store this SDK cannot read, for `Treebars.initialize(adopt:)`.

 Every field is nil by default, and each is written only into a key that is currently empty —
 see `adopt` on `Treebars.initialize` for why that rule is what makes this safe.

 The in-app ledger crosses as an opaque JSON string rather than as a type: the wrapper's shape
 is its own, and it is not parsed here. What matters is that its `done` map survives, because
 that map is what stops a message somebody already dismissed from being shown again. Without it,
 every message still pending would be drawn again on the first launch after the handover — to a
 person who already said no.
 */
public struct Adoption: Sendable {
    public let deviceId: String?
    public let fetchSecret: String?
    public let firstSeenAt: String?
    public let signedInUser: String?
    public let identifiedUser: String?
    public let inAppLedgerJson: String?
    /// The SDK name a wrapper reports in place of this one's, so its installs stay distinguishable
    /// from native ones: `platform_type` names the OS either way.
    public let sdkName: String?

    public init(
        deviceId: String? = nil,
        fetchSecret: String? = nil,
        firstSeenAt: String? = nil,
        signedInUser: String? = nil,
        identifiedUser: String? = nil,
        inAppLedgerJson: String? = nil,
        sdkName: String? = nil
    ) {
        self.deviceId = deviceId
        self.fetchSecret = fetchSecret
        self.firstSeenAt = firstSeenAt
        self.signedInUser = signedInUser
        self.identifiedUser = identifiedUser
        self.inAppLedgerJson = inAppLedgerJson
        self.sdkName = sdkName
    }

    func apply() {
        let defaults = UserDefaults.standard

        func claim(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            // The guard, and the only one that matters: a key that already holds something is
            // this device's own answer and outranks anything a wrapper remembers. An empty
            // string is nothing rather than a value — a device id of "" would be worse than
            // none, because the key would then read as answered forever.
            guard defaults.object(forKey: key) == nil else { return }
            defaults.set(value, forKey: key)
        }

        // The id and its secret go to the identity store as one pair, never to `UserDefaults`, which a
        // backup carries to another phone (`DeviceIdentityStore`).
        if let deviceId, !deviceId.isEmpty {
            DeviceInfo.adopt(id: deviceId, secret: fetchSecret)
        }
        claim(TreebarsConstants.keyFirstSeenAt, firstSeenAt)
        claim(TreebarsConstants.keySignedInUser, signedInUser)
        claim("treebars.identified_user", identifiedUser)
        claim("treebars.in_app_ledger", inAppLedgerJson)
    }
}

/// A label for `Treebars.initialize`'s `env`, which the SDK accepts and does not read: the write key is
/// what names the environment.
public enum TreebarsEnv: String {
    case production, stage, test
}

/// Which service issued a push token (`Treebars.registerPushToken`): Apple's APNs, or Firebase Cloud Messaging.
public enum PushProvider: String {
    case apns, fcm
}

/// The Treebars iOS SDK.
///
/// Call `initialize` once, at launch; everything else is a static call on this type. Events are
/// written to a queue on disk that survives the process being killed, and uploaded in batches —
/// on a timer, when the app leaves the foreground, and on `flush()` — with exponential backoff
/// when the network fails. The Android SDK behaves the same way, and the React Native SDK is a
/// bridge over this one.
public final class Treebars {
    public static let shared = Treebars()

    /// `log`'s events not yet on the queue, which a `flush()` waits for.
    let recording = InFlight()

    /// The keys Treebars puts into a push's payload so a tap can be traced back to the send.
    /// `trackNotificationOpened(userInfo:)` and `trackNotificationDismissed(userInfo:)` read them.
    ///
    /// Shared with the Android and React Native SDKs and with the server that writes them, so a
    /// rename on one side alone would stop opens being counted, with no error to say so.
    public static let deliveryIdKey = TreebarsConstants.deliveryIdKey
    public static let campaignIdKey = TreebarsConstants.campaignIdKey

    /// The intervals `initialize` uses when none is passed, in seconds: `flushInterval` and
    /// `inAppPollInterval`.
    ///
    /// Taken from the values every Treebars SDK shares, so they cannot drift from the other
    /// platforms. Public because a public function's default argument may name only public
    /// declarations.
    public static let defaultFlushInterval = TreebarsConstants.defaultFlushInterval
    public static let defaultInAppPollInterval = TreebarsConstants.defaultInAppPollInterval

    /// The events the SDK emits on its own. The names are reserved for the SDK.
    public enum DefaultEvent {
        public static let appOpen = "app_open"
        public static let appForeground = "app_foreground"
        public static let appBackground = "app_background"
        public static let sessionStart = "session_start"
        public static let sessionEnd = "session_end"
        public static let screenView = "screen_view"
        public static let userIdentified = "user_identified"
        public static let userSignedOut = "user_signed_out"
        public static let notificationRead = "notification_read"
        public static let notificationDismissed = "notification_dismissed"
        /// Once per install, with consent. See `Acquisition.swift`.
        public static let appleAdsAttribution = "apple_ads_attribution"
    }

    /// Traits a message set with nobody signed in, sent on the event queue because `/v1/identify` needs an account id.
    /// The name is reserved for the SDK. The values go on the person and are kept out of analytics, which records only
    /// their names (`trait_keys`), as it does for `user_identified`.
    static let traitsSetEvent = "traits_set"

    private static let identifiedUserKey = "treebars.identified_user"
    /// The person's `optOut()`, in `UserDefaults`: their answer travels with a backup, as it should.
    private static let optedOutKey = "treebars.opted_out"

    private var writeKey: String?
    /// `initialize`'s `env`, kept as passed. Nothing reads it.
    private var env: TreebarsEnv = .production
    /*
     * `userId`, `optedOut` and `userSignature` are internal rather than private for one reader,
     * `ContextTokenTests`, which signs in or opts out an instance of its own: the public doors to
     * them are static, and every static acts on `shared`.
     */
    var userId: String?
    /// `optOut()`: nothing recorded and nothing sent until `optIn()`. Kept in `UserDefaults`, and set
    /// in memory by an `optOut()` made before `initialize`, which then keeps it.
    var optedOut = false
    /// The app's backend's signature of `userId`, which an environment that requires signed identities
    /// asks for on every content read. Kept beside the id and cleared with it: a signature is only ever
    /// a claim about the person it names.
    var userSignature: String?
    /// Whether the app has been told its environment wants a signature. Once per process is enough.
    private var warnedSignature = false

    private var autoTrackLifecycle = true
    private var autoTrackSessions = true

    private var currentScreen: String?

    /*
     * The in-app queue, the ledger of what this device has drawn, and the app's renderer.
     *
     * In-app is on unless the app turns it off: this SDK draws an HTML message itself, and a standard one from its
     * render plan when no renderer is registered. What turns in-app off is `disableInApps()`; a renderer overrides how
     * a standard message is drawn, not whether one is.
     */
    /**
     The SDK's own engagement reports, which must never trigger another message: every `in_app_` name. A prefix rather
     than a list, so a new report is covered without a change here; a message's own `trackEvent` may not use the
     prefix. Android's `isInAppReport` is the same rule.
     */
    private static func isInAppReport(_ eventName: String) -> Bool { eventName.hasPrefix("in_app_") }
    /// The app's contexts, its in-app delegate, the screens it blocks, and the message waiting out its delay.
    private var appContexts: Set<String> = []
    private weak var inAppDelegate: TreebarsInAppDelegate?
    private var blockedScreens: Set<String> = []
    private var delayedDelivery: String?
    /// The nudges' slots, and where the app last allowed nudges (`showNudge`): the screen then, and the edge it asked for.
    private let nudgeSlots = NudgeSlots(capacity: InAppBridge.nudgeMaxOnScreen)
    private var nudgePlace: (screen: String?, position: TreebarsNudgePosition)?
    private let inApp = InAppStore()
    /// The files the held messages load, fetched after each sync and kept by hash, under Caches —
    /// which the system may empty; a file it took is fetched again.
    private let assetCache: InAppAssetCache = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let cache = InAppAssetCache(directory: caches.appendingPathComponent("treebars-assets", isDirectory: true))
        InAppAssetCache.shared = cache
        return cache
    }()
    private var inAppRenderer: InAppRenderer?
    private var inAppEnabled = true
    #if canImport(UIKit)
    /// The HTML message on screen, drawn by this SDK, or nil.
    @MainActor private var htmlHost: InAppHtmlHost?
    /// The standard message on screen, drawn by this SDK from its plan because no renderer was registered, or nil. It
    /// shares `presentation` with the HTML host and the app's renderer: one message at a time.
    @MainActor private var nativeHost: InAppNativeHost?
    /// The nudges on screen, by delivery: a slot of their own beside `presentation`, so a modal may
    /// be drawn over nudges and neither waits for the other.
    @MainActor private var nudgeHosts: [String: InAppHtmlHost] = [:]
    /// `setInAppWebViewCustomizer`: the app's hook on the WebView an HTML message is drawn in.
    @MainActor private var webViewCustomizer: ((WKWebView) -> Void)?
    /// Whether this process has drawn an HTML message: the first one pays for the web content process (`cold`).
    @MainActor private var htmlDrawnInProcess = false
    #endif
    private var inAppPollTimer: Timer?

    /*
     * The notification centre's cache, and everyone watching it.
     *
     * Always live, unlike the overlay renderer: reading a history draws nothing over
     * anybody's app, and an app that never asks pays only the one UserDefaults read the
     * store does on construction.
     */
    private let notificationStore = NotificationStore()
    private var notificationWatchers: [UUID: (NotificationPage) -> Void] = [:]
    /// Whatever `server_time` the last successful page carried. The mark-all watermark.
    private var lastNotificationServerTime: String?
    private var foregroundedAt: TimeInterval = 0
    private var backgroundedAt: TimeInterval = 0
    private var firstSeenAt: String?
    private var firstLaunch = false

    private var acquisitionConsent = false
    private var acquisition: AcquisitionCapture?
    /// Off unless the host app asked: reading a pasteboard it did not write spends Apple's prompt.
    private var deferredHandoff = false
    /// The app's own link domains, the only hosts `handleLink` asks about (`initialize`'s `linkHosts`).
    private var linkHosts: Set<String> = []
    private let deferredDeepLink = DeferredDeepLink()
    private var deepLinkListener: ((String) -> Void)?

    private let sessionManager: SessionManager

    /**
     Seconds this app had been idle when this launch began. Zero on a first-ever launch.

     Read once, lazily, on the FIRST use — and `SessionManager` stamps the activity time to now as
     soon as it resolves a session, so this reads `UserDefaults` directly at `initialize` time
     instead of asking it. One launch, one value: the question a return answers is how long somebody
     had been away before this launch brought them back, and a link that opens the app is the launch.

     The threshold that turns a gap into a re-engagement is not applied here. Each core reports the
     fact only it can measure and the server decides what it means, because a number baked into four
     SDKs takes four releases to change.
     */
    private var idleAtLaunch: TimeInterval = 0
    private let queue: EventQueue
    private var backendClient: BackendClient?
    private var uploader: EventUploader?
    private var triggers: TriggerEvents?
    private var flushTimer: Timer?

    private static let batchSize = TreebarsConstants.batchSize

    /**
     `shared` is the only instance the SDK makes. The parameters are `ContextTokenTests`', which builds one over a
     session store, a clock and a queue file of its own: `shared` initializes once per process, over the real stores, and
     starts timers, observers and a sync that no test could take back.
     */
    init(sessionManager: SessionManager = SessionManager(), queue: EventQueue = EventQueue()) {
        self.sessionManager = sessionManager
        self.queue = queue
    }

    /**
     Starts the SDK. Call it once, at launch; later calls are ignored.

     Records `app_open` (unless `autoTrackLifecycle` is false), uploads whatever an earlier launch left
     unsent, and fetches this device's in-app messages — none of which `initialize` waits for. A user
     signed in on an earlier launch is restored, so there is no need to call `identify` again on every
     launch just to keep them signed in.

     - Parameters:
       - writeKey: The environment's public write key, from the project's settings.
       - backendURL: The ingest endpoint — `https://ingest.treebars.com`, or a proxy of your own. It must
         be https: plain http is accepted only for a local development server (loopback, a `.local` name
         or a private address), and any other URL leaves the SDK off, with a warning in the console.
       - env: Accepted and not read: no event or request carries it, and passing a different value
         changes nothing this SDK does. The write key is what names the environment — each environment
         of a project has its own, so the key an app is built with is the whole of that choice.
       - flushInterval: Seconds between automatic uploads.
       - debug: Logs what the SDK does to the console.
       - autoTrackLifecycle: Records `app_open`, `app_foreground` and `app_background`. Turning it off
         also turns off the upload made as the app goes to the background, so call `flush()` from your
         own scene handler instead.
       - autoTrackSessions: Records `session_start` and `session_end`.
       - inAppPollInterval: Seconds between in-app syncs while the app stays open; zero turns the poll off.
       - adopt: Values a wrapper such as the React Native SDK hands down from its own store, written only
         where this SDK holds nothing yet.
       - acquisitionConsent: Whether this install may ask Apple's AdServices how it arrived. Off by
         default; `setAcquisitionConsent(_:)` can grant it later.
       - deferredHandoff: Whether the first launch of a new install reads the click a Treebars link left
         on the pasteboard, which makes iOS show its "Allow Paste" alert once. Off by default.
       - linkHosts: The app's associated domains for Universal Links: the only hosts `handleLink` asks
         what a link means.
     */
    public static func initialize(
        writeKey: String,
        backendURL: URL,
        env: TreebarsEnv = .production,
        flushInterval: TimeInterval = Treebars.defaultFlushInterval,
        debug: Bool = false,
        /// Emit `app_open`, `app_foreground` and `app_background` automatically.
        ///
        /// Turning this off also turns off the flush that rides on backgrounding, which is
        /// the last reliable moment to upload before the process may be suspended or
        /// killed. An app that opts out should call `flush()` from its own scene handler.
        autoTrackLifecycle: Bool = true,
        /// Emit `session_start` and `session_end` around session boundaries.
        autoTrackSessions: Bool = true,
        /// How often to re-pull the in-app queue while the app stays open. Zero disables it.
        inAppPollInterval: TimeInterval = Treebars.defaultInAppPollInterval,
        /**
         Values a wrapper is handing down from its own store, honoured only into an empty one.

         For a wrapper that kept the device's identity in storage of its own before handing it
         to this SDK — the React Native SDK's JavaScript layer, whose AsyncStorage this SDK
         cannot read. The wrapper reads `device_id`, `fetch_secret`, `first_seen_at` and the two
         user keys from its store and passes them in here.

         Each one matters. The device id and its secret belong together, and an install that
         loses them becomes a new device: the person's history splits, and their push token,
         in-app messages and notification inbox stay with the old one. A missed `first_seen_at`
         reports `is_first_launch: true` on every existing install at once, which fires any
         onboarding campaign filtered on it.

         **Only into an empty store**, which is what makes this safe to pass on every launch
         rather than only the first: once this SDK holds a value it wins, so a wrapper that
         keeps handing down a stale copy cannot overwrite it.
         */
        adopt: Adoption = Adoption(),
        /**
         Whether this install may ask Apple how it arrived — the AdServices answer, sent once as
         `apple_ads_attribution`. **Off unless the host app says otherwise.**

         AdServices needs no tracking permission and this never shows a prompt; the gate is for the
         consent regimes that want agreement before anything about an install's origin is read. An
         app with a prompt passes the answer here, or to `setAcquisitionConsent(_:)` once it has
         one, and nothing is lost by waiting: the answer is owed from the first launch and asked
         for whenever consent arrives. `true` here grants; only the setter withdraws.
         */
        acquisitionConsent: Bool = false,
        /**
         Read the click id a Treebars link handed to this device across the App Store, on the first
         launch of a new install and only with acquisition consent.

         **Off by default, because it costs a prompt.** Reading a pasteboard this app did not write
         makes iOS show its own "Allow Paste" alert once, and that is the app owner's call rather
         than this SDK's. On, it is what makes an install from one of your own links measurable at
         all on iPhone — nothing else survives the App Store — and it is what delivers a deferred
         deep link to `onDeferredDeepLink`. The project's Acquisition settings has the other half of
         the switch; both are needed, and neither alone breaks anything.
         */
        deferredHandoff: Bool = false,
        /**
         The domains this app declares as associated domains for Universal Links — `open.example.com`
         — and the only hosts `handleLink` asks what a link means. Empty asks nothing: a tracker link
         carrying its click id is still reported, and a Universal Link opens the app as it would
         without this SDK. A list the app already has, in its entitlements.
         */
        linkHosts: [String] = []
    ) {
        TreebarsLogger.debug = debug

        let instance = shared
        /*
         * Idempotent, as Android's is. A second call would register the lifecycle observers and
         * arm the timers again against the same singleton — every foreground emitting
         * `app_foreground` twice, and two flush loops racing one queue. Under React Native a
         * second call is routine: a fast refresh re-runs the JavaScript `init()` against a native
         * singleton that never went away.
         */
        if instance.writeKey != nil { return }
        /*
         * https, or plain http to a local development server and nothing else (`BackendURL`). Refused
         * rather than trapped: an SDK that crashes the app it ships in over a configuration value is
         * worse than one that stays off and says why.
         */
        guard BackendURL.allows(backendURL) else {
            TreebarsLogger.warn(
                "initialize refused: \(backendURL.absoluteString) is not https. Plain http is accepted only for a local "
                    + "stack (localhost, a .local name or a private address); nothing will be recorded or sent."
            )
            return
        }
        instance.writeKey = writeKey
        instance.linkHosts = Set(linkHosts.map(LinkResolve.normalizeHost).filter { !$0.isEmpty })
        /*
         * What another write key left — its unsent events, its sealed batches, the session whose
         * `session_end` the next touch would send, the messages it fetched — dropped before the idle
         * read below, the session, the queue or the uploader can read it, so none of it is sent or
         * drawn under this key (`WriteKeyStamp`). Synchronous, and first: the queue has not
         * loaded yet, and the in-app and notification stores, which have, are emptied here.
         */
        if WriteKeyStamp.claim(writeKey) {
            instance.inApp.reset()
            instance.notificationStore.reset()
            TreebarsLogger.log("the write key changed: what the previous key left unsent, its session and its messages were dropped")
        }
        /*
         * Before anything resolves a session, which stamps this key to now — one line later the gap
         * is zero and every re-engagement reads as somebody who was already using the app.
         *
         * Zero for a first-ever launch, which refuses: that person is installing rather than
         * returning, and the install path already credits the link they came in on.
         */
        let lastActivity = UserDefaults.standard.double(forKey: TreebarsConstants.keySessionLastActivity)
        instance.idleAtLaunch = lastActivity > 0 ? max(0, Date().timeIntervalSince1970 - lastActivity) : 0
        instance.env = env
        instance.autoTrackLifecycle = autoTrackLifecycle
        instance.autoTrackSessions = autoTrackSessions
        // Grant-only: a `setAcquisitionConsent(_:)` made before this call must not be undone by a
        // parameter nobody passed. Withdrawing is the setter's job alone.
        if acquisitionConsent { instance.acquisitionConsent = true }
        adopt.apply()
        // Identity keys an older version of this SDK kept in `UserDefaults` are removed: a backup would
        // carry them to another phone, and nothing reads them.
        DeviceInfo.legacyIdentityKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        // An opt-out made before this call is kept; one made on an earlier launch is read back.
        if instance.optedOut {
            UserDefaults.standard.set(true, forKey: Self.optedOutKey)
        } else {
            instance.optedOut = UserDefaults.standard.bool(forKey: Self.optedOutKey)
        }
        instance.sdkNameOverride = adopt.sdkName.flatMap { $0.isEmpty ? nil : $0 }
        instance.primeFirstSeen()
        if deferredHandoff { instance.deferredHandoff = true }
        instance.acquisition = AcquisitionCapture(
            handoff: { [weak instance] in
                guard instance?.deferredHandoff == true else { return .empty }
                /*
                 The project's own switch, asked before the pasteboard is touched. `deferredHandoff`
                 is the APP's consent to reading the pasteboard; whether the project's links copy
                 anything is a project setting. Without asking, a URL somebody copied to open in
                 Safari would cost them Apple's "Allow Paste" alert for a project with the feature
                 switched off.

                 Only a definite "off" skips the read. No answer reads anyway, because the handoff is
                 the one exact answer an iPhone install has, and losing it to a dropped request on a
                 first launch is worse than a prompt the project asked for.
                 */
                if await instance?.backendClient?.getHandoffEnabled() == false {
                    TreebarsLogger.log("Handoff: this project has the link handoff off; not reading the clipboard")
                    return .empty
                }
                return await clipboardHandoff()
            },
            carried: { [weak instance] path in
                // Stored rather than delivered here: the read finishes when the pasteboard answers
                // and the app registers its listener when it reaches that line, and neither
                // ordering is wrong. The store decides, and taking is what clears it.
                instance?.deferredDeepLink.remember(path)
                instance?.deliverDeferredDeepLink()
            },
            send: { properties in
                await instance.enqueue(eventName: DefaultEvent.appleAdsAttribution, properties: properties)
            }
        )

        /*
         * Who this install was signed in as, read back before anything asks the server.
         *
         * In-app and notification reads name the signed-in person, so a cold start has to know
         * who that is from its first request — not only once the app calls `identify` again — or
         * that person's messages and inbox are missing until it does.
         *
         * Synchronous and before the task below, which is what launches the first sync.
         */
        instance.userId = UserDefaults.standard.string(forKey: TreebarsConstants.keySignedInUser)
        // And its signature, for the same reason, for an environment that requires signed identities.
        instance.userSignature = instance.userId == nil
            ? nil
            : UserDefaults.standard.string(forKey: TreebarsConstants.keySignedInUserSignature)

        let client = BackendClient(backendURL: backendURL, writeKey: writeKey, deviceSecret: { DeviceInfo.getFetchSecret() })
        let triggers = TriggerEvents(store: TriggerStore()) {
            guard !instance.optedOut else { return nil }
            return (try? await client.getTriggerEvents(deviceID: DeviceInfo.getDeviceId())) ?? nil
        }
        instance.triggers = triggers
        instance.backendClient = client
        /*
         An install that starts opted out drops the batches an earlier launch sealed, before the uploader
         reads them: an opt-out given before this call had no uploader to drop them from (its queue it
         clears itself), and a later `optIn()` would otherwise send events recorded before the "no".
         */
        let uploaderStore = UploaderStore()
        if instance.optedOut { uploaderStore.save(UploaderState()) }
        instance.uploader = EventUploader(
            queue: instance.queue,
            transport: client,
            store: uploaderStore,
            writeKey: writeKey,
            triggers: triggers,
            paused: { instance.optedOut }
        )

        instance.startAutoFlush(interval: flushInterval)
        if autoTrackLifecycle { instance.observeLifecycle() }
        instance.observeActivation()

        TreebarsLogger.log("Initialized")

        // Anything left over from the previous run goes out immediately.
        Task {
            if autoTrackLifecycle {
                instance.foregroundedAt = Date().timeIntervalSince1970
                await instance.enqueue(
                    eventName: DefaultEvent.appOpen,
                    properties: ["is_first_launch": instance.firstLaunch]
                )
            }
            await instance.reportDeviceContext()
            await instance.uploader?.flush()
            /*
             * One sync on the way up, so a message queued while the app was closed is in
             * hand before the first screen finishes drawing. Not awaited by `initialize`,
             * which returns before any of this.
             */
            await instance.syncInApp()
        }

        /*
         * Its own task rather than a step in the one above: the trade with Apple can take a
         * minute of retries, and nothing on the way up should wait on it — not the first upload,
         * and not the in-app sync behind it. It flushes for itself when it has something to send.
         */
        Task { await instance.settleAcquisition() }

        /*
         * Session start and foreground already sync, so this only catches an app left open
         * for a long time. Zero disables it, which is right for anything opened briefly —
         * the poll would never fire before the next session start did the work.
         */
        if inAppPollInterval > 0 {
            /*
             * Armed on the main queue, because `Timer.scheduledTimer` attaches to the CURRENT
             * run loop and a background thread has none running.
             *
             * `initialize` may be called from any thread — a `DispatchQueue.global()` block, a
             * background bootstrap — and a timer armed there is retained and never fires, with
             * no error to say so. The auto-flush timer is armed the same way.
             */
            DispatchQueue.main.async {
                instance.inAppPollTimer?.invalidate()
                instance.inAppPollTimer = Timer.scheduledTimer(
                    withTimeInterval: inAppPollInterval, repeats: true
                ) { _ in
                    Task { await instance.syncInApp() }
                }
            }
        }
    }

    /// Reads — or, on the very first launch, mints — when this install was first seen.
    ///
    /// Two callers want the same fact from opposite directions. `app_open` wants the
    /// boolean, and the user profile wants the timestamp, which is the one date about a
    /// person the SDK can state and the host app usually cannot.
    private func primeFirstSeen() {
        if let existing = UserDefaults.standard.string(forKey: TreebarsConstants.keyFirstSeenAt) {
            firstSeenAt = existing
            firstLaunch = false
            return
        }

        let now = Iso8601.now()
        /*
         The Apple Ads answer is owed from this moment, and only from this one — set beside
         `first_seen_at` so the two agree about whether this install is new. An install that
         already had `first_seen_at` never gets the latch, which is what keeps an app update that
         brings this SDK to existing installs from asking Apple about every one of them at once.
         */
        UserDefaults.standard.set(true, forKey: TreebarsConstants.keyAcquisitionPending)
        UserDefaults.standard.set(now, forKey: TreebarsConstants.keyFirstSeenAt)
        firstSeenAt = now
        firstLaunch = true
    }

    /**
     Report that a link opened this app, so a tracker link that brings somebody back is credited
     (`acq_kind: "return"`).

     Call it where the app already handles links: `onOpenURL` in SwiftUI, or
     `application(_:continue:restorationHandler:)` and `scene(_:openURLContexts:)` in UIKit. Anything
     that is not a Treebars tracker link is ignored, so there is no need to test for that first.

     **A Universal Link on one of the app's `linkHosts` is asked about.** iOS opens the app holding
     only the link's address — `https://open.example.com/summer-sale` — with no click id and no path, so
     the core asks that address what it means, reports the return with the click id it gets back, and
     hands `completion` the link's deep-link path to route on, if it is a path inside the app. Any other
     URL is not asked, answers `completion` with nil, and the app routes it as it always did.
     `completion` runs on the main queue, once.

     **A return never becomes an install.** The install was decided once, when the app first arrived;
     the server keeps that decision, leaves the person's acquisition source alone, and emits a
     separate `reengagement_attributed`. That is what makes it safe to call on every launch.

     Does nothing before `initialize` or while opted out; `completion` is then called with nil.
     */
    public static func handleLink(_ url: URL?, completion: ((String?) -> Void)? = nil) {
        let answer: (String?) -> Void = { path in
            guard let completion else { return }
            DispatchQueue.main.async { completion(path) }
        }
        guard shared.writeKey != nil else {
            TreebarsLogger.log("handleLink before initialize; ignored")
            answer(nil)
            return
        }
        // Opted out: the link is neither reported nor asked about.
        guard !shared.optedOut else {
            answer(nil)
            return
        }
        if let clickId = shared.clickId(from: url) {
            reportLinkOpened(clickId)
            answer(nil)
            return
        }
        guard let address = LinkResolve.candidate(url, hosts: shared.linkHosts) else {
            if shared.linkHosts.isEmpty {
                TreebarsLogger.log("handleLink: initialize was given no linkHosts, so no Universal Link is asked about")
            }
            answer(nil)
            return
        }
        Task {
            let resolved = await LinkResolve.ask(address)
            if let resolved { reportLinkOpened(resolved.clickId) }
            answer(resolved?.deepLinkPath)
        }
    }

    /*
     * `idle_seconds` and not a verdict: the gap is a fact only the device holds, and what it
     * means is one rule on the server, exactly as the referrer's encoding is.
     */
    private static func reportLinkOpened(_ clickId: String) {
        log(
            TreebarsConstants.linkOpenedEvent,
            properties: [
                "click_id": clickId,
                "idle_seconds": Int(shared.idleAtLaunch),
            ]
        )
    }

    /**
     The Treebars click id in a URL, or nil for anything that is not a Treebars tracker link.

     `URLComponents` rather than a substring search: a link arrives with whatever the OS gives it,
     and the parameter name can appear inside a path or another parameter's value.
     */
    private func clickId(from url: URL?) -> String? {
        guard let url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        let value = items.first { $0.name == TreebarsConstants.clickIdParam }?.value
        return (value?.isEmpty == false) ? value : nil
    }

    /**
     Called with the screen a link was for, when somebody installs from one and opens the app.

     The same call as Android's `onDeferredDeepLink`, so one React Native screen subscribes on both
     platforms without asking which it is on. Delivered once per install, ever, and only while the
     install is younger than a day: without "once" every launch would reopen a sale somebody bought
     three weeks ago, and without the window an app that adds a listener in a later version would
     throw its whole installed base into that sale on release day.

     Called on the main queue. Nil clears it, which is what a screen going away needs, and nothing
     is lost — a path is only taken when somebody is listening.

     **It needs `deferredHandoff` on**, because the path arrives with the click id the person
     carried across the App Store, and nothing else on iPhone carries one.
     */
    public static func onDeferredDeepLink(_ listener: ((String) -> Void)?) {
        shared.deepLinkListener = listener
        if listener != nil, shared.writeKey != nil { shared.deliverDeferredDeepLink() }
    }

    /// Hand over whatever is owed, if anybody is listening. Both callers race and the store decides.
    private func deliverDeferredDeepLink() {
        guard let listener = deepLinkListener else { return }
        let installedAt = firstSeenAt.flatMap { Iso8601.millisOrNil($0) }
        guard let path = deferredDeepLink.take(installedAtMs: installedAt, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        else { return }
        DispatchQueue.main.async {
            // The host app's code, so it is theirs to get wrong without taking the SDK with it.
            listener(path)
        }
        TreebarsLogger.log("Deferred deep link delivered: \(path)")
    }

    /// Grants or withdraws consent to ask Apple how this install arrived. See
    /// `acquisitionConsent` on `initialize`, which is where an app that already knows should say.
    ///
    /// Withdrawing stops a trade that has not happened; it cannot recall an answer already sent,
    /// which is an erasure request's job rather than this switch's.
    public static func setAcquisitionConsent(_ granted: Bool) {
        shared.acquisitionConsent = granted
        if granted, shared.writeKey != nil {
            Task { await shared.settleAcquisition() }
        }
    }

    private func settleAcquisition() async {
        guard let acquisition else { return }
        if await acquisition.settle(consented: acquisitionConsent) {
            await uploader?.flush()
        }
    }

    /// Emits `device_context` when this device's context differs from the last reported one.
    ///
    /// A reserved event rather than a bespoke endpoint, so it inherits the batching, retry
    /// and on-disk queue every other event gets, and costs no cold-start round trip. The
    /// hash check is what keeps this rare: after the first launch a device normally reports
    /// nothing until the app or OS is upgraded.
    ///
    /// `force` skips the hash gate. Two callers need it, and both are answering a server
    /// that has said `claim_required`: this device's secret is not registered yet, and
    /// waiting out the seven-day TTL would leave in-app messages and the notification
    /// centre unavailable for a week.
    private func reportDeviceContext(force: Bool = false) async {
        // Read the permission first, so the context this builds is current rather than
        // whatever was true when the process started. `getNotificationSettings` has no
        // synchronous form, which is why this is awaited here rather than read inline.
        await DeviceInfo.refreshPermission()

        /*
         * Before the hash gate, not after it, because the two answer different questions.
         *
         * The gate asks whether this device's description is already on file, and it can
         * be true while a permission flipped and flipped back inside one TTL window. It
         * also returns early, so anything below it is skipped on the common path. A
         * transition happened at a moment in time; it is not derivable from the state that
         * follows it, and must not depend on whether a state report was due.
         */
        if let change = DeviceInfo.pendingPermissionChange() {
            await enqueue(
                eventName: "notification_permission_changed",
                properties: ["from": change.from, "to": change.to]
            )
        }

        // Not while opted out: the report would be dropped, and remembering it as made would keep the
        // device from describing itself — or registering its secret — for a week after `optIn()`.
        guard !optedOut else { return }

        let context = DeviceInfo.context()
        let hash = DeviceInfo.hashContext(context)
        guard force || DeviceInfo.shouldReportContext(hash) else { return }

        var properties = context
        properties["context_hash"] = hash
        // Registers this device's secret with the report that describes the device, so it costs
        // no round trip of its own.
        properties["fetch_secret"] = DeviceInfo.getFetchSecret()
        await enqueue(eventName: "device_context", properties: properties)
        // After the event is on the queue, never before it: a report that failed to enqueue must
        // not count as made, or the device would not describe itself again for seven days.
        DeviceInfo.rememberReportedContext(hash)
    }

    /**
     Signs a known user in on this device: every event from here on carries `userId`, and their
     profile is updated with `attributes`. The SDK adds what it knows about the device — platform,
     locale, time zone, app version, when the install was first seen — beneath `attributes`, and
     values you pass win. Records `user_identified`. The sign-in is kept across launches; call
     `reset()` when the person signs out.

     `signature` is the hex HMAC-SHA256 of `userId` under the environment's identity secret,
     computed by your backend — never on the handset, because the secret must not ship in an app.
     An environment that requires signed identities refuses the sign-in without it, and withholds
     the person's in-app messages and notifications; the SDK logs a warning once when that happens.
     Calling again for the same person without one keeps the signature already held, so an app that
     re-identifies to update attributes does not lose its sign-in.

     Identifying a different person while somebody is signed in clears what this device held for the
     last one — queued in-app messages, the nudges on screen and the notification centre's history —
     before anything is drawn for the new one. `reset()` is still the call for a sign-out: it also
     records it and starts a new session.

     Does nothing while opted out.
     */
    public static func identify(_ userId: String, attributes: [String: Any] = [:], signature: String? = nil) {
        guard !shared.optedOut else { return }
        shared.userSignature = signature ?? (userId == shared.userId ? shared.userSignature : nil)
        /*
         * Somebody else, with no sign-out between. What this device holds is the last person's — the queued messages,
         * one waiting out its delay, the nudges on screen, the notification history — and so is a read in flight: all
         * of it goes here, before this sign-in's own events can draw any of it. Not the same one identified again,
         * which every launch does, and not a first sign-in from anonymous, whose queue is the same person's — either
         * would drop what was right.
         */
        var replaced = false
        if let previous = shared.userId, previous != userId {
            shared.inApp.supersede()
            shared.notificationStore.supersede()
            shared.delayedDelivery = nil
            shared.lastNotificationServerTime = nil
            #if canImport(UIKit)
            Task { @MainActor in shared.closeNudges() }
            #endif
            replaced = true
        }
        shared.userId = userId
        // Told once the new person is the one signed in, so a list that fetches again on a change asks as them.
        if replaced {
            shared.emitNotificationChange(
                NotificationPage(notifications: [], unreadCount: 0, nextCursor: nil, fromCache: true)
            )
        }
        // So the next cold start knows who this is, and can prove it.
        UserDefaults.standard.set(userId, forKey: TreebarsConstants.keySignedInUser)
        // Also what this call signs with, whatever a later identify does to the field meanwhile.
        let held = shared.userSignature
        if let held {
            UserDefaults.standard.set(held, forKey: TreebarsConstants.keySignedInUserSignature)
        } else {
            UserDefaults.standard.removeObject(forKey: TreebarsConstants.keySignedInUserSignature)
        }

        /*
         * What the SDK knows, underneath what the app said.
         *
         * A profile that arrives carrying nothing but an id renders as an empty card, even
         * though locale and timezone were in the device dimensions the whole time. The
         * app's own values always win: passing `locale` is a claim about the person's
         * preference, which outranks the handset's setting.
         */
        var merged = shared.defaultUserAttributes()
        for (key, value) in attributes { merged[key] = value }

        Task {
            let body: [String: Any] = [
                "user_id": userId,
                "device_id": DeviceInfo.getDeviceId(),
                "attributes": merged,
            ]

            if (try? await shared.backendClient?.postIdentify(payload: body, signature: held)) == true {
                shared.warnSignatureRequired()
            }

            // Re-reported so the device row picks up the identity it was registered
            // without. Forced rather than left to shouldReportContext, whose hash covers
            // the device's own attributes and is unchanged by a login.
            let context = DeviceInfo.context()
            var properties = context
            properties["context_hash"] = DeviceInfo.hashContext(context)
            properties["fetch_secret"] = DeviceInfo.getFetchSecret()
            await shared.enqueue(eventName: "device_context", properties: properties)

            await shared.reportUserIdentified(userId, attributes: merged)
        }
    }

    /**
     A token for something this app is about to have reported by somebody else — a purchase its backend, the App Store,
     Stripe or RevenueCat will file — so the event that comes back through the server events API or a billing provider
     lands on this device, its person and, within thirty minutes, this session. Hand it over as the purchase starts:
     `product.purchase(options: [.appAccountToken(token)])` for StoreKit, and `token.uuidString.lowercased()` for a
     backend (`context.treebars`) or a provider's metadata.

     **The server issues it; the SDK only asks.** The request carries this device's secret, and the signed-in account's
     signature where the environment requires one, so a token shows that this device asked for it. It is a UUID because
     StoreKit's `appAccountToken` is one: 128 bits cannot carry a device, a session and a time, so the server keeps
     them instead.

     **One per purchase, asked for when it starts.** Asking moves the session exactly as the next event would — one that
     had aged out is closed with `session_end` and a new one opened — so the token names the session the purchase
     happens in. It is not an event and is not counted as one. A token asked for at launch and held names a session that
     may be long over by the time anything is bought.

     Nil before `initialize`, while opted out, and whenever the server cannot be reached or refuses: go ahead with the
     purchase without one. The event still arrives, filed by whatever else it carries. Never throws, and waits at most about five
     seconds.
     */
    public static func contextToken() async -> UUID? {
        await shared.contextToken(from: shared.backendClient)
    }

    /// `contextToken()` against the client it is handed: `backendClient` in the SDK, one answered by a `URLProtocol` in
    /// `ContextTokenTests`. No client means `initialize` has not run, and nothing is asked or moved.
    func contextToken(from client: BackendClient?) async -> UUID? {
        guard !optedOut, let client else { return nil }

        let advance = await advanceSession(countsAsEvent: false)
        await announceQueued(advance.queued)
        /*
         * A session this opened is offered to in-app as the event path offers one. Nothing else will: the purchase's
         * own events continue this session, and a message waiting on `session_start` is drawn from the event that
         * opened the session or never.
         */
        if let opened = advance.opened {
            Task {
                await self.considerInApp(
                    eventName: DefaultEvent.sessionStart, properties: opened.properties, dimensions: opened.dimensions
                )
            }
        }

        // One read: the account sent and whether a signature goes with it cannot disagree.
        let signedIn = userId
        switch await client.postContextToken(
            deviceID: DeviceInfo.getDeviceId(),
            sessionID: advance.sessionId,
            userID: signedIn,
            signature: signedIn == nil ? nil : userSignature
        ) {
        case .token(let token):
            return token
        case .signatureRequired:
            warnSignatureRequired()
            return nil
        case .unavailable:
            return nil
        }
    }

    /// The handful of profile attributes the SDK can fill in before the app says anything.
    private func defaultUserAttributes() -> [String: Any] {
        let dimensions = DeviceInfo.dimensions()

        var attributes: [String: Any] = ["platform": "ios"]
        attributes["locale"] = dimensions["locale"]
        attributes["timezone"] = dimensions["timezone"]
        attributes["app_version"] = dimensions["app_version"]
        if let firstSeenAt { attributes["first_seen_at"] = firstSeenAt }

        return attributes.compactMapValues { $0 }
    }

    /// Records the moment somebody stopped being anonymous.
    ///
    /// `/v1/identify` writes the profile and links the identities, but it is not an event —
    /// so without this the single most interesting transition in an app's funnel would be
    /// invisible to analytics, to retention cohorts, to journey triggers and to campaign
    /// goals. The endpoint call stays: this is an addition to it, not a replacement.
    ///
    /// Attribute *keys*, never values. Event properties are stored as append-only history,
    /// with different retention and deletion from the profile; a name or an email belongs
    /// in the profile the identify call just wrote, not duplicated into an event nobody can
    /// revise.
    private func reportUserIdentified(_ userId: String, attributes: [String: Any]) async {
        let previousUserId = UserDefaults.standard.string(forKey: Self.identifiedUserKey)
        UserDefaults.standard.set(userId, forKey: Self.identifiedUserKey)

        var properties: [String: Any] = [
            "user_id": userId,
            // "First on this device", which is the only version of the question the SDK
            // can answer. Whether the account itself is new is the server's to know.
            "is_first_identify": previousUserId == nil,
            "attribute_keys": attributes.keys.sorted(),
        ]
        if let previousUserId, previousUserId != userId {
            properties["previous_user_id"] = previousUserId
        }

        await enqueue(eventName: DefaultEvent.userIdentified, properties: properties)
    }

    /// Records a `screen_view`, and remembers the screen for everything that follows.
    ///
    /// The name is sent as `screen_name`, a field of its own rather than a property, so a
    /// breakdown can group by it. Every later event carries the same value until the next
    /// `screen` call — which is what makes "where did this happen" a question you can ask of
    /// any event, not just of the view itself. The view also carries `previous_screen`, and
    /// `properties` are added last.
    ///
    /// Moving to a different screen takes down the nudges `showNudge()` allowed on the last one.
    public static func screen(_ name: String, properties: [String: Any] = [:]) {
        let previous = shared.currentScreen
        shared.currentScreen = name
        // The nudges belonged to the screen they were allowed on: a new screen asks for its own with `showNudge`.
        #if canImport(UIKit)
        if previous != name, shared.nudgePlace != nil {
            shared.nudgePlace = nil
            Task { @MainActor in shared.closeNudges() }
        }
        #endif

        var enriched: [String: Any] = ["screen_name": name]
        if let previous { enriched["previous_screen"] = previous }
        for (key, value) in properties { enriched[key] = value }

        log(DefaultEvent.screenView, properties: enriched)
    }

    /// Signs in the user named by `profile["id"]`, with the whole dictionary as their attributes; does
    /// nothing without a string `id`. Kept for source compatibility: prefer
    /// `identify(_:attributes:signature:)`, which can carry a signature.
    public static func setUser(_ profile: [String: Any]) {
        guard let id = profile["id"] as? String else { return }
        identify(id, attributes: profile)
    }

    /// Records an event named `eventName` with `properties`, in the current session and under whoever
    /// is signed in, with the device's context and the current screen attached.
    ///
    /// The event is written to the on-disk queue and uploaded with the next batch; `flush()` sends it
    /// now. An event logged before `initialize` is dropped, and nothing is recorded while opted out.
    public static func log(_ eventName: String, properties: [String: Any] = [:]) {
        guard !shared.optedOut else { return }
        // Remembered until it lands, so a flush() on the next line waits for it (`InFlight`).
        shared.recording.run { await shared.enqueue(eventName: eventName, properties: properties) }
    }

    /// Registers a push token so campaigns and journeys can reach this device.
    ///
    /// Pass the token from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`
    /// with `.apns`, or a Firebase Cloud Messaging token with `.fcm`. It is recorded as
    /// `push_token_registered` and uploaded at once.
    ///
    /// An ordinary event rather than a bespoke endpoint, so the same server path handles
    /// registration for every platform.
    ///
    /// On Apple the environment the build was signed for rides along, because nothing
    /// downstream can work it out: a device token carries no environment marker, and a
    /// sandbox token sent to the production host fails as `BadDeviceToken` — the same
    /// answer an uninstalled app gives. It is attached only for `.apns`; FCM has no such
    /// concept, and stamping an Apple entitlement onto a Google token would make the value
    /// mean nothing.
    public static func registerPushToken(_ token: Data, provider: PushProvider = .apns) {
        let hex = token.map { String(format: "%02.2hhx", $0) }.joined()
        var properties: [String: Any] = ["token": hex, "provider": provider.rawValue]
        // Omitted rather than sent null: an absent key means "let the channel decide".
        if provider == .apns, let environment = DeviceInfo.apsEnvironment {
            properties["apns_environment"] = environment
        }
        log("push_token_registered", properties: properties)
        flush()
    }

    /// Reports that somebody tapped a notification sent by a campaign.
    ///
    /// Pass the notification's `userInfo` straight through — from
    /// `didReceive response:` in your `UNUserNotificationCenterDelegate` — and this
    /// picks out the identifiers the server put there. APNs carries them at the payload
    /// root, beside `aps`.
    ///
    /// Nothing happens when they are absent, so it is safe to call for every
    /// notification the app handles, including ones Treebars did not send.
    ///
    /// Call it only for a real tap. `willPresent` fires for a notification arriving
    /// while the app is open, which nobody has opened, and counting those would put
    /// opens above sends.
    public static func trackNotificationOpened(userInfo: [AnyHashable: Any]) {
        guard let deliveryId = userInfo[deliveryIdKey] as? String, !deliveryId.isEmpty else { return }

        var properties: [String: Any] = [deliveryIdKey: deliveryId]
        if let campaignId = userInfo[campaignIdKey] as? String, !campaignId.isEmpty {
            properties[campaignIdKey] = campaignId
        }

        // Which of a push's buttons was pressed, when it was one.
        if let button = userInfo[TreebarsConstants.richPushButtonIdKey] as? String, !button.isEmpty {
            properties[TreebarsConstants.richPushButtonIdKey] = button
        }

        log("notification_opened", properties: properties)
        // Flushed rather than batched: this runs as the app is being brought up, which
        // is exactly when it is most likely to be suspended again.
        flush()
    }

    /// A push button's "set a trait", on the person as any message's trait is (`setMessageTraits`): through `identify`
    /// for whoever is signed in, on the anonymous person otherwise. A button pressed before `initialize` has run sets
    /// nothing; the tap itself is still recorded.
    static func setAttributeFromPush(key: String, value: String) {
        guard shared.writeKey != nil, !key.isEmpty else { return }
        setMessageTraits([key: value])
    }

    /*
     Traits a message set — a form's answer kept as a trait, a button's "set a trait", an HTML message's
     `setUserAttribute` family and `data-tb-save`, a push button's — on the person, signed in or not.

     Signed in, through `identify`. With nobody signed in there is still a person — the anonymous identity this device
     resolves to — and the traits go on it and travel with it at `identify()`, when that identity becomes the account or
     is merged into it. That keeps an onboarding survey's answers for exactly the people an onboarding survey is shown
     to. `/v1/identify` needs an account id, so they ride the event queue as `traits_set`: its retries, its copy on disk
     across a kill, and the device proof every event carries. Which checks apply (declared, reserved) is the caller's;
     this decides only where an allowed trait goes.
     */
    static func setMessageTraits(_ traits: [String: Any]) {
        guard !traits.isEmpty else { return }
        if let user = shared.userId {
            identify(user, attributes: traits)
            return
        }
        log(traitsSetEvent, properties: traitsSetProperties(traits))
    }

    /// What `traits_set` carries: the values, which are kept out of analytics, and their names, which are not. Apart
    /// from the singleton so a Mac can ask it (`MessageTraitsTests`).
    static func traitsSetProperties(_ traits: [String: Any]) -> [String: Any] {
        ["trait_keys": traits.keys.sorted(), "traits": traits]
    }

    /// After a permission prompt is answered: read the permission again now, so the change is reported as
    /// `notification_permission_changed` rather than at the next launch.
    static func reportPermissionNow() {
        Task { await shared.reportDeviceContext() }
    }

    /// Reports that somebody swiped away a notification sent by a campaign without opening it, as `push_dismissed`.
    ///
    /// iOS draws the alert, so the app sees a dismissal only through a `UNUserNotificationCenterDelegate` whose
    /// category was registered with `.customDismissAction` — the SDK registers that category itself for a push its
    /// Notification Service Extension enriched, and `handleNotificationResponse` reports the dismissal for it.
    /// For any other, the delegate's `didReceive response:` with
    /// `actionIdentifier == UNNotificationDismissActionIdentifier` passes that response's `userInfo` here. Nothing
    /// happens for a notification Treebars did not send.
    public static func trackNotificationDismissed(userInfo: [AnyHashable: Any]) {
        guard let deliveryId = userInfo[deliveryIdKey] as? String, !deliveryId.isEmpty else { return }
        var properties: [String: Any] = [deliveryIdKey: deliveryId]
        if let campaignId = userInfo[campaignIdKey] as? String, !campaignId.isEmpty {
            properties[campaignIdKey] = campaignId
        }
        log("push_dismissed", properties: properties)
    }

    /**
     Watch what the uploader is doing, as an `UploadLog` per step, for an app that shows its own
     diagnostics. Nil stops it.

     `debug` logging writes to the console, which only somebody reading Xcode sees; this is
     what an app can render itself. The React Native SDK forwards it as `onUpload`.

     Called from the uploader's actor, not the main thread. A listener that touches UI is the
     caller's job to hop.
     */
    public static func setUploadListener(_ listener: (@Sendable (UploadLog) -> Void)?) {
        Task { await shared.uploader?.setListener(listener) }
    }

    /**
     How many events are waiting to be uploaded, for an app that shows it — a debug screen's
     pending count, say. Zero before `initialize`.
     */
    public static func pendingCount() async -> Int {
        await shared.uploader?.pending() ?? 0
    }

    /**
     Seconds until the auto-flush next runs, or nil when nothing is scheduled.

     Nil rather than zero when the timer is not running, which is the distinction a caller
     needs: "no flush is scheduled" and "a flush is due right now" are different sentences and
     a screen showing 0 for both would be lying about one of them. Clamped at zero on the low
     side, because a negative countdown reads as a bug.
     */
    public static func secondsUntilNextFlush() -> TimeInterval? {
        shared.nextFlushAt.map { max(0, $0.timeIntervalSinceNow) }
    }

    /**
     Uploads the events waiting on this device now, rather than on the next timer — including every
     event logged before this call, even one still being written to the queue.

     Returns at once; the upload runs in the background, never throws, and backs off and retries on
     its own when the network fails. Does nothing while opted out.
     */
    public static func flush() {
        guard !shared.optedOut else { return }
        // The logs still in flight, captured here, synchronously, and awaited before the drain — so the
        // drain cannot overtake an event logged on the line before.
        let logged = shared.recording.snapshot()
        Task {
            for task in logged { await task.value }
            await shared.uploader?.flush()
        }
    }

    /// Signs the current user out of this device, keeping the events already captured.
    ///
    /// Records `user_signed_out` and starts uploading it, then clears the signed-in id and its
    /// signature, starts a new session, and clears what belonged to that person here: queued in-app
    /// messages, the nudges on screen and the notification centre's history. Events queued before
    /// the call are still uploaded under the person who logged them. The device id stays. Does
    /// nothing when nobody is signed in, so calling it defensively on launch is safe.
    public static func reset() {
        /*
         * Captured before the clear, emitted after it, in one Task.
         *
         * The identity clears synchronously because a logout that is only eventually true
         * is a bug the caller cannot see — `inApp` must stop rendering for this person on
         * this line, not a hop later. But `build()` reads `userId` inside the Task, so by
         * then it is nil; `userIdOverride` is what keeps the event attributed to the person
         * who signed out. That matters beyond the timeline: an erasure request finds a
         * person's events by the account id they carry, so an unattributed sign-out would
         * outlive the erasure of the person who signed out.
         */
        /*
         * `identifiedUserKey` is history and deliberately stays — it is what
         * `previous_user_id` is computed from. This one is current state, and a sign-out
         * that failed to clear it would let the next launch present the previous person's
         * `user_id` on the read routes and fetch their queued messages. Cleared whoever is
         * held, so a reset() that runs before anything was restored still clears it.
         */
        UserDefaults.standard.removeObject(forKey: TreebarsConstants.keySignedInUser)
        UserDefaults.standard.removeObject(forKey: TreebarsConstants.keySignedInUserSignature)
        /*
         * Nobody signed in, so there is no sign-in to end and nothing below applies. An app that calls reset()
         * defensively on launch must not split the person's session or wipe their in-app queue and the ledger of what
         * they have already seen and answered — the next sync would offer those messages again. The anonymous person
         * before the call is the same one after it.
         */
        guard let signedOutUserId = shared.userId else { return }
        shared.userId = nil
        shared.userSignature = nil
        shared.currentScreen = nil
        // The previous person's nudges, and where they were allowed.
        shared.nudgePlace = nil
        #if canImport(UIKit)
        Task { @MainActor in shared.closeNudges() }
        #endif

        Task {
            await shared.enqueue(
                eventName: DefaultEvent.userSignedOut,
                properties: ["user_id": signedOutUserId],
                userIdOverride: signedOutUserId
            )
            await shared.uploader?.flush()
            // In the SAME Task, after the enqueue. Split across two, the session would be
            // torn down first and the sign-out would land in a freshly minted session
            // preceded by a spurious session_start.
            await shared.sessionManager.reset()
        }
        /*
         * The queued messages go — they were addressed to whoever was signed in. The device id
         * and its secret stay: they belong to the handset rather than the person, and the two
         * are only ever replaced together (`wipeLocalData`).
         */
        shared.inApp.reset()
        shared.delayedDelivery = nil
        // A trigger held for a renderer is the previous person's moment, replayed against the next one's queue.
        shared.withUndrawnTriggers { $0.removeAll() }
        /*
         * And the notification centre, for the same reason: a history belongs to the
         * person, not the handset. The device secret and the device id still survive —
         * see above.
         */
        shared.notificationStore.reset()
        shared.lastNotificationServerTime = nil
        shared.emitNotificationChange(
            NotificationPage(notifications: [], unreadCount: 0, nextCursor: nil, fromCache: true)
        )
    }

    /**
     Stops this SDK recording or sending anything from this device — events, sign-ins, content reads,
     link questions, push-token registrations — until `optIn()`, and on every later launch: the answer
     is kept. What was waiting to be sent is dropped with it. Call it before `initialize` when a consent
     prompt answers first.

     Nothing already sent is touched: erasing a person's data on the server is the API's
     `/privacy/delete`, which the app's backend calls. And opting out is not signing out — `reset()` is.
     */
    public static func optOut() {
        shared.optedOut = true
        UserDefaults.standard.set(true, forKey: optedOutKey)
        Task { await shared.discardUnsent() }
    }

    /// Undoes `optOut()`: recording resumes with the next event, and nothing dropped comes back.
    public static func optIn() {
        shared.optedOut = false
        UserDefaults.standard.removeObject(forKey: optedOutKey)
    }

    /// Whether `optOut()` is in effect on this device.
    public static var isOptedOut: Bool { shared.optedOut }

    /**
     Forgets this device, here: the device id and its secret, who is signed in and who had been, the
     queue and every batch waiting to be sent, the session, the in-app ledger and the notification
     history. Nothing is sent on the way — not even the sign-out `reset()` records — and from the next
     event on this is a device the server has never seen, with a new id and a new secret. The opt-out
     stays: it is the person's answer, not data about them, so a person who wants to be forgotten and
     not recorded again calls `optOut()` as well.

     Nothing on the server is touched: what was already sent is erased by the API's `/privacy/delete`,
     which the app's backend calls.
     */
    public static func wipeLocalData() {
        let instance = shared
        instance.userId = nil
        instance.userSignature = nil
        instance.currentScreen = nil
        UserDefaults.standard.removeObject(forKey: TreebarsConstants.keySignedInUser)
        UserDefaults.standard.removeObject(forKey: TreebarsConstants.keySignedInUserSignature)
        UserDefaults.standard.removeObject(forKey: identifiedUserKey)
        DeviceInfo.forgetIdentity()
        instance.inApp.reset()
        instance.notificationStore.reset()
        // The files its messages loaded: a forgotten device keeps nothing it was sent.
        instance.assetCache.clear()
        instance.lastNotificationServerTime = nil
        instance.emitNotificationChange(
            NotificationPage(notifications: [], unreadCount: 0, nextCursor: nil, fromCache: true)
        )
        Task {
            await instance.discardUnsent()
            await instance.sessionManager.reset()
        }
    }

    /// The queue and every sealed batch: what an opt-out or a wipe says must not be sent.
    private func discardUnsent() async {
        await queue.clear()
        await uploader?.discardPending()
    }

    /**
     How the host app draws a standard overlay, when it wants to draw its own.

     A closure rather than a view this SDK presents: the SDK decides *which* message and *when*, and the app decides
     what it looks like. With no renderer registered the SDK draws a standard message itself — in a window of its own,
     so it owns none of the app's — and this is the override. Call `onClick` with the button pressed and `onDismiss`
     when the message is closed; the SDK records both.
     */
    public typealias InAppRenderer = (
        _ message: InAppMessage,
        _ tokens: InAppTokens?,
        _ onClick: @escaping (InAppButton) -> Void,
        _ onDismiss: @escaping () -> Void
    ) -> Void

    /**
     Registers the app's renderer for standard in-app messages, or removes it with nil.

     Present, every standard message is handed to it and the SDK draws none of them itself. Absent — the default — the
     SDK draws a standard message itself from its render plan. An HTML message is drawn by the SDK either way, and a
     self-handled message still goes to the in-app delegate. `disableInApps()` is what stops messages; clearing this
     does not.

     `reattaching` is a host that detached and is attaching again with its presentation still in hand — the React
     Native bridge, whose JavaScript host unmounts and mounts while the module lives on, and which hands its
     outstanding overlay straight back. Anything else is a host that has just mounted, and whatever it was showing
     went with the view that drew it.
     */
    public static func setInAppRenderer(_ renderer: InAppRenderer?, reattaching: Bool = false) {
        shared.inAppRenderer = renderer
        TreebarsLogger.log(renderer == nil ? "in-app: renderer detached" : "in-app: renderer attached\(reattaching ? " again" : "")")
        /*
         * Released only for a new host. On a re-attach the overlay handed back is still up, and releasing the screen
         * would let the next event present a second message over it.
         */
        if renderer != nil, !reattaching { shared.presentation.releaseUnpinned() }
        // Attaching one is the moment a trigger that had nowhere to go can finally be answered.
        if renderer != nil { Task { await shared.replayUndrawnTriggers() } }
    }

    /// The in-app messages authored as inbox rows, for an app that draws a message centre. Data only: the app draws
    /// the list, and reports what happens to a row with `inboxMessageViewed`, `inboxMessageClicked` and
    /// `dismissInboxMessage`.
    public static func inbox() -> [InAppMessage] { shared.inApp.inbox() }

    /// An inbox row came into view: records `in_app_displayed`, the card's "viewed". Call it once per showing of the
    /// list.
    public static func inboxMessageViewed(_ deliveryID: String) {
        let props = inboxReceipt(deliveryID)
        Task { await shared.enqueue(eventName: "in_app_displayed", properties: props) }
    }

    /// An inbox receipt names the campaign as an overlay's does, when the message is still held.
    private static func inboxReceipt(_ deliveryID: String) -> [String: Any] {
        shared.inApp.list().first(where: { $0.delivery_id == deliveryID }).map(inAppReceipt) ?? [deliveryIdKey: deliveryID]
    }

    /// An inbox row was tapped: records `in_app_clicked`, with `destination` — where it went — when given, and uploads
    /// it at once. The app does the going.
    public static func inboxMessageClicked(_ deliveryID: String, destination: String? = nil) {
        var props = inboxReceipt(deliveryID)
        if let destination { props["destination"] = destination }
        Task {
            await shared.enqueue(eventName: "in_app_clicked", properties: props)
            await shared.uploader?.flush()
        }
    }

    /*
     The app's in-app API, named as common engagement SDKs name it on iOS, so a migration keeps its call sites.
     */

    /// Where somebody is in the app, in its own words: a message naming contexts shows only while one of them is set.
    /// Replaces the set; `invalidateInAppContexts()` clears it.
    public static func setCurrentInAppContexts(_ contexts: [String]) {
        shared.appContexts = Set(contexts.filter { !$0.isEmpty })
    }

    /// Clears the contexts, so a message naming any is not shown until they are set again.
    public static func invalidateInAppContexts() {
        shared.appContexts = []
    }

    /// The app's in-app delegate: shown, dismissed, every press (a `custom` button's keys arrive only here), and a
    /// self-handled message to draw. Held weakly, as a delegate is.
    public static func setInAppDelegate(_ delegate: TreebarsInAppDelegate?) {
        shared.inAppDelegate = delegate
    }

    /// Stops in-app messages on this device from now on; the queue is still kept, so the inbox reads it.
    ///
    /// The message on screen goes too, and so do the nudges. This SDK draws an HTML message itself, and a standard one
    /// when no renderer is registered, so removing the renderer does not stop messages; this does. The React Native SDK
    /// calls it for `in_app_enabled: false`.
    public static func disableInApps() {
        shared.inAppEnabled = false
        #if canImport(UIKit)
        Task { @MainActor in
            InAppHtmlHost.cool()
            shared.closeNudges()
            if let host = shared.htmlHost {
                host.destroy()
                shared.htmlHost = nil
                shared.presentation.release()
            }
            // Taken down unspent and unreported, as the HTML host's is: nobody closed it.
            if let host = shared.nativeHost {
                host.destroy()
                shared.nativeHost = nil
                shared.presentation.release()
            }
        }
        #endif
    }

    #if canImport(UIKit)
    /// The WebView an HTML in-app message is drawn in, handed to the app before the page loads — a debugging flag
    /// (`isInspectable`), its scroll behaviour, a user agent. The SDK's own
    /// configuration (a non-persistent store, no second window) is applied first, and the bridge and who may navigate
    /// stay the SDK's: its delegates are put back after the hook runs.
    public static func setInAppWebViewCustomizer(_ customizer: ((WKWebView) -> Void)?) {
        Task { @MainActor in shared.webViewCustomizer = customizer }
    }
    #endif

    /// Never draws an in-app message over this screen: while a view controller of its type is in front, a trigger is
    /// held, and answered on the next screen.
    public static func blockInApp(forViewController viewController: AnyObject) {
        shared.blockedScreens.insert(String(describing: type(of: viewController)))
    }

    /// Evaluate the messages for this screen now: an `immediate` message, or one triggered by the screen in front, is
    /// shown if the caps allow — as if the screen had just been reported.
    public static func showInApp() {
        let screen = shared.currentScreen
        Task { _ = await shared.drawInApp(eventName: "screen_view", properties: screen.map { ["screen_name": $0] } ?? [:], dimensions: nil) }
    }

    /// Nudges may appear on this screen, at any edge, until the screen changes. Call
    /// `showNudge()` in the view controllers that should have them; nudges never appear anywhere it was not.
    public static func showNudge() {
        showNudge(atPosition: .any)
    }

    /// Nudges may appear on this screen at this edge, until the screen changes. The
    /// nudges this screen brings are asked for at once, as `showInApp` asks for modals.
    public static func showNudge(atPosition position: TreebarsNudgePosition) {
        guard shared.inAppEnabled else { return }
        let screen = shared.currentScreen
        shared.nudgePlace = (screen, position)
        Task { await shared.drawNudges(eventName: "screen_view", properties: screen.map { ["screen_name": $0] } ?? [:], dimensions: nil) }
    }

    /// The self-handled message this device may show now, on the main actor — or nil. Eligible: marked self-handled,
    /// allowed by the caps and the contexts, triggered by nothing narrower than now or this screen.
    public static func getSelfHandledInApp(completion: @escaping @MainActor (InAppMessage?) -> Void) {
        Task {
            let first = await shared.eligibleSelfHandled().first
            await MainActor.run { completion(first) }
        }
    }

    /// Every self-handled message this device may show now.
    public static func getSelfHandledInApps(completion: @escaping @MainActor ([InAppMessage]) -> Void) {
        Task {
            let all = await shared.eligibleSelfHandled()
            await MainActor.run { completion(all) }
        }
    }

    private func eligibleSelfHandled() async -> [InAppMessage] {
        guard inAppEnabled else { return [] }
        let session = await sessionManager.currentID()
        return inApp.list().filter { message in
            guard let content = message.content.in_app, content.display?.self_handled == true, content.surface != "inbox" else { return false }
            guard inAppBlockedBy(message, content: content, session: session) == nil else { return false }
            switch content.trigger.kind {
            case "immediate", "session_start": return true
            case "screen_view": return content.trigger.screen_name == currentScreen
            default: return false
            }
        }
    }

    /// The app drew a self-handled message: spent and reported as any display is.
    public static func selfHandledShown(campaignInfo message: InAppMessage) {
        Task {
            let session = await shared.sessionManager.currentID()
            shared.inApp.recordDisplay(message, session: session)
            if message.content.in_app?.trigger.kind == "immediate" { shared.inApp.markDone(message.delivery_id) }
            await shared.enqueue(eventName: "in_app_displayed", properties: inAppReceipt(message))
            await MainActor.run { shared.inAppDelegate?.inAppShown(message) }
        }
    }

    /// A self-handled message was pressed; `button` names what, when there is one — its index and label ride on the
    /// click as any message's do. A call to action ends the message.
    public static func selfHandledClicked(campaignInfo message: InAppMessage, button: InAppButton? = nil) {
        Task {
            await shared.enqueue(eventName: "in_app_clicked", properties: button.map { inAppClickProperties(message, button: $0) } ?? inAppReceipt(message))
            if let button, inAppClickEndsMessage(button) { shared.inApp.markDone(message.delivery_id) }
            await shared.uploader?.flush()
        }
    }

    /// A self-handled message went away.
    public static func selfHandledDismissed(campaignInfo message: InAppMessage) {
        shared.inApp.markDone(message.delivery_id)
        Task {
            await shared.enqueue(eventName: "in_app_dismissed", properties: inAppReceipt(message))
            await MainActor.run { shared.inAppDelegate?.inAppDismissed(message) }
        }
    }

    /// A form's answers, from the renderer that drew it: `in_app_form_submitted` with the answers, and — for a field the
    /// form keeps as an address — `email` or `phone` beside them, which the server attaches to the person. A field the
    /// form keeps as a trait is set on the person too. The message is done on this device once answered.
    public static func submitInAppForm(_ message: InAppMessage, responses: [String: Any]) {
        var props = inAppReceipt(message)
        props["responses"] = responses
        // Answered: the message is done on this device and the screen is free, as after a call to action.
        shared.inApp.markDone(message.delivery_id)
        shared.presentation.releaseUnpinned()
        let (addresses, traits) = formKeeps(message.content.in_app, responses: responses)
        for (kind, value) in addresses { props[kind] = value }
        if !traits.isEmpty { setMessageTraits(traits) }
        Task {
            await shared.enqueue(eventName: "in_app_form_submitted", properties: props)
            await shared.uploader?.flush()
        }
    }

    /// The same, by delivery id, for a bridge that holds the id rather than the message. Unknown ids are ignored.
    public static func submitInAppForm(deliveryID: String, responses: [String: Any]) {
        guard let message = shared.inApp.list().first(where: { $0.delivery_id == deliveryID }) else { return }
        submitInAppForm(message, responses: responses)
    }

    /// An inbox row was dismissed: records `in_app_dismissed`, uploads it at once, and the message is done on this
    /// device. An inbox dismissal is the person's, not the handset's, so the server removes it for every device they
    /// own; an overlay dismissal deliberately does not.
    public static func dismissInboxMessage(_ deliveryID: String) {
        let receipt = inboxReceipt(deliveryID)
        shared.inApp.markDone(deliveryID)
        Task {
            await shared.enqueue(eventName: "in_app_dismissed", properties: receipt)
            await shared.uploader?.flush()
        }
    }

    /*
     * The in-app sync: it fetches the queue the store, the ledger, the trigger matcher and the
     * frequency rules work from.
     */

    /// Fetches this device's in-app messages now, rather than at the next session start, foreground or poll. Never
    /// throws: a sync that fails leaves the messages already held as they were.
    public static func syncInAppMessages() {
        Task { await shared.syncInApp() }
    }

    private func syncInApp() async {
        guard !optedOut, let client = backendClient else { return }
        /*
         * With in-app off there is no queue to read — and the whole sync marks every pending message
         * fetched, a stage of the campaign's funnel, for a device that will never draw one — so the
         * sync still owed to the trigger list is the list alone. Turning in-app off never turns
         * triggers off.
         */
        guard inAppEnabled else {
            await triggers?.refresh()
            return
        }

        // The answer carries the trigger list on every outcome, the refusals included, so the list
        // is told a sync is out: an upload answered with a new version meanwhile waits for this.
        triggers?.beginSync()
        var list: TriggerList?
        defer { triggers?.endSync(list) }

        // Before the request: a sign-out that lands while it is out makes its answer the previous person's.
        let asked = inApp.generation
        let secret = DeviceInfo.getFetchSecret()
        let fetched = try? await client.getInApp(
            deviceID: DeviceInfo.getDeviceId(),
            secret: secret,
            userID: userId,
            signature: userSignature
        )
        guard let fetched else { return }
        list = TriggerList(json: (try? JSONSerialization.jsonObject(with: fetched) as? [String: Any])?["trigger_events"])
        let data = await withLargeBodies(fetched, client: client, secret: secret)
        guard let response = try? JSONDecoder().decode(InAppSyncResponse.self, from: data) else { return }
        if response.signature_required == true { warnSignatureRequired() }

        /*
         * The server has not registered this device's secret yet: report it now, forced past the
         * hash gate, rather than wait out the seven-day context TTL with no messages to show.
         */
        if response.claim_required == true {
            await reportDeviceContext(force: true)
            await uploader?.flush()
            return
        }

        if !inApp.accept(response, askedAt: asked) {
            TreebarsLogger.log("in-app: dropped a sync asked for a previous sign-in")
        } else {
            prefetchAssets()
            if let place = nudgePlace, place.screen == currentScreen {
                // Nudges queued since the screen allowed them: asked for now, not at some later event.
                await drawNudges(eventName: "screen_view", properties: currentScreen.map { ["screen_name": $0] } ?? [:], dimensions: nil)
            }
        }
        await warmForQueuedHtml()
    }

    /**
     The notification centre: one page of the history of what Treebars sent this person, push
     included.

     Raw rows and a cursor; the app draws the list. Not the same thing as `inbox()` — that is the
     queue of in-app messages authored as rows, still actionable and still styled, while this is the
     history, keeping what expiry and dismissal take out of that queue.

     `limit` is the page size, `cursor` the previous page's `nextCursor`, and `channels` narrows the
     rows to those channels. When the network cannot be reached the first page comes from the copy
     kept on the device (`fromCache`); a later page cannot, and comes back empty with its cursor so
     the call can be retried. Empty before `initialize` and while opted out.
     */
    public static func notifications(
        limit: Int? = nil,
        cursor: String? = nil,
        channels: [String]? = nil
    ) async -> NotificationPage {
        await shared.notificationPage(limit: limit, cursor: cursor, channels: channels)
    }

    /// The badge. One number, at the cost of the same round trip as a page.
    public static func unreadNotificationCount() async -> Int {
        await notifications(limit: 1).unreadCount
    }

    /// Marks one send read, on every device this person owns.
    public static func markNotificationRead(_ groupID: String) {
        shared.notificationStore.noteRead(groupID)
        shared.emitNotificationChange()
        Task { await shared.writeNotificationState(read: [groupID]) }
    }

    /// A notification or card tapped in the centre: opened, and read with it — the campaign report's Opened for
    /// the send, which a centre row cannot reach through a delivery id because it is never given one.
    public static func markNotificationOpened(_ groupID: String) {
        shared.notificationStore.noteRead(groupID)
        shared.emitNotificationChange()
        Task { await shared.writeNotificationState(opened: [groupID]) }
    }

    /**
     Marks everything read.

     Sends the server's own `server_time` as a watermark rather than a list of ids: a list
     cannot express somebody returning to nine hundred unread — a capped one leaves the tail
     unread and the badge stuck — and the server clamps the instant to its own `NOW()`, so a
     handset with a fast clock cannot pre-read what has not been sent yet.
     */
    public static func markAllNotificationsRead() {
        Task {
            _ = await shared.notificationPage(limit: 1, cursor: nil, channels: nil)
            guard let through = shared.lastNotificationServerTime else { return }
            shared.notificationStore.noteReadThrough(through)
            shared.emitNotificationChange()
            await shared.writeNotificationState(readThrough: through)
        }
    }

    /**
     Removes one send from the centre, for this person rather than this handset.

     The same dismissal an inbox dismissal records — so a message deleted here is also gone
     from the in-app queue, which is what pressing a bin is taken to mean.
     */
    public static func dismissNotification(_ groupID: String) {
        shared.notificationStore.noteDismissed(groupID)
        shared.emitNotificationChange()
        Task { await shared.writeNotificationState(dismissed: [groupID]) }
    }

    /**
     Called whenever the centre changes — a fetch, a mark, a sign-out.

     Returns its own unsubscribe. It exists because the alternative is a timer, and a badge
     driven by one is a badge that is wrong for up to its interval.
     */
    public static func onNotificationsChange(
        _ callback: @escaping (NotificationPage) -> Void
    ) -> () -> Void {
        let token = UUID()
        shared.notificationWatchers[token] = callback
        return { shared.notificationWatchers.removeValue(forKey: token) }
    }

    /// One page, falling back to the cache when the network cannot be reached.
    private func notificationPage(
        limit: Int?,
        cursor: String?,
        channels: [String]?
    ) async -> NotificationPage {
        let empty = NotificationPage(
            notifications: [], unreadCount: 0, nextCursor: cursor, fromCache: true
        )
        guard !optedOut, let client = backendClient else { return empty }

        // Before the request, so an answer for somebody who has since signed out is not shown as the next person's.
        let asked = notificationStore.generation
        let secret = DeviceInfo.getFetchSecret()
        let data = try? await client.getNotifications(
            deviceID: DeviceInfo.getDeviceId(),
            secret: secret,
            userID: userId,
            signature: userSignature,
            limit: limit,
            cursor: cursor,
            channels: channels
        )

        guard let data,
              let body = try? JSONDecoder().decode(NotificationWireResponse.self, from: data)
        else {
            // A cursored call has no cache to fall back to — deep pages are network-only,
            // because what a bell needs in a tunnel is its first screen — so it hands the
            // cursor back and the caller retries.
            if cursor != nil { return empty }
            return notificationStore.cached() ?? empty
        }

        if asked != notificationStore.generation { return notificationStore.cached() ?? empty }
        if body.signature_required == true { warnSignatureRequired() }

        if body.claim_required == true {
            await reportDeviceContext(force: true)
            await uploader?.flush()
            return cursor != nil ? empty : (notificationStore.cached() ?? empty)
        }

        lastNotificationServerTime = body.server_time

        let notifications = notificationStore.overlay(body.notifications)
        let page = NotificationPage(
            notifications: notifications,
            // Counted against the server's own rows, never the overlaid ones.
            unreadCount: notificationStore.overlayCount(body.unread_count, body.notifications),
            nextCursor: body.next_cursor,
            fromCache: false
        )

        /*
         * Only the DEFAULT first page is cached, and every clause of that matters.
         *
         * A cursored page is a scroll position rather than a screen somebody returns to. And
         * a page with an explicit `limit` is a probe — `unreadCount()` and `markAllRead()`
         * both ask for one row, the latter only to learn the server's clock. Caching a
         * one-row answer over the real first page leaves the unread arithmetic running
         * against a single row, and the badge then disagrees with the list beside it.
         */
        if cursor == nil && limit == nil {
            guard notificationStore.accept(owner: userId ?? DeviceInfo.getDeviceId(), page: page, askedAt: asked) else {
                return notificationStore.cached() ?? empty
            }
            emitNotificationChange(page)
        }
        return page
    }

    /**
     Sends the marks, then reports them for analytics.

     In that order, and both halves matter. The request is what makes a mark hold on every
     device the person owns, and it is acknowledged. The events make "how many of our
     notifications get read" answerable, and they ride the ordinary queue where a drop costs
     a data point rather than somebody's unread badge.
     */
    private func writeNotificationState(
        read: [String] = [],
        dismissed: [String] = [],
        readThrough: String? = nil,
        opened: [String] = []
    ) async {
        guard !optedOut, let client = backendClient else { return }

        var payload: [String: Any] = ["device_id": DeviceInfo.getDeviceId()]
        if let userId { payload["user_id"] = userId }
        if !read.isEmpty { payload["read"] = read }
        if !dismissed.isEmpty { payload["dismissed"] = dismissed }
        if let readThrough { payload["read_through"] = readThrough }
        if !opened.isEmpty { payload["opened"] = opened }

        let data = try? await client.postNotificationState(
            secret: DeviceInfo.getFetchSecret(),
            signature: userSignature,
            payload: payload
        )
        guard let data,
              let body = try? JSONDecoder().decode(NotificationStateResponse.self, from: data)
        else {
            // Kept in the ledger, so the row still reads as marked on this device and the
            // next successful page reconciles.
            return
        }
        // Refused, not written: a mark that did not land is not reported as one.
        if body.signature_required == true {
            warnSignatureRequired()
            return
        }
        lastNotificationServerTime = body.server_time

        for groupID in read + opened {
            await enqueue(
                eventName: DefaultEvent.notificationRead,
                properties: ["notification_group_id": groupID]
            )
        }
        for groupID in dismissed {
            await enqueue(
                eventName: DefaultEvent.notificationDismissed,
                properties: ["notification_group_id": groupID]
            )
        }
        if let readThrough {
            await enqueue(
                eventName: DefaultEvent.notificationRead,
                properties: ["read_through": readThrough]
            )
        }
    }

    /**
     Said out loud, and not only under debug: a missing signature is a setup step the integration
     skipped, and what it costs — every sign-in unrecorded and every signed-in person's messages
     withheld, silently — is exactly the kind of absence nobody goes looking for.
     */
    private func warnSignatureRequired() {
        guard !warnedSignature else { return }
        warnedSignature = true
        TreebarsLogger.warn(
            "This environment requires a signed identity, so sign-ins are not recorded and in-app messages "
                + "and notifications are withheld: pass the signature your backend computes to "
                + "identify(_:attributes:signature:)."
        )
    }

    private func emitNotificationChange(_ page: NotificationPage? = nil) {
        guard !notificationWatchers.isEmpty else { return }
        guard let next = page ?? notificationStore.cached() else { return }
        for watcher in notificationWatchers.values { watcher(next) }
    }

    /**
     Show a queued in-app message, if this event is what it was waiting for.

     The server settled eligibility before any of these were queued; what is decided here
     is only *when*, which only the device can know for a screen view or a custom event.
     */
    private func considerInApp(eventName: String, properties: [String: Any], dimensions: [String: Any]?) async {
        /*
         * Syncing happens whether or not anything can draw an overlay, and the order here
         * is load-bearing. An app that only draws an inbox — or only a notification centre
         * — has no renderer by design, and putting this below the renderer check would mean
         * it never fetched anything at all.
         *
         * And above the in-app switch, for a reason that is not in-app's: the sync carries the
         * trigger list, and a device that draws no messages still needs to know which of its events
         * to send at once. Nor does it depend on the poll — an `inAppPollInterval` of zero, which the
         * React Native bridge sets for `in_app_enabled: false`, stops only the timer.
         */
        if eventName == DefaultEvent.sessionStart || eventName == DefaultEvent.appForeground {
            await syncInApp()
            // Replayed after the fetch too, not only when a renderer arrives: the store can be
            // empty at `session_start` and hold the message a round trip later, which is the
            // same miss reached from the other side.
            await replayUndrawnTriggers()
        }

        guard inAppEnabled else { return }
        await drawInApp(eventName: eventName, properties: properties, dimensions: dimensions)
    }

    /**
     Triggers that matched nothing because nothing could draw yet.

     `session_start` is reported while the app is starting, and a renderer — a React Native
     host's especially — may attach a few hundred milliseconds later. Without this the one
     trigger that fires exactly once per launch would fire while nothing could draw, and a
     `session_start` message could never be drawn: not then, because nothing could draw, and
     not afterwards, because nothing fires `session_start` twice.

     In order, deduplicated by name, and bounded. Keeping only the latest does not work — a
     launch fires `session_start`, `app_open`, `screen_view`, `device_context`,
     `user_identified` and `push_token_registered` within a few hundred milliseconds, so the
     single held trigger by the time anything could draw would be the last of those and never
     the one a message was waiting on.

     Each keeps the dimensions its event was stamped with, so a replay after the screen or the
     network has changed answers a dimension row from the values the stored event holds, not
     from the device as it is now.
     */
    private var _undrawnTriggers: [(String, [String: Any], [String: Any]?)] = []

    /*
     Every touch under one lock. A launch holds triggers routinely — every event while the app is still inactive — from
     whichever task recorded it, while `didBecomeActive` and the launch's sync each drain the list from tasks of their
     own. A class, not an actor, so nothing else serialises them.
     */
    private let undrawnLock = NSLock()

    private func withUndrawnTriggers<T>(_ body: (inout [(String, [String: Any], [String: Any]?)]) -> T) -> T {
        undrawnLock.lock()
        defer { undrawnLock.unlock() }
        return body(&_undrawnTriggers)
    }

    /**
     When the message currently on screen was handed to the renderer, or nil if none is.

     "One at a time" has to hold across events, not only within one: a launch fires six of them
     in a few hundred milliseconds, and each could otherwise spend another queued `immediate`
     message — three displays reported, of which the person saw one. A renderer's hold lasts until
     the person answers or `TreebarsConstants.inAppPresentationHold` has passed: a duration rather
     than a flag the host clears, so a renderer that never reports back cannot hold the screen for
     good. `PresentationSlot` says why it is claimed under a lock rather than read and then written.
     */
    private let presentation = PresentationSlot()

    /**
     Whether this build draws an overlay itself: a markup body, and a standard one when no renderer is registered.
     Never without UIKit, where there is nothing to draw with.
     */
    static var coreDraws: Bool {
        #if canImport(UIKit)
        return true
        #else
        return false
        #endif
    }

    /// Whether a message in the queue is one this SDK would draw with no renderer registered: on a device with UIKit,
    /// any overlay.
    private func queueHasWhatTheCoreDraws() -> Bool {
        inApp.list().contains { $0.content.in_app.map { inAppDrawer($0, hasRenderer: false, coreDraws: Self.coreDraws) != .none } ?? false }
    }

    /**
     Answer a trigger that fired before anything could draw. Once, and only when something can: a renderer, or a queued
     message this SDK draws itself.

     Deliberately not a replay of every missed trigger in turn: `allows` and the frequency
     policy are still the gate, and drawing for each held trigger would spend a day's
     allowance in one launch. It stops at the first message shown, as the draw loop does.
     */
    private func replayUndrawnTriggers() async {
        guard inAppRenderer != nil || queueHasWhatTheCoreDraws() else { return }

        // Taken and cleared before replaying: `drawInApp` re-appends a trigger if the renderer
        // has gone again, and mutating the list being iterated is the bug that would follow.
        let pending: [(String, [String: Any], [String: Any]?)] = withUndrawnTriggers { held in
            defer { held.removeAll() }
            return held
        }
        guard !pending.isEmpty else { return }

        for (eventName, properties, dimensions) in pending {
            TreebarsLogger.log("in-app: replaying held '\(eventName)'")
            if await drawInApp(eventName: eventName, properties: properties, dimensions: dimensions) { return }
        }
    }

    /**
     The half that needs somewhere to draw. Split out so a replay does not re-sync.

     Returns whether a message was actually shown, which is what stops a replay after the
     first draw — the loop below already refuses to stack two overlays, and a replay must not
     get round that by calling this once per held trigger.
     */
    @discardableResult
    private func drawInApp(eventName: String, properties: [String: Any], dimensions: [String: Any]?) async -> Bool {
        guard inAppEnabled else { return false }
        // Nor held for a renderer: a trigger replayed later would be the same spend on a screen that has gone.
        if isLeavingEvent(eventName) { return false }
        /*
         The push state, read now rather than trusted from the last foreground: somebody can switch
         notifications on in Settings and come straight back, and a primer drawn then asks for what they just gave. Only
         when a message waits on it — the read is a round trip to `UNUserNotificationCenter`.
         */
        if inApp.list().contains(where: { $0.content.in_app?.display?.only_when_push_askable == true }) {
            await DeviceInfo.refreshPermission()
        }

        /*
         A self-handled message is the app's to draw: handed to its delegate whether or not a renderer exists — an
         app that draws only its own messages sets no renderer at all — and never to the renderer while a delegate is
         set. Nothing is spent here; the app's `selfHandledShown` is the display.
         */
        let delegate = await MainActor.run { () -> TreebarsInAppDelegate? in
            guard let delegate = self.inAppDelegate, delegate.handlesSelfHandledInApps else { return nil }
            return delegate
        }
        if let delegate, !Self.isInAppReport(eventName) {
            let session = await sessionManager.currentID()
            for message in inApp.list() {
                guard let content = message.content.in_app, content.surface == "overlay", content.display?.self_handled == true else { continue }
                guard inAppTriggerMatches(content.trigger, eventName: eventName, properties: properties,
                                          screenName: currentScreen, dimensions: dimensions) else { continue }
                guard inAppBlockedBy(message, content: content, session: session) == nil else { continue }
                TreebarsLogger.log("in-app: \(message.delivery_id) is self-handled; handed to the app")
                await MainActor.run { delegate.selfHandledInAppTriggered(message) }
                return true
            }
        }

        // A screen the app blocked (`blockInApp(forViewController:)`): held, and answered on the next screen.
        if await frontScreenIsBlocked() {
            holdTrigger(eventName, properties: properties, dimensions: dimensions, why: "the screen in front blocks in-app messages")
            return false
        }

        // Nothing to draw with. The queue is still worth having: the inbox reads it, and the
        // trigger is kept so it can be answered once something can. A markup body is this SDK's to draw, and a standard
        // one is too when no renderer is registered, so on a device only an inbox-only queue waits here.
        let renderer = inAppRenderer
        if renderer == nil, !queueHasWhatTheCoreDraws() {
            holdTrigger(eventName, properties: properties, dimensions: dimensions, why: "nothing can draw yet")
            return false
        }
        /*
         * Somewhere to draw, but nowhere for it to appear: the app is not active — in the background, where
         * an event can still be recorded, or still launching. Held exactly as for a missing renderer and answered when
         * the app becomes active, by the same replay, which asks the caps, the trigger and the store again. Above the
         * clear below, or the trigger would be wiped before it was kept.
         */
        guard await inAppSurfaceReady() else {
            holdTrigger(eventName, properties: properties, dimensions: dimensions, why: "no screen to draw on")
            return false
        }
        withUndrawnTriggers { $0.removeAll() }

        /*
         * Something is already on screen and has not been answered. Returning here leaves the
         * message in the store with nothing spent, so the next event after the person deals
         * with this one is its opportunity.
         */
        // Nudges first, in their own slot: a modal on screen holds back the next modal, not a nudge.
        if !Self.isInAppReport(eventName) { await drawNudges(eventName: eventName, properties: properties, dimensions: dimensions) }
        if presentation.isHeld() {
            TreebarsLogger.log("in-app: '\(eventName)' ignored, a message is still on screen")
            return false
        }

        // The session in progress, for the per-session cap; read once, not per candidate.
        let currentSession = await sessionManager.currentID()
        // Highest priority first; the list is newest first and the sort keeps that among equals.
        let ordered = inApp.list().enumerated().sorted { lhs, rhs in
            let left = lhs.element.content.in_app?.display?.priority ?? 5
            let right = rhs.element.content.in_app?.display?.priority ?? 5
            return left != right ? left > right : lhs.offset < rhs.offset
        }.map(\.element)
        for message in ordered {
            guard let content = message.content.in_app else { continue }
            // An inbox message is a row in a list the app draws; nothing is shown over
            // anything, so there is no trigger to fire.
            guard content.surface == "overlay" else { continue }
            // A nudge has its own pass, above, and its own slot.
            if isNudge(message) { continue }
            // The app's own, above, while it has a delegate to hand them to.
            if content.display?.self_handled == true, delegate != nil { continue }
            /*
             * Say why, for each candidate. An in-app that does not appear has half a dozen
             * equally plausible causes — wrong surface, an unmatched trigger, the frequency
             * policy, an expiry, a `done` entry from a dismissal — and without a trace,
             * diagnosing one means reading the store off the device and reasoning backwards.
             * Only under `debug`, one line per skipped message.
             */
            guard inAppTriggerMatches(content.trigger, eventName: eventName,
                                      properties: properties, screenName: currentScreen,
                                      dimensions: dimensions) else {
                TreebarsLogger.log(
                    "in-app: \(message.delivery_id) trigger \(content.trigger.kind) "
                        + "does not match '\(eventName)'"
                )
                continue
            }
            // Already waiting out its delay: the trigger firing again is not a second message.
            if delayedDelivery == message.delivery_id { return false }
            if let blocked = inAppBlockedBy(message, content: content, session: currentSession) {
                TreebarsLogger.log("in-app: \(message.delivery_id) matched but is held back (\(blocked))")
                if blocked != "done" { await reportInAppFailure(message, reason: blocked) }
                continue
            }

            // A delay. Asked again when it is up — a cap may have been spent, or the context left, meanwhile.
            if content.display?.on == "delay", let delay = content.display?.delay_seconds, delay > 0 {
                if delayedDelivery != nil { return false }
                delayedDelivery = message.delivery_id
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                    await self.presentDelayed(message, content: content)
                }
                return true
            }

            // One at a time: two overlays at once is two messages nobody reads. False when another
            // event's consideration claimed the screen first; this message stays queued, unspent.
            let noSurface = {
                self.holdTrigger(eventName, properties: properties, dimensions: dimensions,
                                 why: "the screen went before the message could be drawn")
            }
            /*
             Who draws it: a markup body is the WebView host's whatever is registered; a registered renderer is handed a
             standard body and the SDK draws nothing of it; with none, the SDK draws the standard body from its plan.
             */
            switch inAppDrawer(content, hasRenderer: renderer != nil, coreDraws: Self.coreDraws) {
            case .markup:
                return await presentHtml(message, content: content, noSurface: noSurface)
            case .app:
                guard let renderer else { continue }
                return await presentInApp(message, content: content, renderer: renderer, session: currentSession, noSurface: noSurface)
            case .native:
                return await presentNative(message, content: content, session: currentSession, noSurface: noSurface)
            case .none:
                // Nothing here draws it (no UIKit, no renderer): it waits, and a message further down may not.
                continue
            }
        }
        return false
    }

    /**
     Keep a trigger to answer once something can draw it. Bounded, because this is only ever a launch's worth of
     events and an unbounded list keyed on event name would grow with a custom vocabulary.
     */
    private func holdTrigger(_ eventName: String, properties: [String: Any], dimensions: [String: Any]?, why: String) {
        guard !Self.isInAppReport(eventName) else { return }
        let kept: Bool = withUndrawnTriggers { held in
            guard held.count < 16, !held.contains(where: { $0.0 == eventName }) else { return false }
            held.append((eventName, properties, dimensions))
            return true
        }
        guard kept else { return }
        TreebarsLogger.log("in-app: held '\(eventName)', \(why)")
    }

    /// Whether the view controller in front is one the app blocked. Always false where there is no UIKit.
    private func frontScreenIsBlocked() async -> Bool {
        guard !blockedScreens.isEmpty else { return false }
        #if canImport(UIKit)
        let blocked = blockedScreens
        return await MainActor.run {
            let window = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)
            var front = window?.rootViewController
            while let presented = front?.presentedViewController { front = presented }
            if let navigation = front as? UINavigationController { front = navigation.visibleViewController ?? navigation }
            if let tabs = front as? UITabBarController { front = tabs.selectedViewController ?? tabs }
            guard let front else { return false }
            return blocked.contains(String(describing: type(of: front)))
        }
        #else
        return false
        #endif
    }

    /**
     Whether an overlay handed to the app now would appear: the app is active. An event can be recorded in the
     background — a silent push, a background task — and a message drawn then would be reported displayed with nobody
     to see it. Read on the main actor, where the state lives.
     */
    private func inAppSurfaceReady() async -> Bool {
        #if canImport(UIKit)
        return await MainActor.run { UIApplication.shared.applicationState == .active }
        #else
        return true
        #endif
    }

    /**
     A delayed message whose delay is up, or which is waiting for the screen.

     A message whose delay ends while another holds the screen waits for it rather than being dropped —
     otherwise it would next appear on a later matching trigger, which for a `session_start + 10s`
     message is the next session. It looks again every `delayedInAppRetryNanoseconds` and asks the caps
     again each time (`delayedInAppStep`): shown once the other message is answered or its hold lapses,
     or reported as not shown (`in_app_failed`) when a cap closes on it meanwhile — the minimum gap,
     typically, since the other message was just drawn. `delayedDelivery` stays set while it waits, so
     the trigger firing again is still not a second message; `reset()` clears it, as `identify` does for
     somebody else, and a waiting message whose person left goes with it.
     */
    private func presentDelayed(_ message: InAppMessage, content: InAppContent) async {
        // What the last look saw, for the present that follows it.
        var session: String?
        var renderer: InAppRenderer?
        await runDelayedInApp(
            stillWaiting: { self.delayedDelivery == message.delivery_id },
            look: {
                session = await self.sessionManager.currentID()
                renderer = self.inAppRenderer
                // No screen to draw on waits as a taken one does: the message is shown once there is one.
                let surface = await self.inAppSurfaceReady()
                return delayedInAppStep(
                    blocked: self.inAppBlockedBy(message, content: content, session: session),
                    // Something to draw it with — the app's renderer or this SDK — else `no_renderer`.
                    hasRenderer: inAppDrawer(content, hasRenderer: renderer != nil, coreDraws: Self.coreDraws) != .none,
                    screenHeld: self.presentation.isHeld() || !surface
                )
            },
            // Another consideration can still claim the slot between the look and the claim; then it waits again.
            present: {
                let again = {
                    // The screen went between the look and the draw: wait for it again, unspent.
                    self.delayedDelivery = message.delivery_id
                    Task {
                        try? await Task.sleep(nanoseconds: delayedInAppRetryNanoseconds)
                        await self.presentDelayed(message, content: content)
                    }
                }
                // The same hook as the immediate path's, so a delayed message is drawn by whoever would draw it at once.
                switch inAppDrawer(content, hasRenderer: renderer != nil, coreDraws: Self.coreDraws) {
                case .markup:
                    return await self.presentHtml(message, content: content, noSurface: again)
                case .app:
                    guard let renderer else { return false }
                    return await self.presentInApp(message, content: content, renderer: renderer, session: session, noSurface: again)
                case .native:
                    return await self.presentNative(message, content: content, session: session, noSurface: again)
                case .none:
                    return false
                }
            },
            finish: { self.delayedDelivery = nil },
            report: { await self.reportInAppFailure(message, reason: $0) },
            sleep: { try? await Task.sleep(nanoseconds: delayedInAppRetryNanoseconds) }
        )
    }

    /// The store's caps, then the app's contexts, as one answer: why not, or nil.
    private func inAppBlockedBy(_ message: InAppMessage, content: InAppContent, session: String?) -> String? {
        if let blocked = inApp.blockedBy(message, session: session, nudgesInFlight: isNudge(message) ? nudgeSlots.inFlight : 0) {
            return blocked
        }
        let contexts = content.display?.contexts ?? []
        if !contexts.isEmpty, !contexts.contains(where: { appContexts.contains($0) }) { return "context" }
        // A primer is for people who can still be asked; `drawInApp` refreshed the read just before.
        if let blocked = pushAskableBlock(content.display, status: DeviceInfo.cachedNotificationPermission) { return blocked }
        return nil
    }

    /// `in_app_failed`: once per message, reason and day, for the campaign's failure report.
    private func reportInAppFailure(_ message: InAppMessage, reason: String) async {
        guard let campaign = message.campaign_id else { return }
        guard inApp.claimFailureReport(message.delivery_id, reason: reason) else { return }
        await enqueue(eventName: "in_app_failed", properties: [
            Self.deliveryIdKey: message.delivery_id, Self.campaignIdKey: campaign, "reason": reason,
        ])
    }

    /**
     Claims the screen and hands the message to the app, and says whether the screen was claimed. `noSurface` runs
     when the app turned out not to be active by the time the handing-over ran; nothing is spent then, and the caller
     keeps what it needs to try again.
     */
    @discardableResult
    private func presentInApp(
        _ message: InAppMessage,
        content: InAppContent,
        renderer: @escaping InAppRenderer,
        session: String?,
        noSurface: @escaping () -> Void
    ) async -> Bool {
        // Claimed before anything is spent or reported, and in one step with the check: see `PresentationSlot`.
        guard presentation.claim() else {
            TreebarsLogger.log("in-app: \(message.delivery_id) not shown, another message took the screen first")
            return false
        }

        /*
         * Asked once more on the thread that draws, and spent only after: an app that went inactive in between would
         * otherwise have a message reported as seen that nobody saw, with nothing able to show it again.
         */
        guard await inAppSurfaceReady() else {
            presentation.release()
            TreebarsLogger.log("in-app: \(message.delivery_id) not shown, no screen to draw on; nothing spent")
            noSurface()
            return true
        }
        TreebarsLogger.log("in-app: showing \(message.delivery_id)")

        inApp.recordDisplay(message, session: session)
        /*
         * "Any event is an opportunity; the first one after a sync wins" (see the trigger
         * matcher) is only true if showing it also spends it. `recordDisplay` alone marks a
         * message done once `max_displays` is reached, which an immediate-trigger message
         * rarely sets — a test send never does — so without this, every later event in the
         * same session would match `immediate` again and redraw the same message, once per
         * event. `isInAppReport` does not cover it: that only stops the SDK re-triggering off
         * its own reports.
         */
        if content.trigger.kind == "immediate" { inApp.markDone(message.delivery_id) }
        await enqueue(eventName: "in_app_displayed", properties: inAppReceipt(message))

        let draw = renderer
        await MainActor.run { self.inAppDelegate?.inAppShown(message) }
        await MainActor.run {
            draw(message, self.inApp.tokensFor(message, dark: Self.appearsDark()), { button in
                // The two-step push opt-in: this link asks for permission rather than opening anything.
                if button.value == TreebarsConstants.pushPermissionLink {
                    Task { _ = await Treebars.requestPushPermission() }
                }
                // A call to action spends the message as a dismissal does, and frees the screen: see
                // `inAppClickEndsMessage`. Before the action, which may record an event that draws the next one.
                if inAppClickEndsMessage(button) {
                    self.presentation.releaseUnpinned()
                    self.inApp.markDone(message.delivery_id)
                }
                // Reported before the app is handed the destination, so a tap that
                // leaves the app is still recorded.
                Task {
                    await self.enqueue(eventName: "in_app_clicked", properties: inAppClickProperties(message, button: button))
                    await self.inAppButtonAction(message, button: button)
                    await self.uploader?.flush()
                }
            }, {
                // Free again the moment the person answers, so a dismiss and the next
                // message are not separated by the hold.
                self.presentation.releaseUnpinned()
                self.inApp.markDone(message.delivery_id)
                self.inAppDelegate?.inAppDismissed(message)
                Task {
                    await self.enqueue(eventName: "in_app_dismissed", properties: inAppReceipt(message))
                }
            })
        }
        return true
    }

    /// A WebView made ahead of time while an HTML message is queued, and let go when none is (`InAppHtmlHost.warm`).
    private func warmForQueuedHtml() async {
        #if canImport(UIKit)
        let queued = inAppEnabled && inApp.list().contains { $0.content.in_app.map(Self.drawsItself) == true && !inApp.isDone($0.delivery_id) }
        await MainActor.run { queued ? InAppHtmlHost.warm() : InAppHtmlHost.cool() }
        #endif
    }

    /**
     The files every held message loads, fetched now and kept by hash, so a message drawn later —
     offline, or a second after the app opens — has them. Detached from the sync: the trigger list and the nudges this
     sync answers do not wait for pictures.
     */
    private func prefetchAssets() {
        let held = inApp.list().map { message -> (manifest: InAppAssetManifest?, markup: Bool) in
            (message.assets, message.content.in_app.map(Self.drawsItself) ?? false)
        }
        guard held.contains(where: { $0.manifest != nil }) else { return }
        let cache = assetCache
        Task.detached(priority: .utility) { await cache.prefetch(held) }
    }

    /// A markup body's document with its files inlined, or nil when it must not be drawn: a store file it names
    /// is gone, or one it inlines could not be had. Disk, and the network for what the prefetch has not landed yet.
    private func preparedMarkup(_ message: InAppMessage, html: String) async -> String? {
        let cache = assetCache
        let manifest = message.assets
        return await Task.detached(priority: .userInitiated) { await cache.prepare(manifest, html: html) }.value
    }

    /// A markup body: this SDK's to draw, in a WKWebView with the `treebars` bridge. A legacy
    /// `layout: "html"` is a fullscreen markup body. Never on a host without UIKit, where there is nothing to draw with.
    static func drawsItself(_ content: InAppContent) -> Bool {
        // The hook's own answer, so the WebView host's share of it cannot drift from the branches that ask it.
        inAppDrawer(content, hasRenderer: false, coreDraws: coreDraws) == .markup
    }

    /**
     Claims the screen and draws a markup body itself, the iOS half of the web SDK's `renderMarkup`
     and of Android's `presentHtml`. Counted as displayed when the page says it is running (`onShown`), not when the
     WebView is made: a page that never runs (`render_error`) is not a display and spends nothing but its report. A
     body over 64 KiB whose fetch never landed is `asset_download`. `noSurface` runs, and nothing is spent, when the app
     turned out not to be showing a scene by the time the drawing ran.
     */
    private func presentHtml(_ message: InAppMessage, content: InAppContent, noSurface: @escaping () -> Void) async -> Bool {
        #if canImport(UIKit)
        // Held until the host says the message ended, which it does on every path: see `PresentationSlot`.
        guard presentation.claim(untilReleased: true) else {
            TreebarsLogger.log("in-app: \(message.delivery_id) not shown, another message took the screen first")
            return false
        }
        guard let html = content.html, !html.isEmpty else {
            presentation.release()
            await reportInAppFailure(message, reason: content.html_ref != nil ? "asset_download" : "render_error")
            return false
        }
        /*
         Its files inlined first, off the main actor: read from disk — or fetched, when the prefetch this
         session's sync started has not landed them. The screen is already claimed, so nothing else is drawn meanwhile.
         A store file that is gone, or one that could not be had, is `asset_download`, as a body that never arrived is.
         */
        guard let prepared = await preparedMarkup(message, html: html) else {
            presentation.release()
            await reportInAppFailure(message, reason: "asset_download")
            return false
        }
        let tokens = inApp.tokensFor(message, dark: await MainActor.run { Self.appearsDark() })
        let drawing: Bool = await MainActor.run {
            guard UIApplication.shared.applicationState == .active, let scene = InAppHtmlHost.activeScene() else { return false }
            TreebarsLogger.log("in-app: drawing \(message.delivery_id) (markup)")
            let sdk = HtmlBridge(core: self, message: message)
            // How long the page took to run and show, from here; and whether this is the process's first WKWebView.
            sdk.started = DispatchTime.now().uptimeNanoseconds
            sdk.cold = !self.htmlDrawnInProcess
            self.htmlDrawnInProcess = true
            let display = BridgeDisplay(message: message, sdk: sdk) { delay, run in
                // Scheduled from the main thread and run on it: the display is main-thread only.
                let later = MainThreadWork(run: run)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay / 1000) { later.run() }
            }
            let host = InAppHtmlHost(
                message: message,
                content: content,
                tokens: tokens,
                display: display,
                onShown: { [weak sdk] in sdk?.shown(content: content) },
                onFailed: { [weak self] reason in
                    guard let self else { return }
                    self.htmlHost = nil
                    self.presentation.release()
                    // A page that would not run will not run on the next event either.
                    if reason == "render_error" { self.inApp.markDone(message.delivery_id) }
                    Task { await self.reportInAppFailure(message, reason: reason) }
                },
                onPersonClosed: { display.dismiss() },
                customizer: self.webViewCustomizer,
                html: prepared
            )
            sdk.host = host
            self.htmlHost = host
            host.show(in: scene)
            return true
        }
        if !drawing {
            presentation.release()
            TreebarsLogger.log("in-app: \(message.delivery_id) not shown, no screen to draw on; nothing spent")
            noSurface()
        }
        return true
        #else
        return false
        #endif
    }

    /**
     Claims the screen and draws a standard body itself, from its render plan: what happens when no renderer is
     registered. The iOS half of Android's native host.

     The environment is read on the main actor as it is drawn — the scene's appearance, the pad idiom as a tablet, and the
     sync's project tokens for a message queued before messages carried their own — and never cached, so a message drawn
     after the phone went dark is planned dark. The screen is held until the host says the message ended, as the HTML
     host's is (`claim(untilReleased:)`): this SDK reports every ending itself, so the renderer's 30-second ceiling would
     only let the next message be drawn over one somebody is still reading. `noSurface` runs, and nothing is spent, when
     the app turned out not to be showing a scene by the time the drawing ran.
     */
    private func presentNative(_ message: InAppMessage, content: InAppContent, session: String?, noSurface: @escaping () -> Void) async -> Bool {
        #if canImport(UIKit)
        guard presentation.claim(untilReleased: true) else {
            TreebarsLogger.log("in-app: \(message.delivery_id) not shown, another message took the screen first")
            return false
        }
        let fallback = inApp.projectTokens()
        let outcome: NativeOutcome = await MainActor.run {
            guard UIApplication.shared.applicationState == .active, let scene = InAppHtmlHost.activeScene() else { return .noScreen }
            let env = InAppRenderEnv(
                appearance: scene.traitCollection.userInterfaceStyle == .dark ? "dark" : "light",
                platform: "ios",
                device_class: UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "mobile",
                fallback_tokens: fallback,
                // The scene's, which the message's own window inherits: what the words will actually be drawn at. The
                // app's setting only if the scene has not said.
                text_size: inAppTextSize(
                    scene.traitCollection.preferredContentSizeCategory == .unspecified
                        ? UIApplication.shared.preferredContentSizeCategory : scene.traitCollection.preferredContentSizeCategory
                )
            )
            /*
             Only an overlay reaches here — an inbox row never does, and a markup body goes to the WebView host — but a
             message whose `body_mode` is neither word beside a legacy `layout: "html"` is read as markup by the plan and
             as standard by `inAppDrawer`; it is let go rather than drawn as something the plan did not plan.
             */
            guard case .overlay(let plan) = inAppRenderPlan(InAppRenderInput(message), env: env) else { return .notOverlay }
            TreebarsLogger.log("in-app: drawing \(message.delivery_id) (native \(plan.shape))")
            let display = NativeDisplay(core: self, message: message, session: session)
            let host = InAppNativeHost(
                plan: plan,
                onShown: { display.shown() },
                onPressed: { display.pressed($0) },
                onDismissed: { display.dismissed() },
                onSubmitted: { display.submitted($0) },
                onAnswered: { display.answered() }
            )
            self.nativeHost = host
            host.show(in: scene)
            return .drawn
        }
        switch outcome {
        case .drawn:
            return true
        case .noScreen:
            presentation.release()
            TreebarsLogger.log("in-app: \(message.delivery_id) not shown, no screen to draw on; nothing spent")
            noSurface()
            return true
        case .notOverlay:
            presentation.release()
            TreebarsLogger.log("in-app: \(message.delivery_id) not drawn: its plan is not an overlay")
            return false
        }
        #else
        return false
        #endif
    }

    private enum NativeOutcome {
        case drawn, noScreen, notOverlay
    }

    /**
     The nudges this event brings: only on the screen the app allowed them on (`showNudge`) and at the
     edge it asked for, each matching one drawn at once, up to three, outside the channel's caps (`isNudge`) but inside every
     rule of its own. The on-app moment (a delay) is not waited for: a nudge that has to wait is a modal.
     */
    private func drawNudges(eventName: String, properties: [String: Any], dimensions: [String: Any]?) async {
        #if canImport(UIKit)
        guard inAppEnabled, let place = nudgePlace, place.screen == currentScreen else { return }
        let session = await sessionManager.currentID()
        let ordered = inApp.list().enumerated().sorted { lhs, rhs in
            let left = lhs.element.content.in_app?.display?.priority ?? 5
            let right = rhs.element.content.in_app?.display?.priority ?? 5
            return left != right ? left > right : lhs.offset < rhs.offset
        }.map(\.element)
        for message in ordered {
            guard nudgeSlots.hasRoom else { return }
            guard let content = message.content.in_app, content.surface == "overlay", isNudge(message), Self.drawsItself(content) else { continue }
            guard place.position.admits(content.position), !nudgeSlots.holds(message.delivery_id) else { continue }
            guard inAppTriggerMatches(content.trigger, eventName: eventName, properties: properties, screenName: currentScreen, dimensions: dimensions) else { continue }
            if let blocked = inAppBlockedBy(message, content: content, session: session) {
                if blocked != "done" { await reportInAppFailure(message, reason: blocked) }
                continue
            }
            await presentNudge(message, content: content)
        }
        #endif
    }

    #if canImport(UIKit)
    /// Draws one nudge in its own window over the app, which lets every touch around it through.
    private func presentNudge(_ message: InAppMessage, content: InAppContent) async {
        guard nudgeSlots.claim(message.delivery_id) else { return }
        guard let html = content.html, !html.isEmpty else {
            nudgeSlots.release(message.delivery_id)
            await reportInAppFailure(message, reason: content.html_ref != nil ? "asset_download" : "render_error")
            return
        }
        // Its files inlined first, as a modal's are.
        guard let prepared = await preparedMarkup(message, html: html) else {
            nudgeSlots.release(message.delivery_id)
            await reportInAppFailure(message, reason: "asset_download")
            return
        }
        let tokens = inApp.tokensFor(message, dark: await MainActor.run { Self.appearsDark() })
        let drawing: Bool = await MainActor.run {
            guard UIApplication.shared.applicationState == .active, let scene = InAppHtmlHost.activeScene() else { return false }
            TreebarsLogger.log("in-app: drawing \(message.delivery_id) (nudge)")
            let sdk = HtmlBridge(core: self, message: message)
            sdk.started = DispatchTime.now().uptimeNanoseconds
            let display = BridgeDisplay(message: message, sdk: sdk) { delay, run in
                let later = MainThreadWork(run: run)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay / 1000) { later.run() }
            }
            let host = InAppHtmlHost(
                message: message,
                content: content,
                tokens: tokens,
                display: display,
                onShown: { [weak sdk] in sdk?.shown(content: content) },
                onFailed: { [weak self] reason in
                    guard let self else { return }
                    self.nudgeHosts[message.delivery_id] = nil
                    self.nudgeSlots.release(message.delivery_id)
                    if reason == "render_error" { self.inApp.markDone(message.delivery_id) }
                    Task { await self.reportInAppFailure(message, reason: reason) }
                },
                onPersonClosed: { display.dismiss() },
                customizer: self.webViewCustomizer,
                html: prepared
            )
            sdk.host = host
            self.nudgeHosts[message.delivery_id] = host
            host.show(in: scene)
            return true
        }
        if !drawing { nudgeSlots.release(message.delivery_id) }
    }

    /// Every nudge taken down: the screen they were allowed on went, or in-app did. Nothing is spent.
    @MainActor private func closeNudges() {
        for (id, host) in nudgeHosts {
            host.destroy()
            nudgeSlots.release(id)
        }
        nudgeHosts = [:]
    }

    /**
     What one native display records: the same receipts a registered renderer's display records
     through `presentInApp`, byte for byte — the same `inAppClickProperties`, `inAppButtonAction` and `submitInAppForm` —
     so a campaign's report cannot tell which drew it.

     Every event goes through `then`, one Task after the last, as `HtmlBridge`'s do: a Task each is ordered by nothing,
     and a quick press would land `in_app_clicked` before the `in_app_displayed` it answers. Called on the main thread.
     */
    private final class NativeDisplay {
        private let core: Treebars
        private let message: InAppMessage
        private let session: String?
        private var tail: Task<Void, Never>?

        init(core: Treebars, message: InAppMessage, session: String?) {
            self.core = core
            self.message = message
            self.session = session
        }

        private func then(_ work: @escaping () async -> Void) {
            let previous = tail
            tail = Task {
                await previous?.value
                await work()
            }
        }

        /// On screen: the display, spent and reported as any display is.
        func shown() {
            let core = core
            let message = message
            let session = session
            then {
                core.inApp.recordDisplay(message, session: session)
                // An `immediate` message matches every event: spent now, or the next event draws it again (see `presentInApp`).
                if message.content.in_app?.trigger.kind == "immediate" { core.inApp.markDone(message.delivery_id) }
                await core.enqueue(eventName: "in_app_displayed", properties: inAppReceipt(message))
            }
            MainActor.assumeIsolated { core.inAppDelegate?.inAppShown(message) }
        }

        /// The ✕, the dim, the escape, the timer or a `dismiss` button: done on this device and the screen free at once.
        func dismissed() {
            let core = core
            let message = message
            core.presentation.release()
            core.inApp.markDone(message.delivery_id)
            MainActor.assumeIsolated {
                core.nativeHost = nil
                core.inAppDelegate?.inAppDismissed(message)
            }
            then { await core.enqueue(eventName: "in_app_dismissed", properties: inAppReceipt(message)) }
        }

        /**
         A button: recorded, its action done, then where it leads opened — after the message has closed (the host closed
         it before calling here) and after the click is in the queue, so a press that leaves the app is still recorded.
         Every action the plan draws but `dismiss` ends the message (`inAppClickEndsMessage`), so it is spent and the
         screen freed here rather than when the app next looks.
         */
        func pressed(_ planned: InAppPlanButton) {
            let core = core
            let message = message
            // The message's own button, as the app's renderer would have been handed it; the plan's copy if it has gone.
            let button = message.content.in_app?.buttons?.first(where: { $0.index == planned.index }) ?? InAppButton(
                label: planned.label, action: planned.action, value: planned.value,
                event_name: planned.event_name, key: planned.key, data: planned.data, index: planned.index
            )
            // The two-step push opt-in: this link asks for permission rather than opening anything.
            if button.value == TreebarsConstants.pushPermissionLink {
                Task { _ = await Treebars.requestPushPermission() }
            }
            core.presentation.release()
            core.inApp.markDone(message.delivery_id)
            MainActor.assumeIsolated { core.nativeHost = nil }
            let destination = planned.destination
            then {
                await core.enqueue(eventName: "in_app_clicked", properties: inAppClickProperties(message, button: button))
                await core.inAppButtonAction(message, button: button)
                // A link or a page, never a trait's value or the opt-in link (the plan's `destination`). The system routes
                // the app's own scheme back to it and a web address to the browser.
                if let destination, let url = URL(string: destination) {
                    await MainActor.run { UIApplication.shared.open(url) }
                }
                await core.uploader?.flush()
            }
        }

        /// The form, checked and sent: `submitInAppForm` spends the message and records the answers. The screen stays
        /// held — it only lets go of a renderer's hold — while the thanks is on it.
        func submitted(_ answers: [String: Any]) {
            Treebars.submitInAppForm(message, responses: answers)
        }

        /// The thanks has been read and the message gone. Nothing more is recorded: the answers are the record.
        func answered() {
            let core = core
            core.presentation.release()
            MainActor.assumeIsolated { core.nativeHost = nil }
        }
    }

    /// A closure handed to the main queue from the main thread, which the compiler cannot see is never shared.
    private struct MainThreadWork: @unchecked Sendable {
        let run: () -> Void
    }

    /**
     What one HTML display may ask of this SDK (`BridgeSdk`). Called on the main thread, where the display lives.

     Every event goes through `tail`, one Task after the last: a Task each would be ordered by nothing, and a page
     that says `_screen` then `trackClick` would be recorded the other way round as often as not.
     */
    private final class HtmlBridge: BridgeSdk {
        private let core: Treebars
        private let message: InAppMessage
        weak var host: InAppHtmlHost?
        var started: UInt64 = 0
        var cold = false
        private var tail: Task<Void, Never>?

        init(core: Treebars, message: InAppMessage) {
            self.core = core
            self.message = message
        }

        private func then(_ work: @escaping () async -> Void) {
            let previous = tail
            tail = Task {
                await previous?.value
                await work()
            }
        }

        /// The page is running and on screen: the display, spent and reported as any display is.
        func shown(content: InAppContent) {
            let core = core
            let message = message
            var receipt = inAppReceipt(message)
            receipt["render_ms"] = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            receipt["cold"] = cold
            then {
                let session = await core.sessionManager.currentID()
                core.inApp.recordDisplay(message, session: session)
                // Counted in the ledger first, then no longer in flight: never neither.
                core.nudgeSlots.shown(message.delivery_id)
                if content.trigger.kind == "immediate" { core.inApp.markDone(message.delivery_id) }
                await core.enqueue(eventName: "in_app_displayed", properties: receipt)
            }
            MainActor.assumeIsolated { core.inAppDelegate?.inAppShown(message) }
        }

        func track(_ name: String, _ properties: [String: Any]) {
            let core = core
            then { await core.enqueue(eventName: name, properties: properties) }
        }

        /*
         Asked off the main actor and answered back on it, where the display lives. Asked again after a 429, a 503 or no
         answer, within a few seconds: a repeated claim is answered as the first one was, so asking again cannot claim
         twice (`RewardClaim.swift`).
         */
        func claimReward(_ pool: String, deliveryID: String, _ answer: @escaping ([String: Any]) -> Void) {
            guard let client = core.backendClient else { return answer(BridgeDisplay.refuse("not_available")) }
            let userID = core.userId
            let signature = core.userSignature
            Task {
                let last = await claimWithRetries(ask: {
                    await client.postInAppReward(
                        deviceID: DeviceInfo.getDeviceId(), secret: DeviceInfo.getFetchSecret(), userID: userID, signature: signature,
                        deliveryID: deliveryID, pool: pool
                    )
                })
                let result = last.answer ?? BridgeDisplay.refuse(rewardRefusalReason(last))
                await MainActor.run { answer(result) }
            }
        }

        func setTraits(_ traits: [String: Any]) -> [String: Any] {
            Treebars.setMessageTraits(traits)
            return BridgeDisplay.ok
        }

        func requestPushPermission(_ answer: @escaping (String) -> Void) {
            Task { @MainActor in
                let granted = await Treebars.requestPushPermission()
                answer(granted ? "granted" : "denied")
            }
        }

        func clicked(action: String, values: [String: Any], fields: [String: Any]) {
            let strings = values.mapValues(jsText)
            let button = InAppButton(
                label: fields[TreebarsConstants.inAppButtonLabelKey] as? String ?? fields[InAppBridge.keyElement] as? String ?? "",
                action: action,
                value: fields[InAppBridge.keyDestination] as? String,
                data: strings,
                index: fields[TreebarsConstants.inAppButtonIndexKey] as? Int
            )
            let message = message
            MainActor.assumeIsolated {
                core.inAppDelegate?.inAppClicked(message, action: InAppClickAction(type: action, values: strings, button: button))
            }
        }

        /// A press that leads somewhere takes the message with it, as the page going does on the web: spent and the
        /// screen freed while it stayed drawn was a message nothing could stop another from being drawn over.
        func spent() {
            // The slot this message took: a nudge's place, or the screen a modal holds.
            if isNudge(message) { core.nudgeSlots.release(message.delivery_id) } else { core.presentation.release() }
            core.inApp.markDone(message.delivery_id)
            MainActor.assumeIsolated {
                guard let host else { return }
                host.destroy()
                if core.htmlHost === host { core.htmlHost = nil }
                if core.nudgeHosts[message.delivery_id] === host { core.nudgeHosts[message.delivery_id] = nil }
            }
            let owner = core
            Task { await owner.warmForQueuedHtml() }
        }

        func dismissed() {
            let nudge = isNudge(message)
            if nudge { core.nudgeSlots.release(message.delivery_id) } else { core.presentation.release() }
            core.inApp.markDone(message.delivery_id)
            let message = message
            MainActor.assumeIsolated {
                if nudge { core.nudgeHosts[message.delivery_id] = nil } else { core.htmlHost = nil }
                core.inAppDelegate?.inAppDismissed(message)
            }
            let owner = core
            Task { await owner.warmForQueuedHtml() }
        }

        func flush() {
            let core = core
            then { await core.uploader?.flush() }
        }

        func keep(key: String, value: Any?) {
            core.inApp.setStored(message.delivery_id, key: key, value: value.flatMap(InAppStoredValue.init))
        }

        private func openURL(_ text: String) -> Bool {
            guard let url = URL(string: text) else { return false }
            MainActor.assumeIsolated { UIApplication.shared.open(url) }
            return true
        }

        func open(_ url: String, via: String) -> Bool {
            // The two-step push opt-in: this link asks for permission rather than opening anything.
            if url == TreebarsConstants.pushPermissionLink {
                Task { _ = await Treebars.requestPushPermission() }
                return true
            }
            // A deep link is the app's own to route and a web address leaves for the browser; the system decides which.
            return openURL(url)
        }

        func copy(_ text: String, toast: String?) -> Bool {
            MainActor.assumeIsolated {
                DeviceActions.copy(text)
                if let toast { InAppToast.show(toast) }
            }
            return true
        }

        // The device's own acts, shared with a typed button's: `DeviceActions`.
        func dial(_ number: String) -> Bool {
            MainActor.assumeIsolated { DeviceActions.dial(number) }
        }

        func sms(_ number: String, body: String?) -> Bool {
            openURL("sms:\(DeviceActions.encoded(number.filter { !$0.isWhitespace }))" + (body.map { "&body=\(DeviceActions.encoded($0))" } ?? ""))
        }

        /// Where a sheet the page asked for is presented from: the message while it is up, else the app's front screen.
        private func presenter() -> UIViewController? {
            MainActor.assumeIsolated {
                if let front = host?.presenter() { return front }
                let window = InAppHtmlHost.activeScene()?.windows.first(where: \.isKeyWindow)
                var front = window?.rootViewController
                while let next = front?.presentedViewController { front = next }
                return front
            }
        }

        func share(_ text: String) -> Bool {
            guard let from = presenter() else { return false }
            MainActor.assumeIsolated { DeviceActions.share(text, from: from) }
            return true
        }

        func settings(notifications: Bool) -> Bool {
            if notifications, #available(iOS 16.0, *) {
                return openURL(UIApplication.openNotificationSettingsURLString)
            }
            return openURL(UIApplication.openSettingsURLString)
        }

        func storeReview() -> Bool {
            MainActor.assumeIsolated { DeviceActions.storeReview() }
        }

        func alert(_ message: String) {
            guard let from = presenter() else { return }
            MainActor.assumeIsolated {
                let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                from.present(alert, animated: true)
            }
        }

        func context() -> [String: Any] {
            MainActor.assumeIsolated {
                let insets = host?.currentInsets() ?? BridgeInsets(top: 0, right: 0, bottom: 0, left: 0)
                return [
                    "locale": Locale.preferredLanguages.first ?? Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
                    "theme": host?.isNight() == true ? "dark" : "light",
                    "insets": ["top": insets.top, "right": insets.right, "bottom": insets.bottom, "left": insets.left],
                ] as [String: Any]
            }
        }

        func log(_ line: String) {
            TreebarsLogger.log(line)
        }
    }
    #endif

    /**
     Bodies over 64 KiB, which the sync hands over as `html_ref`: each fetched once from
     `/v1/in-app/body`, checked against its SHA-256 and written into the answer before the store keeps it — or taken
     from the copy this device already holds. One that never arrives is `asset_download` when it would be drawn.
     Android's `fetchLargeBodies`; done on the answer's JSON, before it is decoded, because a decoded body is a `let`.
     */
    private func withLargeBodies(_ data: Data, client: BackendClient, secret: String) async -> Data {
        guard var answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var messages = answer["messages"] as? [Any] else { return data }
        let held = Dictionary(inApp.list().map { ($0.delivery_id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for index in messages.indices {
            guard var message = messages[index] as? [String: Any],
                  var content = message["content"] as? [String: Any],
                  var body = content["in_app"] as? [String: Any],
                  let sha = (body["html_ref"] as? [String: Any])?["sha256"] as? String, !sha.isEmpty,
                  (body["html"] as? String ?? "").isEmpty,
                  let deliveryID = message["delivery_id"] as? String else { continue }
            let kept = held[deliveryID]?.content.in_app
            var html: String?
            if let keptBody = kept?.html, !keptBody.isEmpty, kept?.html_ref?.sha256 == sha {
                html = keptBody
            } else if let fetched = await client.getInAppBody(
                deviceID: DeviceInfo.getDeviceId(), secret: secret, userID: userId, signature: userSignature, deliveryID: deliveryID
            ), Self.sha256Hex(fetched) == sha {
                html = fetched
            }
            guard let html else {
                TreebarsLogger.log("in-app: the body of \(deliveryID) did not arrive, or did not match its hash")
                continue
            }
            body["html"] = html
            content["in_app"] = body
            message["content"] = content
            messages[index] = message
            changed = true
        }
        guard changed else { return data }
        answer["messages"] = messages
        return (try? JSONSerialization.data(withJSONObject: answer)) ?? data
    }

    private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether the app is drawn dark right now: its front scene's appearance, which is what the
    /// app's own screens follow. Main thread; false where there is no UIKit.
    @MainActor
    static func appearsDark() -> Bool {
        #if canImport(UIKit)
        return InAppHtmlHost.activeScene()?.traitCollection.userInterfaceStyle == .dark
        #else
        return false
        #endif
    }

    /// What a button does beyond reporting the tap: an event, a trait, a device action, or keys for the app.
    private func inAppButtonAction(_ message: InAppMessage, button: InAppButton) async {
        var campaign: [String: Any] = [:]
        if let id = message.campaign_id { campaign[Self.campaignIdKey] = id }
        switch button.action {
        case "track_event":
            if let name = button.event_name { await enqueue(eventName: name, properties: campaign) }
        case "set_attribute":
            if let key = button.key { Treebars.setMessageTraits([key: button.value ?? ""]) }
        /*
         The device actions, done here by the SDK, as the HTML bridge's are — so the app's renderer draws the button
         and a React Native one only forwards the press. The same `DeviceActions`.
         */
        #if canImport(UIKit)
        case "call":
            if let number = button.value { await MainActor.run { _ = DeviceActions.dial(number) } }
        case "copy":
            if let text = button.value { await MainActor.run { DeviceActions.copy(text) } }
        case "share":
            // Not on the front controller: that is the app's closing message, and the sheet went down with it.
            if let text = button.value { await MainActor.run { _ = DeviceActions.shareInOwnWindow(text) } }
        case "store_review":
            await MainActor.run { _ = DeviceActions.storeReview() }
        #endif
        default:
            break
        }
        // Every press goes to the app's delegate after it is recorded; a `custom` button's keys arrive only there.
        // `dismiss` is a dismissal, not a press.
        guard button.action != "dismiss" else { return }
        let values = clickValues(button)
        let action = InAppClickAction(type: button.action, values: values, button: button)
        await MainActor.run { self.inAppDelegate?.inAppClicked(message, action: action) }
    }

    /// `userIdOverride` stamps an event with a user id the SDK no longer holds.
    ///
    /// One caller: `reset()`, whose event is *about* the sign-in that just ended. The
    /// identity has to be cleared synchronously — a logout that is only eventually true is
    /// a bug the caller cannot see — but this event still belongs to the person who left.
    /// The same shape `session_end` already uses with `timestamp` and `detached`.
    private func enqueue(
        eventName: String,
        properties: [String: Any],
        userIdOverride: String? = nil
    ) async {
        // Every event passes through here — the app's, the lifecycle's, the AdServices answer. Before
        // the `defer` below, so an opted-out event is not offered to in-app either.
        guard !optedOut else { return }
        /*
         * Guarded so reporting a display cannot recurse into considering one.
         *
         * `openedSession` is the other half, and it is read at scope exit rather than here.
         * `session_start` is APPENDED below rather than logged, so it would not reach
         * `considerInApp` by itself — and then a message triggered on `session_start` could
         * never be drawn, and the sync `considerInApp` runs for it would not run either.
         *
         * One `Task` and not two, because two would not be ordered against each other and the
         * session has to be offered before the event that opened it.
         */
        var openedSession: [String: Any]?
        /*
         * The dimensions each event was stamped with, kept from the very dictionary `build`
         * appended — never a second read of `DeviceInfo`, which reads the network type fresh on every call, so
         * a second read could disagree with the stored row. A trigger's dimension row reads these.
         */
        var sessionDimensions: [String: Any]?
        var eventDimensions: [String: Any]?
        defer {
            let opened = openedSession
            let openedDimensions = sessionDimensions
            let stamped = eventDimensions
            let considerEvent = !Self.isInAppReport(eventName)
            if opened != nil || considerEvent {
                Task {
                    if let opened {
                        await self.considerInApp(
                            eventName: DefaultEvent.sessionStart, properties: opened, dimensions: openedDimensions
                        )
                    }
                    if considerEvent {
                        await self.considerInApp(eventName: eventName, properties: properties, dimensions: stamped)
                    }
                }
            }
        }
        guard writeKey != nil else {
            TreebarsLogger.log("Dropped event; Treebars.initialize has not been called")
            return
        }

        // Both boundaries go out before the event that revealed them, so the events
        // read in the order things happened: the old session closes, the new one
        // opens, and only then does the event that triggered all this land inside it.
        let advance = await advanceSession(countsAsEvent: true)
        var appended = advance.queued
        openedSession = advance.opened?.properties
        sessionDimensions = advance.opened?.dimensions

        let event = build(
            eventName: eventName,
            properties: properties,
            sessionId: advance.sessionId,
            userIdOverride: userIdOverride
        )
        await queue.append(event)
        appended.append(eventName)
        eventDimensions = Self.stampedDimensions(event)

        await announceQueued(appended)
    }

    /// What moving the session put on the queue, and the session it moved to.
    private struct SessionAdvance {
        let sessionId: String
        /// `session_end` for a session that had aged out, then `session_start`, as far as either was queued.
        var queued: [String] = []
        /// The `session_start` queued, with the dimensions it was stamped with, for in-app to be offered.
        var opened: (properties: [String: Any], dimensions: [String: Any])?
    }

    /**
     Moves the session to now and queues the boundaries that revealed, and it is the only place either is emitted.

     Two callers, and the second is why this is not inline in `enqueue`: every event, and `contextToken()`, which has
     to hand the server the session a purchase will happen in — so it moves the session exactly as the purchase's
     first event would, closing one that aged out, rather than naming a session the next event is about to end. A second
     copy of these lines would be two definitions of a session boundary, free to drift, on the one path where a drift
     files revenue under a session that no longer exists.
     */
    private func advanceSession(countsAsEvent: Bool) async -> SessionAdvance {
        let touch = await sessionManager.touch(countsAsEvent: countsAsEvent)
        var advance = SessionAdvance(sessionId: touch.sessionId)
        guard autoTrackSessions else { return advance }

        if let expired = touch.expired {
            await queue.append(
                build(
                    eventName: DefaultEvent.sessionEnd,
                    properties: ["duration_ms": expired.durationMs, "event_count": expired.eventCount],
                    sessionId: expired.id,
                    // The session's own last moment, not this one. Somebody who closed
                    // the app at nine and reopened at noon had a session that ended at
                    // nine.
                    timestamp: Date(timeIntervalSince1970: expired.endedAt),
                    detached: true
                )
            )
            advance.queued.append(DefaultEvent.sessionEnd)
        }

        if touch.isNew {
            let sessionProperties: [String: Any] = ["is_first_session": touch.isFirstSession]
            let sessionEvent = build(
                eventName: DefaultEvent.sessionStart,
                properties: sessionProperties,
                sessionId: touch.sessionId
            )
            await queue.append(sessionEvent)
            advance.queued.append(DefaultEvent.sessionStart)
            advance.opened = (sessionProperties, Self.stampedDimensions(sessionEvent))
        }
        return advance
    }

    /**
     Every event a call put on the queue, the session boundaries included — a journey can
     start on `session_start` as readily as on anything the app logs. After the appends, so
     the flush a listed one asks for finds it there.
     */
    private func announceQueued(_ names: [String]) async {
        for name in names { await uploader?.eventLogged(name) }

        if await queue.count >= Self.batchSize {
            await uploader?.flush()
        }
    }

    /// The dimensions an event was stamped with: the names an in-app trigger may read, taken from the
    /// dictionary `build` produced for it.
    static func stampedDimensions(_ event: [String: Any]) -> [String: Any] {
        event.filter { TreebarsConstants.inAppDimensions.contains($0.key) }
    }

    /// - Parameter detached: suppresses the current screen. Only `session_end` uses it:
    ///   that event is stamped into a session that closed before this process started, so
    ///   labelling it with a screen the user is looking at now would be a false statement
    ///   about where it happened.
    private func build(
        eventName: String,
        properties: [String: Any],
        sessionId: String,
        timestamp: Date = Date(),
        detached: Bool = false,
        userIdOverride: String? = nil
    ) -> [String: Any] {
        var event: [String: Any] = [
            "event_id": UUID().uuidString,
            "session_id": sessionId,
            "device_id": DeviceInfo.getDeviceId(),
            "event_name": eventName,
            "properties": properties,
            "timestamp": Iso8601.string(from: timestamp),
            "sdk_version": TreebarsConstants.sdkVersion,
            "sdk_name": sdkNameOverride ?? TreebarsConstants.sdkName,
        ]

        if let owner = userIdOverride ?? userId { event["user_id"] = owner }
        if !detached, let currentScreen { event["screen_name"] = currentScreen }
        // Includes platform_type. Cached after the first call, so this is a dictionary
        // copy per event rather than a fresh read of UIDevice and the bundle.
        DeviceInfo.dimensions().forEach { event[$0.key] = $0.value }

        return event
    }

    /**
     When the auto-flush timer is next due. Nil when it is not running.

     Recorded rather than derived: `Timer` exposes a `fireDate`, but reading it means holding
     the timer and knowing it is the right one, and the value has to survive the timer being
     replaced. Written when the timer is armed and again on each fire, so a caller reading it
     mid-upload gets the next one rather than one already in the past.
     */
    private var nextFlushAt: Date?

    /**
     What to call this SDK on the wire, when a wrapper is the thing an integrator installed.

     Nil means this SDK. The React Native bridge passes `treebars-react-native`, and it has
     to: with `platform_type` reporting the real OS, `sdk_name` is the only field that still
     answers "which SDK is this customer on" — and a bridge reporting `treebars-ios` would make
     every React Native device indistinguishable from a native one.
     */
    private var sdkNameOverride: String?

    /// Armed on the main queue, as the in-app poll is: `Timer.scheduledTimer` attaches to the current
    /// run loop, and `initialize` may be called from a thread that has none running.
    private func startAutoFlush(interval: TimeInterval) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushTimer?.invalidate()
            self.nextFlushAt = Date().addingTimeInterval(interval)
            self.flushTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.nextFlushAt = Date().addingTimeInterval(interval)
                Task { await self?.uploader?.flush() }
            }
        }
    }

    /**
     The app became active: the moment a trigger held for want of a screen can be answered. Registered
     whatever `autoTrackLifecycle` says, because it is in-app's and not the lifecycle events'. `didBecomeActive`
     rather than `willEnterForeground`, because "active" is exactly what `inAppSurfaceReady` asks, and a launch never
     sends the latter.
     */
    private func observeActivation() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.writeKey != nil else { return }
            Task { await self.replayUndrawnTriggers() }
        }
        // A queue kept from the last run can draw an HTML message on this launch's first event, before any sync.
        Task { await self.warmForQueuedHtml() }
        // The WebView kept ahead of an HTML message is the first thing to give back when memory is short.
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { InAppHtmlHost.cool() }
        }
        #endif
    }

    /// Watches the app move between foreground and background.
    ///
    /// `willEnterForeground` rather than `didBecomeActive` for `app_foreground`: the latter also
    /// fires when a pulled-down Control Centre or a dismissed app switcher hands control back,
    /// moments the user does not experience as returning to the app, and counting those would put
    /// an `app_foreground` behind every notification-centre glance.
    ///
    /// The background transition carries the flush, and that is the more important half:
    /// it is the last reliable moment to upload before the process may be suspended or
    /// killed.
    private func observeLifecycle() {
        #if canImport(UIKit)
        /*
         * The handoff gets another look every time the app becomes active, and the latch is what
         * makes that safe: once the install is decided the settle returns immediately.
         *
         * It needs the retry because a first launch is not one moment. The app is active, then
         * INACTIVE for as long as a system alert is up — the push prompt, most often, which a
         * person may take their time over — and iOS hands an inactive app no pasteboard, returning
         * nil while `hasStrings` still answers true. One look at launch therefore sees nothing on
         * exactly the launch that matters. `didBecomeActive` rather than `willEnterForeground`
         * here, and deliberately unlike `app_foreground` below: what this waits for is the alert
         * going away, which is precisely the "moment the user does not experience as returning"
         * that the event is right to ignore.
         */
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.writeKey != nil, self.deferredHandoff else { return }
            Task { await self.settleAcquisition() }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }

            let now = Date().timeIntervalSince1970
            let backgroundMs = Int(max(0, (now - self.backgroundedAt) * 1000))
            self.foregroundedAt = now

            // Skipped for the launch itself, which `app_open` already reported.
            guard self.backgroundedAt > 0 else { return }
            Task {
                await self.enqueue(
                    eventName: DefaultEvent.appForeground,
                    properties: ["background_ms": backgroundMs]
                )

                /*
                 * And re-state the context, because coming back is the one moment it can
                 * have changed without this process seeing it happen. Notification
                 * permission is the reason — it moves in the Settings app — but an OS
                 * upgrade and a locale change arrive the same way, and would otherwise wait
                 * for a cold launch or for the seven-day TTL to lapse.
                 *
                 * Nearly free: `reportDeviceContext` short-circuits on the stored hash, so
                 * a foreground where nothing moved costs a settings read and no network.
                 */
                await self.reportDeviceContext()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }

            let now = Date().timeIntervalSince1970
            let foregroundMs = Int(max(0, (now - self.foregroundedAt) * 1000))
            let hadForeground = self.foregroundedAt > 0
            self.backgroundedAt = now

            // Request a short window of background execution so an in-flight upload
            // is not cut off the instant the app is suspended.
            var taskId: UIBackgroundTaskIdentifier = .invalid
            taskId = UIApplication.shared.beginBackgroundTask(withName: "treebars-flush") {
                UIApplication.shared.endBackgroundTask(taskId)
                taskId = .invalid
            }

            Task {
                // Awaited before the flush, not fired alongside it: two independent tasks
                // race, and the flush routinely wins and uploads a batch that does not yet
                // contain the event that prompted it.
                if hadForeground {
                    await self.enqueue(
                        eventName: DefaultEvent.appBackground,
                        properties: ["foreground_ms": foregroundMs]
                    )
                }
                await self.uploader?.flush()
                if taskId != .invalid {
                    // On the main actor, which `UIApplication.shared` is isolated to.
                    await UIApplication.shared.endBackgroundTask(taskId)
                }
            }
        }
        #endif
    }
}
