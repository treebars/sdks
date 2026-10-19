import Foundation

/*
 App actions: a named action and a small JSON payload, fired from a tap — an element of an in-app message, a push or
 one of its buttons — which the app subscribes to by name with `Treebars.onAction`.

 Every Treebars SDK runs this same dispatcher, held to the shared cases in `app-action-scenarios.json`:
 - an action goes to every handler subscribed to its name and to every catch-all, in the order they subscribed;
 - one that nothing has subscribed to yet is held for a few seconds, at most a handful at a time, and handed to the first
   handler that subscribes for it — so the tap that opened the app reaches the screen that subscribes once it is built,
   and a React Native app, whose handlers subscribe from JavaScript, misses nothing;
 - once its fate is known it is recorded as `app_action` with `handled` true or false, the name and where it came from,
   and never the payload, which can carry a person's own ids. A preview's actions are handed over and never recorded.
 */

/// Where an action came from: `kind` is `in_app`, `push` or `card`; the campaign and the message, when there are.
public struct AppActionSource: Sendable, Equatable {
    public let kind: String
    public let campaignId: String?
    public let messageId: String?

    public init(kind: String, campaignId: String? = nil, messageId: String? = nil) {
        self.kind = kind
        self.campaignId = campaignId
        self.messageId = messageId
    }
}

/// What a handler receives: the action's `name` (`add_to_cart`, `cart.open`, or the built-in `navigate`), its `payload`
/// as JSON values — `{ screen, props }` for `navigate` — and its `source`.
public struct AppAction: @unchecked Sendable {
    public let name: String
    public let payload: [String: Any]
    public let source: AppActionSource

    public init(name: String, payload: [String: Any], source: AppActionSource) {
        self.name = name
        self.payload = payload
        self.source = source
    }
}

/// What `Treebars.onAction` returns: `cancel()` stops the handler being called. Cancelling twice does nothing.
public final class AppActionSubscription: @unchecked Sendable {
    private var stop: (() -> Void)?
    private let lock = NSLock()

    init(_ stop: @escaping () -> Void) {
        self.stop = stop
    }

    public func cancel() {
        lock.lock()
        let stopping = stop
        stop = nil
        lock.unlock()
        stopping?()
    }
}

/// An app's answer to an action, on the main actor.
public typealias AppActionHandler = @MainActor (AppAction) -> Void

/// The dispatcher. Main actor only; the clock is handed in so a test can run it.
@MainActor
final class AppActions {
    private final class Subscription {
        let name: String?
        let handler: AppActionHandler

        init(name: String?, handler: @escaping AppActionHandler) {
            self.name = name
            self.handler = handler
        }
    }

    private final class Held {
        let action: AppAction
        let record: Bool
        var timer: AnyObject?

        init(action: AppAction, record: Bool) {
            self.action = action
            self.record = record
        }
    }

    /// What an action may be called: lower-case letters, digits, dots and underscores, starting with a letter.
    nonisolated static func isName(_ name: String) -> Bool {
        name.range(of: TreebarsConstants.appActionNamePattern, options: .regularExpression) != nil
    }

    private let track: (String, [String: Any]) -> Void
    private let later: (TimeInterval, @escaping @MainActor () -> Void) -> AnyObject
    private let cancelLater: (AnyObject) -> Void
    private let log: (String) -> Void
    private var subscriptions: [Subscription] = []
    private var held: [Held] = []

    init(
        track: @escaping (String, [String: Any]) -> Void,
        later: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> AnyObject,
        cancel: @escaping (AnyObject) -> Void,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.track = track
        self.later = later
        cancelLater = cancel
        self.log = log
    }

    /// Subscribes to one action by name, or every action when `name` is nil, and hands over what is held for it.
    func on(_ name: String?, _ handler: @escaping AppActionHandler) -> AppActionSubscription {
        let subscription = Subscription(name: name, handler: handler)
        subscriptions.append(subscription)
        for entry in held where name == nil || entry.action.name == name {
            held.removeAll { $0 === entry }
            if let timer = entry.timer { cancelLater(timer) }
            deliver(entry.action, to: [subscription], record: entry.record)
        }
        return AppActionSubscription { [weak self] in
            let stop: @Sendable () -> Void = { MainActor.assumeIsolated { self?.subscriptions.removeAll { $0 === subscription } } }
            if Thread.isMainThread { stop() } else { DispatchQueue.main.async { stop() } }
        }
    }

    /// Hands an action to the handlers subscribed to it, or holds it until one subscribes.
    func fire(_ action: AppAction, record: Bool = true) {
        let handlers = subscriptions.filter { $0.name == nil || $0.name == action.name }
        if !handlers.isEmpty {
            deliver(action, to: handlers, record: record)
            return
        }
        let entry = Held(action: action, record: record)
        entry.timer = later(TreebarsConstants.appActionHold) { [weak self] in self?.letGo(entry) }
        held.append(entry)
        // More held than the hold keeps lets the oldest go: a burst of taps nothing listens to is not a queue to replay.
        while held.count > TreebarsConstants.appActionHoldMax, let oldest = held.first {
            if let timer = oldest.timer { cancelLater(timer) }
            letGo(oldest)
        }
    }

    /// Lets go of everything held, unrecorded: the person who tapped has signed out.
    func clear() {
        for entry in held { if let timer = entry.timer { cancelLater(timer) } }
        held.removeAll()
    }

    private func deliver(_ action: AppAction, to handlers: [Subscription], record: Bool) {
        // A Swift handler cannot throw here; one that traps takes the app with it, as any code of the app's would.
        for subscription in handlers { subscription.handler(action) }
        if record { self.record(action, handled: true) }
    }

    private func letGo(_ entry: Held) {
        guard held.contains(where: { $0 === entry }) else { return }
        held.removeAll { $0 === entry }
        if entry.record { record(entry.action, handled: false) }
    }

    private func record(_ action: AppAction, handled: Bool) {
        var properties: [String: Any] = [
            TreebarsConstants.appActionNameKey: action.name,
            TreebarsConstants.appActionHandledKey: handled,
            TreebarsConstants.appActionSourceKey: action.source.kind,
        ]
        if let campaign = action.source.campaignId, !campaign.isEmpty { properties[TreebarsConstants.campaignIdKey] = campaign }
        if let message = action.source.messageId, !message.isEmpty { properties[TreebarsConstants.deliveryIdKey] = message }
        track(TreebarsConstants.appActionEvent, properties)
    }
}
