import XCTest
@testable import TreebarsSDK

/**
 An `event` trigger's property filters.

 A matcher that compared the event name alone would show a filtered trigger's message to
 everyone who fired the event. That direction matters. The matcher's own comment says an
 unrecognised kind fails closed because showing a message to people who do not qualify is
 worse than showing it to nobody — and ignoring a filter is exactly that failure, arrived at
 by a different route.

 It answers all fourteen operators, as the web and Kotlin SDKs read them on a device; an
 operator this build does not know fails closed for the same reason.
 */
final class InAppFilterTests: XCTestCase {

    private func matches(_ filters: [InAppFilter], _ properties: [String: Any]) -> Bool {
        inAppTriggerMatches(
            InAppTrigger(kind: "event", event_name: "purchase", filters: filters),
            eventName: "purchase",
            properties: properties,
            screenName: nil
        )
    }

    func testAFilterThatIsMetMatchesAndOneThatIsNotDoesNot() {
        let gte = [InAppFilter(key: "value", op: "gte", value: .number(50))]
        XCTAssertTrue(matches(gte, ["value": 80]))
        XCTAssertFalse(matches(gte, ["value": 20]))
    }

    /// A trigger with no `filters` at all, which matches on its event name alone.
    func testATriggerWithNoFiltersIsUnchanged() {
        let trigger = InAppTrigger(kind: "event", event_name: "purchase")
        XCTAssertNil(trigger.filters)
        XCTAssertTrue(
            inAppTriggerMatches(trigger, eventName: "purchase", properties: ["value": 1], screenName: nil)
        )
    }

    func testEveryFilterHasToHoldNotJustOne() {
        let both = [
            InAppFilter(key: "tier", op: "eq", value: .string("gold")),
            InAppFilter(key: "value", op: "gt", value: .number(10)),
        ]
        XCTAssertTrue(matches(both, ["tier": "gold", "value": 11]))
        XCTAssertFalse(matches(both, ["tier": "gold", "value": 9]))
        XCTAssertFalse(matches(both, ["tier": "silver", "value": 11]))
    }

    func testTheOperatorsMeanWhatTheOtherSDKsMean() {
        XCTAssertTrue(matches([InAppFilter(key: "a", op: "exists")], ["a": "x"]))
        XCTAssertFalse(matches([InAppFilter(key: "a", op: "exists")], ["b": "x"]))
        XCTAssertTrue(matches([InAppFilter(key: "a", op: "eq", value: .string("x"))], ["a": "x"]))
        XCTAssertTrue(matches([InAppFilter(key: "a", op: "neq", value: .string("x"))], ["a": "y"]))
        XCTAssertTrue(matches([InAppFilter(key: "a", op: "contains", value: .string("ell"))], ["a": "hello"]))
        XCTAssertFalse(matches([InAppFilter(key: "a", op: "contains", value: .string("ell"))], ["a": 5]))
        XCTAssertTrue(matches([InAppFilter(key: "a", op: "lt", value: .number(5))], ["a": 4]))
        XCTAssertTrue(matches([InAppFilter(key: "a", op: "lte", value: .number(5))], ["a": 5]))
    }

    /*
     * The composer offers only the operators above, but the wire is not the composer: a newer
     * dashboard, a hand-edited row or an agent-written trigger can put anything here. Passing
     * would show the message to everybody.
     */
    func testAnOperatorThisBuildDoesNotKnowFailsClosed() {
        XCTAssertFalse(
            matches([InAppFilter(key: "a", op: "matches_regex", value: .string("^x"))], ["a": "x"])
        )
    }

