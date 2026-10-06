package com.treebars.sdk

import com.treebars.sdk.generated.TreebarsConstants
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * What the device says about its power and its network, asked when an upload is armed.
 *
 * Both false is also the answer for a device that cannot be asked, so a host app that withholds a
 * permission gets the ordinary pace rather than a slower one nobody chose.
 */
internal data class UploadConditions(
    /** Saving power or data: Battery Saver or Data Saver is on. */
    val constrained: Boolean = false,
    /** The active network is one its owner pays for by the amount sent. */
    val metered: Boolean = false,
)

/** Whether a write key belongs to a test environment, which its prefix says. */
internal fun isTestWriteKey(writeKey: String): Boolean = writeKey.startsWith("pk_test_")

/**
 * The least time between two uploads from a busy device, in milliseconds.
 *
 * A device saving power or data keeps the longest spacing whatever else is true: its owner asked
 * every app for less, and that outranks an app's choice and a test key alike. Otherwise an
 * interval the app chose is the spacing, never tighter than the debounce. A test key keeps almost
 * none, because somebody is watching a screen for the event they just caused. Everything else
 * keeps what the last accepted upload named, or the default before one has — and on a metered
 * network never less than the metered floor, since every upload there wakes a radio.
 *
 * @param chosenMs the interval the app chose at `initialize`; zero or less when it chose none.
 * @param namedMs what the last accepted upload named, already held to the bounds a device accepts.
 */
internal fun uploadSpacingMs(conditions: UploadConditions, chosenMs: Long, testKey: Boolean, namedMs: Long?): Long {
    if (conditions.constrained) return TreebarsConstants.DEFAULT_FLUSH_INTERVAL_MS
    if (chosenMs > 0) return maxOf(chosenMs, TreebarsConstants.FLUSH_DEBOUNCE_MS)
    if (testKey) return TreebarsConstants.FLUSH_SPACING_TEST_MS
    val spacing = namedMs ?: TreebarsConstants.FLUSH_SPACING_MS
    return if (conditions.metered) maxOf(spacing, TreebarsConstants.FLUSH_SPACING_METERED_MS) else spacing
}

/**
 * When an event is uploaded: the pace, one of three implementations — the iOS and web SDKs carry
 * the other two — and all three run the same shared scenarios (`flush-pace-scenarios.json`).
 *
 * An event arms one upload. It is due a debounce after the event — armed by the first event and
 * not moved by later ones, so a burst is one upload and a steady stream is still sent — or at the
 * end of the spacing since the last upload began, whichever is later. So a quiet device sends an
 * event a second after it happens, and a busy one is held to an upload per spacing.
 *
 * "The last upload" is any upload, whoever asked for it: one this armed, a listed event's, a full
 * batch, a retry, `flush()`, the one on the way to the background. The uploader says so as each
 * request leaves ([uploadBegan]) — when it leaves and not when it is answered, so a slow network
 * stretches nothing and a refused upload counts as much as an accepted one. And it is the last
 * upload when the armed one falls due, not when it was armed: an upload that begins in between
 * holds the armed one to the spacing after it.
 *
 * An upload that ends with events still waiting arms the next by itself ([backlogLeft]), a spacing
 * after it began. One upload carries a bounded number of batches, so a long queue goes a spacing at
 * a time, and it must not need a new event to keep going.
 *
 * It sits beside [EventUploader] and never inside it. This decides when to ask; the uploader still
 * decides whether anything is sent, so an armed upload that finds a closed gate or an empty queue
 * sends nothing. A listed event keeps the uploader's own wake, which ignores the spacing, and the
 * upload armed here then finds its events already gone.
 *
 * Nothing in here reads the device. The clock, the conditions and the upload are handed in, which
 * is what lets the scenarios run it without waiting; [scope] is where its one wake is launched.
 */
