import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Network)
import Network
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

final class DeviceInfo {
    /// Where an older build kept the id and secret, in `UserDefaults` — deleted on launch, never read.
    static let legacyIdentityKeys = ["treebars.device_id", "treebars.fetch_secret"]
    private static let contextHashKey = "treebars.device_context_hash"
    /// The last permission this device reported a CHANGE from. Its own key: the context
    /// hash says the context moved, never which part of it did.
    private static let permissionKey = "treebars.notification_permission"

    /// The lock under both mints, and the reason it exists.
    ///
    /// Minting is a read-modify-write: two callers that overlap both find nothing stored and
    /// both mint, and the loser of the write has already handed its value to something.
    /// The Android SDK holds the same lock (`@Synchronized`) for the same reason.
    ///
    /// A second device id would split one handset's history in two. A second secret is
    /// worse: it is the credential `/v1/in-app` and `/v1/notifications` are read with, so it
    /// has to be one value from the first read onwards, and two for one device cannot both
    /// be right.
    ///
    /// The window is real: `getFetchSecret` is read by the `device_context` report and by
    /// the in-app sync within milliseconds of each other on first launch, and the React
    /// Native bridge adds a third caller on a different thread.
    ///
    /// One lock for both, not one each: they are minted from the same two entry points and a
    /// second lock would only add an ordering to get wrong.
    private static let mintLock = NSLock()

    /// Where the device's id and secret live, outside every backup (`DeviceIdentityStore`).
    /// Replaceable so a test can point it at a directory of its own.
    static var identityStore: DeviceIdentityStore? = DeviceIdentityStore.standard()
    /// This process's answer, once the store has given one.
    private static var resolved: DeviceIdentity?
    /// What this process uses while the store cannot be read, until it can.
    private static var transient: DeviceIdentity?

    /**
     The device's id and the secret that proves it, one pair from one file outside every backup —
     never from `UserDefaults`, which iCloud and a computer restore onto another phone.

     Resolved under `mintLock`: the one on file, else a new pair, written before it is returned. A pair
     new to this install is a device the server has never heard from, so the context hash — kept in
     `UserDefaults`, and so perhaps restored from another phone — is forgotten and it reports itself.

     **A file that is there but cannot be read is not a missing one.** Before the first unlock since a
     restart the data protection key is not available, and a background launch then can see the file
     and not open it. Minting over it would split the device and lose its secret, so this process
     uses a pair of its own until the file can be read, and writes nothing.
     */
    private static func identity() -> DeviceIdentity {
        mintLock.lock()
        defer { mintLock.unlock() }

        if let resolved { return resolved }
        switch identityStore?.load() ?? .unreadable {
        case .found(let stored):
            resolved = stored
            return stored
        case .unreadable:
            if let transient { return transient }
            let pair = DeviceIdentity.mint()
            transient = pair
            return pair
        case .absent:
            let pair = DeviceIdentity.mint()
            if identityStore?.save(pair) != true {
                TreebarsLogger.warn("the device identity could not be written; this install will be a new device next launch")
            }
            UserDefaults.standard.removeObject(forKey: contextHashKey)
            resolved = pair
            return pair
        }
    }

    /**
     Takes a wrapper's hand-down into an empty store only — the id with its secret, or with a fresh
     one when the wrapper never had one (it never sent one, so nothing depends on it). A store that
     holds a pair, or cannot be read, keeps what it has.
     */
    static func adopt(id: String, secret: String?) {
        mintLock.lock()
        defer { mintLock.unlock() }

        guard resolved == nil, identityStore?.load() == .absent else { return }
        let pair = DeviceIdentity(id: id, secret: secret.flatMap { $0.isEmpty ? nil : $0 } ?? DeviceIdentity.mintSecret())
        if identityStore?.save(pair) == true { resolved = pair }
    }

    /**
     Erases the pair, for `wipeLocalData`: the next caller mints a new one — id and secret together,
     never a new secret under the old id, because the two belong together — and the context report
     is forgotten, so the new device reports itself.
     */
    static func forgetIdentity() {
        mintLock.lock()
        defer { mintLock.unlock() }
        identityStore?.erase()
        resolved = nil
        transient = nil
        UserDefaults.standard.removeObject(forKey: contextHashKey)
    }

