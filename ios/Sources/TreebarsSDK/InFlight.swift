import Foundation

/**
 The events `log` has handed to a Task and not yet queued, so a `flush()` can wait for the ones logged before it.

 `log` and `flush` each start an unstructured Task, and nothing orders two Tasks: `enqueue` is a method on a class, not
 on an actor, so without this a `flush()` on the very next line could drain before the event reached the queue and
 leave it for the upload its own logging armed. Winning that race most of the time is not ordering, so `flush()` waits
 for what was logged before it. The Android SDK does the same.

 The snapshot is taken synchronously in `flush()`, after `log()` has returned and so after its Task is in here —
 that ordering is the happens-before, and the lock makes it hold across threads.
 */
final class InFlight: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// Starts `work` and remembers it until it finishes. Inserted under the lock its own removal takes, so a Task that
    /// finishes at once is still removed rather than kept.
    func run(_ work: @escaping () async -> Void) {
        let id = UUID()
        lock.lock()
        defer { lock.unlock() }
        tasks[id] = Task { [weak self] in
            await work()
            self?.finish(id)
        }
    }

    /// The Tasks started so far and not yet finished — what a flush called now has to wait for.
    func snapshot() -> [Task<Void, Never>] {
        lock.lock()
        defer { lock.unlock() }
        return Array(tasks.values)
    }

    private func finish(_ id: UUID) {
        lock.lock()
        tasks[id] = nil
        lock.unlock()
    }
}
