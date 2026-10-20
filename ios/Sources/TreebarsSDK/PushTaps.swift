import Foundation
import ObjectiveC.runtime
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// A tapped Treebars push, as the app receives it from `Treebars.onPushOpened`.
///
/// A push's link (`yourapp://orders/42`, or an https address your app opens) is here for the app to route the same way
/// it routes any link it is opened with, so a tapped push lands on the same screen a tapped link does — whether the app
/// was in front, in the background, or not running at all. A screen or an app action the push names reaches `onAction`,
/// as before; this says the push was opened, and which.
public struct PushOpen: Sendable, Equatable {
    /// The link the push opens, exactly as it was written; nil for a push that only opens the app or runs an action.
    public let link: String?
    /// The pressed button's id, or nil for a tap on the notification itself.
    public let buttonId: String?
    public let deliveryId: String?
    public let campaignId: String?
    /// A test sent from the dashboard: it acts like any push, and is never counted as opened.
    public let isTest: Bool
    /// The push's own data — the keys its author added — without the SDK's own.
    public let data: [String: String]

    public init(link: String?, buttonId: String? = nil, deliveryId: String? = nil, campaignId: String? = nil, isTest: Bool = false, data: [String: String] = [:]) {
        self.link = link
        self.buttonId = buttonId
        self.deliveryId = deliveryId
        self.campaignId = campaignId
        self.isTest = isTest
        self.data = data
    }

    /// What the bridges hand across as JSON.
    var json: [String: Any] {
        ["link": link ?? NSNull(), "button_id": buttonId ?? NSNull(), "delivery_id": deliveryId ?? NSNull(), "campaign_id": campaignId ?? NSNull(), "is_test": isTest, "data": data]
    }
}

extension Treebars {
    public typealias PushOpenHandler = @MainActor (PushOpen) -> Void

    /// Where every tapped Treebars push goes, in every state of the app.
    ///
    /// A push that opened the app from not running is held until a handler is set, so a handler set after the first
    /// screen is up — or from JavaScript — still receives it. With a handler, the SDK does not open the push's link
    /// itself: the handler routes it. Without one, the SDK opens the link with the system, as an app that never set a
    /// handler expects; a tap that launched the app waits a few seconds after `initialize` for a handler before that.
    /// Passing nil removes the handler.
    public static func onPushOpened(_ handler: PushOpenHandler?) {
        PushOpens.shared.setHandler(handler)
    }

    /// Whether this SDK may install itself in front of the app's notification delegate. On unless the app's
    /// Info.plist sets `TreebarsHandlesPushTaps` to NO, for an app that forwards every response to
    /// `handleNotificationResponse` itself.
    static var handlesPushTaps: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "TreebarsHandlesPushTaps") as? Bool) ?? true
    }

    /// Whether a Treebars push arriving while the app is in front is shown as a banner. On unless the app's
    /// Info.plist sets `TreebarsShowsPushInForeground` to NO; other pushes are left to the app's own delegate.
    static var showsPushInForeground: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "TreebarsShowsPushInForeground") as? Bool) ?? true
    }

    /// Puts the SDK in front of whatever notification delegate the app — or a library it uses — sets, now and later,
    /// so a tap on a Treebars push reaches the SDK in every state with nothing for the app to forward. Every other
    /// notification passes through to that delegate unchanged. Called by `initialize`; call it earlier, from
    /// `application(_:didFinishLaunchingWithOptions:)` before `initialize`, if the app initialises late — a tap
    /// that launched the app is only delivered to a delegate set before launching finishes. Safe to call twice.
    public static func installPushTaps() {
        PushTaps.install()
    }

    /// Whether this payload is one this SDK sent: a delivery's own, or a test from the dashboard.
    static func isTreebarsPush(_ info: [AnyHashable: Any]) -> Bool {
        if let delivery = info[deliveryIdKey] as? String, !delivery.isEmpty { return true }
        return (info[TreebarsConstants.richPushTestKey] as? String) == "1"
    }
}

/// The app's handler and the tap held for it. Main-actor work only, reached from anywhere.
final class PushOpens: @unchecked Sendable {
    static let shared = PushOpens()

