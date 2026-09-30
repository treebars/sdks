import CryptoKit
import Foundation

/*
 Asset prefetch.

 Every in-app message a sync hands over carries a manifest beside its content: the files from the project's asset store
 it loads, by SHA-256, type and size; the store's font stylesheets; and the store files it names that are gone. This
 SDK fetches those files after the sync, keeps them on disk by their hash — checked, so a file is only ever the bytes its
 address names — and draws from them:

 - A markup body is drawn with every file it inlines swapped for a `data:` URI and every store stylesheet written into
   the document (`InAppAssetInline`), so it draws offline. A download this SDK makes is invisible to a WKWebView, whose
   store is non-persistent and reads only its own cache; `data:` is what the frame policy already allows for images,
   fonts and media, so the policy needs nothing wider. A store file the manifest says is gone, or one it would inline
   that could not be had, is a failed display (`asset_download`), never a broken image. A file past the inline bounds
   keeps its address and the WebView loads it, online only.
 - A standard body's picture is read from here when it is a store file this device holds (`NativePictures`), and
   fetched as it is drawn otherwise, into the placeholder the render contract draws — which stays if it fails.

 The same rules run in the web and Android SDKs; `Fixtures/in-app-assets.json` holds this file's pure half to the shared
 cases (`InAppAssetsTests`).
 */

/// One store file a message loads, as the sync's manifest names it.
public struct InAppAssetFile: Codable, Sendable, Equatable {
    public let url: String
    public let sha256: String
    public let type: String
    public let bytes: Int
}

/// A message's `assets`. Read tolerantly: anything unreadable in it is left out, and nothing in it fails the message.
public struct InAppAssetManifest: Codable, Sendable, Equatable {
    public var files: [InAppAssetFile]
    public var stylesheets: [String]
    public var missing: [String]

    init(files: [InAppAssetFile] = [], stylesheets: [String] = [], missing: [String] = []) {
        self.files = files
        self.stylesheets = stylesheets
        self.missing = missing
    }

    private enum CodingKeys: String, CodingKey { case files, stylesheets, missing }

    /// One entry of `files`, or nothing: a file without a hash and an address is not one this core can check.
    private struct Loose: Decodable {
        let file: InAppAssetFile?
        private enum Keys: String, CodingKey { case url, sha256, type, bytes }

