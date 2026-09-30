import XCTest
@testable import TreebarsSDK

/**
 The two gates that decide whether this device says anything about itself.

 **The context TTL.** `device_context` is what makes the device known to Treebars, and the SDK
 suppresses it once it has been sent while the description is unchanged. What the server holds
 can go away without the handset seeing it — a project reset, a privacy erase — and a device that
 never reported again would stay unknown while it carried on sending events, and could be missed
 by every scheduled send. Nothing on the device can notice that, so the week-long TTL is what
 asks it to report again.

 **The permission transition.** `notification_permission_changed` is a thing that happened at a
 moment in time; it is not derivable from the state that follows it, which is why the event exists
 at all — the device's attributes say who is reachable now, and only this says how many people
 turned notifications off last month. A fabricated one is therefore worse than a missing one, and
 there is exactly one way to fabricate them across a whole fleet: treat a value the SDK has not
 learned yet as one it just saw change.

 `shouldReportContext` only asks; `rememberReportedContext` records, once the report is made. The
 record stores `timeIntervalSince1970`, so seconds, and these tests seed it and read it back rather
 than passing a clock.
 */
final class DeviceContextTests: XCTestCase {

    /*
     * Spelled out rather than read from `TreebarsConstants`, which is where the SDK gets them.
     * A storage key is not a shared value: changing one migrates nothing, it points the SDK at an
     * empty address and every install in the field silently becomes a new anonymous device. A test
     * that read the constant would follow such a change without a word.
     */
    private static let contextKey = "treebars.device_context_hash"
    private static let permissionKey = "treebars.notification_permission"
    private static let keys = [contextKey, permissionKey]

    private let day: TimeInterval = 24 * 60 * 60

