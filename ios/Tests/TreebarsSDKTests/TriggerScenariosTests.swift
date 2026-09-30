import XCTest
@testable import TreebarsSDK

/**
 The shared trigger scenarios, run against this core.

 The same scenarios drive the web SDK and the Kotlin core too.
 Uploads and the trigger-only fetch go through the real `BackendClient` and `URLSession`, answered by
 a `URLProtocol` — so the version read off an `HTTPURLResponse` and the `triggers_only` request this
 core really builds are part of what is checked. The uploader's wakes sleep in `ManualWakes`, whose
 clock only the scenario moves: a debounce and a retry fall due in the order the uploader armed
 them, not the order two real timers happened to fire in.

 Disagreements are collected and asserted once, for the reason `UploaderScenariosTests` gives:
 in an async XCTest only the first failed assertion is recorded.
 */
final class TriggerScenariosTests: XCTestCase {

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // TreebarsSDKTests
        .appendingPathComponent("Fixtures/trigger-scenarios.json")

    private static let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first ?? URL(fileURLWithPath: NSTemporaryDirectory())

    private var filenames: [String] = []
    private let problems = Box<[String]>([])

    private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        guard actual != expected else { return }
        problems.mutate { $0.append("\(label): expected \(expected), got \(actual)") }
    }

    override func tearDown() {
        for name in filenames {
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(name))
        }
        filenames = []
        ScriptedTriggerIngest.shared.reset()
        super.tearDown()
    }

    private func fixture() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.fixtureURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The numbers in the scenarios are consequences of the policy, as they are for the uploads.
    func testTheGeneratedPolicyIsTheOneTheTriggerScenariosWereDerivedFrom() throws {
        let policy = try XCTUnwrap(try fixture()["policy"] as? [String: Any])
        XCTAssertEqual(policy["trigger_flush_debounce_ms"] as? Double, TreebarsConstants.triggerFlushDebounce * 1000)
        XCTAssertEqual(policy["backoff_base_seconds"] as? Double, TreebarsConstants.backoffBase)
        XCTAssertEqual(policy["auth_cooldown_seconds"] as? Double, TreebarsConstants.authCooldown)
    }

    func testEveryTriggerScenarioAgrees() async throws {
        let fixture = try fixture()
        let scenarios = try XCTUnwrap(fixture["scenarios"] as? [[String: Any]])
        for scenario in scenarios {
            try await run(scenario, fixture: fixture)
        }
        XCTAssertEqual(scenarios.count, 14, "the fixture changed size; check every scenario still runs here")
        XCTAssertTrue(problems.value.isEmpty, "\n" + problems.value.joined(separator: "\n"))
    }

    private struct Shape: Equatable, CustomStringConvertible {
        let batchId: String
        let events: [String]
        var description: String { "\(batchId)\(events)" }
    }

    private static func shapes(_ value: Any?) -> [Shape] {
        (value as? [[String: Any]] ?? []).map {
            Shape(batchId: $0["batch_id"] as? String ?? "", events: $0["events"] as? [String] ?? [])
        }
    }

    private static func event(_ entry: [String: Any]) -> [String: Any] {
        [
            "event_id": entry["id"] as? String ?? "",
            "session_id": "s1",
            "device_id": "dev_fixture",
            "event_name": entry["name"] as? String ?? "",
            "properties": [String: Any](),
            "timestamp": "2026-09-15T12:00:00.000Z",
            "sdk_version": TreebarsConstants.sdkVersion,
        ]
    }

    private func run(_ scenario: [String: Any], fixture: [String: Any]) async throws {
        let id = scenario["id"] as? String ?? "?"
        let epoch = try XCTUnwrap((fixture["epoch_ms"] as? NSNumber)?.int64Value)
        let writeKey = fixture["write_key"] as? String ?? ""
        let batchSize = scenario["batch_size"] as? Int ?? TreebarsConstants.batchSize

        let unique = UUID().uuidString
        let queueName = "treebars-queue-trigger-\(unique).json"
        let storeName = "treebars-uploader-trigger-\(unique).json"
        let triggersName = "treebars-triggers-trigger-\(unique).json"
        filenames += [queueName, storeName, triggersName]

        let ingest = ScriptedTriggerIngest.shared
        ingest.reset()
        let clock = Box<Int64>(epoch)
        let randoms = Box<[Double]>([])
        let minted = Box<Int>(0)
        let wakes = ManualWakes(clock: clock)

        if let stored = TriggerList(json: scenario["stored_triggers"]) {
            TriggerStore(filename: triggersName).save(stored)
        }

        let client = BackendClient(
            backendURL: URL(string: "https://\(ScriptedTriggerIngestProtocol.host)")!,
            writeKey: writeKey,
            protocolClasses: [ScriptedTriggerIngestProtocol.self]
        )

        var queue = EventQueue(filename: queueName)
        for entry in scenario["queue"] as? [[String: Any]] ?? [] {
            await queue.append(Self.event(entry))
        }

        var triggers = TriggerEvents(store: TriggerStore(filename: triggersName)) { nil }
        func build() -> EventUploader {
            triggers = TriggerEvents(store: TriggerStore(filename: triggersName)) {
                (try? await client.getTriggerEvents(deviceID: "dev_fixture")) ?? nil
            }
            return EventUploader(
                queue: queue,
                transport: client,
                store: UploaderStore(filename: storeName),
                writeKey: writeKey,
                batchSize: batchSize,
                now: { clock.value },
                random: {
                    randoms.mutate { values in
                        if values.isEmpty {
                            ingest.note("a random draw")
                            // Not zero: with wakes live, an unscripted failure retried after no delay
                            // at all would fall due again at once, and the advance would never end.
                            return 0.5
                        }
                        return values.removeFirst()
                    }
                },
                newBatchId: { minted.mutate { $0 += 1; return "b\($0)" } },
                wakes: wakes,
                triggers: triggers
            )
        }
        var uploader = build()

        func offset(_ value: Int64) -> Int64? { value == 0 ? nil : value - epoch }
        let problemsBefore = problems.value.count

        for (index, step) in (scenario["steps"] as? [[String: Any]] ?? []).enumerated() {
            // A scenario stops at its first disagreement, as the other two harnesses' assertions do:
            // every step after one describes a state this core is no longer in.
            if problems.value.count > problemsBefore { break }
            let action = step["do"] as? String ?? "?"
            let label = "\(id) step \(index + 1) (\(action))"
            let expected = step["expect"] as? [String: Any] ?? [:]
            let at = (step["at"] as? NSNumber)?.int64Value ?? 0

            ingest.script(
                uploads: (step["responses"] as? [[String: Any]] ?? []).map {
                    ScriptedTriggerIngest.Upload(
                        status: ($0["network_error"] as? Bool) == true ? nil : $0["status"] as? Int,
                        retryAfter: $0["retry_after"] as? String,
                        triggersVersion: $0["triggers_version"] as? String
                    )
                },
                syncs: (step["syncs"] as? [[String: Any]] ?? []).map {
                    ScriptedTriggerIngest.Sync(
                        failed: ($0["network_error"] as? Bool) == true,
                        triggerEvents: $0["trigger_events"]
                    )
                }
            )
            randoms.value = (step["random"] as? [NSNumber] ?? []).map(\.doubleValue)

            if !(await wakes.advance(to: epoch + at)) {
                problems.mutate { $0.append("\(label): wakes kept falling due; the scenario cannot settle") }
                break
            }
            switch action {
            case "track":
                for entry in step["events"] as? [[String: Any]] ?? [] {
                    await queue.append(Self.event(entry))
                    await uploader.eventLogged(entry["name"] as? String ?? "")
                }
            case "tick":
                await uploader.flush()
            case "sync_start":
                triggers.beginSync()
            case "sync_end":
                triggers.endSync(TriggerList(json: step["trigger_events"]))
            case "relaunch":
                // The process dies, and every wake it had armed dies with it.
                wakes.dropAll()
                queue = EventQueue(filename: queueName)
                uploader = build()
            case "advance":
                break
            default:
                problems.mutate { $0.append("\(label): `\(action)` is not a step this core can take") }
            }

            expectEqual(ingest.unscripted, [], "\(label): not in the scenario")
            expectEqual(ingest.unusedUploads, 0, "\(label): responses never asked for")
            expectEqual(ingest.unusedSyncs, 0, "\(label): trigger list answers never asked for")
            expectEqual(randoms.value, [], "\(label): random values never drawn")
            expectEqual(ingest.violations, [], "\(label): requests")

            expectEqual(ingest.sent.map { Shape(batchId: $0.batchId, events: $0.events) }, Self.shapes(expected["sent"]), "\(label): sent")
            expectEqual(ingest.synced, expected["synced"] as? Int ?? 0, "\(label): trigger list fetches")

            if expected.keys.contains("triggers") {
                let stored = TriggerStore(filename: triggersName).load()
                expectEqual(stored, TriggerList(json: expected["triggers"]), "\(label): stored triggers")
            }
            if let queued = expected["queue"] as? [String] {
                let actual = await EventQueue(filename: queueName).peek(Int.max).compactMap { $0["event_id"] as? String }
                expectEqual(actual, queued, "\(label): queue")
            }
            let state = UploaderStore(filename: storeName).load()
            if expected["pending"] != nil {
                let pending = state.pending.map { Shape(batchId: $0.batchId, events: $0.events.compactMap { $0["event_id"] as? String }) }
                expectEqual(pending, Self.shapes(expected["pending"]), "\(label): pending")
            }
            if expected.keys.contains("next_allowed_at") {
                expectEqual(offset(state.nextAllowedAt), (expected["next_allowed_at"] as? NSNumber)?.int64Value, "\(label): next_allowed_at")
            }
            if expected.keys.contains("auth_blocked_until") {
                expectEqual(offset(state.authBlockedUntil), (expected["auth_blocked_until"] as? NSNumber)?.int64Value, "\(label): auth_blocked_until")
            }
        }
        wakes.dropAll()
    }
}

