import XCTest
@testable import TreebarsSDK

/**
 An app rebuilt with another write key. What the previous key left — the unsent queue, a sealed batch,
 the session whose `session_end` is owed at the next launch — belongs to the previous project, so the
 first launch under a new key drops it rather than sending it to the new one. Plus two smaller in-app
 cases: a delayed message that finds the screen taken, and a message's direction.

 Files are isolated by UUID filename in the real Application Support directory, as `EventQueueTests`
 explains; the defaults by a suite of their own.
 */
final class WriteKeyStampTests: XCTestCase {

    private static let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first ?? URL(fileURLWithPath: NSTemporaryDirectory())

    private let t0: TimeInterval = 1_787_475_600 // 2026-08-23T09:00:00Z
    private var suite = ""
    private var defaults: UserDefaults!
    private var queueFile = ""
    private var uploaderFile = ""
    private var triggersFile = ""

    override func setUp() {
        super.setUp()
        suite = "treebars.stamp.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        queueFile = "treebars-queue-stamp-\(UUID().uuidString).json"
        uploaderFile = "treebars-uploader-stamp-\(UUID().uuidString).json"
        triggersFile = "treebars-triggers-stamp-\(UUID().uuidString).json"
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        for file in [queueFile, uploaderFile, triggersFile] {
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(file))
        }
        super.tearDown()
    }

    private func claim(_ key: String) -> Bool {
        WriteKeyStamp.claim(key, defaults: defaults, queueFilename: queueFile, uploaderFilename: uploaderFile, triggersFilename: triggersFile)
    }

    /// What a launch under the first key leaves: a queued event, a sealed batch, and a session that will have aged out.
    private func leftBy(_ key: String) async {
        XCTAssertFalse(claim(key), "a first launch adopts its key")
        await EventQueue(filename: queueFile).append(["event_id": "old-1", "event_name": "viewed"])
        UploaderStore(filename: uploaderFile).save(
            UploaderState(json: ["pending": [["batch_id": "b1", "sent_at": "2026-08-23T09:00:00.000Z", "events": [["event_id": "old-0"]]]]])
        )
        _ = await SessionManager(defaults: defaults, clock: { self.t0 }).touch()
    }

    /// The next launch, three hours later: the session it finds has expired, and would be closed.
    private func nextLaunch() async -> SessionTouch {
        await SessionManager(defaults: defaults, clock: { self.t0 + 3 * 3600 }).touch()
    }

    func testADifferentKeyDropsThePreviousKeysQueueBatchesAndSession() async {
        await leftBy("pk_live_before")

        XCTAssertTrue(claim("pk_live_after"))

        let count = await EventQueue(filename: queueFile).count
        XCTAssertEqual(count, 0)
        XCTAssertTrue(UploaderStore(filename: uploaderFile).load().pending.isEmpty)
        let launch = await nextLaunch()
        XCTAssertNil(launch.expired, "no session_end is owed to the new project for the old one's session")
        XCTAssertFalse(launch.isFirstSession, "the install has still been used: not a first session")
        XCTAssertEqual(defaults.string(forKey: WriteKeyStamp.key), "pk_live_after")
    }

    func testTheSameKeyKeepsAllOfItAndTheAgedOutSessionIsStillClosed() async {
        await leftBy("pk_live_before")

        XCTAssertFalse(claim("pk_live_before"))

        let count = await EventQueue(filename: queueFile).count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(UploaderStore(filename: uploaderFile).load().pending.count, 1)
        let launch = await nextLaunch()
        XCTAssertNotNil(launch.expired)
    }

    func testAnInstallFromBeforeTheStampAdoptsTheKeyAndDropsNothing() async {
        await EventQueue(filename: queueFile).append(["event_id": "old-1"])

        XCTAssertFalse(claim("pk_live_after"))

        let count = await EventQueue(filename: queueFile).count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(defaults.string(forKey: WriteKeyStamp.key), "pk_live_after")
    }

    /// A queue built before the claim has not read its file, so the claim still reaches it — which is why it loads lazily.
    func testAQueueBuiltBeforeTheClaimSeesTheDrop() async {
        await leftBy("pk_live_before")
        let built = EventQueue(filename: queueFile)

        XCTAssertTrue(claim("pk_live_after"))

        let count = await built.count
        XCTAssertEqual(count, 0)
    }

    // A delayed message whose delay ends while another holds the screen waits, rather than being dropped.
    func testADelayedMessageWaitsForTheScreenAndIsReportedWhenRefused() {
        XCTAssertEqual(delayedInAppStep(blocked: nil, hasRenderer: true, screenHeld: true), .wait)
        XCTAssertEqual(delayedInAppStep(blocked: "min_gap", hasRenderer: true, screenHeld: true), .wait)
        XCTAssertEqual(delayedInAppStep(blocked: nil, hasRenderer: true, screenHeld: false), .present)
        XCTAssertEqual(delayedInAppStep(blocked: "min_gap", hasRenderer: true, screenHeld: false), .drop("min_gap"))
        XCTAssertEqual(delayedInAppStep(blocked: "done", hasRenderer: true, screenHeld: false), .drop(nil))
        XCTAssertEqual(delayedInAppStep(blocked: nil, hasRenderer: false, screenHeld: false), .drop("no_renderer"))
    }

    // The direction survives decoding AND the re-encode the store and the bridge do; absent stays absent.
    func testAMessagesDirectionSurvivesTheRoundTrip() throws {
        let json = #"{"surface":"overlay","layout":"modal","trigger":{"kind":"immediate"},"direction":"rtl"}"#
        let decoded = try JSONDecoder().decode(InAppContent.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.direction, "rtl")
        let again = try JSONDecoder().decode(InAppContent.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(again.direction, "rtl")
        let plain = try JSONDecoder().decode(InAppContent.self, from: Data(#"{"surface":"overlay","layout":"modal","trigger":{"kind":"immediate"}}"#.utf8))
        XCTAssertNil(plain.direction)
    }

    /*
     Every key a device must keep survives the decode AND the re-encode the store and the React Native bridge do. The
     fixture between the markers carries every key the server sends a device, and a check on the server's side reads it
     from here and fails when one is missing — so a key the server adds cannot be dropped here without a test failing on
     one side or the other.
     */
    func testEveryDeviceKeySurvivesTheRoundTrip() throws {
        // device-keys:start
        let json = #"{"surface":"overlay","direction":"rtl","layout":"modal","body_mode":"html","html":"<p>Hi</p>","declared":{"events":["offer_claimed"],"traits":["streak"]},"transparent":true,"html_ref":{"sha256":"ab12","bytes":70000},"position":"bottom","image_alt":"A red winter coat","dismissible":true,"buttons":[{"label":"OK","action":"dismiss"}],"trigger":{"kind":"immediate"},"expires_after_seconds":3600,"max_displays":2,"ignore_min_gap":true,"display":{"on":"delay","delay_seconds":2,"contexts":["home"],"priority":1,"auto_dismiss_seconds":30,"self_handled":false,"only_when_push_askable":true},"form":{"fields":[{"id":"size","kind":"dropdown","label":"Size","required":true,"options":["S","M"],"placeholder":"Pick one","save_as":"email","trait":"shoe_size"}]},"slides":[{"image_url":"https://cdn.example.com/1.png","image_alt":"The first coat","title":"One"}],"countdown_to":"2030-01-01T00:00:00Z","font_url":"https://fonts.example.com/a.css","card":{"template":"basic","icon_url":"https://cdn.example.com/i.png","image_alt":"A coat","action":{"type":"url","value":"https://shop.example/sale"},"pinned":true,"show_from":"2030-01-01T00:00:00Z","category":"Offers","cta":{"label":"Shop","action":{"type":"deep_link","value":"app://sale"}},"expires_after_seen_days":7}}"#
        // device-keys:end
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let decoded = try JSONDecoder().decode(InAppContent.self, from: Data(json.utf8))
        let again = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        for key in sent.keys {
            XCTAssertNotNil(again[key], "\(key) was dropped by the round trip")
        }
        // And every display rule an app reads, one level down: the struct re-encodes `display` too.
        let sentDisplay = try XCTUnwrap(sent["display"] as? [String: Any])
        let againDisplay = try XCTUnwrap(again["display"] as? [String: Any])
        for key in sentDisplay.keys {
            XCTAssertNotNil(againDisplay[key], "display.\(key) was dropped by the round trip")
        }
        // And every key of a card: the struct re-encodes the card as well.
        let sentCard = try XCTUnwrap(sent["card"] as? [String: Any])
        let againCard = try XCTUnwrap(again["card"] as? [String: Any])
        for key in sentCard.keys {
            XCTAssertNotNil(againCard[key], "card.\(key) was dropped by the round trip")
        }
        // And every key of a form field: the struct re-encodes the form as well.
        let sentField = try XCTUnwrap(((sent["form"] as? [String: Any])?["fields"] as? [[String: Any]])?.first)
        let againField = try XCTUnwrap(((again["form"] as? [String: Any])?["fields"] as? [[String: Any]])?.first)
        for key in sentField.keys {
            XCTAssertNotNil(againField[key], "form.fields[0].\(key) was dropped by the round trip")
        }
        XCTAssertEqual(decoded.body_mode, "html")
    }
}
