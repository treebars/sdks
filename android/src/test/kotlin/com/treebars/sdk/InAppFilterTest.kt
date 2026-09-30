package com.treebars.sdk

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * An `event` trigger's property filters.
 *
 * A filter the SDK did not evaluate would show a filtered message to everyone who fired the
 * event. The matcher fails closed on an unrecognised kind because "showing a message to people
 * who do not qualify is worse than showing it to nobody" — and ignoring a filter would be
 * exactly that failure, arrived at by a different route.
 *
 * It answers all fourteen operators, as every SDK reads them on a device; an operator this
 * build does not know fails closed for the same reason.
 */
@RunWith(RobolectricTestRunner::class)
class InAppFilterTest {

    private fun trigger(filters: String): InAppTrigger {
        val json = JSONObject()
            .put("surface", "overlay")
            .put("layout", "modal")
            .put(
                "trigger",
                JSONObject()
                    .put("kind", "event")
                    .put("event_name", "purchase")
                    .put("filters", JSONArray(filters)),
            )
        return parseInAppContent(json).trigger
    }

    private fun matches(filters: String, properties: Map<String, Any?>) =
        inAppTriggerMatches(trigger(filters), "purchase", properties, null)

    @Test
    fun `a filter that is met matches, and one that is not does not`() {
        val gte = """[{"key":"value","op":"gte","value":50}]"""
        assertTrue(matches(gte, mapOf("value" to 80)))
        assertFalse(matches(gte, mapOf("value" to 20)))
    }

    @Test
    fun `a trigger with no filters is unchanged, which is every message authored so far`() {
        val json = JSONObject()
            .put("surface", "overlay")
            .put("layout", "modal")
            .put("trigger", JSONObject().put("kind", "event").put("event_name", "purchase"))
        val parsed = parseInAppContent(json).trigger
        assertEquals(emptyList<InAppFilter>(), parsed.filters)
        assertTrue(inAppTriggerMatches(parsed, "purchase", mapOf("value" to 1), null))
    }

    @Test
    fun `every filter has to hold, not just one of them`() {
        val both = """[{"key":"tier","op":"eq","value":"gold"},{"key":"value","op":"gt","value":10}]"""
        assertTrue(matches(both, mapOf("tier" to "gold", "value" to 11)))
        assertFalse(matches(both, mapOf("tier" to "gold", "value" to 9)))
        assertFalse(matches(both, mapOf("tier" to "silver", "value" to 11)))
    }

    @Test
    fun `the operators mean what the other SDKs mean`() {
        assertTrue(matches("""[{"key":"a","op":"exists"}]""", mapOf("a" to "x")))
        assertFalse(matches("""[{"key":"a","op":"exists"}]""", mapOf("b" to "x")))
        assertTrue(matches("""[{"key":"a","op":"eq","value":"x"}]""", mapOf("a" to "x")))
        assertTrue(matches("""[{"key":"a","op":"neq","value":"x"}]""", mapOf("a" to "y")))
        assertTrue(matches("""[{"key":"a","op":"contains","value":"ell"}]""", mapOf("a" to "hello")))
        assertFalse(matches("""[{"key":"a","op":"contains","value":"ell"}]""", mapOf("a" to 5)))
        assertTrue(matches("""[{"key":"a","op":"lt","value":5}]""", mapOf("a" to 4)))
        assertTrue(matches("""[{"key":"a","op":"lte","value":5}]""", mapOf("a" to 5)))
    }

    /*
     * The composer offers only the operators above, but the wire is not the composer: a message
     * authored by a newer version of Treebars can carry an operator this build has never seen.
     * Passing would show the message to everybody.
     */
    @Test
    fun `an operator this build does not know fails closed`() {
        assertFalse(matches("""[{"key":"a","op":"matches_regex","value":"^x"}]""", mapOf("a" to "x")))
    }

    /*
     * A missing operator is the unknown operator's case, but only once the row has a value. With
     * neither an operator nor a value the row is unfinished and dropped, like the one Add filter
     * leaves. The rule is the same in every SDK, and both answers are pinned here so they
     * cannot drift apart.
     */
    @Test
    fun `a row missing its operator fails closed, unless it is unfinished`() {
        assertFalse(matches("""[{"key":"value","value":50}]""", mapOf("value" to 80)))
        assertTrue(matches("""[{"key":"value"}]""", mapOf("value" to 80)))
    }

    /*
     * JSON hands back an `Int` where a host app's map may hold a `Long` or a `Double`, and
     * Kotlin's `==` on boxed numbers of different types is false. `80 == 80L` failing would be
     * a filter that never matches, which is the quiet direction of this bug.
     */
    @Test
    fun `a number equals itself across the types JSON and a host app disagree about`() {
        val eq = """[{"key":"value","op":"eq","value":80}]"""
        assertTrue(matches(eq, mapOf("value" to 80)))
        assertTrue(matches(eq, mapOf("value" to 80L)))
        assertTrue(matches(eq, mapOf("value" to 80.0)))
    }

