import Foundation

/// Durable event queue backed by a file in Application Support.
///
/// On disk so that events not yet uploaded survive the app being killed or crashing —
/// which is precisely when the most interesting events tend to occur — and cold starts.
///
/// This is an `actor` so that appends from any thread and the uploader's drain
/// cannot interleave.
actor EventQueue {
    private let fileURL: URL
    /*
     Read from disk on first use, not in `init`. The queue is built with the `Treebars` singleton —
     the first time anything touches `shared`, which is before `initialize` — so a queue that loaded
     in its initialiser would hold the previous run's events in memory before `initialize` could ask
     whose they were. `WriteKeyStamp` removes the file when the write key has changed, and that only
     works while nothing has read it yet: nothing reaches the queue before `initialize` except an
     opt-out or a wipe, both of which clear it anyway.
     */
    private lazy var events: [[String: Any]] = Self.load(from: fileURL)

    static let defaultFilename = "treebars-queue.json"

    /// Bounds disk usage for a device that stays offline for a long time. Oldest
    /// events are dropped first: recent behaviour is more valuable, and the
    /// alternative is refusing to record anything once full.
    private let maxEvents = TreebarsConstants.queueCap

    init(filename: String = EventQueue.defaultFilename) {
        self.fileURL = Self.url(for: filename)
    }

    private static func url(for filename: String) -> URL {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(filename)
    }

    /// Removes the stored queue without reading it — for a queue no instance has loaded yet (`WriteKeyStamp`).
    static func forget(filename: String = EventQueue.defaultFilename) {
        try? FileManager.default.removeItem(at: url(for: filename))
    }

    private static func load(from url: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return decoded
    }

    private func persist() {
        guard let data = try? JSONSerialization.data(withJSONObject: events) else { return }
        // `.atomic` prevents a half-written file if the app is terminated mid-write,
        // which would otherwise make the whole queue unreadable on next launch.
        try? data.write(to: fileURL, options: .atomic)
    }

    func append(_ event: [String: Any]) {
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        persist()
    }

    func peek(_ count: Int) -> [[String: Any]] {
        Array(events.prefix(count))
    }

    func remove(_ count: Int) {
        events.removeFirst(min(count, events.count))
        persist()
    }

    /// Removes these events wherever they are, rather than the oldest `n`.
    ///
    /// By id because the uploader seals a batch with `peek` and takes it off the queue only after
    /// writing it out, and an `append` can reach this actor in between: at the cap every append
    /// evicts from the front, which is where the batch being sealed sits. A `remove(n)` there
    /// takes events that were never sent.
    @discardableResult
    func remove(ids: Set<String>) -> Int {
        let before = events.count
        events.removeAll { ($0["event_id"] as? String).map(ids.contains) ?? false }
        let removed = before - events.count
        if removed > 0 { persist() }
        return removed
    }

    var count: Int { events.count }

    func clear() {
        events.removeAll()
        persist()
    }
}
