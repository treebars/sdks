import Foundation

/**
 What an upload attempt did, for a host app that wants to watch.

 `TreebarsLogger` writes to the console when `debug` is on, and that is a developer reading
 Xcode, not something an app can render; this is. It is also what the React Native bridge
 forwards as `onUpload`.

 `count` and `eventNames` are nil on anything that is not an event batch. Names rather than
 bodies deliberately: the point is "what went and did it land", and a panel that printed
 properties would put a customer's data on a screen this SDK does not control.
 */
public struct UploadLog: Sendable {
    public let type: String
    public let status: String
    public let message: String
    public let count: Int?
    public let eventNames: [String]?
    public let statusCode: Int?
}

/*
 How far ahead either gate may legitimately be. Anything further is a clock that moved backwards
 after the gate was written, and a persisted gate would otherwise hold a device silent until the
 clock caught up — a day, for somebody who set their phone back a day.
 */
private let retryGateCeilingMs = Int64(max(TreebarsConstants.backoffCap, TreebarsConstants.retryAfterMax) * 1000)
private let authGateCeilingMs = Int64(TreebarsConstants.authCooldown * 1000)

/**
 The upload policy, one of three implementations of it — the Kotlin core and `sdks/web` carry the
 other two — and all three run the same shared scenarios (`UploaderScenariosTests` here).

 A batch is sealed and written to `UploaderStore` before its first send, and it is resent
 unchanged — same id, same events — until a 2xx removes it, including after the app is killed. So
 a batch whose response was lost — written by the server, the connection gone before the 200 —
 goes out again under the same id and can be recognised as the one already written. A flush drains
 up to `drainMaxBatches`, stops at the first failure, and leaves behind a persisted gate: a
 full-jitter backoff, the server's `Retry-After`, or an hour's cooldown for a refused write key.
 Jitter rather than a fixed ladder, so devices recovering from the same outage do not all retry at
 the same instants. A 413 splits the batch into halves with derived ids; any other 4xx drops it.

 An `actor` so that a timer-driven flush, a size-triggered flush and a background-transition
 flush cannot run concurrently and send the same batch twice. Nothing in it sleeps except the one
 wake it schedules; the clock, the jitter, the ids and where a wake sleeps are handed in, which is
 what lets the scenarios run it without waiting.

 It also decides when a listed event goes out — the trigger scenarios (`TriggerScenariosTests`) are
 that half of the policy, and `TriggerEvents` is the list it asks.
 */
