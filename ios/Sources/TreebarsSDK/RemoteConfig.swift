import Foundation

/**
 One remote config value as ingest hands it over: the key, the kind of value, and the value.

 `value` is whatever the JSON held — a boolean, a number, a string, or for a `json` variable a dictionary, an
 array or any of those — and is only ever answered to a read of its own `type`.
 */
struct ConfigEntry: @unchecked Sendable {
    let key: String
    let type: String
    let value: Any
    /// The answer may differ for a different account, or with nobody signed in.
    let userDependent: Bool
    /// Set when the value is an experiment's variant: its id, key, variant and unit, as they arrived.
    let experiment: [String: Any]?

    private static let types: Set<String> = ["boolean", "string", "number", "json"]

    /// Checked rather than trusted, off the wire and out of storage alike. Nil for anything that is not one.
    init?(json: Any?) {
        guard let object = json as? [String: Any],
              let key = object["key"] as? String, !key.isEmpty,
              let type = object["type"] as? String, Self.types.contains(type),
              let value = object["value"]
        else { return nil }
        self.key = key
        self.type = type
        self.value = value
        self.userDependent = (object["user_dependent"] as? NSNumber).map { Self.isBoolean($0) && $0.boolValue } ?? false
        let experiment = object["experiment"] as? [String: Any]
        self.experiment = experiment.flatMap {
            $0["id"] is String && $0["key"] is String && $0["variant"] is String ? $0 : nil
        }
    }

    var json: [String: Any] {
        var out: [String: Any] = ["key": key, "type": type, "value": value]
        if userDependent { out["user_dependent"] = true }
        if let experiment { out["experiment"] = experiment }
        return out
    }

    /// Whether a read of this and a read of `other` would answer alike.
    func sameAs(_ other: ConfigEntry?) -> Bool {
        guard let other else { return false }
        return type == other.type && userDependent == other.userDependent && Self.canonical(value) == Self.canonical(other.value)
    }

    /// `JSONSerialization` hands back a boolean and a number as the same class: this tells them apart.
    static func isBoolean(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }

    /// A value as text two equal values share: a dictionary's keys in order, whatever order they arrived in.
    static func canonical(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether `value` is a value of `type`. A value is never bent into another kind.
    static func fits(_ value: Any?, _ type: String) -> Bool {
        guard let value else { return false }
        switch type {
        case "boolean": return (value as? NSNumber).map(isBoolean) ?? false
        case "string": return value is String
        case "number":
            guard let number = value as? NSNumber, !isBoolean(number) else { return false }
            return number.doubleValue.isFinite
        default: return true
        }
    }
}

/// Who is asking, as an ask carries it.
struct ConfigAsk: @unchecked Sendable {
    let userId: String?
    let attributes: [String: Any]
}

/// What an ask came back with: the answer's body, or how it failed.
enum ConfigAnswer: @unchecked Sendable {
    case answered(Any?)
    case failed(status: Int?, retryAfter: String?)
}

/**
 Remote config's file, in Application Support beside the trigger list's: the answers held and the wait a
 refusal set, what each key read as in the running session, and what the app said about the install. Written
 `.atomic`, so a kill mid-write leaves the previous state rather than half of this one.
 */
final class ConfigStore: @unchecked Sendable {
    private let fileURL: URL

    init(filename: String = TreebarsConstants.configFile) {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent(filename)
    }

