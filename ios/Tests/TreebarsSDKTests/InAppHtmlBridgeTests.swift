import XCTest
@testable import TreebarsSDK

/*
 The iOS half of the bridge's two shared contracts, which the web and Kotlin SDKs run too: the document a WebView is
 handed, byte for byte (`bridge-documents.json`), and what each call means (`bridge-conformance.json`). Both sit in
 `Fixtures/` beside this file and are read from `#filePath` as the other shared scenarios are — a simulator reads the
 host's disk. The WKWebView itself is the simulator's to prove.
 */
final class InAppHtmlBridgeTests: XCTestCase {

    private func fixture(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], "\(name): the shared fixture is missing or malformed")
    }

    func testEveryGoldenDocumentIsBuiltByteForByte() throws {
        let cases = try XCTUnwrap(fixture("bridge-documents.json")["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for spec in cases {
            let options = try XCTUnwrap(spec["options"] as? [String: Any])
            let insets = (options["insets"] as? [String: Int]).map {
                BridgeInsets(top: $0["top"] ?? 0, right: $0["right"] ?? 0, bottom: $0["bottom"] ?? 0, left: $0["left"] ?? 0)
            }
            let built = BridgeDocument.build(
                try XCTUnwrap(spec["html"] as? String),
                host: try XCTUnwrap(options["host"] as? String),
                nonce: try XCTUnwrap(options["nonce"] as? String),
                direction: options["direction"] as? String,
                insets: insets,
                device: options["device"] as? String,
                orientation: options["orientation"] as? String
            )
            XCTAssertEqual(built, spec["document"] as? String, spec["name"] as? String ?? "")
        }
    }

    func testAnswersEveryMethodTheBridgeTableGivesIOS() {
        XCTAssertEqual(BridgeDisplay.methods, InAppBridge.hostMethods)
    }

    func testEveryConformanceCaseMeansWhatItMeansOnTheWeb() throws {
        let cases = try XCTUnwrap(fixture("bridge-conformance.json")["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for spec in cases { try run(spec) }
    }

    func testANumberAndAFlagAreNotTheSame() throws {
        let sdk = FakeSdk()
        let display = BridgeDisplay(message: try message(["delivery_id": "d", "campaign_id": "c", "declared": ["events": [], "traits": ["streak"]]]), sdk: sdk) { _, _ in }
        var answer: Any?
        display.call("trackRating", try args(#"[true]"#), close: {}) { answer = $0 }
        XCTAssertEqual(json(plain(answer)), json(plain(["ok": false, "reason": "invalid_value"])))
        display.call("setUserAttribute", try args(#"["streak", true]"#), close: {}) { answer = $0 }
        XCTAssertEqual(sdk.traits.count, 1)
        XCTAssertTrue(sdk.traits.first?["streak"] as? Bool == true, "a flag stays a flag")
    }

    func testALinkIsReadAsEveryRendererReadsOne() {
        XCTAssertEqual(readInAppHtmlAction("treebars://dismiss"), .dismiss)
        XCTAssertEqual(readInAppHtmlAction(" treebars://click/3 "), .click(3))
        XCTAssertEqual(readInAppHtmlAction("https://shop.example"), .link("https://shop.example"))
        XCTAssertNil(readInAppHtmlAction("java\tscript:alert(1)"))
        XCTAssertNil(readInAppHtmlAction("#"))
    }

    func testAStoredValueSurvivesTheStoresRoundTrip() throws {
        let json = #"{"delivery_id":"d","content":{},"stored":{"streak":2,"name":"Ada","vip":true,"bad":{"x":1}}}"#
        let decoded = try JSONDecoder().decode(InAppMessage.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.stored, ["streak": .number(2), "name": .string("Ada"), "vip": .bool(true)])
        let again = try JSONDecoder().decode(InAppMessage.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(again.stored, decoded.stored)
    }

    // MARK: - The harness

    private func args(_ json: String) throws -> [Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any])
    }

    /// A message as the sync delivers one: decoded from JSON, as the store and the host receive it.
    private func message(_ spec: [String: Any]) throws -> InAppMessage {
        var inApp: [String: Any] = [
            "surface": "overlay", "layout": "modal", "body_mode": "html", "html": "<p>x</p>",
            "trigger": ["kind": "immediate"],
        ]
        inApp["declared"] = spec["declared"] ?? ["events": [], "traits": []]
        let raw: [String: Any] = [
            "delivery_id": spec["delivery_id"] as? String ?? "d",
            "campaign_id": spec["campaign_id"] ?? NSNull(),
            "content": ["in_app": inApp],
            "stored": spec["stored"] ?? [:],
        ]
        return try JSONDecoder().decode(InAppMessage.self, from: JSONSerialization.data(withJSONObject: raw))
    }

    private final class FakeSdk: BridgeSdk {
        var events: [(String, [String: Any])] = []
        var traits: [[String: Any]] = []
        var opened: [[String]] = []
        var dismissedCount = 0
        var spentCount = 0
        var clickedCount = 0

        /// The server's answers a case names (`rewards`); a pool it does not name is one the server refuses.
        let rewards: [String: Any]

        init(rewards: [String: Any] = [:]) {
            self.rewards = rewards
        }

        func claimReward(_ pool: String, deliveryID: String, _ answer: @escaping ([String: Any]) -> Void) {
            answer(rewards[pool] as? [String: Any] ?? BridgeDisplay.refuse("not_available"))
        }

        func track(_ name: String, _ properties: [String: Any]) { events.append((name, properties)) }
        func setTraits(_ traits: [String: Any]) -> [String: Any] {
            // Where a trait goes — `identify` or the anonymous person — is the SDK's, and the page cannot tell.
            self.traits.append(traits)
            return BridgeDisplay.ok
        }
        func requestPushPermission(_ answer: @escaping (String) -> Void) { answer("granted") }
        func clicked(action: String, values: [String: Any], fields: [String: Any]) { clickedCount += 1 }
        func spent() { spentCount += 1 }
        func dismissed() { dismissedCount += 1 }
        func flush() {}
        func keep(key: String, value: Any?) {}
        func open(_ url: String, via: String) -> Bool {
            opened.append([url, via])
            return true
        }
        func copy(_ text: String, toast: String?) -> Bool { true }
        func dial(_ number: String) -> Bool { true }
        func sms(_ number: String, body: String?) -> Bool { true }
        func share(_ text: String) -> Bool { true }
        func settings(notifications: Bool) -> Bool { true }
        func storeReview() -> Bool { true }
        func alert(_ message: String) {}
        func context() -> [String: Any] { [:] }
        func log(_ line: String) {}
    }

    private struct Unanswered {}

    private func run(_ spec: [String: Any]) throws {
        let name = spec["name"] as? String ?? ""
        let sdk = FakeSdk(rewards: spec["rewards"] as? [String: Any] ?? [:])
        var waiting: [() -> Void] = []
        let display = BridgeDisplay(message: try message(try XCTUnwrap(spec["message"] as? [String: Any])), sdk: sdk) { _, run in
            waiting.append(run)
        }
        var closes = 0
        let turn = {
            let due = waiting
            waiting = []
            due.forEach { $0() }
        }
        for step in try XCTUnwrap(spec["steps"] as? [[String: Any]]) {
            if step["turn"] as? Bool == true {
                turn()
                continue
            }
            let method = try XCTUnwrap(step["call"] as? String)
            let stepArgs = step["args"] as? [Any] ?? []
            var answer: Any? = Unanswered()
            display.call(method, stepArgs, close: { closes += 1 }) { answer = $0 }
            XCTAssertFalse(answer is Unanswered, "\(name): \(method) never answered")
            XCTAssertEqual(json(plain(answer)), json(plain(step["answer"])), "\(name): \(method)\(stepArgs)")
        }
        turn()

        if let expected = spec["events"] {
            XCTAssertEqual(json(plain(sdk.events.map { [$0.0, $0.1] as [Any] })), json(plain(expected)), "\(name): events")
        }
        if let count = spec["event_count"] as? Int { XCTAssertEqual(sdk.events.count, count, "\(name): event count") }
        if let expected = spec["traits"] { XCTAssertEqual(json(plain(sdk.traits)), json(plain(expected)), "\(name): traits") }
        if let expected = spec["opened"] { XCTAssertEqual(json(plain(sdk.opened)), json(plain(expected)), "\(name): opened") }
        if let count = spec["closes"] as? Int { XCTAssertEqual(closes, count, "\(name): closes") }
        if let count = spec["dismissed"] as? Int { XCTAssertEqual(sdk.dismissedCount, count, "\(name): dismissed") }
        if let count = spec["spent"] as? Int { XCTAssertEqual(sdk.spentCount, count, "\(name): spent") }
        if let count = spec["clicked"] as? Int { XCTAssertEqual(sdk.clickedCount, count, "\(name): clicked") }
    }

    /// A JSON value as plain values, every number a Double and every flag a Bool, so `1` and `1.0` compare as JSON does.
    private func plain(_ value: Any?) -> Any {
        switch value {
        case nil, is NSNull: return NSNull()
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): return number.boolValue
        case let number as NSNumber: return number.doubleValue
        case let text as String: return text
        case let object as [String: Any]: return object.mapValues { plain($0) }
        case let list as [Any]: return list.map { plain($0) }
        case let other?: return String(describing: other)
        }
    }

    /// Sorted-key JSON text, the one comparison that reads `[String: Any]` without a custom equality.
    private func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else {
            return "<unserializable \(value)>"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