        init(from decoder: Decoder) throws {
            let container = try? decoder.container(keyedBy: Keys.self)
            guard let url = try? container?.decode(String.self, forKey: .url), !url.isEmpty,
                  let sha = try? container?.decode(String.self, forKey: .sha256), InAppAssetInline.isHash(sha)
            else {
                file = nil
                return
            }
            file = InAppAssetFile(
                url: url,
                sha256: sha,
                type: (try? container?.decode(String.self, forKey: .type)) ?? "",
                bytes: (try? container?.decode(Int.self, forKey: .bytes)) ?? Int.max
            )
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        files = ((try? container?.decode([Loose].self, forKey: .files)) ?? []).compactMap(\.file)
        stylesheets = (try? container?.decode([String].self, forKey: .stylesheets)) ?? []
        missing = (try? container?.decode([String].self, forKey: .missing)) ?? []
    }
}

/// What one display of a markup body does with its manifest.
struct InAppAssetPlan: Equatable {
    var inline: [InAppAssetFile]
    var left: [InAppAssetFile]
    var stylesheets: [String]
    var missing: [String]
}

/// The pure half, answer for answer with the other SDKs. Foundation only, so a Mac runs it.
enum InAppAssetInline {
    static let fileMaxBytes = 1024 * 1024
    static let totalMaxBytes = 4 * 1024 * 1024
    static let cacheMaxBytes = 32 * 1024 * 1024
    static let stylesheetMaxBytes = 64 * 1024

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let storeFileURL = regex(
        #"https?://[^\s"'()<>/]+/assets/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/([0-9a-f]{64})\.(?:png|jpg|gif|webp|ttf|otf|woff|woff2)(?![A-Za-z0-9?#/._~%-])"#
    )
    private static let linkTag = regex(#"<link\b[^>]*>"#, .caseInsensitive)
    private static let href = regex(#"\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, .caseInsensitive)
    private static let relStylesheet = regex(#"\brel\s*=\s*["']?[^"'>]*\bstylesheet\b"#, .caseInsensitive)
    private static let importRule = regex(
        #"@import\s+(?:url\(\s*(?:"([^"]*)"|'([^']*)'|([^)\s]*))\s*\)|"([^"]*)"|'([^']*)')\s*;"#,
        .caseInsensitive
    )
    private static let hash = regex("^[0-9a-f]{64}$")

    static func isHash(_ value: String) -> Bool {
        hash.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    /// Which files a display inlines: manifest order, each within the file bound, until the display's bound.
    static func plan(_ manifest: InAppAssetManifest?) -> InAppAssetPlan {
        var inline: [InAppAssetFile] = []
        var left: [InAppAssetFile] = []
        var total = 0
        for file in manifest?.files ?? [] {
            if file.bytes <= fileMaxBytes, total + file.bytes <= totalMaxBytes {
                inline.append(file)
                total += file.bytes
            } else {
                left.append(file)
            }
        }
        return InAppAssetPlan(inline: inline, left: left, stylesheets: manifest?.stylesheets ?? [], missing: manifest?.missing ?? [])
    }

    /// `ready`, or `asset_download` when a store file is gone or one the display inlines is not on the device.
    static func outcome(_ plan: InAppAssetPlan, has: (String) -> Bool, hasStylesheet: (String) -> Bool) -> String {
        if !plan.missing.isEmpty { return "asset_download" }
        if plan.inline.contains(where: { !has($0.sha256) }) { return "asset_download" }
        if plan.stylesheets.contains(where: { !hasStylesheet($0) }) { return "asset_download" }
        return "ready"
    }

    /// Store stylesheets written in, then every inlined file's address — in the markup and the stylesheets — as `data:`.
    static func inline(_ html: String, files: [String: String], stylesheets: [String: String]) -> String {
        let linked = replace(linkTag, in: html) { tag, _ in
            guard relStylesheet.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) != nil,
                  let found = href.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag))
            else { return tag }
            guard let text = stylesheets[attributeValue(firstGroup(found, in: tag))] else { return tag }
            return "<style>\(text)</style>"
        }
        let imported = replace(importRule, in: linked) { statement, match in
            stylesheets[attributeValue(firstGroup(match, in: linked))] ?? statement
        }
        return replace(storeFileURL, in: imported) { address, match in
            guard let range = Range(match.range(at: 1), in: imported) else { return address }
            return files[String(imported[range])] ?? address
        }
    }

    static func isInlinableStylesheet(_ text: String) -> Bool {
        text.utf16.count <= stylesheetMaxBytes && !text.contains("<")
    }

    static func dataURI(type: String, bytes: Data) -> String {
        "data:\(type);base64,\(bytes.base64EncodedString())"
    }

    /// A store file's hash, when the whole address names one — what a picture is looked up by.
    static func storeHash(_ url: String) -> String? {
        let whole = NSRange(url.startIndex..., in: url)
        guard let match = storeFileURL.firstMatch(in: url, range: whole), match.range == whole,
              let range = Range(match.range(at: 1), in: url) else { return nil }
        return String(url[range])
    }

    /// Each match replaced by what `transform` says, literally — no template syntax, since a `data:` URI is not one.
    private static func replace(_ pattern: NSRegularExpression, in text: String, _ transform: (String, NSTextCheckingResult) -> String) -> String {
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        var out = ""
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            out += text[cursor..<range.lowerBound]
            out += transform(String(text[range]), match)
            cursor = range.upperBound
        }
        out += text[cursor...]
        return out
    }

    /// The first alternative that took part in the match, as JavaScript's `??` over its groups picks it.
    private static func firstGroup(_ match: NSTextCheckingResult, in text: String) -> String {
        for index in 1..<match.numberOfRanges {
            let nsRange = match.range(at: index)
            if nsRange.location != NSNotFound, let range = Range(nsRange, in: text) { return String(text[range]) }
        }
        return ""
    }

    private static func attributeValue(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: #"&#0?39;|&apos;"#, with: "'", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Fetches an address, at most `maxBytes`; nil for anything else. Swapped in tests.
protocol InAppAssetFetching: Sendable {
    func get(_ url: String, maxBytes: Int) async -> Data?
}

/// A plain GET, `http` or `https`, with the picture loader's patience.
struct URLSessionAssetFetch: InAppAssetFetching {
    func get(_ url: String, maxBytes: Int) async -> Data? {
        guard let address = URL(string: url), ["http", "https"].contains(address.scheme?.lowercased() ?? "") else { return nil }
        var request = URLRequest(url: address)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status),
              data.count <= maxBytes
        else { return nil }
        return data
    }
}

/**
 The files on disk, by hash, and the stylesheets by their address's hash, under Caches — which the system may empty; a
 file it took is fetched again. Bounded (`InAppAssetInline.cacheMaxBytes`): after each prefetch the files no held message
 names go first, then the longest unused. Writes land beside their name and are renamed, so a reader never meets half a
 file, and a prefetch and a display fetching the same file at once each write a whole one.

 When each file was last used, and how big it is, is this cache's own record (`.index.json`), never the file system's.
 A file's modification date is a required-reason API on iOS (`NSPrivacyAccessedAPICategoryFileTimestamp`): reading it
 would put a new declaration in the SDK's privacy manifest, which every app shipping the SDK answers for at review.
 Android reads `lastModified`, which asks nothing.
 */
final class InAppAssetCache: @unchecked Sendable {
    /// The one `initialize` made, for the native picture loader, which is handed a URL and nothing else.
    static var shared: InAppAssetCache?