    override func setUp() {
        super.setUp()
        Self.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        Self.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    private var storedContext: String? {
        UserDefaults.standard.string(forKey: Self.contextKey)
    }

    /// A report of `hash` made `age` ago, in the shape `shouldReportContext` writes.
    private func seedContext(_ hash: String, reportedAgo age: TimeInterval) {
        UserDefaults.standard.set("\(hash):\(Date().timeIntervalSince1970 - age)", forKey: Self.contextKey)
    }

    // MARK: - The context report TTL

    func testAnUnchangedContextReportedTodayIsNotReportedAgain() {
        seedContext("aaaa", reportedAgo: day)
        let untouched = storedContext

        XCTAssertFalse(DeviceInfo.shouldReportContext("aaaa"))
        XCTAssertEqual(storedContext, untouched, "a suppressed report must not refresh its own deadline")
    }

    /// The hash is the first question and the age only the second: a device whose description
    /// moved has something new to say however recently it last spoke.
    func testAChangedContextIsReportedHoweverRecentlyTheLastOneWent() {
        seedContext("aaaa", reportedAgo: 60)

        XCTAssertTrue(DeviceInfo.shouldReportContext("bbbb"))
        XCTAssertEqual(
            storedContext?.split(separator: ":").first.map(String.init),
            "aaaa",
            "asking does not write — the old record stands until the report is actually made"
        )

        DeviceInfo.rememberReportedContext("bbbb")
        XCTAssertEqual(
            storedContext?.split(separator: ":").first.map(String.init),
            "bbbb",
            "the record now names what was reported, not what it replaced"
        )
    }

    /// The repair: the TTL is what asks an unchanged device to report again.
    func testAnUnchangedContextGoesAgainOnceTheReportIsAWeekOld() {
        seedContext("aaaa", reportedAgo: 6 * day)
        XCTAssertFalse(DeviceInfo.shouldReportContext("aaaa"))

        seedContext("aaaa", reportedAgo: 8 * day)
        XCTAssertTrue(DeviceInfo.shouldReportContext("aaaa"))
    }

    /// Cheaper than a migration, and the outcome is the same by the next launch: one redundant
    /// report buys a record in the current shape.
    func testARecordFromBeforeTheTimestampReReportsOnceWhichRefreshesIt() {
        UserDefaults.standard.set("aaaa", forKey: Self.contextKey)

        XCTAssertTrue(DeviceInfo.shouldReportContext("aaaa"))
        DeviceInfo.rememberReportedContext("aaaa")
        XCTAssertFalse(DeviceInfo.shouldReportContext("aaaa"), "and the record it wrote is a current one")
    }

    /// A timestamp that will not parse is treated as no timestamp at all rather than as the epoch,
    /// which would read as a report from 1970 and re-report on every launch forever.
    func testAnUnparseableTimestampReReportsOnceTheSameWay() {
        UserDefaults.standard.set("aaaa:not-a-number", forKey: Self.contextKey)

        XCTAssertTrue(DeviceInfo.shouldReportContext("aaaa"))
        DeviceInfo.rememberReportedContext("aaaa")
        XCTAssertFalse(DeviceInfo.shouldReportContext("aaaa"))
    }

    func testNothingStoredMeansNothingHasBeenReported() {
        XCTAssertTrue(DeviceInfo.shouldReportContext("aaaa"))
    }

    /**
     The report is recorded separately, so a lost one is retried.

     If asking closed the question — the hash stored before the event existed — a
     `device_context` that then failed to enqueue would leave the device suppressed for the whole
     seven-day TTL, having never reported once, and nothing could tell that from a device whose
     context genuinely had not changed.
     */
    func testTheReportIsRecordedSeparatelySoALostOneIsRetried() {
        XCTAssertTrue(DeviceInfo.shouldReportContext("deadbeef"))
        XCTAssertNil(storedContext, "asking alone records nothing")

        // Asked again, and still true: nothing was spent by the question.
        XCTAssertTrue(DeviceInfo.shouldReportContext("deadbeef"))

        DeviceInfo.rememberReportedContext("deadbeef")

        let parts = (storedContext ?? "").split(separator: ":")
        XCTAssertEqual(parts.first.map(String.init), "deadbeef")
        XCTAssertEqual(
            parts.last.flatMap { TimeInterval($0) } ?? 0,
            Date().timeIntervalSince1970,
            accuracy: 5,
            "stamped when the report was made, which is what starts the week"
        )
        XCTAssertFalse(DeviceInfo.shouldReportContext("deadbeef"))
    }

    // MARK: - The notification permission transition

    /**
     Only the "nothing to say" half of the permission cases is reachable from here, and the
     reason is structural rather than an omission.

     `pendingPermissionChange` reads `cachedNotificationPermission`, whose only writer is
     `refreshNotificationPermission` → `UNUserNotificationCenter.current()`. That call raises
     `bundleProxyForCurrentProcess is nil` inside an SPM test bundle, which has no host app, and
     the backing `storedPermission` is `private` with no setter. So the current permission cannot
     be given a value from a test at all, and the four cases that need one — first observation is
     not a change, a flip names both ends, an unchanged value stays silent however often it is
     asked, and the record is written before the event is emitted — have no way to run. They are
     listed here so the gap reads as a missing seam rather than as a family nobody thought about.

     What IS reachable is the guard those four sit behind, and it is the one carrying the
     fleet-wide risk: on iOS "not yet known" is `nil`, and `nil` is not `not_determined`.
     `not_determined` is a real answer a person's device gave and is not ours to manufacture.
     */
    func testNotYetKnownIsNoChangeAndNoRecord() {
        XCTAssertNil(
            DeviceInfo.cachedNotificationPermission,
            """
            The permission cache is populated, which this test bundle was not able to do. If a host \
            app or a test seam has arrived, the four permission transitions are reachable now and \
            this test is not covering the branch it names.
            """
        )

        XCTAssertNil(DeviceInfo.pendingPermissionChange())
        XCTAssertNil(
            UserDefaults.standard.string(forKey: Self.permissionKey),
            "a value the SDK has not learned yet must not be recorded as one it observed"
        )
    }

    /// The same guard from the far side, and the expensive way to get it wrong.
    ///
    /// Defaulting the unknown current value to `not_determined` — the obvious tidy-up — would read
    /// every launch whose settings callback had not landed yet as a fresh opt-out, on every device
    /// that had ever reported `authorized`. Reachable state, whole-fleet blast radius, and the resulting series would be
    /// indistinguishable from people really turning notifications off.
    func testNotYetKnownDoesNotFabricateATransitionAwayFromAKnownValue() {
        UserDefaults.standard.set("authorized", forKey: Self.permissionKey)

        XCTAssertNil(DeviceInfo.pendingPermissionChange())
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: Self.permissionKey),
            "authorized",
            "the last thing this device actually observed still stands"
        )
    }
}
