import XCTest
@testable import TreebarsSDK

/**
 `contextToken()`: the token an app hands whatever will report a purchase for it — its backend, StoreKit, a billing
 provider — minted by the server for this device and the session the purchase happens in.

 What is pinned here: it asks as a sign-in asks (the same headers, the signature when somebody is signed in), it works
 for a guest as well as a signed-in account, it names the session the purchase's own first event would be in, and asking
 is not an event.

 On an instance of its own rather than `shared`, over a session store, a clock and a queue file of its own, with the
 real `BackendClient` and `URLSession` answered by a `URLProtocol`: `shared` initializes once per process and would start
 timers, observers and a sync against a real host.
 */
final class ContextTokenTests: XCTestCase {

    private let t0: TimeInterval = 1_787_475_600 // 2026-08-23T09:00:00Z
    private let minted = "6f1c0d2e-9a4b-4c8d-b7e1-2f3a4b5c6d7e"

    /// A class, so the SDK's session manager and the test move one instant by reference.
    private final class TestClock {
        var now: TimeInterval
        init(at now: TimeInterval) { self.now = now }
    }

    private var suite = ""
    private var defaults: UserDefaults!
    private var queueFile = ""
    private var identityDirectory: URL!
    private var clock: TestClock!
    private var queue: EventQueue!

    override func setUp() {
        super.setUp()
        suite = "treebars.context-token.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        queueFile = "treebars-queue-context-token-\(UUID().uuidString).json"
        queue = EventQueue(filename: queueFile)
        clock = TestClock(at: t0)
        identityDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        DeviceInfo.identityStore = DeviceIdentityStore(directory: identityDirectory)
        DeviceInfo.forgetResolvedIdentity()
        ContextTokenIngest.reset()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        EventQueue.forget(filename: queueFile)
        try? FileManager.default.removeItem(at: identityDirectory)
        DeviceInfo.identityStore = DeviceIdentityStore.standard()
        DeviceInfo.forgetResolvedIdentity()
        ContextTokenIngest.reset()
        super.tearDown()
    }

    private func sessions() -> SessionManager {
        let clock = self.clock!
        return SessionManager(defaults: defaults, clock: { clock.now })
    }

    private func sdk() -> Treebars {
        Treebars(sessionManager: sessions(), queue: queue)
    }

    /// Built as `initialize` builds it: the device secret from the same place.
    private func client() -> BackendClient {
        BackendClient(
            backendURL: URL(string: "https://\(ContextTokenIngest.host)")!,
            writeKey: "pk_test_context",
            deviceSecret: { DeviceInfo.getFetchSecret() },
            protocolClasses: [ContextTokenIngest.self]
        )
    }

    private func queuedNames() async -> [String] {
        await queue.peek(100).compactMap { $0["event_name"] as? String }
    }

