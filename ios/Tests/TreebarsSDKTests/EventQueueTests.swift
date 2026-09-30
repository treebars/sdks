import XCTest
@testable import TreebarsSDK

/**
 The queue may not lose an event, whoever is appending and whatever else is happening at the time.

 On first launch `device_context` and `push_token_registered` are queued milliseconds apart. An
 append that read the stored array before the other had written it back would write over it and
 erase the other event. Losing `device_context` in particular costs more than one event: it is
 what makes the device known to Treebars, and a device Treebars does not know can be missed by a
 scheduled send for as long as the app is installed.

 The Android core guards its queue with a `Mutex` and this core makes it an `actor` — two
 mechanisms for one property, which is why the property is what these tests assert rather than
 the mechanism.

 **Isolation is by filename, not by directory.** `EventQueue.init` takes only a `filename` and
 resolves the directory itself (Application Support), so a test cannot point it at a temporary
 directory; each queue below gets a UUID filename in the real location and `tearDown` removes it.
 A fixed name would mean every test in this file loading whatever the previous one left, and the
 first assertion to fail would be about the wrong events entirely.

 There is no test that a failed write reaches the caller: `append` does not throw and `persist()`
 swallows its write error with `try?`, so there is no failure surface to test, and inventing one
 would mean changing production code.
 */
final class EventQueueTests: XCTestCase {

    /// Where `EventQueue` resolves its file to, computed the same way it does so tearDown can
    /// find what the tests wrote.
    private static let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first ?? URL(fileURLWithPath: NSTemporaryDirectory())

    private var filenames: [String] = []

    override func tearDown() {
        for filename in filenames {
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(filename))
        }
        filenames = []
        super.tearDown()
    }

    private func makeQueue() -> EventQueue {
        let filename = "treebars-queue-test-\(UUID().uuidString).json"
        filenames.append(filename)
        return EventQueue(filename: filename)
    }

    /// The shape `Treebars.build` produces, carrying the fields these assertions read.
    ///
    /// Built inside each task rather than handed to one: `[String: Any]` is not `Sendable`, and
    /// a `String` name is.
    private static func event(_ name: String) -> [String: Any] {
        [
            "event_id": UUID().uuidString,
            "session_id": "s1",
            "device_id": "d1",
            "event_name": name,
            "properties": [String: Any](),
            "timestamp": "2026-08-22T12:00:00.000Z",
            "sdk_version": TreebarsConstants.sdkVersion,
            "sdk_name": TreebarsConstants.sdkName,
        ]
    }

    private func names(_ events: [[String: Any]]) -> [String] {
        events.compactMap { $0["event_name"] as? String }
    }

    /// Two events queued milliseconds apart from unrelated callers.
    ///
    /// Asserted as a set, and that is not laziness: the order in which two tasks reach an actor
    /// is the runtime's business, so pinning it here would be pinning a coin toss. Ordering is
    /// asserted where it is actually promised, below.
    func testTwoAppendsThatOverlapBothSurvive() async {
        let queue = makeQueue()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await queue.append(Self.event("device_context")) }
            group.addTask { await queue.append(Self.event("push_token_registered")) }
        }

        let queued = names(await queue.peek(10))

        XCTAssertEqual(
            Set(queued),
            ["device_context", "push_token_registered"],
            """
            One append overwrote the other: the losing event is gone before any flush sees it, and \
            if it was device_context Treebars never learns this device exists.
            """
        )
        XCTAssertEqual(queued.count, 2, "and neither was written twice")
    }

    /// The same property under load, plus the FIFO order everything else depends on.
    ///
    /// The two halves are separate on purpose. Concurrent appends prove nothing is lost; sequential
    /// appends prove `peek` hands back the oldest first, which is the half `remove` relies on and
    /// the half the runtime actually guarantees.
    func testABurstOfAppendsKeepsEveryEventAndPeekReturnsThemOldestFirst() async {
        let raced = makeQueue()
        let expected = (0..<25).map { "event_\($0)" }

        await withTaskGroup(of: Void.self) { group in
            for name in expected {
                group.addTask { await raced.append(Self.event(name)) }
            }
        }

        let queued = names(await raced.peek(50))
        XCTAssertEqual(Set(queued), Set(expected), "every event of the burst is still here")
        XCTAssertEqual(queued.count, 25, "and each exactly once")
        let racedCount = await raced.count
        XCTAssertEqual(racedCount, 25)

        let ordered = makeQueue()
        for name in expected {
            await ordered.append(Self.event(name))
        }

        let inOrder = names(await ordered.peek(50))
        XCTAssertEqual(
            inOrder,
            expected,
            "peek is oldest-first, which is what makes remove(n) safe to run against a live queue"
        )
    }

    /// What an upload does: take a batch, then drop exactly that many — while the app keeps
    /// tracking.
    ///
    /// The late arrival must outlive the removal, and it does so for a reason that holds whichever
    /// side wins: the queue is FIFO, so an event appended during an upload sits *behind* the ones
    /// being dropped. Both interleavings have to end at the same answer, which is why this one is
    /// not a coin toss.
    func testRemovingABatchWhileAnotherEventArrivesDropsOnlyTheBatch() async {
        let queue = makeQueue()
        await queue.append(Self.event("first"))
        await queue.append(Self.event("second"))

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await queue.remove(2) }
            group.addTask { await queue.append(Self.event("during_upload")) }
        }

        let survivors = names(await queue.peek(10))
        XCTAssertEqual(
            survivors,
            ["during_upload"],
            "the batch went and the event that arrived during the upload stayed"
        )
    }

    /// The cap.
    ///
    /// A device offline for a week would otherwise grow its file without bound. Dropping the
    /// oldest is the deliberate choice: recent behaviour is worth more than stale behaviour, and
    /// the alternative once full is recording nothing at all.
    func testTheQueueCapsAtQueueCapAndDropsTheOldestFirst() async {
        let queue = makeQueue()
        let overflow = 5

        for index in 0..<(TreebarsConstants.queueCap + overflow) {
            await queue.append(Self.event("event_\(index)"))
        }

        let capped = await queue.count
        XCTAssertEqual(capped, TreebarsConstants.queueCap, "the cap holds")

        let queued = names(await queue.peek(TreebarsConstants.queueCap + overflow))
        XCTAssertEqual(queued.first, "event_\(overflow)", "the oldest five are the ones that went")
        XCTAssertEqual(
            queued.last,
            "event_\(TreebarsConstants.queueCap + overflow - 1)",
            "and the newest event is still the last one in"
        )
        XCTAssertFalse(queued.contains("event_0"), "the very first event is gone, not the latest")
    }
}
