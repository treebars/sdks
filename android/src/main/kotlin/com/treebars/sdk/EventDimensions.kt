package com.treebars.sdk

import com.treebars.sdk.generated.TreebarsConstants

/** One read of the device and the current screen, taken once per tracked event. */
internal class DeviceSnapshot(val device: Map<String, Any?>, val screen: String?)

/**
 * The dimensions an event is stamped with, from one snapshot: the SDK's own name and version, the screen
 * when there is one, and every device field but `os_api_level`, which travels in `device_extra` instead.
 *
 * `buildEvent` writes exactly these onto the event, and `track` hands exactly these to the in-app evaluator,
 * which is what makes a trigger's dimension rule read what the stored event will hold. One snapshot rather than
 * two reads, because the network type is read fresh each time and could differ between them.
 */
internal fun eventDimensions(device: Map<String, Any?>, screen: String?, sdkName: String): Map<String, Any?> =
    buildMap {
        put("sdk_version", TreebarsConstants.SDK_VERSION)
        put("sdk_name", sdkName)
        screen?.let { put("screen_name", it) }
        for ((key, value) in device) if (key != "os_api_level") put(key, value)
    }
