package com.treebars.sdk

import android.content.Context
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import com.treebars.sdk.generated.TreebarsConstants
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.zip.GZIPInputStream
import kotlin.concurrent.thread

/**
 * The context token (`Treebars.contextToken()`), driven through the real SDK against a real socket.
 *
 * A socket rather than a fake transport because the headers are the point: the token request carries the device
 * secret and the signature exactly as `/v1/identify` sends them, and a seam above `HttpURLConnection` could only
 * assert what the SDK meant to send. A bare `ServerSocket`
 * rather than the JDK's `HttpServer`, which a unit test compiled against android.jar cannot see.
 *
 * Events are read from the queue file AND from whatever reached `/v1/events`: a flush loop left running by an
 * earlier suite in this JVM can seal the queue mid-test, and a check that read the file alone would call that
 * a missing event.
 */
@RunWith(RobolectricTestRunner::class)
class ContextTokenTest {

    private class Request(val method: String, val path: String, val headers: Map<String, String>, val body: String)

    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val prefs get() = context.getSharedPreferences(Treebars.PREFS_NAME, Context.MODE_PRIVATE)

    private val requests = CopyOnWriteArrayList<Request>()
    @Volatile
    private var tokenAnswer: Pair<Int, String> = 201 to """{"token":"5B0E4C4A-9F1D-4E0B-A0D4-3C1E2F6A7B8C"}"""
    private lateinit var server: ServerSocket

    /** One request, answered and closed: what the SDK sends is all this has to understand. */
    private fun serve(socket: Socket) = socket.use {
        val input = socket.getInputStream().buffered()
        val head = generateSequence { line(input) }.takeWhile { it.isNotEmpty() }.toList()
        val (method, target) = head.first().split(" ")
        val headers = head.drop(1).associate { it.substringBefore(":").trim().lowercase() to it.substringAfter(":").trim() }
        val raw = ByteArray(headers["content-length"]?.toInt() ?: 0).also { bytes ->
            var read = 0
            while (read < bytes.size) read += input.read(bytes, read, bytes.size - read).also { if (it < 0) error("short body") }
        }
        val body = String(if (headers["content-encoding"] == "gzip") GZIPInputStream(raw.inputStream()).readBytes() else raw)
        val path = target.substringBefore("?")
        requests += Request(method, path, headers, body)
        val (status, answer) = when (path) {
            TreebarsConstants.CONTEXT_TOKEN_PATH -> tokenAnswer
            TreebarsConstants.EVENTS_PATH, TreebarsConstants.IDENTIFY_PATH -> 200 to """{"ok":true}"""
            else -> 404 to "{}"
        }
        val bytes = answer.toByteArray()
        socket.getOutputStream().apply {
            write("HTTP/1.1 $status X\r\nContent-Type: application/json\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n".toByteArray())
            write(bytes)
            flush()
        }
    }

    private fun line(input: InputStream): String? {
        val out = ByteArrayOutputStream()
        while (true) {
            val byte = input.read()
            if (byte < 0) return if (out.size() == 0) null else out.toString()
            if (byte == '\n'.code) return out.toString().removeSuffix("\r")
            out.write(byte)
        }
    }

    @Before
    fun start() {
        server = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
        thread(isDaemon = true) {
            while (!server.isClosed) {
                val socket = runCatching { server.accept() }.getOrNull() ?: break
                thread(isDaemon = true) { runCatching { serve(socket) } }
            }
        }

        prefs.edit().clear().commit()
        File(context.filesDir, EventQueue.FILE_NAME).delete()
        File(context.filesDir, TreebarsConstants.UPLOADER_FILE).delete()
        Treebars.initialize(
            context,
            "pk_test_context_token",
            "http://127.0.0.1:${server.localPort}",
            flushIntervalMs = 3_600_000,
            autoTrackLifecycle = false,
            inAppPollIntervalMs = 0,
        )
        // The launch's own records — its session and the device report — before any test looks at a session.
        settle { events().any { it.optString("event_name") == "device_context" } }
    }

    @After
    fun stop() {
        Treebars.optIn()
        Treebars.reset()
        Treebars::class.java.getDeclaredField("writeKey").apply { isAccessible = true }.set(Treebars, null)
        server.close()
    }

