package com.treebars.sdk

import com.treebars.sdk.generated.TreebarsConstants
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * What the shared pace scenarios cannot reach: the header as it is read off an answer, the spacing
 * kept across a relaunch, the countdown an app can show, which uploads the uploader calls a backlog,
 * and what the pace does about one.
 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
class FlushPaceTest {

    @get:Rule
    val temp = TemporaryFolder()

    private val epoch = 1_790_000_000_000L

    private fun event(id: String): JSONObject = JSONObject()
        .put("event_id", id)
        .put("device_id", "dev_pace")
        .put("event_name", "evt_$id")
        .put("properties", JSONObject())
        .put("timestamp", "2026-10-06T12:00:00.000Z")
        .put("sdk_version", TreebarsConstants.SDK_VERSION)

    @Test
    fun `a spacing is whole milliseconds, held to the bounds a device accepts`() {
        assertEquals(2_000L, namedSpacingMs("2000"))
        assertEquals(2_000L, namedSpacingMs(" 2000 "))
        assertEquals(TreebarsConstants.FLUSH_SPACING_MIN_MS, namedSpacingMs("100"))
        assertEquals(TreebarsConstants.FLUSH_SPACING_MIN_MS, namedSpacingMs("0"))
        assertEquals(TreebarsConstants.FLUSH_SPACING_MAX_MS, namedSpacingMs("999999"))
        // Too long for a Long: still the most a device accepts, not a throw.
        assertEquals(TreebarsConstants.FLUSH_SPACING_MAX_MS, namedSpacingMs("9".repeat(40)))
        for (unreadable in listOf(null, "", " ", "fast", "1.5", "-5", "+5", "5s", "0x10", "null")) {
            assertNull("`$unreadable` names no spacing", namedSpacingMs(unreadable))
        }
    }

    @Test
    fun `the spacing follows the device first, then the app, then the key, then the server`() {
        val quiet = UploadConditions()
        val metered = UploadConditions(metered = true)
        val saving = UploadConditions(constrained = true)
        val unset = Treebars.SDK_PACE

        assertEquals(TreebarsConstants.FLUSH_SPACING_MS, uploadSpacingMs(quiet, unset, testKey = false, namedMs = null))
        assertEquals(2_000L, uploadSpacingMs(quiet, unset, testKey = false, namedMs = 2_000L))
        assertEquals(TreebarsConstants.FLUSH_SPACING_METERED_MS, uploadSpacingMs(metered, unset, testKey = false, namedMs = 2_000L))
        // The metered spacing is a floor: a slower word from the server still stands.
        assertEquals(40_000L, uploadSpacingMs(metered, unset, testKey = false, namedMs = 40_000L))
        assertEquals(TreebarsConstants.FLUSH_SPACING_TEST_MS, uploadSpacingMs(metered, unset, testKey = true, namedMs = 40_000L))
        // The app's own choice is the spacing, on any network and under any key, never under the debounce.
        assertEquals(45_000L, uploadSpacingMs(metered, 45_000L, testKey = true, namedMs = 2_000L))
        assertEquals(TreebarsConstants.FLUSH_DEBOUNCE_MS, uploadSpacingMs(quiet, 10L, testKey = false, namedMs = null))
        // Below zero is "none chosen" as much as zero is.
        assertEquals(TreebarsConstants.FLUSH_SPACING_MS, uploadSpacingMs(quiet, -1L, testKey = false, namedMs = null))
        // And a device saving power or data outranks every one of them.
        assertEquals(TreebarsConstants.DEFAULT_FLUSH_INTERVAL_MS, uploadSpacingMs(saving, 2_000L, testKey = true, namedMs = 1_000L))
        assertEquals(TreebarsConstants.DEFAULT_FLUSH_INTERVAL_MS, uploadSpacingMs(saving.copy(metered = true), unset, testKey = false, namedMs = null))
    }

