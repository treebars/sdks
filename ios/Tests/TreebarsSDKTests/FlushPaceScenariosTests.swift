import XCTest
@testable import TreebarsSDK

/**
 The shared pace scenarios, run against this core.

 The same scenarios drive the web SDK and the Kotlin core too. Each one is run against `FlushPace`
 wired to the real `EventUploader` the way `Treebars.initialize` wires them: the pace is handed to
 the uploader, which tells it as each batch goes out and what spacing an accepted one named, and
 every queued event is told to the uploader and then to the pace, as `announceQueued` does. So a
 listed event's own wake, a full batch and the pace's wake are all live at once, which is the only
 arrangement in which "whichever is later" means anything.

 Uploads go through the real `BackendClient` and `URLSession`, answered by a `URLProtocol` — the
 spacing is read off an `HTTPURLResponse` by the code that reads it on a device. Both sets of wakes
 sleep in one `ManualWakes`, whose clock only the scenario moves.

 Disagreements are collected and asserted once, for the reason `UploaderScenariosTests` gives: in
 an async XCTest only the first failed assertion is recorded.
 */
final class FlushPaceScenariosTests: XCTestCase {

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // TreebarsSDKTests
        .appendingPathComponent("Fixtures/flush-pace-scenarios.json")

    private static let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first ?? URL(fileURLWithPath: NSTemporaryDirectory())

    private var filenames: [String] = []
    private let problems = Box<[String]>([])

