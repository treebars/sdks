import XCTest
@testable import TreebarsSDK

/// Every tapped Treebars push reaches the app's `onPushOpened` handler, a tap that launched the app included, and a link
/// is routed by the app when it has a handler and by the system when it has none. Each failure here was silent on a
/// phone: a tap that only opened the app, on the wrong screen or none.
@MainActor
final class PushOpensTests: XCTestCase {
    private var opened: [String] = []
    private var heard: [PushOpen] = []

    override func setUp() async throws {
        PushOpens.shared.reset()
        opened = []
        heard = []
        PushOpens.openLink = { [weak self] in self?.opened.append($0) }
    }

    override func tearDown() async throws {
        PushOpens.shared.reset()
        PushOpens.openLink = { Treebars.openURL($0) }
    }

    private func settle() async {
        // The hand-over runs on the main actor, a turn later.
        for _ in 0..<3 { await Task.yield() }
    }

    func testATapThatLaunchedTheAppIsHeldForTheHandlerAndHandedOverOnce() async {
        PushOpens.shared.deliver(PushOpen(link: "daleela://p/42", deliveryId: "d1"))
        XCTAssertTrue(opened.isEmpty, "not opened by the system while the app may still set a handler")

        PushOpens.shared.setHandler { [weak self] in self?.heard.append($0) }
        await settle()
        XCTAssertEqual(heard.map(\.link), ["daleela://p/42"])

        PushOpens.shared.setHandler(nil)
        PushOpens.shared.setHandler { [weak self] in self?.heard.append($0) }
        await settle()
        XCTAssertEqual(heard.count, 1, "handed over once")
        XCTAssertTrue(opened.isEmpty, "the handler routes the link, not the system")
    }

    func testWithAHandlerTheLinkIsTheHandlersAndNeverTheSystems() async {
        PushOpens.shared.start()
        PushOpens.shared.setHandler { [weak self] in self?.heard.append($0) }
        PushOpens.shared.deliver(PushOpen(link: "daleela://chat", isTest: true))
        XCTAssertEqual(heard.map(\.link), ["daleela://chat"])
        XCTAssertTrue(heard[0].isTest)
        XCTAssertTrue(opened.isEmpty)
    }

    func testAWarmTapWithNoHandlerOpensItsLinkAtOnce() {
        PushOpens.shared.start()
        PushOpens.shared.deliver(PushOpen(link: "daleela://d/7"))
        XCTAssertEqual(opened, ["daleela://d/7"])
        PushOpens.shared.deliver(PushOpen(link: nil))
        XCTAssertEqual(opened.count, 1, "a push with no link opens nothing")
    }

    func testAHeldLinkNobodyClaimsIsOpenedByTheSystemOnceTheWaitIsOver() async {
        PushOpens.shared.deliver(PushOpen(link: "daleela://t"))
        PushOpens.shared.start()
        XCTAssertTrue(opened.isEmpty, "not before the wait")
        let waited = expectation(description: "the wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + PushOpens.launchWaitSeconds + 0.5) { waited.fulfill() }
        await fulfillment(of: [waited], timeout: PushOpens.launchWaitSeconds + 5)
        await settle()
        XCTAssertEqual(opened, ["daleela://t"])
    }

    func testTheTapsLinkIsTheDeepLinkAndTheDataIsTheAuthorsOwn() {
        XCTAssertEqual(PushParts.link(["type": "deep_link", "url": "daleela://p/1"]), "daleela://p/1")
        XCTAssertNil(PushParts.link(["type": "app_action", "name": "open_cart"]))
        XCTAssertNil(PushParts.link(["type": "deep_link", "url": ""]))
        let info: [AnyHashable: Any] = [
            "aps": ["alert": "Hi"], "promo": "spring", "deep_link": "daleela://p/1", "image_url": "https://x/y.png",
            Treebars.deliveryIdKey: "d1", TreebarsConstants.richPushActionKey: "{}", "gcm.message_id": "1",
        ]
        XCTAssertEqual(PushParts.authored(info), ["promo": "spring"])
    }

    func testAPushIsTheSDKsWhenItCarriesADeliveryOrIsATest() {
        XCTAssertTrue(Treebars.isTreebarsPush([Treebars.deliveryIdKey: "d1"]))
        XCTAssertTrue(Treebars.isTreebarsPush([TreebarsConstants.richPushTestKey: "1"]))
        XCTAssertFalse(Treebars.isTreebarsPush([Treebars.deliveryIdKey: ""]))
        XCTAssertFalse(Treebars.isTreebarsPush(["gcm.message_id": "1"]))
    }

    func testAResponseHandedOverTwiceActsOnce() {
        let key = "request-\(UUID().uuidString)|com.apple.UNNotificationDefaultActionIdentifier"
        XCTAssertTrue(HandledResponses.first(key))
        XCTAssertFalse(HandledResponses.first(key))
    }
}
