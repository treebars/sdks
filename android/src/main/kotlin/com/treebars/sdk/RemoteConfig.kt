package com.treebars.sdk

import com.treebars.sdk.generated.TreebarsConstants

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.TreeMap
import java.util.concurrent.CopyOnWriteArraySet

/**
 * One remote config value as the ingest endpoint hands it over: the key, the kind of value, and the value.
 *
 * [value] is whatever the JSON held — a `Boolean`, a `Number`, a `String`, or for a `json` variable a
 * `JSONObject`, a `JSONArray` or any of those — and is only ever answered to a read of its own [type].
 */
internal class ConfigEntry(
    val key: String,
    val type: String,
    val value: Any,
    /** The answer may differ for a different account, or with nobody signed in. */
    val userDependent: Boolean,
    /** Set when the value is an experiment's variant: its id, key, variant and unit, as they arrived. */
    val experiment: JSONObject?,
) {
    fun toJson(): JSONObject = JSONObject().put("key", key).put("type", type).put("value", value).also { json ->
        if (userDependent) json.put("user_dependent", true)
        experiment?.let { json.put("experiment", it) }
    }

    /** Whether a read of this and a read of [other] would answer alike. */
    fun sameAs(other: ConfigEntry?): Boolean =
        other != null && type == other.type && userDependent == other.userDependent && canonical(value) == canonical(other.value)

    companion object {
        private val TYPES = setOf("boolean", "string", "number", "json")

        /** Checked rather than trusted, off the wire and out of storage alike. Null for anything that is not one. */
        fun fromJson(json: JSONObject?): ConfigEntry? {
            if (json == null) return null
            // `opt` rather than `optString`, which reads a JSON null as the four-letter string "null".
            val key = (json.opt("key") as? String)?.takeIf { it.isNotEmpty() } ?: return null
            val type = (json.opt("type") as? String)?.takeIf { it in TYPES } ?: return null
            val value = json.opt("value") ?: return null
            val experiment = (json.opt("experiment") as? JSONObject)?.takeIf {
                it.opt("id") is String && it.opt("key") is String && it.opt("variant") is String
            }
            return ConfigEntry(key, type, value, json.opt("user_dependent") == true, experiment)
        }

        /** A value as text two equal values share: `2` and `2.0` are one number however each was parsed. */
        fun canonical(value: Any): String = if (value is Number) value.toDouble().toString() else value.toString()

        /** Whether [value] is a value of [type]. A value is never bent into another kind. */
        fun fits(value: Any?, type: String): Boolean = when (type) {
            "boolean" -> value is Boolean
            "string" -> value is String
            "number" -> value is Number && value.toDouble().let { !it.isNaN() && !it.isInfinite() }
            else -> value != null
        }
    }
}

/** A read answered an experiment's variant: what is reported about it. */
internal class ConfigExposure(
    val experimentId: String,
    val experimentKey: String,
    val variant: String,
    /** The key that was read. */
    val variable: String,
    /** What the variant was drawn by: `device` or `user`. */
    val unit: String,
)

/** Who is asking, as an ask carries it. */
internal class ConfigAsk(val userId: String?, val attributes: Map<String, Any>)

/** What an ask came back with: the answer's body, or how it failed. */
internal sealed class ConfigAnswer {
    class Answered(val body: JSONObject?) : ConfigAnswer()
    class Failed(val status: Int? = null, val retryAfter: String? = null) : ConfigAnswer()
}

/**
 * Remote config's file, beside the uploader's: the answers held and the wait a refusal set, what each key read
 * as in the running session, and what the app said about the install. Written the way the queue is — a temp
 * file renamed over the live one — so a kill mid-write leaves the previous state rather than half of this one.
 */
internal class ConfigStore(directory: File, filename: String = TreebarsConstants.CONFIG_FILE) {

    private val file = File(directory, filename)

    fun load(): JSONObject? {
        if (!file.exists()) return null
        return runCatching { JSONObject(file.readText()) }.getOrNull()
    }

    fun save(state: JSONObject): Boolean = runCatching {
        val temp = File(file.parentFile, "${file.name}.tmp")
        temp.writeText(state.toString())
        check(temp.renameTo(file)) { "rename over ${file.name} failed" }
    }.onFailure {
        TreebarsLogger.log("Remote config could not be written: ${it.message}")
    }.isSuccess

    fun clear() {
        runCatching { file.delete() }
    }
}

