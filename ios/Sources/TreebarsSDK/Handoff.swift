import Foundation
#if canImport(UIKit)
import UIKit
#endif

/*
 The iPhone's only deterministic route from one of our links to a fresh install.

 Android reads the Play Store's `referrer`, which survives the install and names the click. Apple
 hands a new install nothing at all — everything on an App Store URL is stripped — so the click id
 crosses with the PERSON: the link's page copies the link on their tap, and this reads it
 back on first launch. The same string arrives the other way too, when somebody who already
 installed taps the link again and iOS opens the app with its URL — `parseHandoff` takes either.

 Three rules, the same three as `Acquisition.swift`:

 - **Only for a new install.** The latch is set with `first_seen_at` and never on an existing one,
   so an app that adds this in a later version does not read a clipboard for its whole installed
   base on release day.
 - **Only with consent**, and only when the host app asked for the feature at all
   (`TreebarsConfig.deferredHandoff`, off by default). Reading a pasteboard the app did not write
   makes iOS show Apple's own "Allow Paste" alert, and spending somebody's prompt is the app's
   decision rather than this SDK's.
 - **Nothing here throws.** A refused clipboard, a missing framework, a value that is not ours: all
   are a nil, and a nil is an install attributed the way it would have been without this file.

 **And nothing is trusted.** A pasteboard is a text box every app on the device can write, so
 `parseHandoff` takes an http(s) URL carrying a click id of the shape this product mints and a path
 that passes `isDeepLinkPath` — the same rule as Android's, and as the server's.
 */

/// What the clipboard, or an opened link, turned out to be carrying.
struct HandoffClaim: Equatable {
    let clickId: String
    let deepLinkPath: String?
    /// The whole string, which is what the evidence event carries — the server parses it again.
    let raw: String
}

/// Our click ids: 22 characters, lower-case letters and digits.
func isClickId(_ value: String) -> Bool {
    value.count == 22 && value.allSatisfy { $0.isLowercase && $0.isASCII || $0.isNumber && $0.isASCII }
}

/**
 A path, never a URL — the same check as Android's `isDeepLinkPath` and the server's.

 The app routes on whatever it is handed, so a value beginning `https://` or a scheme of its own
 would turn a link's settings field into a way OUT of the app for everybody who installs from it.
 `//evil.example/x` goes with them: a leading `//` is scheme-relative wherever it is parsed. A
 backslash goes too, because several routers fold it to `/`.
 */
func isDeepLinkPath(_ value: String) -> Bool {
    if value.isEmpty || value.count > TreebarsConstants.maxDeepLinkPathLength { return false }
    if !value.hasPrefix("/") || value.hasPrefix("//") { return false }
    return !value.unicodeScalars.contains { scalar in
        scalar == "\\" || CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar.value < 0x20 || scalar.value == 0x7f
    }
}

/// The longest string worth parsing. Ours is far shorter; this bounds everything else.
private let maxHandoffLength = 2048

/// Read one back, or refuse it.
func parseHandoff(_ value: String?) -> HandoffClaim? {
    guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty, text.count <= maxHandoffLength,
          let components = URLComponents(string: text),
          let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
          let items = components.queryItems
    else { return nil }

    guard let clickId = items.first(where: { $0.name == TreebarsConstants.clickIdParam })?.value,
          isClickId(clickId)
    else { return nil }

    let path = items.first(where: { $0.name == TreebarsConstants.deepLinkParam })?.value
    return HandoffClaim(clickId: clickId, deepLinkPath: path.flatMap { isDeepLinkPath($0) ? $0 : nil }, raw: text)
}

/**
 The pasteboard, asked once and only where it can answer.

 `detectPatterns` first: it reports whether the pasteboard holds something that looks like a URL
 WITHOUT reading it, so an app whose user copied a phone number or a paragraph never shows the paste
 alert at all. Only a probable URL is worth the prompt — and even then the read can be refused,
 which is a nil like any other.
 */
/// What a look at the pasteboard came to. `notYet` is not `empty`, and the difference is the latch.
enum HandoffRead {
    case found(HandoffClaim)
    /// Looked, and there was nothing of ours. Most installs.
    case empty
    /// Could not look at all — the app is not foreground-active, so iOS serves no pasteboard.
    case notYet
}