    @Test
    fun `a key is a test key by its prefix and nothing else`() {
        assertTrue(isTestWriteKey("pk_test_demo0000000000000000demo"))
        assertFalse(isTestWriteKey("pk_live_demo0000000000000000demo"))
        assertFalse(isTestWriteKey("pk_live_pk_test_"))
        assertFalse(isTestWriteKey(""))
    }

    @Test
    fun `the spacing an accepted upload named is kept for the next launch, and a refusal names nothing`() = runBlocking {
        val directory = temp.newFolder()
        val answers = ArrayDeque(
            listOf(
                UploadResponse(200, flushSpacing = "2000"),
                // An accepted upload that names none leaves the last word standing.
                UploadResponse(200),
                // A refusal's header is not the server's word about anything.
                UploadResponse(400, flushSpacing = "9000"),
            ),
        )
        fun uploader(queue: EventQueue) = EventUploader(
            queue = queue,
            transport = EventTransport { answers.removeFirst() },
            store = UploaderStore(directory),
            writeKey = "pk_live_pace",
            clock = { epoch },
        )

        val queue = EventQueue(directory)
        val first = uploader(queue)
        assertNull("nothing has named a spacing yet", first.spacingMs)
        for (id in listOf("e1", "e2", "e3")) {
            queue.append(event(id))
            first.flush()
            assertEquals("after $id", 2_000L, first.spacingMs)
        }
        assertEquals(0, answers.size)

        assertEquals("a relaunch starts with it", 2_000L, uploader(EventQueue(directory)).spacingMs)

        // What a person asked not to be sent goes, and the state it was kept in goes with it.
        first.discardPending()
        assertNull(uploader(EventQueue(directory)).spacingMs)
    }

    @Test
    fun `a stored spacing is held to the bounds again when it is read back`() {
        val state = UploaderState.fromJson(JSONObject().put("flush_spacing_ms", 5))
        assertEquals(TreebarsConstants.FLUSH_SPACING_MIN_MS, state.spacingMs)
        assertNull(UploaderState.fromJson(JSONObject()).spacingMs)
        assertNull(UploaderState.fromJson(JSONObject().put("flush_spacing_ms", "soon")).spacingMs)
        assertEquals(7_000L, UploaderState.fromJson(UploaderState(spacingMs = 7_000L).toJson()).spacingMs)
        assertNull(UploaderState.fromJson(UploaderState().toJson()).spacingMs)
    }

    /** A pace on a virtual clock, counting the uploads it asks for. */
    private class Rig(epoch: Long) {
        val scheduler = TestCoroutineScheduler()
        private val job = Job()
        var offset = 0L
        var uploads = 0
        /** What the last accepted upload named, as the uploader would answer. */
        var named: Long? = null
        val pace: FlushPace = FlushPace(
            scope = CoroutineScope(StandardTestDispatcher(scheduler) + job),
            chosenMs = Treebars.SDK_PACE,
            testKey = false,
            conditions = { UploadConditions() },
            named = { named },
            upload = { uploads += 1 },
            clock = { epoch + offset + scheduler.currentTime },
        )

        fun advance(ms: Long) {
            scheduler.advanceTimeBy(ms)
            scheduler.runCurrent()
        }

        fun stop() = job.cancel()
    }

    @Test
    fun `the countdown is null until an event arms an upload, and null again once it has gone`() {
        val rig = Rig(epoch)
        assertNull("nothing is armed before the first event", rig.pace.msUntilDue())

        rig.pace.eventQueued()
        assertEquals(TreebarsConstants.FLUSH_DEBOUNCE_MS, rig.pace.msUntilDue())
        rig.advance(400)
        // A later event rides the upload the first one armed, and does not move it.
        rig.pace.eventQueued()
        assertEquals(TreebarsConstants.FLUSH_DEBOUNCE_MS - 400, rig.pace.msUntilDue())

        rig.advance(TreebarsConstants.FLUSH_DEBOUNCE_MS - 400)
        assertEquals(1, rig.uploads)
        assertNull("nothing is armed once the upload has run", rig.pace.msUntilDue())
        rig.stop()
    }

