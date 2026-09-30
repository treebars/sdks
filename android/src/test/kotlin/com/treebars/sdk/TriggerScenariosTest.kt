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
 * The shared trigger scenarios, run against this core.
 *
 * The same `trigger-scenarios.json` drives `sdks/web` and the iOS SDK too. The
 * uploader's wakes are real coroutines here — launched into a scope on a test dispatcher, sleeping
 * in `delay` — and time moves only when a step moves it, so a debounce, a retry and the order they
 * fall due in are the uploader's own and not a simulation of them. The send and the list fetch run
 * on that dispatcher too (`ioContext`), because on a real IO thread they would finish outside the
 * virtual clock. What is asserted is read back from fresh stores over the same directory.
 */
internal fun triggerFixtureFile(): File =
    File(requireNotNull(Thread.currentThread().contextClassLoader?.getResource("bridge/trigger-scenarios.json")) {
        "the shared fixture bridge/trigger-scenarios.json is missing from the test resources"
    }.toURI())

@RunWith(RobolectricTestRunner::class)
class TriggerPolicyFixtureTest {

    /* The numbers in the scenarios are consequences of the policy, as they are for the uploads. */
    @Test
    fun `the generated policy is the one the trigger scenarios were derived from`() {
        val policy = JSONObject(triggerFixtureFile().readText()).getJSONObject("policy")
        assertEquals(policy.getLong("trigger_flush_debounce_ms"), TreebarsConstants.TRIGGER_FLUSH_DEBOUNCE_MS)
        assertEquals(policy.getLong("backoff_base_seconds"), TreebarsConstants.BACKOFF_BASE_SECONDS)
        assertEquals(policy.getLong("auth_cooldown_seconds"), TreebarsConstants.AUTH_COOLDOWN_SECONDS)
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(ParameterizedRobolectricTestRunner::class)
class TriggerScenariosTest(private val id: String) {

    companion object {
        /** Ids only — the parameters method runs outside Robolectric's sandbox, where `org.json` is a stub. */
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}")
        fun scenarios(): List<Array<Any>> =
            Regex("\"id\":\\s*\"(TR-\\d+)\"").findAll(triggerFixtureFile().readText())
                .map { arrayOf<Any>(it.groupValues[1]) }
                .toList()
    }

    @Rule
    @JvmField
    val temp = TemporaryFolder()

    private data class Shape(val batchId: String, val events: List<String>)

    private fun JSONArray.strings(): List<String> = (0 until length()).map { getString(it) }

    private fun JSONObject.shape() = Shape(getString("batch_id"), getJSONArray("events").let { events ->
        (0 until events.length()).map { events.getJSONObject(it).getString("event_id") }
    })

    private fun shapes(array: JSONArray?): List<Shape> =
        if (array == null) emptyList() else (0 until array.length()).map { index ->
            val each = array.getJSONObject(index)
            Shape(each.getString("batch_id"), each.getJSONArray("events").strings())
        }

    private fun event(id: String, name: String): JSONObject = JSONObject()
        .put("event_id", id)
        .put("session_id", "s1")
        .put("device_id", "dev_fixture")
        .put("event_name", name)
        .put("properties", JSONObject())
        .put("timestamp", "2026-09-15T12:00:00.000Z")
        .put("sdk_version", TreebarsConstants.SDK_VERSION)

    private fun versionAndNames(json: JSONObject?): Pair<String, List<String>>? =
        TriggerList.fromJson(json)?.let { it.version to it.names }

    @Test
    fun `agrees with the shared scenario`() {
        val fixture = JSONObject(triggerFixtureFile().readText())
        val all = fixture.getJSONArray("scenarios")
        val scenario = (0 until all.length()).map { all.getJSONObject(it) }.single { it.getString("id") == id }

        val epoch = fixture.getLong("epoch_ms")
        val directory = temp.newFolder()
        val writeKey = fixture.getString("write_key")
        val batchSize = scenario.optInt("batch_size", TreebarsConstants.BATCH_SIZE)

        val scheduler = TestCoroutineScheduler()
        val dispatcher = StandardTestDispatcher(scheduler)
        val clock = { epoch + scheduler.currentTime }
        // Failures inside a wake are collected, not thrown on a dispatcher thread nobody watches.
        val failures = mutableListOf<String>()
        val handler = CoroutineExceptionHandler { _, error -> failures += "a wake threw: $error" }
        var process = Job()
        fun scope() = CoroutineScope(dispatcher + process + handler)

        var minted = 0
        val responses = ArrayDeque<JSONObject>()
        val syncs = ArrayDeque<JSONObject>()
        val randoms = ArrayDeque<Double>()
        val unscripted = mutableListOf<String>()
        val sent = mutableListOf<Shape>()
        var synced = 0

        scenario.optJSONObject("stored_triggers")?.let { stored ->
            check(TriggerStore(directory).save(TriggerList.fromJson(stored)!!))
        }

        val transport = EventTransport { batch ->
            val next = responses.removeFirstOrNull()
            if (next == null) {
                unscripted += "an upload of ${batch.getString("batch_id")}"
                throw IOException("no response scripted")
            }
            sent += batch.shape()
            if (next.optBoolean("network_error", false)) throw IOException("network unreachable")
            UploadResponse(
                next.getInt("status"),
                if (next.has("retry_after")) next.getString("retry_after") else null,
                if (next.has("triggers_version")) next.getString("triggers_version") else null,
            )
        }

        val fetch: suspend () -> TriggerList? = {
            synced += 1
            val next = syncs.removeFirstOrNull()
            if (next == null) {
                unscripted += "a trigger list fetch"
                null
            } else if (next.optBoolean("network_error", false)) {
                throw IOException("network unreachable")
            } else {
                TriggerList.fromJson(next.optJSONObject("trigger_events"))
            }
        }

        var queue = EventQueue(directory)
        runBlocking {
            val initial = scenario.getJSONArray("queue")
            for (index in 0 until initial.length()) {
                val each = initial.getJSONObject(index)
                queue.append(event(each.getString("id"), each.getString("name")))
            }
        }

        var triggers = TriggerEvents(TriggerStore(directory), fetch)
        fun build(): EventUploader {
            triggers = TriggerEvents(TriggerStore(directory), fetch)
            return EventUploader(
                queue = queue,
                transport = transport,
                store = UploaderStore(directory),
                writeKey = writeKey,
                batchSize = batchSize,
                clock = clock,
                random = {
                    randoms.removeFirstOrNull() ?: run {
                        unscripted += "a random draw"
                        // Not zero: with wakes live, an unscripted failure retried after no delay at
                        // all would fall due again at once, and the scheduler would never go idle.
                        0.5
                    }
                },
                newBatchId = { "b${++minted}" },
                scope = scope(),
                ioContext = EmptyCoroutineContext,
                triggers = triggers,
            )
        }
        var uploader = build()

        /* Moves virtual time to `at`, running every wake that falls due on the way, in order. */
        fun advanceTo(at: Long) {
            val delta = at - scheduler.currentTime
            if (delta > 0) scheduler.advanceTimeBy(delta)
            scheduler.runCurrent()
        }

        fun offset(value: Long): Long? = if (value == 0L) null else value - epoch

        val steps = scenario.getJSONArray("steps")
        for (index in 0 until steps.length()) {
            val step = steps.getJSONObject(index)
            val action = step.getString("do")
            val label = "$id step ${index + 1} ($action)"
            val expected = step.optJSONObject("expect") ?: JSONObject()

            sent.clear()
            synced = 0
            unscripted.clear()
            failures.clear()
            responses.clear()
            step.optJSONArray("responses")?.let { array -> (0 until array.length()).forEach { responses.addLast(array.getJSONObject(it)) } }
            syncs.clear()
            step.optJSONArray("syncs")?.let { array -> (0 until array.length()).forEach { syncs.addLast(array.getJSONObject(it)) } }
            randoms.clear()
            step.optJSONArray("random")?.let { array -> (0 until array.length()).forEach { randoms.addLast(array.getDouble(it)) } }

            advanceTo(step.getLong("at"))
            when (action) {
                "track" -> {
                    val events = step.getJSONArray("events")
                    for (each in 0 until events.length()) {
                        val entry = events.getJSONObject(each)
                        runBlocking { queue.append(event(entry.getString("id"), entry.getString("name"))) }
                        uploader.eventLogged(entry.getString("name"))
                    }
                }
                "tick" -> {
                    // The host's periodic flush, on the same dispatcher as the wakes.
                    val job = CoroutineScope(dispatcher + handler).launch { uploader.flush() }
                    scheduler.runCurrent()
                    assertTrue("$label: the flush did not finish on the virtual clock", job.isCompleted)
                }
                "sync_start" -> triggers.beginSync()
                "sync_end" -> triggers.endSync(TriggerList.fromJson(step.optJSONObject("trigger_events")))
                "relaunch" -> {
                    // The process dies, and every wake it had armed dies with it.
                    process.cancel()
                    process = Job()
                    queue = EventQueue(directory)
                    uploader = build()
                }
                "advance" -> Unit
                else -> error("$label: `$action` is not a step this core can take")
            }

            assertEquals("$label: failures", emptyList<String>(), failures)
            assertEquals("$label: not in the scenario", emptyList<String>(), unscripted)
            assertEquals("$label: responses never asked for", 0, responses.size)
            assertEquals("$label: trigger list answers never asked for", 0, syncs.size)
            assertEquals("$label: random values never drawn", 0, randoms.size)

            assertEquals("$label: sent", shapes(expected.optJSONArray("sent")), sent.toList())
            assertEquals("$label: trigger list fetches", expected.optInt("synced", 0), synced)

            if (expected.has("triggers")) {
                val want = if (expected.isNull("triggers")) null else versionAndNames(expected.getJSONObject("triggers"))
                assertEquals("$label: stored triggers", want, TriggerStore(directory).load()?.let { it.version to it.names })
            }
            if (expected.has("queue")) {
                val queued = runBlocking { EventQueue(directory).peek(Int.MAX_VALUE) }.map { it.getString("event_id") }
                assertEquals("$label: queue", expected.getJSONArray("queue").strings(), queued)
            }
            val state = UploaderStore(directory).load()
            if (expected.has("pending")) {
                assertEquals(
                    "$label: pending",
                    shapes(expected.getJSONArray("pending")),
                    state.pending.map { Shape(it.batchId, it.events.map { e -> e.getString("event_id") }) },
                )
            }
            if (expected.has("next_allowed_at")) {
                val want = if (expected.isNull("next_allowed_at")) null else expected.getLong("next_allowed_at")
                assertEquals("$label: next_allowed_at", want, offset(state.nextAllowedAt))
            }
            if (expected.has("auth_blocked_until")) {
                val want = if (expected.isNull("auth_blocked_until")) null else expected.getLong("auth_blocked_until")
                assertEquals("$label: auth_blocked_until", want, offset(state.authBlockedUntil))
            }
        }
        process.cancel()
    }
}