func clipboardHandoff() async -> HandoffRead {
    #if canImport(UIKit)
    /*
     Active first, and this is the difference between a feature that works and one that silently
     does not. iOS serves the pasteboard only to a FOREGROUND-ACTIVE app: read it any earlier and
     the string comes back nil, no prompt is shown, and nothing reports a refusal — and
     `initialize` is earlier, since a host app calls it from `didFinishLaunching`. Read there, a
     handoff sitting on the clipboard would be reported as "nothing of ours on the pasteboard" and
     the install would come out unattributed.

     And "not active" is ordinary rather than rare on a first launch: an app is `.inactive` for as
     long as a system alert is up, which on a first launch is the push permission prompt somebody
     may take their time over. So this waits, and if it runs out of patience it says `notYet` —
     which keeps the latch, so the next launch looks again. `empty` would clear it for good.
     */
    guard await appIsActive() else {
        TreebarsLogger.log("Handoff: the app is not active yet; will look again next launch")
        return .notYet
    }
    if #available(iOS 14.0, *), await pasteboardPatterns() == .noWebURL {
        TreebarsLogger.log("Handoff: the pasteboard holds no link")
        return .empty
    }
    /*
     On the main actor, because that is where UIKit answers and where Apple presents its "Allow
     Paste" alert. A read off the main thread comes back nil while `hasStrings` and `hasURLs` still
     answer true — the app sees that SOMETHING is there and is handed nothing, which reads as
     "nobody came from a link" and is the quietest way this feature could fail.

     **A simulator answers nil here whatever the thread**, with the metadata still true and no
     prompt shown: its paste-permission UI does not engage. So this line can only be proven on a
     real device, which is why the `HandoffTests` fake the pasteboard and test the decisions
     around it instead.
     */
    guard let claim = parseHandoff(await MainActor.run(body: { UIPasteboard.general.string })) else {
        TreebarsLogger.log("Handoff: nothing of ours on the pasteboard")
        return .empty
    }
    TreebarsLogger.log("Handoff: read a click id off the pasteboard")
    return .found(claim)
    #else
    return .empty
    #endif
}

#if canImport(UIKit)
/**
 Whether the app is foreground-active, waiting a bounded moment for it if it is not.

 Bounded because this runs on a path that must not hold anything up, and because an app launched
 into the background — a push, a background fetch — may not become active on this launch at all.
 Giving up is free: the latch is only cleared once the evidence is sent, so the next launch asks
 again, and a handoff that waits one launch is a handoff, where one read too early is nothing.
 */
private func appIsActive(timeoutSeconds: Double = 30) async -> Bool {
    let center = NotificationCenter.default
    return await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            /*
             Subscribed BEFORE the state is checked, and then the state is checked — the plain
             ordering, because the other one loses the race. React Native starts JavaScript after
             the app has become active, so by the time `initialize` reaches here the notification
             has usually already fired: an observer added afterwards waits for a second activation
             that only a trip to the home screen and back would produce.
             */
            let activations = center.notifications(named: UIApplication.didBecomeActiveNotification)
            if await MainActor.run(body: { UIApplication.shared.applicationState == .active }) { return true }
            for await _ in activations { return true }
            return false
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            return false
        }
        let answer = await group.next() ?? false
        group.cancelAll()
        return answer
    }
}
#endif

#if canImport(UIKit)
/// What `detectPatterns` said — including that it could not say, which is not a "no".
enum PasteboardPatterns {
    case webURL
    case noWebURL
    /// It errored, or the OS has no answer. A simulator answers this way.
    case unknown
}

/**
 The completion-handler form wrapped once, because that is the only one every SDK here compiles.

 **`unknown` reads the pasteboard anyway, and that is the whole point of the three cases.** This
 check is an optimisation — it spares somebody Apple's paste alert when their clipboard holds a
 phone number — and treating its failure as "no link" turns an optimisation into a silent loss of
 the one deterministic answer iPhone has. On a simulator, where `detectPatterns` answers nothing
 at all, that reading would leave a handoff on the clipboard, the alert never shown, and the
 install unattributed with nothing anywhere saying why.
 */
@available(iOS 14.0, *)
private func pasteboardPatterns() async -> PasteboardPatterns {
    await withCheckedContinuation { continuation in
        UIPasteboard.general.detectPatterns(for: [.probableWebURL]) { result in
            switch result {
            case .success(let patterns): continuation.resume(returning: patterns.contains(.probableWebURL) ? .webURL : .noWebURL)
            case .failure: continuation.resume(returning: .unknown)
            }
        }
    }
}
#endif

/**
 The destination a link carried, held until the host app takes it — once, ever.

 The same shape as Android's `DeferredDeepLink`, for the same two reasons. Persisted rather than
 handed straight over, because the read finishes whenever the clipboard answers and the app
 registers its listener whenever it reaches that line of `didFinishLaunching`, and holding it in
 memory loses the link for whichever is slower. Delivered once and bounded by the install's own age,
 because without "once" every launch reopens a sale somebody bought weeks ago, and without the
 window an app that adds a listener in a later version throws its whole installed base into it.
 */
final class DeferredDeepLink {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Remember a path the handoff carried. Never overwrites one already waiting.
    func remember(_ path: String) {
        guard defaults.string(forKey: TreebarsConstants.keyDeferredDeepLink) == nil else { return }
        defaults.set(path, forKey: TreebarsConstants.keyDeferredDeepLink)
    }

    /// The path, if one is owed and still worth opening — and gone afterwards either way.
    func take(installedAtMs: Int64?, nowMs: Int64) -> String? {
        guard let path = defaults.string(forKey: TreebarsConstants.keyDeferredDeepLink) else { return nil }
        defaults.removeObject(forKey: TreebarsConstants.keyDeferredDeepLink)
        // An install with no first-seen moment cannot be inside any window, and cannot exist either:
        // the same write records both. Refusing rather than assuming is the cheap side of the pair.
        guard let installedAtMs else { return nil }
        let age = nowMs - installedAtMs
        if age < 0 || age > TreebarsConstants.deferredDeepLinkWindowMs { return nil }
        return isDeepLinkPath(path) ? path : nil
    }
}
