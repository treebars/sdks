import XCTest
@testable import TreebarsSDK

/**
 The two pure halves of in-app on the device: which message may be shown, and when.

 These rules are the same on every platform on purpose — a message capped at three a day
 has to mean the same thing on an iPhone as on a Pixel.

 Worth testing at all rather than trusting an end-to-end run because both halves fail
 silently. A trigger that stops matching produces no error anywhere: the message simply
 never appears, which is indistinguishable from a campaign nobody qualified for. And a cap
 that miscounts shows too many messages to real people before anyone notices.

 `InAppStore` holds `UserDefaults.standard` directly rather than taking a store, so
 isolating it means clearing the two keys it writes and putting them back, as
 `HarnessTests` does for `SessionManager`.
 */
final class InAppTests: XCTestCase {

    private static let keys = ["treebars.in_app_queue", "treebars.in_app_ledger"]

    override func setUp() {
        super.setUp()
        Self.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        Self.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    // MARK: - Fixtures

    private func trigger(
        _ kind: String,
        screenName: String? = nil,
        eventName: String? = nil
    ) -> InAppTrigger {
        InAppTrigger(kind: kind, screen_name: screenName, event_name: eventName)
    }

    private func message(
        _ deliveryID: String = "del_1",
        expiresAt: String? = nil,
        surface: String = "overlay",
        maxDisplays: Int? = nil
    ) -> InAppMessage {
        InAppMessage(
            delivery_id: deliveryID,
            campaign_id: "cmp_1",
            content: InAppBody(
                title: "Hello",
                body: nil,
                image_url: nil,
                in_app: InAppContent(
                    surface: surface,
                    layout: "modal",
                    html: nil,
                    position: nil,
                    dismissible: nil,
                    buttons: nil,
                    trigger: trigger("session_start"),
                    expires_after_seconds: nil,
                    max_displays: maxDisplays
                )
            ),
            expires_at: expiresAt,
            style: nil
        )
    }

    /// A sync carrying a policy that forbids nothing, so each test turns on one limit at a time.
    private func response(
        _ messages: [InAppMessage]? = nil,
        policy: InAppPolicy? = InAppPolicy(
            max_per_day: nil,
            min_gap_seconds: nil,
            messages_shown_today: 0,
            last_shown_at: nil
        )
    ) -> InAppSyncResponse {
        InAppSyncResponse(
            messages: messages ?? [message()],
            policy: policy,
            style: nil,
            claim_required: nil,
            signature_required: nil
        )
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - inAppTriggerMatches

    /* Every receipt names the campaign; only a link is a destination. */
    func testAClickNamesTheCampaignAndADestinationOnlyForAButtonThatGoesSomewhere() {
        let shown = message()
        let link = inAppClickProperties(shown, button: InAppButton(label: "Shop", action: "deep_link", value: "treebarsdemo://shop"))
        XCTAssertEqual(link[TreebarsConstants.campaignIdKey] as? String, "cmp_1")
        XCTAssertEqual(link[TreebarsConstants.deliveryIdKey] as? String, "del_1")
        XCTAssertEqual(link["destination"] as? String, "treebarsdemo://shop")
        let trait = inAppClickProperties(shown, button: InAppButton(label: "Join", action: "set_attribute", value: "yes", key: "newsletter"))
        XCTAssertNil(trait["destination"])
        XCTAssertEqual(trait[TreebarsConstants.campaignIdKey] as? String, "cmp_1")
        XCTAssertEqual(inAppReceipt(shown)[TreebarsConstants.campaignIdKey] as? String, "cmp_1")
    }

    /* A click says which element was pressed — a typed button's place, a markup body's `<n>`. */
    func testAClickSaysWhichButtonWasPressedNumberedFromOne() throws {
        let json = #"{"delivery_id":"d2","campaign_id":"cmp_1","content":{"in_app":{"surface":"overlay","layout":"modal","trigger":{"kind":"immediate"},"buttons":[{"label":"Shop now","action":"url","value":"https://x.example"},{"label":"Later","action":"dismiss"}]}}}"#
        let message = try JSONDecoder().decode(InAppMessage.self, from: Data(json.utf8))
        let buttons = try XCTUnwrap(message.content.in_app?.buttons)
        XCTAssertEqual(buttons.map(\.index), [1, 2])
        let pressed = inAppClickProperties(message, button: buttons[0])
        XCTAssertEqual(pressed[TreebarsConstants.inAppButtonIndexKey] as? Int, 1)
        XCTAssertEqual(pressed[TreebarsConstants.inAppButtonLabelKey] as? String, "Shop now")
        // A markup body's `treebars://click/2`, as the React Native bridge hands it over: the number, no invented label.
        let markup = try JSONDecoder().decode(InAppButton.self, from: Data(#"{"label":"","action":"click","index":2}"#.utf8))
        let reported = inAppClickProperties(message, button: markup)
        XCTAssertEqual(reported[TreebarsConstants.inAppButtonIndexKey] as? Int, 2)
        XCTAssertNil(reported[TreebarsConstants.inAppButtonLabelKey])
    }

    /* A call to action spends the message; a dismiss spends it through its own dismissal; a report does not. */
    func testACallToActionEndsTheMessageAndABareReportOfAPressDoesNot() {
        // Push's device actions too: a call, a copy, a share, a store review.
        for action in ["url", "deep_link", "track_event", "set_attribute", "custom", "call", "copy", "share", "store_review"] {
            XCTAssertTrue(inAppClickEndsMessage(InAppButton(label: "Go", action: action, value: "x")), action)
        }
        XCTAssertFalse(inAppClickEndsMessage(InAppButton(label: "Later", action: "dismiss", value: nil)))
        XCTAssertFalse(inAppClickEndsMessage(InAppButton(label: "Button 0", action: "click", value: nil)))
    }

    /* A push's coupon copied twice is one open. */
    func testCopyingAPushCouponCountsAsAnOpenTheFirstTimeOnly() {
        let defaults = UserDefaults(suiteName: "treebars.coupon.\(UUID().uuidString)")!
        XCTAssertTrue(Treebars.firstCouponCopy("coupon-1", defaults: defaults))
        XCTAssertFalse(Treebars.firstCouponCopy("coupon-1", defaults: defaults))
        XCTAssertTrue(Treebars.firstCouponCopy("coupon-2", defaults: defaults))
    }

    func testSessionStartFiresOnEitherEventThatMeansTheAppOpened() {
        let t = trigger("session_start")

        XCTAssertTrue(inAppTriggerMatches(t, eventName: "session_start", properties: [:], screenName: nil))
        XCTAssertTrue(inAppTriggerMatches(t, eventName: "app_open", properties: [:], screenName: nil))
        XCTAssertFalse(inAppTriggerMatches(t, eventName: "add_to_cart", properties: [:], screenName: nil))
    }

    func testAScreenIsMatchedByTheNameTheAppReportsCaseIncluded() {
        let t = trigger("screen_view", screenName: "Cart")

        XCTAssertTrue(inAppTriggerMatches(t, eventName: "screen_view", properties: [:], screenName: "Cart"))
        // Not normalised, deliberately: this is the host app's own vocabulary and we are in
        // no position to decide that "cart" meant "Cart".
        XCTAssertFalse(inAppTriggerMatches(t, eventName: "screen_view", properties: [:], screenName: "cart"))
        XCTAssertFalse(inAppTriggerMatches(t, eventName: "screen_view", properties: [:], screenName: "Checkout"))
    }

    func testTheScreenIsReadFromPropertiesWhenTheSDKHasNoCurrentScreen() {
        let t = trigger("screen_view", screenName: "Cart")

        XCTAssertTrue(inAppTriggerMatches(
            t,
            eventName: "screen_view",
            properties: ["screen_name": "Cart"],
            screenName: nil
        ))
    }

    /// An `event` trigger with no filters matches on the event name alone; `InAppFilterTests`
    /// covers the filters.
    func testAnEventTriggerMatchesOnTheEventName() {
        let t = trigger("event", eventName: "purchase")

        XCTAssertTrue(inAppTriggerMatches(t, eventName: "purchase", properties: ["value": 80], screenName: nil))
        XCTAssertFalse(inAppTriggerMatches(t, eventName: "refund", properties: ["value": 80], screenName: nil))
    }

    /// A trigger kind added server-side and not ported here must fail closed: showing a
    /// message to people who do not qualify is worse than showing it to nobody. Same
    /// reasoning as the unknown-operator case in `InAppFilterTests`, one level up —
    /// the kind is the only vocabulary this matcher has to be surprised by.
    func testAnUnknownTriggerKindFailsClosed() {
        XCTAssertFalse(inAppTriggerMatches(
            trigger("geofence_enter"),
            eventName: "purchase",
            properties: ["sku": "anything"],
            screenName: nil
        ))
    }

    // MARK: - InAppStore.allows

    func testItPermitsAnOrdinaryMessage() {
        let store = InAppStore()
        store.accept(response())

        XCTAssertTrue(store.allows(message()))
    }

    func testItRefusesOneThatHasExpiredWithoutWaitingForTheServerToSaySo() {
        let store = InAppStore()
        store.accept(response())

        // No fractional seconds, which is the shape the server sends and the shape that
        // makes the SDK's primary formatter return nil — `InAppStore.parse` falls back to a
        // plain ISO8601 formatter for exactly this. A parse failure here would read as "not
        // expired" and the message would go on being shown.
        XCTAssertFalse(store.allows(message(expiresAt: "2020-01-01T00:00:00Z")))
    }

    func testItStopsAtMaxDisplaysForThisDevice() {
        let store = InAppStore()
        let m = message(maxDisplays: 2)
        store.accept(response([m]))

        XCTAssertTrue(store.allows(m))
        store.recordDisplay(m)
        XCTAssertTrue(store.allows(m))
        store.recordDisplay(m)
        XCTAssertFalse(store.allows(m))
    }

    func testItCountsTheDailyCapInMessagesNotInShowings() {
        let store = InAppStore()
        let first = message("a", maxDisplays: 5)
        let second = message("b")
        store.accept(response(
            [first, second],
            policy: InAppPolicy(
                max_per_day: 1,
                min_gap_seconds: nil,
                messages_shown_today: 0,
                last_shown_at: nil
            )
        ))

        store.recordDisplay(first)
        // Showing the same message again is not a second message, so the allowance is intact
        // for it — this is what max_displays governs instead.
        XCTAssertTrue(store.allows(first))
        // A different message would be the second one today, and the cap is one.
        XCTAssertFalse(store.allows(second))
    }

    func testItAddsThisDevicesDisplaysToWhatTheServerAlreadyCounted() {
        let store = InAppStore()
        let a = message("a")
        let b = message("b")
        store.accept(response(
            [a, b],
            // Another device of theirs showed one earlier; the cap is two.
            policy: InAppPolicy(
                max_per_day: 2,
                min_gap_seconds: nil,
                messages_shown_today: 1,
                last_shown_at: nil
            )
        ))

        XCTAssertTrue(store.allows(a))
        store.recordDisplay(a)
        XCTAssertFalse(store.allows(b))
    }

    // MARK: - the caps this device counts

    private func capped(_ id: String, _ kind: String, ignoreMinGap: Bool = false) -> InAppMessage {
        var content = InAppContent(
            surface: "overlay", layout: "modal", html: nil, position: nil, dismissible: nil, buttons: nil,
            trigger: trigger(kind, eventName: "purchase"), expires_after_seconds: nil, max_displays: nil
        )
        content.ignore_min_gap = ignoreMinGap ? true : nil
        return InAppMessage(
            delivery_id: id, campaign_id: "cmp_1",
            content: InAppBody(title: "Hello", body: nil, image_url: nil, in_app: content),
            expires_at: nil, style: nil
        )
    }

    private func policy(minGap: Int? = nil, perSession: Int? = nil, perTrigger: [String: Int]? = nil) -> InAppPolicy {
        var policy = InAppPolicy(max_per_day: nil, min_gap_seconds: minGap, messages_shown_today: 0, last_shown_at: nil)
        policy.max_per_session = perSession
        policy.trigger_max_per_day = perTrigger
        return policy
    }

    func testTheSessionCapStopsASecondDrawAndANewSessionStartsAgain() {
        let store = InAppStore()
        let (a, b) = (capped("a", "screen_view"), capped("b", "screen_view"))
        store.accept(response([a, b], policy: policy(perSession: 1)))
        store.recordDisplay(a, session: "s1")
        XCTAssertFalse(store.allows(b, session: "s1"))
        XCTAssertTrue(store.allows(b, session: "s2"))
    }

    func testATriggerKindsDayCapCountsItsOwnKindAndARepeatSpendsNothing() {
        let store = InAppStore()
        let (a, b, c) = (capped("a", "event"), capped("b", "event"), capped("c", "session_start"))
        store.accept(response([a, b, c], policy: policy(perTrigger: ["event": 1])))
        let now = Date()
        store.recordDisplay(a, session: "s1", now: now)
        XCTAssertFalse(store.allows(b, session: "s1", now: now))
        XCTAssertTrue(store.allows(a, session: "s1", now: now))
        XCTAssertTrue(store.allows(c, session: "s1", now: now))
        XCTAssertTrue(store.allows(b, session: "s1", now: now.addingTimeInterval(36 * 3600)))
    }

    func testAMessageThatIgnoresTheMinimumGapIsLetThroughIt() {
        let store = InAppStore()
        let (a, b, urgent) = (capped("a", "immediate"), capped("b", "immediate"), capped("u", "immediate", ignoreMinGap: true))
        store.accept(response([a, b, urgent], policy: policy(minGap: 600)))
        store.recordDisplay(a, session: "s1")
        XCTAssertFalse(store.allows(b, session: "s1"))
        XCTAssertTrue(store.allows(urgent, session: "s1"))
    }

    /* A test send is drawn past every cap, and still not once it is done. */
    func testATestSendIsDrawnPastEveryCapAndStillNotOnceItIsDone() {
        let store = InAppStore()
        var test = capped("t", "immediate")
        test.test = true
        let (a, b) = (capped("a", "immediate"), capped("b", "immediate"))
        var caps = policy(minGap: 600, perSession: 1, perTrigger: ["immediate": 1])
        caps = InAppPolicy(max_per_day: 1, min_gap_seconds: caps.min_gap_seconds, messages_shown_today: 0, last_shown_at: nil)
        caps.max_per_session = 1
        caps.trigger_max_per_day = ["immediate": 1]
        store.accept(response([a, b, test], policy: caps))
        store.recordDisplay(a, session: "s1")
        XCTAssertFalse(store.allows(b, session: "s1"))
        XCTAssertTrue(store.allows(test, session: "s1"))
        store.markDone("t")
        XCTAssertEqual(store.blockedBy(test, session: "s1"), "done")
    }

    func testThePolicyReadsTheCapsOffTheWireAndDropsANullKind() throws {
        let json = #"{"max_per_day":null,"min_gap_seconds":null,"messages_shown_today":0,"last_shown_at":null,"max_per_session":2,"trigger_max_per_day":{"session_start":null,"screen_view":3,"event":null}}"#
        let decoded = try JSONDecoder().decode(InAppPolicy.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.max_per_session, 2)
        XCTAssertEqual(decoded.trigger_max_per_day, ["screen_view": 3])
    }

    func testItHonoursTheMinimumGapTakingWhicheverDeviceShowedOneMostRecently() {
        let store = InAppStore()
        let a = message("a")
        store.accept(response(
            [a],
            policy: InAppPolicy(
                max_per_day: nil,
                min_gap_seconds: 600,
                messages_shown_today: 1,
                last_shown_at: Self.iso.string(from: Date().addingTimeInterval(-60))
            )
        ))

        XCTAssertFalse(store.allows(a))
    }

    func testItRefusesOneThisDeviceIsFinishedWith() {
        let store = InAppStore()
        let a = message("a")
        store.accept(response([a]))

        store.markDone("a")
        XCTAssertFalse(store.allows(a))
    }

    // MARK: - InAppStore.accept

    func testItKeepsTheLedgerWhileReplacingTheQueue() {
        let store = InAppStore()
        let a = message("a", maxDisplays: 1)

        store.accept(response([a]))
        store.recordDisplay(a)
        // The server does not know this device is finished with it — that is device-scoped
        // state — so a re-sync returning the same message must not make it showable again.
        store.accept(response([a]))

        XCTAssertFalse(store.allows(a))
    }

    func testItSeparatesTheInboxFromTheOverlaySurface() {
        let store = InAppStore()
        let overlay = message("a")
        let inbox = message("b", surface: "inbox")

        store.accept(response([overlay, inbox]))

        XCTAssertEqual(store.inbox().map(\.delivery_id), ["b"])
        XCTAssertEqual(store.list().count, 2)
    }

    // MARK: - The SDK must not trigger off its own reports

    /*
     * `in_app_displayed` leaves through the same enqueue as every other event, and a message
     * triggered on `immediate` matches anything. Without a guard, showing one message shows
     * it again, and again — a loop that would look like an SDK bug on a device and like a
     * flood of events on the server.
     *
     * The guard itself is `Treebars.inAppEvents`, which is `private` and so out of reach even
     * from a `@testable` import. What these two can still do is prove the hazard is real, so
     * the guard is not cargo-culted, and name every event it has to cover.
     */
    private static let inAppEvents = ["in_app_displayed", "in_app_clicked", "in_app_dismissed"]

    func testAnImmediateTriggerWouldOtherwiseMatchTheSDKsOwnDisplayReport() {
        XCTAssertTrue(inAppTriggerMatches(
            trigger("immediate"),
            eventName: "in_app_displayed",
            properties: [:],
            screenName: nil
        ))
    }

    func testItNamesEveryEventTheGuardHasToCover() {
        // If a fourth in-app event is added and not listed in each SDK's guard, this is the
        // test that should have caught it.
        for name in Self.inAppEvents {
            XCTAssertTrue(
                inAppTriggerMatches(trigger("immediate"), eventName: name, properties: [:], screenName: nil),
                "\(name) matches an immediate trigger, so Treebars.inAppEvents has to list it"
            )
        }
    }

    /// The app going away is never a moment to draw: an immediate trigger matches it, so the guard must.
    func testTheAppsOwnLeavingEventsAreNeverAMomentToDraw() {
        for name in ["app_background", "session_end"] {
            XCTAssertTrue(inAppTriggerMatches(trigger("immediate"), eventName: name, properties: [:], screenName: nil), name)
            XCTAssertTrue(isLeavingEvent(name), name)
        }
        for name in ["app_foreground", "app_open", "session_start", "screen_view", "purchase"] {
            XCTAssertFalse(isLeavingEvent(name), name)
        }
    }

    // MARK: - A sync that outlives its sign-in

    /// A launch's sync for the previous person that lands after reset() has emptied the store must not put their queue
    /// back: the ledger that would have held it back is already gone, so it would be drawn again after sign-out.
    func testDropsASyncAskedForBeforeASignOut() {
        let store = InAppStore()
        let asked = store.generation
        store.reset()

        XCTAssertFalse(store.accept(response([message("stale")]), askedAt: asked))
        XCTAssertTrue(store.list().isEmpty)

        // The next sync, asked after it, is the new person's and lands.
        XCTAssertTrue(store.accept(response([message("fresh")]), askedAt: store.generation))
        XCTAssertEqual(store.list().map(\.delivery_id), ["fresh"])
    }

    func testDropsASyncAskedForBeforeSomebodyElseSignedIn() {
        let store = InAppStore()
        let asked = store.generation
        store.supersede()
        XCTAssertFalse(store.accept(response([message("previous")]), askedAt: asked))
        XCTAssertTrue(store.list().isEmpty)
    }

    // MARK: - One overlay at a time, however many threads ask

    /// Two events of one burst are considered on two threads. The claim must be one step, or both
    /// pass the check and one modal reports `in_app_displayed` twice.
    func testOnlyOneOfManyConcurrentClaimsTakesTheScreen() {
        let slot = PresentationSlot(hold: 30)
        let lock = NSLock()
        var granted = 0
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            if slot.claim() {
                lock.lock()
                granted += 1
                lock.unlock()
            }
        }
        XCTAssertEqual(granted, 1)
        XCTAssertTrue(slot.isHeld())
    }

    func testTheScreenIsFreeAgainOnAnAnswerOrOnceTheHoldIsOut() {
        let slot = PresentationSlot(hold: 30)
        let start = Date()
        XCTAssertTrue(slot.claim(now: start))
        XCTAssertFalse(slot.claim(now: start.addingTimeInterval(29)))
        XCTAssertTrue(slot.claim(now: start.addingTimeInterval(31)))
        slot.release()
        XCTAssertFalse(slot.isHeld())
        XCTAssertTrue(slot.claim())
    }

    /// The SDK's own HTML host reports every ending, so its claim outlasts the hold: a three-screen message read for a
    /// minute is not drawn over at thirty seconds.
    func testAClaimUntilReleasedOutlastsTheHold() {
        let slot = PresentationSlot(hold: 30)
        let start = Date()
        XCTAssertTrue(slot.claim(now: start, untilReleased: true))
        XCTAssertTrue(slot.isHeld(now: start.addingTimeInterval(3600)))
        XCTAssertFalse(slot.claim(now: start.addingTimeInterval(3600)))
        slot.releaseUnpinned()
        XCTAssertTrue(slot.isHeld(now: start.addingTimeInterval(3600)), "a renderer cannot free the SDK's own claim")
        slot.release()
        XCTAssertTrue(slot.claim(now: start.addingTimeInterval(3601)))
        XCTAssertFalse(slot.isHeld(now: start.addingTimeInterval(3632)), "an ordinary claim after it has the hold again")
    }

    // A nudge is outside the channel's caps, neither waiting on them nor spending them.
    func testANudgeNeitherWaitsOnTheCapsNorSpendsThem() {
        let nudge = InAppMessage(
            delivery_id: "n", campaign_id: "cmp_1",
            content: InAppBody(title: "Hello", body: nil, image_url: nil, in_app: InAppContent(
                surface: "overlay", layout: "nudge", html: "<p>Free delivery</p>", position: "bottom", dismissible: nil, buttons: nil,
                trigger: trigger("immediate", eventName: "purchase"), expires_after_seconds: nil, max_displays: nil
            )),
            expires_at: nil, style: nil
        )
        let (a, b) = (capped("a", "immediate"), capped("b", "immediate"))
        let store = InAppStore()
        store.accept(response([a, b, nudge], policy: policy(minGap: 600, perSession: 1)))
        store.recordDisplay(a, session: "s1")
        XCTAssertFalse(store.allows(b, session: "s1"))
        XCTAssertTrue(store.allows(nudge, session: "s1"))
        // A second store reads the first one's ledger back from UserDefaults: cleared, so only the nudge is on it.
        let fresh = InAppStore()
        fresh.reset()
        fresh.accept(response([a, nudge], policy: policy(minGap: 600, perSession: 1)))
        fresh.recordDisplay(nudge, session: "s1")
        XCTAssertTrue(fresh.allows(a, session: "s1"))
    }

    /* Nudges shown at once mark themselves done from several tasks at once, so the store takes concurrent writes. */
    func testTheStoreTakesWritesFromManyThreadsAtOnce() {
        let store = InAppStore()
        store.reset()
        let messages = (0..<50).map { capped("m\($0)", "immediate") }
        store.accept(response(messages, policy: policy(perSession: 100)))
        DispatchQueue.concurrentPerform(iterations: 500) { index in
            let message = messages[index % messages.count]
            store.recordDisplay(message, session: "s1")
            store.markDone(message.delivery_id)
            _ = store.allows(message, session: "s1")
        }
        XCTAssertTrue(messages.allSatisfy { store.isDone($0.delivery_id) })
    }

    func testNudgeSlotsHoldThreeEachOnceAndFreeOnlyTheirOwn() {
        let slots = NudgeSlots(capacity: InAppBridge.nudgeMaxOnScreen)
        XCTAssertTrue(slots.claim("a"))
        XCTAssertFalse(slots.claim("a"))
        XCTAssertTrue(slots.claim("b"))
        XCTAssertTrue(slots.claim("c"))
        XCTAssertFalse(slots.hasRoom)
        XCTAssertFalse(slots.claim("d"))
        slots.release("b")
        XCTAssertTrue(slots.claim("d"))
        XCTAssertEqual(slots.clear(), ["a", "c", "d"])
    }

    func testANudgePositionAdmitsItsEdge() {
        XCTAssertTrue(TreebarsNudgePosition.any.admits("top"))
        XCTAssertTrue(TreebarsNudgePosition.top.admits("top"))
        XCTAssertFalse(TreebarsNudgePosition.top.admits("bottom"))
        XCTAssertTrue(TreebarsNudgePosition.bottom.admits(nil), "a nudge with no edge sits at the bottom")
        XCTAssertFalse(TreebarsNudgePosition.bottom.admits("top"))
    }

    // A primer is held back from anybody the app cannot ask, and asked again each time.
    func testAPrimerWaitsForPeopleWhoCanStillBeAsked() throws {
        let primer = try JSONDecoder().decode(InAppDisplay.self, from: Data(#"{"only_when_push_askable":true}"#.utf8))
        XCTAssertEqual(primer.only_when_push_askable, true)
        for status in ["not_determined", "provisional"] { XCTAssertNil(pushAskableBlock(primer, status: status), status) }
        for status in ["authorized", "ephemeral", "denied", "unsupported"] { XCTAssertEqual(pushAskableBlock(primer, status: status), "push_answered", status) }
        XCTAssertEqual(pushAskableBlock(primer, status: nil), "push_answered")
        // A message that did not ask is never held back by it.
        XCTAssertNil(pushAskableBlock(InAppDisplay(), status: "authorized"))
        XCTAssertNil(pushAskableBlock(nil, status: "authorized"))
    }
}

/**
 The delayed in-app loop itself, on a fake clock: `sleep` is one tick the test counts, and the SDK's state is
 plain fields. The decision tests cannot see the loop's own failures — a wait that never looks again, a present that
 loses the slot and is forgotten, a cap that closes mid-wait and is never reported.
 */
final class DelayedInAppLoopTests: XCTestCase {
    private final class Fake {
        var waiting = true
        var heldFor = 0
        var blocked: String?
        /// Set when the clock reaches this tick: a cap closing mid-wait.
        var blockAt: (tick: Int, reason: String)?
        var claimRefusals = 0
        var ticks = 0
        var presented = 0
        var reports: [String] = []

        func run() async {
            await runDelayedInApp(
                stillWaiting: { self.waiting },
                look: {
                    let held = self.heldFor > 0
                    if held { self.heldFor -= 1 }
                    return delayedInAppStep(blocked: self.blocked, hasRenderer: true, screenHeld: held)
                },
                present: {
                    if self.claimRefusals > 0 {
                        self.claimRefusals -= 1
                        return false
                    }
                    self.presented += 1
                    return true
                },
                finish: { self.waiting = false },
                report: { self.reports.append($0) },
                sleep: {
                    self.ticks += 1
                    if let blockAt = self.blockAt, blockAt.tick == self.ticks { self.blocked = blockAt.reason }
                    // A runaway loop fails the test instead of hanging it.
                    if self.ticks > 50 { self.waiting = false }
                }
            )
        }
    }

    func testABusyScreenForTwoTicksThenFreeIsPresentedOnce() async {
        let fake = Fake()
        fake.heldFor = 2
        await fake.run()
        XCTAssertEqual(fake.ticks, 2)
        XCTAssertEqual(fake.presented, 1)
        XCTAssertEqual(fake.reports, [])
        XCTAssertFalse(fake.waiting)
    }

    func testACapClosingMidWaitIsReportedAndNotPresented() async {
        let fake = Fake()
        fake.heldFor = 2
        fake.blockAt = (tick: 1, reason: "min_gap")
        await fake.run()
        XCTAssertEqual(fake.presented, 0)
        XCTAssertEqual(fake.reports, ["min_gap"])
        XCTAssertEqual(fake.ticks, 2)
        XCTAssertFalse(fake.waiting)
    }

    func testLosingTheSlotLooksAgain() async {
        let fake = Fake()
        fake.claimRefusals = 1
        await fake.run()
        XCTAssertEqual(fake.ticks, 1)
        XCTAssertEqual(fake.presented, 1)
    }

    func testAMessageNoLongerWaitingStopsWithoutAWord() async {
        let fake = Fake()
        fake.heldFor = 5
        await runDelayedInApp(
            stillWaiting: { fake.waiting },
            look: { .wait },
            present: {
                fake.presented += 1
                return true
            },
            finish: { fake.waiting = false },
            report: { fake.reports.append($0) },
            // reset(), or a new person, while it waits: the loop sees it on its next look.
            sleep: {
                fake.ticks += 1
                fake.waiting = false
            }
        )
        XCTAssertEqual(fake.ticks, 1)
        XCTAssertEqual(fake.presented, 0)
        XCTAssertEqual(fake.reports, [])
    }

    /// What a sent form keeps beyond its answers: the web's and Kotlin's `formKeeps`, the same cases.
    func testAFormKeepsAnAddressAndOnlyTheDeclaredUnreservedTraits() throws {
        func content(_ declared: [String]) throws -> InAppContent {
            let traits = declared.map { "\"\($0)\"" }.joined(separator: ",")
            let json = """
            {"surface":"overlay","layout":"modal","declared":{"events":[],"traits":[\(traits)]},
             "form":{"fields":[{"id":"age","kind":"number","label":"Age","trait":"age"},
               {"id":"likes","kind":"multi_choice","label":"Likes","options":["Coats","Shoes"],"trait":"likes"},
               {"id":"email","kind":"email","label":"Email","save_as":"email"},
               {"id":"id","kind":"text","label":"Id","trait":"user_id"}]}}
            """
            return try JSONDecoder().decode(InAppContent.self, from: Data(json.utf8))
        }
        let responses: [String: Any] = ["age": 31, "likes": "Coats,Shoes", "email": "a@b.co", "id": "someone-else"]
        let kept = formKeeps(try content(["age", "likes", "user_id"]), responses: responses)
        XCTAssertEqual(kept.addresses, ["email": "a@b.co"])
        XCTAssertEqual(kept.traits["age"] as? Int, 31)
        XCTAssertEqual(kept.traits["likes"] as? String, "Coats,Shoes")
        XCTAssertNil(kept.traits["user_id"], "a trait the product keeps is never set")
        XCTAssertEqual(Array(formKeeps(try content(["age"]), responses: responses).traits.keys), ["age"])
        XCTAssertTrue(formKeeps(try content(["age"]), responses: ["age": ""]).traits.isEmpty)
    }

    /// A message's dark variant: the dark tokens when the app is drawn dark, the light ones otherwise,
    /// and a message with no dark variant as it always was — the same cases as Kotlin's `InAppDarkTokensTest`.
    func testAMessageHandsItsDarkTokensOnlyWhenTheAppIsDark() throws {
        func tokens(_ surface: String) -> InAppTokens {
            InAppTokens(accent: "#5B4DF5", on_accent: "#FFFFFF", surface: surface, on_surface: "#111827", on_surface_muted: "#6B7280", backdrop: "#0F172A99", radius: 8, font_family: "", button_shape: "rounded")
        }
        // Built here: `InAppTests.message` is private to that class.
        let body = InAppBody(title: "Hello", body: nil, image_url: nil, in_app: nil)
        let both = InAppMessage(delivery_id: "both", campaign_id: "cmp_1", content: body, expires_at: nil, style: tokens("#FFFFFF"), style_dark: tokens("#16161D"))
        let light = InAppMessage(delivery_id: "light", campaign_id: "cmp_1", content: body, expires_at: nil, style: tokens("#FFFFFF"))
        let store = InAppStore()
        XCTAssertEqual(store.tokensFor(both).map(\.surface), "#FFFFFF")
        XCTAssertEqual(store.tokensFor(both, dark: true).map(\.surface), "#16161D")
        XCTAssertEqual(store.tokensFor(light, dark: true).map(\.surface), "#FFFFFF")
        // Kept across a launch: the store re-encodes the message, and an undeclared key would be dropped there.
        let again = try JSONDecoder().decode(InAppMessage.self, from: JSONEncoder().encode(both))
        XCTAssertEqual(again.style_dark?.surface, "#16161D")
    }

    /// A link's key-values ride beside its value, never in place of it: Kotlin's and the web's cases.
    func testTheDelegateIsHandedALinksValueBesideItsKeyValues() {
        let link = InAppButton(label: "Shop", action: "deep_link", value: "app://sale?utm_source=in_app", data: ["utm_source": "in_app"])
        XCTAssertEqual(clickValues(link), ["utm_source": "in_app", "value": "app://sale?utm_source=in_app"])
        XCTAssertEqual(clickValues(InAppButton(label: "Keys", action: "custom", value: nil, data: ["coupon": "SPRING"])), ["coupon": "SPRING"])
        XCTAssertEqual(clickValues(InAppButton(label: "Cart", action: "deep_link", value: "app://cart")), ["value": "app://cart"])
    }
}