    private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        guard actual != expected else { return }
        problems.mutate { $0.append("\(label): expected \(expected), got \(actual)") }
    }

    override func tearDown() {
        for name in filenames {
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(name))
        }
        filenames = []
        ScriptedPaceIngest.shared.script([])
        super.tearDown()
    }

    private func fixture() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.fixtureURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The numbers in the scenarios are consequences of the policy. Every key is named, so a number
    /// the fixture gains is one this suite has to be taught rather than one it never reads.
    func testTheGeneratedPolicyIsTheOneThePaceScenariosWereDerivedFrom() throws {
        let policy = try XCTUnwrap(try fixture()["policy"] as? [String: Any])
        let generated: [String: Double] = [
            "debounce_ms": TreebarsConstants.flushDebounce * 1000,
            "spacing_ms": TreebarsConstants.flushSpacing * 1000,
            "spacing_metered_ms": TreebarsConstants.flushSpacingMetered * 1000,
            "spacing_test_ms": TreebarsConstants.flushSpacingTest * 1000,
            // A device saving power or data keeps the interval the public `defaultFlushInterval` names.
            "spacing_constrained_ms": TreebarsConstants.defaultFlushInterval * 1000,
            "spacing_min_ms": TreebarsConstants.flushSpacingMin * 1000,
            "spacing_max_ms": TreebarsConstants.flushSpacingMax * 1000,
            "batch_size": Double(TreebarsConstants.batchSize),
        ]
        XCTAssertEqual(policy.compactMapValues { ($0 as? NSNumber)?.doubleValue }, generated)
        XCTAssertEqual(Set(policy.keys), Set(generated.keys))
        // A listed event waits the same second; it differs only in not waiting for the spacing.
        XCTAssertEqual(TreebarsConstants.triggerFlushDebounce, TreebarsConstants.flushDebounce)
        // And the public name an app reads is the constrained spacing, not a number of its own.
        XCTAssertEqual(Treebars.defaultFlushInterval, TreebarsConstants.defaultFlushInterval)
    }

    func testEveryPaceScenarioAgrees() async throws {
        let fixture = try fixture()
        let scenarios = try XCTUnwrap(fixture["scenarios"] as? [[String: Any]])
        for scenario in scenarios {
            try await run(scenario, fixture: fixture)
        }
        XCTAssertEqual(scenarios.count, 20, "the fixture changed size; check every scenario still runs here")
        XCTAssertTrue(problems.value.isEmpty, "\n" + problems.value.joined(separator: "\n"))
    }

    /// What a scenario or a step may say. Anything else is something this harness would otherwise
    /// ignore and pass — a new condition, a new kind of answer — so it is a failure instead.
    private static let scenarioKeys: Set<String> = ["id", "rule", "name", "key", "network", "flush_interval_ms", "batch_size", "queue", "steps"]
    private static let stepKeys: Set<String> = ["do", "at", "events", "trigger", "responses", "expect"]
    private static let responseKeys: Set<String> = ["status", "flush_ms"]

    private static func event(_ id: String) -> [String: Any] {
        [
            "event_id": id,
            "session_id": "s1",
            "device_id": "dev_fixture",
            // The id is the name as well, so a step marked `trigger` lists its events by it.
            "event_name": id,
            "properties": [String: Any](),
            "timestamp": "2026-09-15T12:00:00.000Z",
            "sdk_version": TreebarsConstants.sdkVersion,
        ]
    }

    private func run(_ scenario: [String: Any], fixture: [String: Any]) async throws {
        let id = scenario["id"] as? String ?? "?"
        let epoch = try XCTUnwrap((fixture["epoch_ms"] as? NSNumber)?.int64Value)
        let steps = scenario["steps"] as? [[String: Any]] ?? []
        let batchSize = scenario["batch_size"] as? Int ?? TreebarsConstants.batchSize
        let chosen = (scenario["flush_interval_ms"] as? NSNumber).map { $0.doubleValue / 1000 }

        expectEqual(Set(scenario.keys).subtracting(Self.scenarioKeys), [], "\(id): keys this harness does not read")

        let writeKey: String
        switch scenario["key"] as? String ?? "live" {
        case "live": writeKey = "pk_live_fixture0000000000"
        case "test": writeKey = "pk_test_fixture0000000000"
        case let other:
            problems.mutate { $0.append("\(id): `\(other)` is not a kind of write key this harness knows") }
            return
        }

        let conditions: FlushConditions
        switch scenario["network"] as? String ?? "unmetered" {
        case "unmetered": conditions = FlushConditions()
        case "metered": conditions = FlushConditions(metered: true)
        case "constrained": conditions = FlushConditions(constrained: true)
        case let other:
            problems.mutate { $0.append("\(id): `\(other)` is not a network this harness knows") }
            return
        }

        let unique = UUID().uuidString
        let queueName = "treebars-queue-pace-\(unique).json"
        let storeName = "treebars-uploader-pace-\(unique).json"
        let triggersName = "treebars-triggers-pace-\(unique).json"
        filenames += [queueName, storeName, triggersName]

        let ingest = ScriptedPaceIngest.shared
        ingest.script([])
        let clock = Box<Int64>(epoch)
        let minted = Box<Int>(0)
        let wakes = ManualWakes(clock: clock)

        // The events of every step marked `trigger` are on the stored list from the start.
        let listed = steps.filter { ($0["trigger"] as? Bool) == true }.flatMap { $0["events"] as? [String] ?? [] }
        if !listed.isEmpty {
            TriggerStore(filename: triggersName).save(TriggerList(version: "v1", names: listed))
        }

        // What storage holds before the first step: on the queue, and told to nobody — an earlier
        // launch logged it, and neither the uploader nor the pace of this one has heard of it.
        let queue = EventQueue(filename: queueName)
        for event in scenario["queue"] as? [String] ?? [] {
            await queue.append(Self.event(event))
        }
        let client = BackendClient(
            backendURL: URL(string: "https://\(ScriptedPaceIngestProtocol.host)")!,
            writeKey: writeKey,
            protocolClasses: [ScriptedPaceIngestProtocol.self]
        )

        // As `Treebars.initialize` builds them: the pace first, then the uploader holding the pace,
        // and then the pace told that what falls due is a flush of that uploader.
        let pace = FlushPace(
            chosen: chosen,
            testKey: FlushPace.isTestKey(writeKey),
            now: { clock.value },
            conditions: { conditions },
            wakes: wakes
        )
        let uploader = EventUploader(
            queue: queue,
            transport: client,
            store: UploaderStore(filename: storeName),
            writeKey: writeKey,
            batchSize: batchSize,
            now: { clock.value },
            random: {
                // No scenario retries anything, so nothing here should draw. Not zero, for the
                // reason `TriggerScenariosTests` gives: a retry after no delay would never settle.
                ingest.note("a random draw")
                return 0.5
            },
            newBatchId: { minted.mutate { $0 += 1; return "b\($0)" } },
            wakes: wakes,
            triggers: TriggerEvents(store: TriggerStore(filename: triggersName)) { nil },
            pace: pace
        )
        pace.onDue { [weak uploader] in await uploader?.flush() }
        defer { wakes.dropAll() }

        let problemsBefore = problems.value.count
        for (index, step) in steps.enumerated() {
            // A scenario stops at its first disagreement: every step after one describes a state
            // this core is no longer in.
            if problems.value.count > problemsBefore { break }
            let action = step["do"] as? String ?? "?"
            let label = "\(id) step \(index + 1) (\(action))"
            let at = (step["at"] as? NSNumber)?.int64Value ?? 0
            let answers = step["responses"] as? [[String: Any]] ?? []

            expectEqual(Set(step.keys).subtracting(Self.stepKeys), [], "\(label): keys this harness does not read")
            for answer in answers {
                expectEqual(Set(answer.keys).subtracting(Self.responseKeys), [], "\(label): an answer this harness cannot give")
            }

            ingest.script(answers.map {
                ScriptedPaceIngest.Answer(status: $0["status"] as? Int ?? 0, flushMs: ($0["flush_ms"] as? NSNumber)?.int64Value)
            })

            if !(await wakes.advance(to: epoch + at)) {
                problems.mutate { $0.append("\(label): wakes kept falling due; the scenario cannot settle") }
                break
            }
            switch action {
            case "track":
                for event in step["events"] as? [String] ?? [] {
                    // `Treebars.enqueue` and `announceQueued`, in their order: on the queue, told to
                    // the uploader, told to the pace, and a full batch goes at once.
                    await queue.append(Self.event(event))
                    await uploader.eventLogged(event)
                    pace.eventLogged()
                    if await queue.count >= batchSize { await uploader.flush() }
                }
            case "advance":
                break
            default:
                problems.mutate { $0.append("\(label): `\(action)` is not a step this core can take") }
            }

            // An upload with no response left, and a response never used.
            expectEqual(ingest.unscripted, [], "\(label): not in the scenario")
            expectEqual(ingest.unused, 0, "\(label): responses never asked for")

            let expected = ((step["expect"] as? [String: Any])?["sent"] as? [[String: Any]] ?? []).map { $0["events"] as? [String] ?? [] }
            expectEqual(ingest.sent, expected, "\(label): sent")
        }
    }

    // MARK: - What the scenarios cannot reach

    /// The clock, the wakes and a count of the flushes a pace asked for, with no uploader behind it.
    private func bench(
        chosen: TimeInterval? = nil,
        testKey: Bool = false,
        conditions: FlushConditions = FlushConditions()
    ) -> (pace: FlushPace, clock: Box<Int64>, wakes: ManualWakes, flushes: Box<Int>) {
        let clock = Box<Int64>(1_700_000_000_000)
        let wakes = ManualWakes(clock: clock)
        let flushes = Box<Int>(0)
        let pace = FlushPace(
            chosen: chosen,
            testKey: testKey,
            now: { clock.value },
            conditions: { conditions },
            wakes: wakes
        )
        pace.onDue { flushes.mutate { $0 += 1 } }
        return (pace, clock, wakes, flushes)
    }

    /// The spacing holds for the whole of an armed wait, not only at the moment it was armed: an
    /// upload that begins in between pushes the armed one out, and it is still one upload.
    func testAnUploadThatBeginsWhileOneIsArmedPushesItOutToTheEndOfItsSpacing() async {
        let (pace, clock, wakes, flushes) = bench()
        let start = clock.value
        let debounce = Int64(TreebarsConstants.flushDebounce * 1000)
        let spacing = Int64(TreebarsConstants.flushSpacing * 1000)

        pace.eventLogged()
        XCTAssertEqual(pace.dueAt, start + debounce)

        // An upload nobody paced — a flush the app asked for, a listed event's — half way through.
        clock.value = start + debounce / 2
        pace.uploadBegan(at: clock.value)
        XCTAssertEqual(pace.dueAt, start + debounce / 2 + spacing)

        // A later event rides the wait and does not move it.
        pace.eventLogged()
        XCTAssertEqual(pace.dueAt, start + debounce / 2 + spacing)

        await wakes.advance(to: start + debounce / 2 + spacing - 1)
        XCTAssertEqual(flushes.value, 0)
        await wakes.advance(to: start + debounce / 2 + spacing)
        XCTAssertEqual(flushes.value, 1)
        XCTAssertNil(pace.dueAt, "a wake that fired is spent")

        await wakes.advance(to: start + 10 * spacing)
        XCTAssertEqual(flushes.value, 1, "one event armed one upload")
    }

    /// The upload a fired wake starts is told to the pace like any other, and finds nothing armed.
    func testTheUploadAPacedFlushStartsArmsNothing() async {
        let (pace, clock, wakes, flushes) = bench()
        pace.eventLogged()
        await wakes.advance(to: clock.value + Int64(TreebarsConstants.flushDebounce * 1000))
        XCTAssertEqual(flushes.value, 1)
        pace.uploadBegan(at: clock.value)
        XCTAssertNil(pace.dueAt)
    }

    func testTheSpacingIsDecidedInTheOrderThePolicyGivesIt() {
        let ms = { (seconds: TimeInterval) in Int64(seconds * 1000) }
        let quiet = FlushConditions()
        let metered = FlushConditions(metered: true)
        let saving = FlushConditions(constrained: true)
        func spacing(chosen: Int64? = nil, testKey: Bool = false, named: Int64? = nil, _ conditions: FlushConditions) -> Int64 {
            FlushPace.spacing(chosen: chosen, testKey: testKey, named: named, in: conditions)
        }

        // An app that chose nothing gets the pace; one that chose thirty seconds gets thirty.
        XCTAssertEqual(spacing(quiet), ms(TreebarsConstants.flushSpacing))
        XCTAssertEqual(spacing(chosen: 30_000, quiet), 30_000)
        XCTAssertEqual(spacing(chosen: 30_000, testKey: true, named: 2000, metered), 30_000)
        XCTAssertEqual(spacing(chosen: 0, quiet), ms(TreebarsConstants.flushDebounce))

        XCTAssertEqual(spacing(testKey: true, named: 20_000, metered), ms(TreebarsConstants.flushSpacingTest))
        XCTAssertEqual(spacing(named: 2000, quiet), 2000)
        XCTAssertEqual(spacing(named: 2000, metered), ms(TreebarsConstants.flushSpacingMetered))
        XCTAssertEqual(spacing(named: 40_000, metered), 40_000, "the metered spacing is a floor, not a value")

        // Saving power or data outranks all of it, a longer choice included.
        for chosen in [nil, 1000, 120_000] as [Int64?] {
            XCTAssertEqual(spacing(chosen: chosen, testKey: true, named: 1000, saving), ms(TreebarsConstants.defaultFlushInterval))
        }
    }

    func testAResponsesSpacingIsWholeMillisecondsHeldToTheBounds() {
        let least = Int64(TreebarsConstants.flushSpacingMin * 1000)
        let most = Int64(TreebarsConstants.flushSpacingMax * 1000)

        XCTAssertEqual(FlushPace.spacing(fromHeader: "2000"), 2000)
        XCTAssertEqual(FlushPace.spacing(fromHeader: " 2000 "), 2000)
        XCTAssertEqual(FlushPace.spacing(fromHeader: "0"), least)
        XCTAssertEqual(FlushPace.spacing(fromHeader: "100"), least)
        XCTAssertEqual(FlushPace.spacing(fromHeader: "999999"), most)
        XCTAssertEqual(FlushPace.spacing(fromHeader: String(repeating: "9", count: 40)), most)
        // Nothing this can read is no news: the spacing in force stays.
        for unreadable in [nil, "", " ", "fast", "-2000", "2000.5", "2e3", "2000ms", "+2000", "٢٠٠٠"] as [String?] {
            XCTAssertNil(FlushPace.spacing(fromHeader: unreadable), unreadable ?? "nil")
        }
    }

    /// A chosen interval is seconds from an app, so it can be anything a `Double` can.
    func testAnIntervalNoClockCouldCountIsStillAnInterval() async {
        for odd in [TimeInterval.infinity, .greatestFiniteMagnitude, -5, .nan] {
            let (pace, clock, wakes, flushes) = bench(chosen: odd)
            pace.eventLogged()
            // Nothing uploaded yet, so whatever the spacing is, the first event is a debounce away.
            await wakes.advance(to: clock.value + Int64(TreebarsConstants.flushDebounce * 1000))
            XCTAssertEqual(flushes.value, 1, "\(odd)")
            // And the next one is armed, at a moment that can be counted, never before its debounce.
            let began = clock.value
            pace.uploadBegan(at: began)
            pace.eventLogged()
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(pace.dueAt), began + Int64(TreebarsConstants.flushDebounce * 1000), "\(odd)")
        }
    }

    /// The last upload is remembered by the wall clock, and a wall clock can be set back.
    func testAClockSetBackDoesNotHoldTheNextUploadForTheDifference() {
        let (pace, clock, _, _) = bench()
        let spacing = Int64(TreebarsConstants.flushSpacing * 1000)
        pace.uploadBegan(at: clock.value)

        clock.value -= 24 * 60 * 60 * 1000
        pace.eventLogged()
        XCTAssertEqual(pace.dueAt, clock.value + spacing)
    }

    /**
     The server's word outlives the process: an accepted upload's spacing is written with the
     acknowledgement, and an uploader built over the same file hands it to its pace before anything
     is logged — and a pace that began again from the default would be visibly faster than this.
     */
    func testTheSpacingAnAcceptedUploadNamedIsWhereTheNextLaunchStarts() async throws {
        let unique = UUID().uuidString
        let queueName = "treebars-queue-pace-\(unique).json"
        let storeName = "treebars-uploader-pace-\(unique).json"
        filenames += [queueName, storeName]
        let epoch: Int64 = 1_700_000_000_000
        let named: Int64 = 20_000
        let ingest = ScriptedPaceIngest.shared

        func launch(at clock: Box<Int64>) -> (FlushPace, EventUploader, EventQueue, ManualWakes) {
            let wakes = ManualWakes(clock: clock)
            let queue = EventQueue(filename: queueName)
            let pace = FlushPace(chosen: nil, testKey: false, now: { clock.value }, conditions: { FlushConditions() }, wakes: wakes)
            let uploader = EventUploader(
                queue: queue,
                transport: BackendClient(
                    backendURL: URL(string: "https://\(ScriptedPaceIngestProtocol.host)")!,
                    writeKey: "pk_live_fixture0000000000",
                    protocolClasses: [ScriptedPaceIngestProtocol.self]
                ),
                store: UploaderStore(filename: storeName),
                writeKey: "pk_live_fixture0000000000",
                now: { clock.value },
                wakes: wakes,
                pace: pace
            )
            pace.onDue { [weak uploader] in await uploader?.flush() }
            return (pace, uploader, queue, wakes)
        }

        let first = Box<Int64>(epoch)
        let (pace, uploader, queue, wakes) = launch(at: first)
        ingest.script([ScriptedPaceIngest.Answer(status: 200, flushMs: named)])
        await queue.append(Self.event("e1"))
        await uploader.eventLogged("e1")
        pace.eventLogged()
        await wakes.advance(to: epoch + Int64(TreebarsConstants.flushDebounce * 1000))
        XCTAssertEqual(ingest.sent, [["e1"]])
        XCTAssertEqual(UploaderStore(filename: storeName).load().flushSpacingMs, named)
        wakes.dropAll()

        // An answer that names no spacing leaves the stored one standing.
        ingest.script([ScriptedPaceIngest.Answer(status: 200, flushMs: nil)])
        await queue.append(Self.event("e2"))
        await uploader.flush()
        XCTAssertEqual(UploaderStore(filename: storeName).load().flushSpacingMs, named)

        // The next launch, a minute later: its first upload begins, and the event after it waits out
        // the spacing the previous launch was told rather than the default.
        let second = Box<Int64>(epoch + 60_000)
        let (relaunched, _, _, relaunchedWakes) = launch(at: second)
        relaunched.uploadBegan(at: second.value)
        relaunched.eventLogged()
        XCTAssertEqual(relaunched.dueAt, second.value + named)
        relaunchedWakes.dropAll()
    }

    // MARK: - A backlog

    /// A pace and the real uploader over files of this test's own, wired as the scenarios wire them,
    /// with `queued` already in storage and told to neither.
    private func rig(queued: [String], batchSize: Int) async -> (pace: FlushPace, uploader: EventUploader, wakes: ManualWakes, clock: Box<Int64>) {
        let unique = UUID().uuidString
        let queueName = "treebars-queue-pace-\(unique).json"
        let storeName = "treebars-uploader-pace-\(unique).json"
        filenames += [queueName, storeName]
        let clock = Box<Int64>(1_700_000_000_000)
        let wakes = ManualWakes(clock: clock)
        let minted = Box<Int>(0)
        let queue = EventQueue(filename: queueName)
        for event in queued { await queue.append(Self.event(event)) }

        let pace = FlushPace(chosen: nil, testKey: false, now: { clock.value }, conditions: { FlushConditions() }, wakes: wakes)
        let uploader = EventUploader(
            queue: queue,
            transport: BackendClient(
                backendURL: URL(string: "https://\(ScriptedPaceIngestProtocol.host)")!,
                writeKey: "pk_live_fixture0000000000",
                protocolClasses: [ScriptedPaceIngestProtocol.self]
            ),
            store: UploaderStore(filename: storeName),
            writeKey: "pk_live_fixture0000000000",
            batchSize: batchSize,
            now: { clock.value },
            random: { 0.5 },
            newBatchId: { minted.mutate { $0 += 1; return "b\($0)" } },
            wakes: wakes,
            pace: pace
        )
        pace.onDue { [weak uploader] in await uploader?.flush() }
        return (pace, uploader, wakes, clock)
    }

    /**
     The shared scenario's backlog is drained by an upload an event had armed. This is the same rule
     with no event anywhere: what an earlier launch left, sent by the flush on the way up, to a pace
     that has been told of nothing.
     */
    func testABacklogKeepsGoingASpacingAtATimeWithNoEventLoggedAtAll() async {
        let ingest = ScriptedPaceIngest.shared
        let ok = ScriptedPaceIngest.Answer(status: 200, flushMs: nil)
        let spacing = Int64(TreebarsConstants.flushSpacing * 1000)
        let drain = TreebarsConstants.drainMaxBatches
        // Two drains and one batch more, a batch being two events.
        let events = (1...(4 * drain + 2)).map { "q\($0)" }
        let batches = stride(from: 0, to: events.count, by: 2).map { Array(events[$0..<$0 + 2]) }
        let (pace, uploader, wakes, clock) = await rig(queued: events, batchSize: 2)
        defer { wakes.dropAll() }
        let start = clock.value

        XCTAssertNil(pace.dueAt)
        ingest.script(Array(repeating: ok, count: drain))
        await uploader.flush()
        XCTAssertEqual(ingest.sent, Array(batches[..<drain]))
        XCTAssertEqual(pace.dueAt, start + spacing, "armed a spacing after the upload began, by nothing but the backlog")

        ingest.script([])
        await wakes.advance(to: start + spacing - 1)
        XCTAssertEqual(ingest.sent, [])

        // The second drain is cut short as well, so it arms a third, counted from when IT began.
        ingest.script(Array(repeating: ok, count: drain))
        await wakes.advance(to: start + spacing)
        XCTAssertEqual(ingest.sent, Array(batches[drain..<2 * drain]))
        XCTAssertEqual(pace.dueAt, start + 2 * spacing)

        ingest.script([ok])
        await wakes.advance(to: start + 2 * spacing)
        XCTAssertEqual(ingest.sent, [batches[2 * drain]])
        XCTAssertEqual(ingest.unused, 0)

        // The queue is empty, and an empty queue arms nothing.
        XCTAssertNil(pace.dueAt)
        ingest.script([])
        await wakes.advance(to: start + 20 * spacing)
        XCTAssertEqual(ingest.sent, [])
        XCTAssertEqual(ingest.unscripted, [])
    }

    /// A batch the server will never take ends the drain, and holds nothing back: what was behind
    /// it goes a spacing later rather than whenever the next event happens to be logged.
    func testEventsBehindADroppedBatchAreABacklog() async {
        let ingest = ScriptedPaceIngest.shared
        let (pace, uploader, wakes, clock) = await rig(queued: ["q1", "q2", "q3"], batchSize: 2)
        defer { wakes.dropAll() }
        let start = clock.value
        let spacing = Int64(TreebarsConstants.flushSpacing * 1000)

        ingest.script([ScriptedPaceIngest.Answer(status: 400, flushMs: nil)])
        await uploader.flush()
        XCTAssertEqual(ingest.sent, [["q1", "q2"]])
        XCTAssertEqual(pace.dueAt, start + spacing)

        ingest.script([ScriptedPaceIngest.Answer(status: 200, flushMs: nil)])
        await wakes.advance(to: start + spacing)
        XCTAssertEqual(ingest.sent, [["q3"]])
        XCTAssertNil(pace.dueAt)
    }

    /// A gate is the uploader's to wait out, with a wake of its own for a retry and none for a
    /// refused key. Arming the pace behind either would only knock on a door that is shut.
    func testEventsHeldBehindAClosedGateAreNotABacklog() async {
        let ingest = ScriptedPaceIngest.shared

        // Told to wait thirty seconds: the uploader's own wake sends it then, and the pace arms nothing.
        var (pace, uploader, wakes, clock) = await rig(queued: ["q1", "q2", "q3"], batchSize: 2)
        ingest.script([ScriptedPaceIngest.Answer(status: 503, flushMs: nil, retryAfter: "30")])
        await uploader.flush()
        XCTAssertEqual(ingest.sent, [["q1", "q2"]])
        XCTAssertNil(pace.dueAt)
        ingest.script([])
        await wakes.advance(to: clock.value + 29_999)
        XCTAssertEqual(ingest.sent, [])
        ingest.script(Array(repeating: ScriptedPaceIngest.Answer(status: 200, flushMs: nil), count: 2))
        await wakes.advance(to: clock.value + 1)
        XCTAssertEqual(ingest.sent, [["q1", "q2"], ["q3"]])
        XCTAssertNil(pace.dueAt)
        wakes.dropAll()

        // A refused write key: nothing is armed anywhere, and nothing goes however long it is left
        // within the cooldown.
        (pace, uploader, wakes, clock) = await rig(queued: ["q1", "q2", "q3"], batchSize: 2)
        ingest.script([ScriptedPaceIngest.Answer(status: 401, flushMs: nil)])
        await uploader.flush()
        XCTAssertEqual(ingest.sent, [["q1", "q2"]])
        XCTAssertNil(pace.dueAt)
        ingest.script([])
        await wakes.advance(to: clock.value + Int64(TreebarsConstants.authCooldown * 1000) - 1)
        XCTAssertEqual(ingest.sent, [])
        XCTAssertEqual(ingest.unscripted, [])
        wakes.dropAll()
    }

    // MARK: - Which app a lifecycle event is from

    func testALifecycleEventNamesTheAppByItsDisplayNameThenItsBundleName() {
        XCTAssertEqual(DeviceInfo.appName(in: ["CFBundleDisplayName": "Acme Shop", "CFBundleName": "AcmeShop"]), "Acme Shop")
        XCTAssertEqual(DeviceInfo.appName(in: ["CFBundleName": "AcmeShop"]), "AcmeShop")
        // A display name that is there and blank is not a name.
        XCTAssertEqual(DeviceInfo.appName(in: ["CFBundleDisplayName": "  ", "CFBundleName": "AcmeShop"]), "AcmeShop")
        XCTAssertNil(DeviceInfo.appName(in: ["CFBundleDisplayName": "", "CFBundleName": " \n"]))
        XCTAssertNil(DeviceInfo.appName(in: ["CFBundleIdentifier": "com.example.acme"]))
        XCTAssertNil(DeviceInfo.appName(in: nil))
    }

    func testEachLifecycleEventCarriesTheNameBesideWhatItMeasured() {
        let open = Treebars.lifecycleProperties(["is_first_launch": true], appName: "Acme Shop")
        XCTAssertEqual(open["name"] as? String, "Acme Shop")
        XCTAssertEqual(open["is_first_launch"] as? Bool, true)
        XCTAssertEqual(Set(open.keys), ["is_first_launch", "name"])

        let foreground = Treebars.lifecycleProperties(["background_ms": 1200], appName: "Acme Shop")
        XCTAssertEqual(Set(foreground.keys), ["background_ms", "name"])
        let background = Treebars.lifecycleProperties(["foreground_ms": 900], appName: "Acme Shop")
        XCTAssertEqual(Set(background.keys), ["foreground_ms", "name"])

        // An app whose bundle declares no name sends what it always sent: no `name`, not an empty one.
        XCTAssertEqual(Set(Treebars.lifecycleProperties(["background_ms": 1200], appName: nil).keys), ["background_ms"])
    }
}

