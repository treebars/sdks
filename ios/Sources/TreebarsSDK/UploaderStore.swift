import Foundation

/**
 A batch that has been sealed and not yet acknowledged.

 It keeps its id, its events and its `sent_at` for as long as it exists, across retries and across
 process death, and that is the whole point of it: the id is what lets the server recognise a
 resend of something it already has, and it only can if the resend is the same batch rather than
 the same events under a new name.
 */
struct PendingBatch {
    let batchId: String
    /// When it was sealed. Not refreshed per attempt, or a retry would not be the same batch.
    let sentAt: String
    let events: [[String: Any]]

    var eventIds: Set<String> { Set(events.compactMap { $0["event_id"] as? String }) }

    /// The upload body, and the stored form: they are the same object by design.
    var json: [String: Any] { ["batch_id": batchId, "sent_at": sentAt, "events": events] }

    init(batchId: String, sentAt: String, events: [[String: Any]]) {
        self.batchId = batchId
        self.sentAt = sentAt
        self.events = events
    }

    init?(json: [String: Any]) {
        guard let batchId = json["batch_id"] as? String, !batchId.isEmpty,
              let sentAt = json["sent_at"] as? String, !sentAt.isEmpty,
              let events = json["events"] as? [[String: Any]]
        else { return nil }
        self.init(batchId: batchId, sentAt: sentAt, events: events)
    }
}

/// Everything the upload policy has to remember past this process.
struct UploaderState {
    /// The head is the batch in flight; the halves of a split wait behind it in order.
    var pending: [PendingBatch] = []
    /// Consecutive retryable failures. The jitter ceiling doubles with each.
    var attempt = 0
    /// Epoch milliseconds before which nothing is sent. Zero is no gate.
    var nextAllowedAt: Int64 = 0
    /// Epoch milliseconds before which `authKey` is not tried again. Zero is no cooldown.
    var authBlockedUntil: Int64 = 0
    /// The write key that was refused. A different key is not held to its cooldown.
    var authKey: String?

    var pendingEventIds: Set<String> { pending.reduce(into: Set<String>()) { $0.formUnion($1.eventIds) } }

    var json: [String: Any] {
        [
            "pending": pending.map(\.json),
            "attempt": attempt,
            "next_allowed_at": nextAllowedAt,
            "auth_blocked_until": authBlockedUntil,
            "auth_key": authKey ?? NSNull(),
        ]
    }

    init() {}

    init(json: [String: Any]) {
        pending = (json["pending"] as? [[String: Any]] ?? []).compactMap(PendingBatch.init(json:))
        attempt = (json["attempt"] as? NSNumber)?.intValue ?? 0
        nextAllowedAt = (json["next_allowed_at"] as? NSNumber)?.int64Value ?? 0
        authBlockedUntil = (json["auth_blocked_until"] as? NSNumber)?.int64Value ?? 0
        authKey = json["auth_key"] as? String
    }
}

/**
 The uploader's file, beside the queue's in Application Support and never inside it.

 Its own file because the queue's shape is what every install in the field already holds, and a
 changed shape there would fail to decode and read as an empty queue on the first launch of the
 upgrade. Written `.atomic`, like the queue, so a kill mid-write leaves the previous state rather
 than half of this one.

 Isolated by filename rather than directory, as `EventQueue` is, so a test can hold its own.
 */
final class UploaderStore {
    private let fileURL: URL

    init(filename: String = TreebarsConstants.uploaderFile) {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent(filename)
    }

    func load() -> UploaderState {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return UploaderState() }
        return UploaderState(json: object)
    }

    /// False when the write did not land, which the uploader must know before it empties the queue.
    @discardableResult
    func save(_ state: UploaderState) -> Bool {
        do {
            let data = try JSONSerialization.data(withJSONObject: state.json)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            TreebarsLogger.log("Upload state could not be written", error.localizedDescription)
            return false
        }
    }
}