    /// Forgets that this context was reported, so the next launch reports it — to a project that has never seen it (`WriteKeyStamp`).
    static func forgetReportedContext(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: contextHashKey)
    }

    /// Forgets this process's answer, so the next call reads the store again. Tests only.
    static func forgetResolvedIdentity() {
        mintLock.lock()
        defer { mintLock.unlock() }
        resolved = nil
        transient = nil
    }

    /// A stable pseudonymous device id. Public: it travels in every event.
    static func getDeviceId() -> String {
        identity().id
    }

    /// The secret this device's content reads, sign-in and push-token uploads are proved with.
    static func getFetchSecret() -> String {
        identity().secret
    }

    /// The hardware identifier, e.g. `iPhone15,3`.
    ///
    /// `UIDevice.current.model` returns "iPhone" or "iPad" for every device ever made,
    /// which is useless as a breakdown dimension. `hw.machine` is the actual model, and
    /// on the simulator it reports the host architecture instead, so the simulator's own
    /// environment variable takes precedence there.
    private static func hardwareModel() -> String? {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }

        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return nil }

        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &bytes, &size, nil, 0)
        let value = String(cString: bytes)
        return value.isEmpty ? nil : value
    }

    /// Which of Apple's two push hosts a token minted by this build belongs to, or nil
    /// when it cannot be determined.
    ///
    /// There is no API for this. A device token is opaque bytes with no environment marker,
    /// so a server holding one cannot tell — and a sandbox token sent to the production host
    /// comes back `BadDeviceToken`, which reads exactly like an uninstall. So the build
    /// reports the entitlement it was signed with, and the send path prefers it over the
    /// channel's single setting.
    ///
    /// `#if DEBUG` is the obvious shortcut and it is wrong: `DEBUG` describes how the code
    /// was compiled, `aps-environment` how the binary was signed, and nothing couples them —
    /// a Release build onto a development profile is a sandbox app that `DEBUG` calls
    /// production.
    ///
    /// The profile is a CMS envelope wrapping an XML plist. Its signature is deliberately
    /// not checked: it is a file Apple put in our own bundle, and a build that could tamper
    /// with it could as easily lie about the value. It is searched as BYTES, because the DER
    /// around the payload is not valid UTF-8 and a string decode of the whole file yields
    /// nil — a failure indistinguishable from the file being absent.
    ///
    /// No profile means production, and the inference is load-bearing: App Store and
    /// TestFlight strip `embedded.mobileprovision` when Apple re-signs, while development,
    /// ad-hoc and enterprise builds all embed one. A Simulator has neither a profile nor a
    /// token Apple can route to, so nil there costs nothing.
    ///
    /// Apple's word is `development`; ours is `sandbox`, matching the channel setting and
    /// the host chooser. Translating here keeps a recorded value comparable with a
    /// configured one.
    static let apsEnvironment: String? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else {
            #if targetEnvironment(simulator)
            return nil
            #else
            return "production"
            #endif
        }

        guard
            let envelope = try? Data(contentsOf: url),
            let opening = "<?xml".data(using: .utf8),
            let closing = "</plist>".data(using: .utf8),
            let start = envelope.range(of: opening),
            let end = envelope.range(of: closing, in: start.lowerBound ..< envelope.endIndex),
            let profile = try? PropertyListSerialization.propertyList(
                from: envelope[start.lowerBound ..< end.upperBound],
                options: [],
                format: nil
            ) as? [String: Any],
            let entitlements = profile["Entitlements"] as? [String: Any],
            let environment = entitlements["aps-environment"] as? String
        else {
            // No profile payload, or no push entitlement at all. Reporting an environment
            // for an app that cannot mint a token would be inventing one.
            return nil
        }

        return environment == "development" ? "sandbox" : "production"
    }()

    /**
     Reads a main-thread-only value from whatever thread the caller is on.

     `UIDevice.current` and `UIScreen.main` are main-thread-only, and every caller of the two
     functions below arrives on a detached `Task` — `reportDeviceContext` runs from three of
     them. Reading them there does not usually crash — these particular getters usually answer
     from a background thread — but "usually" is the whole problem: under the main-thread
     checker it is a hard error, and it is undefined behaviour whatever the checker says.

     The `isMainThread` guard is what makes `.sync` safe rather than a deadlock — calling it
     from the main queue onto the main queue is the classic way to hang an app, and the one
     place this helper could plausibly be reached from is a caller that is already there.
     */
    private static func onMain<T>(_ read: () -> T) -> T {
        if Thread.isMainThread { return read() }
        return DispatchQueue.main.sync(execute: read)
    }

    /// Computed once. A `static let` rather than a cached `var` because `enqueue` runs
    /// concurrently and Swift guarantees lazy static initialisation happens exactly once.
    ///
    /// Network type is deliberately *not* in here: it is the one dimension that changes
    /// during a process, and it is also unavailable until the path monitor's first
    /// callback lands, so caching it would pin every event to whatever was true at launch.
    private static let staticDimensions: [String: String] = {
        var values: [String: String] = [
            "platform_type": "ios",
            "locale": Locale.current.identifier,
            "timezone": TimeZone.current.identifier,
        ]

        values["device_manufacturer"] = "Apple"
        values["device_model"] = hardwareModel()

        #if canImport(UIKit)
        let device = onMain {
            (
                UIDevice.current.systemName,
                UIDevice.current.systemVersion,
                UIDevice.current.userInterfaceIdiom
            )
        }
        values["os_name"] = device.0
        values["os_version"] = device.1
        switch device.2 {
        case .pad: values["device_type"] = "tablet"
        case .phone: values["device_type"] = "phone"
        case .tv: values["device_type"] = "tv"
        case .mac: values["device_type"] = "desktop"
        default: break
        }
        #else
        values["os_name"] = "macOS"
        values["os_version"] = ProcessInfo.processInfo.operatingSystemVersionString
        values["device_type"] = "desktop"
        #endif

        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            values["app_version"] = version
        }
        if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            values["app_build"] = build
        }

        return values
    }()

    /**
     The app's name: its display name, else its bundle name, or nil when the bundle declares neither.

     As the bundle declares it and not as a localisation shows it, so one app reports one name
     whatever language the phone is set to.
     */
    static func appName(in info: [String: Any]? = Bundle.main.infoDictionary) -> String? {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            let name = (info?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !name.isEmpty { return name }
        }
        return nil
    }

    /// The low-cardinality dimensions carried on every event.
    ///
    /// Sent per event because a stored event is never rewritten: it has to record the
    /// context it happened under, or upgrading the OS would retroactively relabel a user's
    /// whole history.
    static func dimensions() -> [String: String] {
        var values = staticDimensions
        if let network = NetworkMonitor.shared.currentType() {
            values["network_type"] = network
        }
        return values
    }

    /// The full context: the dimensions plus everything worth knowing once but never
    /// worth a copy on every event. Anything here without a field of its own is kept with
    /// the device's attributes, so adding a key needs no change on the server.
    static func context() -> [String: Any] {
        var values: [String: Any] = dimensions()

        #if canImport(UIKit)
        let screen = onMain { (UIScreen.main.bounds, UIScreen.main.scale) }
        values["screen_width"] = Int(screen.0.width.rounded())
        values["screen_height"] = Int(screen.0.height.rounded())
        values["screen_scale"] = Double(screen.1)
        #endif

        // The application's own id. On the context and not in `staticDimensions`: it is a
        // fact about the build, so a copy on every event is the same string a million
        // times. It is kept with the device's attributes.
        if let bundleId = Bundle.main.bundleIdentifier {
            values["app_id"] = bundleId
        }

        // Whether the OS will draw this app's notifications. Absent until the first
        // settings callback has landed, which is not the same answer as `not_determined`.
        if let permission = cachedNotificationPermission {
            values["notification_permission"] = permission
        }

        #if targetEnvironment(simulator)
        values["is_emulator"] = true
        #else
        values["is_emulator"] = false
        #endif

        return values
    }

    /**
     What `device_context` says of this app's in-app messages, as `in_app_display`: `off` when nothing
     will be drawn — in-app is switched off (`Treebars.disableInApps()`) — `app` when the app
     registered its own renderer (`Treebars.setInAppRenderer`), and `sdk` when this SDK draws them,
     which is the default.

     The same three words in every Treebars SDK. Not part of `context()`: that is what the device
     says of itself, and this is what the app's code has said, so it is read from the two values a
     draw is decided by at the moment a report is built, and kept nowhere.
     */
    static func inAppDisplay(enabled: Bool, ownRenderer: Bool) -> String {
        if !enabled { return "off" }
        return ownRenderer ? "app" : "sdk"
    }

    /// A stable 32-bit FNV-1a over the sorted context.
    ///
    /// Not a cryptographic hash: it only has to change when the context does. FNV rather
    /// than CryptoKit because the same comparison runs in every SDK and no digest API is
    /// common to all of them, whereas this is identical everywhere by construction.
    static func hashContext(_ context: [String: Any]) -> String {
        let canonical = context.keys.sorted()
            .map { "\($0)=\(String(describing: context[$0] ?? ""))" }
            .joined(separator: " ")

        var hash: UInt32 = TreebarsConstants.fnvOffsetBasis
        for byte in Array(canonical.utf8) {
            hash ^= UInt32(byte)
            hash = hash &* TreebarsConstants.fnvPrime
        }
        return String(format: "%08x", hash)
    }

    /// Whether this context differs from the last reported one, recording it if so.
    ///
    /// False is the common case after the first launch, which is the point: the server
    /// hears a handful of these per install, not one per app open.
    ///
    /// True also when the last report has aged past the TTL. A hash alone would be a
    /// one-way promise: this device remembers having reported, but what it reported is kept
    /// on the server, where a project reset or a privacy erase can remove it, and nothing
    /// here could notice. A device the server no longer knows is one no broadcast reaches,
    /// so the report is repeated rather than trusted forever.
    ///
    /// Hash and timestamp are one value rather than two keys, so a write that only half
    /// lands cannot leave a hash that never expires — the failure the TTL exists to end.
    static func shouldReportContext(_ hash: String) -> Bool {
        guard let stored = UserDefaults.standard.string(forKey: contextHashKey) else { return true }
        return isStale(stored, hash)
    }

    /// Whether this device has reported its context before, whatever it said then.
    ///
    /// A device that has not is one nobody has heard from: its first report is what registers it, so
    /// that one is made at once, where every later one waits until the launch has settled.
    static func hasReportedContext() -> Bool {
        UserDefaults.standard.string(forKey: contextHashKey) != nil
    }

    /**
     Records that the report was made — separately, and after it was.

     Not part of `shouldReportContext`, so asking the question does not also answer it. Were
     the hash stored before the event existed, a `device_context` that then failed to enqueue
     would leave the device suppressed for the whole seven-day TTL, having never reported once,
     and nothing above could tell that from a device whose context genuinely had not changed —
     while a device the server does not know is unreachable by every broadcast.
     */
    static func rememberReportedContext(_ hash: String) {
        UserDefaults.standard.set("\(hash):\(Date().timeIntervalSince1970)", forKey: contextHashKey)
    }

    /// A week: one extra event per device per week, and a device list that repairs itself.
    private static let contextReportTTL: TimeInterval = TreebarsConstants.contextReportTtl

    // MARK: - Notification permission

    /// Written on whatever queue `UNUserNotificationCenter` calls back on, read from
    /// wherever an event is being built — different threads, so the pair is guarded rather
    /// than assumed. Not a `static let` like `apsEnvironment`: that one is settled at build
    /// time and this one moves in the Settings app.
    private static let permissionLock = NSLock()
    private static var storedPermission: String?

    static var cachedNotificationPermission: String? {
        permissionLock.lock()
        defer { permissionLock.unlock() }
        return storedPermission
    }

    /// Reads the OS notification permission, asynchronously, into the cache above.
    ///
    /// The reason any of this exists: a device can hold a live push token with
    /// notifications switched off, and every layer above reports success — APNs accepts
    /// the send, returns 200, and nothing is ever drawn. No provider signal distinguishes
    /// that from a delivered push, so the SDK is the only place the fact can come from.
    ///
    /// `getNotificationSettings` is completion-handler-only; there is no synchronous read.
    /// Hence the cache, refreshed at init and on every foreground — Settings is the only
    /// place this changes, and returning from it is what a foreground means.
    static func refreshNotificationPermission(_ completion: (() -> Void)? = nil) {
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status: String?
            switch settings.authorizationStatus {
            case .notDetermined: status = "not_determined"
            case .denied: status = "denied"
            case .authorized: status = "authorized"
            case .provisional: status = "provisional"
            case .ephemeral: status = "ephemeral"
            @unknown default: status = nil
            }

            // A status Apple adds later is reported as nothing rather than filed as one of
            // the five we know. An unrecognised value is a gap; a wrong one is a lie.
            if let status {
                permissionLock.lock()
                storedPermission = status
                permissionLock.unlock()
            }
            completion?()
        }
        #else
        completion?()
        #endif
    }

    /// The same read, awaited.
    ///
    /// Callers refresh immediately before building a context rather than from a lifecycle
    /// observer of their own: the value is only ever wanted at that moment, and tying it to
    /// the report is one fewer observer to keep in step with `reportDeviceContext`'s four
    /// call sites.
    static func refreshPermission() async {
        await withCheckedContinuation { continuation in
            refreshNotificationPermission { continuation.resume() }
        }
    }

    /// The transition to report, if there is one, and the bookkeeping that goes with it.
    ///
    /// **The first observation is never a change.** A device seeing its own permission for
    /// the first time records it and reports nothing: `device_context` already carries the
    /// state, and treating first sight as a transition would stamp one on every install.
    ///
    /// Recorded before the caller enqueues anything, which is the opposite of what
    /// `shouldReportContext` does, and deliberately. A lost context report leaves a device
    /// unknown to the server and unreachable by every broadcast, so it must be retried;
    /// a lost change event leaves one gap in a series. Double-counting an opt-out would be
    /// worse than missing one.
    static func pendingPermissionChange() -> (from: String, to: String)? {
        guard let current = cachedNotificationPermission else { return nil }

        let previous = UserDefaults.standard.string(forKey: permissionKey)
        guard previous != current else { return nil }

        UserDefaults.standard.set(current, forKey: permissionKey)
        guard let previous else { return nil }
        return (from: previous, to: current)
    }

    private static func isStale(_ stored: String, _ hash: String) -> Bool {
        // A record with no timestamp re-reports once, which is what refreshes it. Cheaper
        // than a migration, and the outcome is the same next launch.
        guard let separator = stored.lastIndex(of: ":") else { return true }

        let reportedAt = TimeInterval(stored[stored.index(after: separator)...]) ?? 0
        guard reportedAt > 0 else { return true }

        return String(stored[..<separator]) != hash
            || Date().timeIntervalSince1970 - reportedAt >= contextReportTTL
    }
}

