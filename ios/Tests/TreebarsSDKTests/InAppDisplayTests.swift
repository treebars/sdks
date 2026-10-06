import XCTest
@testable import TreebarsSDK

/**
 `in_app_display` on `device_context`: what draws this app's in-app messages — this SDK (`sdk`), the
 app's own renderer (`app`), or nothing (`off`).

 It is the one value in the context the app's own code sets, usually a moment after `initialize`, so
 what these pin is as much *when* it is reported as *what*. The wait that decides when is
 `ContextSettle`, run here on its own with a wait short enough to sit through: one report for a
 description that stood, none for one that changed back, and none while the app is not in front.
 */
final class InAppDisplayTests: XCTestCase {

    private static let contextKey = "treebars.device_context_hash"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.contextKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.contextKey)
        super.tearDown()
    }

    // MARK: - What it says

    func testTheThreeAnswers() {
        XCTAssertEqual(DeviceInfo.inAppDisplay(enabled: true, ownRenderer: false), "sdk", "on, and nothing registered: this SDK draws")
        XCTAssertEqual(DeviceInfo.inAppDisplay(enabled: true, ownRenderer: true), "app", "on, and the app registered its own renderer")
        XCTAssertEqual(DeviceInfo.inAppDisplay(enabled: false, ownRenderer: false), "off", "switched off")
        XCTAssertEqual(DeviceInfo.inAppDisplay(enabled: false, ownRenderer: true), "off", "switched off, whatever renderer is also registered")
    }

    /// The shared cases every Treebars SDK hashes alike, so a key added to the context is hashed the
    /// same way everywhere.
    func testItIsHashedAsTheOtherSDKsHashIt() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/device-context-hash.json")
        let fixture = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], "the shared fixture is missing or malformed"
        )
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)

        var seen: [String: String] = [:]
        for spec in cases {
            let name = spec["name"] as? String ?? ""
            let context = try XCTUnwrap(spec["context"] as? [String: String], name)
            let hash = try XCTUnwrap(spec["hash"] as? String, name)
            XCTAssertEqual(DeviceInfo.hashContext(context), hash, name)
            if context["app_id"] != nil { seen[context["in_app_display"] ?? "absent"] = hash }
        }
        XCTAssertEqual(Set(seen.keys), ["sdk", "app", "off", "absent"])
        XCTAssertEqual(Set(seen.values).count, 4, "one hash for each answer, and one for a context without the key")
    }

    func testADeviceThatHasNeverReportedIsToldApartFromOneThatHas() {
        XCTAssertFalse(DeviceInfo.hasReportedContext())
        DeviceInfo.rememberReportedContext("aaaa")
        XCTAssertTrue(DeviceInfo.hasReportedContext())
        DeviceInfo.forgetReportedContext()
        XCTAssertFalse(DeviceInfo.hasReportedContext())
    }

    // MARK: - When it says it

    /// What a wait did, counted where any thread may count it.
    private final class Record: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var front = true

        var reports: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        var inFront: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return front
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                front = newValue
            }
        }

        func reported() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
        }
    }

    private static let wait: TimeInterval = 0.2

    private func settle(_ record: Record) -> ContextSettle {
        ContextSettle(wait: Self.wait, inFront: { record.inFront }, report: { record.reported() })
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Long enough for a wait to have ended, and its report to have been made, several times over.
    private func outlast() async {
        await pause(Self.wait * 4)
    }

    func testADescriptionIsReportedOnceItHasStoodAndNotBefore() async {
        let record = Record()
        let settle = settle(record)

        settle.start()
        await pause(Self.wait / 4)
        XCTAssertEqual(record.reports, 0, "nothing while it has stood for less than the wait")
        await outlast()
        XCTAssertEqual(record.reports, 1)
        await outlast()
        XCTAssertEqual(record.reports, 1, "once, not once per wait")
    }

    /// A launch, then the app's own answer a moment later, then a host remounting: three starts, and
    /// the gate is asked once, about what stood at the end.
    func testEveryStartInsideTheWaitIsOneReportCountedFromTheLast() async {
        let record = Record()
        let settle = settle(record)

        settle.start()
        await pause(Self.wait / 2)
        settle.start()
        await pause(Self.wait / 2)
        settle.start()
        await pause(Self.wait / 2)
        XCTAssertEqual(record.reports, 0, "the first start's wait has passed, and it was replaced")
        await outlast()
        XCTAssertEqual(record.reports, 1)
    }

    func testAWaitThatEndsWithTheAppNotInFrontReportsNothingUntilItIs() async {
        let record = Record()
        let settle = settle(record)

        // The app is left, and its host takes the renderer with it.
        record.inFront = false
        settle.start()
        await outlast()
        XCTAssertEqual(record.reports, 0, "not described for having been left")

        // It comes back: the description waits again, and is reported as it stands then.
        record.inFront = true
        settle.cameToFront()
        await pause(Self.wait / 4)
        XCTAssertEqual(record.reports, 0, "after the wait, not at the return")
        await outlast()
        XCTAssertEqual(record.reports, 1)

        // And a later return, with nothing owed, starts nothing.
        settle.cameToFront()
        await outlast()
        XCTAssertEqual(record.reports, 1)
    }

    func testAStoppedWaitReportsNothingAndIsNotOwed() async {
        let record = Record()
        let settle = settle(record)

        settle.start()
        settle.stop()
        await outlast()
        XCTAssertEqual(record.reports, 0)

        record.inFront = false
        settle.start()
        await outlast()
        settle.stop()
        record.inFront = true
        settle.cameToFront()
        await outlast()
        XCTAssertEqual(record.reports, 0, "a wipe forgets the report that was owed as well")
    }
}
