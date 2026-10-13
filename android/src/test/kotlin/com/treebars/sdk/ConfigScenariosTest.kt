package com.treebars.sdk

import com.treebars.sdk.generated.TreebarsConstants
import java.io.File
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
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
 * The shared remote config scenarios, run against this core.
 *
 * The same `config-scenarios.json` drives the web SDK and the iOS SDK too, so the three cores are held to one
 * set of rules: when to ask, what a read answers, and what a sign-in or a sign-out does to both. The harness
 * owns exactly what the host owns in an app — the file, the clock and the request — and scripts the answers.
 * Asks are real coroutines on a test dispatcher, so one left out by a `hold` is genuinely still out when the
 * next step runs. What a relaunch finds is read back by a fresh instance over the same directory.
 */
internal fun configFixtureFile(): File =
    File(requireNotNull(Thread.currentThread().contextClassLoader?.getResource("bridge/config-scenarios.json")) {
        "the shared fixture bridge/config-scenarios.json is missing from the test resources"
    }.toURI())

@RunWith(RobolectricTestRunner::class)
class ConfigPolicyFixtureTest {

    /* The waits in the scenarios are consequences of the policy, as the uploads' are. */
    @Test
    fun `the generated policy is the one the config scenarios were derived from`() {
        val policy = JSONObject(configFixtureFile().readText()).getJSONObject("policy")
        assertEquals(policy.getLong("config_retry_seconds"), TreebarsConstants.CONFIG_RETRY_SECONDS)
        assertEquals(policy.getLong("retry_after_max_seconds"), TreebarsConstants.RETRY_AFTER_MAX_SECONDS)
        assertEquals(policy.getLong("auth_cooldown_seconds"), TreebarsConstants.AUTH_COOLDOWN_SECONDS)
        assertEquals(policy.getLong("config_exposure_floor_seconds"), TreebarsConstants.CONFIG_EXPOSURE_FLOOR_SECONDS)
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(ParameterizedRobolectricTestRunner::class)
class ConfigScenariosTest(private val id: String) {

    companion object {
        /** Ids only — the parameters method runs outside Robolectric's sandbox, where `org.json` is a stub. */
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}")
        fun scenarios(): List<Array<Any>> =
            Regex("\"id\":\\s*\"(RC-\\d+)\"").findAll(configFixtureFile().readText())
                .map { arrayOf<Any>(it.groupValues[1]) }
                .toList()
    }

    @Rule
    @JvmField
    val temp = TemporaryFolder()

    /** A JSON value as text two equal values share: keys in order, and `2` the same number as `2.0`. */
    private fun canon(value: Any?): String = when (value) {
        null, JSONObject.NULL -> "null"
        is JSONObject -> value.keys().asSequence().sorted().joinToString(",", "{", "}") { "${JSONObject.quote(it)}:${canon(value.opt(it))}" }
        is JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { canon(value.opt(it)) }
        is Map<*, *> -> value.keys.map { it.toString() }.sorted().joinToString(",", "{", "}") { "${JSONObject.quote(it)}:${canon(value[it])}" }
        is Number -> value.toDouble().toString()
        is String -> JSONObject.quote(value)
        else -> value.toString()
    }

    private fun JSONObject.map(): Map<String, Any?> = keys().asSequence().associateWith { opt(it) }

    @Test
    fun `agrees with the shared scenario`() {
        val fixture = JSONObject(configFixtureFile().readText())
        val all = fixture.getJSONArray("scenarios")
        val scenario = (0 until all.length()).map { all.getJSONObject(it) }.single { it.getString("id") == id }
        val epoch = fixture.getLong("epoch_ms")
        val directory = temp.newFolder()

        val scheduler = TestCoroutineScheduler()
        val dispatcher = StandardTestDispatcher(scheduler)
        // Failures inside an ask are collected, not thrown on a dispatcher thread nobody watches.
        val failures = mutableListOf<String>()
        val scope = CoroutineScope(dispatcher + Job() + CoroutineExceptionHandler { _, error -> failures += "an ask threw: $error" })

        var now = epoch
        val asked = mutableListOf<Pair<String?, Map<String, Any>>>()
        var changes = 0
        /** Each exposure reported in the running step, as the scenarios name one. */
        val exposures = mutableListOf<String>()
        val scripted = ArrayDeque<JSONObject>()
        var holding = false
        val out = ArrayDeque<CompletableDeferred<ConfigAnswer>>()

        fun answerFor(response: JSONObject?): ConfigAnswer {
            checkNotNull(response) { "$id: an ask was started with no answer scripted for it" }
            return when {
                response.optBoolean("network_error", false) -> ConfigAnswer.Failed()
                response.has("status") -> ConfigAnswer.Failed(response.getInt("status"), if (response.has("retry_after")) response.getString("retry_after") else null)
                else -> ConfigAnswer.Answered(JSONObject().put("version", response.opt("version")).put("values", response.opt("values")))
            }
        }
        val fetch: suspend (ConfigAsk) -> ConfigAnswer = { ask ->
            asked += ask.userId to ask.attributes
            if (holding) CompletableDeferred<ConfigAnswer>().also { out += it }.await() else answerFor(scripted.removeFirstOrNull())
        }

        // What storage holds, in this core's own file.
        val stored = scenario.getJSONObject("stored")
        val state = JSONObject().put("not_before", 0)
        stored.optJSONObject("config")?.let { config ->
            state.put(
                "set",
                JSONObject()
                    .put("version", config.getString("version"))
                    .put("values", config.getJSONArray("values"))
                    .put("context", config.getJSONObject("asked_as").getString("context"))
                    .put("stale", false),
            )
        }
        stored.optJSONObject("session")?.let { state.put("session", it) }
        stored.optJSONObject("attributes")?.let { state.put("attributes", it) }
        if (state.length() > 1) check(ConfigStore(directory).save(state))

        lateinit var config: RemoteConfig
        fun launchApp(session: String, user: String?, context: String) {
            config = RemoteConfig(
                ConfigStore(directory),
                fetch,
                launch = { block -> scope.launch { block() } },
                clock = { now },
                expose = { exposure -> exposures += "${exposure.experimentKey}|${exposure.variant}|${exposure.variable}" },
            )
            config.onChange { changes += 1 }
            config.start(session, user, context)
        }

        fun user(json: JSONObject, name: String = "user"): String? = json.opt(name) as? String

        fun verify(label: String, expected: JSONObject?, result: Any?) {
            if (expected == null) return
            if (expected.has("fetches")) {
                val wanted = expected.getJSONArray("fetches").let { list -> (0 until list.length()).map { list.getJSONObject(it) } }
                assertEquals(
                    "$label: who asked",
                    wanted.map { "${user(it)}|${canon(it.optJSONObject("attributes"))}" },
                    asked.map { (who, attributes) -> "$who|${canon(attributes)}" },
                )
            }
            if (expected.has("held")) assertEquals("$label: the version held", expected.opt("held") as? String, config.version)
            if (expected.has("changes")) assertEquals("$label: changes announced", expected.getInt("changes"), changes)
            if (expected.has("result")) assertEquals("$label: what the call answered", expected.getBoolean("result"), result)
            if (expected.has("value")) assertEquals("$label: what the read answered", canon(expected.opt("value")), canon(result))
            if (expected.has("exposures")) {
                val wanted = expected.getJSONArray("exposures").let { list -> (0 until list.length()).map { list.getJSONObject(it) } }
                assertEquals(
                    "$label: exposures reported",
                    wanted.map { "${it.getString("experiment")}|${it.getString("variant")}|${it.getString("variable")}" },
                    exposures.toList(),
                )
            }
        }

        fun script(responses: JSONArray?) {
            scripted.clear()
            if (responses != null) for (index in 0 until responses.length()) scripted += responses.getJSONObject(index)
        }

        val start = scenario.getJSONObject("start")
        script(start.optJSONArray("responses"))
        launchApp(start.getString("session"), user(start), start.getString("context"))
        scheduler.advanceUntilIdle()
        verify("$id start", start.optJSONObject("expect"), null)
        assertTrue("$id start: answers scripted and never asked for", scripted.isEmpty())

        val steps = scenario.getJSONArray("steps")
        for (index in 0 until steps.length()) {
            val step = steps.getJSONObject(index)
            val action = step.getString("do")
            val label = "$id step ${index + 1} ($action)"
            if (step.has("at")) now = epoch + step.getLong("at")
            asked.clear()
            changes = 0
            exposures.clear()
            script(step.optJSONArray("responses"))
            holding = step.optBoolean("hold", false)
            var result: Any? = null

            when (action) {
                "read" -> result = config.read(step.getString("key"), step.getString("as")) ?: step.opt("fallback")
                "list" -> config.all()
                "upload" -> config.observe(step.opt("config_version") as? String)
                "session" -> config.sessionStarted(step.getString("id"))
                "identify" -> config.identityChanged(user(step))
                "reset" -> config.identityChanged(null)
                "attributes" -> config.setAttributes(step.getJSONObject("set").map())
                "activate" -> result = config.activate()
                "override" -> config.override(step.getString("key"), step.opt("value").takeUnless { it == JSONObject.NULL })
                "fetch" -> scope.launch { result = config.refresh() }
                // The asks left out are answered in the order they were started; one an answer starts takes the next.
                "answer" -> while (out.isNotEmpty()) {
                    out.removeFirst().complete(answerFor(scripted.removeFirstOrNull()))
                    scheduler.advanceUntilIdle()
                }
                "relaunch" -> launchApp(step.getString("session"), user(step), step.getString("context"))
                else -> error("$label: a step this harness does not know")
            }
            scheduler.advanceUntilIdle()
            holding = false
            verify(label, step.optJSONObject("expect"), result)
            assertTrue("$label: answers scripted and never asked for", scripted.isEmpty())
        }
        assertTrue("$id: an ask was left out and never answered", out.isEmpty())
        assertTrue("$id: $failures", failures.isEmpty())
    }
}
