package com.treebars.sdk

import com.treebars.sdk.generated.TreebarsConstants
import java.io.File
import java.io.IOException
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.RobolectricTestRunner

/*
 * The shared upload scenarios, run against this core.
 *
 * The same `uploader-scenarios.json` drives `sdks/web` and the iOS SDK too, and that is the
 * point of it being data: three implementations of one policy agree only
 * if each is asked the same questions. The transport is scripted, the clock and the jitter are
 * handed in, and what is asserted is read back from a fresh `UploaderStore` and `EventQueue` over
 * the same directory — what a relaunch would find, not what this uploader holds in memory.
 *
 * The fixture is found by walking up from the working directory, which Gradle sets to this
 * module. It is parsed inside each test rather than in the parameters method, because that
 * method runs outside Robolectric's
 * sandbox, where `org.json` is the android.jar stub and every getter quietly answers null.
 */
internal fun uploaderFixtureFile(): File =
    File(requireNotNull(Thread.currentThread().contextClassLoader?.getResource("bridge/uploader-scenarios.json")) {
        "the shared fixture bridge/uploader-scenarios.json is missing from the test resources"
    }.toURI())

@RunWith(RobolectricTestRunner::class)
class UploaderPolicyFixtureTest {

    /*
     * The numbers in the scenarios are consequences of the policy. If the generated constants
     * moved and the fixture did not, every expectation would be checking the wrong arithmetic.
     */
    @Test
    fun `the generated policy is the one the scenarios were derived from`() {
        val policy = JSONObject(uploaderFixtureFile().readText()).getJSONObject("policy")
        fun ints(name: String) = policy.getJSONArray(name).let { array -> (0 until array.length()).map { array.getInt(it) } }

        assertEquals(policy.getInt("batch_size"), TreebarsConstants.BATCH_SIZE)
        assertEquals(policy.getInt("drain_max_batches"), TreebarsConstants.DRAIN_MAX_BATCHES)
        assertEquals(policy.getLong("backoff_base_seconds"), TreebarsConstants.BACKOFF_BASE_SECONDS)
        assertEquals(policy.getLong("backoff_cap_seconds"), TreebarsConstants.BACKOFF_CAP_SECONDS)
        assertEquals(ints("retry_after_statuses"), TreebarsConstants.RETRY_AFTER_STATUSES.toList())
        assertEquals(policy.getLong("retry_after_max_seconds"), TreebarsConstants.RETRY_AFTER_MAX_SECONDS)
        assertEquals(ints("auth_statuses"), TreebarsConstants.AUTH_STATUSES.toList())
        assertEquals(policy.getLong("auth_cooldown_seconds"), TreebarsConstants.AUTH_COOLDOWN_SECONDS)
    }

    /*
     * The HTTP date is computed by hand here and in the other two cores, so none of them inherits
     * a platform parser's leniency. Checked against the JVM's own clock arithmetic across two
     * thousand instants — the scenarios can only afford two dates.
     */
    @Test
    fun `an IMF-fixdate reads as the instant it names`() {
        val format = java.text.SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss 'GMT'", java.util.Locale.US).apply {
            timeZone = java.util.TimeZone.getTimeZone("UTC")
        }
        var seed = 7L
        repeat(2000) {
            seed = (seed * 48271) % 2147483647
            val at = 31_536_000_000L + seed * 1000
            val text = format.format(java.util.Date(at))
            assertEquals(text, at, retryAfterDelayMs(text, 0))
        }
    }
}

@RunWith(ParameterizedRobolectricTestRunner::class)
class UploaderScenariosTest(private val id: String) {

