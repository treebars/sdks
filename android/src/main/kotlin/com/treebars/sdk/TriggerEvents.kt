package com.treebars.sdk

import com.treebars.sdk.generated.TreebarsConstants

import kotlinx.coroutines.CancellationException
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

/**
 * The environment's trigger list, as the ingest endpoint hands it over: a version and the event names on it.
 *
 * The version is opaque. Equal lists have equal versions, and that is all a device needs to know
 * about it — it is compared with the one every accepted upload carries, never parsed.
 */
internal data class TriggerList(val version: String, val names: List<String>) {

    fun toJson(): JSONObject = JSONObject().put("version", version).put("names", JSONArray(names))

    companion object {
        /** Checked rather than trusted, off the wire and out of storage alike. Null for anything else. */
        fun fromJson(json: JSONObject?): TriggerList? {
            if (json == null) return null
            // `opt` rather than `optString`, which reads a JSON null as the four-letter string "null".
            val version = (json.opt("version") as? String)?.takeIf { it.isNotEmpty() } ?: return null
            val array = json.opt("names") as? JSONArray ?: return null
            return TriggerList(version, (0 until array.length()).mapNotNull { array.opt(it) as? String })
        }
    }
}

/**
 * The list's file, beside the uploader's. Written the way the queue is — a temp file renamed over
 * the live one — so a kill mid-write leaves the previous list rather than half of this one.
 */
internal class TriggerStore(directory: File, filename: String = TreebarsConstants.TRIGGERS_FILE) {

    private val file = File(directory, filename)

    fun load(): TriggerList? {
        if (!file.exists()) return null
        return runCatching { TriggerList.fromJson(JSONObject(file.readText())) }.getOrNull()
    }

    fun save(list: TriggerList): Boolean = runCatching {
        val temp = File(file.parentFile, "${file.name}.tmp")
        temp.writeText(list.toJson().toString())
        check(temp.renameTo(file)) { "rename over ${file.name} failed" }
    }.onFailure {
        TreebarsLogger.log("Trigger list could not be written: ${it.message}")
    }.isSuccess
}

/**
 * The environment's trigger list: the events this device sends within a second of logging them,
 * rather than at the thirty-second tick. One of three implementations — `TriggerEvents.swift` and
 * `sdks/web/src/triggers.ts` are the others — and all three run the same shared scenarios.
 *
 * The server decides what is on it — the events that start or advance a live campaign or journey —
 * and hands it over in the in-app sync. Every accepted upload carries the list's version, so the
 * device learns its copy is stale from an answer it was already waiting for and only then fetches
 * the list — alone, with `triggers_only=1`, rather than asking for the whole sync again.
 *
 * Persisted so a relaunch flushes a listed event promptly before its own sync has returned. The
 * list belongs to the write key's environment rather than to whoever is signed in, so `reset()`
 * leaves it alone; a build that switches keys carries the other environment's list only until its
 * first upload's version says otherwise.
 */
internal class TriggerEvents(
    private val store: TriggerStore,
    /** Asks the ingest endpoint for the list alone. Null when it could not be had. */
    private val fetch: suspend () -> TriggerList?,
) {

    /** The list and its names as a set, replaced together so a reader never sees one without the other. */
    private class Held(val list: TriggerList) {
        val names: Set<String> = list.names.toSet()
    }

    @Volatile
    private var held: Held? = store.load()?.let(::Held)

    /**
     * Syncs in flight, the session's whole sync included. While one is out, a stale version on an
     * upload does not start another: the answer on its way carries the list, and a cold start — whose
     * first flush and first sync leave together — would otherwise fetch it twice.
     */
    private val syncing = AtomicInteger(0)

    val version: String? get() = held?.list?.version

    fun contains(eventName: String): Boolean = held?.names?.contains(eventName) == true

    /** Called before a sync that may carry the list is sent. */
    fun beginSync() {
        syncing.incrementAndGet()
    }

    /**
     * Called when it has answered, with whatever its `trigger_events` held — or null, when it failed
     * or carried none, which keeps the list this device already has.
     */
    fun endSync(next: TriggerList?) {
        syncing.updateAndGet { maxOf(0, it - 1) }
        if (next == null) return
        held = Held(next)
        store.save(next)
    }

    /** Fetches the list alone, unless a sync that will carry it is already out. Never throws. */
    suspend fun refresh() {
        if (!syncing.compareAndSet(0, 1)) return
        val next = try {
            fetch()
        } catch (cancelled: CancellationException) {
            endSync(null)
            throw cancelled
        } catch (error: Exception) {
            TreebarsLogger.log("Trigger list refresh failed: ${error.message}")
            null
        }
        endSync(next)
    }

    /**
     * What an upload's answer said the current version is. A different one refreshes the list; the
     * same one, or none — a refusal carries none — changes nothing.
     */
    suspend fun observe(version: String?) {
        if (version == null || version == this.version) return
        refresh()
    }
}