    /**
     * The unfinished-row rule, which is the whole of `isComplete`.
     *
     * The composer's filter builder autosaves `{key:"",op:"eq",value:""}` the moment "Add filter"
     * is clicked. Read literally it asks for a property named `""`, which nothing has, so the
     * trigger would match nobody on the device — while Treebars, which drops the row, goes on
     * treating the campaign as live.
     */
    @Test
    fun `an unfinished filter row is ignored rather than matching nobody`() {
        val props = mapOf<String, Any?>("plan" to "pro")

        assertTrue(matches("""[{"key":"","op":"eq","value":""}]""", props))
        assertTrue(matches("""[{"key":"plan","op":"eq","value":""}]""", props))

        /*
         * The damaging shape: an unfinished row beside a real one. Dropped before the conjunction
         * rather than failed inside it, so the real filter is left deciding.
         */
        assertTrue(
            matches(
                """[{"key":"plan","op":"eq","value":"pro"},{"key":"","op":"eq","value":""}]""",
                props,
            ),
        )
        assertFalse(
            matches(
                """[{"key":"plan","op":"eq","value":"gold"},{"key":"","op":"eq","value":""}]""",
                props,
            ),
        )

        // `exists` is complete on its key alone, so it is never dropped.
        assertTrue(matches("""[{"key":"plan","op":"exists"}]""", props))
        assertFalse(matches("""[{"key":"coupon","op":"exists"}]""", props))
    }

    // The fourteen operators, as every SDK reads them on a device.

    private fun on(filter: String, properties: Map<String, Any?>) = matches("[$filter]", properties)

    @Test
    fun `the six new operators against a present value, a missing one and an empty one`() {
        val cases = listOf(
            // filter, present "pro-plan", missing, ""
            Triple("""{"key":"v","op":"not_contains","value":"pro"}""", false, true to true),
            Triple("""{"key":"v","op":"starts_with","value":"pro"}""", true, false to false),
            Triple("""{"key":"v","op":"ends_with","value":"plan"}""", true, false to false),
            Triple("""{"key":"v","op":"in","value":"[\"pro-plan\",\"team\"]"}""", true, false to false),
            Triple("""{"key":"v","op":"not_in","value":"[\"pro-plan\",\"team\"]"}""", false, true to true),
            Triple("""{"key":"v","op":"not_exists","value":true}""", false, true to true),
        )
        for ((filter, present, absent) in cases) {
            assertEquals("$filter present", present, on(filter, mapOf("v" to "pro-plan")))
            assertEquals("$filter missing", absent.first, on(filter, emptyMap()))
            assertEquals("$filter empty", absent.second, on(filter, mapOf("v" to "")))
        }
        // "" is not set, so "is set" is false for it, and every negated operator matches it.
        assertFalse(on("""{"key":"v","op":"exists"}""", mapOf("v" to "")))
        assertTrue(on("""{"key":"v","op":"neq","value":"pro"}""", emptyMap()))
    }

    /*
     * A list is read as `JSON.parse` reads it, which is strict; org.json is not, and reads `[pro]` and
     * `['pro']` as a list of one. A list that does not decode says nothing, `not_in` included.
     */
    @Test
    fun `a list that does not decode matches nobody, however leniently org json would read it`() {
        for (bad in listOf("[]", "[pro]", "['pro']", "[\"pro\",1]", "[\"\"]", "[true]", "[1,]", "[01]", "pro")) {
            val escaped = JSONObject.quote(bad)
            assertFalse(bad, on("""{"key":"v","op":"in","value":$escaped}""", mapOf("v" to "pro")))
            assertFalse(bad, on("""{"key":"v","op":"not_in","value":$escaped}""", emptyMap()))
        }
        assertTrue(on("""{"key":"v","op":"in","value":"[\"a\\u0062c\"]"}""", mapOf("v" to "abc")))
        val fifty = (0 until 50).joinToString(",", "[", "]")
        assertTrue(on("""{"key":"v","op":"in","value":"$fifty"}""", mapOf("v" to 49)))
        val fiftyOne = (0 until 51).joinToString(",", "[", "]")
        assertFalse(on("""{"key":"v","op":"in","value":"$fiftyOne"}""", mapOf("v" to 49)))
        // SameValueZero, as JavaScript's `includes` compares: -0 is one of [0].
        assertTrue(on("""{"key":"v","op":"in","value":"[0]"}""", mapOf("v" to -0.0)))
    }