/**
 Wakes that sleep until the scenario says it is time.

 `advance(to:)` fires every live wake due by then, earliest first — one armed earlier wins a tie —
 with the clock moved to each wake's moment before it fires, and awaits each one's flush before
 looking for the next, which is the order a device's timers would have produced them in.
 */
final class ManualWakes: UploadWakes, @unchecked Sendable {
    final class Entry: UploadWake, @unchecked Sendable {
        let at: Int64
        let serial: Int
        let fire: @Sendable () async -> Void
        private let cancelled = Box<Bool>(false)

        init(at: Int64, serial: Int, fire: @escaping @Sendable () async -> Void) {
            self.at = at
            self.serial = serial
            self.fire = fire
        }

        var isCancelled: Bool { cancelled.value }
        func cancel() { cancelled.value = true }
    }

    private let clock: Box<Int64>
    private let entries = Box<[Entry]>([])
    private let serials = Box<Int>(0)

    init(clock: Box<Int64>) {
        self.clock = clock
    }

    func arm(after milliseconds: Int64, _ fire: @escaping @Sendable () async -> Void) -> any UploadWake {
        let serial = serials.mutate { $0 += 1; return $0 }
        let entry = Entry(at: clock.value + milliseconds, serial: serial, fire: fire)
        entries.mutate { $0.append(entry) }
        return entry
    }