    func testAsksForThisDeviceAndItsSessionAsASignInWouldAndReturnsTheTokenMinted() async throws {
        ContextTokenIngest.script([.init(status: 201, body: #"{"token":"\#(minted)"}"#)])

        let token = await sdk().contextToken(from: client())

        XCTAssertEqual(token, UUID(uuidString: minted))
        let asked = try XCTUnwrap(ContextTokenIngest.requests.first)
        XCTAssertEqual(ContextTokenIngest.requests.count, 1)
        XCTAssertEqual(asked.method, "POST")
        XCTAssertEqual(asked.path, "/v1/context-token")
        XCTAssertEqual(asked.headers[TreebarsConstants.writeKeyHeader], "pk_test_context")
        XCTAssertEqual(asked.headers[TreebarsConstants.deviceAuthHeader], DeviceInfo.getFetchSecret())
        XCTAssertNil(asked.headers[TreebarsConstants.userSignatureHeader], "nobody is signed in, so nothing is signed")
        XCTAssertEqual(asked.body["device_id"] as? String, DeviceInfo.getDeviceId())
        XCTAssertEqual(asked.body["session_id"] as? String, defaults.string(forKey: "treebars.session.id"))
        XCTAssertNotNil(asked.body["session_id"])
        XCTAssertNil(asked.body["user_id"], "a guest is a device's person, and a token for one is the point")
    }

    func testSignedInItNamesTheAccountAndCarriesItsSignature() async throws {
        ContextTokenIngest.script([.init(status: 201, body: #"{"token":"\#(minted)"}"#)])
        let instance = sdk()
        instance.userId = "user_1001"
        instance.userSignature = "3f9a0c"

        let token = await instance.contextToken(from: client())

        XCTAssertEqual(token, UUID(uuidString: minted))
        let asked = try XCTUnwrap(ContextTokenIngest.requests.first)
        XCTAssertEqual(asked.body["user_id"] as? String, "user_1001")
        XCTAssertEqual(asked.headers[TreebarsConstants.userSignatureHeader], "3f9a0c")
    }

    func testARefusalForWantOfASignatureIsNil() async throws {
        ContextTokenIngest.script([.init(status: 403, body: #"{"error":"signature_required"}"#)])
        let instance = sdk()
        instance.userId = "user_1001"

        let token = await instance.contextToken(from: client())

        XCTAssertNil(token)
        XCTAssertNil(ContextTokenIngest.requests.first?.headers[TreebarsConstants.userSignatureHeader])
    }

    /// Nil, and never a throw: the purchase goes ahead without a token whatever went wrong asking for one.
    func testEveryOtherOutcomeIsNil() async {
        let outcomes: [ContextTokenIngest.Answer?] = [
            .init(status: 503, body: #"{"error":"identity_unavailable"}"#),
            .init(status: 429, body: #"{"error":"rate_limited"}"#),
            .init(status: 403, body: #"{"error":"device_auth_required"}"#),
            .init(status: 400, body: #"{"error":"bad_request"}"#),
            .init(status: 201, body: #"{}"#),
            .init(status: 201, body: #"{"token":"tb1.dev.sess"}"#),
            .init(status: 201, body: "not json"),
            nil, // no answer at all
        ]
        for outcome in outcomes {
            ContextTokenIngest.script([outcome])
            let token = await sdk().contextToken(from: client())
            XCTAssertNil(token, "\(outcome.map { "\($0.status) \($0.body)" } ?? "no answer")")
        }
    }

    func testOptedOutAsksNothingAndMovesNothing() async {
        let instance = sdk()
        instance.optedOut = true

        let token = await instance.contextToken(from: client())

        XCTAssertNil(token)
        XCTAssertTrue(ContextTokenIngest.requests.isEmpty)
        XCTAssertNil(defaults.string(forKey: "treebars.session.id"), "an opted-out install opens no session")
        let names = await queuedNames()
        XCTAssertEqual(names, [])
    }

    func testBeforeInitializeThereIsNoClientAndNoToken() async {
        let token = await sdk().contextToken(from: nil)

        XCTAssertNil(token)
        XCTAssertNil(defaults.string(forKey: "treebars.session.id"))
    }

    /*
     The case the token's session exists for. Somebody left the app at nine and comes back at noon to buy: the purchase
     happens in a new session, so the token has to name that one — closing the old session as the next event would,
     backdated to nine — rather than the session the purchase's first event is about to end.
     */
    func testAnAgedOutSessionIsClosedAndANewOneOpenedAndTheTokenNamesTheNewOne() async throws {
        let old = await sessions().touch()
        clock.now += 60
        _ = await sessions().touch()
        let lastActivity = clock.now
        clock.now += 3 * 3600
        ContextTokenIngest.script([.init(status: 201, body: #"{"token":"\#(minted)"}"#)])

        let token = await sdk().contextToken(from: client())

        XCTAssertEqual(token, UUID(uuidString: minted))
        let queued = await queue.peek(100)
        XCTAssertEqual(queued.compactMap { $0["event_name"] as? String }, ["session_end", "session_start"], "the boundaries, and no event for the token")

        let end = queued[0]
        XCTAssertEqual(end["session_id"] as? String, old.sessionId)
        XCTAssertEqual((end["properties"] as? [String: Any])?["event_count"] as? Int, 2)
        XCTAssertEqual(end["timestamp"] as? String, Iso8601.string(from: Date(timeIntervalSince1970: lastActivity)))

        let start = queued[1]
        let opened = try XCTUnwrap(start["session_id"] as? String)
        XCTAssertNotEqual(opened, old.sessionId)
        XCTAssertEqual((start["properties"] as? [String: Any])?["is_first_session"] as? Bool, false)
        XCTAssertEqual(ContextTokenIngest.requests.first?.body["session_id"] as? String, opened)

        // The session the token opened counts the purchase's events and not the token: one event, then an end.
        clock.now += 60
        let next = await sessions().touch()
        XCTAssertEqual(next.sessionId, opened)
        clock.now += 3 * 3600
        let after = await sessions().touch()
        XCTAssertEqual(after.expired?.id, opened)
        XCTAssertEqual(after.expired?.eventCount, 1)
    }

    func testInsideTheSessionTheTokenNamesItQueuesNothingAndCountsForNothing() async {
        let open = await sessions().touch()
        clock.now += 60
        ContextTokenIngest.script([.init(status: 201, body: #"{"token":"\#(minted)"}"#)])

        _ = await sdk().contextToken(from: client())

        XCTAssertEqual(ContextTokenIngest.requests.first?.body["session_id"] as? String, open.sessionId)
        let names = await queuedNames()
        XCTAssertEqual(names, [])

        // Held open by the token, and still at the one event that opened it.
        let tokenAt = clock.now
        clock.now = tokenAt + TreebarsConstants.sessionTimeout - 1
        let still = await sessions().touch()
        XCTAssertEqual(still.sessionId, open.sessionId, "the token was activity: the session is held from it, not from the event before")
        clock.now += TreebarsConstants.sessionTimeout + 1
        let after = await sessions().touch()
        XCTAssertEqual(after.expired?.eventCount, 2, "the opening event and the one just now, not the token")
    }
}

/// The ingest endpoint's `/v1/context-token` as each test scripts it, recording what was asked.
final class ContextTokenIngest: URLProtocol {
    static let host = "ingest.context-token.test"

    struct Answer {
        let status: Int
        let body: String
    }

    struct Asked {
        let method: String?
        let path: String?
        let headers: [String: String]
        let body: [String: Any]
    }

    /// Nil in the script answers with no HTTP response at all.
    private static let state = Box<(answers: [Answer?], requests: [Asked])>(([], []))

    static func reset() { state.value = ([], []) }
    static func script(_ answers: [Answer?]) { state.value = (answers, []) }
    static var requests: [Asked] { state.value.requests }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let asked = Asked(
            method: request.httpMethod,
            path: request.url?.path,
            headers: request.allHTTPHeaderFields ?? [:],
            body: ScriptedIngestProtocol.batch(from: request) ?? [:]
        )
        let next: Answer?? = Self.state.mutate { state in
            state.requests.append(asked)
            return state.answers.isEmpty ? .none : .some(state.answers.removeFirst())
        }
        guard let scripted = next, let answer = scripted else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
