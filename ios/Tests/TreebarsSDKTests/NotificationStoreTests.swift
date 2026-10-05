import XCTest
@testable import TreebarsSDK

/**
 The one part of the notification centre with logic in it: reconciling what this device just
 did with what the server last said.

 Worth holding here rather than trusting an end-to-end run, because every failure is a screen
 that looks fine. A missing overlay makes a
 tap appear to do nothing and then undo itself on the next refresh. A ledger entry that is
 never dropped makes a row read as read forever, including after somebody's account changed
 hands. And an owner check that runs only in `reset()` draws one person's notifications under
 another person's name.

 `NotificationStore` holds `UserDefaults.standard` rather than taking a store, so a shared store
 would carry one `noteDismissed` into every test after it. Isolation costs a clear of these two
 keys either side of every test — and a store constructed *after* that clear, since the load
 happens in `init()` and not in a `load()` a test can await.
 */
final class NotificationStoreTests: XCTestCase {

    private static let keys = ["treebars.notifications", "treebars.notification_ledger"]

    private var store: NotificationStore!

    override func setUp() {
        super.setUp()
        Self.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        store = NotificationStore()
    }

    override func tearDown() {
        store = nil
        Self.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    private func notification(
        groupID: String = "grp_1",
        createdAt: String = "2026-08-01T00:00:00.000Z",
        readAt: String? = nil
    ) -> TreebarsNotification {
        TreebarsNotification(
            group_id: groupID,
            campaign_id: "cmp_1",
            channel_type: "push",
            device_count: 1,
            content: TreebarsNotificationContent(
                title: "Hello",
                body: "There",
                image_url: nil,
                deep_link: nil,
                in_app: nil
            ),
            created_at: createdAt,
            read_at: readAt,
            opened_at: nil,
            expires_at: nil,
            style: nil
        )
    }

    private func page(_ notifications: [TreebarsNotification], unread: Int? = nil) -> NotificationPage {
        NotificationPage(
            notifications: notifications,
            unreadCount: unread ?? notifications.count,
            nextCursor: nil,
            fromCache: false
        )
    }

    // MARK: - the overlay

    func testReadsALocallyMarkedRowAsReadBeforeTheServerHasHeard() {
        // The whole point. Without this a tap sets a row from bold to plain, the next refresh
        // sets it back, and the person taps again.
        store.noteRead("grp_1")
        XCTAssertNotNil(store.overlay([notification()])[0].read_at)
    }

    func testHidesALocallyDismissedRow() {
        store.noteDismissed("grp_1")
        XCTAssertEqual(store.overlay([notification()]).count, 0)
    }

    func testLeavesEverythingElseAlone() {
        let rows = store.overlay([notification(), notification(groupID: "grp_2")])
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.read_at == nil })
    }

    func testAppliesAMarkAllWatermarkByTimeNotById() {
        // A list of ids cannot express somebody returning to nine hundred unread. The
        // watermark covers rows this device has never seen, which is why it is an instant.
        store.noteReadThrough("2026-08-02T00:00:00.000Z")
        let rows = store.overlay([
            notification(groupID: "before", createdAt: "2026-08-01T00:00:00.000Z"),
            notification(groupID: "after", createdAt: "2026-08-03T00:00:00.000Z"),
        ])
        guard let before = rows.first(where: { $0.group_id == "before" }),
              let after = rows.first(where: { $0.group_id == "after" })
        else { return XCTFail("the watermark dropped a row it should only have marked") }

        XCTAssertNotNil(before.read_at)
        XCTAssertNil(after.read_at)
    }

    func testCountsAgainstTheServersRowsNotTheOverlaidOnes() {
        // The subtraction asks "how many rows the server still calls unread have we marked",
        // which is unanswerable once overlay has stamped read_at on them. Passing the overlaid
        // list leaves the badge on the server's number while the rows read as read.
        store.noteRead("grp_1")
        XCTAssertEqual(store.overlayCount(1, [notification()]), 0)
        XCTAssertEqual(store.overlayCount(1, store.overlay([notification()])), 1)
    }

    func testNeverGoesNegative() {
        // The server has already counted a mark it confirmed; subtracting it again shows -1.
        XCTAssertEqual(store.overlayCount(0, [notification(readAt: "x")]), 0)
    }

    // MARK: - the ledger

    func testDropsAnEntryOnceTheServerAgreesWithIt() {
        store.noteRead("grp_1")
        store.accept(owner: "user_a", page: page([notification(readAt: "2026-08-01T00:00:01.000Z")], unread: 0))

        // The row now says read on its own, so the ledger has nothing left to assert — and an
        // entry kept forever would keep asserting it after the account changed hands.
        let cached = store.cached()
        XCTAssertEqual(cached?.notifications[0].read_at, "2026-08-01T00:00:01.000Z")
        XCTAssertEqual(cached?.unreadCount, 0)
    }

    func testForgetsADismissalOnceTheRowIsGoneFromTheAnswer() {
        store.noteDismissed("grp_1")
        store.accept(owner: "user_a", page: page([notification(groupID: "grp_2")]))
        // Dismissed rows do not come back in the server's list, so absence IS agreement.
        XCTAssertEqual(store.cached()?.notifications.map(\.group_id), ["grp_2"])
    }

    // MARK: - the owner check

    func testClearsTheFeedAndTheLedgerWhenTheAccountChanges() {
        store.accept(owner: "user_a", page: page([notification(groupID: "a_only")]))
        store.noteRead("a_only")

        // identify(b) without an intervening reset(). This is the case that runs on every
        // accept rather than only in reset(), and the reason is right here: otherwise b reads
        // a's notifications, with a's read marks on them.
        store.accept(owner: "user_b", page: page([notification(groupID: "b_only")]))

        guard let handedOver = store.cached() else { return XCTFail("b has no feed at all") }
        XCTAssertEqual(handedOver.notifications.map(\.group_id), ["b_only"])
        XCTAssertNil(handedOver.notifications[0].read_at)

        // This package exposes no reader for the recorded owner, so it is checked the only way it
        // is observable from outside — a third accept for b that does NOT clear the mark just made
        // under b.
        store.noteRead("b_only")
        store.accept(owner: "user_b", page: page([notification(groupID: "b_only")]))
        XCTAssertNotNil(store.cached()?.notifications[0].read_at)
    }

    func testKeepsTheFeedForTheSameAccount() {
        store.accept(owner: "user_a", page: page([notification()]))
        store.noteRead("grp_1")
        store.accept(owner: "user_a", page: page([notification()]))
        XCTAssertNotNil(store.cached()?.notifications[0].read_at)
    }

    // MARK: - the cache

    func testDoesItsUnreadArithmeticAgainstTheWholePageItWasGiven() {
        /*
         * Only visible on a device. `markAllRead()` and `unreadCount()` both fetch ONE row —
         * the first only to learn the server's clock. A one-row probe cached over the real
         * first page would have the count computed against that single row: the badge reading
         * "2 unread" beside a list where every row is already marked read.
         *
         * The store's half of the contract is this: whatever page it accepts is the page it
         * counts against. The SDK's half — cache only a page with no cursor AND no explicit
         * limit — lives in `Treebars.swift`.
         */
        let rows = [
            notification(groupID: "a"),
            notification(groupID: "b"),
            notification(groupID: "c"),
        ]
        store.accept(owner: "user_a", page: page(rows, unread: 3))
        store.noteReadThrough(Iso8601.now())

        XCTAssertEqual(store.cached()?.unreadCount, 0)

        // A one-row page accepted over it can only account for one row, which is exactly why
        // the SDK must not hand it one.
        store.accept(owner: "user_a", page: page([rows[0]], unread: 3))
        XCTAssertEqual(store.cached()?.unreadCount, 2)
    }

    func testAnswersNothingBeforeAnythingHasBeenFetched() {
        XCTAssertNil(store.cached())
    }

    func testIsFlaggedAsCachedSoAScreenCanSaySoRatherThanImplyARoundTrip() {
        store.accept(owner: "user_a", page: page([notification()]))
        XCTAssertEqual(store.cached()?.fromCache, true)
    }

    func testIsEmptiedByResetBecauseAHistoryBelongsToThePerson() {
        store.accept(owner: "user_a", page: page([notification()]))
        store.reset()
        XCTAssertNil(store.cached())
    }

    /// `cached()` hands its page over without asking whose it is, so somebody else signing in with no sign-out between
    /// has to empty it then — not at the next fetch, which may never land — along with the last person's marks and a
    /// page still in flight for them.
    func testIsEmptiedWhenSomebodyElseSignsInBecauseTheCacheAnswersWithoutAskingWhose() {
        store.accept(owner: "user_a", page: page([notification(groupID: "a_only")]))
        store.noteDismissed("b_only")
        let asked = store.generation

        store.supersede()

        XCTAssertNil(store.cached())
        XCTAssertNil(NotificationStore().cached())
        XCTAssertFalse(store.accept(owner: "user_a", page: page([notification(groupID: "a_only")]), askedAt: asked))
        XCTAssertNil(store.cached())
        // A mark the last person made hides nothing of the next person's.
        XCTAssertEqual(store.overlay([notification(groupID: "b_only")]).count, 1)
    }

    /// The owner is read when the answer lands, so a page asked for before a sign-out must not be filed as the device's.
    func testDropsAFirstPageAskedForBeforeASignOut() {
        let asked = store.generation
        store.reset()
        XCTAssertFalse(store.accept(owner: "device_1", page: page([notification()]), askedAt: asked))
        XCTAssertNil(store.cached())
    }
}
