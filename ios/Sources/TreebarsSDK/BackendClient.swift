import Foundation

/// What an upload got back: the status, and the two headers the upload policy reads.
///
/// A thrown error is the other outcome — no answer at all — and the uploader treats the two
/// differently, so a status is never invented to stand for "the network failed".
struct UploadResponse {
    let status: Int
    let retryAfter: String?
    /// `X-Treebars-Triggers-Version`, which the server sets on an accepted upload and nothing else.
    var triggersVersion: String? = nil
}

/// What `/v1/context-token` answered, as far as anything acts on it.
enum ContextTokenAnswer: Equatable {
    case token(UUID)
    /// 403 `signature_required`: the one refusal the app is told about, as it is told about a sign-in's.
    case signatureRequired
    /// Any other answer, or none. The purchase goes ahead without a token; nothing is asked again.
    case unavailable
}

/// The seam between the upload policy and HTTP.
///
/// A protocol for one reason: the shared scenarios drive `EventUploader` with scripted answers,
/// and `BackendClient` is the conformance they go through — with a `URLProtocol` standing in for
/// the network, so the request the policy builds is the request that would really be sent.
protocol EventTransport {
    /// Throws when no HTTP answer arrived.
    func postEvents(batch: [String: Any]) async throws -> UploadResponse
}

/// Transport for the ingest endpoint.
///
/// The public write key is sent on every request. There is no token exchange: the
/// key ships inside the app binary regardless, so a round trip would buy nothing but
/// latency on every cold start.
final class BackendClient: EventTransport {
    private let backendURL: URL
    private let writeKey: String
    /// This device's secret, for the posts that name the device: a sign-in, and an upload that may
    /// carry a push token. Nil in the scenario tests, which drive the upload policy and nothing else.
    private let deviceSecret: (@Sendable () -> String)?
    private let session: URLSession
    private let readSession: URLSession

