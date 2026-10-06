import Foundation

/// What about the device slows its uploads down, read as an upload is armed.
struct FlushConditions: Equatable, Sendable {
    /// Saving power or data: Low Power Mode, or a network in Low Data Mode.
    var constrained = false
    /// A network paid for by use: cellular, or a personal hotspot.
    var metered = false
}

/**
 What the uploader says about its uploads, to whoever paces them.

 The uploader decides what a batch is and whether one may go; when the next one is due is decided
 beside it. These are the two facts that decision needs and only the uploader holds.
 */
protocol UploadPacing: AnyObject, Sendable {
    /// An upload is going out now: the first batch of a drain, which may carry several. Said for
    /// every one — paced, a listed event's, a full batch, a retry, a flush the app asked for —
    /// because the spacing is counted from all of them.
    func uploadBegan(at now: Int64)
    /// The spacing an accepted upload named, in milliseconds.
    func spacingNamed(_ milliseconds: Int64)
    /// The upload that just ended left events waiting, with no gate closed in front of them.
    func uploadLeftBacklog()
}

/**
 When an event is uploaded. One of three implementations — the Kotlin core and the web SDK carry the
 other two — and all three run the same shared scenarios (`FlushPaceScenariosTests` here).

 An event arms one upload. It is due a debounce after the event, or at the end of the spacing since
 the last upload began, whichever is later — so an event on a quiet device is on its way a second
 after it happened, and a busy device is held to one upload per spacing. The first event arms the
 wait and later ones ride it rather than pushing it back, or a device logging an event every nine
 hundred milliseconds would never upload.

 The spacing is counted from when an upload BEGAN, and from every upload, whoever asked for it. An
 upload that begins while one is armed pushes the armed one out to the end of its own spacing: the
 upload that began has normally carried what the armed one was for, and what it left is not sent
 sooner than the spacing allows.

 A backlog needs no event to ask for it. One upload carries a bounded number of batches, so it can
 end with events still queued; when it does, and nothing is holding the device back, the next
 upload is armed a spacing after that one began. A device that logs nothing more still empties its
 queue, one upload per spacing.

 This type decides when and nothing else. What fires is an ordinary flush, so the uploader's gates
 — a `Retry-After`, a refused write key, an opt-out — decide whether a request goes, and a batch
 that is full does not wait for any of this. Nothing here reads a clock, a network or a timer of its
 own: all three are handed in, which is what lets the scenarios run it without waiting.

 A class behind a lock rather than an actor, because the uploader tells it about each batch from
 inside its own drain and must not wait on a hop to do it.
 */
final class FlushPace: UploadPacing, @unchecked Sendable {
    /// The interval the app chose at `initialize`, in milliseconds. Nil when it chose none.
    private let chosen: Int64?
    private let testKey: Bool
    private let now: @Sendable () -> Int64
    private let conditions: @Sendable () -> FlushConditions
    private let wakes: any UploadWakes

    private let lock = NSLock()
    /// What a due upload does: asks the uploader to drain. Set once the uploader exists.
    private var flush: (@Sendable () async -> Void)?
    /// The spacing the last accepted upload named. Nil until one has.
    private var named: Int64?
    private var lastBegan: Int64?
    /// When the armed upload is due. Nil when none is armed.
    private var armed: Int64?
    private var wake: (any UploadWake)?
    /// Which arming the live wake belongs to, so one that was replaced and fires anyway does nothing.
    private var armings = 0

