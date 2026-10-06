import Foundation

/**
 The wait before this device's description is put to the hash gate again: a launch, a return to the
 foreground, or a change to how in-app messages are drawn starts it, and when it ends the description
 is reported if it differs from the last one reported.

 **The wait is what makes one launch one answer.** An app says how its messages are drawn a moment
 after it starts this SDK — `disableInApps()` on the line below `initialize`, a renderer registered
 when the first screen is built, a wrapper attaching its renderer in its next call — and a
 description hashed before then would say `sdk`, be corrected when the app's own answer arrived, and
 say `sdk` again on the next launch: two reports from every launch, for an app that never changed.
 Asked only at the end of the wait, the gate sees what the app settled on, and a renderer detached
 and attached again inside it — a screen rebuilt, a host remounting — is no change at all.

 **And only with the app in front.** What draws a message is a question about an app somebody is
 looking at. A host that takes its renderer away as its screen goes would otherwise be described as
 `sdk` each time the app was left and `app` each time it came back. A wait that ends with the app
 not active reports nothing and is owed: `cameToFront()` starts it again.

 Apart from `Treebars` so the rule can be run on its own, with a wait a test can sit through.
 */
final class ContextSettle {
    private let lock = NSLock()
    private var waiting: Task<Void, Never>?
    /// A wait that ended with the app not in front, owed to the next time it is.
    private var owed = false
    /// How long a description stands before it is reported. Replaceable for a test.
    var wait: TimeInterval
    private let inFront: () async -> Bool
    private let report: () async -> Void

    init(
        wait: TimeInterval = TreebarsConstants.contextSettle,
        inFront: @escaping () async -> Bool,
        report: @escaping () async -> Void
    ) {
        self.wait = wait
        self.inFront = inFront
        self.report = report
    }

    /// Starts the wait, from now: one already running is replaced, so the description is reported
    /// once it has stood for the whole of it.
    func start() {
        let nanoseconds = UInt64(max(0, wait) * 1_000_000_000)
        let next = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self?.ended()
        }
        replace(with: next)
    }

    /// The app became active: a wait that ended while it was not is started again.
    func cameToFront() {
        if takeOwed() { start() }
    }

    /// Stops the wait and forgets one that was owed: for a device being forgotten.
    func stop() {
        replace(with: nil)
    }

    private func ended() async {
        guard await inFront() else {
            // Unless a newer wait replaced this one while the app was being asked: that one answers.
            if !Task.isCancelled { setOwed() }
            return
        }
        guard !Task.isCancelled else { return }
        await report()
    }

    private func replace(with next: Task<Void, Never>?) {
        lock.lock()
        defer { lock.unlock() }
        waiting?.cancel()
        waiting = next
        owed = false
    }

    private func setOwed() {
        lock.lock()
        defer { lock.unlock() }
        owed = true
    }

    private func takeOwed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        defer { owed = false }
        return owed
    }
}