    companion object {
        /** Ids only — see the note above on why nothing here may touch `org.json`. */
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}")
        fun scenarios(): List<Array<Any>> =
            Regex("\"id\":\\s*\"(UP-\\d+)\"").findAll(uploaderFixtureFile().readText())
                .map { arrayOf<Any>(it.groupValues[1]) }
                .toList()
    }

    @Rule
    @JvmField
    val temp = TemporaryFolder()

    private data class Shape(val batchId: String, val events: List<String>)

    private class Sent(val batch: JSONObject, val status: Int?)

    private fun JSONArray.strings(): List<String> = (0 until length()).map { getString(it) }

    private fun JSONObject.shape() = Shape(getString("batch_id"), getJSONArray("events").let { events ->
        (0 until events.length()).map { events.getJSONObject(it).getString("event_id") }
    })

    private fun shapes(array: JSONArray?): List<Shape> =
        if (array == null) emptyList() else (0 until array.length()).map { index ->
            val each = array.getJSONObject(index)
            Shape(each.getString("batch_id"), each.getJSONArray("events").strings())
        }

    /** Key order is an implementation detail of whichever parser last touched the object. */
    private fun canonical(value: Any?): String = when (value) {
        is JSONObject -> value.keys().asSequence().sorted()
            .joinToString(",", "{", "}") { "\"$it\":${canonical(value.opt(it))}" }
        is JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { canonical(value.opt(it)) }
        is String -> JSONObject.quote(value)
        else -> value.toString()
    }

    private fun event(id: String): JSONObject = JSONObject()
        .put("event_id", id)
        .put("session_id", "s1")
        .put("device_id", "dev_fixture")
        .put("event_name", "evt_$id")
        .put("properties", JSONObject().put("id", id))
        .put("timestamp", "2026-09-15T12:00:00.000Z")
        .put("sdk_version", TreebarsConstants.SDK_VERSION)

    @Test
    fun `agrees with the shared scenario`() {
        val fixture = JSONObject(uploaderFixtureFile().readText())
        val scenarios = fixture.getJSONArray("scenarios")
        val scenario = (0 until scenarios.length()).map { scenarios.getJSONObject(it) }.single { it.getString("id") == id }

        val platforms = scenario.optJSONArray("platforms")?.strings()
        if (platforms != null && "android" !in platforms) {
            // A page-hide scenario. Asserted rather than skipped silently, so a scenario that
            // stopped naming its platform would start running here and fail loudly instead.
            assertTrue("$id is for ${platforms.joinToString()}", platforms.all { it == "web" })
            return
        }

        val epoch = fixture.getLong("epoch_ms")
        val directory = temp.newFolder()
        var writeKey = scenario.optString("write_key").takeIf { it.isNotEmpty() } ?: fixture.getString("write_key")
        val batchSize = scenario.optInt("batch_size", TreebarsConstants.BATCH_SIZE)

        var now = epoch
        var minted = 0
        val responses = ArrayDeque<JSONObject>()
        val randoms = ArrayDeque<Double>()
        // Recorded rather than thrown where they happen: the uploader treats a transport that
        // throws as a network failure, so a throw would surface as whatever the policy did next.
        val unscripted = mutableListOf<String>()
        val sent = mutableListOf<Sent>()
        val firstSend = mutableMapOf<String, String>()

        val transport = EventTransport { batch ->
            val shape = batch.shape()
            // Invariant one: the batch on the wire is already the persisted head.
            val head = UploaderStore(directory).load().pending.firstOrNull()
            assertEquals("$id: ${shape.batchId} was sent before it was the persisted head", shape,
                head?.let { Shape(it.batchId, it.events.map { e -> e.getString("event_id") }) })
            // Invariant two: every send of one id carries what its first send carried.
            val carried = canonical(JSONObject().put("sent_at", batch.getString("sent_at")).put("events", batch.getJSONArray("events")))
            val first = firstSend.getOrPut(shape.batchId) { carried }
            assertEquals("$id: ${shape.batchId} changed between sends", first, carried)

            val next = responses.removeFirstOrNull()
            if (next == null) {
                unscripted += "a request for ${shape.batchId}"
                throw IOException("no response scripted")
            }
            val failed = next.optBoolean("network_error", false)
            sent += Sent(batch, if (failed) null else next.getInt("status"))
            if (failed) throw IOException("network unreachable")
            UploadResponse(next.getInt("status"), if (next.has("retry_after")) next.getString("retry_after") else null)
        }

        var queue = EventQueue(directory)
        runBlocking { scenario.getJSONArray("queue").strings().forEach { queue.append(event(it)) } }

        fun build() = EventUploader(
            queue = queue,
            transport = transport,
            store = UploaderStore(directory),
            writeKey = writeKey,
            batchSize = batchSize,
            clock = { now },
            random = {
                randoms.removeFirstOrNull() ?: run {
                    unscripted += "a random draw"
                    0.0
                }
            },
            newBatchId = { "b${++minted}" },
        )
        var uploader = build()

        fun offset(value: Long): Long? = if (value == 0L) null else value - epoch

        fun verify(label: String, expected: JSONObject, full: Boolean) {
            val state = UploaderStore(directory).load()
            val pending = state.pending.map { Shape(it.batchId, it.events.map { e -> e.getString("event_id") }) }
            val queued = runBlocking { EventQueue(directory).peek(Int.MAX_VALUE) }.map { it.getString("event_id") }

            if (full || expected.has("sent")) {
                assertEquals("$label: sent", shapes(expected.optJSONArray("sent")), sent.map { it.batch.shape() })
            }
            if (full || expected.has("pending")) {
                assertEquals("$label: pending", shapes(expected.optJSONArray("pending")), pending)
            }
            if (full || expected.has("queue")) {
                assertEquals("$label: queue", expected.optJSONArray("queue")?.strings() ?: emptyList<String>(), queued)
            }
            if (full || expected.has("attempt")) {
                assertEquals("$label: attempt", expected.optInt("attempt", 0), state.attempt)
            }
            if (full || expected.has("next_allowed_at")) {
                val want = if (expected.isNull("next_allowed_at")) null else expected.getLong("next_allowed_at")
                assertEquals("$label: next_allowed_at", want, offset(state.nextAllowedAt))
            }
            if (full || expected.has("auth_blocked_until")) {
                val want = if (expected.isNull("auth_blocked_until")) null else expected.getLong("auth_blocked_until")
                assertEquals("$label: auth_blocked_until", want, offset(state.authBlockedUntil))
            }
            if (full || expected.has("dropped")) {
                // Sent in this step, never acknowledged, and now in neither store.
                val acknowledged = sent.filter { it.status != null && it.status in 200..299 }
                    .flatMap { it.batch.shape().events }.toSet()
                val kept = (pending.flatMap { it.events } + queued).toSet()
                val dropped = sent.flatMap { it.batch.shape().events }.distinct()
                    .filter { it !in acknowledged && it !in kept }
                assertEquals("$label: dropped", expected.optJSONArray("dropped")?.strings() ?: emptyList<String>(), dropped)
            }
        }

        val steps = scenario.getJSONArray("steps")
        for (index in 0 until steps.length()) {
            val step = steps.getJSONObject(index)
            val action = step.getString("do")
            val label = "$id step ${index + 1} ($action)"
            val expected = step.optJSONObject("expect") ?: JSONObject()
            sent.clear()
            unscripted.clear()

            when (action) {
                "flush" -> {
                    now = epoch + step.getLong("at")
                    responses.clear()
                    step.optJSONArray("responses")?.let { array ->
                        (0 until array.length()).forEach { responses.addLast(array.getJSONObject(it)) }
                    }
                    randoms.clear()
                    step.optJSONArray("random")?.let { array ->
                        (0 until array.length()).forEach { randoms.addLast(array.getDouble(it)) }
                    }

                    runBlocking { uploader.flush() }

                    assertEquals("$label: not in the scenario", emptyList<String>(), unscripted)
                    assertEquals("$label: responses never asked for", 0, responses.size)
                    assertEquals("$label: random values never drawn", 0, randoms.size)
                    verify(label, expected, full = true)
                }
                "track" -> {
                    runBlocking { step.getJSONArray("events").strings().forEach { queue.append(event(it)) } }
                    if (step.has("expect")) verify(label, expected, full = false)
                }
                "relaunch" -> {
                    step.optString("write_key").takeIf { it.isNotEmpty() }?.let { writeKey = it }
                    queue = EventQueue(directory)
                    uploader = build()
                    if (step.has("expect")) verify(label, expected, full = false)
                }
                else -> error("$label: `$action` is not a step this core can take")
            }
        }
    }
}
