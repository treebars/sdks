package com.treebars.sdk

import android.app.NotificationManager
import android.content.Context
import android.content.ContextWrapper
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf

/**
 * The two gates that decide whether a launch says anything about the device.
 *
 * They differ on purpose. For the context report, asking and recording are separate calls
 * (`shouldReportContext` / `rememberReportedContext`); for the notification permission, asking IS
 * the recording. Each order is asserted below with the reason for it.
 */
@RunWith(RobolectricTestRunner::class)
class DeviceInfoTest {

    private val app: Context get() = ApplicationProvider.getApplicationContext()

    private fun prefs() = app.getSharedPreferences(Treebars.PREFS_NAME, Context.MODE_PRIVATE)

    private fun storedContextRecord(): String? = prefs().getString("device_context_hash", null)

    private fun seedContextRecord(value: String) =
        prefs().edit().putString("device_context_hash", value).commit()

    private fun storedPermission(): String? = prefs().getString("notification_permission", null)

    private fun notificationsEnabled(enabled: Boolean) =
        shadowOf(app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .setNotificationsEnabled(enabled)

    @Before
    fun clearStore() {
        prefs().edit().clear().commit()
    }

    /*
     * ---------------------------------------------------------------------------------------
     * A. The TTL on `device_context`.
     *
     * `device_context` is what registers the device with Treebars, and the hash gate suppresses
     * it once it has been sent. Without a TTL that is a one-way promise about a record the
     * handset cannot see, so anything that removed the record — a project reset, a privacy
     * erase — would leave the device silent while it went on sending events, and unreachable by
     * any broadcast to registered devices. Nothing on the device could notice. The TTL is what
     * asks it to try again.
     *
     * There is no injectable clock here, so each case seeds the stored record with a timestamp
     * at a chosen distance from now.
     * ---------------------------------------------------------------------------------------
     */

    private val day = 24L * 60 * 60 * 1000

    @Test
    fun `an unchanged context reported today is not reported again`() {
        val record = "aaaa:${System.currentTimeMillis() - day}"
        seedContextRecord(record)

        assertFalse(DeviceInfo.shouldReportContext(app, "aaaa"))
        // And the ask did not refresh the record. If it did, a device opened daily would push
        // its own expiry out forever and the repair above would never fire on the installs that
        // need it most — the ones in constant use.
        assertEquals(record, storedContextRecord())
    }

    @Test
    fun `a changed context is reported however recently the last one went`() {
        seedContextRecord("aaaa:${System.currentTimeMillis() - 60_000}")

        assertTrue(DeviceInfo.shouldReportContext(app, "bbbb"))
        // Asking does not write. The record only moves once the report has actually been
        // made — see `the report is recorded separately` below.
        assertTrue("the old record is untouched by the ask", storedContextRecord()!!.startsWith("aaaa:"))

        DeviceInfo.rememberReportedContext(app, "bbbb")
        assertTrue("the new hash replaces the old", storedContextRecord()!!.startsWith("bbbb:"))
    }

    @Test
    fun `an unchanged context goes again once the report is a week old`() {
        seedContextRecord("aaaa:${System.currentTimeMillis() - 6 * day}")
        assertFalse(DeviceInfo.shouldReportContext(app, "aaaa"))

        seedContextRecord("aaaa:${System.currentTimeMillis() - 8 * day}")
        assertTrue(DeviceInfo.shouldReportContext(app, "aaaa"))
    }

    @Test
    fun `a record from before the timestamp existed re-reports once, which refreshes it`() {
        // A bare hash with no timestamp is re-reported once rather than trusted, and is in the
        // current shape by the next launch.
        seedContextRecord("aaaa")
        assertTrue(DeviceInfo.shouldReportContext(app, "aaaa"))

        DeviceInfo.rememberReportedContext(app, "aaaa")
        assertFalse("once, not every launch", DeviceInfo.shouldReportContext(app, "aaaa"))

        seedContextRecord("aaaa:not-a-number")
        assertTrue(DeviceInfo.shouldReportContext(app, "aaaa"))
    }

    @Test
    fun `nothing stored is nothing reported`() {
        assertTrue(DeviceInfo.shouldReportContext(app, "aaaa"))
    }

    @Test
    fun `the report is recorded separately, so a lost one is retried`() {
        /*
         * Asking does not close the question. If `shouldReportContext` stored the hash before
         * the event existed, a `device_context` that then failed to enqueue would leave the
         * device suppressed for the whole seven-day TTL, having never reported once — and
         * nothing above could tell that from a device whose context genuinely had not changed.
         * An unregistered device is also unreachable by any broadcast to registered devices.
         */
        assertTrue(DeviceInfo.shouldReportContext(app, "deadbeef"))
        assertNull("asking alone records nothing", storedContextRecord())

        // Asked again, and still true: nothing was spent by the question.
        assertTrue(DeviceInfo.shouldReportContext(app, "deadbeef"))

        val before = System.currentTimeMillis()
        DeviceInfo.rememberReportedContext(app, "deadbeef")

        val record = storedContextRecord()!!
        assertEquals("deadbeef", record.substringBeforeLast(':'))
        assertTrue(
            "the record carries the moment it was written",
            record.substringAfterLast(':').toLong() >= before,
        )
        assertFalse(DeviceInfo.shouldReportContext(app, "deadbeef"))
    }

    /*
     * ---------------------------------------------------------------------------------------
     * B. `notification_permission_changed`, and the rule that keeps it from lying to a fleet.
     *
     * A transition happened at a moment in time. It is not derivable from the state that
     * follows it, which is the whole reason the event exists — the reported device context says
     * who is reachable now, and only this says how many people turned notifications off last month.
     * That makes a fabricated transition worse than a missing one, and there is exactly one way
     * to fabricate them at scale: treating the first observation as a change. Every install in
     * the fleet observes for the first time on the day the SDK carrying this ships.
     * ---------------------------------------------------------------------------------------
     */

    @Test
    fun `the first observation records the value and reports no change`() {
        notificationsEnabled(true)

        assertNull(DeviceInfo.pendingPermissionChange(app))
        // Recorded, so the *next* flip has something to be a transition from.
        assertEquals("authorized", storedPermission())
    }

    @Test
    fun `a flip after that is a change, with both ends named`() {
        notificationsEnabled(true)
        DeviceInfo.pendingPermissionChange(app)

        notificationsEnabled(false)
        assertEquals("authorized" to "denied", DeviceInfo.pendingPermissionChange(app))
    }

    @Test
    fun `an unchanged permission reports nothing, however often it is asked`() {
        // This runs on every foreground. An event per app open would be the whole fleet's
        // volume, for a value that did not move.
        notificationsEnabled(false)
        DeviceInfo.pendingPermissionChange(app)

        assertNull(DeviceInfo.pendingPermissionChange(app))
        assertNull(DeviceInfo.pendingPermissionChange(app))
    }

    @Test
    fun `a transition is recorded before it is reported, so it cannot be emitted twice`() {
        /*
         * The opposite order from `shouldReportContext` above, and deliberately. A lost context
         * report leaves a device unregistered and unreachable by broadcasts, so it must be
         * retried; a lost change event leaves one gap in a series.
         * Double-counting an opt-out would be worse than missing one.
         */
        notificationsEnabled(true)
        DeviceInfo.pendingPermissionChange(app)

        notificationsEnabled(false)
        assertEquals("authorized" to "denied", DeviceInfo.pendingPermissionChange(app))
        assertNull(DeviceInfo.pendingPermissionChange(app))
    }

    @Test
    fun `a platform with nothing to say produces no change at all`() {
        /*
         * No answer is NOT `not_determined`, which is a real state a person's device could be
         * in and not ours to manufacture — and it must not become a transition to or from
         * anything. On iOS it is the moment before the settings callback has come back; on
         * Android the notification service is always there, so the only way to have nothing to
         * say is not to have the service, and that is what this hands the gate.
         */
        val silent = object : ContextWrapper(app) {
            override fun getSystemService(name: String): Any? =
                if (name == Context.NOTIFICATION_SERVICE) null else super.getSystemService(name)
        }

        assertNull(DeviceInfo.pendingPermissionChange(silent))
        assertNull("nothing recorded either, so a real answer later is still a first sight", storedPermission())
    }

    /*
     * ---------------------------------------------------------------------------------------
     * C. `is_emulator`, for current Google emulator images as well as the older `generic` ones.
     * Real values, copied from the devices.
     * ---------------------------------------------------------------------------------------
     */

    @Test
    fun `a current Google emulator image is an emulator`() {
        assertTrue(
            DeviceInfo.isEmulator(
                fingerprint = "google/sdk_gphone16k_arm64/emu64a16k:16/BP22.250325.006/13344233:userdebug/dev-keys",
                model = "sdk_gphone16k_arm64",
                product = "sdk_gphone16k_arm64",
                hardware = "ranchu",
                manufacturer = "Google",
                brand = "google",
                device = "emu64a16k",
            ),
        )
        // Each fact alone is enough: the board, and the model a Google image names itself.
        assertTrue(DeviceInfo.isEmulator("", "", "", "ranchu", "", "", ""))
        assertTrue(DeviceInfo.isEmulator("", "sdk_gphone64_x86_64", "", "", "", "", ""))
        assertTrue(DeviceInfo.isEmulator("", "", "", "goldfish", "", "", ""))
        assertTrue(DeviceInfo.isEmulator("", "", "", "vbox86", "Genymotion", "", ""))
        // The old images still are.
        assertTrue(DeviceInfo.isEmulator("generic/sdk/generic:7.0/NYC/1:eng/test-keys", "Android SDK built for x86", "sdk", "goldfish", "unknown", "generic", "generic"))
    }

    @Test
    fun `a real handset is not, whatever letters its codename holds`() {
        // A handset whose codename holds the letters "emu" (made up for the case), and a Galaxy S23 Ultra: neither may be
        // filtered out of a customer's numbers.
        assertFalse(
            DeviceInfo.isEmulator(
                fingerprint = "lemur/lemur/lemur:14/UQ1A.240205.004/11269751:user/release-keys",
                model = "Lemur Phone",
                product = "lemur",
                hardware = "lemur",
                manufacturer = "Lemur",
                brand = "lemur",
                device = "lemur",
            ),
        )
        assertFalse(
            DeviceInfo.isEmulator(
                fingerprint = "samsung/dm3qxxx/dm3q:14/UP1A.231005.007/S918BXXU3BWK5:user/release-keys",
                model = "SM-S918B",
                product = "dm3qxxx",
                hardware = "qcom",
                manufacturer = "samsung",
                brand = "samsung",
                device = "dm3q",
            ),
        )
    }
}
