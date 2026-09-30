import XCTest
@testable import TreebarsSDK

/**
 Sessionisation.

 The injectable clock is what makes these cases reachable at all: a thirty-minute timeout cannot be
 exercised in thirty minutes, so without one the only reachable cases are "a session opens" and
 "a second touch continues it" — which `HarnessTests` already covers. Note the unit. Swift's clock is in **seconds** and Kotlin's is in
 milliseconds, deliberately, because each matches its platform's own epoch; the `durationMs` this
 manager reports is milliseconds either way.

 There is no shape in which this manager has nowhere to write — `UserDefaults` is always there —
 so there is no in-memory fallback to assert. And there is no `restore()`: the manager reads
 `UserDefaults` on every touch, so a relaunch resumes by construction — which is why the two
 relaunch cases below build a second manager over the same store and do nothing else.
 */
final class SessionManagerTests: XCTestCase {

    /// The five keys `SessionManager` writes. Private over there, so spelled out here — the same
    /// arrangement `HarnessTests` lives with.
    private static let keys = [
        "treebars.session.id",
        "treebars.session.started_at",
        "treebars.session.last_activity",
        "treebars.session.event_count",
        "treebars.session.ever_started",
    ]

    /// A fixed instant, 2026-08-23T09:00:00Z, in this platform's unit.
    private static let epoch: TimeInterval = 1_787_475_600

    private let timeout = TreebarsConstants.sessionTimeout

    /// A clock a test can move, and the store it moves time against.
    ///
    /// A class rather than a captured `var` so the two managers in a relaunch case share one
    /// instant by reference: the point of that case is that the second manager sees the time the
    /// first one wrote against, and a boxed copy would quietly make it see something else.
    private final class TestClock {
        private(set) var now: TimeInterval
        init(at now: TimeInterval) { self.now = now }
        func advance(_ seconds: TimeInterval) { now += seconds }
    }

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // A suite per test, not `UserDefaults.standard`: sessions persist by design, so two tests
        // sharing a store would hand the second one the first one's relaunch.
        suiteName = "treebars.tests.session.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func manager(_ clock: TestClock) -> SessionManager {
        SessionManager(defaults: defaults, clock: { clock.now })
    }

    func testActivityInsideTheTimeoutContinuesTheSameSession() async {
        let sessions = manager(TestClock(at: Self.epoch))

        let first = await sessions.touch()
        let second = await sessions.touch()

        XCTAssertTrue(first.isNew)
        XCTAssertTrue(first.isFirstSession)
        XCTAssertFalse(second.isNew)
        XCTAssertEqual(second.sessionId, first.sessionId)
        XCTAssertNil(second.expired)
    }

    /*
     The retroactive end. A session cannot be closed at the moment the app is backgrounded — the
     user may be back in ten seconds, and the timeout says that is the same session — so the close
     is only recognisable once the next activity turns out to be past the gap.
     */
    func testAGapPastTheTimeoutEndsTheOldSessionAndBackdatesTheEnd() async throws {
        let clock = TestClock(at: Self.epoch)
        let sessions = manager(clock)

        let first = await sessions.touch()
        clock.advance(60)
        _ = await sessions.touch()

        let lastActivity = clock.now
        clock.advance(timeout + 1)
        let reopened = await sessions.touch()

        XCTAssertTrue(reopened.isNew)
        XCTAssertNotEqual(reopened.sessionId, first.sessionId)
        XCTAssertFalse(reopened.isFirstSession)

        let expired = try XCTUnwrap(reopened.expired)
        XCTAssertEqual(expired.id, first.sessionId)
        XCTAssertEqual(expired.eventCount, 2)
        XCTAssertEqual(expired.durationMs, 60_000, "seconds in, milliseconds out")
        // The session's own last moment, not the moment the app came back.
        XCTAssertEqual(expired.endedAt, lastActivity)
    }

    /*
     The reason this is persisted at all. A person who comes back inside the timeout is in the same
     session whether or not the process died in between, so a session id kept only in memory would
     count two sessions where there was one.
     */
    func testARelaunchInsideTheTimeoutResumesThePreviousProcessSession() async {
        let clock = TestClock(at: Self.epoch)

        let before = manager(clock)
        let original = await before.touch()

        clock.advance(5 * 60)

        let after = manager(clock)
        let resumed = await after.touch()

        XCTAssertEqual(resumed.sessionId, original.sessionId)
        XCTAssertFalse(resumed.isNew)
        XCTAssertNil(resumed.expired)
    }

    func testARelaunchPastTheTimeoutIsANewSessionAndNotAFirstOne() async {
        let clock = TestClock(at: Self.epoch)

        let before = manager(clock)
        let original = await before.touch()

        clock.advance(timeout + 1)

        let after = manager(clock)
        let next = await after.touch()

        XCTAssertNotEqual(next.sessionId, original.sessionId)
        XCTAssertTrue(next.isNew)
        // The install has been used before, so this is not the first session on it.
        XCTAssertFalse(next.isFirstSession)
        XCTAssertEqual(next.expired?.id, original.sessionId)
    }

    /*
     Logout has to take the stored record with it. Leaving it would hand the next person to sign in
     on this device the previous one's session id, stitching two people's activity into a single
     session.
     */
    func testResetClearsThePersistedSessionSoTheNextSignInStartsClean() async {
        let clock = TestClock(at: Self.epoch)
        let sessions = manager(clock)

        let first = await sessions.touch()
        await sessions.reset()

        XCTAssertNil(defaults.string(forKey: "treebars.session.id"))

        let next = await sessions.touch()
        XCTAssertNotEqual(next.sessionId, first.sessionId)
        XCTAssertNil(next.expired)

        // `reset()` keeps the first-session flag, so the session after a logout does not claim to be
        // the install's first. The handset has been used; only the person has changed.
        XCTAssertFalse(next.isFirstSession)
    }

    /*
     A record written by a version that shaped it differently is treated as no record. The record is
     five typed keys, so the corruption available is a value of the wrong type. Read it, do not throw
     on it, and pay one extra session boundary.
     */
    func testAMalformedStoredRecordIsTreatedAsNoRecord() async {
        let garbage = Data("{not json".utf8)
        defaults.set(garbage, forKey: "treebars.session.id")
        defaults.set(garbage, forKey: "treebars.session.started_at")
        defaults.set("not a timestamp", forKey: "treebars.session.last_activity")
        defaults.set(garbage, forKey: "treebars.session.event_count")

        let sessions = manager(TestClock(at: Self.epoch))
        let touched = await sessions.touch()

        XCTAssertTrue(touched.isNew)
        XCTAssertNil(touched.expired)
        XCTAssertTrue(touched.sessionId.hasPrefix("sess_"))
    }
}