actor EventUploader {
    private let queue: EventQueue
    private let transport: EventTransport
    private let store: UploaderStore
    private let writeKey: String
    private let batchSize: Int
    private let now: @Sendable () -> Int64
    /// In [0, 1). The jitter source, and the only randomness in the policy.
    private let random: @Sendable () -> Double
    private let newBatchId: @Sendable () -> String
    /// Where a wake sleeps. Nil in the upload scenarios, which drive time themselves.
    private let wakes: (any UploadWakes)?
    /// The trigger list. Nil means no event flushes early and no version is acted on.
    private let triggers: TriggerEvents?
    /**
     True while the person has opted out (`Treebars.optOut()`). Nothing is sent then, whoever asks — the
     timer, the lifecycle, a wake, a trigger, the flush on the way up — not only the public `flush()`.
     Asked before every batch, so a drain already running stops at the next one. It drops nothing
     itself; that is the opt-out's discard.
     */
    private let paused: @Sendable () -> Bool

    /// Read from storage on construction, as the queue reads its own file.
    private var state: UploaderState
    private var reconciled = false
    private var isFlushing = false
    private var wake: (any UploadWake)?
    private var wakeAt: Int64 = 0
    /// The newest trigger version the current flush's answers carried.
    private var seenTriggersVersion: String?
    /// Bumped by `discardPending`, so an upload that was out at the time settles nothing when it answers.
    private var generation = 0

    /// Set through `Treebars.setUploadListener`. Never awaited and never allowed to break a
    /// flush: a listener that throws is the host app's bug, and losing a batch over it
    /// would be ours.
    var listener: (@Sendable (UploadLog) -> Void)?

    private func report(
        _ status: String,
        _ message: String,
        count: Int? = nil,
        names: [String]? = nil,
        statusCode: Int? = nil
    ) {
        listener?(
            UploadLog(
                type: "events",
                status: status,
                message: message,
                count: count,
                eventNames: names,
                statusCode: statusCode
            )
        )
    }

    init(
        queue: EventQueue,
        transport: EventTransport,
        store: UploaderStore,
        writeKey: String,
        batchSize: Int = TreebarsConstants.batchSize,
        now: @escaping @Sendable () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
        newBatchId: @escaping @Sendable () -> String = { UUID().uuidString },
        wakes: (any UploadWakes)? = TaskWakes(),
        triggers: TriggerEvents? = nil,
        paused: @escaping @Sendable () -> Bool = { false }
    ) {
        self.queue = queue
        self.transport = transport
        self.store = store
        self.writeKey = writeKey
        self.batchSize = max(1, batchSize)
        self.now = now
        self.random = random
        self.newBatchId = newBatchId
        self.wakes = wakes
        self.triggers = triggers
        self.paused = paused
        self.state = store.load()
    }

    /**
     Drains, and then — if an answer said the trigger list has moved on — fetches it. After the drain
     rather than inside it, so queued uploads are never held behind a list, and after `isFlushing`
     is released, so a wake is not either; a drain whose every answer carried the new version fetches
     the list once.
     */
    func flush() async {
        guard !isFlushing else { return }
        isFlushing = true
        seenTriggersVersion = nil
        await drain()
        isFlushing = false
        await triggers?.observe(seenTriggersVersion)
    }

    /**
     A logged event, told to the uploader once it is on the queue. A listed one asks for a flush
     `triggerFlushDebounce` from now.

     It asks and nothing more. The flush that answers checks the `Retry-After` gate and the auth
     cooldown like every other flush, so a trigger cannot send anything a 429 said to hold — and a
     wake already due sooner, a retry's, is left where it is and carries the trigger with it. Only
     the first trigger arms the wake: later ones inside the second ride it rather than pushing it
     back, or a trigger every nine hundred milliseconds would never be sent.
     */
    func eventLogged(_ eventName: String) {
        guard triggers?.contains(eventName) == true else { return }
        scheduleWake(at: now() + Int64(TreebarsConstants.triggerFlushDebounce * 1000))
    }

    private func drain() async {
        await reconcile()
        var sends = 0
        while sends < TreebarsConstants.drainMaxBatches {
            if paused() || gated(at: now()) { return }
            let batch: PendingBatch
            if let head = state.pending.first {
                batch = head
            } else if let sealed = await seal() {
                batch = sealed
            } else {
                return
            }

            let names = batch.events.compactMap { $0["event_name"] as? String }
            report("sending", "Sending \(batch.events.count) event(s)", count: batch.events.count, names: names)

            let started = generation
            var response: UploadResponse?
            do {
                response = try await transport.postEvents(batch: batch.json)
            } catch {
                // No answer at all. The batch is on disk, so this recovers.
                TreebarsLogger.log("Upload failed", error.localizedDescription)
            }
            // Discarded while the request was out: the batch it answers for is gone, and all behind it.
            // Settling it anyway would split or retry a batch that no longer exists.
            if generation != started { return }
            if let version = response?.triggersVersion { seenTriggersVersion = version }
            sends += 1
            guard await settle(batch, response) else { return }
        }
    }

    /**
     Drops every sealed batch, with the gates they had closed — for an opt-out or a wipe, where the
     person said stop rather than "after these". An upload already out finishes its one request and
     settles nothing (`generation`).
     */
    func discardPending() {
        generation += 1
        commit(UploaderState())
    }

    func setListener(_ listener: (@Sendable (UploadLog) -> Void)?) {
        self.listener = listener
    }

    /// How many events are waiting: the queue, and the batches sealed and not yet acknowledged.
    ///
    /// Both, because a batch leaves the queue when it is sealed rather than when it lands:
    /// counting the queue alone would show a failing upload as an empty one.
    func pending() async -> Int {
        await queue.count + state.pending.reduce(0) { $0 + $1.events.count }
    }

    /**
     The queue checked against the stored batches, once per process.

     A batch is written out and only then taken off the queue, so an app killed between the two
     leaves its events in both. They are the same events under the same ids, and sealing the
     queue's copies into a new batch would be exactly the double count this exists to prevent.
     */
    private func reconcile() async {
        guard !reconciled else { return }
        reconciled = true
        await queue.remove(ids: state.pendingEventIds)
    }

    @discardableResult
    private func commit(_ next: UploaderState) -> Bool {
        state = next
        return store.save(next)
    }

    /// Whether either gate is closed at `now`, re-basing one further ahead than it could have been set.
    private func gated(at now: Int64) -> Bool {
        var next = state
        var moved = false
        if next.nextAllowedAt > now + retryGateCeilingMs {
            next.nextAllowedAt = now + retryGateCeilingMs
            moved = true
        }
        if next.authBlockedUntil > now + authGateCeilingMs {
            next.authBlockedUntil = now + authGateCeilingMs
            moved = true
        }
        if moved { commit(next) }

        if next.authBlockedUntil > now, next.authKey == writeKey { return true }
        if next.nextAllowedAt > now {
            scheduleWake(at: next.nextAllowedAt)
            return true
        }
        return false
    }

    /**
     Takes the head of the queue as a new pending batch, written before anything is sent.

     The queue's copies are removed only once that write has landed. If it did not, they stay
     queued and are removed on acknowledgement instead, so a kill in between re-sends them rather
     than losing them.
     */
    private func seal() async -> PendingBatch? {
        let events = await queue.peek(batchSize)
        guard !events.isEmpty else { return nil }

        let sealedAt = Date(timeIntervalSince1970: TimeInterval(now()) / 1000)
        let batch = PendingBatch(batchId: newBatchId(), sentAt: Iso8601.string(from: sealedAt), events: events)
        var next = state
        next.pending = [batch]
        if commit(next) { await queue.remove(ids: batch.eventIds) }
        return batch
    }

    /// Applies one answer. True when the drain may continue.
    private func settle(_ batch: PendingBatch, _ response: UploadResponse?) async -> Bool {
        let now = now()
        var next = state
        let status = response?.status ?? 0
        let count = batch.events.count
        let names = batch.events.compactMap { $0["event_name"] as? String }

        if response != nil, (200..<300).contains(status) {
            if !next.pending.isEmpty { next.pending.removeFirst() }
            next.attempt = 0
            next.nextAllowedAt = 0
            next.authBlockedUntil = 0
            next.authKey = nil
            commit(next)
            // Normally a no-op: see `seal` for the one case where the queue still holds them.
            await queue.remove(ids: batch.eventIds)
            TreebarsLogger.log("Uploaded \(count) event(s)")
            report("success", "Sent \(count) event(s)", count: count, names: names, statusCode: status)
            return true
        }

        if response != nil, status == 413 {
            if count > 1 {
                /*
                 * Halves under derived ids, written in place of the batch. Derived rather than
                 * minted so that a split replayed after a crash — the whole batch resent, refused
                 * again, split again — produces the same two ids, and a half the server already
                 * took is recognised.
                 */
                let middle = (count + 1) / 2
                next.pending.replaceSubrange(0..<1, with: [
                    PendingBatch(batchId: "\(batch.batchId).0", sentAt: batch.sentAt, events: Array(batch.events[..<middle])),
                    PendingBatch(batchId: "\(batch.batchId).1", sentAt: batch.sentAt, events: Array(batch.events[middle...])),
                ])
                next.attempt = 0
                next.nextAllowedAt = 0
                commit(next)
                TreebarsLogger.log("Batch of \(count) too large; split in two")
                report("error", "Batch too large; split in two", count: count, names: names, statusCode: status)
                return true
            }
            await drop(batch, status: status, names: names)
            return false
        }

        if response != nil, TreebarsConstants.authStatuses.contains(status) {
            next.attempt = 0
            next.nextAllowedAt = 0
            next.authBlockedUntil = now + authGateCeilingMs
            next.authKey = writeKey
            commit(next)
            TreebarsLogger.log("Upload rejected (HTTP \(status)). Check the write key; retrying in an hour.")
            report("error", "Upload refused; check the write key", count: count, names: names, statusCode: status)
            return false
        }

        let honoursRetryAfter = response != nil && TreebarsConstants.retryAfterStatuses.contains(status)
        if response != nil, !honoursRetryAfter, (400..<500).contains(status) {
            await drop(batch, status: status, names: names)
            return false
        }

        /*
         * Everything else is worth another attempt: no answer at all, a 5xx, a 429, and whatever a
         * proxy invents. The server's own delay wins where it gave a usable one; otherwise jitter.
         */
        let asked = honoursRetryAfter ? retryAfterDelayMs(response?.retryAfter, now: now) : nil
        let wait: Int64
        if let asked, asked > 0 {
            wait = min(asked, Int64(TreebarsConstants.retryAfterMax * 1000))
        } else {
            wait = jitterMs(attempt: next.attempt, random: random())
        }
        next.attempt += 1
        next.nextAllowedAt = now + wait
        commit(next)
        TreebarsLogger.log("Upload not accepted (\(response == nil ? "no answer" : "HTTP \(status)")); retrying in \(wait)ms")
        report("error", "Upload failed; retrying in \((wait + 999) / 1000)s", count: count, names: names, statusCode: response?.status)
        scheduleWake(at: next.nextAllowedAt)
        return false
    }

    /// A batch that will never succeed. Gone from both stores, and the drain ends with it.
    private func drop(_ batch: PendingBatch, status: Int, names: [String]) async {
        var next = state
        if !next.pending.isEmpty { next.pending.removeFirst() }
        next.attempt = 0
        next.nextAllowedAt = 0
        commit(next)
        await queue.remove(ids: batch.eventIds)
        TreebarsLogger.log("Server rejected \(batch.events.count) event(s) (HTTP \(status)); discarded")
        report("error", "Server rejected the batch; discarded", count: batch.events.count, names: names, statusCode: status)
    }

    /**
     One wake, at the earliest moment anything has asked for: a retry falling due, or a listed
     event's debounce running out.

     Without it a two-second backoff would wait for the thirty-second timer, and the jitter would be
     decoration — and so would a trigger. A closed gate reports itself on every flush attempt — each
     event past the batch size is one — so a wake still sleeping towards this time or an earlier one
     is left alone: it will find the gate and ask again. A wake whose time has come is not treated as
     pending, because the flush that schedules the next retry is usually that wake's own.
     */
    private func scheduleWake(at: Int64) {
        guard let wakes else { return }
        let current = now()
        if let sleeping = wake, wakeAt > current {
            if wakeAt <= at { return }
            sleeping.cancel()
        }
        wakeAt = at
        wake = wakes.arm(after: max(0, at - current)) { [weak self] in
            await self?.woken(at: at)
        }
    }

    /**
     A fired wake is spent before it flushes, told rather than inferred from the clock: the sleep runs
     on a monotonic clock and `now` is the wall clock, so a wake can fire a moment before `now`
     reaches the time it was armed for — and one that still looked asleep would refuse to arm the
     next, leaving a retry to the thirty-second tick.
     */
    private func woken(at: Int64) async {
        if wakeAt == at { wakeAt = 0 }
        await flush()
    }
}

