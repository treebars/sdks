package com.treebars.sdk

import com.treebars.sdk.generated.TreebarsBridge
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/*
 * The Android half of the bridge's two shared contracts, which the web and iOS SDKs run too: the document a WebView is
 * handed, byte for byte (`bridge-documents.json`, generated from the reference implementation), and what each call
 * means (`bridge-conformance.json`, written by hand). Both are shared test resources. The WebView itself is the
 * emulator's to prove.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class InAppHtmlBridgeTest {

    private fun fixture(name: String): JSONObject =
        JSONObject(requireNotNull(javaClass.classLoader?.getResource("bridge/$name")) { "bridge/$name is missing from the test resources" }.readText())

    @Test
    fun everyGoldenDocumentIsBuiltByteForByte() {
        val cases = fixture("bridge-documents.json").getJSONArray("cases")
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            val options = case.getJSONObject("options")
            val insets = options.optJSONObject("insets")?.let { BridgeInsets(it.getInt("top"), it.getInt("right"), it.getInt("bottom"), it.getInt("left")) }
            val built = BridgeDocument.build(
                case.getString("html"),
                options.getString("host"),
                options.getString("nonce"),
                if (options.isNull("direction")) null else options.optString("direction").takeIf { it.isNotEmpty() },
                insets,
                if (options.isNull("device")) null else options.optString("device").takeIf { it.isNotEmpty() },
                if (options.isNull("orientation")) null else options.optString("orientation").takeIf { it.isNotEmpty() },
            )
            assertEquals(case.getString("name"), case.getString("document"), built)
        }
    }

    @Test
    fun answersEveryMethodTheBridgeTableGivesAndroid() {
        val display = BridgeDisplay(message(JSONObject().put("delivery_id", "d").put("campaign_id", JSONObject.NULL)), FakeSdk()) { _, _ -> }
        assertEquals(TreebarsBridge.HOST_METHODS, display.methods)
    }

    @Test
    fun everyConformanceCaseMeansWhatItMeansOnTheWeb() {
        val cases = fixture("bridge-conformance.json").getJSONArray("cases")
        for (i in 0 until cases.length()) run(cases.getJSONObject(i))
    }

    private fun message(spec: JSONObject): InAppMessage {
        val inApp = JSONObject()
            .put("surface", "overlay").put("layout", "modal").put("body_mode", "html").put("html", "<p>x</p>")
            .put("trigger", JSONObject().put("kind", "immediate"))
            .put("declared", spec.optJSONObject("declared") ?: JSONObject().put("events", JSONArray()).put("traits", JSONArray()))
        val raw = JSONObject()
            .put("delivery_id", spec.getString("delivery_id"))
            .put("campaign_id", spec.opt("campaign_id") ?: JSONObject.NULL)
            .put("content", JSONObject().put("in_app", inApp))
            .put("stored", spec.optJSONObject("stored") ?: JSONObject())
        return InAppMessage(
            deliveryId = spec.getString("delivery_id"),
            campaignId = if (spec.isNull("campaign_id")) null else spec.optString("campaign_id"),
            title = null,
            body = null,
            imageUrl = null,
            content = parseInAppContent(inApp),
            expiresAt = null,
            style = null,
            raw = raw,
        )
    }

    private class FakeSdk(val rewards: JSONObject? = null) : BridgeSdk {
        val events = mutableListOf<Pair<String, Map<String, Any?>>>()
        val traits = mutableListOf<Map<String, Any?>>()
        val opened = mutableListOf<List<String>>()
        var dismissed = 0
        var spent = 0
        var clicked = 0

        override fun track(name: String, properties: Map<String, Any?>) {
            events.add(name to properties)
        }
        // Where a trait goes — `identify` or the anonymous person — is the SDK's, and the page cannot tell.
        override fun setTraits(traits: Map<String, Any?>): Map<String, Any?> {
            this.traits.add(traits)
            return BridgeDisplay.OK
        }
        override fun requestPushPermission(answer: (String) -> Unit) = answer("granted")
        override fun clicked(action: String, values: Map<String, Any?>, fields: Map<String, Any?>) {
            clicked += 1
        }
        override fun spent() {
            spent += 1
        }
        override fun dismissed() {
            dismissed += 1
        }
        override fun flush() {}
        override fun open(url: String, via: String): Boolean {
            opened.add(listOf(url, via))
            return true
        }
        override fun copy(text: String, toast: String?) = true
        override fun dial(number: String) = true
        override fun sms(number: String, body: String?) = true
        override fun share(text: String) = true
        override fun settings(notifications: Boolean) = true
        override fun storeReview() = true
        override fun alert(message: String) {}
        override fun context(): Map<String, Any?> = emptyMap()
        override fun log(line: String) {}
        // The server's answers a case names (`rewards`); a pool it does not name is refused.
        override fun claimReward(pool: String, deliveryId: String, answer: (Map<String, Any?>) -> Unit) =
            answer(rewards?.optJSONObject(pool)?.let { BridgeDisplay.toMap(it) } ?: BridgeDisplay.refuse("not_available"))
    }

    private fun run(spec: JSONObject) {
        val name = spec.getString("name")
        val sdk = FakeSdk(spec.optJSONObject("rewards"))
        val waiting = mutableListOf<() -> Unit>()
        val display = BridgeDisplay(message(spec.getJSONObject("message")), sdk) { _, run -> waiting.add(run) }
        var closes = 0
        val turn = {
            val due = waiting.toList()
            waiting.clear()
            due.forEach { it() }
        }
        val steps = spec.getJSONArray("steps")
        for (i in 0 until steps.length()) {
            val step = steps.getJSONObject(i)
            if (step.optBoolean("turn", false)) {
                turn()
                continue
            }
            var answer: Any? = UNANSWERED
            display.call(step.getString("call"), step.optJSONArray("args") ?: JSONArray(), { closes += 1 }) { answer = it }
            assertEquals("$name: ${step.getString("call")}${step.optJSONArray("args")}", plain(step.opt("answer")), plain(answer))
        }
        turn()
        spec.optJSONArray("events")?.let { expected ->
            assertEquals("$name: events", plain(expected), plain(JSONArray(sdk.events.map { JSONArray().put(it.first).put(JSONObject.wrap(it.second)) })))
        }
        if (spec.has("event_count")) assertEquals("$name: event count", spec.getInt("event_count"), sdk.events.size)
        spec.optJSONArray("traits")?.let { assertEquals("$name: traits", plain(it), plain(JSONArray(sdk.traits.map { trait -> JSONObject.wrap(trait) }))) }
        spec.optJSONArray("opened")?.let { assertEquals("$name: opened", plain(it), plain(JSONArray(sdk.opened.map { pair -> JSONArray(pair) }))) }
        if (spec.has("closes")) assertEquals("$name: closes", spec.getInt("closes"), closes)
        if (spec.has("dismissed")) assertEquals("$name: dismissed", spec.getInt("dismissed"), sdk.dismissed)
        if (spec.has("spent")) assertEquals("$name: spent", spec.getInt("spent"), sdk.spent)
        if (spec.has("clicked")) assertEquals("$name: clicked", spec.getInt("clicked"), sdk.clicked)
    }

    /** A JSON value as plain Kotlin, numbers as doubles, so `1` and `1.0` and a map and an object compare as JSON does. */
    private fun plain(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> value.keys().asSequence().associateWith { plain(value.opt(it)) }
        is JSONArray -> (0 until value.length()).map { plain(value.opt(it)) }
        is Map<*, *> -> value.entries.associate { (key, item) -> key.toString() to plain(item) }
        is List<*> -> value.map { plain(it) }
        is Number -> value.toDouble()
        else -> value
    }

    private object UNANSWERED
}
