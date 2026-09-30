import XCTest
@testable import TreebarsSDK

/**
 The handoff: what the device accepts off a clipboard, and what it does with it.

 The pasteboard itself cannot be exercised here — `UIPasteboard` needs a device — so the source is
 faked and what is under test is the decision around it, which is where every way of getting this
 wrong lives. A value accepted that is not ours routes the app somewhere the link never named; a
 value refused that is ours loses the only deterministic answer iPhone has.

 Disagreements are collected and asserted once, as in `UploaderScenariosTests`: on the simulator
 an async test records only its first failed assertion.
 */
/// Collects what was sent, across tasks — a plain array would be a data race in this suite's one
/// concurrent case, which is the case most worth having. A lock rather than an actor because the
/// capture's `send` is a synchronous closure, and making it async to suit a test would change the
/// thing under test.
private final class Sent: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [[String: Any]] = []
    func add(_ event: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
    }
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return events.count
    }
}

final class HandoffTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "handoff-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private let clickId = "jbhhcnhilbwjtgt5ea60e8"

    // MARK: - What may be read off a clipboard

    func testReadsOurLinkWithItsClickIdAndPath() {
        let claim = parseHandoff("https://tbrs.cc/spring?tbrs_click_id=\(clickId)&tbrs_deep_link=/sale/summer")
        XCTAssertEqual(claim?.clickId, clickId)
        XCTAssertEqual(claim?.deepLinkPath, "/sale/summer")
    }

    func testKeepsTheClickIdWhenThePathIsNotOne() {
        // The click id is the part that measures and the path is the part that routes. Losing the
        // second must not lose the first.
        let claim = parseHandoff("https://tbrs.cc/spring?tbrs_click_id=\(clickId)&tbrs_deep_link=https://evil.example/x")
        XCTAssertEqual(claim?.clickId, clickId)
        XCTAssertNil(claim?.deepLinkPath)
    }

    func testRefusesEverythingThatIsNotOurs() {
        /*
         A pasteboard is a text box every app on the device can write, and the app routes on what
         this returns. A scheme that is not http would hand a link's settings field a way out of the
         app; an id that is not in the shape Treebars issues names no click and could only ever be a guess.
         */
        var problems: [String] = []
        for junk in [
            "",
            "   ",
            "a shopping list",
            "https://tbrs.cc/spring",
            "https://tbrs.cc/spring?tbrs_click_id=",
            "https://tbrs.cc/spring?tbrs_click_id=not-one-of-ours",
            "javascript://tbrs.cc/spring?tbrs_click_id=\(clickId)",
            "myapp://open?tbrs_click_id=\(clickId)",
        ] where parseHandoff(junk) != nil {
            problems.append(junk)
        }
        XCTAssertEqual(problems, [])
    }

    func testReadsAHandoffOnTheCustomersOwnDomain() {
        // `tbrs.cc` is only the default short domain; a project can bring its own.
        XCTAssertEqual(parseHandoff("https://go.acme.com/spring?tbrs_click_id=\(clickId)")?.clickId, clickId)
    }

    func testPathRuleMatchesTheOtherCores() {
        var problems: [String] = []
        for refused in ["", "sale/summer", "//evil.example/x", "https://evil.example", "/sale/\u{09}summer", "/a\\b", "/" + String(repeating: "a", count: 512)]
        where isDeepLinkPath(refused) {
            problems.append(refused)
        }
        for accepted in ["/sale/summer", "/search?q=red%20shoes", "/"] where !isDeepLinkPath(accepted) {
            problems.append("refused \(accepted)")
        }
        XCTAssertEqual(problems, [])
    }

    // MARK: - The evidence it rides on

    /// A capture whose Apple side answers `responses` and whose handoff is whatever is passed.
    private func capture(
        claim: HandoffRead,
        token: AttributionTokenResult = .token("tok"),
        responses: [(Int, String)?],
        sent: @escaping ([String: Any]) -> Void,
        carried: @escaping (String) -> Void = { _ in }
    ) -> AcquisitionCapture {
        var queue = responses
        return AcquisitionCapture(
            defaults: defaults,
            mintToken: { token },
            post: { _ in
                guard !queue.isEmpty, let next = queue.removeFirst() else { return nil }
                return (next.0, Data(next.1.utf8))
            },
            sleep: { _ in },
            random: { 0.5 },
            handoff: { claim },
            carried: carried,
            send: { sent($0) }
        )
    }

    private func owe() { defaults.set(true, forKey: TreebarsConstants.keyAcquisitionPending) }

    private func claimOf(path: String? = nil) -> HandoffClaim {
        HandoffClaim(clickId: clickId, deepLinkPath: path, raw: "https://tbrs.cc/spring?tbrs_click_id=\(clickId)")
    }

    func testTheHandoffRidesOnAppleSOwnEvent() async {
        /*
         One event, not two: Apple's answer and the handoff travel together, so the install's source
         is judged on both pieces of evidence at once.
         */
        owe()
        var events: [[String: Any]] = []
        let apple = #"{"attribution":false}"#
        _ = await capture(claim: .found(claimOf()), responses: [(200, apple)], sent: { events.append($0) }).settle(consented: true)

        var problems: [String] = []
        if events.count != 1 { problems.append("sent \(events.count) events") }
        if events.first?[TreebarsConstants.handoffProperty] as? String != claimOf().raw {
            problems.append("did not carry the handoff")
        }
        if events.first?["attribution"] as? Bool != false { problems.append("dropped Apple's own answer") }
        XCTAssertEqual(problems, [])
    }

    func testTheHandoffGoesEvenWhenAppleNeverWill() async {
        /*
         `platformNotSupported` is Apple saying it has nothing, ever — but the handoff names the
         LINK, which is the better evidence anyway. It goes alone, with `attribution: false`, which
         reads the same as Apple saying nothing.
         */
        owe()
        var events: [[String: Any]] = []
        let sent = await capture(claim: .found(claimOf()), token: .unsupported, responses: [], sent: { events.append($0) })
            .settle(consented: true)

        var problems: [String] = []
        if !sent { problems.append("reported nothing sent") }
        if events.count != 1 { problems.append("sent \(events.count) events") }
        if events.first?[TreebarsConstants.handoffProperty] as? String == nil { problems.append("no handoff on it") }
        if defaults.bool(forKey: TreebarsConstants.keyAcquisitionPending) { problems.append("left the latch set") }
        XCTAssertEqual(problems, [])
    }

    func testNothingIsSentWhenNeitherSideHasAnything() async {
        owe()
        var events: [[String: Any]] = []
        let sent = await capture(claim: .empty, token: .unsupported, responses: [], sent: { events.append($0) })
            .settle(consented: true)
        XCTAssertFalse(sent)
        XCTAssertEqual(events.count, 0)
    }

    func testTheDestinationIsHandedOverBeforeTheEvent() async {
        // Before, because the person is waiting on the screen and not on the event — and a send
        // that threw must not decide whether they land on it.
        owe()
        var order: [String] = []
        _ = await capture(
            claim: .found(claimOf(path: "/sale/summer")),
            responses: [(200, #"{"attribution":false}"#)],
            sent: { _ in order.append("event") },
            carried: { order.append("carried:\($0)") }
        ).settle(consented: true)
        XCTAssertEqual(order, ["carried:/sale/summer", "event"])
    }

    func testTheDestinationIsHandedOverEvenWhenAppleIsNotReady() async {
        /*
         Apple answers 404 for a while after a token is minted, and that is a reason to ask again
         next launch — not a reason to leave somebody on the home screen when the link said
         otherwise.
         */
        owe()
        var carried: [String] = []
        _ = await capture(
            claim: .found(claimOf(path: "/sale/summer")),
            responses: [nil, nil, nil, nil, nil],
            sent: { _ in },
            carried: { carried.append($0) }
        ).settle(consented: true)
        XCTAssertEqual(carried, ["/sale/summer"])
    }

    func testAPasteboardItCouldNotReadKeepsTheInstallOwed() async {
        /*
         The difference between "there was nothing" and "we could not look", and the latch is what
         it costs. An app is `.inactive` while a system alert is up — the push prompt, on exactly
         the launch this runs — and iOS serves no pasteboard to an inactive app. Clearing the latch
         then would lose the only deterministic answer this install has, for good.
         */
        owe()
        var events: [[String: Any]] = []
        let sent = await capture(claim: .notYet, token: .unsupported, responses: [], sent: { events.append($0) })
            .settle(consented: true)

        var problems: [String] = []
        if sent { problems.append("reported something sent") }
        if !events.isEmpty { problems.append("sent an event anyway") }
        if !defaults.bool(forKey: TreebarsConstants.keyAcquisitionPending) { problems.append("cleared the latch") }
        XCTAssertEqual(problems, [])
    }

    func testTwoSettlesAtOnceSendOneEvent() async {
        /*
         Actor reentrancy, which an actor does not prevent. Every `await` in `settle` releases the
         actor — the pasteboard read waits for the app to be foreground-active, and Apple's token
         round-trips — and the persisted latch is cleared only after the send. So a second caller
         walks straight past `guard pending` while the first is still waiting.

         Two callers are what a real first launch produces: `didBecomeActive` fires on launch and
         again when a system alert such as the local-network permission prompt is dismissed, each
         arming its own `Task`. Both are correct and necessary — a first launch is not one moment —
         so the one-send guarantee belongs here, not there.
         */
        owe()
        let events = Sent()
        let capture = capture(
            claim: .found(claimOf()),
            responses: [(200, #"{"attribution":false}"#), (200, #"{"attribution":false}"#)],
            sent: { events.add($0) }
        )

        async let first = capture.settle(consented: true)
        async let second = capture.settle(consented: true)
        let outcomes = await [first, second]

        let count = await events.count
        var problems: [String] = []
        if count != 1 { problems.append("sent \(count) events") }
        // Exactly one caller reports having queued something, so a flush is not scheduled twice.
        if outcomes.filter({ $0 }).count != 1 { problems.append("\(outcomes.filter { $0 }.count) callers claimed the send") }
        XCTAssertEqual(problems, [])
    }

    // MARK: - Delivering the destination

    func testDeliveredOnceAndOnlyInsideTheWindow() {
        let store = DeferredDeepLink(defaults: defaults)
        let installedAt: Int64 = 1_700_000_000_000

        store.remember("/sale/summer")
        XCTAssertEqual(store.take(installedAtMs: installedAt, nowMs: installedAt + 60_000), "/sale/summer")
        // Gone afterwards: without this every launch reopens a sale somebody bought weeks ago.
        XCTAssertNil(store.take(installedAtMs: installedAt, nowMs: installedAt + 120_000))

        store.remember("/sale/autumn")
        let past = installedAt + TreebarsConstants.deferredDeepLinkWindowMs + 1
        XCTAssertNil(store.take(installedAtMs: installedAt, nowMs: past))
        // And dropped for good rather than re-deciding the same expiry on every launch forever.
        XCTAssertNil(store.take(installedAtMs: installedAt, nowMs: installedAt + 1_000))
    }

    func testASecondDestinationNeverDisplacesTheOneWaiting() {
        // There is one install, so there is one answer to where it came from.
        let store = DeferredDeepLink(defaults: defaults)
        store.remember("/sale/summer")
        store.remember("/something/else")
        XCTAssertEqual(store.take(installedAtMs: 1_000, nowMs: 2_000), "/sale/summer")
    }

    func testAnInstallWithNoFirstSeenMomentIsInsideNoWindow() {
        let store = DeferredDeepLink(defaults: defaults)
        store.remember("/sale/summer")
        XCTAssertNil(store.take(installedAtMs: nil, nowMs: 1_700_000_000_000))
    }

    func testAStoredValueThatIsNotAPathIsRefusedOnTheWayOutToo() {
        // Belt and braces, and the braces are the point: anything with this app's defaults can
        // write that key, and the check on the way in is the only other thing standing there.
        defaults.set("https://evil.example/x", forKey: TreebarsConstants.keyDeferredDeepLink)
        XCTAssertNil(DeferredDeepLink(defaults: defaults).take(installedAtMs: 1_000, nowMs: 2_000))
    }
}