    /// How long a tap that launched the app waits, after `initialize`, for a handler before the SDK opens its link.
    /// Replaceable for a test, which should not wait eight seconds.
    nonisolated(unsafe) static var launchWaitSeconds: TimeInterval = 8

    /// How a link is opened when no handler routes it: the system. Replaceable for a test, which has no app to open.
    @MainActor static var openLink: (String) -> Void = { Treebars.openURL($0) }

    private let lock = NSLock()
    private var handler: Treebars.PushOpenHandler?
    private var held: PushOpen?
    private var started = false
    /// True until the launch wait after `initialize` is over. An app initialises the SDK early and subscribes once its
    /// first screen is up — after a splash screen, a sign-in check — and the tap that launched it arrives in between, so
    /// a tap with no handler is held for all of that, not only until `initialize`.
    private var holding = true
    /// Which run a launch wait belongs to: `reset` starts another, and a wait left over from the last one ends nothing.
    private var run = 0

    func setHandler(_ handler: Treebars.PushOpenHandler?) {
        lock.lock()
        self.handler = handler
        let pending = handler == nil ? nil : held
        if handler != nil { held = nil }
        lock.unlock()
        guard let handler, let pending else { return }
        Task { @MainActor in handler(pending) }
    }

    /// A tap, resolved: to the handler; else held while the app is still starting; else its link opened by the system.
    @MainActor
    func deliver(_ open: PushOpen) {
        lock.lock()
        let current = handler
        let waiting = current == nil && holding
        if waiting { held = open }
        lock.unlock()
        if let current { current(open); return }
        if waiting { return }
        if let link = open.link { Self.openLink(link) }
    }

    /// `initialize` ran: a tap that launched the app gets a little longer for a handler, then its link is opened.
    func start() {
        lock.lock()
        let first = !started
        started = true
        let thisRun = run
        lock.unlock()
        guard first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchWaitSeconds) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.run == thisRun else {
                self.lock.unlock()
                return
            }
            self.holding = false
            let unclaimed = self.handler == nil ? self.held : nil
            if unclaimed != nil { self.held = nil }
            self.lock.unlock()
            if let link = unclaimed?.link { Task { @MainActor in Self.openLink(link) } }
        }
    }

    /// For tests: back to a fresh process.
    func reset() {
        lock.lock()
        handler = nil
        held = nil
        started = false
        holding = true
        run += 1
        lock.unlock()
    }
}

/// The delegates the SDK stands in front of.
///
/// Each delegate set on the notification centre gets its own stand-in, which handles a Treebars push and passes
/// everything else to the delegate behind it. One stand-in per delegate, not one for all, because notification
/// libraries chain: one reads the delegate already set, keeps it as its "original", and sets itself — and a single
/// shared stand-in would then be its own original, forwarding in a circle and dropping the app's delegate out.
enum PushTaps {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed = false
    /// The centre holds its delegate weakly, so the stand-ins are kept here. Bounded: a delegate set over and over
    /// leaves only its latest stand-ins.
    nonisolated(unsafe) private static var standIns: [PushTapsStandIn] = []

