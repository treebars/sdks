import XCTest
@testable import TreebarsSDK

/*
 Asset prefetch. The pure half answers every case of the shared `Fixtures/in-app-assets.json` as the reference
 implementation does; the cache is driven with a fake network, so what it keeps, what a display gets and what it refuses
 are checked without one. Foundation only: `swift test` on a Mac runs it.
 */

private func assetsFixture() throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/in-app-assets.json")
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], "the shared fixture is missing or malformed")
}

private func manifestOf(_ spec: [String: Any]) throws -> InAppAssetManifest? {
    guard let raw = spec["manifest"] as? [String: Any] else { return nil }
    return try JSONDecoder().decode(InAppAssetManifest.self, from: JSONSerialization.data(withJSONObject: raw))
}

/// A network that answers from a map and counts what it was asked.
private final class FakeNetwork: InAppAssetFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var answersByURL: [String: Data]
    private var askedURLs: [String] = []

    init(_ answers: [String: Data]) { answersByURL = answers }

    var asked: [String] { lock.lock(); defer { lock.unlock() }; return askedURLs }
    func forget() { lock.lock(); answersByURL = [:]; lock.unlock() }

    func get(_ url: String, maxBytes: Int) async -> Data? {
        lock.lock(); defer { lock.unlock() }
        askedURLs.append(url)
        guard let data = answersByURL[url], data.count <= maxBytes else { return nil }
        return data
    }
}

/// A network that never answers, as a captive portal does — until its request is cancelled.
private final class HangingNetwork: InAppAssetFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var asked = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return asked }

    func get(_ url: String, maxBytes: Int) async -> Data? {
        lock.lock(); asked += 1; lock.unlock()
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        return nil
    }
}

final class InAppAssetsTests: XCTestCase {

    func testTheBoundsAreTheReferences() throws {
        let limits = try XCTUnwrap(try assetsFixture()["limits"] as? [String: Any])
        XCTAssertEqual(limits["inline_file_max_bytes"] as? Int, InAppAssetInline.fileMaxBytes)
        XCTAssertEqual(limits["inline_total_max_bytes"] as? Int, InAppAssetInline.totalMaxBytes)
        XCTAssertEqual(limits["cache_max_bytes"] as? Int, InAppAssetInline.cacheMaxBytes)
        XCTAssertEqual(limits["stylesheet_max_bytes"] as? Int, InAppAssetInline.stylesheetMaxBytes)
    }