/// A wake the uploader has armed, which it cancels when it arms an earlier one.
protocol UploadWake: Sendable {
    func cancel()
}

/**
 Where the uploader's one wake sleeps.

 A seam for one reason: the trigger scenarios need a debounce and a retry to fall due in the order
 the clock says, and a `Task.sleep` answers to the real clock and nothing else. On a device it is
 `TaskWakes`; the scenarios hand in a clock they move by hand.
 */
protocol UploadWakes: Sendable {
    func arm(after milliseconds: Int64, _ fire: @escaping @Sendable () async -> Void) -> any UploadWake
}

/// A `Task` asleep until the wake is due.
struct TaskWakes: UploadWakes {
    func arm(after milliseconds: Int64, _ fire: @escaping @Sendable () async -> Void) -> any UploadWake {
        TaskWake(task: Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
            guard !Task.isCancelled else { return }
            await fire()
        })
    }
}

private struct TaskWake: UploadWake {
    let task: Task<Void, Never>
    func cancel() { task.cancel() }
}

/// `random(0, min(cap, base * 2^attempt))`, in whole milliseconds.
func jitterMs(attempt: Int, random: Double) -> Int64 {
    let ceilingMs = min(
        TreebarsConstants.backoffCap,
        TreebarsConstants.backoffBase * pow(2, Double(min(attempt, 30)))
    ) * 1000
    return Int64((random * ceilingMs).rounded(.down))
}

