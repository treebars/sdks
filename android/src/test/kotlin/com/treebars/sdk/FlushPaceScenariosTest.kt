package com.treebars.sdk

import com.treebars.sdk.generated.TreebarsConstants
import java.io.File
import java.io.IOException
import kotlin.coroutines.EmptyCoroutineContext
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
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
 * The shared pace scenarios, run against this core.
 *
 * The same `flush-pace-scenarios.json` drives `sdks/web` and the iOS SDK too. What runs here is the
 * pace wired to the real uploader exactly as `Treebars.initialize` wires them: the pace asks the
 * uploader to send and reads the spacing its answers named, the uploader tells the pace as each
 * request leaves and when an upload ends with events still waiting, and an event on the queue is
 * announced to both — then a full batch is flushed at once. So a scenario fails for a pace that is
 * wrong and equally for a wiring that drops one of those lines: an uploader that never said a
 * request left would send the second event of most scenarios a spacing early.
 *
 * Both wakes — the pace's, and the uploader's for a listed event — are real coroutines on a test
 * dispatcher, sleeping in `delay`, and time moves only when a step moves it. The send runs on that
 * dispatcher too (`ioContext`), because on a real IO thread it would finish outside the virtual
 * clock.
 */
internal fun flushPaceFixtureFile(): File =
    File(requireNotNull(Thread.currentThread().contextClassLoader?.getResource("bridge/flush-pace-scenarios.json")) {
        "the shared fixture bridge/flush-pace-scenarios.json is missing from the test resources"
    }.toURI())

@RunWith(RobolectricTestRunner::class)
class FlushPacePolicyFixtureTest {