internal class FlushPace(
    private val scope: CoroutineScope,
    /** The interval the app chose at `initialize`. Zero or less when it chose none. */
    private val chosenMs: Long,
    private val testKey: Boolean,
    /** Asked once for each upload armed and at no other time: each answer is a call into the system. */
    private val conditions: () -> UploadConditions,
    /** The spacing the last accepted upload named, as the uploader holds it. Null before one has. */
    private val named: () -> Long?,
    /** The upload itself: the uploader's flush. */
    private val upload: suspend () -> Unit,
    private val clock: () -> Long = System::currentTimeMillis,
) {

    /** When the last upload began, as epoch millis. Null until this launch has sent one. */
    private var beganAt: Long? = null

    /** What the device said when the armed upload was armed; the spacing is worked out from it until that upload goes. */
    private var armedUnder = UploadConditions()

    /** When the armed upload is due, as epoch millis. Null while none is armed. */
    @Volatile
    private var dueAt: Long? = null

    /**
     * Milliseconds until the armed upload, or null when none is armed. Clamped at zero: the wake
     * sleeps on a monotonic clock and this reads the wall clock, so the two can disagree by a moment.
     */
    fun msUntilDue(): Long? = dueAt?.let { maxOf(0L, it - clock()) }

    /**
     * An event is on the queue. The first one arms the upload, a debounce on; the ones behind it
     * ride it.
     *
     * Synchronized, as everything that arms is, because events are recorded on several threads and
     * two that both found nothing armed would each arm an upload.
     */
    @Synchronized
    fun eventQueued() {
        if (dueAt != null) return
        arm(clock() + TreebarsConstants.FLUSH_DEBOUNCE_MS)
    }

    /**
     * An upload ended with events still waiting and nothing holding them back. The next is armed
     * for the end of the spacing, with no wait of its own: nobody is typing behind a backlog.
     *
     * Nothing to do when an upload is armed already — it is held to the same spacing when it wakes.
     */
    @Synchronized
    fun backlogLeft() {
        if (dueAt != null) return
        arm(clock())
    }

    /**
     * A request is leaving. Every send says so, so the spacing is counted from any of them.
     *
     * An upload already armed is put back to the end of the spacing here so that [msUntilDue] is
     * right at once; the wake works the same sum out again when it wakes, from whatever the answer
     * to this request named, and that one decides.
     */
    @Synchronized
    fun uploadBegan() {
        val now = clock()
        beganAt = now
        val due = dueAt ?: return
        val spaced = now + spacing()
        if (spaced > due) dueAt = spaced
    }

    private fun spacing(): Long = uploadSpacingMs(armedUnder, chosenMs, testKey, named())

    /**
     * When the spacing since the last upload ends, or null when this launch has sent none.
     *
     * Counted from no later than now. A last upload that appears to lie ahead is a clock set back
     * since it left, and taken at its word it would hold the next one for as long as the clock was
     * moved — a day, for somebody who set their phone back a day.
     */
    private fun spacedUntil(now: Long): Long? = beganAt?.let { minOf(it, now) + spacing() }

    /** Arms the upload for [soonest], or for the end of the spacing when that is later. Under the lock. */
    private fun arm(soonest: Long) {
        armedUnder = conditions()
        val spaced = spacedUntil(clock())
        val at = if (spaced != null && spaced > soonest) spaced else soonest
        dueAt = at
        scope.launch {
            var target = at
            while (true) {
                delay(maxOf(0L, target - clock()))
                target = heldUntil(target) ?: break
            }
            upload()
        }
    }

    /**
     * The wake has slept to [woke]. Null when the upload may go, and the wake is spent — before the
     * upload starts, so an event recorded while it runs arms the next one. Otherwise the later time
     * it is held to: an upload began while this one slept, or the last answer named a longer spacing.
     *
     * Compared with the time the wake was sleeping to rather than with the clock: `delay` runs on a
     * monotonic clock and [clock] is the wall clock, so a wake can finish a moment before the clock
     * reaches its time, and one that then slept that moment again would send a millisecond late.
     */
    @Synchronized
    private fun heldUntil(woke: Long): Long? {
        val spaced = spacedUntil(clock())
        if (spaced != null && spaced > woke) {
            dueAt = spaced
            return spaced
        }
        dueAt = null
        return null
    }
}