    func testPlansEveryCaseAsCoreDoes() throws {
        let cases = try XCTUnwrap(try assetsFixture()["plans"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 5)
        for spec in cases {
            let name = spec["name"] as? String ?? ""
            let plan = InAppAssetInline.plan(try manifestOf(spec))
            XCTAssertEqual(plan.inline.map(\.sha256), spec["inline"] as? [String], name)
            XCTAssertEqual(plan.left.map(\.sha256), spec["left"] as? [String], name)
            XCTAssertEqual(plan.stylesheets, spec["stylesheets"] as? [String], name)
            XCTAssertEqual(plan.missing, spec["missing"] as? [String], name)
        }
    }

    func testDecidesEveryOutcomeAsCoreDoes() throws {
        for spec in try XCTUnwrap(try assetsFixture()["outcomes"] as? [[String: Any]]) {
            let have = spec["have"] as? [String] ?? []
            let sheets = spec["have_stylesheets"] as? [String] ?? []
            let outcome = InAppAssetInline.outcome(InAppAssetInline.plan(try manifestOf(spec)), has: { have.contains($0) }, hasStylesheet: { sheets.contains($0) })
            XCTAssertEqual(outcome, spec["outcome"] as? String, spec["name"] as? String ?? "")
        }
    }

    func testWritesEveryDocumentAsCoreDoes() throws {
        let cases = try XCTUnwrap(try assetsFixture()["documents"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 6)
        for spec in cases {
            let out = InAppAssetInline.inline(
                spec["html"] as? String ?? "",
                files: spec["files"] as? [String: String] ?? [:],
                stylesheets: spec["stylesheets"] as? [String: String] ?? [:]
            )
            XCTAssertEqual(out, spec["expected"] as? String, spec["name"] as? String ?? "")
        }
    }

    func testKeepsOnlyTheStylesheetsCoreKeeps() throws {
        for spec in try XCTUnwrap(try assetsFixture()["stylesheet_checks"] as? [[String: Any]]) {
            let text = spec["text"] as? String ?? String(repeating: "a", count: spec["text_length"] as? Int ?? 0)
            XCTAssertEqual(InAppAssetInline.isInlinableStylesheet(text), spec["ok"] as? Bool, spec["name"] as? String ?? "")
        }
    }

    // The cache.

    private let project = "11111111-1111-4111-8111-111111111111"
    private let png = Data("png-bytes".utf8)
    private var pngSha: String { InAppAssetCache.sha256Hex(png) }
    private var pngURL: String { "https://api.treebars.test/assets/\(project)/\(pngSha).png" }
    private var sheetURL: String { "https://api.treebars.test/assets/\(project)/font.css?family=Brand&face=\(pngSha).png:400:normal" }

    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("treebars-assets-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func file(bytes: Int? = nil, type: String = "image/png") -> InAppAssetFile {
        InAppAssetFile(url: pngURL, sha256: pngSha, type: type, bytes: bytes ?? png.count)
    }

    func testAMarkupBodyIsDrawnFromThePrefetchWithNothingAskedAtTheDraw() async throws {
        let network = FakeNetwork([pngURL: png])
        let cache = InAppAssetCache(directory: directory(), fetcher: network)
        let held = InAppAssetManifest(files: [file()])
        await cache.prefetch([(held, true)])
        XCTAssertEqual(network.asked, [pngURL])

        network.forget()
        let document = await cache.prepare(held, html: "<img src=\"\(pngURL)\">")
        XCTAssertEqual(document, "<img src=\"data:image/png;base64,\(png.base64EncodedString())\">")
        XCTAssertEqual(network.asked, [pngURL], "offline at the draw, and nothing asked")
    }

    func testAFileThePrefetchHasNotLandedIsFetchedAtTheDraw() async throws {
        let cache = InAppAssetCache(directory: directory(), fetcher: FakeNetwork([pngURL: png]))
        let document = await cache.prepare(InAppAssetManifest(files: [file()]), html: "<img src=\"\(pngURL)\">")
        XCTAssertTrue(document?.contains("data:image/png;base64,") == true)
    }

    func testADisplayWaitsForWhatItIsMissingWithinItsDeadlineTogetherThenFails() async throws {
        let hanging = HangingNetwork()
        let cache = InAppAssetCache(directory: directory(), fetcher: hanging, drawWaitSeconds: 0.3)
        let files = (0..<6).map { index -> InAppAssetFile in
            let body = Data("file-\(index)".utf8)
            let sha = InAppAssetCache.sha256Hex(body)
            return InAppAssetFile(url: "https://api.treebars.test/assets/\(project)/\(sha).png", sha256: sha, type: "image/png", bytes: body.count)
        }
        let started = Date()
        let document = await cache.prepare(InAppAssetManifest(files: files), html: "<p>x</p>")
        XCTAssertNil(document)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "failed rather than hold the screen")
        XCTAssertEqual(hanging.count, 6, "asked together, not one after another")
    }

    func testAFileThatIsNotItsHashIsNeverKeptAndItsDisplayIsNotDrawn() async throws {
        let cache = InAppAssetCache(directory: directory(), fetcher: FakeNetwork([pngURL: Data("a proxy's error page".utf8)]))
        let held = InAppAssetManifest(files: [file()])
        await cache.prefetch([(held, true)])
        XCTAssertFalse(cache.has(pngSha))
        let document = await cache.prepare(held, html: "<img src=\"\(pngURL)\">")
        XCTAssertNil(document)
    }

    func testAGoneStoreFileAndOneThatCannotBeHadFailTheDisplay() async throws {
        let cache = InAppAssetCache(directory: directory(), fetcher: FakeNetwork([:]))
        let gone = await cache.prepare(InAppAssetManifest(missing: [pngURL]), html: "<p>hi</p>")
        XCTAssertNil(gone)
        let unreachable = await cache.prepare(InAppAssetManifest(files: [file()]), html: "<img src=\"\(pngURL)\">")
        XCTAssertNil(unreachable)
        let nothing = await cache.prepare(nil, html: "<p>hi</p>")
        XCTAssertEqual(nothing, "<p>hi</p>", "nothing to load is drawn as written")
    }

    func testAFilePastTheInlineBoundKeepsItsAddressAndIsNeverFetchedForAMarkupBody() async throws {
        let network = FakeNetwork([:])
        let cache = InAppAssetCache(directory: directory(), fetcher: network)
        let big = InAppAssetManifest(files: [file(bytes: InAppAssetInline.fileMaxBytes + 1, type: "image/jpeg")])
        await cache.prefetch([(big, true)])
        XCTAssertEqual(network.asked, [])
        let document = await cache.prepare(big, html: "<img src=\"\(pngURL)\">")
        XCTAssertEqual(document, "<img src=\"\(pngURL)\">")
    }

    func testAFontStylesheetIsKeptOnlyWhenItCanBeWrittenIntoADocument() async throws {
        let held = InAppAssetManifest(files: [file(type: "font/woff2")], stylesheets: [sheetURL])
        let cache = InAppAssetCache(directory: directory(), fetcher: FakeNetwork([sheetURL: Data("@font-face{src:url(\(pngURL))}".utf8), pngURL: png]))
        let link = "<link rel=\"stylesheet\" href=\"\(sheetURL.replacingOccurrences(of: "&", with: "&amp;"))\">"
        let document = await cache.prepare(held, html: link)
        XCTAssertTrue(document?.hasPrefix("<style>@font-face{src:url(data:font/woff2;base64,") == true, document ?? "nil")

        let hostile = InAppAssetCache(directory: directory(), fetcher: FakeNetwork([sheetURL: Data("</style><script>1</script>".utf8), pngURL: png]))
        let refused = await hostile.prepare(held, html: link)
        XCTAssertNil(refused)
    }

    func testAStandardBodysPictureIsReadFromTheCacheByItsAddress() async throws {
        let cache = InAppAssetCache(directory: directory(), fetcher: FakeNetwork([pngURL: png]))
        await cache.prefetch([(InAppAssetManifest(files: [file()]), false)])
        XCTAssertEqual(cache.pictureBytes(pngURL), png)
        XCTAssertNil(cache.pictureBytes(pngURL + "?v=2"), "another address is not this file")
        XCTAssertNil(cache.pictureBytes("https://cdn.example.com/\(pngSha).png"))
    }

    /// Its own record of use, never a file's modification date: that is a required-reason API on iOS.
    func testTheFilesNoHeldMessageNamesGoAndPastTheBoundTheLongestUnusedGo() async throws {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000) }
        let clock = Clock()
        let bodies = ["old": Data(count: 6), "used": Data([1, 1, 1, 1, 1, 1]), "gone": Data([2])]
        var files: [String: InAppAssetFile] = [:]
        var answers: [String: Data] = [:]
        for (name, body) in bodies {
            let sha = InAppAssetCache.sha256Hex(body)
            let url = "https://api.treebars.test/assets/\(project)/\(sha).png"
            files[name] = InAppAssetFile(url: url, sha256: sha, type: "image/png", bytes: body.count)
            answers[url] = body
        }
        let cache = InAppAssetCache(directory: directory(), fetcher: FakeNetwork(answers), maxBytes: 10, clock: { clock.now })
        for name in ["old", "gone", "used"] {
            let fetched = await cache.fetch(try XCTUnwrap(files[name]), limit: 100)
            XCTAssertTrue(fetched)
            clock.now = clock.now.addingTimeInterval(1_000)
        }
        clock.now = Date(timeIntervalSince1970: 1_000_000)
        cache.evict(keeping: [try XCTUnwrap(files["old"]).sha256, try XCTUnwrap(files["used"]).sha256])
        XCTAssertFalse(cache.has(try XCTUnwrap(files["gone"]).sha256), "named by no held message")
        XCTAssertFalse(cache.has(try XCTUnwrap(files["old"]).sha256), "the longest unused, past the bound")
        XCTAssertTrue(cache.has(try XCTUnwrap(files["used"]).sha256))
    }

    func testAFileWrittenInTheLastMinuteIsNotEvictedForBeingUnnamed() async throws {
        let cache = InAppAssetCache(directory: directory(), fetcher: FakeNetwork([pngURL: png]))
        let fetched = await cache.fetch(file(), limit: 100)
        XCTAssertTrue(fetched)
        cache.evict(keeping: [])
        XCTAssertTrue(cache.has(pngSha), "a display may have fetched it for a message a later sync brought")
    }

    /// The manifest rides the message through the store's own encoding, so a queue kept across a launch still has it.
    func testAManifestIsReadTolerantlyAndSurvivesTheStoresRoundTrip() throws {
        let raw: [String: Any] = [
            "delivery_id": "d-1", "campaign_id": NSNull(), "expires_at": NSNull(),
            "content": ["in_app": ["surface": "overlay", "layout": "modal", "body_mode": "html", "html": "<p>x</p>", "trigger": ["kind": "immediate"]]],
            "assets": [
                "files": [["url": pngURL, "sha256": pngSha, "type": "image/png", "bytes": 9], ["url": "x", "sha256": "nope"], "not a file"],
                "stylesheets": [sheetURL],
                "missing": [pngURL],
            ],
        ]
        let message = try JSONDecoder().decode(InAppMessage.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertEqual(message.assets?.files, [InAppAssetFile(url: pngURL, sha256: pngSha, type: "image/png", bytes: 9)])
        let again = try JSONDecoder().decode(InAppMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(again.assets, message.assets)

        var broken = raw
        broken["assets"] = "not a manifest"
        XCTAssertNotNil(try? JSONDecoder().decode(InAppMessage.self, from: JSONSerialization.data(withJSONObject: broken)), "a bad manifest never loses the message")
    }
}
