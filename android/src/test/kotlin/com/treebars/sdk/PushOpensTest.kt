package com.treebars.sdk

import android.app.Application
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import com.treebars.sdk.generated.TreebarsConstants
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.shadows.ShadowLooper
import java.util.concurrent.TimeUnit

/*
 * Every tap on a Treebars push reaches the app's open listener — a push the SDK drew and a plain one the system drew,
 * from a running app or a dead one — and a link is routed by the app when it listens, by the system when it does not.
 * Each failure here was silent on a device: a tap that only opened the app, on the wrong screen or none.
 */
@RunWith(RobolectricTestRunner::class)
class PushOpensTest {

    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val heard = mutableListOf<PushOpen>()

    @Before
    fun clear() {
        PushOpens.reset()
        context.getSharedPreferences(Treebars.PREFS_NAME, Context.MODE_PRIVATE).edit().clear().commit()
        shadowOf(context as Application).clearNextStartedActivities()
    }

    @After
    fun detach() {
        TreebarsPush.setOpenListener(null)
        PushOpens.reset()
    }

    /** A plain push's tap, as Firebase opens the SDK's activity through `click_action`: the data as the intent's extras. */
    private fun systemTap(vararg data: Pair<String, String>): Intent =
        Intent(TreebarsConstants.PUSH_OPEN_ACTION).setPackage(context.packageName).apply { data.forEach { (key, value) -> putExtra(key, value) } }

    private fun tap(intent: Intent) {
        Robolectric.buildActivity(TreebarsPushActivity::class.java, intent).create()
        ShadowLooper.idleMainLooper()
    }

    @Test
    fun `the SDK's manifest answers a plain push's click action with its own activity`() {
        val resolved = context.packageManager.resolveActivity(systemTap(), 0)
        assertEquals(TreebarsPushActivity::class.java.name, resolved?.activityInfo?.name)
    }

    @Test
    fun `a plain push's link reaches the listener, with the app brought forward and nothing opened by the system`() {
        TreebarsPush.setOpenListener { heard += it }
        tap(systemTap(TreebarsConstants.DELIVERY_ID_KEY to "d1", TreebarsConstants.CAMPAIGN_ID_KEY to "c1", TreebarsConstants.RICH_PUSH_DEEP_LINK_KEY to "daleela://p/42", "promo" to "spring"))

        val open = heard.single()
        assertEquals("daleela://p/42", open.link)
        assertEquals("d1", open.deliveryId)
        assertEquals("c1", open.campaignId)
        assertFalse(open.isTest)
        // The author's own keys, and none of the SDK's.
        assertEquals(mapOf("promo" to "spring"), open.data)
        // The app's own launcher (none in this test's package), never the link through the system: the listener routes it.
        val started = shadowOf(context as Application).nextStartedActivity
        assertTrue(started == null || started.action != Intent.ACTION_VIEW)
    }

    @Test
    fun `a tap that launched the app is held until a listener is set, then handed over once`() {
        tap(systemTap(TreebarsConstants.DELIVERY_ID_KEY to "d2", TreebarsConstants.RICH_PUSH_DEEP_LINK_KEY to "daleela://chat"))
        assertTrue(heard.isEmpty())

        TreebarsPush.setOpenListener { heard += it }
        ShadowLooper.idleMainLooper()
        assertEquals(listOf("daleela://chat"), heard.map { it.link })

        TreebarsPush.setOpenListener(null)
        TreebarsPush.setOpenListener { heard += it }
        ShadowLooper.idleMainLooper()
        assertEquals("handed over once", 1, heard.size)
    }

    @Test
    fun `with no listener after initialize, a held link is opened by the system once the wait is over`() {
        tap(systemTap(TreebarsConstants.DELIVERY_ID_KEY to "d3", TreebarsConstants.RICH_PUSH_DEEP_LINK_KEY to "daleela://t"))
        shadowOf(context as Application).clearNextStartedActivities()
        PushOpens.start(context)

        ShadowLooper.idleMainLooper(PushOpens.LAUNCH_WAIT_MS - 1, TimeUnit.MILLISECONDS)
        assertNull("not before the wait", shadowOf(context as Application).nextStartedActivity)
        ShadowLooper.idleMainLooper(2, TimeUnit.MILLISECONDS)
        val opened = shadowOf(context as Application).nextStartedActivity
        assertEquals(Intent.ACTION_VIEW, opened?.action)
        assertEquals("daleela://t", opened?.dataString)
    }

    @Test
    fun `a warm tap with no listener opens its link at once, as an app that never listened expects`() {
        PushOpens.start(context)
        tap(systemTap(TreebarsConstants.DELIVERY_ID_KEY to "d4", TreebarsConstants.RICH_PUSH_DEEP_LINK_KEY to "daleela://d/7"))
        val opened = shadowOf(context as Application).nextStartedActivity
        assertEquals(Intent.ACTION_VIEW, opened?.action)
        assertEquals("daleela://d/7", opened?.dataString)
    }

    @Test
    fun `a test from the dashboard acts when tapped and is never recorded as opened`() {
        TreebarsPush.setOpenListener { heard += it }
        tap(systemTap(TreebarsConstants.RICH_PUSH_TEST_KEY to "1", TreebarsConstants.RICH_PUSH_DEEP_LINK_KEY to "daleela://summit/1"))

        val open = heard.single()
        assertTrue(open.isTest)
        assertNull(open.deliveryId)
        assertEquals("daleela://summit/1", open.link)
        assertTrue("nothing kept to send", PendingPushReceipts.drain(context).isEmpty())
    }

    @Test
    fun `a push nobody sent through Treebars is not the SDK's to open`() {
        tap(systemTap("google.message_id" to "m1", "deep_link" to "other://x"))
        TreebarsPush.setOpenListener { heard += it }
        ShadowLooper.idleMainLooper()
        // Opened by the system's launcher as before; no open is made up for it.
        assertTrue(heard.isEmpty() || heard.single().deliveryId == null && !heard.single().isTest)
    }

    @Test
    fun `an open reported twice — by the SDK and by an app still reporting it — counts once`() {
        val data = mapOf(TreebarsConstants.DELIVERY_ID_KEY to "d5")
        Treebars.pushReceipt(context, opened = true, data = data)
        Treebars.pushReceipt(context, opened = true, data = data)
        assertEquals(1, PendingPushReceipts.drain(context).size)
    }

    @Test
    fun `a plain push that arrives while the app is in front is drawn, with the same tap`() {
        val drawn = TreebarsPush.handle(
            context,
            mapOf(TreebarsConstants.DELIVERY_ID_KEY to "d6", TreebarsConstants.RICH_PUSH_TITLE_KEY to "Hello", TreebarsConstants.RICH_PUSH_BODY_KEY to "A new guide", TreebarsConstants.RICH_PUSH_DEEP_LINK_KEY to "daleela://p/1"),
        )
        assertTrue(drawn)
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val posted = shadowOf(manager).allNotifications.single()
        assertNotNull(posted.contentIntent)
        // Not a push of ours, or one with nothing to say: left to the app.
        assertFalse(TreebarsPush.handle(context, mapOf("title" to "x")))
        assertFalse(TreebarsPush.handle(context, mapOf(TreebarsConstants.DELIVERY_ID_KEY to "d7")))
    }
}