/// The ingest endpoint as the pace scenarios script it, shared with the `URLProtocol` that answers.
final class ScriptedPaceIngest: @unchecked Sendable {
    struct Answer {
        let status: Int
        /// The spacing the answer names, or nil when it names none.
        let flushMs: Int64?
        /// No scenario scripts one; the tests of a closed gate do.
        var retryAfter: String? = nil
    }

    static let shared = ScriptedPaceIngest()

    private let lock = NSLock()
    private var answers: [Answer] = []
    private var _sent: [[String]] = []
    private var _unscripted: [String] = []

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// The answers for the next step, which also starts that step's record.
    func script(_ answers: [Answer]) {
        locked {
            self.answers = answers
            _sent = []
            _unscripted = []
        }
    }

    func note(_ unscripted: String) {
        locked { _unscripted.append(unscripted) }
    }

    /// The event ids of each upload this step, in the order they went.
    var sent: [[String]] { locked { _sent } }
    var unscripted: [String] { locked { _unscripted } }
    var unused: Int { locked { answers.count } }

    func answer(_ batch: [String: Any]) -> Answer? {
        let events = (batch["events"] as? [[String: Any]] ?? []).compactMap { $0["event_id"] as? String }
        return locked {
            guard !answers.isEmpty else {
                _unscripted.append("an upload of \(events)")
                return nil
            }
            _sent.append(events)
            return answers.removeFirst()
        }
    }
}

final class ScriptedPaceIngestProtocol: URLProtocol {
    static let host = "pace.scenarios.test"

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard request.url?.path == TreebarsConstants.eventsPath,
              let batch = ScriptedIngestProtocol.batch(from: request)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        guard let answer = ScriptedPaceIngest.shared.answer(batch) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        var headers = ["Content-Type": "application/json"]
        if let flushMs = answer.flushMs { headers[TreebarsConstants.flushSpacingHeader] = String(flushMs) }
        if let retryAfter = answer.retryAfter { headers["Retry-After"] = retryAfter }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
