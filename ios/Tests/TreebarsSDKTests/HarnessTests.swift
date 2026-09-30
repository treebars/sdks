import XCTest
@testable import TreebarsSDK

/**
 Proves the test harness, not the SDK: that `@testable import` reaches the `internal` types and
 that an `actor` can be exercised from XCTest.

 It also pins the thing that makes running these on the wrong destination silently useless: every
 UIKit path in this target is behind `#if canImport(UIKit)`, so on macOS the package compiles a
 different branch — os_name "macOS", device_type "desktop", no screen metrics, no lifecycle
 observer. A green run there says nothing about the shipping code.

 `SessionManager` holds `private let defaults = UserDefaults.standard` rather than taking a store,
 so isolating it means clearing its keys from the process-wide defaults before and after each case.
 */
final class HarnessTests: XCTestCase {

    private static let keys = [
        "treebars.session.id",
        "treebars.session.started_at",
        "treebars.session.last_activity",
        "treebars.session.event_count",
        "treebars.session.ever_started",
    ]

    override func setUp() {
        super.setUp()
        Self.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        Self.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    func testSessionManagerOpensAndThenContinuesASession() async {
        let sessions = SessionManager()

        let first = await sessions.touch()
        XCTAssertTrue(first.isNew, "the first touch opens a session")
        XCTAssertTrue(first.isFirstSession, "and it is the first this install has had")

        let second = await sessions.touch()
        XCTAssertFalse(second.isNew, "a touch inside the timeout continues it")
        XCTAssertEqual(first.sessionId, second.sessionId, "and keeps the same id")
        XCTAssertNil(second.expired, "nothing has aged out yet")
    }

    func testTheSuiteIsRunningAgainstUIKitAndNotTheMacOSBranch() {
        #if canImport(UIKit)
        XCTAssertTrue(true)
        #else
        XCTFail("""
            Running where canImport(UIKit) is false. Every device fact this SDK reports comes from \
            the other branch, so a green run here proves nothing about the shipping code. Use \
            -destination 'platform=iOS Simulator,…'.
            """)
        #endif
    }
}
