import XCTest
@testable import TreebarsSDK

/**
 What a payload missing one key costs: that one thing, and nothing beside it.

 Swift's synthesized `Codable` throws when a non-optional field's key is absent, and both
 things this SDK reads arrive as many rows at once: `syncInApp` decodes an array of messages,
 `fetchNotifications` a whole page. One throw there would empty in-app and the notification
 centre together, and look exactly like a project with nothing queued.

 `InAppTokens` shows the shape of it: nine tokens, carried as the optional `style` on a
 message. A message with NO style decodes whatever the rules — so the field looks safe —
 while a style that arrives with eight of its nine tokens must not take every other message
 in the sync down with it. A server that stops sending one token, or a theme edited
 mid-flight, produces precisely that.

 So these tests are all one assertion wearing different clothes: **the incomplete thing
 degrades, and the things beside it arrive.** The two `UserDefaults`-backed cases at the end
 are the same rule applied to what is already on disk, where the payload was written by an
 older build rather than sent by a server.
 */
final class DecodingTests: XCTestCase {

    private static let keys = [
        "treebars.in_app_queue",
        "treebars.in_app_ledger",
        "treebars.notifications",
        "treebars.notification_ledger",
    ]

    override func setUp() {
        super.setUp()
        Self.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        Self.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    /// Eight of the nine tokens, which is the shape a rolled-back server sends.
    private let partialStyle = """
    {
      "accent": "#5B4DF5",
      "on_accent": "#FFFFFF",
      "surface": "#FFFFFF",
      "on_surface": "#111827",
      "on_surface_muted": "#6B7280",
      "backdrop": "#0F172A99",
      "radius": 20,
      "button_shape": "pill"
    }
    """

    // MARK: - In-app

    func testAStyleMissingOneTokenStillDecodesAndKeepsTheOthers() throws {
        let tokens = try decode(InAppTokens.self, partialStyle)

        XCTAssertEqual(tokens.font_family, "")
        XCTAssertEqual(tokens.accent, "#5B4DF5")
        XCTAssertEqual(tokens.radius, 20)
        XCTAssertEqual(tokens.button_shape, "pill")
    }

    /// The two tokens with a real default rather than an empty one. Both match Android's
    /// `parseInAppTokens`, because the same theme has to degrade the same way on both.
    func testAStyleWithNoTokensAtAllTakesTheDefaultsTheOtherSDKsUse() throws {
        let tokens = try decode(InAppTokens.self, "{}")

        XCTAssertEqual(tokens.radius, 8)
        XCTAssertEqual(tokens.button_shape, "rounded")
        XCTAssertEqual(tokens.accent, "")
        XCTAssertEqual(tokens.backdrop, "")
    }

    /// An explicit `null` and a value of the wrong type are as fatal as an absent key to a
    /// synthesized decoder, and cost the same one field here.
    func testANullOrWrongTypedTokenIsTheSameAsAMissingOne() throws {
        let tokens = try decode(InAppTokens.self, #"{"radius": null, "accent": 17}"#)

        XCTAssertEqual(tokens.radius, 8)
        XCTAssertEqual(tokens.accent, "")
    }

    /// The case this suite exists for: one message's style is short a token, and the sync
    /// comes back whole rather than empty.
    func testOneIncompleteStyleDoesNotEmptyTheSync() throws {
        let response = try decode(InAppSyncResponse.self, """
        {
          "messages": [
            { "delivery_id": "del_1", "content": { "title": "First" } },
            { "delivery_id": "del_2", "content": { "title": "Second" }, "style": \(partialStyle) },
            { "delivery_id": "del_3", "content": { "title": "Third" } }
          ],
          "policy": { "max_per_day": 3, "messages_shown_today": 1 }
        }
        """)

        XCTAssertEqual(response.messages.map(\.delivery_id), ["del_1", "del_2", "del_3"])
        XCTAssertEqual(response.messages[1].style?.font_family, "")
        XCTAssertEqual(response.messages[1].style?.accent, "#5B4DF5")
        XCTAssertEqual(response.messages[0].content.title, "First")
        XCTAssertEqual(response.policy?.max_per_day, 3)
    }

    /**
     `delivery_id` is the one required field on a message, so this is the row that still
     cannot decode — and the point is that it costs itself and nothing else. Without the
     row-by-row decode, one required field would be enough to empty the whole sync.
     */
    func testAMessageWithNoDeliveryIdIsDroppedAndTheRestArrive() throws {
        let response = try decode(InAppSyncResponse.self, """
        {
          "messages": [
            { "delivery_id": "del_1", "content": { "title": "First" } },
            { "campaign_id": "cmp_9", "content": { "title": "Nameless" } },
            { "delivery_id": "del_3", "content": { "title": "Third" } }
          ]
        }
        """)

        XCTAssertEqual(response.messages.map(\.delivery_id), ["del_1", "del_3"])
    }

    func testASyncWithNoMessagesKeyStillCarriesItsPolicyAndTokens() throws {
        let response = try decode(InAppSyncResponse.self, """
        { "policy": { "min_gap_seconds": 60 }, "style": \(partialStyle) }
        """)

        XCTAssertEqual(response.messages.count, 0)
        XCTAssertEqual(response.policy?.min_gap_seconds, 60)
        // Absent, where the server would have sent a number: nothing shown yet, so the cap
        // errs towards showing a message rather than withholding one.
        XCTAssertEqual(response.policy?.messages_shown_today, 0)
        XCTAssertEqual(response.style?.radius, 20)
    }

    /// A message whose content survived is still a message; a trigger that did not arrive
    /// matches nothing, which is the same direction `inAppTriggerMatches` fails in already.
    func testAnIncompleteTriggerLeavesTheMessageSilentRatherThanUniversal() throws {
        let response = try decode(InAppSyncResponse.self, """
        {
          "messages": [{
            "delivery_id": "del_1",
            "content": { "title": "Hi", "in_app": { "surface": "overlay", "layout": "modal" } }
          }]
        }
        """)

        let content = try XCTUnwrap(response.messages.first?.content.in_app)
        XCTAssertEqual(content.trigger.kind, "")
        XCTAssertFalse(
            inAppTriggerMatches(
                content.trigger, eventName: "session_start", properties: [:], screenName: nil
            )
        )
    }

    func testAButtonWithNoActionIsInertRatherThanFatal() throws {
        let response = try decode(InAppSyncResponse.self, """
        {
          "messages": [{
            "delivery_id": "del_1",
            "content": {
              "in_app": {
                "surface": "overlay",
                "layout": "modal",
                "trigger": { "kind": "immediate" },
                "buttons": [{ "label": "Later" }, { "label": "Open", "action": "deep_link" }]
              }
            }
          }]
        }
        """)

        let buttons = try XCTUnwrap(response.messages.first?.content.in_app?.buttons)
        XCTAssertEqual(buttons.map(\.label), ["Later", "Open"])
        XCTAssertEqual(buttons[0].action, "")
        XCTAssertEqual(buttons[1].action, "deep_link")
    }

    /// A filter clause missing its operator fails closed, which is what the matcher does with
    /// an operator it does not recognise — and for the same reason.
    ///
    /// The row carries a value, and that is the point of it. Under the unfinished-row rule, which
    /// every SDK shares, a row of a key alone has nothing to compare against, so it is dropped
    /// before the conjunction and the trigger matches. A missing operator only has something to
    /// fail on once the row is otherwise complete.
    func testAFilterMissingItsOperatorFailsClosed() throws {
        let trigger = try decode(InAppTrigger.self, """
        { "kind": "event", "event_name": "purchase", "filters": [{ "key": "value", "value": 50 }] }
        """)

        XCTAssertEqual(trigger.filters?.count, 1)
        XCTAssertEqual(trigger.filters?.first?.op, "")
        XCTAssertFalse(
            inAppTriggerMatches(
                trigger, eventName: "purchase", properties: ["value": 80], screenName: nil
            )
        )
    }

    /// A row with neither an operator nor a value is unfinished. It is ignored, not failed: the
    /// shape Add filter leaves behind must not silence a message that was already reaching people.
    func testAFilterWithNoOperatorAndNoValueIsUnfinishedAndIgnored() throws {
        let trigger = try decode(InAppTrigger.self, """
        { "kind": "event", "event_name": "purchase", "filters": [{ "key": "value" }] }
        """)

        XCTAssertEqual(trigger.filters?.count, 1)
        XCTAssertTrue(
            inAppTriggerMatches(
                trigger, eventName: "purchase", properties: ["value": 80], screenName: nil
            )
        )
    }

    // MARK: - Notifications

    /// Same rule on the page: one row short of half its fields, and the page is still a page.
    func testARowMissingHalfItsFieldsDoesNotEmptyThePage() throws {
        let body = try decode(NotificationWireResponse.self, """
        {
          "notifications": [
            {
              "group_id": "grp_1",
              "channel_type": "push",
              "device_count": 2,
              "content": { "title": "First" },
              "created_at": "2026-08-01T00:00:00.000Z"
            },
            { "group_id": "grp_2", "style": \(partialStyle) },
            {
              "group_id": "grp_3",
              "channel_type": "in_app",
              "device_count": 1,
              "content": { "title": "Third" },
              "created_at": "2026-08-03T00:00:00.000Z"
            }
          ],
          "unread_count": 3,
          "server_time": "2026-08-04T00:00:00.000Z"
        }
        """)

        XCTAssertEqual(body.notifications.map(\.group_id), ["grp_1", "grp_2", "grp_3"])
        XCTAssertEqual(body.unread_count, 3)

        let bare = body.notifications[1]
        XCTAssertEqual(bare.channel_type, "")
        // 1, not 0: a send reached at least the device reading it, and Android says 1 too.
        XCTAssertEqual(bare.device_count, 1)
        XCTAssertEqual(bare.created_at, "")
        XCTAssertNil(bare.content.title)
        XCTAssertEqual(bare.style?.font_family, "")
        XCTAssertEqual(bare.style?.radius, 20)
    }

    func testANotificationWithNoGroupIdIsDroppedAndTheRestArrive() throws {
        let body = try decode(NotificationWireResponse.self, """
        {
          "notifications": [
            { "group_id": "grp_1", "created_at": "2026-08-01T00:00:00.000Z" },
            { "channel_type": "push", "created_at": "2026-08-02T00:00:00.000Z" },
            { "group_id": "grp_3", "created_at": "2026-08-03T00:00:00.000Z" }
          ],
          "unread_count": 2,
          "server_time": "2026-08-04T00:00:00.000Z"
        }
        """)

        XCTAssertEqual(body.notifications.map(\.group_id), ["grp_1", "grp_3"])
    }

    /**
     `server_time` is the mark-all watermark, and the stand-in has to be a real timestamp: an
     empty string parses to no date, which leaves `overlay` marking nothing while
     `overlayCount` still believes a mark-all is outstanding.
     */
    func testAPageWithNoServerTimeGetsAWatermarkThatParses() throws {
        let body = try decode(NotificationWireResponse.self, #"{"notifications": []}"#)

        XCTAssertNotNil(InAppStore.parse(body.server_time))
        XCTAssertEqual(body.unread_count, 0)

        let state = try decode(NotificationStateResponse.self, "{}")
        XCTAssertNotNil(InAppStore.parse(state.server_time))
    }

    // MARK: - What is already on disk

    /**
     The ledger is written by this SDK and read back by whatever version runs next, so the
     same rule applies there: a build that adds a field must not throw on every ledger written
     before it, or this device forgets what it has already shown. Asserted
     through `InAppStore` because `Ledger` is private to `InApp.swift` — which is also the only
     honest way to ask the question, since forgetting is only visible as a message shown again.
     */
    func testALedgerWrittenBeforeAFieldExistedIsStillHonoured() {
        // `shown`, `lastShownAt` and `sinceSync` absent, as an older build would have left it.
        UserDefaults.standard.set(
            Data(#"{"done":{"del_1":true}}"#.utf8),
            forKey: "treebars.in_app_ledger"
        )

        let store = InAppStore()
        XCTAssertFalse(store.allows(message("del_1")))
        XCTAssertTrue(store.allows(message("del_2")))
    }

    /**
     The one deliberate exception, and the direction of it matters. `cached()` hands its page
     straight to the screen without re-checking whose it is, so a feed that cannot name its
     owner has to be no feed at all: the cost is a round trip, where the alternative is one
     person's notifications drawn under another person's name.
     */
    func testACachedFeedWithNoOwnerIsNoCacheAtAll() {
        let rows = #"[{"group_id":"grp_1","created_at":"2026-08-01T00:00:00.000Z"}]"#

        UserDefaults.standard.set(
            Data(#"{"notifications":\#(rows),"unreadCount":1}"#.utf8),
            forKey: "treebars.notifications"
        )
        XCTAssertNil(NotificationStore().cached())

        // The same feed, owned: everything else on it may be missing and it still stands.
        UserDefaults.standard.set(
            Data(#"{"owner":"user_1","notifications":\#(rows)}"#.utf8),
            forKey: "treebars.notifications"
        )
        let cached = NotificationStore().cached()
        XCTAssertEqual(cached?.notifications.map(\.group_id), ["grp_1"])
        XCTAssertEqual(cached?.unreadCount, 0)
    }

    private func message(_ deliveryID: String) -> InAppMessage {
        InAppMessage(
            delivery_id: deliveryID,
            campaign_id: nil,
            content: InAppBody(title: "Hello", body: nil, image_url: nil, in_app: nil),
            expires_at: nil,
            style: nil
        )
    }
}
