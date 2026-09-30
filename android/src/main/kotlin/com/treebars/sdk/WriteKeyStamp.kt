package com.treebars.sdk

import android.content.SharedPreferences
import com.treebars.sdk.generated.TreebarsConstants
import java.io.File

/**
 * Which write key this install's stored data was recorded under.
 *
 * Almost everything this SDK keeps belongs to ONE project: the queue and the uploader's sealed
 * batches, the session a `session_end` is owed for, the trigger list, the in-app queue and its
 * ledger, the notification history, the device context last reported. Without a record of whose
 * it is, an app rebuilt with another write key would send the previous session's `session_end` —
 * closed at the next launch, dated to that session — and whatever the previous build had left
 * unsent into the NEW project, and the previous project would never receive them.
 *
 * So the key is stamped beside the data, and [claim] drops the data at `initialize` when the key
 * differs, before the session manager, the queue, the uploader or the in-app store reads any of
 * it. Dropped rather than sent under the key it was recorded with: the SDK holds one key, and a key
 * that was rotated away is typically revoked, so there is nowhere left to send it.
 *
 * That includes rotating a key WITHIN one project, which a device cannot tell from a switch to
 * another project without asking the server. What is lost there is the previous build's unsent
 * tail and one `session_end` — the cheaper mistake of the two, since the other one writes into a
 * project that never had the events.
 *
 * Kept, because they belong to the install or the person rather than to a project: the device id
 * and its secret (always kept or dropped as a pair), who is signed in and who had been, the
 * opt-out, first-launch and first-seen, and `session_ever_started`. The device context is
 * forgotten on purpose, so the new project hears about this device on its first launch rather
 * than when the TTL runs out.
 *
 * No stamp at all is a first launch, or an install last run by an SDK version that did not stamp:
 * the key is adopted and nothing is dropped, because there is nothing to compare against.
 */
internal object WriteKeyStamp {
    const val KEY = "stored_under_write_key"

    /**
     * Stamps [writeKey], dropping what another key left first. Returns whether anything was
     * dropped, which is the caller's cue to empty the stores it builds after this (in-app,
     * notifications) — they read what they hold when they are built.
     */
    fun claim(prefs: SharedPreferences, filesDir: File, writeKey: String): Boolean {
        val stamped = runCatching { prefs.getString(KEY, null) }.getOrNull()
        if (stamped == writeKey) return false
        val dropped = stamped != null
        if (dropped) {
            EventQueue.forget(filesDir)
            UploaderStore(filesDir).save(UploaderState())
            File(filesDir, TreebarsConstants.TRIGGERS_FILE).delete()
            // The session record goes and `session_ever_started` stays: the install has been used.
            SessionManager(prefs).reset()
        }
        val editor = prefs.edit().putString(KEY, writeKey)
        if (dropped) editor.remove("device_context_hash")
        editor.commit()
        return dropped
    }
}
