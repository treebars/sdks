import Compression
import XCTest
@testable import TreebarsSDK

/**
 The shared upload scenarios, run against this core.

 The same scenarios drive the web SDK and the Kotlin core too,
 and that is the point of it being data: three implementations of one policy agree only if each is
 asked the same questions.

 The requests go through the real `BackendClient` and `URLSession`, answered by a `URLProtocol`
 rather than a fake transport — so what the scenarios check includes the compressed body this core
 really sends and the `Retry-After` it really reads off an `HTTPURLResponse`. The clock and the
 jitter are handed in. What is asserted is read back from a fresh `UploaderStore` and `EventQueue`
 over the same files: what a relaunch would find, not what this uploader holds in memory.

 The fixture is found from `#filePath`, which works on a simulator because a simulator reads the
 host's file system. It would not on a device, and nothing here is meant to run on one.
 */
final class UploaderScenariosTests: XCTestCase {

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // TreebarsSDKTests
        .appendingPathComponent("Fixtures/uploader-scenarios.json")

    private static let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first ?? URL(fileURLWithPath: NSTemporaryDirectory())

    private var filenames: [String] = []

    /**
     Every disagreement, asserted once at the end rather than as each is found.

     Measured on an iOS 26.5 simulator: with four scenarios deliberately broken, this async test
     recorded the first `XCTAssertEqual` failure and none of the three after it, while the loop went
     on running every scenario. So assertions made one by one would let a scenario after a failing
     one pass unseen — the failure this suite exists to report would be the one it hides.
     */
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
        ScriptedIngest.shared.reset(storeName: nil)
        super.tearDown()
    }

    private func fixture() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.fixtureURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The numbers in the scenarios are consequences of the policy. If the generated constants
    /// moved and the fixture did not, every expectation would be checking the wrong arithmetic.
    func testTheGeneratedPolicyIsTheOneTheScenariosWereDerivedFrom() throws {
        let policy = try XCTUnwrap(try fixture()["policy"] as? [String: Any])

        XCTAssertEqual(policy["batch_size"] as? Int, TreebarsConstants.batchSize)
        XCTAssertEqual(policy["drain_max_batches"] as? Int, TreebarsConstants.drainMaxBatches)
        XCTAssertEqual(policy["backoff_base_seconds"] as? Double, TreebarsConstants.backoffBase)
        XCTAssertEqual(policy["backoff_cap_seconds"] as? Double, TreebarsConstants.backoffCap)
        XCTAssertEqual(Set(policy["retry_after_statuses"] as? [Int] ?? []), TreebarsConstants.retryAfterStatuses)
        XCTAssertEqual(policy["retry_after_max_seconds"] as? Double, TreebarsConstants.retryAfterMax)
        XCTAssertEqual(Set(policy["auth_statuses"] as? [Int] ?? []), TreebarsConstants.authStatuses)
        XCTAssertEqual(policy["auth_cooldown_seconds"] as? Double, TreebarsConstants.authCooldown)
    }

    /// The HTTP date is computed by hand here and in the other two cores, so none of them inherits
    /// a platform parser's leniency. Checked against Foundation's own formatting across two
    /// thousand instants — the scenarios can only afford two dates.
    func testAnIMFFixdateReadsAsTheInstantItNames() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"

        var seed: Int64 = 7
        for _ in 0..<2000 {
            seed = (seed * 48271) % 2147483647
            let at: Int64 = 31_536_000_000 + seed * 1000
            let text = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(at) / 1000))
            XCTAssertEqual(retryAfterDelayMs(text, now: 0), at, text)
        }
    }

    func testEveryScenarioAgrees() async throws {
        let fixture = try fixture()
        let scenarios = try XCTUnwrap(fixture["scenarios"] as? [[String: Any]])
        var ran = 0

        for scenario in scenarios {
            let id = scenario["id"] as? String ?? "?"
            if let platforms = scenario["platforms"] as? [String], !platforms.contains("ios") {
                // A page-hide scenario. Asserted rather than skipped silently, so a scenario that
                // stopped naming its platform would start running here and fail loudly instead.
                XCTAssertEqual(Set(platforms), ["web"], "\(id) names a platform this suite does not know")
                continue
            }
            try await run(scenario, fixture: fixture)
            ran += 1
        }
        XCTAssertGreaterThan(ran, 0, "no scenario ran")
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

    private static func shape(ofBatch batch: [String: Any]) -> Shape {
        Shape(
            batchId: batch["batch_id"] as? String ?? "",
            events: (batch["events"] as? [[String: Any]] ?? []).compactMap { $0["event_id"] as? String }
        )
    }

    private static func event(_ id: String) -> [String: Any] {
        [
            "event_id": id,
            "session_id": "s1",
            "device_id": "dev_fixture",
            "event_name": "evt_\(id)",
            "properties": ["id": id],
            "timestamp": "2026-09-15T12:00:00.000Z",
            "sdk_version": TreebarsConstants.sdkVersion,
        ]
    }

    private func run(_ scenario: [String: Any], fixture: [String: Any]) async throws {
        let id = scenario["id"] as? String ?? "?"
        let epoch = try XCTUnwrap((fixture["epoch_ms"] as? NSNumber)?.int64Value)
        var writeKey = scenario["write_key"] as? String ?? (fixture["write_key"] as? String ?? "")
        let batchSize = scenario["batch_size"] as? Int ?? TreebarsConstants.batchSize

        let queueName = "treebars-queue-scenario-\(UUID().uuidString).json"
        let storeName = "treebars-uploader-scenario-\(UUID().uuidString).json"
        filenames += [queueName, storeName]

        let ingest = ScriptedIngest.shared
        ingest.reset(storeName: storeName)
        let clock = Box<Int64>(epoch)
        let randoms = Box<[Double]>([])
        let minted = Box<Int>(0)

        var queue = EventQueue(filename: queueName)
        for each in scenario["queue"] as? [String] ?? [] {
            await queue.append(Self.event(each))
        }

        func build() -> EventUploader {
            let key = writeKey
            return EventUploader(
                queue: queue,
                transport: BackendClient(
                    backendURL: URL(string: "https://\(ScriptedIngestProtocol.host)")!,
                    writeKey: key,
                    protocolClasses: [ScriptedIngestProtocol.self]
                ),
                store: UploaderStore(filename: storeName),
                writeKey: key,
                batchSize: batchSize,
                now: { clock.value },
                random: {
                    randoms.mutate { values in
                        if values.isEmpty {
                            ingest.note("a random draw")
                            return 0
                        }
                        return values.removeFirst()
                    }
                },
                newBatchId: { minted.mutate { $0 += 1; return "b\($0)" } },
                wakes: nil
            )
        }
        var uploader = build()

        func offset(_ value: Int64) -> Int64? { value == 0 ? nil : value - epoch }

        func verify(_ label: String, _ expected: [String: Any], full: Bool) async {
            let state = UploaderStore(filename: storeName).load()
            let pending = state.pending.map { Shape(batchId: $0.batchId, events: $0.events.compactMap { $0["event_id"] as? String }) }
            let queued = await EventQueue(filename: queueName).peek(Int.max).compactMap { $0["event_id"] as? String }
            let sent = ingest.sent

            if full || expected["sent"] != nil {
                expectEqual(sent.map { Self.shape(ofBatch: $0.batch) }, Self.shapes(expected["sent"]), "\(label): sent")
            }
            if full || expected["pending"] != nil {
                expectEqual(pending, Self.shapes(expected["pending"]), "\(label): pending")
            }
            if full || expected["queue"] != nil {
                expectEqual(queued, expected["queue"] as? [String] ?? [], "\(label): queue")
            }
            if full || expected["attempt"] != nil {
                expectEqual(state.attempt, expected["attempt"] as? Int ?? 0, "\(label): attempt")
            }
            if full || expected["next_allowed_at"] != nil {
                expectEqual(offset(state.nextAllowedAt), (expected["next_allowed_at"] as? NSNumber)?.int64Value, "\(label): next_allowed_at")
            }
            if full || expected["auth_blocked_until"] != nil {
                expectEqual(offset(state.authBlockedUntil), (expected["auth_blocked_until"] as? NSNumber)?.int64Value, "\(label): auth_blocked_until")
            }
            if full || expected["dropped"] != nil {
                // Sent in this step, never acknowledged, and now in neither store.
                let acknowledged = Set(sent.filter { ($0.status ?? 0) >= 200 && ($0.status ?? 0) < 300 }
                    .flatMap { Self.shape(ofBatch: $0.batch).events })
                let kept = Set(pending.flatMap(\.events) + queued)
                var seen = Set<String>()
                let dropped = sent.flatMap { Self.shape(ofBatch: $0.batch).events }
                    .filter { seen.insert($0).inserted && !acknowledged.contains($0) && !kept.contains($0) }
                expectEqual(dropped, expected["dropped"] as? [String] ?? [], "\(label): dropped")
            }
        }

        for (index, step) in (scenario["steps"] as? [[String: Any]] ?? []).enumerated() {
            let action = step["do"] as? String ?? "?"
            let label = "\(id) step \(index + 1) (\(action))"
            let expected = step["expect"] as? [String: Any] ?? [:]

            switch action {
            case "flush":
                clock.value = epoch + ((step["at"] as? NSNumber)?.int64Value ?? 0)
                ingest.script((step["responses"] as? [[String: Any]] ?? []).map {
                    ScriptedIngest.Answer(
                        status: ($0["network_error"] as? Bool) == true ? nil : $0["status"] as? Int,
                        retryAfter: $0["retry_after"] as? String
                    )
                })
                randoms.value = (step["random"] as? [NSNumber] ?? []).map(\.doubleValue)

                await uploader.flush()

                expectEqual(ingest.unscripted, [], "\(label): not in the scenario")
                expectEqual(ingest.unused, 0, "\(label): responses never asked for")
                expectEqual(randoms.value, [], "\(label): random values never drawn")
                expectEqual(ingest.violations, [], "\(label): invariants")
                await verify(label, expected, full: true)

            case "track":
                for each in step["events"] as? [String] ?? [] {
                    await queue.append(Self.event(each))
                }
                if step["expect"] != nil { await verify(label, expected, full: false) }

            case "relaunch":
                if let key = step["write_key"] as? String { writeKey = key }
                queue = EventQueue(filename: queueName)
                uploader = build()
                ingest.script([])
                if step["expect"] != nil { await verify(label, expected, full: false) }

            default:
                problems.mutate { $0.append("\(label): `\(action)` is not a step this core can take") }
            }
        }
    }
}

