package com.treebars.sdk

import com.treebars.sdk.generated.TreebarsConstants
import java.io.File
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.RobolectricTestRunner

/*
 * The shared reward-claim scenarios, run against this SDK.
 *
 * The same `reward-claim-scenarios.json` drives `sdks/web` and the iOS SDK too: three SDKs ask for a reward again the
 * same way only if each is asked the same questions. The request is scripted, and the clocks and the
 * jitter are handed in; the harness's clock moves only by what a request took and by the waits the loop sleeps. Parsed
 * inside each test rather than in the parameters method, for the reason `UploaderScenariosTest` gives: outside
 * Robolectric's sandbox `org.json` is the android.jar stub.
 */
internal fun rewardClaimFixtureFile(): File =
    File(requireNotNull(Thread.currentThread().contextClassLoader?.getResource("bridge/reward-claim-scenarios.json")) {
        "the shared fixture bridge/reward-claim-scenarios.json is missing from the test resources"
    }.toURI())

@RunWith(RobolectricTestRunner::class)
class RewardClaimPolicyTest {

    // The numbers in the scenarios are consequences of the policy; a moved constant would make them check the wrong sums.
    @Test
    fun `the generated policy is the one the scenarios were derived from`() {
        val policy = JSONObject(rewardClaimFixtureFile().readText()).getJSONObject("policy")
        val statuses = policy.getJSONArray("retry_after_statuses").let { array -> (0 until array.length()).map { array.getInt(it) } }
        assertEquals(policy.getInt("retries"), TreebarsConstants.REWARD_CLAIM_RETRIES)
        assertEquals(policy.getLong("budget_ms"), TreebarsConstants.REWARD_CLAIM_BUDGET_MS)
        assertEquals(statuses, TreebarsConstants.RETRY_AFTER_STATUSES.toList())
        assertEquals(policy.getLong("backoff_base_seconds"), TreebarsConstants.BACKOFF_BASE_SECONDS)
        assertEquals(policy.getLong("backoff_cap_seconds"), TreebarsConstants.BACKOFF_CAP_SECONDS)
    }
}

@RunWith(ParameterizedRobolectricTestRunner::class)
class RewardClaimScenariosTest(private val id: String) {

    companion object {
        /** Ids only — see the note above on why nothing here may touch `org.json`. */
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}")
        fun scenarios(): List<Array<Any>> =
            Regex("\"id\":\\s*\"(RC-\\d+)\"").findAll(rewardClaimFixtureFile().readText())
                .map { arrayOf<Any>(it.groupValues[1]) }
                .toList()
    }

    @Test
    fun `agrees with the shared scenario`() {
        val fixture = JSONObject(rewardClaimFixtureFile().readText())
        val scenarios = fixture.getJSONArray("scenarios")
        val scenario = (0 until scenarios.length()).map { scenarios.getJSONObject(it) }.single { it.getString("id") == id }
        val expect = scenario.getJSONObject("expect")

        val answers = scenario.getJSONArray("answers").let { array -> ArrayDeque((0 until array.length()).map { array.getJSONObject(it) }) }
        val randoms = scenario.getJSONArray("random").let { array -> ArrayDeque((0 until array.length()).map { array.getDouble(it) }) }
        val nowMs = fixture.getLong("now_ms")
        var clock = 0L
        var requests = 0
        val waits = mutableListOf<Long>()

        val last = runBlocking {
            claimWithRetries(
                ask = {
                    val next = answers.removeFirstOrNull() ?: error("$id: a request with no answer left")
                    requests += 1
                    clock += next.optLong("took_ms", 0)
                    RewardAttempt(
                        status = if (next.isNull("status")) -1 else next.getInt("status"),
                        retryAfter = if (next.has("retry_after")) next.getString("retry_after") else null,
                        answer = if (next.optBoolean("answer", false)) JSONObject().put("won", true) else null,
                    )
                },
                elapsed = { clock },
                now = { nowMs + clock },
                sleep = { ms ->
                    waits += ms
                    clock += ms
                },
                random = { randoms.removeFirstOrNull() ?: error("$id: a jitter draw the scenario did not expect") },
            )
        }

        val expectedWaits = expect.getJSONArray("waits").let { array -> (0 until array.length()).map { array.getLong(it) } }
        assertEquals("$id requests", expect.getInt("requests"), requests)
        assertEquals("$id waits", expectedWaits, waits)
        assertEquals("$id outcome", expect.getString("outcome"), if (last.answer != null) "answer" else rewardRefusalReason(last))
        assertEquals("$id: random values never drawn", emptyList<Double>(), randoms.toList())
        assertEquals("$id: answers never asked for", 0, answers.size)
    }
}
