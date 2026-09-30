import XCTest
@testable import TreebarsSDK

/*
 The render contract: every case in `Fixtures/in-app-render.json` planned as the reference implementation and the Kotlin
 core plan it, so the renderer built on `inAppRenderPlan` cannot draw a message differently from the Android one.

 Each row is decoded the way the SDK decodes it — a synced message as `InAppMessage`, a feed row as
 `TreebarsNotification` — so a key the structs drop fails here, not on a device. Plans are compared as JSON: the actual
 one is written and read back through `JSONSerialization`, so a number is a number whether it was 12 or 12.0.
 */
final class InAppRenderPlanTests: XCTestCase {

    private func fixture() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/in-app-render.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], "the shared fixture is missing or malformed")
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }

    /// Through `JSONSerialization` and back, so both sides of a comparison are the same kinds of object.
    private func roundTrip(_ value: [String: Any]) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: value)) as? NSDictionary)
    }

    private func printed(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\(value)"
    }

    func testTheLayoutNumbersAreTheFixtures() throws {
        let expected = try XCTUnwrap(try fixture()["layout"] as? [String: Any])
        let actual = try roundTrip(InAppStandardLayout.json)
        XCTAssertTrue(NSDictionary(dictionary: expected).isEqual(to: actual as! [AnyHashable: Any]), printed(actual))
    }

    func testEveryMessageIsPlannedAsTheOtherCoresPlanIt() throws {
        let plans = try XCTUnwrap(try fixture()["plans"] as? [[String: Any]])
        XCTAssertFalse(plans.isEmpty)
        var overlays = 0
        for spec in plans {
            let name = "\(spec["id"] as? String ?? ""): \(spec["name"] as? String ?? "")"
            let envJson = try XCTUnwrap(spec["env"] as? [String: Any], name)
            let env = InAppRenderEnv(
                appearance: envJson["appearance"] as? String ?? "",
                platform: envJson["platform"] as? String ?? "",
                device_class: envJson["device_class"] as? String ?? "",
                fallback_tokens: try (envJson["fallback_tokens"] as? [String: Any]).map { try decode(InAppTokens.self, $0) },
                text_size: envJson["text_size"] as? String
            )
            let row = try XCTUnwrap(spec["row"] as? [String: Any], name)
            let input = spec["from"] as? String == "feed"
                ? InAppRenderInput(try decode(TreebarsNotification.self, row))
                : InAppRenderInput(try decode(InAppMessage.self, row))
            let plan = inAppRenderPlan(input, env: env)
            if case .overlay = plan { overlays += 1 }
            let expected = try XCTUnwrap(spec["expect"] as? [String: Any], name)
            let actual = try roundTrip(plan.json)
            XCTAssertTrue(
                NSDictionary(dictionary: expected).isEqual(to: actual as! [AnyHashable: Any]),
                "\(name)\nexpected \(printed(expected))\nactual \(printed(actual))"
            )
        }
        XCTAssertGreaterThan(overlays, 0)
    }

    func testTheCountdownReadsAsTheOtherCoresReadIt() throws {
        let cases = try XCTUnwrap(try fixture()["countdown_text"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for spec in cases {
            let to = try XCTUnwrap((spec["to_ms"] as? NSNumber)?.int64Value)
            let now = try XCTUnwrap((spec["now_ms"] as? NSNumber)?.int64Value)
            XCTAssertEqual(inAppCountdownText(toMs: to, nowMs: now), spec["text"] as? String, spec["name"] as? String ?? "")
        }
    }

    func testTheFormSaysWhatTheOtherCoresSay() throws {
        let cases = try XCTUnwrap(try fixture()["form_checks"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        var sent = 0
        for spec in cases {
            let name = "\(spec["id"] as? String ?? ""): \(spec["name"] as? String ?? "")"
            let fields = try decode([InAppFormField].self, try XCTUnwrap(spec["fields"])).map(inAppPlanField)
            let answers = try XCTUnwrap(spec["answers"] as? [String: Any], name)
            let problem = inAppFormProblem(fields, answers: answers)
            XCTAssertEqual(problem, spec["problem"] as? String, name)
            if problem == nil {
                sent += 1
                let expected = try XCTUnwrap(spec["sent"] as? [String: Any], name)
                let actual = try roundTrip(inAppFormAnswers(fields, answers: answers))
                XCTAssertTrue(NSDictionary(dictionary: expected).isEqual(to: actual as! [AnyHashable: Any]), "\(name): \(printed(actual))")
            }
        }
        XCTAssertGreaterThan(sent, 0)
    }
}
