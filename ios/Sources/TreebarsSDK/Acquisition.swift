import Foundation
#if canImport(AdServices)
import AdServices
#endif

/*
 How this install arrived, as Apple tells it.

 Nothing a tracker link appends to an App Store URL survives the install, so on iPhone the one
 deterministic answer is Apple's own, and only for Apple Ads: the AdServices framework mints a
 token on the device, and Apple's attribution endpoint trades it for the campaign that led here.
 This file makes that trade once per install and forwards Apple's answer as
 `apple_ads_attribution`, with Apple's keys verbatim. It does not interpret the answer — that is
 the server's job, in one place — and it never presents a prompt: AdServices needs no tracking
 permission, and whatever consent the host app asks for, it asks for itself.

 The same three rules as Android's `Acquisition.kt`: only for a new install (the latch is set with `first_seen_at`, never on an existing one), only
 with consent (off by default, and waiting costs nothing), and nothing on this path may throw.
 */

/// What Apple said, in the three shapes the latch acts on.
enum AdServicesAnswer {
    case found([String: Any])
    /// It never will: no AdServices on this OS, or a token Apple calls malformed.
    case never
    /// Not this time. The latch stays and the next launch mints a fresh token.
    case notNow
}

/// Minting a token, separated so tests can hand one over without the framework.
enum AttributionTokenResult {
    case token(String)
    case unsupported
    case failed
}

/// The device half: `AAAttribution.attributionToken()`, where the OS has it.
func deviceAttributionToken() -> AttributionTokenResult {
    #if canImport(AdServices)
    if #available(iOS 14.3, macOS 11.1, *) {
        do {
            return .token(try AAAttribution.attributionToken())
        } catch {
            /*
             The one error a relaunch will not change is `platformNotSupported`. Network and
             internal errors are exactly what the next launch's fresh token is for.
             */
            if let attributionError = error as? AAAttributionError, attributionError.code == .platformNotSupported {
                return .unsupported
            }
            return .failed
        }
    }
    #endif
    return .unsupported
}

/**
 Apple's side of the trade, and deliberately not `BackendClient`.

 Both cores' clients are bound to the ingest origin and stamp `X-Treebars-Key` on every request,
 so sending a third party's host through one would hand Apple a customer's write key. This is its
 own request on its own session, carrying the token and nothing of ours.
 */
struct AppleAttributionEndpoint {
    static let url = URL(string: "https://api-adservices.apple.com/api/v1/")!

    var session: URLSession = .shared

    /// The status and body, or nil when no response arrived at all.
    func post(token: String) async -> (status: Int, body: Data)? {
        var request = URLRequest(url: Self.url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(token.utf8)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return nil }
        return (http.statusCode, data)
    }
}

/**
 The latch and its decision: mint, trade, and what to do with Apple's answer.

 An actor, because two callers can arrive together — `initialize` settling on the way up, the host
 app granting consent a moment later, and `didBecomeActive` every time a system alert is dismissed.

 **Being an actor is not by itself enough.** An actor serialises entry, not a whole `async`
 function: every `await` releases it, and this one suspends waiting for the app to be
 foreground-active and again on Apple's token. A second caller would walk past `guard pending`
 during that gap, because the latch is cleared only after the send. The `settling` flag below is
 what actually makes it once-only.
 */