private let imfFixdate = try! NSRegularExpression(
    pattern: "^(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun), ([0-9]{2}) ([A-Z][a-z]{2}) ([0-9]{4}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) GMT$"
)
private let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

/**
 How long a `Retry-After` asks for, in milliseconds from `now`, or nil when it says nothing usable.
 Zero or negative when a date has already passed.

 Delta-seconds or an IMF-fixdate, and nothing looser, computed by hand rather than through a
 `DateFormatter` — whose leniency and calendar are settings a host app's locale can reach. A header
 one SDK honoured and another ignored would make three policies of one. A value this refuses falls
 back to jitter, which is never faster than the policy.
 */
func retryAfterDelayMs(_ header: String?, now: Int64) -> Int64? {
    guard let value = header?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    if value.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) {
        // Any number past an hour is capped anyway; the clamp only keeps the arithmetic finite.
        return Int64(min((Double(value) ?? .infinity) * 1000, 1e15))
    }

    let range = NSRange(value.startIndex..., in: value)
    guard let match = imfFixdate.firstMatch(in: value, range: range), match.numberOfRanges == 7 else { return nil }
    func field(_ index: Int) -> String? {
        Range(match.range(at: index), in: value).map { String(value[$0]) }
    }
    guard let day = field(1).flatMap(Int.init),
          let monthIndex = field(2).flatMap(months.firstIndex(of:)),
          let year = field(3).flatMap(Int.init),
          let hour = field(4).flatMap(Int.init),
          let minute = field(5).flatMap(Int.init),
          let second = field(6).flatMap(Int.init),
          (1...31).contains(day), hour <= 23, minute <= 59, second <= 60
    else { return nil }

    let days = daysFromCivil(year: Int64(year), month: Int64(monthIndex + 1), day: Int64(day))
    let at = days * 86_400_000 + ((Int64(hour) * 60 + Int64(minute)) * 60 + Int64(second)) * 1000
    return at - now
}

/// Days since 1970-01-01 for a proleptic Gregorian date, month 1-12 (Howard Hinnant's algorithm).
private func daysFromCivil(year: Int64, month: Int64, day: Int64) -> Int64 {
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yearOfEra = y - era * 400
    let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
}
