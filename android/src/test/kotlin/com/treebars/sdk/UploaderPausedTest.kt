package com.treebars.sdk

import com.treebars.sdk.generated.TreebarsConstants
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * An opted-out install sends nothing, whoever asks for a flush — the public `Treebars.flush()`, the
 * timer, the lifecycle, a wake or the flush on the way up — so events an earlier launch left behind
 * never go out once the install has said no. The gate is in the uploader (`paused`), asked before
 * each batch.
 */
@RunWith(RobolectricTestRunner::class)
class UploaderPausedTest {
    @get:Rule
    val temp = TemporaryFolder()

    private fun event(id: String): JSONObject = JSONObject()
        .put("event_id", id)
        .put("device_id", "dev_paused")
        .put("event_name", "evt_$id")
        .put("properties", JSONObject())
        .put("timestamp", "2026-09-25T12:00:00.000Z")
        .put("sdk_version", TreebarsConstants.SDK_VERSION)

    @Test
    fun `sends nothing while paused, and everything once it is not`() = runBlocking {
        val directory = temp.newFolder()
        val queue = EventQueue(directory)
        queue.append(event("e1"))
        queue.append(event("e2"))
        val sent = mutableListOf<String>()
        var paused = true
        val uploader = EventUploader(
            queue = queue,
            transport = EventTransport { batch ->
                sent += batch.getString("batch_id")
                UploadResponse(200)
            },
            store = UploaderStore(directory),
            writeKey = "pk_test_paused",
            clock = { 1_790_000_000_000L },
            paused = { paused },
        )

        uploader.flush()
        assertEquals(emptyList<String>(), sent)
        assertEquals(2, queue.size())

        paused = false
        uploader.flush()
        assertEquals(1, sent.size)
        assertEquals(0, queue.size())
        assertEquals(0, uploader.pendingEvents())
    }

    @Test
    fun `stops a drain already running at the next batch`() = runBlocking {
        val directory = temp.newFolder()
        val queue = EventQueue(directory)
        repeat(3) { queue.append(event("e$it")) }
        var paused = false
        val sent = mutableListOf<String>()
        val uploader = EventUploader(
            queue = queue,
            transport = EventTransport { batch ->
                sent += batch.getString("batch_id")
                // The opt-out, arriving while this request is out.
                paused = true
                UploadResponse(200)
            },
            store = UploaderStore(directory),
            writeKey = "pk_test_paused",
            batchSize = 2,
            clock = { 1_790_000_000_000L },
            paused = { paused },
        )

        uploader.flush()
        assertEquals(1, sent.size)
        assertEquals(1, queue.size())
    }

    @Test
    fun `forgets a stored queue before anything reads it`() = runBlocking {
        val directory = temp.newFolder()
        EventQueue(directory).append(event("left_behind"))

        EventQueue.forget(directory)

        assertEquals(0, EventQueue(directory).size())
    }
}