/// A value several closures share across the concurrency boundary, behind a lock.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }

    func mutate<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&stored)
    }
}

/**
 The ingest endpoint as the scenarios script it, shared with the `URLProtocol` that answers requests.

 Every check that has to happen at the moment of sending happens here — the batch already being the
 persisted head, and a resend carrying what the first send carried — and is recorded rather than
 asserted, because it runs on URLSession's own thread and a failure there would be attributed to
 nothing.
 */
final class ScriptedIngest: @unchecked Sendable {
    struct Answer {
        /// Nil answers with no HTTP response at all.
        let status: Int?
        let retryAfter: String?
    }

    static let shared = ScriptedIngest()

    private let lock = NSLock()
    private var answers: [Answer] = []
    private var storeName: String?
    private var firstSend: [String: String] = [:]
    private var _sent: [(batch: [String: Any], status: Int?)] = []
    private var _violations: [String] = []
    private var _unscripted: [String] = []

    func reset(storeName: String?) {
        lock.lock(); defer { lock.unlock() }
        self.storeName = storeName
        answers = []
        firstSend = [:]
        _sent = []
        _violations = []
        _unscripted = []
    }

    /// The answers for the next step, which also starts that step's record of what was sent.
    func script(_ next: [Answer]) {
        lock.lock(); defer { lock.unlock() }
        answers = next
        _sent = []
        _violations = []
        _unscripted = []
    }