    /// False when wakes went on falling due past any number a scenario could need — a core that
    /// re-arms itself at the moment it is woken, which would otherwise hang the suite.
    @discardableResult
    func advance(to target: Int64) async -> Bool {
        var fired = 0
        while let next = takeEarliest(dueBy: target) {
            fired += 1
            if fired > 200 { return false }
            clock.value = max(clock.value, next.at)
            await next.fire()
        }
        clock.value = target
        return true
    }

    func dropAll() {
        entries.mutate { all in
            all.forEach { $0.cancel() }
            all.removeAll()
        }
    }

    private func takeEarliest(dueBy target: Int64) -> Entry? {
        entries.mutate { all -> Entry? in
            all.removeAll { $0.isCancelled }
            guard let earliest = all.filter({ $0.at <= target }).min(by: { ($0.at, $0.serial) < ($1.at, $1.serial) }) else {
                return nil
            }
            all.removeAll { $0 === earliest }
            return earliest
        }
    }
}

/// The ingest endpoint as the trigger scenarios script it, shared with the `URLProtocol` that answers.
final class ScriptedTriggerIngest: @unchecked Sendable {
    struct Upload {
        /// Nil answers with no HTTP response at all.
        let status: Int?
        let retryAfter: String?
        let triggersVersion: String?
    }