    /// - Parameter protocolClasses: prepended to both sessions' URL loading, for tests that
    ///   answer requests without a network. Nil in the SDK.
    init(backendURL: URL, writeKey: String, deviceSecret: (@Sendable () -> String)? = nil, protocolClasses: [AnyClass]? = nil) {
        self.backendURL = backendURL
        self.writeKey = writeKey
        self.deviceSecret = deviceSecret

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        // Analytics must never block a user-visible request for bandwidth.
        configuration.networkServiceType = .background
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? [])
        }
        self.session = URLSession(configuration: configuration)

        /*
         * A second session, at normal priority, and the difference is the whole reason it
         * exists. `.background` is right for a batch of events nobody is waiting on and
         * wrong for a read: the in-app queue is fetched while an app is starting and the
         * notification centre is fetched while somebody watches a spinner, so both would
         * be deprioritised behind exactly the traffic they are racing.
         */
        let reading = URLSessionConfiguration.default
        reading.timeoutIntervalForRequest = 15
        if let protocolClasses {
            reading.protocolClasses = protocolClasses + (reading.protocolClasses ?? [])
        }
        self.readSession = URLSession(configuration: reading)
    }

    /// A post carries the device secret beside the key: it is what ties a sign-in or a push token to this
    /// device. A header, never the URL.
    private func request(path: String, body: Data, gzip: Bool) -> URLRequest {
        var request = URLRequest(url: backendURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(writeKey, forHTTPHeaderField: TreebarsConstants.writeKeyHeader)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if gzip { request.setValue(Compressor.contentEncoding, forHTTPHeaderField: "Content-Encoding") }
        if let deviceSecret { request.setValue(deviceSecret(), forHTTPHeaderField: TreebarsConstants.deviceAuthHeader) }
        return request
    }

    func postEvents(batch: [String: Any]) async throws -> UploadResponse {
        let json = try JSONSerialization.data(withJSONObject: batch)

        // Fall back to the uncompressed body if compression fails rather than dropping
        // the batch; the server accepts both.
        let compressed = Compressor.compress(json)
        let body = compressed ?? json

        let (_, response) = try await session.data(
            for: request(path: TreebarsConstants.eventsPath, body: body, gzip: compressed != nil)
        )
        let http = response as? HTTPURLResponse
        return UploadResponse(
            status: http?.statusCode ?? 0,
            retryAfter: http?.value(forHTTPHeaderField: "Retry-After"),
            triggersVersion: http?.value(forHTTPHeaderField: TreebarsConstants.triggersVersionHeader)
        )
    }

    /// A sign-in, and whether the server refused it for want of a signature (403 `signature_required`).
    ///
    /// The refusal's body is the answer that matters: when the project requires signed sign-ins,
    /// `Treebars` says so once instead of letting a best-effort call swallow it.
    func postIdentify(payload: [String: Any], signature: String?) async throws -> Bool {
        let json = try JSONSerialization.data(withJSONObject: payload)
        var request = self.request(path: TreebarsConstants.identifyPath, body: json, gzip: false)
        if let signature { request.setValue(signature, forHTTPHeaderField: TreebarsConstants.userSignatureHeader) }

        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 403 else { return false }
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return body?["error"] as? String == "signature_required"
    }

    /**
     A context token for this device and `sessionID`, from `/v1/context-token`.

     Built by the same `request` a sign-in is, so it carries the same proof: the device secret, and for a signed-in
     account the signature a sign-in carries.
     On `readSession` rather than the background one, with five seconds rather than fifteen, because somebody is
     standing at a purchase button while this is out — and a token that arrives after the purchase went ahead
     without one is worth nothing, so waiting longer buys nothing either.
     */
    func postContextToken(deviceID: String, sessionID: String, userID: String?, signature: String?) async -> ContextTokenAnswer {
        var payload: [String: Any] = ["device_id": deviceID, "session_id": sessionID]
        if let userID { payload["user_id"] = userID }
        guard let json = try? JSONSerialization.data(withJSONObject: payload) else { return .unavailable }

        var request = self.request(path: TreebarsConstants.contextTokenPath, body: json, gzip: false)
        request.timeoutInterval = 5
        if userID != nil, let signature { request.setValue(signature, forHTTPHeaderField: TreebarsConstants.userSignatureHeader) }

        guard let (data, response) = try? await readSession.data(for: request) else {
            TreebarsLogger.log("context token: no answer")
            return .unavailable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if status == 200 || status == 201, let token = (body?["token"] as? String).flatMap(UUID.init(uuidString:)) {
            return .token(token)
        }
        if status == 403, body?["error"] as? String == "signature_required" { return .signatureRequired }
        TreebarsLogger.log("context token: refused \(status)")
        return .unavailable
    }

    /*
     * The reads.
     *
     * A read carries the write key *and* a per-device secret. The key is public — it ships
     * in the binary — and these routes return content: rendered messages carrying whatever
     * personalization a campaign put in them, and a person's notification history.
     */

    /**
     The account id as `X-Treebars-User-Id` carries it: UTF-8, percent-encoded, nothing but ASCII
     letters, digits and `-._~` sent as itself — the twin of Kotlin's `userIdHeaderValue`, for the same
     reason: a header value is Latin-1 at best, an account id is whatever the customer chose, and a raw
     id could not be sent for "用户7". The server decodes it.

     An explicit ASCII set, never `.alphanumerics`, which counts "é" and "用" as letters and would
     leave them raw. Nil only for a string with no UTF-8 form, which a Swift `String` cannot be.
     */
    static func userIdHeaderValue(_ userID: String) -> String? {
        userID.addingPercentEncoding(withAllowedCharacters: unreservedASCII)
    }

    private static let unreservedASCII = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// Adds the device secret to a request that returns content — or leaves it off, for the one
    /// read it authenticates nothing on: the trigger list, which belongs to the environment.
    /// `userID` is the signed-in person's account id and `signature` the one the app's backend made
    /// for it: headers rather than query items, so neither sits in a URL a log or a proxy keeps — and an
    /// account id is often an email address.
    private func readRequest(
        path: String,
        query: [String: String],
        secret: String?,
        userID: String? = nil,
        signature: String? = nil
    ) -> URLRequest? {
        var components = URLComponents(
            url: backendURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(writeKey, forHTTPHeaderField: TreebarsConstants.writeKeyHeader)
        if let secret { request.setValue(secret, forHTTPHeaderField: TreebarsConstants.deviceAuthHeader) }
        if let userID, let value = Self.userIdHeaderValue(userID) {
            request.setValue(value, forHTTPHeaderField: TreebarsConstants.userIdHeader)
        }
        if let signature { request.setValue(signature, forHTTPHeaderField: TreebarsConstants.userSignatureHeader) }
        return request
    }

    /**
     Whether the project turned the iPhone link handoff on — nil when there was no answer.

     Asked once, on a first launch, before the pasteboard is read: the switch is the project's and
     lives on the server, and without asking the SDK would read the clipboard — and show Apple's
     "Allow Paste" alert — for a project that has the feature off. Nil is not "no" — see the caller
     for what it does with one.
     */
    func getHandoffEnabled() async -> Bool? {
        guard let request = readRequest(path: TreebarsConstants.handoffPath, query: [:], secret: nil),
              let (data, response) = try? await readSession.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let enabled = object["ios_handoff"] as? Bool
        else { return nil }
        return enabled
    }

    /**
     The environment's trigger list alone: `triggers_only=1`, which asks for the list and nothing
     else — no queued messages, and no message marked fetched.

     No device secret and no user id: the list belongs to the environment, so neither would
     authenticate anything, and a secret sent where it is not needed is one more place it can leak
     from.
     */
    func getTriggerEvents(deviceID: String) async throws -> TriggerList? {
        let query = ["device_id": deviceID, "triggers_only": "1"]
        guard let request = readRequest(path: TreebarsConstants.inAppPath, query: query, secret: nil) else {
            return nil
        }

        let (data, response) = try await readSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            TreebarsLogger.log("trigger list refused \(status)")
            return nil
        }
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return TriggerList(json: object?["trigger_events"])
    }

    /// This device's queued in-app messages.
    func getInApp(deviceID: String, secret: String, userID: String?, signature: String?) async throws -> Data? {
        let query = ["device_id": deviceID]
        guard let request = readRequest(
            path: TreebarsConstants.inAppPath, query: query, secret: secret,
            userID: userID, signature: userID == nil ? nil : signature
        ) else {
            return nil
        }

        let (data, response) = try await readSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // Logged rather than swallowed: a refused read is not an empty queue, and a
            // silent failure here would look exactly like one.
            TreebarsLogger.log("in-app: sync refused \(status)")
            return nil
        }
        return data
    }

    /// One in-app body the sync handed over by reference (`html_ref`), or nil. The caller checks it
    /// against the reference's SHA-256; this only fetches.
    func getInAppBody(deviceID: String, secret: String, userID: String?, signature: String?, deliveryID: String) async -> String? {
        let query = ["device_id": deviceID, "delivery_id": deliveryID]
        guard let request = readRequest(
            path: TreebarsConstants.inAppBodyPath, query: query, secret: secret,
            userID: userID, signature: userID == nil ? nil : signature
        ), let (data, response) = try? await readSession.data(for: request) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            TreebarsLogger.log("in-app: body \(deliveryID) refused \(status)")
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["html"] as? String
    }

    /**
     A game's answer: `claimReward(pool)` for this device's person, in the campaign of `deliveryID` —
     the answer and the status that gave it, or no answer and the status that refused it (-1 when there was none), with
     its `Retry-After` for `claimWithRetries`. A POST behind the sync's gate: the device secret, and the signed-in account
     with its signature. One attempt; asking again is the caller's.
     */
    func postInAppReward(deviceID: String, secret: String, userID: String?, signature: String?, deliveryID: String, pool: String) async -> RewardAttempt {
        guard let json = try? JSONSerialization.data(withJSONObject: ["device_id": deviceID, "delivery_id": deliveryID, "pool": pool]) else {
            return RewardAttempt(status: -1)
        }
        var request = self.request(path: TreebarsConstants.inAppRewardPath, body: json, gzip: false)
        request.setValue(secret, forHTTPHeaderField: TreebarsConstants.deviceAuthHeader)
        if let userID, let value = Self.userIdHeaderValue(userID) {
            request.setValue(value, forHTTPHeaderField: TreebarsConstants.userIdHeader)
            if let signature { request.setValue(signature, forHTTPHeaderField: TreebarsConstants.userSignatureHeader) }
        }
        guard let (data, response) = try? await readSession.data(for: request) else {
            TreebarsLogger.log("reward failed for \(pool)")
            return RewardAttempt(status: -1)
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let retryAfter = http?.value(forHTTPHeaderField: "Retry-After")
        guard status == 200 else {
            TreebarsLogger.log("reward refused \(status) for \(pool)")
            return RewardAttempt(status: status, retryAfter: retryAfter)
        }
        // A 200 whose body is not an answer is `failed`, not `offline`: it was answered, and asking again would not help.
        return RewardAttempt(status: status, retryAfter: retryAfter, answer: try? JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// One page of this device's notification history.
    func getNotifications(
        deviceID: String,
        secret: String,
        userID: String?,
        signature: String?,
        limit: Int?,
        cursor: String?,
        channels: [String]?
    ) async throws -> Data? {
        var query = ["device_id": deviceID]
        if let limit { query["limit"] = String(limit) }
        if let cursor { query["cursor"] = cursor }
        if let channels, !channels.isEmpty { query["channels"] = channels.joined(separator: ",") }

        guard let request = readRequest(
            path: TreebarsConstants.notificationsPath, query: query, secret: secret,
            userID: userID, signature: userID == nil ? nil : signature
        ) else {
            return nil
        }

        let (data, response) = try await readSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            TreebarsLogger.log("notifications: refused \(status)")
            return nil
        }
        return data
    }

    /**
     Read and dismissal, as an acknowledged write.

     Not an event, and that is deliberate. The event pipeline drops a batch the server refuses
     as malformed, to keep moving, so a read-mark sent as an event could be lost with nothing to
     say so and leave a notification unread for good. And a mark cannot be taken back — there is
     no "mark unread" — so "mark everything before now" goes on a request that carries the device
     secret and gets an answer.
     */
    func postNotificationState(secret: String, signature: String?, payload: [String: Any]) async throws -> Data? {
        let json = try JSONSerialization.data(withJSONObject: payload)
        var request = self.request(path: TreebarsConstants.notificationStatePath, body: json, gzip: false)
        request.setValue(secret, forHTTPHeaderField: TreebarsConstants.deviceAuthHeader)
        if payload["user_id"] != nil, let signature {
            request.setValue(signature, forHTTPHeaderField: TreebarsConstants.userSignatureHeader)
        }

        let (data, response) = try await readSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            TreebarsLogger.log("notifications: state write refused \(status)")
            return nil
        }
        return data
    }
}