    /*
     * `Codable` cannot hold `Any`, so a filter value has to be one of a few cases — and an
     * unrecognised shape decodes to `.unsupported` rather than throwing, because one odd value
     * must not take down the decode of every message in the sync.
     */
    func testAFilterDecodesFromTheWireShapeTheServerSends() throws {
        let json = """
        {
          "kind": "event",
          "event_name": "purchase",
          "filters": [
            {"key": "value", "op": "gte", "value": 50},
            {"key": "tier", "op": "eq", "value": "gold"},
            {"key": "trial", "op": "eq", "value": true},
            {"key": "coupon", "op": "eq", "value": null}
          ]
        }
        """.data(using: .utf8)!

        let trigger = try JSONDecoder().decode(InAppTrigger.self, from: json)
        XCTAssertEqual(trigger.filters?.count, 4)
        XCTAssertEqual(trigger.filters?[0].value, .number(50))
        XCTAssertEqual(trigger.filters?[1].value, .string("gold"))
        XCTAssertEqual(trigger.filters?[2].value, .bool(true))
        /*
         * `nil`, not `.null`, and the difference is Swift's rather than ours: `value` is
         * declared optional, so the synthesized decoder resolves a JSON null to `nil` without
         * the enum's own decoder ever running. `.null` stays reachable through the public
         * initializer, and both spellings make an unfinished row to `isComplete` — which is what
         * makes the distinction safe to have rather than a trap.
         */
        XCTAssertNil(trigger.filters?[3].value)

        /*
         * A filter with no value is an UNFINISHED ROW, not `eq null`.
         *
         * Every SDK drops any row whose value is absent, null or empty, and the reason is the
         * composer, whose filter builder autosaves exactly this shape the moment "Add filter" is
         * clicked. Read as a null comparison, a stray click would add `plan eq null` to a working
         * campaign and silently stop it reaching every handset. `exists` is the operator for
         * asking about presence; there is no `eq null`.
         */
        XCTAssertTrue(matches([InAppFilter(key: "coupon", op: "eq")], [:]))
        XCTAssertTrue(
            matches([InAppFilter(key: "coupon", op: "eq")], ["coupon": "SAVE10"]),
            "an unfinished row is ignored, so the trigger matches on its event name alone"
        )
    }

    /// The unfinished-row rule, which is the whole of `isComplete`.
    func testAnUnfinishedFilterRowIsIgnoredRatherThanMatchingNobody() {
        let props: [String: Any] = ["plan": "pro"]

        // The exact shape the composer autosaves on the first click of "Add filter".
        XCTAssertTrue(matches([InAppFilter(key: "", op: "eq", value: .string(""))], props))
        // A key with nothing to compare against is still unfinished.
        XCTAssertTrue(matches([InAppFilter(key: "plan", op: "eq", value: .string(""))], props))

        /*
         * The damaging shape: an unfinished row beside a real one. Dropped before the conjunction
         * rather than failed inside it, so the real filter is left deciding — which is why
         * `matchesFilters` filters and then folds rather than folding over everything.
         */
        XCTAssertTrue(
            matches(
                [
                    InAppFilter(key: "plan", op: "eq", value: .string("pro")),
                    InAppFilter(key: "", op: "eq", value: .string("")),
                ],
                props
            )
        )
        XCTAssertFalse(
            matches(
                [
                    InAppFilter(key: "plan", op: "eq", value: .string("gold")),
                    InAppFilter(key: "", op: "eq", value: .string("")),
                ],
                props
            ),
            "dropping the empty row must not also drop the real one"
        )

        // `exists` is complete on its key alone, so it is never dropped.
        XCTAssertTrue(matches([InAppFilter(key: "plan", op: "exists")], props))
        XCTAssertFalse(matches([InAppFilter(key: "coupon", op: "exists")], props))
    }

    /// An absent `filters` key must decode, not throw — it is the shape of every stored message.
    func testATriggerWithoutAFiltersKeyStillDecodes() throws {
        let json = #"{"kind":"session_start"}"#.data(using: .utf8)!
        let trigger = try JSONDecoder().decode(InAppTrigger.self, from: json)
        XCTAssertNil(trigger.filters)
        XCTAssertEqual(trigger.kind, "session_start")
    }

