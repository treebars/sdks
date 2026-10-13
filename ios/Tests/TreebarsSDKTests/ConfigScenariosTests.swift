import XCTest
@testable import TreebarsSDK

/**
 The shared remote config scenarios, run against this core.

 The same scenarios drive the web SDK and the Kotlin core too, so the three are held to one set of rules: when
 to ask, what a read answers, and what a sign-in or a sign-out does to both. The harness owns exactly what the
 host owns in an app — the file, the clock and the request — and scripts the answers. An ask is a real task,
 so one left out by a `hold` is genuinely still out when the next step runs; the harness counts the tasks it
 was asked to start and waits for that count, never for a length of time. What a relaunch finds is read back
 by a fresh instance over the same file.

 Disagreements are collected and asserted once, for the reason `UploaderScenariosTests` gives: in an async
 XCTest only the first failed assertion is recorded.
 */
final class ConfigScenariosTests: XCTestCase {

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // TreebarsSDKTests
        .appendingPathComponent("Fixtures/config-scenarios.json")

    private static let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first ?? URL(fileURLWithPath: NSTemporaryDirectory())

    private var filenames: [String] = []
    private let problems = Box<[String]>([])

    override func tearDown() {
        for name in filenames {
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(name))
        }
        filenames = []
        super.tearDown()
    }

    private func fixture() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.fixtureURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The waits in the scenarios are consequences of the policy, as the uploads' are.
    func testTheGeneratedPolicyIsTheOneTheConfigScenariosWereDerivedFrom() throws {
        let policy = try XCTUnwrap(try fixture()["policy"] as? [String: Any])
        XCTAssertEqual(policy["config_retry_seconds"] as? Double, TreebarsConstants.configRetry)
        XCTAssertEqual(policy["retry_after_max_seconds"] as? Double, TreebarsConstants.retryAfterMax)
        XCTAssertEqual(policy["auth_cooldown_seconds"] as? Double, TreebarsConstants.authCooldown)
        XCTAssertEqual(policy["config_exposure_floor_seconds"] as? Double, TreebarsConstants.configExposureFloor)
    }

    func testEveryConfigScenarioAgrees() async throws {
        let fixture = try fixture()
        let scenarios = try XCTUnwrap(fixture["scenarios"] as? [[String: Any]])
        for scenario in scenarios {
            try await run(scenario, fixture: fixture)
        }
        XCTAssertEqual(scenarios.count, 29, "the fixture changed size; check every scenario still runs here")
        XCTAssertTrue(problems.value.isEmpty, "\n" + problems.value.joined(separator: "\n"))
    }

    /// A JSON value as text two equal values share. `nil` and `NSNull` are both "null".
    private static func canon(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "null" }
        return ConfigEntry.canonical(value)
    }

    private static func who(_ user: String?, _ attributes: [String: Any]) -> String {
        "\(user ?? "nobody")|\(canon(attributes))"
    }

    private func run(_ scenario: [String: Any], fixture: [String: Any]) async throws {
        let id = scenario["id"] as? String ?? "?"
        let epoch = try XCTUnwrap((fixture["epoch_ms"] as? NSNumber)?.int64Value)
        let filename = "treebars-config-scenario-\(UUID().uuidString).json"
        filenames.append(filename)

        let clock = Box<Int64>(epoch)
        let asked = Box<[String]>([])
        let changes = Box<Int>(0)
        /// Each exposure reported in the running step, as the scenarios name one.
        let exposures = Box<[String]>([])
        let scripted = Box<[[String: Any]]>([])
        let holding = Box<Bool>(false)
        let out = Box<[CheckedContinuation<ConfigAnswer, Never>]>([])
        /// Tasks this core asked to have started that are still running — not counting one waiting on a `hold`.
        let active = Box<Int>(0)
        let problems = self.problems

        @Sendable func answer(for response: [String: Any]?) -> ConfigAnswer {
            guard let response else {
                problems.mutate { $0.append("\(id): an ask was started with no answer scripted for it") }
                return .failed(status: nil, retryAfter: nil)
            }
            if response["network_error"] as? Bool == true { return .failed(status: nil, retryAfter: nil) }
            if let status = response["status"] as? Int { return .failed(status: status, retryAfter: response["retry_after"] as? String) }
            var body: [String: Any] = [:]
            if let version = response["version"] { body["version"] = version }
            if let values = response["values"] { body["values"] = values }
            return .answered(body)
        }

        let fetch: @Sendable (ConfigAsk) async -> ConfigAnswer = { ask in
            asked.mutate { $0.append(Self.who(ask.userId, ask.attributes)) }
            guard holding.value else {
                return answer(for: scripted.mutate { $0.isEmpty ? nil : $0.removeFirst() })
            }
            return await withCheckedContinuation { continuation in
                out.mutate { $0.append(continuation) }
                // Waiting on a later step: no longer something this step has to wait for.
                active.mutate { $0 -= 1 }
            }
        }
        let launch: @Sendable (@escaping @Sendable () async -> Void) -> Void = { body in
            active.mutate { $0 += 1 }
            Task {
                await body()
                active.mutate { $0 -= 1 }
            }
        }
        /// Everything this step started has run to its end, or to where it waits on a later step.
        func settle() async {
            var turns = 0
            while active.value != 0 {
                await Task.yield()
                turns += 1
                if turns % 64 == 0 { try? await Task.sleep(nanoseconds: 200_000) }
                if turns > 400_000 {
                    problems.mutate { $0.append("\(id): an ask never finished") }
                    return
                }
            }
        }

        // What storage holds, in this core's own file.
        let stored = scenario["stored"] as? [String: Any] ?? [:]
        var state: [String: Any] = ["not_before": 0]
        if let config = stored["config"] as? [String: Any] {
            state["set"] = [
                "version": config["version"] ?? "",
                "values": config["values"] ?? [],
                "context": (config["asked_as"] as? [String: Any])?["context"] ?? "",
                "stale": false,
            ] as [String: Any]
        }
        if let session = stored["session"] as? [String: Any] { state["session"] = session }
        if let attributes = stored["attributes"] as? [String: Any] { state["attributes"] = attributes }
        if state.count > 1 { ConfigStore(filename: filename).save(state) }

        var config = RemoteConfig(store: nil, fetch: fetch)
        func launchApp(session: String, user: String?, context: String) {
            config = RemoteConfig(
                store: ConfigStore(filename: filename),
                fetch: fetch,
                launch: launch,
                // Written at once, so a relaunch in the next step reads what this one left.
                persist: { store, state in store.save(state) },
                now: { clock.value },
                expose: { exposure in
                    exposures.mutate { $0.append("\(exposure.experimentKey)|\(exposure.variant)|\(exposure.variable)") }
                }
            )
            config.onChange { changes.mutate { $0 += 1 } }
            config.start(sessionId: session, userId: user, context: context)
        }

        func verify(_ label: String, _ expected: [String: Any]?, _ result: Any?) {
            guard let expected else { return }
            func differ(_ what: String, _ wanted: String, _ got: String) {
                if wanted != got { problems.mutate { $0.append("\(label): \(what): expected \(wanted), got \(got)") } }
            }
            if let fetches = expected["fetches"] as? [[String: Any]] {
                let wanted = fetches.map { Self.who($0["user"] as? String, $0["attributes"] as? [String: Any] ?? [:]) }
                differ("who asked", "\(wanted)", "\(asked.value)")
            }
            if expected.keys.contains("held") { differ("the version held", expected["held"] as? String ?? "nil", config.version ?? "nil") }
            if let count = expected["changes"] as? Int { differ("changes announced", "\(count)", "\(changes.value)") }
            if let wanted = expected["result"] as? Bool { differ("what the call answered", "\(wanted)", "\(result as? Bool ?? !wanted)") }
            if expected.keys.contains("value") { differ("what the read answered", Self.canon(expected["value"]), Self.canon(result)) }
            if let wanted = expected["exposures"] as? [[String: Any]] {
                let named = wanted.map { "\($0["experiment"] as? String ?? "?")|\($0["variant"] as? String ?? "?")|\($0["variable"] as? String ?? "?")" }
                differ("exposures reported", "\(named)", "\(exposures.value)")
            }
        }

        let start = scenario["start"] as? [String: Any] ?? [:]
        scripted.value = start["responses"] as? [[String: Any]] ?? []
        launchApp(session: start["session"] as? String ?? "", user: start["user"] as? String, context: start["context"] as? String ?? "")
        await settle()
        verify("\(id) start", start["expect"] as? [String: Any], nil)
        if !scripted.value.isEmpty { problems.mutate { $0.append("\(id) start: answers scripted and never asked for") } }

        for (index, step) in (scenario["steps"] as? [[String: Any]] ?? []).enumerated() {
            let action = step["do"] as? String ?? "?"
            let label = "\(id) step \(index + 1) (\(action))"
            if let at = (step["at"] as? NSNumber)?.int64Value { clock.value = epoch + at }
            asked.value = []
            changes.value = 0
            exposures.value = []
            scripted.value = step["responses"] as? [[String: Any]] ?? []
            holding.value = step["hold"] as? Bool ?? false
            var result: Any?

            switch action {
            case "read":
                result = config.read(step["key"] as? String ?? "", as: step["as"] as? String ?? "") ?? step["fallback"]
            case "list": _ = config.all()
            case "upload": config.observe(step["config_version"] as? String)
            case "session": config.sessionStarted(step["id"] as? String ?? "")
            case "identify": config.identityChanged(step["user"] as? String)
            case "reset": config.identityChanged(nil)
            case "attributes": config.setAttributes(step["set"] as? [String: Any] ?? [:])
            case "activate": result = config.activate()
            case "override":
                let value = step["value"]
                config.override(step["key"] as? String ?? "", value is NSNull ? nil : value)
            case "fetch": result = await config.refresh()
            case "answer":
                // The asks left out are answered in the order they were started; one an answer starts takes the next.
                while let waiting = out.mutate({ $0.isEmpty ? nil : $0.removeFirst() }) {
                    active.mutate { $0 += 1 }
                    waiting.resume(returning: answer(for: scripted.mutate { $0.isEmpty ? nil : $0.removeFirst() }))
                    await settle()
                }
            case "relaunch":
                launchApp(session: step["session"] as? String ?? "", user: step["user"] as? String, context: step["context"] as? String ?? "")
            default:
                problems.mutate { $0.append("\(label): a step this harness does not know") }
            }
            await settle()
            holding.value = false
            verify(label, step["expect"] as? [String: Any], result)
            if !scripted.value.isEmpty { problems.mutate { $0.append("\(label): answers scripted and never asked for") } }
        }
        if !out.value.isEmpty { problems.mutate { $0.append("\(id): an ask was left out and never answered") } }
    }
}
