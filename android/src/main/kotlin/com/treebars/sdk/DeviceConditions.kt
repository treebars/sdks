package com.treebars.sdk

import android.annotation.SuppressLint
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.os.PowerManager

/**
 * The device's own answers for [UploadConditions], and the one place this SDK asks for them.
 *
 * Each question is asked on its own and fails to false. Battery Saver and Data Saver need no
 * permission; whether the network is metered needs `ACCESS_NETWORK_STATE`, which this SDK's manifest
 * declares and a host app may still remove. A read that is refused, or that throws for any other
 * reason, answers as an unmetered device that is saving nothing: the pace is a courtesy to the
 * person's battery and bill, and never worth a crash or a line in the log on every event.
 */
internal object DeviceConditions {

    fun read(context: Context): UploadConditions = UploadConditions(
        constrained = savingPower(context) || savingData(context),
        metered = metered(context),
    )

    private fun connectivity(context: Context): ConnectivityManager? =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager

    private fun savingPower(context: Context): Boolean = runCatching {
        (context.getSystemService(Context.POWER_SERVICE) as? PowerManager)?.isPowerSaveMode == true
    }.getOrDefault(false)

    /** Data Saver is on and this app is held to it; an app the person exempted is not saving data. */
    private fun savingData(context: Context): Boolean = runCatching {
        connectivity(context)?.restrictBackgroundStatus == ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED
    }.getOrDefault(false)

    @SuppressLint("MissingPermission")
    private fun metered(context: Context): Boolean = runCatching {
        connectivity(context)?.isActiveNetworkMetered == true
    }.getOrDefault(false)
}

/**
 * Tells the SDK when the device gets its network back, so what was queued while it had none goes
 * out then rather than with the next event.
 *
 * The default network's callback, which needs `ACCESS_NETWORK_STATE` like the metered read. Without
 * it [start] does nothing and says nothing: the queue is still sent by the next event, the next
 * retry and the way to the background, only later.
 *
 * Watched only while the app is in front ([start] and [stop] follow the process lifecycle). A
 * callback left registered would wake a backgrounded app for an upload nobody is waiting on.
 */
internal class NetworkWatch(
    private val context: Context,
    /** Called on the system's own thread, so it must hand the work off rather than do it. */
    private val regained: () -> Unit,
) {

    /**
     * Whether the device was last seen without a network. Registering answers with the network
     * already there, and so does moving from one network to another; neither is getting it back,
     * and only an answer that follows a loss is reported.
     */
    @Volatile
    private var offline = false

    private var registered = false

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            if (!offline) return
            offline = false
            runCatching { regained() }
        }

        override fun onLost(network: Network) {
            offline = true
        }
    }

    @SuppressLint("MissingPermission")
    @Synchronized
    fun start() {
        if (registered) return
        runCatching {
            val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: return@runCatching
            offline = manager.activeNetwork == null
            manager.registerDefaultNetworkCallback(callback)
            registered = true
        }
    }

    @Synchronized
    fun stop() {
        if (!registered) return
        registered = false
        runCatching {
            (context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager)
                ?.unregisterNetworkCallback(callback)
        }
    }
}
