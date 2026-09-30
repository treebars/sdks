import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// A push's rich parts on iOS: its media and buttons, added in the app's Notification
/// Service Extension, and what its buttons do when pressed.
///
/// iOS always draws the alert itself — title, subtitle, badge, sound and interruption level arrive in `aps` and need
/// nothing from the app. What it cannot do alone is fetch an image, a GIF, a sound or a video to attach, or know the
/// buttons: a notification's buttons are its category's actions, and a category must be registered before the alert
/// shows. So the app adds a Notification Service Extension that calls `TreebarsNotificationService.enrich`, and the
/// channel's "draws them with the Treebars SDK" is turned on. The extension runs only for a `mutable-content` payload,
/// which the server sets whenever there is anything to fetch or register.
public enum TreebarsNotificationService {
    /// Attaches the push's media and registers its buttons' category, and returns the content to deliver. Call it from
    /// `didReceive(_:withContentHandler:)`; on any failure the original content goes out unchanged.
    public static func enrich(_ request: UNNotificationRequest) async -> UNNotificationContent {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else { return request.content }
        let info = content.userInfo

        if let url = mediaURL(info), let attachment = await attachment(from: url) {
            content.attachments = [attachment]
        }

        let buttons = PushParts.buttons(info)
        let coupon = PushParts.options(info)["coupon_code"] as? String
        if !content.categoryIdentifier.isEmpty, !buttons.isEmpty || !(coupon ?? "").isEmpty {
            var actions: [UNNotificationAction] = []
            for (index, button) in buttons.prefix(3).enumerated() {
                let type = (button["action"] as? [String: Any])?["type"] as? String ?? ""
                // Copying, recording and setting a trait need no screen; the rest bring the app forward.
                let foreground = !PushParts.backgroundActions.contains(type)
                actions.append(UNNotificationAction(identifier: "treebars.button.\(index)", title: button["label"] as? String ?? "", options: foreground ? [.foreground] : []))
            }
            if let coupon, !coupon.isEmpty {
                actions.append(UNNotificationAction(identifier: "treebars.coupon", title: "Copy \(coupon)", options: []))
            }
            // The dismiss action is custom so a swipe-away reaches the delegate and can be reported.
            let category = UNNotificationCategory(identifier: content.categoryIdentifier, actions: actions, intentIdentifiers: [], options: [.customDismissAction])
            let center = UNUserNotificationCenter.current()
            // Added to what the app already registered, never in place of it — replacing would take the app's own away.
            let existing = await center.notificationCategories()
            center.setNotificationCategories(existing.filter { $0.identifier != category.identifier }.union([category]))
        }
        return content
    }

    /// A carousel's first card, else the image, else the media. A notification shows one attachment; the rest of a
    /// carousel is a Content Extension's to draw, and without one the first card stands for it.
    private static func mediaURL(_ info: [AnyHashable: Any]) -> URL? {
        if let card = PushParts.cards(info).first, let image = card["image_url"] as? String { return URL(string: image) }
        if let image = info["image_url"] as? String, !image.isEmpty { return URL(string: image) }
        if let media = PushParts.object(info[TreebarsConstants.richPushMediaKey]), let url = media["url"] as? String { return URL(string: url) }
        return nil
    }

    /// Downloads a file into a place the notification may keep, named with the extension iOS reads its type from.
    private static func attachment(from url: URL) async -> UNNotificationAttachment? {
        do {
            let (location, response) = try await URLSession.shared.download(from: url)
            let suffix = url.pathExtension.isEmpty ? (response.suggestedFilename.map { ($0 as NSString).pathExtension } ?? "jpg") : url.pathExtension
            let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
            try FileManager.default.moveItem(at: location, to: target)
            return try UNNotificationAttachment(identifier: "treebars", url: target)
        } catch {
            return nil
        }
    }
}

/// Reading the SDK's keys off a push. Each arrives as a JSON string so both platforms parse one shape.
enum PushParts {
    static let backgroundActions: Set<String> = ["copy", "track_event", "set_attribute"]

    static func object(_ value: Any?) -> [String: Any]? {
        guard let text = value as? String, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func array(_ value: Any?) -> [[String: Any]] {
        guard let text = value as? String, let data = text.data(using: .utf8) else { return [] }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]) ?? []
    }

    static func buttons(_ info: [AnyHashable: Any]) -> [[String: Any]] { array(info[TreebarsConstants.richPushButtonsKey]) }
    static func cards(_ info: [AnyHashable: Any]) -> [[String: Any]] { array(info[TreebarsConstants.richPushCarouselKey]) }
    static func options(_ info: [AnyHashable: Any]) -> [String: Any] { object(info[TreebarsConstants.richPushOptionsKey]) ?? [:] }

    /// The action a response carries: a button's own, else a card's, else the push's deep link.
    static func action(_ info: [AnyHashable: Any], button: Int?) -> [String: Any]? {
        if let button {
            let all = buttons(info)
            return all.indices.contains(button) ? all[button]["action"] as? [String: Any] : nil
        }
        if let card = cards(info).first?["action"] as? [String: Any] { return card }
        if let link = info[TreebarsConstants.richPushDeepLinkKey] as? String, !link.isEmpty { return ["type": "deep_link", "url": link] }
        return nil
    }
}

extension Treebars {
    /// The app's answer to "open screen X" and to a `custom` action, which only it knows how to do.
    public typealias PushActionHandler = @MainActor (_ type: String, _ values: [String: String]) -> Void

    private static let handlerBox = PushHandlerBox()