    func load() -> [String: Any]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The stored state removed: it was another write key's, or the person said to forget it.
    func forget() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    @discardableResult
    func save(_ state: [String: Any]) -> Bool {
        do {
            let data = try JSONSerialization.data(withJSONObject: state)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            TreebarsLogger.log("Remote config could not be written", error.localizedDescription)
            return false
        }
    }
}

/// A read answered an experiment's variant: what is reported about it.
struct ConfigExposure: Sendable {
    let experimentId: String
    let experimentKey: String
    let variant: String
    /// The key that was read.
    let variable: String
    /// What the variant was drawn by: `device` or `user`.
    let unit: String
}

/**
 Remote config: values an app reads by key and Treebars decides. One of three implementations —
 `RemoteConfig.kt` and the web SDK's `config.ts` are the others — and all three are held to the same shared set
 of scenarios.

 Treebars works out this install's answers and hands them over whole — one value for each variable, and nothing
 about why. This holds them, answers reads from them, and decides when to ask again.

 **A read never waits and never fails.** It answers from what this install holds, and nil — for the caller to
 put its fallback in place of — when it holds nothing for that key or holds another kind.

 **A variant is reported when a read answers it, not when it arrives.** A value that is an experiment's variant
 says so, and the first read to answer it reports that this install was shown that variant — at most once a day
 for the same variant, and at once for a different one. A value held and never read reports nothing: no screen
 used it. Nor does a read answered by an override, a read as another kind, or a listing of every value.

 **A key keeps its answer for the session.** The first read of a key in a session fixes what that key reads as
 until the session ends, "not set" included, so a screen never changes under somebody because a newer answer
 arrived half-way through. A key not read yet takes the newest answer held; a new session, or `activate()`,
 forgets what was read.

 **It asks only when there is something to learn.** Every accepted upload names the current version, so this
 learns its copy is stale from an answer it was already waiting for. With nothing held and no version named,
 nothing is asked at all: an app whose project has no variables never makes a config request. It also asks when
 who is asking changes in a way an answer may depend on — an account signs in or out, the app sets different
 attributes, the device describes itself differently than it did — and whenever the app says to.

 **An account's answers do not outlive the account.** At sign-out, and when a different account signs in, the
 answers that depended on the last one are dropped at once, before the next ones arrive.

 A class behind a lock rather than an actor: a read is synchronous, from whichever thread the app reads on, and
 a hop to read a flag would turn every read into something to await. Listeners are called outside the lock.
 */
final class RemoteConfig: @unchecked Sendable {
    /// The answers held, and how they were asked for.
    private struct Held {
        let version: String
        var values: [ConfigEntry]
        /// How the device described itself when these were asked for.
        let context: String
        /// Who is asking has changed since: these stand until the next answer, and another ask is owed.
        var stale: Bool

        func entry(_ key: String) -> ConfigEntry? { values.first { $0.key == key } }

        var json: [String: Any] {
            ["version": version, "values": values.map(\.json), "context": context, "stale": stale]
        }
    }

    private let store: ConfigStore?
    /// Asks ingest for this install's answers.
    private let fetch: @Sendable (ConfigAsk) async -> ConfigAnswer
    /// Starts an ask nobody is waiting on: after an upload's answer, a sign-in, a change of attributes.
    private let launch: @Sendable (@escaping @Sendable () async -> Void) -> Void
    /// Writes the state somewhere a read on the main thread does not wait for.
    private let persist: @Sendable (ConfigStore, [String: Any]) -> Void
    /// Epoch milliseconds.
    private let now: @Sendable () -> Int64
    /// Told, outside the lock, when a read answers an experiment's variant that is due to be reported.
    private let expose: @Sendable (ConfigExposure) -> Void

    private let lock = NSLock()
    private var held: Held?
    /// No ask before this moment, in epoch milliseconds: a refusal's wait, kept across launches.
    private var notBefore: Int64 = 0
    /// What this install was last reported as shown, by experiment id: the variant, and when.
    private var exposed: [String: (variant: String, at: Int64)] = [:]
    private var sessionId = ""
    /// What each key read as in this session. A key mapped to nil read as "not set".
    private var seen: [String: ConfigEntry?] = [:]
    private var attributes: [String: Any] = [:]
    private var overrides: [String: Any] = [:]
    private var listeners: [UUID: @Sendable () -> Void] = [:]
    private var userId: String?
    private var context = ""
    /// Whether an ask is out.
    private var asking = false
    /// Who is waiting to hear whether the ask that is out brought answers: `fetchConfig`, `configReady`.
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    /// Who is asking changed while an ask was out: one more follows it.
    private var again = false
    /// The next answer is for a different account than the last: what depended on the account is read afresh from it.
    private var reopen = false

    /// The writes take turns on one queue, so the state written last is the newest.
    private static let writes = DispatchQueue(label: "com.treebars.sdk.config-store", qos: .utility)