    /// A standard body's picture is drawn natively, sampled down: kept up to the store's own upload bound.
    static let pictureMaxBytes = 5 * 1024 * 1024
    private static let recent: TimeInterval = 60

    private let directory: URL
    private let fetcher: InAppAssetFetching
    private let maxBytes: Int
    private let clock: () -> Date
    /// How long a display waits, in all, for what the prefetch has not landed (`drawWait`).
    private let drawWaitSeconds: TimeInterval
    private let lock = NSLock()

    /// Five seconds for everything a display is still missing: a slow network fails the message, never the screen.
    static let drawWait: TimeInterval = 5

    /// One file's use, as this cache recorded it.
    private struct Use: Codable {
        var at: TimeInterval
        var bytes: Int
    }

    private var uses: [String: Use]?
    private var indexURL: URL { directory.appendingPathComponent(".index.json") }

    init(
        directory: URL,
        fetcher: InAppAssetFetching = URLSessionAssetFetch(),
        maxBytes: Int = InAppAssetInline.cacheMaxBytes,
        clock: @escaping () -> Date = Date.init,
        drawWaitSeconds: TimeInterval = InAppAssetCache.drawWait
    ) {
        self.directory = directory
        self.fetcher = fetcher
        self.maxBytes = maxBytes
        self.clock = clock
        self.drawWaitSeconds = drawWaitSeconds
    }

    /// The record, read once. Called with the lock held.
    private func index() -> [String: Use] {
        if let uses { return uses }
        let read = (try? Data(contentsOf: indexURL)).flatMap { try? JSONDecoder().decode([String: Use].self, from: $0) } ?? [:]
        uses = read
        return read
    }

