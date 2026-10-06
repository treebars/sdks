package com.treebars.sdk

import android.app.Activity
import android.content.Context
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import com.treebars.sdk.generated.TreebarsConstants
import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.android.controller.ActivityController

/**
 * `in_app_display` on `device_context`: what draws this app's in-app messages — this SDK (`sdk`), the app's own
 * renderer (`app`), or nothing (`off`).
 *
 * It is the one value in the context the app's own code sets, usually a moment after `initialize`, so what these pin
 * is as much *when* it is reported as *what*: a device that has reported before waits until the launch has settled,
 * so one launch gives one answer; a change is reported once it has stood, with a screen in front; and nothing is
 * reported for a person who opted out.
 *
 * The second half drives the real SDK, with the wait shortened, against a backend that does not answer — so every
 * event stays on the device, where these read it.
 */
@RunWith(RobolectricTestRunner::class)
class InAppDisplayTest {

    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private fun prefs() = context.getSharedPreferences(Treebars.PREFS_NAME, Context.MODE_PRIVATE)

    // ---- What it says -------------------------------------------------------------------------------------------

    @Test
    fun `the three answers`() {
        assertEquals("on, and nothing registered: this SDK draws", "sdk", DeviceInfo.inAppDisplay(enabled = true, ownRenderer = false))
        assertEquals("on, and the app registered its own renderer", "app", DeviceInfo.inAppDisplay(enabled = true, ownRenderer = true))
        assertEquals("switched off", "off", DeviceInfo.inAppDisplay(enabled = false, ownRenderer = false))
        assertEquals("switched off, whatever renderer is also registered", "off", DeviceInfo.inAppDisplay(enabled = false, ownRenderer = true))
    }

