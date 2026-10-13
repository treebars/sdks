package com.treebars.sdk

import java.io.IOException
import kotlin.coroutines.EmptyCoroutineContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/*
 * Where remote config hears that a newer config exists: an accepted upload's answer.
 *
 * The shared scenarios start from "an upload's answer named version 4". This pins the step before that — that
 * the uploader tells remote config after a drain in which an upload was ACCEPTED, with the version its answers
 * named or with none, and tells it nothing after a drain the endpoint refused or never reached. Without the
 * second half, an ingest that is down would have every install ask it for config as often as it tries to upload.
 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
class ConfigVersionTest {

    @Rule
    @JvmField
    val temp = TemporaryFolder()

    private fun event(id: String): JSONObject = JSONObject()
        .put("event_id", id)
        .put("session_id", "s1")
        .put("device_id", "dev_fixture")
        .put("event_name", "screen_view")
        .put("properties", JSONObject())
        .put("timestamp", "2026-09-15T12:00:00.000Z")

    /** One event queued and one drain, answered by [answer]; what remote config was told, in order. */
    private fun told(answer: () -> UploadResponse): List<String?> {
        val directory = temp.newFolder()
        val scheduler = TestCoroutineScheduler()
        val scope = CoroutineScope(StandardTestDispatcher(scheduler) + Job())
        val heard = mutableListOf<String?>()
        val queue = EventQueue(directory)
        runBlocking { queue.append(event("e1")) }
        val uploader = EventUploader(
            queue = queue,
            transport = EventTransport { answer() },
            store = UploaderStore(directory),
            writeKey = "pk_test_fixture",
            scope = scope,
            ioContext = EmptyCoroutineContext,
            configSeen = { version -> heard += version },
        )
        scope.launch { uploader.flush() }
        scheduler.runCurrent()
        return heard
    }

    @Test
    fun `an accepted upload tells remote config the version its answer named`() {
        assertEquals(listOf<String?>("7"), told { UploadResponse(200, configVersion = "7") })
    }

    @Test
    fun `an accepted upload that names no version still says so, so an ask that is owed can be made`() {
        assertEquals(listOf<String?>(null), told { UploadResponse(200) })
    }

    @Test
    fun `a refused upload and one that never arrived tell it nothing`() {
        assertEquals(emptyList<String?>(), told { UploadResponse(503, retryAfter = "60", configVersion = "7") })
        assertEquals(emptyList<String?>(), told { UploadResponse(401) })
        assertEquals(emptyList<String?>(), told { throw IOException("network unreachable") })
    }
}