    func note(_ unscripted: String) {
        lock.lock(); defer { lock.unlock() }
        _unscripted.append(unscripted)
    }

    var sent: [(batch: [String: Any], status: Int?)] { lock.lock(); defer { lock.unlock() }; return _sent }
    var violations: [String] { lock.lock(); defer { lock.unlock() }; return _violations }
    var unscripted: [String] { lock.lock(); defer { lock.unlock() }; return _unscripted }
    var unused: Int { lock.lock(); defer { lock.unlock() }; return answers.count }

    /// Checks the two invariants, records the send, and returns what to answer — or nil when the
    /// scenario scripted nothing, which is itself recorded.
    func answer(_ batch: [String: Any]) -> Answer? {
        let batchId = batch["batch_id"] as? String ?? "?"
        let events = (batch["events"] as? [[String: Any]] ?? []).compactMap { $0["event_id"] as? String }

        lock.lock(); defer { lock.unlock() }

        if let storeName {
            let head = UploaderStore(filename: storeName).load().pending.first
            if head?.batchId != batchId || head?.events.compactMap({ $0["event_id"] as? String }) != events {
                _violations.append("\(batchId) was sent before it was the persisted head")
            }
        }

        let carried = Self.canonical(["sent_at": batch["sent_at"] ?? NSNull(), "events": batch["events"] ?? NSNull()])
        if let first = firstSend[batchId] {
            if first != carried { _violations.append("\(batchId) changed between sends") }
        } else {
            firstSend[batchId] = carried
        }

        guard !answers.isEmpty else {
            _unscripted.append("a request for \(batchId)")
            return nil
        }
        let next = answers.removeFirst()
        _sent.append((batch: batch, status: next.status))
        return next
    }

    private static func canonical(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

final class ScriptedIngestProtocol: URLProtocol {
    static let host = "ingest.scenarios.test"

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let batch = Self.batch(from: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotDecodeRawData))
            return
        }
        guard let answer = ScriptedIngest.shared.answer(batch), let status = answer.status else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }

        var headers = ["Content-Type": "application/json"]
        if let retryAfter = answer.retryAfter { headers["Retry-After"] = retryAfter }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    /// The body as the core sent it: a stream rather than `httpBody` by the time it reaches here,
    /// and zlib-framed deflate when `Compressor` managed to compress it. Not private: the trigger
    /// scenarios read their uploads the same way.
    static func batch(from request: URLRequest) -> [String: Any]? {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
        }
        if request.value(forHTTPHeaderField: "Content-Encoding") == Compressor.contentEncoding {
            guard let inflated = inflate(body) else { return nil }
            body = inflated
        }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    /// RFC 1950 in: a two-byte header and a four-byte trailer around the raw DEFLATE that
    /// `COMPRESSION_ZLIB` decodes.
    private static func inflate(_ framed: Data) -> Data? {
        guard framed.count > 6 else { return nil }
        let raw = framed.subdata(in: 2..<(framed.count - 4))
        let capacity = 8 * 1024 * 1024
        var output = Data(count: capacity)
        let size = output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) -> Int in
            raw.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        return size > 0 ? output.prefix(size) : nil
    }
}