    @Test
    fun `it is hashed as the other SDKs hash it`() {
        val fixture = JSONObject(
            requireNotNull(javaClass.classLoader?.getResource("bridge/device-context-hash.json")) { "the shared fixture is missing from the test resources" }.readText(),
        )
        val cases = fixture.getJSONArray("cases")
        assertTrue("the fixture has cases", cases.length() > 0)
        val seen = mutableMapOf<String, String>()
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            val given = case.getJSONObject("context")
            val values = given.keys().asSequence().associateWith { given.getString(it) as Any }
            assertEquals(case.getString("name"), case.getString("hash"), DeviceInfo.hashContext(values))
            if (given.has("app_id")) seen[given.optString("in_app_display", "absent")] = case.getString("hash")
        }
        assertEquals("one hash for each answer, and one for a context without the key", 4, seen.values.toSet().size)
    }

    @Test
    fun `a device that has never reported is told apart from one that has`() {
        prefs().edit().clear().commit()
        assertFalse(DeviceInfo.hasReportedContext(context))
        DeviceInfo.rememberReportedContext(context, "aaaa")
        assertTrue(DeviceInfo.hasReportedContext(context))
        DeviceInfo.forgetReportedContext(context)
        assertFalse(DeviceInfo.hasReportedContext(context))
    }

    // ---- When it says it ----------------------------------------------------------------------------------------

    private val renderer = Treebars.InAppRenderer { _, _, _, _ -> }
    private var screen: ActivityController<Activity>? = null

    private fun field(name: String) = Treebars::class.java.getDeclaredField(name).apply { isAccessible = true }

    /** Every `device_context` this install has recorded: still on the queue, or sealed into a batch that could not be sent. */
    private fun reports(): List<JSONObject> {
        fun array(file: File): JSONArray? = file.takeIf { it.exists() }?.let { runCatching { JSONArray(it.readText()) }.getOrNull() }
        fun objects(array: JSONArray?) = if (array == null) emptyList() else (0 until array.length()).map { array.getJSONObject(it) }

        val queued = objects(array(File(context.filesDir, EventQueue.FILE_NAME)))
        val sealed = File(context.filesDir, TreebarsConstants.UPLOADER_FILE).takeIf { it.exists() }
            ?.let { runCatching { JSONObject(it.readText()).optJSONArray("pending") }.getOrNull() }
            .let(::objects)
            .flatMap { objects(it.optJSONArray("events")) }
        return (queued + sealed).distinctBy { it.getString("event_id") }
            .filter { it.optString("event_name") == "device_context" }
            .sortedBy { it.getString("timestamp") }
    }

    private fun displays(): List<String> = reports().map { it.getJSONObject("properties").optString("in_app_display", "absent") }

    /** Runs the main looper, and waits for the SDK's background coroutines, until [done] or five seconds pass. */
    private fun until(done: () -> Boolean): Boolean {
        val deadline = System.currentTimeMillis() + 5_000
        while (System.currentTimeMillis() < deadline) {
            shadowOf(Looper.getMainLooper()).idle()
            if (done()) return true
            Thread.sleep(20)
        }
        return false
    }

    /** Long enough for a wait to have ended, and its report to have been recorded, several times over. */
    private fun outlast() {
        val deadline = System.currentTimeMillis() + SETTLE_MS * 6
        while (System.currentTimeMillis() < deadline) {
            shadowOf(Looper.getMainLooper()).idle()
            Thread.sleep(20)
        }
    }

    /**
     * A device that has reported before, and said [display] when it did: its identity is on file, and so is the
     * record of that report. What a launch finds on every start but an install's first.
     */
    private fun reportedBefore(display: String) {
        DeviceIdentityStore(context.noBackupFilesDir).write(DeviceIdentity(mintDeviceId(), mintDeviceSecret()))
        val hash = DeviceInfo.hashContext(DeviceInfo.context(context) + ("in_app_display" to display))
        DeviceInfo.rememberReportedContext(context, hash)
    }

    /** A launch, and whatever the app does on the lines below `initialize`. */
    private fun launch(beside: () -> Unit = {}) {
        Treebars.initialize(context, "pk_test_display", "http://localhost:1", autoTrackLifecycle = false, autoTrackSessions = false, inAppPollIntervalMs = 0)
        beside()
    }

    /** A screen comes to the front. */
    private fun show() {
        screen = Robolectric.buildActivity(Activity::class.java).setup()
    }

    /** And goes: nothing of this app is in front. */
    private fun leave() {
        screen?.pause()?.stop()?.destroy()
        screen = null
    }

    @Before
    fun aDeviceNobodyHasHeardFrom() {
        prefs().edit().clear().commit()
        File(context.filesDir, EventQueue.FILE_NAME).delete()
        File(context.filesDir, TreebarsConstants.UPLOADER_FILE).delete()
        File(context.noBackupFilesDir, DeviceIdentityStore.FILE_NAME).delete()
        field("identity").set(Treebars, null)
        field("writeKey").set(Treebars, null)
        field("inAppEnabled").set(Treebars, true)
        Treebars.setInAppRenderer(null)
        Treebars.contextSettleMs = SETTLE_MS
        // No screen until a test shows one, whatever an earlier suite left the process lifecycle saying.
        TreebarsPush.processResumed = { false }
    }

    /*
     * `Treebars` is one object per sandbox, shared with every other suite: what these changed on it is put back, so a
     * suite that runs after this one finds in-app on, nobody opted out, no renderer and an SDK not yet initialised.
     */
    @After
    fun putTheSingletonBack() {
        leave()
        Treebars.optIn()
        Treebars::class.java.getDeclaredMethod("stopSettlingContext").apply { isAccessible = true }.invoke(Treebars)
        Treebars.setInAppRenderer(null)
        field("inAppEnabled").set(Treebars, true)
        field("writeKey").set(Treebars, null)
        Treebars.contextSettleMs = TreebarsConstants.CONTEXT_SETTLE_MS
        TreebarsPush.processResumed = {
            runCatching {
                androidx.lifecycle.ProcessLifecycleOwner.get().lifecycle.currentState
                    .isAtLeast(androidx.lifecycle.Lifecycle.State.RESUMED)
            }.getOrDefault(true)
        }
    }

    @Test
    fun `a first launch reports at once, with no screen and no wait, what the app had already said`() {
        // Longer than the test waits: this report is not the one a wait makes.
        Treebars.contextSettleMs = 60_000
        Treebars.setInAppRenderer(renderer)
        launch()

        assertTrue("the first report was never made", until { reports().isNotEmpty() })
        assertEquals(listOf("app"), displays())
        val properties = reports().single().getJSONObject("properties")
        assertTrue("with its hash, which now covers the answer", properties.getString("context_hash").matches(Regex("[0-9a-f]{8}")))
        assertTrue("and the secret it registers", properties.has("fetch_secret"))
    }

    @Test
    fun `a later launch says nothing when the renderer is attached a moment after initialize, as a wrapper attaches it`() {
        reportedBefore("app")
        launch()
        show()
        Thread.sleep(SETTLE_MS / 4)
        Treebars.setInAppRenderer(renderer)
        outlast()

        // Not `sdk` for the moment before the renderer arrived, and not `app` again: the app never changed.
        assertEquals(emptyList<String>(), displays())
    }

    @Test
    fun `a later launch of an app that no longer registers one says so, once`() {
        reportedBefore("app")
        launch()
        show()
        assertTrue("the change was never reported", until { displays() == listOf("sdk") })
        outlast()
        assertEquals(listOf("sdk"), displays())
    }

    @Test
    fun `in-app switched off on the line below initialize is what the launch reports, once`() {
        reportedBefore("sdk")
        launch { Treebars.disableInApps() }
        show()
        assertTrue("off was never reported", until { displays() == listOf("off") })
        outlast()
        assertEquals(listOf("off"), displays())
        assertNotEquals(
            "a different description, so a different hash",
            DeviceInfo.hashContext(DeviceInfo.context(context) + ("in_app_display" to "sdk")),
            reports().single().getJSONObject("properties").getString("context_hash"),
        )
    }

    @Test
    fun `a renderer registered later is reported once it has stood, and not before`() {
        Treebars.contextSettleMs = 800
        reportedBefore("sdk")
        launch()
        show()

        Treebars.setInAppRenderer(renderer)
        Thread.sleep(200)
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals("nothing while it has stood for less than the wait", emptyList<String>(), displays())
        assertTrue("and then the app's own", until { displays() == listOf("app") })
    }

    @Test
    fun `another renderer in place of one, and one detached and attached again, report nothing`() {
        reportedBefore("app")
        launch { Treebars.setInAppRenderer(renderer) }
        show()
        outlast()
        assertEquals(emptyList<String>(), displays())

        // A second host's renderer replaces the first: still the app's own.
        Treebars.setInAppRenderer(Treebars.InAppRenderer { _, _, _, _ -> })
        // And a host that unmounts and mounts again takes its renderer away and brings it back.
        Treebars.setInAppRenderer(null)
        Thread.sleep(SETTLE_MS / 4)
        Treebars.setInAppRenderer(renderer)
        outlast()
        assertEquals(emptyList<String>(), displays())

        // One that is taken away and stays away is a change: this SDK draws from here.
        Treebars.setInAppRenderer(null)
        assertTrue(until { displays() == listOf("sdk") })
    }

    @Test
    fun `a change with no screen in front is not reported until one is`() {
        reportedBefore("app")
        launch { Treebars.setInAppRenderer(renderer) }
        show()
        outlast()

        // The app is left, and its host takes the renderer with it.
        leave()
        Treebars.setInAppRenderer(null)
        outlast()
        assertEquals("not described as drawn by the SDK for having been left", emptyList<String>(), displays())

        // It comes back, and the host registers again: nothing changed.
        show()
        Treebars.setInAppRenderer(renderer)
        outlast()
        assertEquals(emptyList<String>(), displays())

        // Left again, and this time it comes back without one: that is reported, once somebody is looking.
        leave()
        Treebars.setInAppRenderer(null)
        outlast()
        assertEquals(emptyList<String>(), displays())
        show()
        assertTrue(until { displays() == listOf("sdk") })
    }

    @Test
    fun `nothing is reported for a person who opted out, and the change stays owed`() {
        reportedBefore("sdk")
        val record = prefs().getString("device_context_hash", null)
        launch()
        show()

        Treebars.optOut()
        Treebars.setInAppRenderer(renderer)
        outlast()
        assertEquals(emptyList<String>(), displays())
        assertEquals("nor is the report counted as made", record, prefs().getString("device_context_hash", null))
    }

    @Test
    fun `it keeps nothing on the device that was not kept already, and a wipe ends the wait`() {
        reportedBefore("sdk")
        launch()
        show()
        outlast()
        // Apart from the session, which any event opens: the report is an event like another.
        fun kept() = prefs().all.keys.filterNot { it.startsWith("session_") }.toSortedSet()
        val keys = kept()

        Treebars.setInAppRenderer(renderer)
        assertTrue(until { displays() == listOf("app") })
        assertEquals("the report is remembered under the key it always was", keys, kept())

        Treebars.setInAppRenderer(null)
        Treebars.wipeLocalData()
        outlast()
        assertTrue("a wipe sends nothing, and drops what was waiting", reports().isEmpty())
        assertNull("and leaves no record of a report", prefs().getString("device_context_hash", null))
    }

    private companion object {
        /** The wait these run with, in place of the real one: long enough to tell from none, short enough to wait out. */
        const val SETTLE_MS = 200L
    }
}
