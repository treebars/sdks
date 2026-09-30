import XCTest
@testable import TreebarsSDK

/**
 An opted-out install sends nothing, whoever asks for a flush — the twin of Kotlin's
 `UploaderPausedTest`. The timer, the lifecycle, a wake and the flush on the way up all reach the
 uploader directly rather than through `Treebars.flush()`, so the gate is in the uploader (`paused`),
 asked before each batch: batches an earlier launch sealed stay unsent once the install has said no.
 */
final class UploaderPausedTests: XCTestCase {

    private static let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first ?? URL(fileURLWithPath: NSTemporaryDirectory())

    private var filenames: [String] = []

    override func tearDown() {
        for name in filenames {
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(name))
        }
        filenames = []
        super.tearDown()
    }

    /// Answers every batch with a 200 and remembers it, after telling the test it was asked.
    private final class RecordingTransport: EventTransport, @unchecked Sendable {
        let sent = Box<[String]>([])
        private let onSend: @Sendable () -> Void

        init(onSend: @escaping @Sendable () -> Void = {}) {
            self.onSend = onSend
        }

        func postEvents(batch: [String: Any]) async throws -> UploadResponse {
            sent.mutate { $0.append(batch["batch_id"] as? String ?? "?") }
            onSend()
            return UploadResponse(status: 200, retryAfter: nil)
        }
    }

    private static func event(_ id: String) -> [String: Any] {
        [
            "event_id": id,
            "session_id": "s1",
            "device_id": "dev_paused",
            "event_name": "evt_\(id)",
            "properties": ["id": id],
            "timestamp": "2026-09-25T12:00:00.000Z",
            "sdk_version": TreebarsConstants.sdkVersion,
        ]
    }

    private func files() -> (queue: String, store: String) {
        let queue = "treebars-queue-paused-\(UUID().uuidString).json"
        let store = "treebars-uploader-paused-\(UUID().uuidString).json"
        filenames += [queue, store]
        return (queue, store)
    }

    func testSendsNothingWhilePausedAndEverythingOnceItIsNot() async {
        let (queueName, storeName) = files()
        let queue = EventQueue(filename: queueName)
        await queue.append(Self.event("e1"))
        await queue.append(Self.event("e2"))
        let paused = Box<Bool>(true)
        let transport = RecordingTransport()
        let uploader = EventUploader(
            queue: queue,
            transport: transport,
            store: UploaderStore(filename: storeName),
            writeKey: "pk_test_paused",
            now: { 1_790_000_000_000 },
            wakes: nil,
            paused: { paused.value }
        )

        await uploader.flush()
        XCTAssertEqual(transport.sent.value, [])
        let waiting = await queue.count
        XCTAssertEqual(waiting, 2)

        paused.value = false
        await uploader.flush()
        XCTAssertEqual(transport.sent.value.count, 1)
        let left = await queue.count
        XCTAssertEqual(left, 0)
    }

    func testStopsADrainAlreadyRunningAtTheNextBatch() async {
        let (queueName, storeName) = files()
        let queue = EventQueue(filename: queueName)
        for id in ["e0", "e1", "e2"] {
            await queue.append(Self.event(id))
        }
        let paused = Box<Bool>(false)
        // The opt-out, arriving while the first request is out.
        let transport = RecordingTransport(onSend: { paused.value = true })
        let uploader = EventUploader(
            queue: queue,
            transport: transport,
            store: UploaderStore(filename: storeName),
            writeKey: "pk_test_paused",
            batchSize: 2,
            now: { 1_790_000_000_000 },
            wakes: nil,
            paused: { paused.value }
        )

        await uploader.flush()
        XCTAssertEqual(transport.sent.value.count, 1)
        let left = await queue.count
        XCTAssertEqual(left, 1)
    }
}
