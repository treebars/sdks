package com.treebars.sdk

import com.treebars.sdk.generated.TreebarsConstants

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.util.UUID
import kotlin.coroutines.CoroutineContext
import kotlin.math.floor
import kotlin.math.pow
import kotlin.random.Random

/**
 * What an upload attempt did, for a host app that wants to watch.
 *
 * `TreebarsLogger` writes to logcat when `debug` is on, and that is a developer reading a
 * console, not something an app can render; this is. It is also what the React Native
 * bridge forwards as `onUpload`.
 *
 * `count` and `eventNames` are null on anything that is not an event batch. Names rather than
 * bodies deliberately: the point is "what went and did it land", and a panel that printed
 * properties would put a customer's data on a screen the SDK does not control.
 */
data class UploadLog(
    val type: String,
    val status: String,
    val message: String,
    val count: Int? = null,
    val eventNames: List<String>? = null,
    val statusCode: Int? = null,
)

/*
 * How far ahead either gate may legitimately be. Anything further is a clock that moved
 * backwards after the gate was written, and a persisted gate would otherwise hold a device
 * silent until the clock caught up — a day, for somebody who set their phone back a day.
 */
private val RETRY_GATE_CEILING_MS =
    maxOf(TreebarsConstants.BACKOFF_CAP_SECONDS, TreebarsConstants.RETRY_AFTER_MAX_SECONDS) * 1000
private const val AUTH_GATE_CEILING_MS = TreebarsConstants.AUTH_COOLDOWN_SECONDS * 1000

/**
 * The upload policy, one of three implementations of it — the iOS and web SDKs carry the other
 * two — and all three run the same shared scenarios (`uploader-scenarios.json`).
 *
 * A batch is sealed and written to [UploaderStore] before its first send, and it is resent
 * unchanged — same id, same events — until a 2xx removes it, including after the process dies.
 * So a batch whose response was lost — written by the server, the connection gone before the
 * 200 — goes out again under the same id and can be recognised as the same batch. Retries wait
 * a full-jitter backoff rather than a fixed ladder, so devices that failed together during an
 * outage do not all retry at the same instants when it ends.
 *
 * A flush drains up to `DRAIN_MAX_BATCHES`, stops at the first failure, and leaves behind a
 * persisted gate: a full-jitter backoff, the server's `Retry-After`, or an hour's cooldown for
 * a refused write key. A 413 splits the batch into halves with derived ids; any other 4xx drops it.
 *
 * Nothing in here sleeps. The clock, the jitter and the ids are handed in, which is what lets
 * the scenarios run it without waiting; [scope] is where the one wake it schedules is launched.
 *
 * It also decides when a listed event goes out — the shared `trigger-scenarios.json` is that half
 * of the policy, and [TriggerEvents] is the list it asks.
 */