    /// A file used — written or read — now. `bytes` is kept from the write, when there was one.
    private func note(_ name: String, bytes: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        var record = index()
        record[name] = Use(at: clock().timeIntervalSince1970, bytes: bytes ?? record[name]?.bytes ?? 0)
        uses = record
        try? JSONEncoder().encode(record).write(to: indexURL)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(_ sha: String) -> URL { directory.appendingPathComponent(sha) }
    private func sheetURL(_ address: String) -> URL { directory.appendingPathComponent("css-" + Self.sha256Hex(Data(address.utf8))) }

    func has(_ sha: String) -> Bool { FileManager.default.fileExists(atPath: fileURL(sha).path) }
    func hasStylesheet(_ address: String) -> Bool { FileManager.default.fileExists(atPath: sheetURL(address).path) }
    func bytes(_ sha: String) -> Data? { try? Data(contentsOf: fileURL(sha)) }
    func stylesheet(_ address: String) -> String? { (try? Data(contentsOf: sheetURL(address))).flatMap { String(data: $0, encoding: .utf8) } }

    /// One file, kept only when its bytes are the hash its address names — a proxy's error page is never an image.
    @discardableResult
    func fetch(_ file: InAppAssetFile, limit: Int) async -> Bool {
        if has(file.sha256) { return true }
        guard file.bytes <= limit, let body = await fetcher.get(file.url, maxBytes: limit) else { return false }
        guard Self.sha256Hex(body) == file.sha256 else {
            TreebarsLogger.log("in-app: \(file.url) did not match its hash; not kept")
            return false
        }
        return write(body, to: fileURL(file.sha256))
    }

    /// A store stylesheet, kept only when it may be written into a document (`isInlinableStylesheet`).
    @discardableResult
    func fetchStylesheet(_ address: String) async -> Bool {
        if hasStylesheet(address) { return true }
        guard let body = await fetcher.get(address, maxBytes: InAppAssetInline.stylesheetMaxBytes),
              let text = String(data: body, encoding: .utf8), InAppAssetInline.isInlinableStylesheet(text)
        else { return false }
        return write(body, to: sheetURL(address))
    }

    /// At sync, for every message the device holds: a markup body's inlined files and stylesheets, a standard body's
    /// pictures. Then the bound.
    func prefetch(_ held: [(manifest: InAppAssetManifest?, markup: Bool)]) async {
        var keep = Set<String>()
        for (manifest, markup) in held {
            guard let manifest else { continue }
            if markup {
                let plan = InAppAssetInline.plan(manifest)
                for file in plan.inline {
                    if await fetch(file, limit: InAppAssetInline.fileMaxBytes) { keep.insert(file.sha256) }
                }
                for address in plan.stylesheets {
                    if await fetchStylesheet(address) { keep.insert(sheetURL(address).lastPathComponent) }
                }
            } else {
                for file in manifest.files where file.type.hasPrefix("image/") {
                    if await fetch(file, limit: Self.pictureMaxBytes) { keep.insert(file.sha256) }
                }
            }
        }
        evict(keeping: keep)
    }

    /**
     A markup body's document, its files inlined — or nil when the display must not go ahead (`asset_download`). What the
     prefetch has not landed yet is asked for here, once: a message triggered by the session that synced it is usually
     drawn before the prefetch it started has finished.
     */
    func prepare(_ manifest: InAppAssetManifest?, html: String) async -> String? {
        let plan = InAppAssetInline.plan(manifest)
        if plan.inline.isEmpty, plan.stylesheets.isEmpty { return plan.missing.isEmpty ? html : nil }
        if !plan.missing.isEmpty { return nil }
        await fetchNow(plan)
        guard InAppAssetInline.outcome(plan, has: has, hasStylesheet: hasStylesheet) == "ready" else { return nil }
        var files: [String: String] = [:]
        for file in plan.inline {
            guard let body = bytes(file.sha256) else { return nil }
            files[file.sha256] = InAppAssetInline.dataURI(type: file.type.isEmpty ? "application/octet-stream" : file.type, bytes: body)
            note(file.sha256)
        }
        var sheets: [String: String] = [:]
        for address in plan.stylesheets {
            guard let text = stylesheet(address) else { return nil }
            sheets[address] = text
        }
        return InAppAssetInline.inline(html, files: files, stylesheets: sheets)
    }

    /**
     What the display is still missing, together and within `drawWaitSeconds` in all. The screen is claimed while this
     runs, so every other message waits on it: one after another, forty files each allowed eight seconds on a captive
     portal would hold the screen for minutes and then fail anyway. At the deadline the fetches are cancelled — a
     URLSession request stops when its task is — and what has not landed is `asset_download`.
     */
    private func fetchNow(_ plan: InAppAssetPlan) async {
        let files = plan.inline.filter { !has($0.sha256) }
        let sheets = plan.stylesheets.filter { !hasStylesheet($0) }
        guard !files.isEmpty || !sheets.isEmpty else { return }
        let wait = UInt64(max(0, drawWaitSeconds) * 1_000_000_000)
        await withTaskGroup(of: Void.self) { race in
            race.addTask {
                await withTaskGroup(of: Void.self) { fetches in
                    for file in files { fetches.addTask { await self.fetch(file, limit: InAppAssetInline.fileMaxBytes) } }
                    for address in sheets { fetches.addTask { await self.fetchStylesheet(address) } }
                }
            }
            race.addTask { try? await Task.sleep(nanoseconds: wait) }
            await race.next()
            race.cancelAll()
        }
    }

    /// A picture's bytes, when its address is a store file this device holds.
    func pictureBytes(_ url: String) -> Data? {
        guard let sha = InAppAssetInline.storeHash(url), let body = bytes(sha) else { return nil }
        note(sha)
        return body
    }

    /// Everything, for `wipeLocalData`: what a forgotten device kept is not kept.
    func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory)
        uses = [:]
    }

    func evict(keeping keep: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        var record = index()
        let now = clock().timeIntervalSince1970
        var held: [(name: String, use: Use)] = []
        for name in names where !name.hasPrefix(".") {
            let use = record[name] ?? Use(at: 0, bytes: 0)
            // Not one written in the last minute: a display may have fetched it for a message a later sync brought.
            if !keep.contains(name), now - use.at > Self.recent {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
                record[name] = nil
                continue
            }
            held.append((name, use))
        }
        held.sort { $0.use.at < $1.use.at }
        var total = held.reduce(0) { $0 + $1.use.bytes }
        for entry in held where total > maxBytes {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.name))
            record[entry.name] = nil
            total -= entry.use.bytes
        }
        // What the directory no longer holds is not remembered either.
        let left = Set(names)
        record = record.filter { left.contains($0.key) }
        uses = record
        try? JSONEncoder().encode(record).write(to: indexURL)
    }

    private func write(_ body: Data, to target: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let part = directory.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString)")
            try body.write(to: part)
            // Another writer got there first with the same bytes, which is the same file: keep theirs.
            if (try? FileManager.default.moveItem(at: part, to: target)) == nil {
                try? FileManager.default.removeItem(at: part)
                guard FileManager.default.fileExists(atPath: target.path) else { return false }
            }
            note(target.lastPathComponent, bytes: body.count)
            return true
        } catch {
            return false
        }
    }

}