    // MARK: - What this SDK cannot read fails closed, and still does after a relaunch

    private func decode(_ json: String) throws -> InAppTrigger {
        try JSONDecoder().decode(InAppTrigger.self, from: Data(json.utf8))
    }

    /// The queue is saved by re-encoding what was decoded, and read back on launch.
    private func relaunched(_ trigger: InAppTrigger) throws -> InAppTrigger {
        try JSONDecoder().decode(InAppTrigger.self, from: JSONEncoder().encode(trigger))
    }

    private func draws(_ trigger: InAppTrigger, _ properties: [String: Any]) -> Bool {
        inAppTriggerMatches(trigger, eventName: "purchase", properties: properties, screenName: nil)
    }

    /// An array value decodes to `.unsupported`, and matches nobody. Read as `.null` it would be an
    /// unfinished row and dropped: the filter ignored and the message drawn for everybody.
    func testAValueThisSDKCannotReadFailsClosedInsteadOfBeingIgnored() throws {
        let trigger = try decode(#"{"kind":"event","event_name":"purchase","filters":[{"key":"plan","op":"eq","value":["pro"]}]}"#)
        XCTAssertEqual(trigger.filters?.first?.value, .unsupported)
        XCTAssertFalse(draws(trigger, ["plan": "pro"]))
        XCTAssertFalse(draws(trigger, [:]))
    }

    /// `exists` reads no value, so an unreadable one changes nothing: the other SDKs answer by presence too.
    func testExistsIgnoresAValueThisSDKCannotRead() throws {
        let trigger = try decode(#"{"kind":"event","event_name":"purchase","filters":[{"key":"plan","op":"exists","value":["pro"]}]}"#)
        XCTAssertTrue(draws(trigger, ["plan": "pro"]))
        XCTAssertFalse(draws(trigger, [:]))
        XCTAssertTrue(draws(try relaunched(trigger), ["plan": "pro"]))
    }

    func testTheUnsupportedMarkerSurvivesASaveAndARelaunch() throws {
        let trigger = try decode(#"{"kind":"event","event_name":"purchase","filters":[{"key":"plan","op":"neq","value":{"a":1}}]}"#)
        let again = try relaunched(trigger)
        XCTAssertEqual(again.filters?.first?.value, .unsupported)
        XCTAssertEqual(draws(again, ["plan": "team"]), draws(trigger, ["plan": "team"]))
        XCTAssertFalse(draws(again, ["plan": "team"]))
    }

    /// A malformed element fails the WHOLE trigger — dropped, the real filter beside it would still draw.
    func testAMalformedElementFailsTheWholeTriggerAndStaysMalformedAfterARelaunch() throws {
        for element in ["null", #""x""#, #"{"op":"eq","value":"pro"}"#, #"{"key":7,"op":"eq","value":"pro"}"#] {
            let trigger = try decode(#"{"kind":"event","event_name":"purchase","filters":[{"key":"plan","op":"eq","value":"pro"},"# + element + "]}")
            XCTAssertFalse(draws(trigger, ["plan": "pro"]), element)
            XCTAssertFalse(draws(try relaunched(trigger), ["plan": "pro"]), "\(element), relaunched")
        }
    }

    /// Filters that are there and are not a list match nobody; decoded to nil — "no filter" — they would draw for everybody.
    func testFiltersThatAreNotAListMatchNobodyAndStillDoAfterARelaunch() throws {
        let trigger = try decode(#"{"kind":"event","event_name":"purchase","filters":"plan"}"#)
        XCTAssertFalse(draws(trigger, ["plan": "pro"]))
        XCTAssertFalse(draws(try relaunched(trigger), ["plan": "pro"]))
        // Absent, or null, is still no filter at all.
        XCTAssertTrue(draws(try decode(#"{"kind":"event","event_name":"purchase","filters":null}"#), [:]))
        XCTAssertTrue(draws(try decode(#"{"kind":"event","event_name":"purchase"}"#), [:]))
    }

    func testARealFilterStillRoundTripsUnchanged() throws {
        let trigger = try decode(#"{"kind":"event","event_name":"purchase","filters":[{"key":"plan","op":"eq","value":"pro"}]}"#)
        let again = try relaunched(trigger)
        XCTAssertEqual(again.filters?.first?.key, "plan")
        XCTAssertEqual(again.filters?.first?.value, .string("pro"))
        XCTAssertTrue(draws(again, ["plan": "pro"]))
    }

    // MARK: - The fourteen operators, as every SDK reads them on a device

    private func on(_ filter: InAppFilter, _ properties: [String: Any]) -> Bool {
        matches([filter], properties)
    }

    func testTheSixNewOperatorsAgainstAPresentValueAMissingOneAndAnEmptyOne() {
        let cases: [(InAppFilter, Bool, Bool, Bool)] = [
            // (filter, present "pro-plan", missing, "")
            (InAppFilter(key: "v", op: "not_contains", value: .string("pro")), false, true, true),
            (InAppFilter(key: "v", op: "starts_with", value: .string("pro")), true, false, false),
            (InAppFilter(key: "v", op: "ends_with", value: .string("plan")), true, false, false),
            (InAppFilter(key: "v", op: "in", value: .string(#"["pro-plan","team"]"#)), true, false, false),
            (InAppFilter(key: "v", op: "not_in", value: .string(#"["pro-plan","team"]"#)), false, true, true),
            (InAppFilter(key: "v", op: "not_exists", value: .bool(true)), false, true, true),
        ]
        for (filter, present, missing, empty) in cases {
            XCTAssertEqual(on(filter, ["v": "pro-plan"]), present, "\(filter.op) present")
            XCTAssertEqual(on(filter, [:]), missing, "\(filter.op) missing")
            XCTAssertEqual(on(filter, ["v": ""]), empty, "\(filter.op) empty")
        }
        // "" is not set, so "is set" is false for it, and every negated operator matches it.
        XCTAssertFalse(on(InAppFilter(key: "v", op: "exists"), ["v": ""]))
        XCTAssertTrue(on(InAppFilter(key: "v", op: "neq", value: .string("pro")), [:]))
    }

    /// A list that does not decode says nothing, `not_in` included: an empty list is never "everyone".
    func testAListThatDoesNotDecodeMatchesNobody() {
        for bad in ["[]", #"["pro",1]"#, #"[""]"#, "pro", #"[true]"#] {
            XCTAssertFalse(on(InAppFilter(key: "v", op: "not_in", value: .string(bad)), [:]), bad)
            XCTAssertFalse(on(InAppFilter(key: "v", op: "in", value: .string(bad)), ["v": "pro"]), bad)
        }
        let fifty = "[" + (0..<50).map(String.init).joined(separator: ",") + "]"
        XCTAssertTrue(on(InAppFilter(key: "v", op: "in", value: .string(fifty)), ["v": 49]))
        let fiftyOne = "[" + (0..<51).map(String.init).joined(separator: ",") + "]"
        XCTAssertFalse(on(InAppFilter(key: "v", op: "in", value: .string(fiftyOne)), ["v": 49]))
    }

    /// With no `type` a number row matches only a JSON number; under `type: 'number'`, text the
    /// grammar accepts whole — and a JSON `true` is never the number 1.
    func testANumberRowReadsNumbersStrictlyAndTextOnlyWhenTyped() {
        XCTAssertFalse(on(InAppFilter(key: "v", op: "eq", value: .number(150)), ["v": "150"]))
        XCTAssertTrue(on(InAppFilter(key: "v", op: "eq", value: .number(150), type: "number"), ["v": "150"]))
        for text in [" 42", "0x10", "inf", ".", "42\n", "\u{0661}\u{0662}"] {
            XCTAssertFalse(on(InAppFilter(key: "v", op: "gte", value: .number(0), type: "number"), ["v": text]), text.debugDescription)
        }
        XCTAssertTrue(on(InAppFilter(key: "v", op: "gte", value: .number(0), type: "number"), ["v": "1e400"]))

        let json = try! JSONSerialization.jsonObject(with: Data(#"{"yes":true,"one":1}"#.utf8)) as! [String: Any]
        XCTAssertFalse(on(InAppFilter(key: "yes", op: "eq", value: .number(1)), json), "true is not the number 1")
        XCTAssertTrue(on(InAppFilter(key: "one", op: "eq", value: .number(1)), json))
        XCTAssertFalse(on(InAppFilter(key: "one", op: "eq", value: .bool(true)), json), "1 is not true")
        XCTAssertTrue(on(InAppFilter(key: "yes", op: "eq", value: .bool(true)), json))
        // A boolean row compares text, so the text "true" matches as well, and has no order.
        XCTAssertTrue(on(InAppFilter(key: "v", op: "eq", value: .bool(true)), ["v": "true"]))
        XCTAssertFalse(on(InAppFilter(key: "v", op: "gt", value: .bool(true), type: "boolean"), ["v": "zebra"]))
    }

    /// A text row reads a number by JavaScript's text for it, which is not Swift's.
    func testANumberIsReadAsTextTheWayJavaScriptWritesIt() {
        XCTAssertEqual(jsNumberText(100), "100")
        XCTAssertEqual(jsNumberText(1.5), "1.5")
        XCTAssertEqual(jsNumberText(1e16), "10000000000000000")
        XCTAssertEqual(jsNumberText(1.2345678901234568e20), "123456789012345680000")
        XCTAssertEqual(jsNumberText(1e21), "1e+21")
        XCTAssertEqual(jsNumberText(0.000001), "0.000001")
        XCTAssertEqual(jsNumberText(1e-7), "1e-7")
        XCTAssertEqual(jsNumberText(-0.0), "0")
        XCTAssertEqual(jsNumberText(-2.5e-8), "-2.5e-8")
        XCTAssertTrue(on(InAppFilter(key: "v", op: "eq", value: .string("150")), ["v": 150]))
        XCTAssertTrue(on(InAppFilter(key: "v", op: "contains", value: .string("50")), ["v": 150.0]))
        // A whole filter value past Int.max must not trap, as `String(Int(value))` would.
        XCTAssertFalse(on(InAppFilter(key: "v", op: "contains", value: .number(1e20)), ["v": 1]))
    }

    /// Text compares by UTF-16 code unit, as JavaScript and the server do — not by Swift's equivalence.
    func testTextComparesByCodeUnitNotByCanonicalEquivalence() {
        XCTAssertFalse(on(InAppFilter(key: "v", op: "eq", value: .string("\u{e9}")), ["v": "e\u{301}"]))
        XCTAssertTrue(on(InAppFilter(key: "v", op: "neq", value: .string("\u{e9}")), ["v": "e\u{301}"]))
        XCTAssertFalse(on(InAppFilter(key: "v", op: "starts_with", value: .string("e")), ["v": "\u{e9}"]))
        // JavaScript orders the surrogate pair before U+FF5A; Swift's `<` would not.
        XCTAssertTrue(on(InAppFilter(key: "v", op: "gt", value: .string("\u{1F600}")), ["v": "\u{ff5a}"]))
    }

    /// A type or a side no reader knows answers nothing, under every operator — and a dimension row with
    /// no dimensions to read answers nothing too.
    func testATypeOrSideThisSDKDoesNotReadFailsClosed() throws {
        XCTAssertFalse(on(InAppFilter(key: "v", op: "eq", value: .string("pro"), type: "colour"), ["v": "pro"]))
        XCTAssertFalse(on(InAppFilter(key: "v", op: "exists", type: "colour"), ["v": "pro"]))
        XCTAssertFalse(on(InAppFilter(key: "v", op: "eq", value: .string("ios"), source: "dimension"), ["v": "ios"]))
        XCTAssertTrue(on(InAppFilter(key: "v", op: "eq", value: .string("ios"), source: "property"), ["v": "ios"]))

        // `type: null` is not an absent type, and it stays unknown across a save and a relaunch.
        let trigger = try decode(#"{"kind":"event","event_name":"purchase","filters":[{"key":"v","op":"eq","value":"pro","type":null}]}"#)
        XCTAssertEqual(trigger.filters?.first?.type, "")
        XCTAssertFalse(draws(trigger, ["v": "pro"]))
        XCTAssertFalse(draws(try relaunched(trigger), ["v": "pro"]))
        let typed = try relaunched(try decode(#"{"kind":"event","event_name":"purchase","filters":[{"key":"v","op":"eq","value":150,"type":"number","source":"property"}]}"#))
        XCTAssertEqual(typed.filters?.first?.type, "number")
        XCTAssertEqual(typed.filters?.first?.source, "property")
        XCTAssertTrue(draws(typed, ["v": "150"]))
    }

    /// A list value whose JavaScript text is empty is an unfinished row, as JavaScript's `String(value)` reads it.
    func testAListValueWithEmptyTextIsAnUnfinishedRow() throws {
        for value in ["[]", "[null]", #"[""]"#, "[[]]"] {
            let trigger = try decode(#"{"kind":"event","event_name":"purchase","filters":[{"key":"plan","op":"eq","value":"# + value + "}]}")
            XCTAssertEqual(trigger.filters?.first?.value, .string(""), value)
            XCTAssertTrue(draws(trigger, ["plan": "team"]), value)
            XCTAssertTrue(draws(try relaunched(trigger), ["plan": "team"]), "\(value), relaunched")
        }
        // Two blank elements have a comma between them, which is text: that row is complete, and says nothing.
        XCTAssertFalse(draws(try decode(#"{"kind":"event","event_name":"purchase","filters":[{"key":"plan","op":"eq","value":[null,null]}]}"#), ["plan": "team"]))
    }

    // MARK: - A dimension row reads the event's own map, and a version compares part by part

    private func dim(_ filter: InAppFilter, _ dimensions: [String: Any]?, _ properties: [String: Any] = [:]) -> Bool {
        inAppTriggerMatches(
            InAppTrigger(kind: "event", event_name: "purchase", filters: [filter]),
            eventName: "purchase", properties: properties, screenName: nil, dimensions: dimensions
        )
    }

    private func row(_ key: String, _ op: String, _ value: InAppFilterValue? = nil, type: String? = nil) -> InAppFilter {
        InAppFilter(key: key, op: op, value: value, type: type, source: "dimension")
    }

    func testADimensionRowReadsTheDimensionAndAPropertyRowNeverDoes() {
        let dims: [String: Any] = ["platform_type": "android"]
        XCTAssertTrue(dim(row("platform_type", "eq", .string("android")), dims, ["platform_type": "ios"]))
        XCTAssertFalse(dim(row("platform_type", "eq", .string("ios")), dims, ["platform_type": "ios"]))
        XCTAssertTrue(dim(InAppFilter(key: "platform_type", op: "eq", value: .string("ios")), dims, ["platform_type": "ios"]))
        XCTAssertFalse(dim(InAppFilter(key: "platform_type", op: "eq", value: .string("ios")), ["platform_type": "ios"]))
    }

    func testGeoAnUnlistedNameAnUnknownSideAndAMissingMapAreFalseUnderNeq() {
        XCTAssertFalse(dim(row("country", "neq", .string("DE")), ["country": "FR"]))
        XCTAssertFalse(dim(row("plan", "neq", .string("pro")), [:]))
        XCTAssertFalse(dim(row("platform_type", "neq", .string("ios")), nil))
        XCTAssertFalse(dim(InAppFilter(key: "platform_type", op: "neq", value: .string("ios"), source: "device"), ["platform_type": "android"]))
        // A map without the name is a map: the name is not set, and a negated operator matches it.
        XCTAssertTrue(dim(row("network_type", "neq", .string("wifi")), ["platform_type": "ios"]))
    }

    func testAStampedValueIsNormalisedAsIngestStoresIt() {
        XCTAssertTrue(dim(row("device_model", "eq", .string("Pixel 8")), ["device_model": "\u{FEFF} Pixel 8\n"]))
        // U+0085 is whitespace to Foundation and not to JavaScript, so it stays.
        XCTAssertFalse(dim(row("device_model", "eq", .string("Pixel 8")), ["device_model": "Pixel 8\u{0085}"]))
        let long = String(repeating: "x", count: 200)
        XCTAssertTrue(dim(row("device_model", "eq", .string(String(repeating: "x", count: 128))), ["device_model": long]))
        XCTAssertTrue(dim(row("screen_name", "eq", .string(" Cart")), ["screen_name": " Cart"]))
        XCTAssertFalse(dim(row("device_model", "exists"), ["device_model": "   "]))
    }

    func testVersionsCompareByTheMeasuredPairs() {
        func version(_ op: String, _ value: String, _ stamped: String) -> Bool {
            dim(row("app_version", op, .string(value), type: "version"), ["app_version": stamped])
        }
        XCTAssertTrue(version("gt", "2.9.1", "2.10"))
        XCTAssertTrue(version("eq", "2.3", "v2.3.0.0"))
        XCTAssertTrue(version("lt", "10.0", "9.9.9"))
        XCTAssertTrue(version("eq", "2.3", "2.3\n"), "trimmed first, as ingest trims it")
        XCTAssertTrue(version("gte", "9999999999", "9999999999.0"))
    }

    func testAVersionThatDoesNotParseIsFalseUnderNeqAndNotInAndSetUnderExists() {
        for stamped in ["2.4.0-beta", "\u{FF12}.\u{FF13}", "+1", "1.2.3.4.5", "2.3 (45)", "00000000001"] {
            XCTAssertFalse(dim(row("app_version", "neq", .string("2.3"), type: "version"), ["app_version": stamped]), stamped)
            XCTAssertFalse(dim(row("app_version", "not_in", .string(#"["2.3"]"#), type: "version"), ["app_version": stamped]), stamped)
            XCTAssertTrue(dim(row("app_version", "exists", type: "version"), ["app_version": stamped]), stamped)
        }
        // An authored value that does not parse says nothing, before the not-set reading.
        XCTAssertFalse(dim(row("app_version", "neq", .string("2.4.0-beta"), type: "version"), ["platform_type": "ios"]))
        XCTAssertTrue(dim(row("app_version", "neq", .string("2.3"), type: "version"), ["platform_type": "ios"]))
        // A property holding the number 2.3 is no version.
        XCTAssertFalse(on(InAppFilter(key: "v", op: "neq", value: .string("2.3"), type: "version"), ["v": 2.3]))
    }

    /// The dimensions a trigger reads are taken from the event dictionary `build` produced — the stamped
    /// values, never a second read of the device.
    func testTheStampedDimensionsAreTheEventsOwnInAppNames() {
        let event: [String: Any] = [
            "event_id": "e1", "event_name": "purchase", "properties": ["plan": "pro"],
            "sdk_name": "treebars-ios", "sdk_version": "1.0.0", "screen_name": "Cart",
            "platform_type": "ios", "network_type": "wifi", "app_version": "2.3",
        ]
        let stamped = Treebars.stampedDimensions(event)
        XCTAssertEqual(Set(stamped.keys), ["sdk_name", "sdk_version", "screen_name", "platform_type", "network_type", "app_version"])
        XCTAssertEqual(stamped["network_type"] as? String, "wifi")
        XCTAssertTrue(dim(InAppFilter(key: "network_type", op: "eq", value: .string("wifi"), source: "dimension"), stamped))
    }
}
