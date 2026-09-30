import Foundation

/**
 Which write key this install's stored data was recorded under.

 Almost everything this SDK keeps belongs to ONE project: the queue and the uploader's sealed batches,
 the session a `session_end` is owed for, the trigger list, the in-app queue and its ledger, the
 notification history, the device context last reported. Without a record of whose it is, an app
 rebuilt with another write key would send the previous session's `session_end` — closed at the next
 launch, dated to that session — and whatever the previous build had left unsent into the new
 project, where it does not belong.

 So the key is stamped beside the data, and `claim` drops the data at `initialize` when the key
 differs, before the session, the queue or the uploader is read. The queue loads lazily for exactly
 this reason (`EventQueue.events`). Dropped rather than sent under the key it was recorded with: the
 SDK holds one key, and a key that was rotated away is typically revoked, so there is nowhere left to
 send it.

 That includes rotating a key WITHIN one project, which a device cannot tell from a switch to another
 project without asking the server. What is lost there is the previous build's unsent tail and one
 `session_end` — the cheaper mistake of the two, since the other one writes into a project that never
 had the events.

 Kept, because they belong to the install or the person rather than to a project: the device id and
 its secret (a pair, so they are kept or dropped together), who is signed in and who had been, the
 opt-out, first launch and first seen, and `ever_started`. The
 device context is forgotten on purpose, so the new project hears about this device on its first
 launch rather than when the TTL runs out.

 No stamp at all is an install from before the stamp existed, or a first launch: the key is adopted
 and nothing is dropped, because there is nothing to compare against.
 */
enum WriteKeyStamp {
    static let key = "treebars.stored_under_write_key"

    /// Stamps `writeKey`, dropping what another key left first. Returns whether anything was dropped, which is
    /// the caller's cue to empty the stores it already holds in memory (in-app, notifications).
    @discardableResult
    static func claim(
        _ writeKey: String,
        defaults: UserDefaults = .standard,
        queueFilename: String = EventQueue.defaultFilename,
        uploaderFilename: String = TreebarsConstants.uploaderFile,
        triggersFilename: String = TreebarsConstants.triggersFile
    ) -> Bool {
        let stamped = defaults.string(forKey: key)
        if stamped == writeKey { return false }
        let dropped = stamped != nil
        if dropped {
            EventQueue.forget(filename: queueFilename)
            UploaderStore(filename: uploaderFilename).save(UploaderState())
            TriggerStore(filename: triggersFilename).forget()
            // The session record goes and `ever_started` stays: the install has been used.
            SessionManager.forgetRecord(in: defaults)
            DeviceInfo.forgetReportedContext(in: defaults)
        }
        defaults.set(writeKey, forKey: key)
        return dropped
    }
}