    init(
        store: ConfigStore?,
        fetch: @escaping @Sendable (ConfigAsk) async -> ConfigAnswer,
        launch: @escaping @Sendable (@escaping @Sendable () async -> Void) -> Void = { body in Task { await body() } },
        persist: @escaping @Sendable (ConfigStore, [String: Any]) -> Void = { store, state in
            RemoteConfig.writes.async { store.save(state) }
        },
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        expose: @escaping @Sendable (ConfigExposure) -> Void = { _ in }
    ) {
        self.store = store
        self.fetch = fetch
        self.launch = launch
        self.persist = persist
        self.now = now
        self.expose = expose
        guard let stored = store?.load() else { return }
        held = Self.readHeld(stored["set"])
        notBefore = (stored["not_before"] as? NSNumber)?.int64Value ?? 0
        if let session = stored["session"] as? [String: Any],
           let id = session["id"] as? String,
           let read = session["seen"] as? [String: Any] {
            sessionId = id
            for (key, entry) in read { seen[key] = .some(ConfigEntry(json: entry)) }
        }
        attributes = Self.cleanAttributes(stored["attributes"] as? [String: Any] ?? [:])
        for (id, one) in stored["exposed"] as? [String: Any] ?? [:] {
            guard let one = one as? [String: Any],
                  let variant = one["variant"] as? String,
                  let at = (one["at"] as? NSNumber)?.int64Value
            else { continue }
            exposed[id] = (variant, at)
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// The version held, or nil when nothing is.
    var version: String? { locked { held?.version } }

    /// Whether there is something to ask for that no upload's answer will prompt: nothing held, or an ask still owed.
    var wanting: Bool { locked { held?.stale ?? true } }

    /**
     Called once the SDK knows who is signed in and how the device describes itself (`context`: any string that
     changes when that description does), and its session where it already knows one. Asks when the answers held
     were asked for by a device that described itself differently, or an ask is owed from before.
     */
    func start(sessionId: String?, userId: String?, context: String) {
        let owed = locked { () -> Bool in
            self.userId = userId
            self.context = context
            if var set = held, !set.values.isEmpty, set.context != context {
                set.stale = true
                held = set
            }
            return held?.stale == true
        }
        // Where the session is not known yet, what was read stands until `sessionStarted` says which one this is.
        if let sessionId { sessionStarted(sessionId) }
        if owed { begin() }
    }

    /// A session began, or is the one already running. A different one forgets what was read.
    func sessionStarted(_ id: String) {
        let moved = locked { () -> Bool in
            guard id != sessionId else { return false }
            let moved = wouldChange()
            sessionId = id
            seen.removeAll()
            save()
            return moved
        }
        if moved { announce() }
    }

    /**
     One key, as the kind asked for: the value, or nil for the caller to answer its fallback — when nothing is held
     for the key, or what is held is another kind. The first read of a key in a session fixes it.
     */
    func read(_ key: String, as type: String) -> Any? {
        let (value, due): (Any?, ConfigExposure?) = locked {
            if let override = overrides[key] { return (ConfigEntry.fits(override, type) ? override : nil, nil) }
            guard let entry = entry(key), entry.type == type, ConfigEntry.fits(entry.value, type) else { return (nil, nil) }
            return (entry.value, exposureDue(entry))
        }
        // Outside the lock: what hears it records an event, and a read must not hold the lock for that.
        if let due { expose(due) }
        return value
    }

    /**
     Under the lock: the exposure to report for a read that answered `entry`, or nil — when no experiment decided
     it, or the same variant was reported less than a day ago. Counted on this install's own clock in either
     direction, so a clock set back does not silence the report for as long as it was set back by.
     */
    private func exposureDue(_ entry: ConfigEntry) -> ConfigExposure? {
        guard let experiment = entry.experiment,
              let id = experiment["id"] as? String,
              let variant = experiment["variant"] as? String
        else { return nil }
        let moment = now()
        if let last = exposed[id], last.variant == variant, abs(moment - last.at) < Self.exposureFloor { return nil }
        exposed[id] = (variant, moment)
        save()
        return ConfigExposure(
            experimentId: id,
            experimentKey: experiment["key"] as? String ?? "",
            variant: variant,
            variable: entry.key,
            unit: experiment["unit"] as? String ?? "device"
        )
    }

    /// The least time between two reports of the same variant, in milliseconds.
    private static let exposureFloor = Int64(TreebarsConstants.configExposureFloor * 1000)

    /// The entry a key answers with now, or nil for "not set". Called under the lock.
    private func entry(_ key: String) -> ConfigEntry? {
        if let read = seen[key] { return read }
        let entry = held?.entry(key)
        seen[key] = .some(entry)
        save()
        return entry
    }

    /// Every key held, with the value a read would answer. Reading them all fixes them all for the session.
    func all() -> [String: Any] {
        locked {
            var out: [String: Any] = [:]
            for one in held?.values ?? [] {
                if let entry = entry(one.key) { out[one.key] = entry.value }
            }
            for (key, entry) in seen where out[key] == nil {
                if let entry { out[key] = entry.value }
            }
            for (key, value) in overrides { out[key] = value }
            return out
        }
    }

    /// Whether a key already read would answer differently if it were read afresh. Called under the lock.
    private func wouldChange() -> Bool {
        seen.contains { key, was in
            let current = held?.entry(key)
            guard let was else { return current != nil }
            return !was.sameAs(current)
        }
    }

    /// Applies the newest answers to keys already read. True when a read now answers differently.
    @discardableResult
    func activate() -> Bool {
        let moved = locked { () -> Bool in
            let moved = wouldChange()
            seen.removeAll()
            save()
            return moved
        }
        if moved { announce() }
        return moved
    }

    /// What an upload's answer said the current version is. A different one asks; so does an ask still owed.
    func observe(_ version: String?) {
        let ask = locked { (version != nil && version != held?.version) || held?.stale == true }
        if ask { begin() }
    }

    /**
     Somebody signed in, or out (nil). What depended on the account is read afresh; when the last one was an
     account, its answers are dropped now rather than when the next ones arrive.
     */
    func identityChanged(_ next: String?) {
        enum Outcome { case nothing, ask, dropAndAsk }
        let outcome = locked { () -> Outcome in
            guard next != userId else { return .nothing }
            let previous = userId
            userId = next
            guard var set = held, set.values.contains(where: \.userDependent) else { return .nothing }

            for key in Array(seen.keys) where (seen[key] ?? nil)?.userDependent == true || set.entry(key)?.userDependent == true {
                seen.removeValue(forKey: key)
            }
            // Kept from nobody to somebody: the same person, a moment before they said who they are.
            if previous != nil { set.values.removeAll(where: \.userDependent) }
            set.stale = true
            held = set
            reopen = true
            save()
            return previous != nil ? .dropAndAsk : .ask
        }
        if outcome == .nothing { return }
        if outcome == .dropAndAsk { announce() }
        begin()
    }

    /// What the app says about this install, for rules to read. The same attributes again change nothing.
    func setAttributes(_ next: [String: Any]) {
        let ask = locked { () -> Bool in
            let cleaned = Self.cleanAttributes(next)
            guard Self.attributesKey(cleaned) != Self.attributesKey(attributes) else { return false }
            attributes = cleaned
            guard var set = held, !set.values.isEmpty else {
                save()
                return false
            }
            set.stale = true
            held = set
            save()
            return true
        }
        if ask { begin() }
    }

    /// Answers a key with `value` in this process, before anything held. Nil takes it back. Never kept.
    func override(_ key: String, _ value: Any?) {
        // Assigning nil through the subscript is how a dictionary forgets a key.
        locked { overrides[key] = value }
        announce()
    }

    /// Calls `listener` whenever what a read answers may have changed. Returns the way to stop hearing.
    @discardableResult
    func onChange(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let id = UUID()
        locked { listeners[id] = listener }
        return { [weak self] in
            guard let self else { return }
            self.locked { _ = self.listeners.removeValue(forKey: id) }
        }
    }

    /**
     Starts an ask, unless one is out or a refusal's wait is still running. Decided here, on the caller's own
     thread and under the lock, and only the request itself is handed off — so two things that each call for
     an ask a moment apart start one, never two: the second finds the first already out.
     */
    private func begin() {
        let started: (ConfigAsk, String)? = locked {
            if asking {
                again = true
                return nil
            }
            guard now() >= notBefore else { return nil }
            asking = true
            return (ConfigAsk(userId: userId, attributes: attributes), context)
        }
        guard let (asked, context) = started else { return }
        launch { [self] in _ = await ask(asked, context: context) }
    }

    /**
     Asks now, unless a refusal's wait is still running, and waits for the answer. Joins an ask already out.
     True when answers arrived, false when they did not.
     */
    @discardableResult
    func refresh() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            enum Plan { case wait, refused, start(ConfigAsk, String) }
            let plan: Plan = locked {
                if asking {
                    again = true
                    waiters.append(continuation)
                    return .wait
                }
                guard now() >= notBefore else { return .refused }
                asking = true
                waiters.append(continuation)
                return .start(ConfigAsk(userId: userId, attributes: attributes), context)
            }
            switch plan {
            case .wait: break
            case .refused: continuation.resume(returning: false)
            case .start(let asked, let context): launch { [self] in _ = await ask(asked, context: context) }
            }
        }
    }