    @Test
    fun `a backlog arms the next upload a spacing after the last one began, with no event to ask`() {
        val rig = Rig(epoch)
        rig.pace.uploadBegan()
        // The upload took a moment; the spacing is counted from when it left, not from when it ended.
        rig.advance(300)
        rig.pace.backlogLeft()
        assertEquals(TreebarsConstants.FLUSH_SPACING_MS - 300, rig.pace.msUntilDue())

        rig.advance(TreebarsConstants.FLUSH_SPACING_MS - 301)
        assertEquals(0, rig.uploads)
        rig.advance(1)
        assertEquals(1, rig.uploads)
        assertNull("one upload was owed, and nothing more is armed until something asks", rig.pace.msUntilDue())
        rig.advance(TreebarsConstants.FLUSH_SPACING_MAX_MS)
        assertEquals(1, rig.uploads)
        rig.stop()
    }

    @Test
    fun `a backlog is carried by the upload an event already armed, not by a second one`() {
        val rig = Rig(epoch)
        rig.pace.eventQueued()
        rig.pace.uploadBegan()
        rig.pace.backlogLeft()
        rig.advance(TreebarsConstants.FLUSH_SPACING_MS)
        assertEquals(1, rig.uploads)
        rig.advance(TreebarsConstants.FLUSH_SPACING_MAX_MS)
        assertEquals(1, rig.uploads)
        rig.stop()
    }

    @Test
    fun `an upload that begins while one is armed holds the armed one to the spacing after it`() {
        val rig = Rig(epoch)
        rig.pace.eventQueued()
        rig.advance(200)
        // Somebody else's upload — a full batch, a listed event, the app's own flush — two hundred milliseconds in.
        rig.pace.uploadBegan()
        assertEquals("the countdown says so at once", TreebarsConstants.FLUSH_SPACING_MS, rig.pace.msUntilDue())

        // Past the moment the event had armed it for, and up to the last millisecond of the spacing.
        rig.advance(TreebarsConstants.FLUSH_SPACING_MS - 1)
        assertEquals(0, rig.uploads)
        rig.advance(1)
        assertEquals(1, rig.uploads)
        rig.stop()
    }

    @Test
    fun `a longer spacing named while an upload is armed is the one it waits for`() {
        val rig = Rig(epoch)
        rig.pace.uploadBegan()
        rig.pace.eventQueued()
        assertEquals(TreebarsConstants.FLUSH_SPACING_MS, rig.pace.msUntilDue())
        // The answer to that upload comes back after the next was armed, and asks for more room.
        rig.named = TreebarsConstants.FLUSH_SPACING_MS * 2

        rig.advance(TreebarsConstants.FLUSH_SPACING_MS)
        assertEquals(0, rig.uploads)
        assertEquals(TreebarsConstants.FLUSH_SPACING_MS, rig.pace.msUntilDue())
        rig.advance(TreebarsConstants.FLUSH_SPACING_MS)
        assertEquals(1, rig.uploads)
        rig.stop()
    }

    /** An uploader over [events] with one event to a batch, counting the backlogs it reports. */
    private class Drains(directory: java.io.File, private val epoch: Long, events: List<JSONObject>, answer: (Int) -> UploadResponse) {
        var requests = 0
        var backlogs = 0
        var paused = false
        val queue = EventQueue(directory).also { queue -> runBlocking { events.forEach { queue.append(it) } } }
        val uploader = EventUploader(
            queue = queue,
            transport = EventTransport { answer(++requests) },
            store = UploaderStore(directory),
            writeKey = "pk_live_pace",
            batchSize = 1,
            clock = { epoch },
            random = { 0.5 },
            paused = { paused },
            backlogLeft = { backlogs += 1 },
        )
    }

