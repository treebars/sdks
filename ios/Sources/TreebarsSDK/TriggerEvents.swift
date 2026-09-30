import Foundation

/**
 The environment's trigger list, as ingest hands it over: a version and the event names on it.

 The version is opaque. Equal lists have equal versions, and that is all a device needs to know
 about it — it is compared with the one every accepted upload carries, never parsed.
 */
struct TriggerList: Equatable, Sendable {
    let version: String
    let names: [String]

    var json: [String: Any] { ["version": version, "names": names] }

    init(version: String, names: [String]) {
        self.version = version
        self.names = names
    }

    /// Checked rather than trusted, off the wire and out of storage alike. Nil for anything else.
    init?(json: Any?) {
        guard let object = json as? [String: Any],
              let version = object["version"] as? String, !version.isEmpty,
              let names = object["names"] as? [Any]
        else { return nil }
        self.init(version: version, names: names.compactMap { $0 as? String })
    }
}

/**
 The list's file, in Application Support beside the uploader's. Written `.atomic`, so a kill
 mid-write leaves the previous list rather than half of this one. Isolated by filename, as the
 queue and the uploader's store are, so a test can hold its own.
 */
final class TriggerStore: @unchecked Sendable {
    private let fileURL: URL

    init(filename: String = TreebarsConstants.triggersFile) {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent(filename)
    }

    func load() -> TriggerList? {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return TriggerList(json: object)
    }

    /// The stored list removed: it was fetched for another write key's environment (`WriteKeyStamp`).
    func forget() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    @discardableResult
    func save(_ list: TriggerList) -> Bool {
        do {
            let data = try JSONSerialization.data(withJSONObject: list.json)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            TreebarsLogger.log("Trigger list could not be written", error.localizedDescription)
            return false
        }
    }
}

/**
 The environment's trigger list: the events this device sends within a second of logging them,
 rather than at the thirty-second tick. One of three implementations — `TriggerEvents.kt` and
 `sdks/web/src/triggers.ts` are the others — and all three are held to the same shared set of
 scenarios.

 The server decides what is on it — the events that start or advance a live campaign or journey —
 and hands it over in the in-app sync. Every accepted upload carries the list's version, so the
 device learns its copy is stale from an answer it was already waiting for and only then fetches
 the list — alone, with `triggers_only=1`, a much smaller request than the whole sync.

 Persisted so a relaunch flushes a listed event promptly before its own sync has returned. The list
 belongs to the write key's environment rather than to whoever is signed in, so `reset()` leaves it
 alone; a build that switches keys carries the other environment's list only until its first
 upload's version says otherwise.

 A class behind a lock rather than an actor: the uploader asks `contains` for every event it is told
 about, and a hop per event to read a set would be the most expensive thing on that path.
 */
final class TriggerEvents: @unchecked Sendable {
    private let store: TriggerStore
    /// Asks ingest for the list alone. Nil when it could not be had.
    private let fetch: @Sendable () async -> TriggerList?

    private let lock = NSLock()
    private var list: TriggerList?
    private var names: Set<String> = []
    /**
     Syncs in flight, the session's whole sync included. While one is out, a stale version on an
     upload does not start another: the answer on its way carries the list, and a cold start — whose
     first flush and first sync leave together — would otherwise fetch it twice.
     */
    private var syncing = 0

    init(store: TriggerStore, fetch: @escaping @Sendable () async -> TriggerList?) {
        self.store = store
        self.fetch = fetch
        if let stored = store.load() {
            list = stored
            names = Set(stored.names)
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var version: String? { locked { list?.version } }

    func contains(_ eventName: String) -> Bool { locked { names.contains(eventName) } }

    /// Called before a sync that may carry the list is sent.
    func beginSync() {
        locked { syncing += 1 }
    }

    /// Called when it has answered, with whatever its `trigger_events` held — or nil, when it failed
    /// or carried none, which keeps the list this device already has.
    func endSync(_ next: TriggerList?) {
        locked {
            syncing = max(0, syncing - 1)
            guard let next else { return }
            list = next
            names = Set(next.names)
        }
        if let next { store.save(next) }
    }

    /// Fetches the list alone, unless a sync that will carry it is already out.
    func refresh() async {
        let claimed = locked { () -> Bool in
            guard syncing == 0 else { return false }
            syncing = 1
            return true
        }
        guard claimed else { return }
        endSync(await fetch())
    }

    /// What an upload's answer said the current version is. A different one refreshes the list; the
    /// same one, or none — a refusal carries none — changes nothing.
    func observe(_ seen: String?) async {
        guard let seen, seen != version else { return }
        await refresh()
    }
}