    private func ask(_ asked: ConfigAsk, context: String) async -> Bool {
        let answer = await fetch(asked)

        var changed = false
        var follow = false
        var waiting: [CheckedContinuation<Bool, Never>] = []
        let arrived = locked { () -> Bool in
            asking = false
            waiting = waiters
            waiters = []
            let wasAgain = again
            again = false
            var read: (String, [ConfigEntry])?
            var failed: (status: Int?, retryAfter: String?) = (nil, nil)
            switch answer {
            case .answered(let body): read = Self.readAnswer(body)
            case .failed(let status, let retryAfter): failed = (status, retryAfter)
            }
            guard let read else {
                notBefore = now() + Self.waitFor(status: failed.status, retryAfter: failed.retryAfter)
                save()
                return false
            }
            // Whether who asked is still who is asking: if not, these stand for now and one more ask follows.
            let current = asked.userId == userId
                && Self.attributesKey(asked.attributes) == Self.attributesKey(attributes)
                && context == self.context
            let previous = held
            let next = Held(version: read.0, values: read.1, context: context, stale: !current)
            held = next
            notBefore = 0
            // An experiment no longer among the answers, last reported more than a day ago, would be reported afresh anyway.
            let moment = now()
            exposed = exposed.filter { id, last in
                abs(moment - last.at) < Self.exposureFloor || next.values.contains { $0.experiment?["id"] as? String == id }
            }
            if reopen {
                for key in Array(seen.keys) where (seen[key] ?? nil)?.userDependent == true || next.entry(key)?.userDependent == true {
                    seen.removeValue(forKey: key)
                }
                if current { reopen = false }
            }
            save()
            changed = previous == nil || previous?.version != next.version || previous?.stale == true
            follow = !current || (wasAgain && next.stale)
            return true
        }
        if changed { announce() }
        for continuation in waiting { continuation.resume(returning: arrived) }
        if follow { begin() }
        return arrived
    }