    @Test
    fun `a queue longer than one drain is a backlog until the drain that empties it`() = runBlocking {
        val events = (1..TreebarsConstants.DRAIN_MAX_BATCHES + 2).map { event("e$it") }
        val drains = Drains(temp.newFolder(), epoch, events) { UploadResponse(200) }

        drains.uploader.flush()
        assertEquals(TreebarsConstants.DRAIN_MAX_BATCHES, drains.requests)
        assertEquals("the drain stopped at its limit with events still waiting", 1, drains.backlogs)

        drains.uploader.flush()
        assertEquals(TreebarsConstants.DRAIN_MAX_BATCHES + 2, drains.requests)
        assertEquals("the queue is empty: nothing is owed", 1, drains.backlogs)

        // And a flush with nothing to send is not an upload at all.
        drains.uploader.flush()
        assertEquals(1, drains.backlogs)
    }

    @Test
    fun `the events behind a dropped batch are a backlog`() = runBlocking {
        val drains = Drains(temp.newFolder(), epoch, listOf(event("e1"), event("e2"))) { UploadResponse(400) }
        drains.uploader.flush()
        assertEquals("a drop ends its drain", 1, drains.requests)
        assertEquals(1, drains.backlogs)
    }

    @Test
    fun `events held behind a closed gate are not a backlog, whichever gate it is`() = runBlocking {
        // A failure worth retrying: the uploader's own wake comes back for these when the gate opens.
        val failing = Drains(temp.newFolder(), epoch, listOf(event("e1"), event("e2"))) { UploadResponse(500) }
        failing.uploader.flush()
        assertEquals(1, failing.requests)
        assertEquals(0, failing.backlogs)

        // A refused key: nothing is tried again until its cooldown has passed.
        val refused = Drains(temp.newFolder(), epoch, listOf(event("e1"), event("e2"))) { UploadResponse(401) }
        refused.uploader.flush()
        refused.uploader.flush()
        assertEquals(1, refused.requests)
        assertEquals(0, refused.backlogs)

        // A person who opted out: nothing is sent, so nothing ended.
        val quiet = Drains(temp.newFolder(), epoch, listOf(event("e1"))) { UploadResponse(200) }
        quiet.paused = true
        quiet.uploader.flush()
        assertEquals(0, quiet.requests)
        assertEquals(0, quiet.backlogs)
    }

    @Test
    fun `a clock set back cannot hold the next upload longer than a spacing`() {
        val rig = Rig(epoch)
        rig.pace.uploadBegan()
        // A day earlier than the last upload began.
        rig.offset = -24L * 60 * 60 * 1000
        rig.pace.eventQueued()
        assertEquals(TreebarsConstants.FLUSH_SPACING_MS, rig.pace.msUntilDue())
        rig.stop()
    }

    @Test
    fun `an upload the pace armed waits its turn behind a drain already running`() = runBlocking {
        val directory = temp.newFolder()
        val queue = EventQueue(directory)
        queue.append(event("first"))

        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val sent = Collections.synchronizedList(mutableListOf<String>())
        val uploader = EventUploader(
            queue = queue,
            transport = EventTransport { batch ->
                sent += batch.getString("batch_id")
                started.countDown()
                release.await(5, TimeUnit.SECONDS)
                UploadResponse(200)
            },
            store = UploaderStore(directory),
            writeKey = "pk_live_pace",
            clock = { epoch },
        )

        val running = async(Dispatchers.Default) { uploader.flush() }
        assertTrue("the first request never left", started.await(5, TimeUnit.SECONDS))

        // A plain flush collapses into the drain that holds the lock, and returns at once.
        withTimeout(2_000) { uploader.flush() }
        // The pace's does not: it is still waiting while that drain has not let go.
        val inTurn = async(Dispatchers.Default) { uploader.flushInTurn() }
        delay(200)
        assertFalse("it ran through a drain that was still sending", inTurn.isCompleted)

        release.countDown()
        withTimeout(5_000) {
            running.await()
            inTurn.await()
        }
        assertEquals("and found nothing left to send when its turn came", 1, sent.size)
    }
}