    private fun settle(done: () -> Boolean) {
        val until = System.currentTimeMillis() + 3_000
        while (System.currentTimeMillis() < until) {
            shadowOf(Looper.getMainLooper()).idle()
            if (done()) return
            Thread.sleep(25)
        }
    }

    /** Every event this install has recorded and not lost: still queued, or already uploaded. */
    private fun events(): List<JSONObject> {
        val queued = File(context.filesDir, EventQueue.FILE_NAME)
            .takeIf { it.exists() }
            ?.let { file -> JSONArray(file.readText()).let { all -> (0 until all.length()).map { all.getJSONObject(it) } } }
            .orEmpty()
        val uploaded = requests.filter { it.path == TreebarsConstants.EVENTS_PATH }.flatMap { request ->
            JSONObject(request.body).getJSONArray("events").let { all -> (0 until all.length()).map { all.getJSONObject(it) } }
        }
        return (queued + uploaded).distinctBy { it.getString("event_id") }
    }

    private fun tokenRequests() = requests.filter { it.path == TreebarsConstants.CONTEXT_TOKEN_PATH }

    @Test
    fun `asks ingest for this device and its session, and hands back the token lower-cased`() {
        val session = prefs.getString(TreebarsConstants.KEY_SESSION_ID, null)
        val token = runBlocking { Treebars.contextToken() }

        assertEquals("5b0e4c4a-9f1d-4e0b-a0d4-3c1e2f6a7b8c", token)
        val request = tokenRequests().single()
        assertEquals("POST", request.method)
        val body = JSONObject(request.body)
        assertEquals(events().first().getString("device_id"), body.getString("device_id"))
        assertEquals(session, body.getString("session_id"))
        assertFalse("nobody is signed in, so no account is named", body.has("user_id"))
        assertEquals("pk_test_context_token", request.headers[TreebarsConstants.WRITE_KEY_HEADER.lowercase()])
        assertTrue(
            "the device proves itself as a sign-in does",
            !request.headers[TreebarsConstants.DEVICE_AUTH_HEADER.lowercase()].isNullOrEmpty(),
        )
        assertNull(request.headers[TreebarsConstants.USER_SIGNATURE_HEADER.lowercase()])
    }

    @Test
    fun `a signed-in person is named, with the signature their backend made`() {
        Treebars.identify("user_42", signature = "sig_for_user_42")
        val token = runBlocking { Treebars.contextToken() }

        assertEquals("5b0e4c4a-9f1d-4e0b-a0d4-3c1e2f6a7b8c", token)
        val request = tokenRequests().single()
        assertEquals("user_42", JSONObject(request.body).getString("user_id"))
        assertEquals("sig_for_user_42", request.headers[TreebarsConstants.USER_SIGNATURE_HEADER.lowercase()])
        // Identical to what the sign-in itself sent, which is the whole reason the two share one post.
        settle { requests.any { it.path == TreebarsConstants.IDENTIFY_PATH } }
        val identify = requests.first { it.path == TreebarsConstants.IDENTIFY_PATH }
        for (header in listOf(TreebarsConstants.DEVICE_AUTH_HEADER, TreebarsConstants.USER_SIGNATURE_HEADER)) {
            assertEquals(header, identify.headers[header.lowercase()], request.headers[header.lowercase()])
        }
    }

    @Test
    fun `nothing is asked while opted out`() {
        Treebars.optOut()
        assertNull(runBlocking { Treebars.contextToken() })
        assertTrue(tokenRequests().isEmpty())
    }

    @Test
    fun `a refusal or an answer without a token is null, and the purchase goes ahead without one`() {
        tokenAnswer = 503 to """{"error":"identity_unavailable"}"""
        assertNull(runBlocking { Treebars.contextToken() })
        tokenAnswer = 403 to """{"error":"signature_required"}"""
        assertNull(runBlocking { Treebars.contextToken() })
        tokenAnswer = 201 to """{"ok":true}"""
        assertNull(runBlocking { Treebars.contextToken() })
        assertEquals(3, tokenRequests().size)
    }

