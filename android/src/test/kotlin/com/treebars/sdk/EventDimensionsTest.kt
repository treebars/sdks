package com.treebars.sdk

import com.treebars.sdk.generated.TreebarsConstants
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The one function that says what an event is stamped with. `buildEvent` writes its map onto
 * the event and `track` hands the same map to the in-app evaluator, both from one snapshot — so these pin the
 * map itself, and the evaluator tests pin what a trigger reads of it.
 */
class EventDimensionsTest {

    private val device = mapOf<String, Any?>(
        "platform_type" to "android",
        "os_version" to "15",
        "network_type" to "wifi",
        "os_api_level" to 35,
    )

    @Test
    fun `carries the SDK, the screen and every device field but the API level`() {
        val stamped = eventDimensions(device, "Cart", "treebars-android")
        assertEquals("treebars-android", stamped["sdk_name"])
        assertEquals(TreebarsConstants.SDK_VERSION, stamped["sdk_version"])
        assertEquals("Cart", stamped["screen_name"])
        assertEquals("wifi", stamped["network_type"])
        // `os_api_level` is no dimension: it rides in `device_extra`, and a trigger cannot name it.
        assertFalse(stamped.containsKey("os_api_level"))
        assertFalse(TreebarsConstants.IN_APP_DIMENSIONS.contains("os_api_level"))
    }

    @Test
    fun `leaves the screen out when there is none, rather than stamping an empty one`() {
        assertFalse(eventDimensions(device, null, "treebars-android").containsKey("screen_name"))
    }

    @Test
    fun `stamps only names an in-app trigger may read, so the evaluator is handed nothing it would refuse`() {
        val stamped = eventDimensions(device, "Cart", "treebars-android")
        assertTrue(stamped.keys.all { it in TreebarsConstants.IN_APP_DIMENSIONS })
    }
}