/**
 * Remote config: values an app reads by key and Treebars decides. One of three implementations —
 * `RemoteConfig.swift` and the web SDK's `config.ts` are the others — and all three run the same shared
 * scenarios (`config-scenarios.json`).
 *
 * Treebars works out this install's answers and hands them over whole — one value for each variable, and
 * nothing about why. This holds them, answers reads from them, and decides when to ask again.
 *
 * **A read never waits and never fails.** It answers from what this install holds, and nothing — for the
 * caller to put its fallback in place of — when it holds nothing for that key or holds another kind.
 *
 * **A key keeps its answer for the session.** The first read of a key in a session fixes what that key reads
 * as until the session ends, "not set" included, so a screen never changes under somebody because a newer
 * answer arrived half-way through. A key not read yet takes the newest answer held; a new session, or
 * [activate], forgets what was read.
 *
 * **It asks only when there is something to learn.** Every accepted upload names the current version, so this
 * learns its copy is stale from an answer it was already waiting for. With nothing held and no version named,
 * nothing is asked at all: an app whose project has no variables never makes a config request. It also asks
 * when who is asking changes in a way an answer may depend on — an account signs in or out, the app sets
 * different attributes, the device describes itself differently than it did — and whenever the app says to.
 *
 * **An account's answers do not outlive the account.** At sign-out, and when a different account signs in, the
 * answers that depended on the last one are dropped at once, before the next ones arrive.
 *
 * **A variant is reported when a read answers it, not when it arrives.** A value that is an experiment's variant
 * says so, and the first read to answer it reports that this install was shown that variant — at most once a
 * day for the same variant, and at once for a different one. A value held and never read reports nothing: no
 * screen used it. Nor does a read answered by an override, a read as another kind, or a listing of every value.
 *
 * Every field is guarded by one lock: reads come from whichever thread the app reads on, and an answer
 * arrives on another. Listeners are called outside it.
 */