internal class EventUploader(
    private val queue: EventQueue,
    private val transport: EventTransport,
    private val store: UploaderStore,
    private val writeKey: String,
    private val batchSize: Int = TreebarsConstants.BATCH_SIZE,
    private val clock: () -> Long = System::currentTimeMillis,
    /** In [0, 1). The jitter source, and the only randomness in the policy. */
    private val random: () -> Double = { Random.nextDouble() },
    private val newBatchId: () -> String = { UUID.randomUUID().toString() },
    /** Where a wake is launched. Null means no wake — the upload scenarios drive time themselves. */
    private val scope: CoroutineScope? = null,
    /**
     * Where the blocking send runs. `Dispatchers.IO` on a device; the trigger scenarios hand in the
     * test dispatcher's own context, because a send on a real IO thread would finish outside the
     * virtual clock and race every assertion after it.
     */
    private val ioContext: CoroutineContext = Dispatchers.IO,
    /** The trigger list. Null means no event flushes early and no version is acted on. */
    private val triggers: TriggerEvents? = null,
    /**
     * True while the person has opted out (`Treebars.optOut`). Nothing is sent then, whoever asks — the
     * timer, the lifecycle, a wake, a trigger, the flush on the way up, or the public `flush()`. Asked
     * before every batch, so a drain already running stops at the next one. It drops nothing itself;
     * that is the opt-out's discard.
     */
    private val paused: () -> Boolean = { false },
) {

    /**
     * Set by `Treebars.setUploadListener`. Volatile because it is written from whatever
     * thread the integrator calls that on and read from the flush coroutine.
     *
     * Never awaited and never allowed to break a flush: a listener that throws is the host
     * app's bug, and losing a batch over it would be ours.
     */
    @Volatile
    var listener: ((UploadLog) -> Unit)? = null

    private fun report(
        status: String,
        message: String,
        count: Int? = null,
        names: List<String>? = null,
        statusCode: Int? = null,
    ) {
        val callback = listener ?: return
        runCatching { callback(UploadLog("events", status, message, count, names, statusCode)) }
    }

    private fun namesOf(events: List<JSONObject>): List<String> =
        events.map { it.optString("event_name") }.filter { it.isNotEmpty() }

    /** A non-suspending guard so overlapping flush triggers collapse into one. */
    private val flushLock = Mutex()

    /**
     * Read from storage on construction, as the queue reads its own file, and replaced whole on
     * every change after it.
     *
     * Volatile because [pendingEvents] reads it from any thread while only the flush, under
     * [flushLock], ever writes it.
     */
    @Volatile
    private var state: UploaderState = store.load()

    /** Whether the queue has been checked against the stored batches yet. Flush-lock only. */
    private var reconciled = false

    @Volatile
    private var wake: Job? = null

    @Volatile
    private var wakeAt = 0L

    /** Events sealed into batches and not yet acknowledged. */
    fun pendingEvents(): Int = state.pending.sumOf { it.events.size }

    /**
     * Drops every sealed batch, with the gates they had closed — for an opt-out or a wipe, where the
     * person said stop rather than "after these". Under the flush lock, so a drain in flight finishes
     * its one request first and cannot re-seal what this dropped.
     */
    suspend fun discardPending() {
        flushLock.lock()
        try {
            commit(UploaderState())
        } finally {
            flushLock.unlock()
        }
    }

    /**
     * Drains, and then — if an answer said the trigger list has moved on — fetches it. After the
     * drain rather than inside it, so queued uploads are never held behind a list, and outside the
     * lock, so a trigger's wake is not either; a drain whose every answer carried the new version
     * fetches the list once.
     */
    suspend fun flush() {
        // Two statements, not `triggers?.observe(drain(...))`: a safe call on a null receiver does
        // not evaluate its argument, so a core with no trigger list would never drain at all.
        val seen = drain(waitForLock = false)
        triggers?.observe(seen)
    }

    /**
     * A logged event, told to the uploader once it is on the queue. A listed one asks for a flush
     * `TRIGGER_FLUSH_DEBOUNCE_MS` from now.
     *
     * It asks and nothing more. The drain that answers checks the `Retry-After` gate and the auth
     * cooldown like every other drain, so a trigger cannot send anything a 429 said to hold — and a
     * wake already due sooner, a retry's, is left where it is and carries the trigger with it. Only
     * the first trigger arms the wake: later ones inside the second ride it rather than pushing it
     * back, or a trigger every nine hundred milliseconds would never be sent.
     */
    fun eventLogged(eventName: String) {
        if (triggers?.contains(eventName) != true) return
        scheduleWake(clock() + TreebarsConstants.TRIGGER_FLUSH_DEBOUNCE_MS)
    }

    /**
     * @param waitForLock false for every ordinary trigger, which collapses into a flush already
     *   running. True for a wake, which is launched from inside the flush that failed and can fire
     *   before that flush has let go — collapsing into it would lose the retry it exists for until
     *   the next timer tick. A listed event's wake waits too: the drain it would collapse into may
     *   have sealed its last batch before the event reached the queue.
     * @return the newest trigger version any answer in this drain carried.
     */
    private suspend fun drain(waitForLock: Boolean): String? {
        if (waitForLock) flushLock.lock() else if (!flushLock.tryLock()) return null

        var seen: String? = null
        try {
            reconcile()
            var sends = 0
            while (sends < TreebarsConstants.DRAIN_MAX_BATCHES) {
                if (paused() || gated(clock())) return seen
                val batch = state.pending.firstOrNull() ?: seal() ?: return seen

                val names = namesOf(batch.events)
                report("sending", "Sending ${batch.events.size} event(s)", batch.events.size, names)

                val response = try {
                    withContext(ioContext) { transport.postEvents(batch.toJson()) }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
                    // No answer at all. The batch is on disk, so this is recoverable.
                    TreebarsLogger.log("Upload failed: ${error.message}")
                    null
                }
                if (response?.triggersVersion != null) seen = response.triggersVersion
                sends += 1
                if (!settle(batch, response)) return seen
            }
            return seen
        } finally {
            flushLock.unlock()
        }
    }

    /**
     * The queue checked against the stored batches, once per process.
     *
     * A batch is written out and only then taken off the queue, so a process killed between the
     * two leaves its events in both. They are the same events under the same ids, and sealing the
     * queue's copies into a new batch would be exactly the double count this exists to prevent.
     */
    private suspend fun reconcile() {
        if (reconciled) return
        queue.removeIds(state.pendingEventIds)
        reconciled = true
    }

    private fun commit(next: UploaderState): Boolean {
        state = next
        return store.save(next)
    }

    /** Whether either gate is closed at [now], re-basing one further ahead than it could have been set. */
    private fun gated(now: Long): Boolean {
        var next = state
        if (next.nextAllowedAt > now + RETRY_GATE_CEILING_MS) {
            next = next.copy(nextAllowedAt = now + RETRY_GATE_CEILING_MS)
        }
        if (next.authBlockedUntil > now + AUTH_GATE_CEILING_MS) {
            next = next.copy(authBlockedUntil = now + AUTH_GATE_CEILING_MS)
        }
        if (next != state) commit(next)

        if (next.authBlockedUntil > now && next.authKey == writeKey) return true
        if (next.nextAllowedAt > now) {
            scheduleWake(next.nextAllowedAt)
            return true
        }
        return false
    }

    /**
     * Takes the head of the queue as a new pending batch, written before anything is sent.
     *
     * The queue's copies are removed only once that write has landed. If it did not, they stay
     * queued and are removed on acknowledgement instead, so a process death in between re-sends
     * them rather than losing them.
     */
    private suspend fun seal(): PendingBatch? {
        val events = queue.peek(batchSize)
        if (events.isEmpty()) return null

        val batch = PendingBatch(newBatchId(), Iso8601.at(clock()), events)
        if (commit(state.copy(pending = listOf(batch)))) queue.removeIds(batch.eventIds)
        return batch
    }

    /** Applies one answer. True when the drain may continue. */
    private suspend fun settle(batch: PendingBatch, response: UploadResponse?): Boolean {
        val now = clock()
        val before = state
        val status = response?.status ?: 0
        val count = batch.events.size
        val names = namesOf(batch.events)

        if (response != null && status in 200..299) {
            commit(
                before.copy(
                    pending = before.pending.drop(1),
                    attempt = 0,
                    nextAllowedAt = 0,
                    authBlockedUntil = 0,
                    authKey = null,
                ),
            )
            // Normally a no-op: see [seal] for the one case where the queue still holds them.
            queue.removeIds(batch.eventIds)
            TreebarsLogger.log("Uploaded $count event(s)")
            report("success", "Sent $count event(s)", count, names, status)
            return true
        }

        if (response != null && status == 413) {
            if (count > 1) {
                /*
                 * Halves under derived ids, written in place of the batch. Derived rather than
                 * minted so that a split replayed after a crash — the whole batch resent, refused
                 * again, split again — produces the same two ids, and a half the server already
                 * took is recognised.
                 */
                val middle = (count + 1) / 2
                val halves = listOf(
                    PendingBatch("${batch.batchId}.0", batch.sentAt, batch.events.subList(0, middle).toList()),
                    PendingBatch("${batch.batchId}.1", batch.sentAt, batch.events.subList(middle, count).toList()),
                )
                commit(before.copy(pending = halves + before.pending.drop(1), attempt = 0, nextAllowedAt = 0))
                TreebarsLogger.log("Batch of $count too large; split in two")
                report("error", "Batch too large; split in two", count, names, status)
                return true
            }
            drop(before, batch, status, names)
            return false
        }

        if (response != null && status in TreebarsConstants.AUTH_STATUSES) {
            commit(
                before.copy(
                    attempt = 0,
                    nextAllowedAt = 0,
                    authBlockedUntil = now + AUTH_GATE_CEILING_MS,
                    authKey = writeKey,
                ),
            )
            TreebarsLogger.log("Upload refused (HTTP $status). Check the write key; retrying in an hour.")
            report("error", "Upload refused; check the write key", count, names, status)
            return false
        }

        val honoursRetryAfter = response != null && status in TreebarsConstants.RETRY_AFTER_STATUSES
        if (response != null && !honoursRetryAfter && status in 400..499) {
            drop(before, batch, status, names)
            return false
        }

        /*
         * Everything else is worth another attempt: no answer at all, a 5xx, a 429, and whatever a
         * proxy invents. The server's own delay wins where it gave a usable one; otherwise jitter.
         */
        val asked = if (honoursRetryAfter) retryAfterDelayMs(response?.retryAfter, now) else null
        val wait = if (asked != null && asked > 0) {
            minOf(asked, TreebarsConstants.RETRY_AFTER_MAX_SECONDS * 1000)
        } else {
            jitterMs(before.attempt, random())
        }
        val retryAt = now + wait
        commit(before.copy(attempt = before.attempt + 1, nextAllowedAt = retryAt))
        TreebarsLogger.log("Upload not accepted (${if (response == null) "no answer" else "HTTP $status"}); retrying in ${wait}ms")
        report("error", "Upload failed; retrying in ${(wait + 999) / 1000}s", count, names, response?.status)
        scheduleWake(retryAt)
        return false
    }

    /** A batch that will never succeed. Gone from both stores, and the drain ends with it. */
    private suspend fun drop(before: UploaderState, batch: PendingBatch, status: Int, names: List<String>) {
        commit(before.copy(pending = before.pending.drop(1), attempt = 0, nextAllowedAt = 0))
        queue.removeIds(batch.eventIds)
        TreebarsLogger.log("Server rejected ${batch.events.size} event(s) (HTTP $status); discarded")
        report("error", "Server rejected the batch; discarded", batch.events.size, names, status)
    }

    /**
     * One wake, at the earliest moment anything has asked for: a retry falling due, or a listed
     * event's debounce running out.
     *
     * Without it a two-second backoff would wait for the thirty-second timer, and the jitter would
     * be decoration — and so would a trigger. A closed gate reports itself on every flush attempt —
     * each event past the batch size is one — so a wake still sleeping towards this time or an
     * earlier one is left alone: it will find the gate and ask again. A wake whose time has come is
     * not treated as pending, because the flush that schedules the next retry is usually that wake's
     * own.
     *
     * Synchronized because it is reached from two threads: the flush coroutine, and whichever
     * one recorded the listed event. Two callers both finding no sleeping wake would each launch
     * one, and the loser's would flush for nothing.
     */
    @Synchronized
    private fun scheduleWake(at: Long) {
        val launcher = scope ?: return
        val sleeping = wake?.takeIf { it.isActive && wakeAt > clock() }
        if (sleeping != null && wakeAt <= at) return
        sleeping?.cancel()
        wakeAt = at
        wake = launcher.launch {
            delay(maxOf(0L, at - clock()))
            woke(at)
            val seen = drain(waitForLock = true)
            triggers?.observe(seen)
        }
    }

    /**
     * A fired wake is spent before it drains, told rather than inferred from the clock: `delay` runs
     * on a monotonic clock and [clock] is the wall clock, so a wake can finish a moment before
     * [clock] reaches the time it was armed for — and one that still looked asleep would refuse to
     * arm the next, leaving a retry to the thirty-second tick.
     */
    @Synchronized
    private fun woke(at: Long) {
        if (wakeAt == at) wakeAt = 0
    }
}