    /*
     * The numbers in the scenarios are consequences of the policy. Every key is checked and no
     * other is allowed, so a number added to the fixture's policy fails here until this core reads
     * it from its constants too.
     */
    @Test
    fun `the generated policy is the one the pace scenarios were derived from`() {
        val policy = JSONObject(flushPaceFixtureFile().readText()).getJSONObject("policy")
        val generated = mapOf(
            "debounce_ms" to TreebarsConstants.FLUSH_DEBOUNCE_MS,
            "spacing_ms" to TreebarsConstants.FLUSH_SPACING_MS,
            "spacing_metered_ms" to TreebarsConstants.FLUSH_SPACING_METERED_MS,
            "spacing_test_ms" to TreebarsConstants.FLUSH_SPACING_TEST_MS,
            // A device saving power or data keeps the interval every device kept before there was a pace.
            "spacing_constrained_ms" to TreebarsConstants.DEFAULT_FLUSH_INTERVAL_MS,
            "spacing_min_ms" to TreebarsConstants.FLUSH_SPACING_MIN_MS,
            "spacing_max_ms" to TreebarsConstants.FLUSH_SPACING_MAX_MS,
            "batch_size" to TreebarsConstants.BATCH_SIZE.toLong(),
        )
        assertEquals(generated.keys, policy.keys().asSequence().toSet())
        for ((name, value) in generated) assertEquals(name, value, policy.getLong(name))
        // A listed event waits the same second and differs only in ignoring the spacing; the scenarios assume it.
        assertEquals(TreebarsConstants.FLUSH_DEBOUNCE_MS, TreebarsConstants.TRIGGER_FLUSH_DEBOUNCE_MS)
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(ParameterizedRobolectricTestRunner::class)
class FlushPaceScenariosTest(private val id: String) {

    companion object {
        /** Ids only — the parameters method runs outside Robolectric's sandbox, where `org.json` is a stub. */
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}")
        fun scenarios(): List<Array<Any>> =
            Regex("\"id\":\\s*\"(FP-\\d+)\"").findAll(flushPaceFixtureFile().readText())
                .map { arrayOf<Any>(it.groupValues[1]) }
                .toList()

        /** The one name on the stored trigger list, and a name that is not on it. */
        private const val LISTED = "purchase"
        private const val UNLISTED = "screen_view"
    }

    @Rule
    @JvmField
    val temp = TemporaryFolder()

    private fun JSONArray.strings(): List<String> = (0 until length()).map { getString(it) }

    private fun event(id: String, name: String): JSONObject = JSONObject()
        .put("event_id", id)
        .put("session_id", "s1")
        .put("device_id", "dev_fixture")
        .put("event_name", name)
        .put("properties", JSONObject())
        .put("timestamp", "2026-09-15T12:00:00.000Z")
        .put("sdk_version", TreebarsConstants.SDK_VERSION)

    @Test
    fun `agrees with the shared scenario`() {
        val fixture = JSONObject(flushPaceFixtureFile().readText())
        val all = fixture.getJSONArray("scenarios")
        val scenario = (0 until all.length()).map { all.getJSONObject(it) }.single { it.getString("id") == id }

        val epoch = fixture.getLong("epoch_ms")
        val directory = temp.newFolder()
        // A real key of each kind, so the prefix test that picks the spacing is part of what runs.
        val writeKey = when (val key = scenario.optString("key", "live")) {
            "live" -> "pk_live_fixture0000000000000000"
            "test" -> "pk_test_fixture0000000000000000"
            else -> error("$id: `$key` is not a kind of key this core knows")
        }
        val network = when (val named = scenario.optString("network", "unmetered")) {
            "unmetered" -> UploadConditions()
            "metered" -> UploadConditions(metered = true)
            "constrained" -> UploadConditions(constrained = true)
            else -> error("$id: `$named` is not a network this core knows")
        }
        // Absent is the app choosing none, said the way `initialize`'s own default says it.
        val chosen = if (scenario.has("flush_interval_ms")) scenario.getLong("flush_interval_ms") else Treebars.SDK_PACE
        val batchSize = scenario.optInt("batch_size", TreebarsConstants.BATCH_SIZE)

        val scheduler = TestCoroutineScheduler()
        val dispatcher = StandardTestDispatcher(scheduler)
        val clock = { epoch + scheduler.currentTime }
        // Failures inside a wake are collected, not thrown on a dispatcher thread nobody watches.
        val failures = mutableListOf<String>()
        val handler = CoroutineExceptionHandler { _, error -> failures += "a wake threw: $error" }
        val process = Job()
        fun scope() = CoroutineScope(dispatcher + process + handler)

        var minted = 0
        val responses = ArrayDeque<JSONObject>()
        val unscripted = mutableListOf<String>()
        val sent = mutableListOf<List<String>>()

        check(TriggerStore(directory).save(TriggerList("v1", listOf(LISTED))))

        val transport = EventTransport { batch ->
            val events = batch.getJSONArray("events")
            val ids = (0 until events.length()).map { events.getJSONObject(it).getString("event_id") }
            val next = responses.removeFirstOrNull()
            if (next == null) {
                unscripted += "an upload of $ids"
                throw IOException("no response scripted")
            }
            sent += ids
            UploadResponse(
                status = next.getInt("status"),
                flushSpacing = if (next.has("flush_ms")) next.getLong("flush_ms").toString() else null,
            )
        }

        val tracked = mutableListOf<String>()
        val delivered = mutableListOf<String>()

        // What storage holds before the first step: an earlier launch's events, which nothing here announces.
        val queue = EventQueue(directory)
        scenario.optJSONArray("queue")?.strings()?.forEach { eventId ->
            tracked += eventId
            runBlocking { queue.append(event(eventId, UNLISTED)) }
        }
        val triggers = TriggerEvents(TriggerStore(directory)) {
            // No answer here names a list version, so nothing should ever ask for the list.
            unscripted += "a trigger list fetch"
            null
        }

        /* The pace and the uploader, each handed the other — `Treebars.initialize`, line for line. */
        lateinit var uploader: EventUploader
        val pace = FlushPace(
            scope = scope(),
            chosenMs = chosen,
            testKey = isTestWriteKey(writeKey),
            conditions = { network },
            named = { uploader.spacingMs },
            upload = { uploader.flushInTurn() },
            clock = clock,
        )
        uploader = EventUploader(
            queue = queue,
            transport = transport,
            store = UploaderStore(directory),
            writeKey = writeKey,
            batchSize = batchSize,
            clock = clock,
            random = {
                unscripted += "a random draw"
                // Not zero: a failure retried after no delay would fall due again at once, for ever.
                0.5
            },
            newBatchId = { "b${++minted}" },
            scope = scope(),
            ioContext = EmptyCoroutineContext,
            triggers = triggers,
            uploadBegan = pace::uploadBegan,
            backlogLeft = pace::backlogLeft,
        )

        /* Moves virtual time to `at`, running every wake that falls due on the way, in order. */
        fun advanceTo(at: Long) {
            val delta = at - scheduler.currentTime
            if (delta > 0) scheduler.advanceTimeBy(delta)
            scheduler.runCurrent()
        }

        val steps = scenario.getJSONArray("steps")
        for (index in 0 until steps.length()) {
            val step = steps.getJSONObject(index)
            val action = step.getString("do")
            val label = "$id step ${index + 1} ($action)"

            sent.clear()
            unscripted.clear()
            failures.clear()
            responses.clear()
            step.optJSONArray("responses")?.let { array -> (0 until array.length()).forEach { responses.addLast(array.getJSONObject(it)) } }

            advanceTo(step.getLong("at"))
            when (action) {
                "track" -> {
                    val name = if (step.optBoolean("trigger", false)) LISTED else UNLISTED
                    for (eventId in step.getJSONArray("events").strings()) {
                        tracked += eventId
                        runBlocking { queue.append(event(eventId, name)) }
                        // What the host does once an event is on the queue, in its order (`announceQueued`).
                        uploader.eventLogged(name)
                        pace.eventQueued()
                        if (runBlocking { queue.size() } >= batchSize) {
                            val job = CoroutineScope(dispatcher + handler).launch { uploader.flush() }
                            scheduler.runCurrent()
                            assertTrue("$label: the flush did not finish on the virtual clock", job.isCompleted)
                        }
                    }
                    scheduler.runCurrent()
                }
                "advance" -> Unit
                else -> error("$label: `$action` is not a step this core can take")
            }

            assertEquals("$label: failures", emptyList<String>(), failures)
            // An upload the scenario did not expect, and an answer it expected that nothing asked for.
            assertEquals("$label: not in the scenario", emptyList<String>(), unscripted)
            assertEquals("$label: responses never used", 0, responses.size)

            // A step that names no uploads expects none.
            val expected = step.optJSONObject("expect")?.optJSONArray("sent")?.let { batches ->
                (0 until batches.length()).map { batches.getJSONObject(it).getJSONArray("events").strings() }
            } ?: emptyList()
            assertEquals("$label: sent", expected, sent.toList())
            delivered += sent.flatten()
        }

        // Read back from fresh stores: every event went exactly once, in order, and nothing is left behind.
        assertEquals("$id: everything tracked was sent, once and in order", tracked, delivered)
        assertEquals("$id: queue", emptyList<String>(), runBlocking { EventQueue(directory).peek(Int.MAX_VALUE) }.map { it.getString("event_id") })
        assertEquals("$id: pending", 0, UploaderStore(directory).load().pending.size)
        process.cancel()
    }
}