actor AcquisitionCapture {
    private let defaults: UserDefaults
    private let mintToken: () -> AttributionTokenResult
    private let post: (String) async -> (status: Int, body: Data)?
    private let sleep: (Int64) async -> Void
    private let random: () -> Double
    private let send: ([String: Any]) async -> Void
    private let handoff: () async -> HandoffRead
    private let carried: (String) -> Void

    init(
        defaults: UserDefaults = .standard,
        mintToken: @escaping () -> AttributionTokenResult = deviceAttributionToken,
        post: @escaping (String) async -> (status: Int, body: Data)? = { await AppleAttributionEndpoint().post(token: $0) },
        sleep: @escaping (Int64) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0)) * 1_000_000) },
        random: @escaping () -> Double = { Double.random(in: 0..<1) },
        /**
         Where the person carried the click id, when the host app asked for the feature — the
         clipboard, or a link that opened the app. Nil by default, which is an app that did not.
         */
        handoff: @escaping () async -> HandoffRead = { .empty },
        /**
         Called with the destination the handoff carried, BEFORE the event is queued. Before, for
         Android's reason: this is the half the person is waiting on, and a `send` that threw must
         not decide whether they land on the right screen.
         */
        carried: @escaping (String) -> Void = { _ in },
        send: @escaping ([String: Any]) async -> Void
    ) {
        self.defaults = defaults
        self.mintToken = mintToken
        self.post = post
        self.sleep = sleep
        self.random = random
        self.handoff = handoff
        self.carried = carried
        self.send = send
    }

    var pending: Bool { defaults.bool(forKey: TreebarsConstants.keyAcquisitionPending) }

    /**
     Whether a settle is already running, which the persisted latch cannot tell us.

     **An actor does not serialise across `await`, and that is the whole reason this exists.** The
     latch is cleared only once the event has been SENT, and the path to sending suspends twice —
     the pasteboard read waits for the app to be foreground-active, and Apple's token round-trips.
     At every suspension the actor is released, so without this a second caller would walk
     straight past `guard pending` while the first is still waiting, and both would send.

     Two callers close together are normal: `didBecomeActive` fires on launch and again when a
     system alert such as the local-network permission is dismissed, each arming its own `Task` —
     which is correct and necessary, because a first launch is not one moment. This flag is what
     keeps that to one event.
     */
    private var settling = false

    /// True when it queued an event, so the caller knows a flush has something to carry.
    func settle(consented: Bool) async -> Bool {
        guard consented, pending, !settling else { return false }
        // Set before the first `await`, so the second caller sees it however soon it arrives.
        settling = true
        defer { settling = false }

        /*
         The handoff first, and on the same event as Apple's answer rather than one of its own.

         One event carries both pieces of evidence, so the server weighs them together — Apple's
         "not Apple Ads" beside the link that actually earned the install — rather than seeing
         them one at a time. So this waits for both and sends one thing.

         The destination is handed to the app BEFORE the event is queued, because that is what the
         person is waiting on. It is handed over even when Apple's side says `notNow` and nothing
         is sent this launch: the screen they were promised does not depend on a token Apple has
         not minted yet.
         */
        let read = await handoff()
        if case .notYet = read {
            /*
             Not "there was nothing" — we could not look. The latch stays set and the next launch
             asks again, which is exactly what a busy Play Store gets on the other platform. Losing
             a handoff here would lose the only deterministic answer this install has.
             */
            TreebarsLogger.log("Acquisition: the handoff could not be read yet; leaving the install owed")
            return false
        }
        let claim: HandoffClaim? = { if case .found(let value) = read { return value } else { return nil } }()
        if let path = claim?.deepLinkPath { carried(path) }

        switch await answer() {
        case .found(var properties):
            if let claim { properties[TreebarsConstants.handoffProperty] = claim.raw }
            /*
             Queued before the latch is cleared, so a process killed between the two asks again
             on the next launch rather than never — a duplicate can be recognised, where a loss is
             something nothing could recover.
             */
            await send(properties)
            defaults.removeObject(forKey: TreebarsConstants.keyAcquisitionPending)
            TreebarsLogger.log(claim == nil ? "Apple Ads attribution sent" : "Apple Ads attribution sent, with the handoff")
            return true
        case .never:
            /*
             Apple will never answer on this device — but the handoff still can, and it is the
             better evidence: it names the LINK. So it goes on its own, with `attribution: false`,
             the same shape Apple answers with when it did not attribute an install.
             */
            defaults.removeObject(forKey: TreebarsConstants.keyAcquisitionPending)
            if let claim {
                await send(["attribution": false, TreebarsConstants.handoffProperty: claim.raw])
                TreebarsLogger.log("No Apple Ads attribution on this device; sent the handoff alone")
                return true
            }
            TreebarsLogger.log("No Apple Ads attribution on this device; not asking again")
            return false
        case .notNow:
            TreebarsLogger.log("Apple Ads attribution not available yet; will ask next launch")
            return false
        }
    }

    private func answer() async -> AdServicesAnswer {
        let token: String
        switch mintToken() {
        case .token(let minted): token = minted
        case .unsupported: return .never
        case .failed: return .notNow
        }

        /*
         Apple answers 404 for a while after a token is minted, and giving up at the first one
         would lose every install whose person opens the app straight away — which is most of
         them. The waits are the uploader's own `jitterMs`, called rather than re-derived, so
         there is one backoff formula in this core; only the attempt count is Apple-specific.
         */
        for attempt in 0..<TreebarsConstants.adServicesRetryAttempts {
            if attempt > 0 { await sleep(jitterMs(attempt: attempt - 1, random: random())) }

            guard let (status, body) = await post(token) else { continue }
            switch status {
            case 200:
                guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                    return .notNow
                }
                return .found(object)
            case 400:
                // Malformed, by Apple's word. A fresh token next launch is the same token from the
                // same framework, so asking again would only repeat the refusal forever.
                return .never
            default:
                // 404 is "not yet"; a 5xx is Apple's to recover from. Both are worth the next draw.
                continue
            }
        }
        return .notNow
    }
}
