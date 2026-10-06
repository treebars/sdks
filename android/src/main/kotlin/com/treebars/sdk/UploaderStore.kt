package com.treebars.sdk

import com.treebars.sdk.generated.TreebarsConstants

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * A batch that has been sealed and not yet acknowledged.
 *
 * It keeps its id, its events and its `sent_at` for as long as it exists, across retries and
 * across process death, and that is the whole point of it: the id is what lets the server
 * recognise a resend of something it already has, and it only can if the resend is the same
 * batch rather than the same events under a new name.
 */
internal data class PendingBatch(
    val batchId: String,
    /** When it was sealed. Not refreshed per attempt, or a retry would not be the same batch. */
    val sentAt: String,
    val events: List<JSONObject>,
) {
    val eventIds: Set<String> get() = events.map { it.optString("event_id") }.toSet()

    /** The upload body, and the stored form: they are the same object by design. */
    fun toJson(): JSONObject = JSONObject()
        .put("batch_id", batchId)
        .put("sent_at", sentAt)
        .put("events", JSONArray(events))

    companion object {
        fun fromJson(json: JSONObject): PendingBatch? {
            val batchId = json.optString("batch_id").takeIf { it.isNotEmpty() } ?: return null
            val sentAt = json.optString("sent_at").takeIf { it.isNotEmpty() } ?: return null
            val array = json.optJSONArray("events") ?: return null
            val events = (0 until array.length()).mapNotNull { array.optJSONObject(it) }
            return PendingBatch(batchId, sentAt, events)
        }
    }
}

/**
 * Everything the upload policy has to remember past this process.
 *
 * Immutable, and replaced whole: the flush writes it under its own lock, and [EventUploader]'s
 * pending count reads it from whatever thread asks, so a reader either sees the state before a
 * change or after it and never a list halfway through one.
 */
internal data class UploaderState(
    /** The head is the batch in flight; the halves of a split wait behind it in order. */
    val pending: List<PendingBatch> = emptyList(),
    /** Consecutive retryable failures. The jitter ceiling doubles with each. */
    val attempt: Int = 0,
    /** Epoch millis before which nothing is sent. Zero is no gate. */
    val nextAllowedAt: Long = 0,
    /** Epoch millis before which [authKey] is not tried again. Zero is no cooldown. */
    val authBlockedUntil: Long = 0,
    /** The write key that was refused. A different key is not held to its cooldown. */
    val authKey: String? = null,
    /**
     * The spacing the last accepted upload named, in milliseconds, already held to the bounds a
     * device accepts. Null before any upload has named one.
     *
     * Kept here, with the rest of what an upload's answer leaves behind, so the next launch keeps
     * the pace this one was told rather than starting again from the default — and so it is dropped
     * with everything else here when the write key changes, since it was said about that key.
     */
    val spacingMs: Long? = null,
) {
    val pendingEventIds: Set<String> get() = pending.flatMapTo(mutableSetOf()) { it.eventIds }

    fun toJson(): JSONObject = JSONObject()
        .put("pending", JSONArray(pending.map { it.toJson() }))
        .put("attempt", attempt)
        .put("next_allowed_at", nextAllowedAt)
        .put("auth_blocked_until", authBlockedUntil)
        .put("auth_key", authKey ?: JSONObject.NULL)
        .put("flush_spacing_ms", spacingMs ?: JSONObject.NULL)

    companion object {
        fun fromJson(json: JSONObject): UploaderState {
            val array = json.optJSONArray("pending") ?: JSONArray()
            return UploaderState(
                pending = (0 until array.length()).mapNotNull { index ->
                    array.optJSONObject(index)?.let(PendingBatch::fromJson)
                },
                attempt = json.optInt("attempt", 0),
                nextAllowedAt = json.optLong("next_allowed_at", 0),
                authBlockedUntil = json.optLong("auth_blocked_until", 0),
                authKey = if (json.isNull("auth_key")) null else json.optString("auth_key"),
                // Checked again on the way out of storage, as it was off the wire: a file is not trusted either.
                spacingMs = namedSpacingMs(json.opt("flush_spacing_ms")?.toString()),
            )
        }
    }
}

/**
 * The uploader's file, beside the queue's and never inside it.
 *
 * Its own file because the queue's shape is what every install in the field already holds, and
 * a changed shape there would read as corrupt and be deleted on the first launch of the upgrade.
 * Written the way the queue is — a temp file renamed over the live one — so a kill mid-write
 * leaves the previous state rather than half of this one.
 */
internal class UploaderStore(directory: File, filename: String = TreebarsConstants.UPLOADER_FILE) {

    private val file = File(directory, filename)

    fun load(): UploaderState {
        if (!file.exists()) return UploaderState()
        return runCatching { UploaderState.fromJson(JSONObject(file.readText())) }
            .getOrElse { UploaderState() }
    }

    /** False when the write did not land, which the uploader must know before it empties the queue. */
    fun save(state: UploaderState): Boolean = runCatching {
        val temp = File(file.parentFile, "${file.name}.tmp")
        temp.writeText(state.toJson().toString())
        check(temp.renameTo(file)) { "rename over ${file.name} failed" }
    }.onFailure {
        TreebarsLogger.log("Upload state could not be written: ${it.message}")
    }.isSuccess
}
