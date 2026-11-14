import Flutter
import TreebarsSDK
import UIKit

/// The iOS half of the Flutter bridge. Everything below it is the Swift Treebars SDK.
///
/// It calls `TreebarsBridge`, the native SDK's own JSON-in, JSON-out face, which is also what the
/// React Native bridge calls. So reading a config, a payload or a page is done once, in the native
/// SDK, for both wrappers, and this file only moves arguments and answers across the channel.
///
/// **Nothing here swallows.** A failure the native SDK reports arrives in Dart as an error with
/// its code (`bad_payload`, `bad_config`, `not_initialized`), never as an empty answer.
///
/// **Events go out on one stream**, as `{ name, data }` JSON, always on the main thread.
public final class TreebarsFlutterPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private static let methodChannel = "com.treebars.sdk/flutter"
    private static let eventChannel = "com.treebars.sdk/flutter/events"

    private var sink: FlutterEventSink?

    public static func register(with registrar: FlutterPluginRegistrar) {
        /*
         * Before the app finishes launching, which is when plugins are registered: the native SDK
         * stands in front of whatever notification delegate the app sets, so the tap that launched
         * the app reaches it. Dart starts far too late to do this.
         */
        TreebarsBridge.installPushTaps()

        let instance = TreebarsFlutterPlugin()
        let methods = FlutterMethodChannel(name: methodChannel, binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: methods)
        let events = FlutterEventChannel(name: eventChannel, binaryMessenger: registrar.messenger())
        events.setStreamHandler(instance)
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        TreebarsBridge.detach()
        TreebarsBridge.setDeferredDeepLinkSink(nil)
        sink = nil
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    // MARK: - Calls

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        func string(_ key: String) -> String? { args[key] as? String }
        func done(_ failure: TreebarsBridgeFailure?) {
            if let failure {
                result(FlutterError(code: failure.code, message: failure.message, details: nil))
            } else {
                result(nil)
            }
        }
        /// Refuses a call the native SDK would otherwise answer with nothing, quietly: an inbox
        /// read before `initialize` would come back empty, indistinguishable from a real answer.
        func started() -> Bool {
            if TreebarsBridge.isStarted { return true }
            result(FlutterError(code: "not_initialized", message: "Treebars: init() has not run, or it failed.", details: nil))
            return false
        }
        func missing(_ key: String) {
            result(FlutterError(code: "bad_payload", message: "Treebars: \(call.method) was called without \(key).", details: nil))
        }
        /// An answer from a completion the native SDK calls on a thread of its own.
        let answer: @Sendable (Any?) -> Void = { value in DispatchQueue.main.async { result(value) } }

        switch call.method {
        // Lifecycle
        case "initialize":
            guard let config = string("config") else { return missing("config") }
            /*
             * Before `start`, so the first values this launch is given cannot arrive ahead of the
             * listener that reports them.
             */
            TreebarsBridge.setConfigChangeSink { [weak self] in self?.emit(name: "configChange", data: NSNull()) }
            let failure = TreebarsBridge.start(
                configJson: config,
                uploadSink: { [weak self] json in self?.emit(name: "uploadLog", json: json) },
                notificationsSink: { [weak self] json in self?.emit(name: "notificationsChange", json: json) }
            )
            done(failure)
        case "reset":
            guard started() else { return }
            TreebarsBridge.reset(); result(nil)
        case "flush":
            guard started() else { return }
            TreebarsBridge.flush(); result(nil)
        case "optOut":
            TreebarsBridge.optOut(); result(nil)
        case "optIn":
            TreebarsBridge.optIn(); result(nil)
        case "isOptedOut":
            result(TreebarsBridge.isOptedOut())
        case "contextToken":
            TreebarsBridge.contextToken { token in answer(token) }
        case "wipeLocalData":
            guard started() else { return }
            TreebarsBridge.wipeLocalData(); result(nil)
        case "setAcquisitionConsent":
            TreebarsBridge.setAcquisitionConsent(args["granted"] as? Bool ?? false); result(nil)
        case "handleLink":
            guard let url = string("url") else { return missing("url") }
            TreebarsBridge.handleLink(url) { path in DispatchQueue.main.async { result(path) } }

        // Events
        case "track":
            guard started() else { return }
            guard let name = string("name") else { return missing("name") }
            done(TreebarsBridge.track(name, propertiesJson: string("properties") ?? "{}"))
        case "screen":
            guard started() else { return }
            guard let name = string("name") else { return missing("name") }
            done(TreebarsBridge.screen(name, propertiesJson: string("properties") ?? "{}"))
        case "identify":
            guard started() else { return }
            done(TreebarsBridge.identify(string("userId"), attributesJson: string("attributes") ?? "{}", signature: string("signature")))

        // Push
        case "registerPushToken":
            guard started() else { return }
            guard let token = string("token"), let provider = string("provider") else { return missing("token") }
            done(TreebarsBridge.registerPushToken(token, provider: provider))
        case "trackNotificationOpened":
            guard started() else { return }
            done(TreebarsBridge.trackNotificationOpened(string("payload") ?? "{}"))
        case "trackNotificationDismissed":
            guard started() else { return }
            done(TreebarsBridge.trackNotificationDismissed(string("payload") ?? "{}"))
        case "handleRemotePush":
            result(TreebarsBridge.handleRemotePush(string("payload") ?? "{}"))
        case "requestPushPermission":
            guard started() else { return }
            TreebarsBridge.requestPushPermission(args["provisional"] as? Bool ?? false) { granted in answer(granted) }
        case "setEventsSubscribed":
            done(TreebarsBridge.setEventsSubscribed(string("names") ?? "[]", sink: { [weak self] json in self?.send(json) }))
        case "subscribeAppAction":
            guard let id = (args["id"] as? NSNumber)?.intValue else { return missing("id") }
            TreebarsBridge.subscribeAppAction(id, name: string("name"), sink: { [weak self] json in self?.send(json) })
            result(nil)
        case "unsubscribeAppAction":
            guard let id = (args["id"] as? NSNumber)?.intValue else { return missing("id") }
            TreebarsBridge.unsubscribeAppAction(id); result(nil)

        // In-app: the native SDK draws every message itself.
        case "syncInAppMessages":
            guard started() else { return }
            TreebarsBridge.syncInAppMessages(); result(nil)
        case "setInAppContext":
            guard started() else { return }
            done(TreebarsBridge.setInAppContext(string("contexts") ?? "[]"))
        case "resetInAppContext":
            guard started() else { return }
            TreebarsBridge.resetInAppContext(); result(nil)
        case "showInApp":
            guard started() else { return }
            TreebarsBridge.showInApp(); result(nil)
        case "holdInApp":
            TreebarsBridge.holdInApp(); result(nil)
        case "releaseInApp":
            TreebarsBridge.releaseInApp(); result(nil)
        case "showNudge":
            guard started() else { return }
            TreebarsBridge.showNudge(string("position") ?? "any"); result(nil)
        case "getSelfHandledInApps":
            guard started() else { return }
            TreebarsBridge.getSelfHandledInApps { json in answer(json) }
        case "selfHandledShown":
            guard started() else { return }
            done(TreebarsBridge.selfHandledShown(string("deliveryId") ?? ""))
        case "selfHandledClicked":
            guard started() else { return }
            done(TreebarsBridge.selfHandledClicked(string("deliveryId") ?? "", buttonJson: string("button") ?? ""))
        case "selfHandledDismissed":
            guard started() else { return }
            done(TreebarsBridge.selfHandledDismissed(string("deliveryId") ?? ""))
        case "submitInAppForm":
            guard started() else { return }
            done(TreebarsBridge.submitInAppForm(string("deliveryId") ?? "", responsesJson: string("responses") ?? "{}"))
        case "inboxList":
            guard started() else { return }
            guard let json = TreebarsBridge.inboxList() else {
                return result(FlutterError(code: "bad_payload", message: "Treebars: the inbox could not be encoded.", details: nil))
            }
            result(json)
        case "inboxDismiss":
            guard started() else { return }
            TreebarsBridge.inboxDismiss(string("deliveryId") ?? ""); result(nil)
        case "inboxViewed":
            guard started() else { return }
            TreebarsBridge.inboxViewed(string("deliveryId") ?? ""); result(nil)
        case "inboxClicked":
            guard started() else { return }
            TreebarsBridge.inboxClicked(string("deliveryId") ?? "", destination: string("destination") ?? ""); result(nil)

        // The notification centre
        case "notificationsList":
            guard started() else { return }
            TreebarsBridge.notificationsList(string("options") ?? "{}") { json, failure in
                DispatchQueue.main.async {
                    if let failure {
                        result(FlutterError(code: failure.code, message: failure.message, details: nil))
                    } else {
                        result(json)
                    }
                }
            }
        case "notificationsTopics":
            guard started() else { return }
            TreebarsBridge.notificationsTopics { json, failure in
                DispatchQueue.main.async {
                    if let failure {
                        result(FlutterError(code: failure.code, message: failure.message, details: nil))
                    } else {
                        result(json)
                    }
                }
            }
        case "notificationsMarkRead":
            guard started() else { return }
            TreebarsBridge.notificationsMarkRead(string("groupId") ?? ""); result(nil)
        case "notificationsMarkOpened":
            guard started() else { return }
            TreebarsBridge.notificationsMarkOpened(string("groupId") ?? ""); result(nil)
        case "notificationsMarkAllRead":
            guard started() else { return }
            TreebarsBridge.notificationsMarkAllRead(string("topic")); result(nil)
        case "notificationsDismiss":
            guard started() else { return }
            TreebarsBridge.notificationsDismiss(string("groupId") ?? ""); result(nil)
        case "setNotificationsSubscribed":
            // The native watch is installed by `start` and stays; a page that changed while nobody looked is still current.
            guard started() else { return }
            result(nil)
        case "setDeferredDeepLinkSubscribed":
            if args["subscribed"] as? Bool == true {
                TreebarsBridge.setDeferredDeepLinkSink { [weak self] path in self?.emit(name: "deferredDeepLink", data: path) }
            } else {
                TreebarsBridge.setDeferredDeepLinkSink(nil)
            }
            result(nil)

        // Telemetry
        case "pendingCount":
            guard started() else { return }
            TreebarsBridge.pendingCount { count in answer(count) }
        case "msUntilNextFlush":
            result(TreebarsBridge.msUntilNextFlush())

        // Remote config: none needs `initialize`; the native SDK answers the fallback until it has started.
        case "configBoolean":
            result(TreebarsBridge.configBoolean(string("key") ?? "", fallback: args["fallback"] as? Bool ?? false))
        case "configString":
            result(TreebarsBridge.configString(string("key") ?? "", fallback: string("fallback") ?? ""))
        case "configNumber":
            result(TreebarsBridge.configNumber(string("key") ?? "", fallback: (args["fallback"] as? NSNumber)?.doubleValue ?? 0))
        case "configJson":
            result(TreebarsBridge.configJson(string("key") ?? ""))
        case "configValue":
            result(TreebarsBridge.configValue(string("key") ?? "", kind: string("kind") ?? ""))
        case "allConfig":
            result(TreebarsBridge.allConfig())
        case "activateConfig":
            result(TreebarsBridge.activateConfig())
        case "fetchConfig":
            TreebarsBridge.fetchConfig { arrived in answer(arrived) }
        case "configReady":
            TreebarsBridge.configReady((args["timeoutMs"] as? NSNumber)?.doubleValue ?? 0) { ready in answer(ready) }
        case "setConfigAttributes":
            done(TreebarsBridge.setConfigAttributes(string("attributes") ?? "{}"))
        case "setConfigOverride":
            done(TreebarsBridge.setConfigOverride(string("key") ?? "", valueJson: string("value")))

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Events

    /// An event the native SDK already wrapped as `{ name, data }`.
    private func send(_ json: String) {
        DispatchQueue.main.async { [weak self] in self?.sink?(json) }
    }

    /// Wraps a JSON payload as `{ name, data }` without decoding and re-encoding it.
    private func emit(name: String, json: String) {
        send("{\"name\":\"\(name)\",\"data\":\(json)}")
    }

    private func emit(name: String, data: Any) {
        guard let encoded = try? JSONSerialization.data(withJSONObject: ["name": name, "data": data]),
              let text = String(data: encoded, encoding: .utf8) else { return }
        send(text)
    }
}
