import XCTest
@testable import TreebarsSDK

/**
 The shared reward-claim scenarios, run against this core.

 The same scenarios drive the web SDK and the Kotlin core too: three cores ask for a reward again the same way only if
 each is asked the same questions. The request is scripted, and the clocks and the jitter are handed in; the harness's
 clock moves only by what a request took and by the waits the loop sleeps.

 Disagreements are collected and asserted once at the end, for the reason `UploaderScenariosTests` gives: an async test
 records the first failed `XCTAssertEqual` and none after it. The fixture is found from `#filePath`, as there.
 */
final class RewardClaimTests: XCTestCase {

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // TreebarsSDKTests
        .appendingPathComponent("Fixtures/reward-claim-scenarios.json")

    private func fixture() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.fixtureURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The numbers in the scenarios are consequences of the policy; a moved constant would make them check the wrong sums.
    func testTheGeneratedPolicyIsTheOneTheScenariosWereDerivedFrom() throws {
        let policy = try XCTUnwrap(try fixture()["policy"] as? [String: Any])
        XCTAssertEqual(policy["retries"] as? Int, TreebarsConstants.rewardClaimRetries)
        XCTAssertEqual((policy["budget_ms"] as? Double).map { $0 / 1000 }, TreebarsConstants.rewardClaimBudget)
        XCTAssertEqual(Set(policy["retry_after_statuses"] as? [Int] ?? []), TreebarsConstants.retryAfterStatuses)
        XCTAssertEqual(policy["backoff_base_seconds"] as? Double, TreebarsConstants.backoffBase)
        XCTAssertEqual(policy["backoff_cap_seconds"] as? Double, TreebarsConstants.backoffCap)
    }

    func testEveryScenarioAgrees() async throws {
        let fixture = try fixture()
        let scenarios = try XCTUnwrap(fixture["scenarios"] as? [[String: Any]])
        let nowMs = (fixture["now_ms"] as? NSNumber)?.int64Value ?? 0
        var problems: [String] = []

        for scenario in scenarios {
            let id = scenario["id"] as? String ?? "?"
            let expect = scenario["expect"] as? [String: Any] ?? [:]
            var answers = scenario["answers"] as? [[String: Any]] ?? []
            var randoms = (scenario["random"] as? [NSNumber] ?? []).map(\.doubleValue)
            var clock: Int64 = 0
            var requests = 0
            var waits: [Int64] = []

            let last = await claimWithRetries(
                ask: {
                    guard !answers.isEmpty else {
                        problems.append("\(id): a request with no answer left")
                        return RewardAttempt(status: -1)
                    }
                    let next = answers.removeFirst()
                    requests += 1
                    clock += (next["took_ms"] as? NSNumber)?.int64Value ?? 0
                    return RewardAttempt(
                        status: (next["status"] as? NSNumber)?.intValue ?? -1,
                        retryAfter: next["retry_after"] as? String,
                        answer: (next["answer"] as? Bool) == true ? ["won": true] : nil
                    )
                },
                elapsed: { clock },
                now: { nowMs + clock },
                sleep: { ms in
                    waits.append(ms)
                    clock += ms
                },
                random: {
                    guard !randoms.isEmpty else {
                        problems.append("\(id): a jitter draw the scenario did not expect")
                        return 0
                    }
                    return randoms.removeFirst()
                }
            )

            let expectedWaits = (expect["waits"] as? [NSNumber] ?? []).map(\.int64Value)
            let outcome = last.answer != nil ? "answer" : rewardRefusalReason(last)
            if requests != expect["requests"] as? Int { problems.append("\(id) requests: expected \(expect["requests"] ?? "?"), got \(requests)") }
            if waits != expectedWaits { problems.append("\(id) waits: expected \(expectedWaits), got \(waits)") }
            if outcome != expect["outcome"] as? String { problems.append("\(id) outcome: expected \(expect["outcome"] ?? "?"), got \(outcome)") }
            if !randoms.isEmpty { problems.append("\(id): random values never drawn: \(randoms)") }
            if !answers.isEmpty { problems.append("\(id): \(answers.count) answer(s) never asked for") }
        }

        XCTAssertFalse(scenarios.isEmpty, "no scenario ran")
        XCTAssertTrue(problems.isEmpty, "\n" + problems.joined(separator: "\n"))
    }
}