internal class RemoteConfig(
    private val store: ConfigStore?,
    /** Asks the ingest endpoint for this install's answers. */
    private val fetch: suspend (ConfigAsk) -> ConfigAnswer,
    /** Starts an ask nobody is waiting on: after an upload's answer, a sign-in, a change of attributes. */
    private val launch: (suspend () -> Unit) -> Unit,
    /** Writes the state somewhere a read on the main thread does not wait for. */
    private val persist: (ConfigStore, JSONObject) -> Unit = { target, state -> target.save(state) },
    private val clock: () -> Long = System::currentTimeMillis,
    /** Told, outside the lock, when a read answers an experiment's variant that is due to be reported. */
    private val expose: (ConfigExposure) -> Unit = {},
) {

    /** The answers held, and how they were asked for. */
    private class Held(
        val version: String,
        var values: List<ConfigEntry>,
        /** How the device described itself when these were asked for. */
        val context: String,
        /** Who is asking has changed since: these stand until the next answer, and another ask is owed. */
        var stale: Boolean,
    ) {
        fun entry(key: String): ConfigEntry? = values.firstOrNull { it.key == key }

        fun toJson(): JSONObject = JSONObject()
            .put("version", version)
            .put("values", JSONArray(values.map { it.toJson() }))
            .put("context", context)
            .put("stale", stale)
    }

    private class Asking(val ask: ConfigAsk, val context: String, val done: CompletableDeferred<Boolean> = CompletableDeferred())

    private val lock = Any()
    private var held: Held? = null
    /** No ask before this moment, in epoch milliseconds: a refusal's wait, kept across launches. */
    private var notBefore = 0L
    /** What this install was last reported as shown, by experiment id: the variant, and when. */
    private val exposed = HashMap<String, Pair<String, Long>>()
    private var sessionId = ""
    /** What each key read as in this session. A key mapped to null read as "not set". */
    private val seen = LinkedHashMap<String, ConfigEntry?>()
    private var attributes: Map<String, Any> = emptyMap()
    private val overrides = HashMap<String, Any>()
    private val listeners = CopyOnWriteArraySet<() -> Unit>()
    private var userId: String? = null
    private var context = ""
    /** The ask that is out, if one is. */
    private var asking: Asking? = null
    /** Who is asking changed while an ask was out: one more follows it. */
    private var again = false
    /** The next answer is for a different account than the last: what depended on the account is read afresh from it. */
    private var reopen = false

    init {
        store?.load()?.let { stored ->
            held = readHeld(stored.opt("set") as? JSONObject)
            notBefore = (stored.opt("not_before") as? Number)?.toLong() ?: 0L
            (stored.opt("session") as? JSONObject)?.let { session ->
                val id = session.opt("id") as? String
                val read = session.opt("seen") as? JSONObject
                if (id != null && read != null) {
                    sessionId = id
                    for (key in read.keys()) seen[key] = ConfigEntry.fromJson(read.opt(key) as? JSONObject)
                }
            }
            attributes = readAttributes(stored.opt("attributes") as? JSONObject)
            (stored.opt("exposed") as? JSONObject)?.let { reported ->
                for (id in reported.keys()) {
                    val one = reported.opt(id) as? JSONObject ?: continue
                    val variant = one.opt("variant") as? String ?: continue
                    val at = (one.opt("at") as? Number)?.toLong() ?: continue
                    exposed[id] = variant to at
                }
            }
        }
    }

    /** The version held, or null when nothing is. */
    val version: String? get() = synchronized(lock) { held?.version }

    /** Whether there is something to ask for that no upload's answer will prompt: nothing held, or an ask still owed. */
    val wanting: Boolean get() = synchronized(lock) { held?.stale ?: true }

    /**
     * Called once the SDK knows who is signed in and how the device describes itself ([context]: any string
     * that changes when that description does), and its session where it already knows one. Asks when the
     * answers held were asked for by a device that described itself differently, or an ask is owed from before.
     */
    fun start(sessionId: String?, userId: String?, context: String) {
        val owed = synchronized(lock) {
            this.userId = userId
            this.context = context
            held?.let { if (it.values.isNotEmpty() && it.context != context) it.stale = true }
            held?.stale == true
        }
        // Where the session is not known yet, what was read stands until `sessionStarted` says which one this is.
        if (sessionId != null) sessionStarted(sessionId)
        if (owed) begin()
    }

    /** A session began, or is the one already running. A different one forgets what was read. */
    fun sessionStarted(id: String) {
        val moved = synchronized(lock) {
            if (id == sessionId) return
            val moved = wouldChange()
            sessionId = id
            seen.clear()
            save()
            moved
        }
        if (moved) announce()
    }

    /**
     * One key, as the kind asked for: the value, or null for the caller to answer its fallback — when nothing is
     * held for the key, or what is held is another kind. The first read of a key in a session fixes it.
     */
    fun read(key: String, type: String): Any? {
        var due: ConfigExposure? = null
        val value = synchronized(lock) {
            if (overrides.containsKey(key)) return@synchronized overrides[key].takeIf { ConfigEntry.fits(it, type) }
            val entry = entry(key)
            if (entry == null || entry.type != type || !ConfigEntry.fits(entry.value, type)) return@synchronized null
            due = exposureDue(entry)
            entry.value
        }
        // Outside the lock: what hears it records an event, and a read must not hold the lock for that.
        due?.let { exposure ->
            try {
                expose(exposure)
            } catch (error: Exception) {
                TreebarsLogger.log("Reporting an exposure failed: ${error.message}")
            }
        }
        return value
    }

    /**
     * Under the lock: the exposure to report for a read that answered [entry], or null — when no experiment
     * decided it, or the same variant was reported less than a day ago. Counted on this install's own clock in
     * either direction, so a clock set back does not silence the report for as long as it was set back by.
     */
    private fun exposureDue(entry: ConfigEntry): ConfigExposure? {
        val experiment = entry.experiment ?: return null
        val id = experiment.opt("id") as? String ?: return null
        val variant = experiment.opt("variant") as? String ?: return null
        val now = clock()
        val last = exposed[id]
        if (last != null && last.first == variant && kotlin.math.abs(now - last.second) < TreebarsConstants.CONFIG_EXPOSURE_FLOOR_SECONDS * 1000) return null
        exposed[id] = variant to now
        save()
        return ConfigExposure(id, experiment.opt("key") as? String ?: "", variant, entry.key, experiment.opt("unit") as? String ?: "device")
    }

    /** The entry a key answers with now, or null for "not set". Called under the lock. */
    private fun entry(key: String): ConfigEntry? {
        if (seen.containsKey(key)) return seen[key]
        val entry = held?.entry(key)
        seen[key] = entry
        save()
        return entry
    }

    /** Every key held, with the value a read would answer. Reading them all fixes them all for the session. */
    fun all(): Map<String, Any> = synchronized(lock) {
        val out = LinkedHashMap<String, Any>()
        for (one in held?.values.orEmpty()) entry(one.key)?.let { out[one.key] = it.value }
        for ((key, entry) in seen) if (entry != null && key !in out) out[key] = entry.value
        out.putAll(overrides)
        out
    }

    /** Whether a key already read would answer differently if it were read afresh. Called under the lock. */
    private fun wouldChange(): Boolean = seen.any { (key, was) ->
        val now = held?.entry(key)
        if (was == null) now != null else !was.sameAs(now)
    }

    /** Applies the newest answers to keys already read. True when a read now answers differently. */
    fun activate(): Boolean {
        val moved = synchronized(lock) {
            val moved = wouldChange()
            seen.clear()
            save()
            moved
        }
        if (moved) announce()
        return moved
    }

    /** What an upload's answer said the current version is. A different one asks; so does an ask still owed. */
    fun observe(version: String?) {
        val ask = synchronized(lock) { (version != null && version != held?.version) || held?.stale == true }
        if (ask) begin()
    }

    /**
     * Somebody signed in, or out (null). What depended on the account is read afresh; when the last one was an
     * account, its answers are dropped now rather than when the next ones arrive.
     */
    fun identityChanged(next: String?) {
        val dropped = synchronized(lock) {
            if (next == userId) return
            val previous = userId
            userId = next
            val set = held ?: return
            if (set.values.none { it.userDependent }) return

            seen.keys.filter { key -> seen[key]?.userDependent == true || set.entry(key)?.userDependent == true }.forEach { seen.remove(it) }
            // Kept from nobody to somebody: the same person, a moment before they said who they are.
            if (previous != null) set.values = set.values.filterNot { it.userDependent }
            set.stale = true
            reopen = true
            save()
            previous != null
        }
        if (dropped) announce()
        begin()
    }

    /** What the app says about this install, for rules to read. The same attributes again change nothing. */
    fun setAttributes(next: Map<String, Any?>) {
        val ask = synchronized(lock) {
            val cleaned = cleanAttributes(next)
            if (attributesKey(cleaned) == attributesKey(attributes)) return
            attributes = cleaned
            val set = held
            if (set == null || set.values.isEmpty()) {
                save()
                return
            }
            set.stale = true
            save()
            true
        }
        if (ask) begin()
    }

    /** Answers a key with [value] in this process, before anything held. Null takes it back. Never kept. */
    fun override(key: String, value: Any?) {
        synchronized(lock) { if (value == null) overrides.remove(key) else overrides[key] = value }
        announce()
    }

    /** Calls [listener] whenever what a read answers may have changed. Returns the way to stop hearing. */
    fun onChange(listener: () -> Unit): () -> Unit {
        listeners.add(listener)
        return { listeners.remove(listener) }
    }

    /**
     * Starts an ask, unless one is out or a refusal's wait is still running. Decided here, on the caller's own
     * thread and under the lock, and only the request itself is handed off — so two things that each call for an
     * ask a moment apart start one, never two: the second finds the first already out.
     */
    private fun begin() {
        val started = synchronized(lock) { claim() } ?: return
        launch { run(started) }
    }

    /** Under the lock: the ask to make — or null, when one is out (which is then told to be followed) or a wait is running. */
    private fun claim(): Asking? {
        if (asking != null) {
            again = true
            return null
        }
        if (clock() < notBefore) return null
        return Asking(ConfigAsk(userId, attributes), context).also { asking = it }
    }

    /**
     * Asks now, unless a refusal's wait is still running, and waits for the answer. Joins an ask already out. True
     * when answers arrived, false when they did not; never throws for a failed ask.
     */
    suspend fun refresh(): Boolean {
        var joined: CompletableDeferred<Boolean>? = null
        val mine = synchronized(lock) {
            val out = asking
            if (out != null) {
                again = true
                joined = out.done
                null
            } else {
                claim()
            }
        }
        joined?.let { return it.await() }
        return run(mine ?: return false)
    }

    private suspend fun run(started: Asking): Boolean {
        val answer = try {
            fetch(started.ask)
        } catch (cancelled: CancellationException) {
            synchronized(lock) { asking = null }
            started.done.complete(false)
            throw cancelled
        } catch (error: Exception) {
            TreebarsLogger.log("Config fetch failed: ${error.message}")
            ConfigAnswer.Failed()
        }

        var changed = false
        var follow = false
        val arrived = synchronized(lock) {
            asking = null
            val wasAgain = again
            again = false
            val read = (answer as? ConfigAnswer.Answered)?.body?.let(::readAnswer)
            if (read == null) {
                notBefore = clock() + waitFor(answer as? ConfigAnswer.Failed)
                save()
                return@synchronized false
            }
            // Whether who asked is still who is asking: if not, these stand for now and one more ask follows.
            val current = started.ask.userId == userId && attributesKey(started.ask.attributes) == attributesKey(attributes) && started.context == context
            val previous = held
            val next = Held(read.first, read.second, started.context, stale = !current)
            held = next
            notBefore = 0
            // An experiment no longer among the answers, last reported more than a day ago, would be reported afresh anyway.
            val now = clock()
            exposed.entries.removeAll { (id, last) ->
                kotlin.math.abs(now - last.second) >= TreebarsConstants.CONFIG_EXPOSURE_FLOOR_SECONDS * 1000 &&
                    next.values.none { it.experiment?.opt("id") == id }
            }
            if (reopen) {
                seen.keys.filter { key -> seen[key]?.userDependent == true || next.entry(key)?.userDependent == true }.forEach { seen.remove(it) }
                if (current) reopen = false
            }
            save()
            changed = previous == null || previous.version != next.version || previous.stale
            follow = !current || (wasAgain && next.stale)
            true
        }
        if (changed) announce()
        started.done.complete(arrived)
        if (follow) begin()
        return arrived
    }

    /** Forgets everything held: for a person who opted out, and a device being forgotten. */
    fun clear() {
        synchronized(lock) {
            held = null
            notBefore = 0
            exposed.clear()
            seen.clear()
            attributes = emptyMap()
            overrides.clear()
            store?.clear()
        }
    }

    private fun announce() {
        for (listener in listeners) {
            try {
                listener()
            } catch (error: Exception) {
                TreebarsLogger.log("A config listener threw: ${error.message}")
            }
        }
    }

    /** Called under the lock: the state as it stands, handed to whatever writes it. */
    private fun save() {
        val target = store ?: return
        val read = JSONObject()
        for ((key, entry) in seen) read.put(key, entry?.toJson() ?: JSONObject.NULL)
        val state = JSONObject()
            .put("set", held?.toJson() ?: JSONObject.NULL)
            .put("not_before", notBefore)
            .put("session", JSONObject().put("id", sessionId).put("seen", read))
            .put("attributes", JSONObject(attributes))
        if (exposed.isNotEmpty()) {
            val reported = JSONObject()
            for ((id, last) in exposed) reported.put(id, JSONObject().put("variant", last.first).put("at", last.second))
            state.put("exposed", reported)
        }
        persist(target, state)
    }

    companion object {
        /** An answer off the wire, checked rather than trusted: a version and a list. An entry that is not one is left out. */
        fun readAnswer(json: JSONObject?): Pair<String, List<ConfigEntry>>? {
            if (json == null) return null
            val version = (json.opt("version") as? String)?.takeIf { it.isNotEmpty() } ?: return null
            val array = json.opt("values") as? JSONArray ?: return null
            return version to (0 until array.length()).mapNotNull { ConfigEntry.fromJson(array.opt(it) as? JSONObject) }
        }

        private fun readHeld(json: JSONObject?): Held? {
            val (version, values) = readAnswer(json) ?: return null
            return Held(version, values, json?.opt("context") as? String ?: "", json?.opt("stale") == true)
        }

        private fun readAttributes(json: JSONObject?): Map<String, Any> {
            if (json == null) return emptyMap()
            return cleanAttributes(json.keys().asSequence().associateWith { json.opt(it) })
        }

        /** Text, numbers and booleans, under keys in order — so the same attributes set in another order are the same. */
        fun cleanAttributes(raw: Map<String, Any?>): Map<String, Any> {
            val out = TreeMap<String, Any>()
            for ((key, value) in raw) {
                if (key.isEmpty()) continue
                when (value) {
                    is String, is Boolean -> out[key] = value
                    is Number -> if (!value.toDouble().isNaN() && !value.toDouble().isInfinite()) out[key] = value
                    else -> Unit
                }
            }
            return out
        }

        /** Attributes as text two equal sets share. */
        fun attributesKey(attributes: Map<String, Any>): String =
            attributes.toSortedMap().entries.joinToString("\u0000") { (key, value) -> "$key=${value::class.simpleName?.take(1)}${ConfigEntry.canonical(value)}" }

        /** How long a refusal asks this install to wait, in milliseconds. */
        fun waitFor(failed: ConfigAnswer.Failed?): Long {
            val status = failed?.status
            if (status != null && status in TreebarsConstants.AUTH_STATUSES) return TreebarsConstants.AUTH_COOLDOWN_SECONDS * 1000
            if (status != null && status in TreebarsConstants.RETRY_AFTER_STATUSES) {
                val seconds = failed.retryAfter?.trim()?.toDoubleOrNull()
                if (seconds != null && seconds >= 0 && !seconds.isInfinite()) {
                    return (minOf(seconds, TreebarsConstants.RETRY_AFTER_MAX_SECONDS.toDouble()) * 1000).toLong()
                }
            }
            return TreebarsConstants.CONFIG_RETRY_SECONDS * 1000
        }
    }
}