    struct Sync {
        let failed: Bool
        let triggerEvents: Any?
    }

    struct Sent {
        let batchId: String
        let events: [String]
    }

    static let shared = ScriptedTriggerIngest()

    private let lock = NSLock()
    private var uploads: [Upload] = []
    private var syncs: [Sync] = []
    private var _sent: [Sent] = []
    private var _synced = 0
    private var _unscripted: [String] = []
    private var _violations: [String] = []

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func reset() {
        script(uploads: [], syncs: [])
    }

    /// The answers for the next step, which also starts that step's record.
    func script(uploads: [Upload], syncs: [Sync]) {
        locked {
            self.uploads = uploads
            self.syncs = syncs
            _sent = []
            _synced = 0
            _unscripted = []
            _violations = []
        }
    }

    func note(_ unscripted: String) {
        locked { _unscripted.append(unscripted) }
    }

    var sent: [Sent] { locked { _sent } }
    var synced: Int { locked { _synced } }
    var unscripted: [String] { locked { _unscripted } }
    var violations: [String] { locked { _violations } }
    var unusedUploads: Int { locked { uploads.count } }
    var unusedSyncs: Int { locked { syncs.count } }

    func answerUpload(_ batch: [String: Any]) -> Upload? {
        let batchId = batch["batch_id"] as? String ?? "?"
        let events = (batch["events"] as? [[String: Any]] ?? []).compactMap { $0["event_id"] as? String }
        return locked {
            guard !uploads.isEmpty else {
                _unscripted.append("an upload of \(batchId)")
                return nil
            }
            let next = uploads.removeFirst()
            _sent.append(Sent(batchId: batchId, events: events))
            return next
        }
    }

    func answerSync(_ request: URLRequest) -> Sync? {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        return locked {
            _synced += 1
            // What the list is asked for with, checked on the request this core really builds.
            if value("triggers_only") != "1" { _violations.append("a trigger list fetch without triggers_only=1") }
            if value("device_id") == nil { _violations.append("a trigger list fetch without a device_id") }
            if request.value(forHTTPHeaderField: TreebarsConstants.deviceAuthHeader) != nil {
                _violations.append("a trigger list fetch that sent the device secret")
            }
            guard !syncs.isEmpty else {
                _unscripted.append("a trigger list fetch")
                return nil
            }
            return syncs.removeFirst()
        }
    }
}

final class ScriptedTriggerIngestProtocol: URLProtocol {
    static let host = "triggers.scenarios.test"

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let ingest = ScriptedTriggerIngest.shared
        switch request.url?.path {
        case TreebarsConstants.eventsPath:
            guard let batch = ScriptedIngestProtocol.batch(from: request) else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotDecodeRawData))
                return
            }
            guard let answer = ingest.answerUpload(batch), let status = answer.status else {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            var headers = ["Content-Type": "application/json"]
            if let retryAfter = answer.retryAfter { headers["Retry-After"] = retryAfter }
            if let version = answer.triggersVersion { headers[TreebarsConstants.triggersVersionHeader] = version }
            respond(status: status, headers: headers, body: Data("{}".utf8))

        case TreebarsConstants.inAppPath:
            guard let answer = ingest.answerSync(request), !answer.failed else {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            var body: [String: Any] = ["server_time": "2026-09-15T12:00:00.000Z"]
            if let list = answer.triggerEvents { body["trigger_events"] = list }
            let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
            respond(status: 200, headers: ["Content-Type": "application/json"], body: data)

        default:
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
        }
    }

    private func respond(status: Int, headers: [String: String], body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
