package com.treebars.sdk

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The shared fixture every SDK's store answers: nudges and modals and the caps, one file (`bridge/in-app-caps.json`
 * in the test resources), so the Android, iOS and web SDKs cannot drift.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class InAppCapsFixtureTest {
    private val context: Context = ApplicationProvider.getApplicationContext()

    @Test
    fun everyCaseIsAnsweredAsTheOtherCoresAnswerIt() {
        val fixture = JSONObject(requireNotNull(javaClass.classLoader?.getResource("bridge/in-app-caps.json")) { "the shared fixture is missing from the test resources" }.readText())
        val cases = fixture.getJSONArray("cases")
        val start = 1_790_000_000_000L
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            val prefs = "treebars.inapp.${UUID.randomUUID()}"
            var store = InAppStore(context, prefs)
            val messages = JSONArray()
            val specs = case.getJSONArray("messages")
            for (m in 0 until specs.length()) {
                val spec = specs.getJSONObject(m)
                messages.put(
                    JSONObject()
                        .put("delivery_id", spec.getString("id"))
                        .put("campaign_id", JSONObject.NULL)
                        .put("created_at", "2026-09-28T09:00:00.000Z")
                        .put("expires_at", JSONObject.NULL)
                        .put("test", spec.optBoolean("test", false))
                        .put(
                            "content",
                            JSONObject().put(
                                "in_app",
                                JSONObject().put("surface", "overlay").put("layout", spec.getString("layout")).put("body_mode", "html")
                                    .put("html", "<p>x</p>").put("trigger", JSONObject().put("kind", "immediate")),
                            ),
                        ),
                )
            }
            val policy = JSONObject().put("max_per_day", JSONObject.NULL).put("min_gap_seconds", JSONObject.NULL)
                .put("messages_shown_today", 0).put("last_shown_at", JSONObject.NULL)
            val given = case.getJSONObject("policy")
            given.keys().forEach { key -> policy.put(key, given.get(key)) }
            store.accept(JSONObject().put("messages", messages).put("policy", policy))
            val byId = store.list().associateBy { it.deliveryId }
            val shown = case.getJSONArray("shown")
            for (s in 0 until shown.length()) {
                val row = shown.getJSONObject(s)
                store.recordDisplay(byId.getValue(row.getString("id")), row.getString("session"), start + row.getInt("seconds") * 1000L)
            }
            // Built again from what it saved, never synced: a cold start.
            if (case.optBoolean("restart", false)) store = InAppStore(context, prefs)
            val asks = case.getJSONArray("asks")
            for (a in 0 until asks.length()) {
                val ask = asks.getJSONObject(a)
                val expected = if (ask.isNull("expect")) null else ask.getString("expect")
                val inFlight = ask.optInt("in_flight", 0)
                val answer = store.blockedBy(byId.getValue(ask.getString("id")), ask.getString("session"), start + ask.getInt("seconds") * 1000L, inFlight)
                assertEquals("${case.getString("name")}: ${ask.getString("id")} in ${ask.getString("session")} at ${ask.getInt("seconds")}s, $inFlight in flight", expected, answer)
            }
        }
    }
}
