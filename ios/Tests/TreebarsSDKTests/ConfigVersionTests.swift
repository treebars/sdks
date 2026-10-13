import XCTest
@testable import TreebarsSDK

/**
 Where remote config hears that a newer config exists: an accepted upload's answer.

 The shared scenarios start from "an upload's answer named version 4". This pins the step before that — that the
 uploader tells remote config after a flush in which an upload was ACCEPTED, with the version its answers named
 or with none, and tells it nothing after a flush the endpoint refused or never reached. Without the second
 half, an ingest that is down would have every install ask it for config as often as it tries to upload.
 */
final class ConfigVersionTests: XCTestCase {

    private struct Scripted: EventTransport {
        let answer: @Sendable () throws -> UploadResponse
        func postEvents(batch: [String: Any]) async throws -> UploadResponse { try answer() }
    }

    private struct Unreachable: Error {}

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

    /// One event queued and one flush, answered by `answer`; what remote config was told, in order.
    private func told(_ answer: @escaping @Sendable () throws -> UploadResponse) async -> [String?] {
        let unique = UUID().uuidString
        let queueName = "treebars-queue-config-\(unique).json"
        let storeName = "treebars-uploader-config-\(unique).json"
        filenames += [queueName, storeName]

        let heard = Box<[String?]>([])
        let queue = EventQueue(filename: queueName)
        await queue.append([
            "event_id": "e1",
            "session_id": "s1",
            "device_id": "dev_fixture",
            "event_name": "screen_view",
            "properties": [String: Any](),
            "timestamp": "2026-09-15T12:00:00.000Z",
        ])
        let uploader = EventUploader(
            queue: queue,
            transport: Scripted(answer: answer),
            store: UploaderStore(filename: storeName),
            writeKey: "pk_test_fixture",
            wakes: nil,
            configSeen: { version in heard.mutate { $0.append(version) } }
        )
        await uploader.flush()
        return heard.value
    }

    func testAnAcceptedUploadTellsRemoteConfigTheVersionItsAnswerNamed() async {
        let heard = await told { UploadResponse(status: 200, retryAfter: nil, configVersion: "7") }
        XCTAssertEqual(heard, ["7"])
    }

    func testAnAcceptedUploadThatNamesNoVersionStillSaysSoSoAnAskThatIsOwedCanBeMade() async {
        let heard = await told { UploadResponse(status: 200, retryAfter: nil) }
        XCTAssertEqual(heard, [nil])
    }

    func testARefusedUploadAndOneThatNeverArrivedTellItNothing() async {
        let refused = await told { UploadResponse(status: 503, retryAfter: "60", configVersion: "7") }
        XCTAssertEqual(refused, [])
        let unauthorised = await told { UploadResponse(status: 401, retryAfter: nil) }
        XCTAssertEqual(unauthorised, [])
        let unreachable = await told { throw Unreachable() }
        XCTAssertEqual(unreachable, [])
    }
}