    /// Where `navigate` and `custom` go. Without one, `navigate` does nothing beyond opening the app — and the action is
    /// held, so a handler set a moment later still receives the tap that opened the app: a React Native bridge, for
    /// one, registers its handler from JavaScript, after a cold tap has already been answered.
    public static func setPushActionHandler(_ handler: PushActionHandler?) {
        handlerBox.handler = handler
        guard let handler, let held = handlerBox.pending else { return }
        handlerBox.pending = nil
        let values = held.values
        Task { @MainActor in handler(held.type, values) }
    }

    /// The handler, or the one-slot hold when there is none yet.
    @MainActor
    private static func deliverAction(_ type: String, _ values: [String: String]) {
        if let handler = handlerBox.handler {
            handler(type, values)
        } else {
            handlerBox.pending = (type, values)
        }
    }

    private static let couponCopiedKey = "treebars.push.coupon_copied.v1"

    /// Whether this is the first copy of this push's coupon on this device, remembering it if so, so that copying one
    /// coupon several times counts as one `notification_opened`. Bounded to the last fifty pushes.
    static func firstCouponCopy(_ deliveryId: String, defaults: UserDefaults = .standard) -> Bool {
        var seen = defaults.stringArray(forKey: couponCopiedKey) ?? []
        if seen.contains(deliveryId) { return false }
        seen.append(deliveryId)
        defaults.set(Array(seen.suffix(50)), forKey: couponCopiedKey)
        return true
    }

    /// Asks for push permission. `provisional` asks for Apple's quiet trial — delivered to Notification Centre
    /// without a prompt, so the person decides from a real push whether to keep them. The answer is reported as
    /// `notification_permission_changed` straight away. True when pushes may now be shown, quietly or not.
    @discardableResult
    public static func requestPushPermission(provisional: Bool = false) async -> Bool {
        var options: UNAuthorizationOptions = [.alert, .badge, .sound]
        if provisional { options.insert(.provisional) }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: options)) ?? false
        reportPermissionNow()
        return granted
    }

    /// Everything a push's response means: the tap or button reported, a swipe-away reported, and the action
    /// performed. Call it from `userNotificationCenter(_:didReceive:withCompletionHandler:)` in place of
    /// `trackNotificationOpened` / `trackNotificationDismissed`, from any thread. Returns false for a push this SDK did
    /// not send.
    @discardableResult
    public static func handleNotificationResponse(_ response: UNNotificationResponse) -> Bool {
        let info = response.notification.request.content.userInfo
        guard let deliveryId = info[deliveryIdKey] as? String, !deliveryId.isEmpty else { return false }
        let identifier = response.actionIdentifier
        if identifier == UNNotificationDismissActionIdentifier {
            trackNotificationDismissed(userInfo: info)
            return true
        }
        if identifier == "treebars.coupon" {
            let code = PushParts.options(info)["coupon_code"] as? String ?? ""
            Task { @MainActor in copy(code) }
            if firstCouponCopy(deliveryId) { trackNotificationOpened(userInfo: info) }
            return true
        }
        var button: Int?
        if identifier.hasPrefix("treebars.button.") { button = Int(identifier.dropFirst("treebars.button.".count)) }

        var opened = info
        if let button, PushParts.buttons(info).indices.contains(button), let id = PushParts.buttons(info)[button]["id"] as? String {
            opened[TreebarsConstants.richPushButtonIdKey] = id
        }
        trackNotificationOpened(userInfo: opened)
        // Opening, sharing and the app's own handler are UI, so they happen on the main actor whatever called this.
        let action = PushParts.action(info, button: button).map(ActionBox.init)
        Task { @MainActor in perform(action?.value) }
        return true
    }

    @MainActor
    private static func perform(_ action: [String: Any]?) {
        guard let action, let type = action["type"] as? String else { return }
        let text = { (key: String) in action[key] as? String ?? "" }
        switch type {
        case "deep_link", "rich_landing":
            open(text("url"))
        case "call":
            open("tel:\(text("phone").filter { !$0.isWhitespace })")
        case "copy":
            copy(text("text"))
        case "share":
            share(text("text"))
        case "track_event":
            let properties = (action["properties"] as? [String: String]) ?? [:]
            if !text("event_name").isEmpty { log(text("event_name"), properties: properties) }
        case "set_attribute":
            setAttributeFromPush(key: text("key"), value: text("value"))
        case "navigate":
            var values = (action["params"] as? [String: String]) ?? [:]
            values["screen"] = text("screen")
            deliverAction(type, values)
        case "custom":
            deliverAction(type, (action["data"] as? [String: String]) ?? [:])
        default:
            break
        }
    }

    @MainActor
    private static func open(_ address: String) {
        #if canImport(UIKit)
        guard let url = URL(string: address) else { return }
        UIApplication.shared.open(url)
        #endif
    }

    @MainActor
    private static func copy(_ text: String) {
        #if canImport(UIKit)
        if !text.isEmpty { UIPasteboard.general.string = text }
        #endif
    }

    @MainActor
    private static func share(_ text: String) {
        #if canImport(UIKit)
        guard !text.isEmpty,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              var top = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        top.present(UIActivityViewController(activityItems: [text], applicationActivities: nil), animated: true)
        #endif
    }
}

/// A push's action handed to the main actor. JSON values are immutable once parsed, which is what makes this safe.
private struct ActionBox: @unchecked Sendable {
    let value: [String: Any]
}

/// Holds the app's handler. A class so a static `let` can hold something that changes.
private final class PushHandlerBox: @unchecked Sendable {
    var handler: Treebars.PushActionHandler?
    /// A `navigate` or `custom` that arrived before any handler; see `setPushActionHandler`.
    var pending: (type: String, values: [String: String])?
}