    /// Forgets everything held: for a person who opted out, and a device being forgotten.
    func clear() {
        locked {
            held = nil
            notBefore = 0
            exposed.removeAll()
            seen.removeAll()
            attributes = [:]
            overrides.removeAll()
        }
        store?.forget()
    }

    private func announce() {
        let hearing = locked { Array(listeners.values) }
        for listener in hearing { listener() }
    }

    /// Called under the lock: the state as it stands, handed to whatever writes it.
    private func save() {
        guard let store else { return }
        var read: [String: Any] = [:]
        for (key, entry) in seen { read[key] = entry?.json ?? NSNull() }
        var state: [String: Any] = [
            "set": held?.json ?? NSNull(),
            "not_before": notBefore,
            "session": ["id": sessionId, "seen": read] as [String: Any],
            "attributes": attributes,
        ]
        if !exposed.isEmpty {
            state["exposed"] = exposed.mapValues { ["variant": $0.variant, "at": $0.at] as [String: Any] }
        }
        persist(store, state)
    }

    /// An answer off the wire, checked rather than trusted: a version and a list. An entry that is not one is left out.
    static func readAnswer(_ json: Any?) -> (String, [ConfigEntry])? {
        guard let object = json as? [String: Any],
              let version = object["version"] as? String, !version.isEmpty,
              let values = object["values"] as? [Any]
        else { return nil }
        return (version, values.compactMap(ConfigEntry.init(json:)))
    }

    private static func readHeld(_ json: Any?) -> Held? {
        guard let (version, values) = readAnswer(json), let object = json as? [String: Any] else { return nil }
        let stale = (object["stale"] as? NSNumber).map { ConfigEntry.isBoolean($0) && $0.boolValue } ?? false
        return Held(version: version, values: values, context: object["context"] as? String ?? "", stale: stale)
    }

    /// Text, numbers and booleans, under keys that are not empty.
    static func cleanAttributes(_ raw: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in raw where !key.isEmpty {
            if value is String {
                out[key] = value
            } else if let number = value as? NSNumber, ConfigEntry.isBoolean(number) || number.doubleValue.isFinite {
                out[key] = number
            }
        }
        return out
    }

    /// Attributes as text two equal sets share, whatever order they were set in.
    static func attributesKey(_ attributes: [String: Any]) -> String { ConfigEntry.canonical(attributes) }

    /// How long a refusal asks this install to wait, in milliseconds.
    static func waitFor(status: Int?, retryAfter: String?) -> Int64 {
        if let status, TreebarsConstants.authStatuses.contains(status) {
            return Int64(TreebarsConstants.authCooldown * 1000)
        }
        if let status, TreebarsConstants.retryAfterStatuses.contains(status),
           let seconds = retryAfter.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
           seconds >= 0, seconds.isFinite {
            return Int64(min(seconds, TreebarsConstants.retryAfterMax) * 1000)
        }
        return Int64(TreebarsConstants.configRetry * 1000)
    }
}

/// Something two tasks race to do once: whichever claims it first does it.
final class ConfigOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
