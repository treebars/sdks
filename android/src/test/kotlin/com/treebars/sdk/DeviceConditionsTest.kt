@file:Suppress("DEPRECATION")

package com.treebars.sdk

import android.content.Context
import android.content.ContextWrapper
import android.net.ConnectivityManager
import android.net.NetworkInfo
import android.os.PowerManager
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.shadows.ShadowNetworkInfo

/**
 * What the device is asked before an upload is armed, and what it is told when the network comes
 * back — and that neither can crash a host app that took the network permission away.
 */
@RunWith(RobolectricTestRunner::class)
class DeviceConditionsTest {

    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val connectivity get() = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val power get() = context.getSystemService(Context.POWER_SERVICE) as PowerManager

    @Suppress("DEPRECATION")
    private fun network(type: Int): NetworkInfo =
        ShadowNetworkInfo.newInstance(NetworkInfo.DetailedState.CONNECTED, type, 0, true, NetworkInfo.State.CONNECTED)

    @Suppress("DEPRECATION")
    private fun onWifi() = shadowOf(connectivity).setActiveNetworkInfo(network(ConnectivityManager.TYPE_WIFI))

    @Suppress("DEPRECATION")
    private fun onMobile() = shadowOf(connectivity).setActiveNetworkInfo(network(ConnectivityManager.TYPE_MOBILE))

    /** A host app without the permission: every system service this SDK asks for refuses. */
    private fun refusing(): Context = object : ContextWrapper(context) {
        override fun getSystemService(name: String): Any? = throw SecurityException("no ACCESS_NETWORK_STATE")
    }

    @Test
    fun `an ordinary device on wifi is neither metered nor saving anything`() {
        onWifi()
        assertEquals(UploadConditions(constrained = false, metered = false), DeviceConditions.read(context))
    }

    @Test
    fun `a mobile network is metered`() {
        onMobile()
        assertEquals(UploadConditions(constrained = false, metered = true), DeviceConditions.read(context))
    }

    @Test
    fun `battery saver is a device saving power`() {
        onWifi()
        shadowOf(power).setIsPowerSaveMode(true)
        assertEquals(UploadConditions(constrained = true, metered = false), DeviceConditions.read(context))
    }

    @Test
    fun `data saver is a device saving data, unless the person exempted this app`() {
        onMobile()
        shadowOf(connectivity).setRestrictBackgroundStatus(ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED)
        assertEquals(UploadConditions(constrained = true, metered = true), DeviceConditions.read(context))

        shadowOf(connectivity).setRestrictBackgroundStatus(ConnectivityManager.RESTRICT_BACKGROUND_STATUS_WHITELISTED)
        assertEquals(UploadConditions(constrained = false, metered = true), DeviceConditions.read(context))

        shadowOf(connectivity).setRestrictBackgroundStatus(ConnectivityManager.RESTRICT_BACKGROUND_STATUS_DISABLED)
        assertEquals(UploadConditions(constrained = false, metered = true), DeviceConditions.read(context))
    }

    @Test
    fun `a device that cannot be asked reads as unmetered and saving nothing`() {
        onMobile()
        shadowOf(power).setIsPowerSaveMode(true)
        assertEquals(UploadConditions(), DeviceConditions.read(refusing()))
    }

    @Test
    fun `the network coming back is reported once, and only after it went`() {
        onWifi()
        var regained = 0
        val watch = NetworkWatch(context) { regained += 1 }
        watch.start()
        val callback = shadowOf(connectivity).networkCallbacks.single()
        val network = connectivity.activeNetwork!!

        // Registering answers with the network that was already there, and so does moving to another.
        callback.onAvailable(network)
        callback.onAvailable(network)
        assertEquals(0, regained)

        callback.onLost(network)
        assertEquals(0, regained)
        callback.onAvailable(network)
        assertEquals(1, regained)
        callback.onAvailable(network)
        assertEquals(1, regained)

        watch.stop()
        assertTrue("nothing is left registered once the app is behind", shadowOf(connectivity).networkCallbacks.isEmpty())
        // Stopping twice, and starting twice, are each one registration.
        watch.stop()
        watch.start()
        watch.start()
        assertEquals(1, shadowOf(connectivity).networkCallbacks.size)
        watch.stop()
    }

    @Test
    fun `a device that starts without a network reports the first one it gets`() {
        @Suppress("DEPRECATION")
        shadowOf(connectivity).setActiveNetworkInfo(null)
        var regained = 0
        val watch = NetworkWatch(context) { regained += 1 }
        watch.start()
        onWifi()
        shadowOf(connectivity).networkCallbacks.single().onAvailable(connectivity.activeNetwork!!)
        assertEquals(1, regained)
        watch.stop()
    }

    @Test
    fun `watching is skipped in silence where the permission is missing, and a listener that throws is contained`() {
        val unwatched = NetworkWatch(refusing()) { error("never called") }
        unwatched.start()
        unwatched.stop()

        @Suppress("DEPRECATION")
        shadowOf(connectivity).setActiveNetworkInfo(null)
        val watch = NetworkWatch(context) { error("the host's own failure") }
        watch.start()
        onWifi()
        // On the system's thread, where an exception would take the app down.
        shadowOf(connectivity).networkCallbacks.single().onAvailable(connectivity.activeNetwork!!)
        watch.stop()
    }
}