/// Reports the current connection: its type, whether using it costs the person anything, and the
/// moment it comes back.
///
/// A passive read of the last observed path rather than a request-time query, because
/// `NWPathMonitor` only delivers a path asynchronously and blocking an event on it would
/// put a wait on the hot path for a single dimension. Before the first update lands this
/// reports nil, so an event says nothing rather than something wrong — and a network nobody has
/// described yet is taken as neither metered nor saving data.
///
/// One monitor for all of it: a second would be a second standing subscription to the same path.
final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()

    private let lock = NSLock()
    private var latest: String?
    /// Low Data Mode is on for the network in use.
    private var constrained = false
    /// The network in use is cellular or a personal hotspot.
    private var expensive = false
    /// Nil until the first path has been delivered.
    private var satisfied: Bool?
    private var regained: (@Sendable () -> Void)?
    #if canImport(Network)
    /// Held for the process lifetime. A monitor that goes out of scope is deallocated and
    /// silently stops delivering, which would leave network_type permanently nil.
    private let monitor = NWPathMonitor()
    #endif

    private init() {
        #if canImport(Network)
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let type: String?
            if path.status != .satisfied {
                type = "none"
            } else if path.usesInterfaceType(.wifi) {
                type = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                type = "cellular"
            } else if path.usesInterfaceType(.wiredEthernet) {
                type = "ethernet"
            } else {
                type = nil
            }

            let nowSatisfied = path.status == .satisfied
            self.lock.lock()
            let wasSatisfied = self.satisfied
            self.satisfied = nowSatisfied
            self.latest = type
            self.constrained = path.isConstrained
            self.expensive = path.isExpensive
            let regained = self.regained
            self.lock.unlock()
            // A path that was down and is up. The first path of a launch is not one: nothing was lost.
            if wasSatisfied == false, nowSatisfied { regained?() }
        }
        monitor.start(queue: DispatchQueue(label: "treebars.network-monitor"))
        #endif
    }

    func currentType() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// What the network in use costs: `constrained` in Low Data Mode, `metered` on cellular or a hotspot.
    func cost() -> (constrained: Bool, metered: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (constrained, expensive)
    }

    /// Called each time the network comes back after being away, on the monitor's own queue. One
    /// listener; nil removes it.
    func onRegained(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        regained = handler
        lock.unlock()
    }
}

extension FlushConditions {
    /// This device's own answer, now: Low Power Mode and the network in use.
    static func current() -> FlushConditions {
        let network = NetworkMonitor.shared.cost()
        return FlushConditions(
            constrained: ProcessInfo.processInfo.isLowPowerModeEnabled || network.constrained,
            metered: network.metered
        )
    }
}
