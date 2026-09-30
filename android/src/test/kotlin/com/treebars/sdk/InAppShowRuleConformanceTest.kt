//
// GENERATED — do not edit. Generated from the show-rule vectors every Treebars SDK is held to.
//
// The show rule, asked of this SDK.
//
// `inAppTriggerMatches` decides whether a message already on the device may be drawn by what
// just happened. The iOS SDK and the web SDK answer the same vectors, and
// the filter half has a reference implementation whose answers are recorded beside each vector.
//
// Every case prints its answer on a `SHOWRULE` line. The FILTER half asserts: a `kind: event` case
// whose answer differs from the recorded one fails this test, after every line has printed. The
// TRIGGER half only reports, and the SDKs' answers are compared with each other. Content that does
// not decode answers false: a device never stores a message it cannot parse.
//

package com.treebars.sdk

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class InAppShowRuleConformanceTest {

    private data class Vector(
        val id: String,
        val content: String,
        val event: String,
        val properties: String,
        val screen: String?,
        // The dimension map the SDK stamped on the event, read for a dimension row; "null" is none.
        val dimensions: String,
        // The reference's recorded answer on an event case, null on a trigger kind.
        val expected: Boolean?,
    )

    /**
     * org.json's null is a sentinel object, and a property holding it must read as absent.
     *
     * `exists` is the operator that can tell the difference, so mapping JSONObject.NULL to the
     * sentinel rather than to null would answer true for a property that was explicitly sent as
     * null — the one case the vectors ask about deliberately.
     */
    private fun unwrap(value: Any?): Any? = when (value) {
        JSONObject.NULL, null -> null
        is JSONObject -> value.keys().asSequence().associateWith { unwrap(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { unwrap(value.get(it)) }
        else -> value
    }

    @Test
    fun answersEveryVectorAndAgreesWithTheReferenceOnTheFilterHalf() {
        val vectors = listOf(
        Vector("SR-001", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"immediate\"}}", "anything", "{}", null, "null", null),
        Vector("SR-002", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"immediate\"}}", "session_end", "{\"a\":1}", "Cart", "null", null),
        Vector("SR-010", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"session_start\"}}", "session_start", "{}", null, "null", null),
        Vector("SR-011", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"session_start\"}}", "app_open", "{}", null, "null", null),
        Vector("SR-012", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"session_start\"}}", "app_foreground", "{}", null, "null", null),
        Vector("SR-020", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"screen_view\",\"screen_name\":\"Cart\"}}", "screen_view", "{}", "Cart", "null", null),
        Vector("SR-021", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"screen_view\",\"screen_name\":\"Cart\"}}", "screen_view", "{\"screen_name\":\"Cart\"}", null, "null", null),
        Vector("SR-022", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"screen_view\",\"screen_name\":\"Cart\"}}", "screen_view", "{\"name\":\"Cart\"}", null, "null", null),
        Vector("SR-023", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"screen_view\",\"screen_name\":\"Cart\"}}", "screen_view", "{\"screen_name\":\"Checkout\"}", "Cart", "null", null),
        Vector("SR-024", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"screen_view\",\"screen_name\":\"Cart\"}}", "screen_view", "{}", "Checkout", "null", null),
        Vector("SR-025", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"screen_view\",\"screen_name\":\"Cart\"}}", "screen_view", "{}", "cart", "null", null),
        Vector("SR-026", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"screen_view\",\"screen_name\":\"Cart\"}}", "page_view", "{}", "Cart", "null", null),
        Vector("SR-027", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"screen_view\"}}", "screen_view", "{}", null, "null", null),
        Vector("SR-028", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"screen_view\"}}", "screen_view", "{}", "Cart", "null", null),
        Vector("SR-029", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"screen_view\",\"screen_name\":\"Cart\"}}", "purchase", "{\"screen_name\":\"Cart\"}", "Cart", "null", null),
        Vector("SR-040", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\"}}", "purchase", "{}", null, "null", true),
        Vector("SR-041", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\"}}", "add_to_cart", "{}", null, "null", false),
        Vector("SR-042", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[]}}", "purchase", "{}", null, "null", true),
        Vector("SR-050", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"plan\",\"op\":\"eq\",\"value\":\"pro\"}]}}", "purchase", "{\"plan\":\"pro\"}", null, "null", true),
        Vector("SR-051", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"plan\",\"op\":\"eq\",\"value\":\"pro\"}]}}", "purchase", "{\"plan\":\"free\"}", null, "null", false),
        Vector("SR-052", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"value\",\"op\":\"eq\",\"value\":150}]}}", "purchase", "{\"value\":150}", null, "null", true),
        Vector("SR-053", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"value\",\"op\":\"eq\",\"value\":150}]}}", "purchase", "{\"value\":\"150\"}", null, "null", false),
        Vector("SR-054", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"value\",\"op\":\"eq\",\"value\":\"150\"}]}}", "purchase", "{\"value\":150}", null, "null", true),
        Vector("SR-055", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"gift\",\"op\":\"eq\",\"value\":true}]}}", "purchase", "{\"gift\":true}", null, "null", true),
        Vector("SR-056", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"gift\",\"op\":\"eq\",\"value\":true}]}}", "purchase", "{\"gift\":\"true\"}", null, "null", true),
        Vector("SR-060", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"plan\",\"op\":\"neq\",\"value\":\"pro\"}]}}", "purchase", "{\"plan\":\"free\"}", null, "null", true),
        Vector("SR-061", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"plan\",\"op\":\"neq\",\"value\":\"pro\"}]}}", "purchase", "{}", null, "null", true),
        Vector("SR-062", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"plan\",\"op\":\"neq\",\"value\":\"pro\"}]}}", "purchase", "{\"plan\":null}", null, "null", true),
        Vector("SR-063", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"plan\",\"op\":\"neq\",\"value\":\"pro\"}]}}", "purchase", "{\"plan\":\"\"}", null, "null", true),
        Vector("SR-064", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"sku\",\"op\":\"not_contains\",\"value\":\"BC\"}]}}", "purchase", "{}", null, "null", true),
        Vector("SR-065", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"plan\",\"op\":\"not_in\",\"value\":\"[\\\"free\\\",\\\"pro\\\"]\"}]}}", "purchase", "{}", null, "null", true),
        Vector("SR-066", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"coupon\",\"op\":\"not_exists\",\"value\":true}]}}", "purchase", "{}", null, "null", true),
        Vector("SR-070", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"coupon\",\"op\":\"exists\"}]}}", "purchase", "{\"coupon\":\"SAVE10\"}", null, "null", true),
        Vector("SR-071", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"coupon\",\"op\":\"exists\"}]}}", "purchase", "{}", null, "null", false),
        Vector("SR-072", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"coupon\",\"op\":\"exists\"}]}}", "purchase", "{\"coupon\":null}", null, "null", false),
        Vector("SR-073", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"coupon\",\"op\":\"exists\"}]}}", "purchase", "{\"coupon\":\"\"}", null, "null", false),
        Vector("SR-074", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"value\",\"op\":\"exists\"}]}}", "purchase", "{\"value\":0}", null, "null", true),
        Vector("SR-075", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"name\",\"op\":\"lt\",\"value\":\"m\"}]}}", "purchase", "{\"name\":\"\"}", null, "null", false),
        Vector("SR-076", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"plan\",\"op\":\"eq\",\"value\":\"pro\"}]}}", "purchase", "{\"plan\":\"\"}", null, "null", false),
        Vector("SR-080", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"sku\",\"op\":\"contains\",\"value\":\"BC\"}]}}", "purchase", "{\"sku\":\"ABC-1\"}", null, "null", true),
        Vector("SR-081", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"sku\",\"op\":\"contains\",\"value\":\"BC\"}]}}", "purchase", "{\"sku\":\"XYZ-1\"}", null, "null", false),
        Vector("SR-082", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"sku\",\"op\":\"contains\",\"value\":\"23\"}]}}", "purchase", "{\"sku\":12345}", null, "null", true),
        Vector("SR-083", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"value\",\"op\":\"contains\",\"value\":15}]}}", "purchase", "{\"value\":\"150\"}", null, "null", false),
        Vector("SR-090", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"value\",\"op\":\"gt\",\"value\":100}]}}", "purchase", "{\"value\":150}", null, "null", true),
        Vector("SR-091", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"value\",\"op\":\"gt\",\"value\":100}]}}", "purchase", "{\"value\":5}", null, "null", false),
        Vector("SR-092", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"value\",\"op\":\"gte\",\"value\":100}]}}", "purchase", "{\"value\":100}", null, "null", true),
        Vector("SR-093", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"value\",\"op\":\"gt\",\"value\":100}]}}", "purchase", "{\"value\":\"150\"}", null, "null", false),
        Vector("SR-094", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"value\",\"op\":\"gt\",\"value\":100}]}}", "purchase", "{\"value\":\"lots\"}", null, "null", false),
        Vector("SR-095", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"version\",\"op\":\"gt\",\"value\":\"1.9\"}]}}", "purchase", "{\"version\":\"1.10\"}", null, "null", false),
        Vector("SR-096", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"value\",\"op\":\"lt\",\"value\":100}]}}", "purchase", "{\"value\":5}", null, "null", true),
        Vector("SR-097", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"value\",\"op\":\"lte\",\"value\":100}]}}", "purchase", "{\"value\":100}", null, "null", true),
        Vector("SR-098", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"value\",\"op\":\"gt\",\"value\":100}]}}", "purchase", "{}", null, "null", false),
        Vector("SR-099", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"gift\",\"op\":\"gt\",\"value\":0}]}}", "purchase", "{\"gift\":true}", null, "null", false),
        Vector("SR-110", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"cart.size\",\"op\":\"gte\",\"value\":2}]}}", "purchase", "{\"cart\":{\"size\":3}}", null, "null", false),
        Vector("SR-111", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"cart.size\",\"op\":\"gte\",\"value\":2}]}}", "purchase", "{\"cart\":{}}", null, "null", false),
        Vector("SR-112", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"cart.size\",\"op\":\"gte\",\"value\":2}]}}", "purchase", "{\"cart.size\":3}", null, "null", true),
        Vector("SR-120", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"plan\",\"op\":\"eq\",\"value\":\"pro\"},{\"key\":\"value\",\"op\":\"gt\",\"value\":100}]}}", "purchase", "{\"plan\":\"pro\",\"value\":150}", null, "null", true),
        Vector("SR-121", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"plan\",\"op\":\"eq\",\"value\":\"pro\"},{\"key\":\"value\",\"op\":\"gt\",\"value\":100}]}}", "purchase", "{\"plan\":\"pro\",\"value\":5}", null, "null", false),
        Vector("SR-130", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"\",\"op\":\"eq\",\"value\":\"\"}]}}", "purchase", "{\"plan\":\"pro\"}", null, "null", true),
        Vector("SR-131", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"plan\",\"op\":\"eq\",\"value\":\"\"}]}}", "purchase", "{\"plan\":\"pro\"}", null, "null", true),
        Vector("SR-132", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"plan\",\"op\":\"eq\",\"value\":\"pro\"},{\"key\":\"\",\"op\":\"eq\",\"value\":\"\"}]}}", "purchase", "{\"plan\":\"pro\"}", null, "null", true),
        Vector("SR-133", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"plan\",\"op\":\"eq\"}]}}", "purchase", "{\"plan\":\"pro\"}", null, "null", true),
        Vector("SR-134", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"plan\",\"op\":\"eq\",\"value\":[]}]}}", "purchase", "{\"plan\":\"team\"}", null, "null", true),
        Vector("SR-135", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"plan\",\"op\":\"eq\",\"value\":[null,null]}]}}", "purchase", "{\"plan\":\"team\"}", null, "null", false),
        Vector("SR-140", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"plan\",\"op\":\"matches_regex\",\"value\":\"^pro\"}]}}", "purchase", "{\"plan\":\"pro\"}", null, "null", false),
        Vector("SR-141", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"inactivity\",\"event_name\":\"purchase\"}}", "purchase", "{}", null, "null", null),
        Vector("SR-142", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\"}}", "purchase", "{}", null, "null", false),
        Vector("SR-150", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[null]}}", "purchase", "{\"plan\":\"pro\"}", null, "null", false),
        Vector("SR-151", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"op\":\"eq\",\"value\":\"pro\"}]}}", "purchase", "{\"plan\":\"pro\"}", null, "null", false),
        Vector("SR-152", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":7,\"op\":\"eq\",\"value\":\"pro\"}]}}", "purchase", "{\"7\":\"pro\"}", null, "null", false),
        Vector("SR-153", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":\"plan\"}}", "purchase", "{\"plan\":\"pro\"}", null, "null", false),
        Vector("SR-154", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"plan\",\"op\":\"eq\",\"value\":[\"pro\"]}]}}", "purchase", "{\"plan\":\"pro\"}", null, "null", false),
        Vector("SR-155", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"plan\",\"op\":\"exists\",\"value\":[\"pro\"]}]}}", "purchase", "{\"plan\":\"pro\"}", null, "null", true),
        Vector("SR-156", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"plan\",\"op\":\"eq\",\"value\":\"pro\",\"type\":\"colour\"}]}}", "purchase", "{\"plan\":\"pro\"}", null, "null", false),
        Vector("SR-157", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"plan\",\"op\":\"exists\",\"type\":\"colour\"}]}}", "purchase", "{\"plan\":\"pro\"}", null, "null", false),
        Vector("SR-158", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"plan\",\"op\":\"eq\",\"value\":\"pro\",\"type\":null}]}}", "purchase", "{\"plan\":\"pro\"}", null, "null", false),
        Vector("SR-159", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"amount\",\"op\":\"gte\",\"value\":0,\"type\":\"number\"}]}}", "purchase", "{\"amount\":\"42\\n\"}", null, "null", false),
        Vector("SR-160", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"platform_type\",\"op\":\"eq\",\"value\":\"ios\"}]}}", "purchase", "{\"platform_type\":\"ios\"}", null, "{\"platform_type\":\"android\"}", true),
        Vector("SR-161", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"platform_type\",\"op\":\"eq\",\"value\":\"ios\",\"source\":\"dimension\"}]}}", "purchase", "{\"platform_type\":\"ios\"}", null, "{\"platform_type\":\"android\"}", false),
        Vector("SR-162", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"platform_type\",\"op\":\"eq\",\"value\":\"android\",\"source\":\"dimension\"}]}}", "purchase", "{\"platform_type\":\"ios\"}", null, "{\"platform_type\":\"android\"}", true),
        Vector("SR-163", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"platform_type\",\"op\":\"eq\",\"value\":\"android\"}]}}", "purchase", "{\"platform_type\":\"android\"}", null, "{\"platform_type\":\"ios\"}", true),
        Vector("SR-164", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"platform_type\",\"op\":\"eq\",\"value\":\"ios\",\"source\":\"device\"}]}}", "purchase", "{\"platform_type\":\"ios\"}", null, "{\"platform_type\":\"ios\"}", false),
        Vector("SR-165", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"platform_type\",\"op\":\"neq\",\"value\":\"ios\",\"source\":\"device\"}]}}", "purchase", "{\"platform_type\":\"android\"}", null, "{\"platform_type\":\"android\"}", false),
        Vector("SR-166", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"country\",\"op\":\"eq\",\"value\":\"DE\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"country\":\"DE\"}", false),
        Vector("SR-167", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"country\",\"op\":\"neq\",\"value\":\"DE\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{}", false),
        Vector("SR-168", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"region\",\"op\":\"eq\",\"value\":\"BE\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"region\":\"BE\"}", false),
        Vector("SR-169", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"city\",\"op\":\"neq\",\"value\":\"Berlin\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"city\":\"Berlin\"}", false),
        Vector("SR-170", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"carrier\",\"op\":\"neq\",\"value\":\"Vodafone\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"carrier\":\"Vodafone\"}", false),
        Vector("SR-171", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"platform_type\",\"op\":\"eq\",\"value\":\"ios\",\"source\":\"dimension\"}]}}", "purchase", "{\"platform_type\":\"ios\"}", null, "null", false),
        Vector("SR-172", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"platform_type\",\"op\":\"neq\",\"value\":\"ios\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "null", false),
        Vector("SR-173", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"neq\",\"value\":\"2.3\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"platform_type\":\"web\"}", true),
        Vector("SR-174", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"gte\",\"value\":\"2.3\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"platform_type\":\"web\"}", false),
        Vector("SR-175", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"screen_name\",\"op\":\"neq\",\"value\":\"Cart\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"screen_name\":\"\"}", true),
        Vector("SR-176", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"screen_name\",\"op\":\"exists\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"screen_name\":\"\"}", false),
        Vector("SR-177", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"lt\",\"value\":\"2.10\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"2.3.1\"}", true),
        Vector("SR-178", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"gt\",\"value\":\"9.9.9\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"10.0\"}", true),
        Vector("SR-179", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"gt\",\"value\":\"2.0.10\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"2.1.0\"}", true),
        Vector("SR-180", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"eq\",\"value\":\"2.3\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"2.3.0\"}", true),
        Vector("SR-181", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"eq\",\"value\":\"2.3\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"v2.3.0.0\"}", true),
        Vector("SR-182", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"gte\",\"value\":\"2.3\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"2.4.0-beta\"}", false),
        Vector("SR-183", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"neq\",\"value\":\"2.3\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"2.4.0-beta\"}", false),
        Vector("SR-184", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"not_in\",\"value\":\"[\\\"2.3\\\"]\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"2.4.0-beta\"}", false),
        Vector("SR-185", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"exists\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"2.4.0-beta\"}", true),
        Vector("SR-186", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"gte\",\"value\":\"2.3\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"2.3\\n\"}", true),
        Vector("SR-187", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"neq\",\"value\":\"2.3\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"2.3\\n\"}", false),
        Vector("SR-188", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"not_in\",\"value\":\"[\\\"2.3\\\"]\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"2.3\\n\"}", false),
        Vector("SR-189", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"exists\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"2.3\\n\"}", true),
        Vector("SR-190", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"gte\",\"value\":\"2.3\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"２.３\"}", false),
        Vector("SR-191", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"neq\",\"value\":\"2.3\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"２.３\"}", false),
        Vector("SR-192", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"not_in\",\"value\":\"[\\\"2.3\\\"]\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"２.３\"}", false),
        Vector("SR-193", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"exists\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"２.３\"}", true),
        Vector("SR-194", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"gte\",\"value\":\"2.3\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"+1\"}", false),
        Vector("SR-195", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"neq\",\"value\":\"2.3\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"+1\"}", false),
        Vector("SR-196", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"not_in\",\"value\":\"[\\\"2.3\\\"]\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"+1\"}", false),
        Vector("SR-197", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"exists\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"+1\"}", true),
        Vector("SR-198", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"gte\",\"value\":\"2.3\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"1.2.3.4.5\"}", false),
        Vector("SR-199", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"neq\",\"value\":\"2.3\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"1.2.3.4.5\"}", false),
        Vector("SR-200", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"not_in\",\"value\":\"[\\\"2.3\\\"]\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"1.2.3.4.5\"}", false),
        Vector("SR-201", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"exists\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"1.2.3.4.5\"}", true),
        Vector("SR-202", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"gte\",\"value\":\"2.3\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"00000000001\"}", false),
        Vector("SR-203", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"neq\",\"value\":\"2.3\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"00000000001\"}", false),
        Vector("SR-204", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"not_in\",\"value\":\"[\\\"2.3\\\"]\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"00000000001\"}", false),
        Vector("SR-205", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"exists\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"00000000001\"}", true),
        Vector("SR-206", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"gte\",\"value\":\"2.3\",\"type\":\"version\"}]}}", "purchase", "{\"app_version\":2.3}", null, "null", false),
        Vector("SR-207", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"neq\",\"value\":\"2.3\",\"type\":\"version\"}]}}", "purchase", "{\"app_version\":2.3}", null, "null", false),
        Vector("SR-208", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"not_in\",\"value\":\"[\\\"2.3\\\"]\",\"type\":\"version\"}]}}", "purchase", "{\"app_version\":2.3}", null, "null", false),
        Vector("SR-209", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"exists\",\"type\":\"version\"}]}}", "purchase", "{\"app_version\":2.3}", null, "null", true),
        Vector("SR-210", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"eq\",\"value\":\"2.3\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"platform_type\":\"ios\"}", false),
        Vector("SR-211", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"neq\",\"value\":\"2.3\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"platform_type\":\"ios\"}", true),
        Vector("SR-212", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"in\",\"value\":\"[\\\"2.3\\\"]\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"platform_type\":\"ios\"}", false),
        Vector("SR-213", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"not_in\",\"value\":\"[\\\"2.3\\\"]\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"platform_type\":\"ios\"}", true),
        Vector("SR-214", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"gt\",\"value\":\"2.3\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"platform_type\":\"ios\"}", false),
        Vector("SR-215", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"gte\",\"value\":\"2.3\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"platform_type\":\"ios\"}", false),
        Vector("SR-216", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"lt\",\"value\":\"2.3\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"platform_type\":\"ios\"}", false),
        Vector("SR-217", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"lte\",\"value\":\"2.3\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"platform_type\":\"ios\"}", false),
        Vector("SR-218", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"exists\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"platform_type\":\"ios\"}", false),
        Vector("SR-219", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"not_exists\",\"value\":true,\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"platform_type\":\"ios\"}", true),
        Vector("SR-220", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"eq\",\"value\":\"2.3\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"\"}", false),
        Vector("SR-221", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"neq\",\"value\":\"2.3\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"\"}", true),
        Vector("SR-222", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"in\",\"value\":\"[\\\"2.3\\\"]\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"\"}", false),
        Vector("SR-223", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"not_in\",\"value\":\"[\\\"2.3\\\"]\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"\"}", true),
        Vector("SR-224", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"gt\",\"value\":\"2.3\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"\"}", false),
        Vector("SR-225", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"gte\",\"value\":\"2.3\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"\"}", false),
        Vector("SR-226", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"lt\",\"value\":\"2.3\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"\"}", false),
        Vector("SR-227", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"lte\",\"value\":\"2.3\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"\"}", false),
        Vector("SR-228", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"exists\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"\"}", false),
        Vector("SR-229", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"not_exists\",\"value\":true,\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"\"}", true),
        Vector("SR-230", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"in\",\"value\":\"[\\\"2.10\\\",\\\"2.3\\\"]\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"2.3.0\"}", true),
        Vector("SR-231", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"not_in\",\"value\":\"[\\\"2.10\\\",\\\"2.3\\\"]\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"app_version\":\"2.3.0\"}", false),
        Vector("SR-232", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"build\",\"op\":\"gt\",\"value\":\"2.9\",\"type\":\"version\"}]}}", "purchase", "{\"build\":\"2.10\"}", null, "null", true),
        Vector("SR-233", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"neq\",\"value\":\"2.4.0-beta\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"platform_type\":\"web\"}", false),
        Vector("SR-234", "{\"surface\":\"overlay\",\"layout\":\"modal\",\"trigger\":{\"kind\":\"event\",\"event_name\":\"purchase\",\"filters\":[{\"key\":\"app_version\",\"op\":\"not_in\",\"value\":\"[\\\"2.3\\\",\\\"beta\\\"]\",\"type\":\"version\",\"source\":\"dimension\"}]}}", "purchase", "{}", null, "{\"platform_type\":\"web\"}", false),
        )

        val disagreements = mutableListOf<String>()
        for (vector in vectors) {
            val trigger = try {
                parseInAppContent(JSONObject(vector.content)).trigger
            } catch (error: Exception) {
                println("SHOWRULE ${vector.id} false")
                if (vector.expected == true) disagreements += "${vector.id}: false, the reference records true"
                continue
            }
            @Suppress("UNCHECKED_CAST")
            val properties = unwrap(JSONObject(vector.properties)) as Map<String, Any?>
            @Suppress("UNCHECKED_CAST")
            val dimensions = if (vector.dimensions == "null") null else unwrap(JSONObject(vector.dimensions)) as Map<String, Any?>

            val answer = inAppTriggerMatches(trigger, vector.event, properties, vector.screen, dimensions)

            println("SHOWRULE ${vector.id} $answer")
            if (vector.expected != null && answer != vector.expected) {
                disagreements += "${vector.id}: $answer, the reference records ${vector.expected}"
            }
        }

        // Once, after every line has printed, so rules.mjs still reads the whole table.
        assertTrue(
            "The filter half disagrees with the reference's recorded answer:\n" + disagreements.joinToString("\n"),
            disagreements.isEmpty(),
        )
    }
}
