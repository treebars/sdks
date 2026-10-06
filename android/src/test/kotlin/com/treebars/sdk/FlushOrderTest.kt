package com.treebars.sdk

import com.treebars.sdk.generated.TreebarsConstants
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * `track(); flush()` sends what was just tracked. A flush waits for the records launched before it (`InFlight`);
 * otherwise it could drain before the event was queued, and the event would go with a later upload.
 *
 * A flush that finds a drain running does nothing, but the running drain seals the queue again after every send, so
 * an event queued while a batch is on the wire goes out in that same drain. The last test pins that — it is what
 * makes the collapse safe. The one window left is a flush landing between the drain's final empty seal and its
 * unlock, microseconds wide.
 */
@RunWith(RobolectricTestRunner::class)
class FlushOrderTest {

    @get:Rule
    val temp = TemporaryFolder()

    @Test
    fun `a flush waits for every record launched before it, and none launched after`() = runTest {
        val inFlight = InFlight()
        val order = Collections.synchronizedList(mutableListOf<String>())

        inFlight.add(launch { delay(100); order += "slow record" })
        inFlight.add(launch { order += "fast record" })
        val tracked = inFlight.snapshot()
        val flush = launch { tracked.joinAll(); order += "flush" }
        inFlight.add(launch { delay(500); order += "later record" })

        flush.join()
        assertEquals(listOf("fast record", "slow record", "flush"), order.toList())
    }

    @Test
    fun `a finished record is forgotten, so a flush does not wait on it`() = runTest {
        val inFlight = InFlight()
        val done = launch { }
        done.join()
        inFlight.add(done)
        assertTrue(inFlight.snapshot().isEmpty())
    }

    private fun event(id: String) = JSONObject()
        .put("event_id", id)
        .put("device_id", "dev_fixture")
        .put("event_name", "purchase")
        .put("properties", JSONObject())
        .put("timestamp", "2026-09-21T18:58:08.303Z")
        .put("sdk_version", TreebarsConstants.SDK_VERSION)

    @Test
    fun `an event queued while a batch is on the wire goes out in the same drain, not with a later one`() = runBlocking {
        val directory = temp.newFolder()
        val queue = EventQueue(directory)
        queue.append(event("first"))

        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val sent = Collections.synchronizedList(mutableListOf<List<String>>())
        val transport = EventTransport { batch ->
            val events = batch.getJSONArray("events")
            val ids = (0 until events.length()).map { events.getJSONObject(it).getString("event_id") }
            val firstSend = sent.isEmpty()
            sent += ids
            if (firstSend) {
                started.countDown()
                check(release.await(10, TimeUnit.SECONDS)) { "the first send was never released" }
            }
            UploadResponse(200)
        }
        // No wake scope and no pace: nothing but the flushes themselves may send, so nothing else can be what rescued it.
        val uploader = EventUploader(queue, transport, UploaderStore(directory), writeKey = "pk_test_fixture", ioContext = Dispatchers.IO)

        val running = async(Dispatchers.Default) { uploader.flush() }
        check(started.await(10, TimeUnit.SECONDS)) { "the first drain never sent" }

        // The purchase lands while the first batch is on the wire, and its own flush finds the drain busy and returns.
        queue.append(event("purchase"))
        withTimeout(5_000) { uploader.flush() }
        assertEquals("the busy flush sent nothing itself", 1, sent.size)

        release.countDown()
        withTimeout(10_000) { running.await() }
        assertEquals(listOf(listOf("first"), listOf("purchase")), sent.toList())
    }
}
