package com.treebars.sdk

import com.treebars.sdk.generated.TreebarsConstants

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Durable event queue backed by a file in the app's private storage.
 *
 * Android kills backgrounded processes aggressively, so anything held only in memory
 * is routinely lost — and usually at the most interesting moment. Persisting means an
 * event captured just before the process dies is still delivered on the next launch.
 *
 * A [Mutex] rather than `synchronized` because every caller is a coroutine; blocking
 * a dispatcher thread here would stall unrelated work.
 */
internal class EventQueue(directory: File, filename: String = FILE_NAME) {

    private val file = File(directory, filename)
    private val mutex = Mutex()
    private val events = mutableListOf<JSONObject>()

    /**
     * Bounds disk usage for a device that stays offline for a long time. The oldest
     * events are dropped first: recent behaviour is more valuable than stale
     * behaviour, and the alternative is recording nothing once full.
     */
    private val maxEvents = TreebarsConstants.QUEUE_CAP

    init {
        load()
    }

    private fun load() {
        if (!file.exists()) return
        runCatching {
            val array = JSONArray(file.readText())
            for (i in 0 until array.length()) {
                events.add(array.getJSONObject(i))
            }
        }.onFailure {
            // A truncated file from an interrupted write is unrecoverable; starting
            // clean is better than refusing to record anything from now on.
            file.delete()
        }
    }

    private fun persist() {
        runCatching {
            val temp = File(file.parentFile, "${file.name}.tmp")
            temp.writeText(JSONArray(events).toString())
            // Write-then-rename so a kill mid-write cannot corrupt the live file.
            temp.renameTo(file)
        }
    }

    suspend fun append(event: JSONObject) = mutex.withLock {
        events.add(event)
        if (events.size > maxEvents) {
            repeat(events.size - maxEvents) { events.removeAt(0) }
        }
        persist()
    }

    suspend fun peek(count: Int): List<JSONObject> = mutex.withLock {
        events.take(count)
    }

    suspend fun remove(count: Int) = mutex.withLock {
        repeat(minOf(count, events.size)) { events.removeAt(0) }
        persist()
    }

    /**
     * Removes these events wherever they are, rather than the oldest `n`.
     *
     * By id because the uploader seals a batch with [peek] and takes it off the queue only after
     * writing it out, and [append] may run on another thread in between: at the cap every append
     * evicts from the front, which is where the batch being sealed sits. A `remove(n)` there
     * takes events that were never sent.
     */
    suspend fun removeIds(ids: Set<String>): Int = mutex.withLock {
        val before = events.size
        events.removeAll { it.optString("event_id") in ids }
        val removed = before - events.size
        if (removed > 0) persist()
        removed
    }

    suspend fun size(): Int = mutex.withLock { events.size }

    suspend fun clear() = mutex.withLock {
        events.clear()
        persist()
    }

    companion object {
        const val FILE_NAME = "treebars-queue.json"

        /**
         * The stored queue, deleted before any queue has read it — for an install that starts opted
         * out, whose earlier launch may have left events a later opt-in would otherwise send.
         */
        fun forget(directory: File) {
            File(directory, FILE_NAME).delete()
        }
    }
}