    @Test
    fun `inside the session the token names it, extends it, and counts as none of its events`() {
        val session = prefs.getString(TreebarsConstants.KEY_SESSION_ID, null)
        val count = prefs.getInt(TreebarsConstants.KEY_SESSION_EVENT_COUNT, -1)
        val before = events().size

        runBlocking { Treebars.contextToken() }

        assertEquals(session, JSONObject(tokenRequests().single().body).getString("session_id"))
        assertEquals(session, prefs.getString(TreebarsConstants.KEY_SESSION_ID, null))
        assertEquals("a token is not an event", count, prefs.getInt(TreebarsConstants.KEY_SESSION_EVENT_COUNT, -1))
        assertEquals("and queues none", before, events().size)
    }

    @Test
    fun `after the gap the token closes the old session and opens the one the purchase lands in`() {
        val expired = prefs.getString(TreebarsConstants.KEY_SESSION_ID, null)!!
        val lastActivity = System.currentTimeMillis() - TreebarsConstants.SESSION_TIMEOUT_MS - 60_000
        prefs.edit()
            .putLong(TreebarsConstants.KEY_SESSION_STARTED_AT, lastActivity - 300_000)
            .putLong(TreebarsConstants.KEY_SESSION_LAST_ACTIVITY_AT, lastActivity)
            .putInt(TreebarsConstants.KEY_SESSION_EVENT_COUNT, 7)
            .commit()

        runBlocking { Treebars.contextToken() }

        val opened = prefs.getString(TreebarsConstants.KEY_SESSION_ID, null)!!
        assertNotEquals(expired, opened)
        assertEquals("the token names the new session", opened, JSONObject(tokenRequests().single().body).getString("session_id"))
        settle { events().any { it.optString("session_id") == opened } }

        val end = events().single { it.optString("event_name") == Treebars.EVENT_SESSION_END }
        assertEquals(expired, end.getString("session_id"))
        assertEquals(7, end.getJSONObject("properties").getInt("event_count"))
        assertEquals(300_000, end.getJSONObject("properties").getLong("duration_ms"))
        assertEquals("backdated to the session's own last moment", Iso8601.at(lastActivity), end.getString("timestamp"))

        assertEquals(
            "the new session holds its start and nothing for the token",
            listOf(Treebars.EVENT_SESSION_START),
            events().filter { it.optString("session_id") == opened }.map { it.getString("event_name") },
        )
        assertEquals(0, prefs.getInt(TreebarsConstants.KEY_SESSION_EVENT_COUNT, -1))
    }
}

/** The session half alone, on a clock the test moves: what `touch(isEvent = false)` does to the count and the gap. */
@RunWith(RobolectricTestRunner::class)
class ContextTokenSessionTest {

    private var now = 1_000_000_000_000L
    private val minute = 60_000L

    private fun sessions(): SessionManager {
        val prefs = ApplicationProvider.getApplicationContext<Context>()
            .getSharedPreferences("context-token-sessions", Context.MODE_PRIVATE)
        prefs.edit().clear().commit()
        return SessionManager(prefs) { now }
    }

    @Test
    fun `a token extends the session it falls in without counting itself`() {
        val sessions = sessions()
        val opened = sessions.touch().sessionId
        now += 20 * minute
        assertEquals(opened, sessions.touch(isEvent = false).sessionId)

        // Twenty-five minutes after the token, forty-five after the event: alive only because the token moved it.
        now += 25 * minute
        assertEquals(opened, sessions.touch().sessionId)

        now += 31 * minute
        val next = sessions.touch()
        assertEquals(opened, next.expired?.id)
        assertEquals("two events; the token is not one", 2, next.expired?.eventCount)
    }

    @Test
    fun `a session a token opened starts with no events in it`() {
        val sessions = sessions()
        val first = sessions.touch()
        now += 31 * minute
        val opened = sessions.touch(isEvent = false)
        assertTrue(opened.isNew)
        assertEquals(first.sessionId, opened.expired?.id)

        now += minute
        sessions.touch()
        now += 31 * minute
        assertEquals("the one event after the token", 1, sessions.touch().expired?.eventCount)
    }
}
