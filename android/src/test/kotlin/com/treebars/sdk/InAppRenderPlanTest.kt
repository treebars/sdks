package com.treebars.sdk

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The render contract: every case in the shared `bridge/in-app-render.json` fixture planned as the reference
 * implementation and the iOS SDK plan it, so the renderer built on [inAppRenderPlan] cannot draw a message differently
 * from the iOS one.
 *
 * Under Robolectric for the real `org.json`: this module's unit tests return defaults from an unstubbed `android.*`, and
 * a stubbed `optString` would answer every case with nothing — which is why each loop also asserts it read something.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class InAppRenderPlanTest {
    private val fixture = JSONObject(
        requireNotNull(javaClass.classLoader?.getResource("bridge/in-app-render.json")) { "the shared fixture is missing from the test resources" }.readText(),
    )

    /** Objects as sorted maps, lists as lists, every number a double and `null` for JSON null — so `1` and `1.0` agree and a missing key does not. */
    private fun canonical(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> value.keys().asSequence().associateWith { canonical(value.opt(it)) }.toSortedMap()
        is JSONArray -> (0 until value.length()).map { canonical(value.opt(it)) }
        is Map<*, *> -> value.entries.associate { (key, item) -> key.toString() to canonical(item) }.toSortedMap()
        is List<*> -> value.map(::canonical)
        is Number -> value.toDouble()
        else -> value
    }

    private fun env(json: JSONObject) = InAppRenderEnv(
        appearance = json.getString("appearance"),
        platform = json.getString("platform"),
        deviceClass = json.getString("device_class"),
        fallbackTokens = (json.opt("fallback_tokens") as? JSONObject)?.let(::parseInAppTokens),
        textSize = json.optString("text_size").takeIf { it.isNotEmpty() },
    )

    @Test
    fun theLayoutNumbersAreTheFixtures() {
        assertEquals(canonical(fixture.getJSONObject("layout")), canonical(InAppStandardLayout.toJson()))
    }

    @Test
    fun everyMessageIsPlannedAsTheOtherCoresPlanIt() {
        val plans = fixture.getJSONArray("plans")
        assertTrue("the fixture has no plans", plans.length() > 0)
        var overlays = 0
        for (i in 0 until plans.length()) {
            val case = plans.getJSONObject(i)
            val plan = inAppRenderPlan(case.getJSONObject("row"), env(case.getJSONObject("env")))
            if (plan is InAppRenderPlan.Overlay) overlays += 1
            assertEquals(
                "${case.getString("id")}: ${case.getString("name")}",
                canonical(case.getJSONObject("expect")),
                canonical(plan.toJson()),
            )
        }
        assertTrue("no case was planned as an overlay — is org.json stubbed?", overlays > 0)
    }

    @Test
    fun theCountdownReadsAsTheOtherCoresReadIt() {
        val cases = fixture.getJSONArray("countdown_text")
        assertTrue(cases.length() > 0)
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            assertEquals(case.getString("name"), case.getString("text"), inAppCountdownText(case.getLong("to_ms"), case.getLong("now_ms")))
        }
    }

    @Test
    fun theFormSaysWhatTheOtherCoresSay() {
        val cases = fixture.getJSONArray("form_checks")
        assertTrue(cases.length() > 0)
        var sent = 0
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            val wire = case.getJSONArray("fields")
            val fields = (0 until wire.length()).map { inAppPlanField(wire.getJSONObject(it)) }
            val given = case.getJSONObject("answers")
            val answers = given.keys().asSequence().associateWith { key ->
                when (val value = given.get(key)) {
                    is JSONArray -> (0 until value.length()).map { value.getString(it) }
                    else -> value
                }
            }
            val name = "${case.getString("id")}: ${case.getString("name")}"
            val problem = inAppFormProblem(fields, answers)
            assertEquals(name, if (case.isNull("problem")) null else case.getString("problem"), problem)
            if (problem == null) {
                sent += 1
                assertEquals(name, canonical(case.getJSONObject("sent")), canonical(inAppFormAnswers(fields, answers)))
            }
        }
        assertTrue(sent > 0)
    }
}