    /// For a wrapper loaded with the app, before `didFinishLaunching`: the setter is replaced now, which touches no
    /// notification centre, and the delegate already set is put behind a stand-in once launching finishes — before
    /// iOS hands over the response that launched the app.
    static func prepare() {
        guard Treebars.handlesPushTaps else { return }
        replaceSetter()
        #if canImport(UIKit)
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: UIApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            install()
            if let token { NotificationCenter.default.removeObserver(token) }
        }
        #endif
    }

    static func install() {
        guard Treebars.handlesPushTaps else { return }
        replaceSetter()
        SilentPushes.install()
        // Whatever is set already — the app's own delegate, set before this ran — goes behind a stand-in now.
        let center = UNUserNotificationCenter.current()
        if !(center.delegate is PushTapsStandIn) {
            center.delegate = center.delegate
        }
    }

    private static func replaceSetter() {
        lock.lock()
        if installed { lock.unlock(); return }
        installed = true
        lock.unlock()

        let selector = #selector(setter: UNUserNotificationCenter.delegate)
        guard let method = class_getInstanceMethod(UNUserNotificationCenter.self, selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Setter.self)
        let replacement: @convention(block) (AnyObject, AnyObject?) -> Void = { target, delegate in
            original(target, selector, standIn(for: delegate))
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    /// The stand-in for a delegate: the delegate itself when it is one, else a new one in front of it.
    private static func standIn(for delegate: AnyObject?) -> AnyObject {
        if let delegate = delegate as? PushTapsStandIn { return delegate }
        let made = PushTapsStandIn(next: delegate as? UNUserNotificationCenterDelegate)
        lock.lock()
        standIns.append(made)
        if standIns.count > 8 { standIns.removeFirst(standIns.count - 8) }
        lock.unlock()
        return made
    }
}

/// The silent push that asks the SDK to fetch its in-app messages now — sent with an in-app test, and with a message to
/// show as soon as it arrives — answered in the app delegate's `didReceiveRemoteNotification`, which the SDK puts its
/// own answer in front of. Without it the push reached only an app that forwarded it, and in a React Native app nothing
/// does: a notification library hands on only the pushes it sent itself, so a test waited for the next launch.
///
/// Every other silent push goes on to the implementation the app or a library already has, unchanged. One class is
/// changed once; a delegate set later is not the SDK's to follow.
enum SilentPushes {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var changed: Set<ObjectIdentifier> = []

    static func install() {
        #if canImport(UIKit)
        guard Thread.isMainThread else {
            DispatchQueue.main.async { install() }
            return
        }
        guard let delegate = UIApplication.shared.delegate, let type = object_getClass(delegate) else { return }
        install(on: type)
        #endif
    }

    #if canImport(UIKit)
    /// Answers the sync push on this class — the app delegate's, or a test's own.
    static func install(on type: AnyClass) {
        lock.lock()
        let first = changed.insert(ObjectIdentifier(type)).inserted
        lock.unlock()
        guard first else { return }

        let selector = #selector(UIApplicationDelegate.application(_:didReceiveRemoteNotification:fetchCompletionHandler:))
        typealias Completion = @convention(block) (UIBackgroundFetchResult) -> Void
        typealias Implementation = @convention(c) (AnyObject, Selector, UIApplication, NSDictionary, Completion) -> Void
        // What answered before — the class's own, or one it inherits — read before anything is added.
        let existing = class_getInstanceMethod(type, selector)
        let previous = existing.map { unsafeBitCast(method_getImplementation($0), to: Implementation.self) }
        let answer: @convention(block) (AnyObject, UIApplication, NSDictionary, @escaping Completion) -> Void = { target, application, info, completion in
            if Treebars.handleRemoteNotification(userInfo: info as? [AnyHashable: Any] ?? [:]) {
                completion(.newData)
                return
            }
            if let previous {
                previous(target, selector, application, info, completion)
            } else {
                completion(.noData)
            }
        }
        let implementation = imp_implementationWithBlock(answer)
        // Added to this class when it only inherits the method, so the superclass every other class shares is untouched.
        if !class_addMethod(type, selector, implementation, "v@:@@@?"), let existing {
            method_setImplementation(existing, implementation)
        }
    }
    #endif
}

/// One delegate's stand-in. Answers for a Treebars push; forwards the rest, unchanged, to the delegate behind it.
final class PushTapsStandIn: NSObject, UNUserNotificationCenterDelegate {
    private weak var next: UNUserNotificationCenterDelegate?

    init(next: UNUserNotificationCenterDelegate?) {
        self.next = next
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if Treebars.isTreebarsPush(notification.request.content.userInfo), Treebars.showsPushInForeground {
            completionHandler([.banner, .list, .sound, .badge])
            return
        }
        if let next, next.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))) {
            next.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler)
        } else {
            completionHandler([])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        // A Treebars push is the SDK's: answered here, and not passed on, so it is opened once.
        if Treebars.handleNotificationResponse(response) {
            completionHandler()
            return
        }
        if let next, next.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))) {
            next.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler)
        } else {
            completionHandler()
        }
    }

    // Anything else the delegate behind answers reaches it — `openSettingsFor`, which iOS asks about before it shows the
    // app's notification settings link, and any method a later iOS adds — and nothing it does not answer is claimed.
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (next?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        next?.responds(to: selector) == true ? next : nil
    }
}