    /** With no `type` a number row matches only a number; under `type: 'number'`, text the grammar accepts whole. */
    @Test
    fun `a number row reads numbers strictly, and text only when typed`() {
        assertFalse(on("""{"key":"v","op":"eq","value":150}""", mapOf("v" to "150")))
        assertTrue(on("""{"key":"v","op":"eq","value":150,"type":"number"}""", mapOf("v" to "150")))
        assertTrue(on("""{"key":"v","op":"eq","value":150}""", mapOf("v" to 150.0)))
        for (text in listOf(" 42", "42 ", "42\n", "0x10", "inf", ".", "1d", "\u0661\u0662")) {
            assertFalse(text, on("""{"key":"v","op":"gte","value":0,"type":"number"}""", mapOf("v" to text)))
        }
        assertTrue(on("""{"key":"v","op":"gte","value":0,"type":"number"}""", mapOf("v" to "1e400")))
        // A boolean is not a number, and a boolean row compares text with no order.
        assertFalse(on("""{"key":"v","op":"eq","value":1}""", mapOf("v" to true)))
        assertTrue(on("""{"key":"v","op":"eq","value":true}""", mapOf("v" to "true")))
        assertFalse(on("""{"key":"v","op":"gt","value":true,"type":"boolean"}""", mapOf("v" to "zebra")))
    }

    @Test
    fun `a number is read as text the way JavaScript writes it`() {
        assertEquals("100", jsNumberText(100.0))
        assertEquals("1.5", jsNumberText(1.5))
        assertEquals("0.1", jsNumberText(0.1))
        assertEquals("10000000000000000", jsNumberText(1e16))
        assertEquals("123456789012345680000", jsNumberText(1.2345678901234568e20))
        assertEquals("1e+21", jsNumberText(1e21))
        assertEquals("0.000001", jsNumberText(0.000001))
        assertEquals("1e-7", jsNumberText(1e-7))
        assertEquals("-2.5e-8", jsNumberText(-2.5e-8))
        assertEquals("5e-324", jsNumberText(Double.MIN_VALUE))
        assertEquals("1.7976931348623157e+308", jsNumberText(Double.MAX_VALUE))
        assertEquals("0", jsNumberText(-0.0))
        assertTrue(on("""{"key":"v","op":"eq","value":"150"}""", mapOf("v" to 150)))
        assertTrue(on("""{"key":"v","op":"contains","value":"50"}""", mapOf("v" to 150.0)))
    }

    /** An element this SDK cannot read fails the WHOLE trigger, rather than being dropped. */
    @Test
    fun `a malformed element fails the whole trigger instead of being dropped`() {
        val pro = """{"key":"plan","op":"eq","value":"pro"}"""
        for (bad in listOf("null", "\"x\"", """{"op":"eq","value":"pro"}""", """{"key":7,"op":"eq","value":"pro"}""")) {
            assertFalse(bad, matches("[$pro,$bad]", mapOf("plan" to "pro")))
        }
        val notAList = JSONObject()
            .put("surface", "overlay")
            .put("layout", "modal")
            .put("trigger", JSONObject().put("kind", "event").put("event_name", "purchase").put("filters", "plan"))
        assertFalse(inAppTriggerMatches(parseInAppContent(notAList).trigger, "purchase", mapOf("plan" to "pro"), null))
    }

    /** A type or a side no reader knows answers nothing under every operator, and so does a dimension row with no dimensions given. */
    @Test
    fun `a type or side this SDK does not read fails closed`() {
        assertFalse(on("""{"key":"v","op":"eq","value":"pro","type":"colour"}""", mapOf("v" to "pro")))
        assertFalse(on("""{"key":"v","op":"exists","type":"colour"}""", mapOf("v" to "pro")))
        assertFalse(on("""{"key":"v","op":"eq","value":"pro","type":null}""", mapOf("v" to "pro")))
        assertFalse(on("""{"key":"v","op":"eq","value":"ios","source":"dimension"}""", mapOf("v" to "ios")))
        assertTrue(on("""{"key":"v","op":"eq","value":"ios","source":"property"}""", mapOf("v" to "ios")))
    }

    /** A list value whose JavaScript text is empty is an unfinished row, as JavaScript's `String(value)` reads it. */
    @Test
    fun `a list value with empty text is an unfinished row, and one that says nothing is not`() {
        for (value in listOf("[]", "[null]", "[\"\"]", "[[]]")) {
            assertTrue(value, on("""{"key":"plan","op":"eq","value":$value}""", mapOf("plan" to "team")))
        }
        assertFalse(on("""{"key":"plan","op":"eq","value":[null,null]}""", mapOf("plan" to "team")))
        assertFalse(on("""{"key":"plan","op":"eq","value":["team"]}""", mapOf("plan" to "team")))
        // `exists` reads no value, so an unreadable one changes nothing.
        assertTrue(on("""{"key":"plan","op":"exists","value":["team"]}""", mapOf("plan" to "team")))
    }