/** `random(0, min(cap, base * 2^attempt))`, in whole milliseconds. */
internal fun jitterMs(attempt: Int, random: Double): Long {
    val ceilingMs = minOf(
        TreebarsConstants.BACKOFF_CAP_SECONDS.toDouble(),
        TreebarsConstants.BACKOFF_BASE_SECONDS * 2.0.pow(minOf(attempt, 30)),
    ) * 1000.0
    return floor(random * ceilingMs).toLong()
}

private val DELTA_SECONDS = Regex("""^[0-9]+$""")
private val IMF_FIXDATE =
    Regex("""^(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun), ([0-9]{2}) ([A-Z][a-z]{2}) ([0-9]{4}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) GMT$""")
private val MONTHS = listOf("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")

/**
 * How long a `Retry-After` asks for, in milliseconds from [now], or null when it says nothing
 * usable. Zero or negative when a date has already passed.
 *
 * Delta-seconds or an IMF-fixdate, and nothing looser, computed by hand rather than through
 * `SimpleDateFormat` — whose leniency is a setting, and whose idea of a two-digit year is not the
 * web SDK's. A header one SDK honours and another ignores is three policies rather than one. A value
 * this refuses falls back to jitter, which is never faster than the policy.
 */
internal fun retryAfterDelayMs(header: String?, now: Long): Long? {
    val value = header?.trim() ?: return null
    // Any number past an hour is capped anyway; the clamp only keeps the arithmetic finite.
    if (DELTA_SECONDS.matches(value)) return minOf(value.toDouble() * 1000.0, 1e15).toLong()

    val match = IMF_FIXDATE.matchEntire(value) ?: return null
    val (dayText, monthText, yearText, hourText, minuteText, secondText) = match.destructured
    val month = MONTHS.indexOf(monthText) + 1
    val day = dayText.toInt()
    val hour = hourText.toInt()
    val minute = minuteText.toInt()
    val second = secondText.toInt()
    if (month < 1 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 60) return null

    val at = daysFromCivil(yearText.toInt(), month, day) * 86_400_000L +
        ((hour * 60L + minute) * 60L + second) * 1000L
    return at - now
}

/** Days since 1970-01-01 for a proleptic Gregorian date, month 1-12 (Howard Hinnant's algorithm). */
private fun daysFromCivil(year: Int, month: Int, day: Int): Long {
    val y = (if (month <= 2) year - 1 else year).toLong()
    val era = Math.floorDiv(y, 400L)
    val yearOfEra = y - era * 400
    val dayOfYear = (153L * ((month + 9) % 12) + 2) / 5 + day - 1
    val dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
}
