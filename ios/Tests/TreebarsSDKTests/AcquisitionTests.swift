import XCTest
@testable import TreebarsSDK

/**
 The Apple Ads latch: asked once per new install, only with consent, never given up at Apple's
 first 404, and never through the client that carries a customer's write key.

 AdServices cannot mint a real token here, so the token, the endpoint and the clock are faked and
 what is under test is the decision around them — which is where every way of getting this wrong
 lives. An install is reported once; a latch cleared on a 404 would lose the install's source for
 good, and it would look exactly like organic traffic.

 Disagreements are collected and asserted once, as in `UploaderScenariosTests`: on the simulator
 an async test records only its first failed assertion.
 */
final class AcquisitionTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "acquisition-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// Everything a capture did, so a test can say what happened rather than infer it.
    private final class Recorder: @unchecked Sendable {
        var sent: [[String: Any]] = []
        var posts = 0
        var mints = 0
        var sleeps: [Int64] = []
    }

    private func owe() { defaults.set(true, forKey: TreebarsConstants.keyAcquisitionPending) }

    private func capture(
        _ recorder: Recorder,
        token: AttributionTokenResult = .token("tok"),
        responses: [(Int, String)?]
    ) -> AcquisitionCapture {
        var queue = responses
        return AcquisitionCapture(
            defaults: defaults,
            mintToken: { recorder.mints += 1; return token },
            post: { _ in
                recorder.posts += 1
                guard !queue.isEmpty, let next = queue.removeFirst() else { return nil }
                return (next.0, Data(next.1.utf8))
            },
            sleep: { recorder.sleeps.append($0) },
            random: { 0.5 },
            send: { recorder.sent.append($0) }
        )
    }

    private let appleSaysYes = """
    {"attribution":true,"orgId":40669820,"campaignId":542370539,"conversionType":"Download","clickDate":"2026-09-18T22:02Z","adGroupId":542317095,"countryOrRegion":"US","keywordId":87675432,"adId":542317136}
    """

    func testNothingIsAskedWithoutConsentAndTheInstallStaysOwed() async {
        owe()
        let recorder = Recorder()
        let sent = await capture(recorder, responses: [(200, appleSaysYes)]).settle(consented: false)

        var problems: [String] = []
        if sent { problems.append("reported sending without consent") }
        if recorder.mints != 0 { problems.append("minted a token without consent") }
        if !defaults.bool(forKey: TreebarsConstants.keyAcquisitionPending) { problems.append("cleared the latch") }
        XCTAssertEqual(problems, [])
    }

    func testAppleAnswerIsSentVerbatimOnceAndTheLatchCleared() async {
        owe()
        let recorder = Recorder()
        let acquisition = capture(recorder, responses: [(200, appleSaysYes), (200, appleSaysYes)])

        let first = await acquisition.settle(consented: true)
        let second = await acquisition.settle(consented: true)

        var problems: [String] = []
        if !first { problems.append("first settle sent nothing") }
        if second { problems.append("second settle sent again") }
        if recorder.sent.count != 1 { problems.append("sent \(recorder.sent.count) events") }
        // Apple's keys, untranslated: the server reads Apple's documented names, in one place.
        if recorder.sent.first?["campaignId"] as? Int != 542370539 { problems.append("campaignId not verbatim") }
        if recorder.sent.first?["attribution"] as? Bool != true { problems.append("attribution not verbatim") }
        if defaults.object(forKey: TreebarsConstants.keyAcquisitionPending) != nil { problems.append("latch kept") }
        XCTAssertEqual(problems, [])
    }

    func testA404IsRetriedByTheUploadersOwnLadderBeforeAnythingIsGivenUp() async {
        /*
         The failure the retries exist for: Apple answers 404 for a while after the token is
         minted, and most people open an app straight after installing it.
         */
        owe()
        let recorder = Recorder()
        let sent = await capture(recorder, responses: [(404, ""), (404, ""), (200, appleSaysYes)])
            .settle(consented: true)

        var problems: [String] = []
        if !sent { problems.append("gave up before Apple answered") }
        if recorder.posts != 3 { problems.append("posted \(recorder.posts) times, not 3") }
        // `jitterMs` with random 0.5: half of min(60, 2 * 2^n) seconds — the uploader's formula.
        if recorder.sleeps != [jitterMs(attempt: 0, random: 0.5), jitterMs(attempt: 1, random: 0.5)] {
            problems.append("waited \(recorder.sleeps), not the uploader's ladder")
        }
        XCTAssertEqual(problems, [])
    }

    func testApplesFullRetryBudgetSpentKeepsTheLatchForTheNextLaunch() async {
        owe()
        let recorder = Recorder()
        let sent = await capture(recorder, responses: Array(repeating: (404, ""), count: 10))
            .settle(consented: true)

        var problems: [String] = []
        if sent { problems.append("reported sending") }
        if recorder.posts != TreebarsConstants.adServicesRetryAttempts {
            problems.append("posted \(recorder.posts) times, not \(TreebarsConstants.adServicesRetryAttempts)")
        }
        if !defaults.bool(forKey: TreebarsConstants.keyAcquisitionPending) { problems.append("cleared the latch") }
        XCTAssertEqual(problems, [])
    }

    func testNoResponseAtAllIsRetriedLikeA404() async {
        owe()
        let recorder = Recorder()
        let sent = await capture(recorder, responses: [nil, (200, appleSaysYes)]).settle(consented: true)
        XCTAssertTrue(sent)
    }

    func testAMalformedTokenAndAnUnsupportedOSStopAsking() async {
        var problems: [String] = []

        owe()
        let refused = Recorder()
        _ = await capture(refused, responses: [(400, "")]).settle(consented: true)
        if defaults.object(forKey: TreebarsConstants.keyAcquisitionPending) != nil { problems.append("400 kept the latch") }
        if !refused.sent.isEmpty { problems.append("400 sent something") }

        owe()
        let unsupported = Recorder()
        _ = await capture(unsupported, token: .unsupported, responses: [(200, appleSaysYes)]).settle(consented: true)
        if defaults.object(forKey: TreebarsConstants.keyAcquisitionPending) != nil { problems.append("unsupported kept the latch") }
        if unsupported.posts != 0 { problems.append("unsupported still posted") }

        XCTAssertEqual(problems, [])
    }

    func testATokenThatFailedToMintIsAskedForAgainNextLaunch() async {
        // A network error minting the token is what a simulator returns, and what a device in a
        // lift returns. Neither is a reason to stop asking.
        owe()
        let recorder = Recorder()
        let sent = await capture(recorder, token: .failed, responses: []).settle(consented: true)

        XCTAssertFalse(sent)
        XCTAssertTrue(defaults.bool(forKey: TreebarsConstants.keyAcquisitionPending))
    }

    func testAnInstallThatWasNeverOwedIsNeverAsked() async {
        // An install that predates this build has `first_seen_at` and no latch. Asking would
        // report an install from last year as if it had just arrived.
        let recorder = Recorder()
        let sent = await capture(recorder, responses: [(200, appleSaysYes)]).settle(consented: true)

        XCTAssertFalse(sent)
        XCTAssertEqual(recorder.mints, 0)
    }

    func testTheEndpointIsApplesAndCarriesNothingOfOurs() {
        // Both cores' `BackendClient`s stamp the write key on every request. This one must not
        // go through them: a third party's host would receive a customer's credential.
        XCTAssertEqual(AppleAttributionEndpoint.url.host, "api-adservices.apple.com")
    }
}
