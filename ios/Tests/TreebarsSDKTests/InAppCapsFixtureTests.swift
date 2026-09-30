import XCTest
@testable import TreebarsSDK

/*
 The shared fixture every core's store answers: nudges and modals and the caps, in one file (`Fixtures/in-app-caps.json`),
 so the three cores cannot drift. The store holds `UserDefaults.standard`, so each case starts from `reset()` as
 `InAppTests` does.
 */
final class InAppCapsFixtureTests: XCTestCase {

    private static let keys = ["treebars.in_app_queue", "treebars.in_app_ledger"]

    override func tearDown() {
        Self.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    func testEveryCaseIsAnsweredAsTheOtherCoresAnswerIt() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/in-app-caps.json")
        let fixture = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], "the shared fixture is missing or malformed"
        )
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        for spec in cases {
            let name = spec["name"] as? String ?? ""
            var store = InAppStore()
            store.reset()
            let messages: [[String: Any]] = try XCTUnwrap(spec["messages"] as? [[String: Any]]).map { m in
                [
                    "delivery_id": m["id"] as? String ?? "",
                    "campaign_id": NSNull(),
                    "created_at": "2026-09-28T09:00:00.000Z",
                    "expires_at": NSNull(),
                    "test": m["test"] as? Bool ?? false,
                    "content": ["in_app": [
                        "surface": "overlay", "layout": m["layout"] as? String ?? "", "body_mode": "html",
                        "html": "<p>x</p>", "trigger": ["kind": "immediate"],
                    ]],
                ]
            }
            var policy: [String: Any] = [
                "max_per_day": NSNull(), "min_gap_seconds": NSNull(), "messages_shown_today": 0, "last_shown_at": NSNull(),
            ]
            for (key, value) in try XCTUnwrap(spec["policy"] as? [String: Any]) { policy[key] = value }
            let body = try JSONSerialization.data(withJSONObject: ["messages": messages, "policy": policy])
            XCTAssertTrue(store.accept(try JSONDecoder().decode(InAppSyncResponse.self, from: body)), name)
            let byID = Dictionary(uniqueKeysWithValues: store.list().map { ($0.delivery_id, $0) })
            for row in try XCTUnwrap(spec["shown"] as? [[String: Any]]) {
                let message = try XCTUnwrap(byID[row["id"] as? String ?? ""], name)
                store.recordDisplay(
                    message, session: row["session"] as? String,
                    now: start.addingTimeInterval(Double(row["seconds"] as? Int ?? 0))
                )
            }
            // Built again from what it saved, never synced: a cold start.
            if spec["restart"] as? Bool == true { store = InAppStore() }
            for ask in try XCTUnwrap(spec["asks"] as? [[String: Any]]) {
                let id = ask["id"] as? String ?? ""
                let session = ask["session"] as? String
                let seconds = ask["seconds"] as? Int ?? 0
                let inFlight = ask["in_flight"] as? Int ?? 0
                let answer = store.blockedBy(
                    try XCTUnwrap(byID[id], name), session: session, now: start.addingTimeInterval(Double(seconds)),
                    nudgesInFlight: inFlight
                )
                XCTAssertEqual(
                    answer, ask["expect"] as? String, "\(name): \(id) in \(session ?? "-") at \(seconds)s, \(inFlight) in flight"
                )
            }
        }
    }
}