    /// - Parameters:
    ///   - chosen: The app's own interval, in seconds, or nil when it chose none.
    ///   - testKey: Whether the write key is a test environment's.
    init(
        chosen: TimeInterval?,
        testKey: Bool,
        now: @escaping @Sendable () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) },
        conditions: @escaping @Sendable () -> FlushConditions,
        wakes: any UploadWakes = TaskWakes()
    ) {
        self.chosen = chosen.flatMap(Self.milliseconds)
        self.testKey = testKey
        self.now = now
        self.conditions = conditions
        self.wakes = wakes
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /**
     What an upload falling due does, which is ask the uploader for a flush and nothing else.

     Given after both exist rather than at `init`, because each needs the other: the uploader is
     built holding the pace it reports to. The uploader is the caller's to hold weakly — it owns the
     pace, not the other way about.
     */
    func onDue(_ flush: @escaping @Sendable () async -> Void) {
        locked { self.flush = flush }
    }

    /// When the armed upload is due, in epoch milliseconds. Nil when none is armed.
    var dueAt: Int64? { locked { armed } }

    /// An event is on the queue. Arms an upload unless one is armed already.
    func eventLogged() {
        locked {
            guard armed == nil else { return }
            let now = now()
            arm(at: Self.due(now: now, lastBegan: lastBegan) { spacingNow() }, now: now)
        }
    }

    func uploadBegan(at now: Int64) {
        locked {
            lastBegan = now
            guard let armed else { return }
            let earliest = now + spacingNow()
            if earliest > armed { arm(at: earliest, now: now) }
        }
    }

    /// Arms the next upload a spacing after the one that left the backlog began. One already armed
    /// is left where it is: `uploadBegan` has put it no earlier than that.
    func uploadLeftBacklog() {
        locked {
            guard armed == nil, let lastBegan else { return }
            let now = now()
            arm(at: max(now, min(lastBegan, now) + spacingNow()), now: now)
        }
    }

    /// Held to the bounds again, whoever read it: the stored copy a launch starts from is a file.
    func spacingNamed(_ milliseconds: Int64) {
        locked { named = Self.bounded(milliseconds) }
    }

    /// Called under the lock. The conditions are read here, as an upload is armed, and not kept.
    private func spacingNow() -> Int64 {
        Self.spacing(chosen: chosen, testKey: testKey, named: named, in: conditions())
    }

    /// Called under the lock.
    private func arm(at: Int64, now: Int64) {
        wake?.cancel()
        armings += 1
        let arming = armings
        armed = at
        wake = wakes.arm(after: max(0, at - now)) { [weak self] in
            await self?.fired(arming)
        }
    }

    /// Spent before it flushes, so the upload it starts finds nothing armed to push out.
    private func fired(_ arming: Int) async {
        let flush = locked { () -> (@Sendable () async -> Void)? in
            guard arming == armings, armed != nil else { return nil }
            armed = nil
            wake = nil
            return self.flush
        }
        await flush?()
    }

    // MARK: - The arithmetic

    /// Whether a write key is a test environment's. The prefix is the one thing about a key that is
    /// public by shape, and it is all this reads of it.
    static func isTestKey(_ writeKey: String) -> Bool { writeKey.hasPrefix("pk_test_") }

    private static let debounceMs = Int64(TreebarsConstants.flushDebounce * 1000)

    /**
     How far apart two uploads are kept.

     A device saving power or data keeps one fixed, wide spacing whatever else is true: the person
     asked the whole phone to do less, and that outranks an app's choice, a test key and the server
     alike.
     Otherwise the app's own interval is the spacing, never tighter than the debounce. Otherwise a
     test key keeps almost none — somebody is watching a screen for the event they just caused.
     Otherwise it is what the last accepted upload named, or the default before any has, and never
     under the metered floor on a network paid for by use: each upload wakes the radio, and it stays
     awake for seconds afterwards.
     */
    static func spacing(chosen: Int64?, testKey: Bool, named: Int64?, in conditions: FlushConditions) -> Int64 {
        if conditions.constrained { return Int64(TreebarsConstants.defaultFlushInterval * 1000) }
        if let chosen { return max(chosen, debounceMs) }
        if testKey { return Int64(TreebarsConstants.flushSpacingTest * 1000) }
        let asked = named ?? Int64(TreebarsConstants.flushSpacing * 1000)
        return conditions.metered ? max(asked, Int64(TreebarsConstants.flushSpacingMetered * 1000)) : asked
    }

    /// When an upload armed at `now` is due. `spacing` is asked only when there is an upload to space from.
    static func due(now: Int64, lastBegan: Int64?, spacing: () -> Int64) -> Int64 {
        let debounced = now + debounceMs
        guard let lastBegan else { return debounced }
        // An upload that began after `now` is a clock that moved backwards since; it began no later than now.
        return max(debounced, min(lastBegan, now) + spacing())
    }

    /**
     The spacing a response named, in milliseconds and within the bounds a device accepts, or nil
     when it named none this can read.

     Whole milliseconds and nothing looser. A value outside the bounds is taken as the nearest bound
     rather than ignored, so a server asking for more than a device will give still gets the most it
     will give; a value that is not a number changes nothing, and the spacing in force stays.
     */
    static func spacing(fromHeader header: String?) -> Int64? {
        guard let value = header?.trimmingCharacters(in: .whitespaces), !value.isEmpty,
              value.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) })
        else { return nil }
        // Digits past what an `Int64` holds are far past the upper bound either way.
        return bounded(Int64(value) ?? .max)
    }

    /// The least and the most a device accepts as the server's word.
    private static func bounded(_ milliseconds: Int64) -> Int64 {
        let least = Int64(TreebarsConstants.flushSpacingMin * 1000)
        let most = Int64(TreebarsConstants.flushSpacingMax * 1000)
        return min(max(milliseconds, least), most)
    }

    /// Seconds as whole milliseconds. Nil for a value that is not a number; one too large to count is
    /// held to a span no app outlives, so the sum of it and a moment cannot overflow.
    private static func milliseconds(_ seconds: TimeInterval) -> Int64? {
        guard !seconds.isNaN else { return nil }
        return Int64((min(max(seconds, 0), 1e12) * 1000).rounded())
    }
}