    // A dimension row reads the event's own map, and a version compares part by part.

    private fun dim(filter: String, dimensions: Map<String, Any?>?, properties: Map<String, Any?> = emptyMap()) =
        inAppTriggerMatches(trigger("[$filter]"), "purchase", properties, null, dimensions)

    @Test
    fun `a dimension row reads the dimension, and a property row never does`() {
        val dims = mapOf("platform_type" to "android")
        assertTrue(dim("""{"key":"platform_type","op":"eq","value":"android","source":"dimension"}""", dims, mapOf("platform_type" to "ios")))
        assertFalse(dim("""{"key":"platform_type","op":"eq","value":"ios","source":"dimension"}""", dims, mapOf("platform_type" to "ios")))
        assertTrue(dim("""{"key":"platform_type","op":"eq","value":"ios"}""", dims, mapOf("platform_type" to "ios")))
        assertFalse(dim("""{"key":"platform_type","op":"eq","value":"ios"}""", mapOf("platform_type" to "ios")))
    }

    @Test
    fun `geo, an unlisted name, an unknown side and a missing map are false under neq`() {
        assertFalse(dim("""{"key":"country","op":"neq","value":"DE","source":"dimension"}""", mapOf("country" to "FR")))
        assertFalse(dim("""{"key":"plan","op":"neq","value":"pro","source":"dimension"}""", emptyMap()))
        assertFalse(dim("""{"key":"platform_type","op":"neq","value":"ios","source":"dimension"}""", null))
        assertFalse(dim("""{"key":"platform_type","op":"neq","value":"ios","source":"device"}""", mapOf("platform_type" to "android")))
        // A map without the name is a map: the name is not set, and a negated operator matches it.
        assertTrue(dim("""{"key":"network_type","op":"neq","value":"wifi","source":"dimension"}""", mapOf("platform_type" to "android")))
    }

    @Test
    fun `a stamped value is normalised as ingest stores it`() {
        assertTrue(dim("""{"key":"device_model","op":"eq","value":"Pixel 8","source":"dimension"}""", mapOf("device_model" to "\uFEFF Pixel 8\n")))
        // U+001C is whitespace to Kotlin's trim() and not to JavaScript's, so it stays.
        assertFalse(dim("""{"key":"device_model","op":"eq","value":"Pixel 8","source":"dimension"}""", mapOf("device_model" to "Pixel 8\u001C")))
        val long = "x".repeat(200)
        assertTrue(dim("""{"key":"device_model","op":"eq","value":"${"x".repeat(128)}","source":"dimension"}""", mapOf("device_model" to long)))
        assertTrue(dim("""{"key":"screen_name","op":"eq","value":" Cart","source":"dimension"}""", mapOf("screen_name" to " Cart")))
        assertFalse(dim("""{"key":"device_model","op":"exists","source":"dimension"}""", mapOf("device_model" to "   ")))
    }

    private fun version(op: String, value: String, stamped: Any?) =
        dim("""{"key":"app_version","op":"$op","value":"$value","type":"version","source":"dimension"}""", mapOf("app_version" to stamped))

    @Test
    fun `versions compare by the measured pairs`() {
        assertTrue(version("gt", "2.9.1", "2.10"))
        assertTrue(version("eq", "2.3", "v2.3.0.0"))
        assertTrue(version("lt", "10.0", "9.9.9"))
        assertTrue("trimmed first, as ingest trims it", version("eq", "2.3", "2.3\n"))
        assertTrue(version("gte", "9999999999", "9999999999.0"))
    }

    @Test
    fun `a version that does not parse is false under neq and not_in, and set under exists`() {
        for (stamped in listOf("2.4.0-beta", "\uFF12.\uFF13", "+1", "1.2.3.4.5", "2.3 (45)", "00000000001")) {
            assertFalse(stamped, version("neq", "2.3", stamped))
            assertFalse(stamped, dim("""{"key":"app_version","op":"not_in","value":"[\"2.3\"]","type":"version","source":"dimension"}""", mapOf("app_version" to stamped)))
            assertTrue(stamped, dim("""{"key":"app_version","op":"exists","type":"version","source":"dimension"}""", mapOf("app_version" to stamped)))
        }
        // An authored value that does not parse says nothing, before the not-set reading.
        assertFalse(version("neq", "2.4.0-beta", null))
        assertTrue(dim("""{"key":"app_version","op":"neq","value":"2.3","type":"version","source":"dimension"}""", mapOf("platform_type" to "android")))
        // A property holding the number 2.3 is no version.
        assertFalse(on("""{"key":"v","op":"neq","value":"2.3","type":"version"}""", mapOf("v" to 2.3)))
    }
}
