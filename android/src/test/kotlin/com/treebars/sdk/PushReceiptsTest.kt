package com.treebars.sdk

import android.app.Activity
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.treebars.sdk.generated.TreebarsConstants
import org.json.JSONObject
import org.robolectric.Robolectric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/*
 * The receipts of a push the SDK drew, when they cannot be sent at once or should not be sent twice. Both failures
 * would be silent: a tap from a dead process would produce no `notification_opened`, and a second coupon copy would
 * count as a second open.
 */
@RunWith(RobolectricTestRunner::class)
class PushReceiptsTest {

    private val context: Context get() = ApplicationProvider.getApplicationContext()

    @Before
    fun clear() {
        context.getSharedPreferences(Treebars.PREFS_NAME, Context.MODE_PRIVATE).edit().clear().commit()
    }

    @Test
    fun `a receipt from before initialize is kept, in order, and handed over once`() {
        PendingPushReceipts.add(context, "notification_opened", mapOf(TreebarsConstants.DELIVERY_ID_KEY to "d1"))
        PendingPushReceipts.add(context, "push_dismissed", mapOf(TreebarsConstants.DELIVERY_ID_KEY to "d2"))

        val drained = PendingPushReceipts.drain(context)
        assertEquals(listOf("notification_opened", "push_dismissed"), drained.map { it.first })
        assertEquals("d1", drained[0].second[TreebarsConstants.DELIVERY_ID_KEY])
        // Handed over, and forgotten in the same step: a second launch sends nothing twice.
        assertTrue(PendingPushReceipts.drain(context).isEmpty())
    }

    @Test
    fun `receipts from a device whose app never starts stay bounded, newest kept`() {
        for (i in 1..30) PendingPushReceipts.add(context, "push_dismissed", mapOf(TreebarsConstants.DELIVERY_ID_KEY to "d$i"))
        val drained = PendingPushReceipts.drain(context)
        assertEquals(20, drained.size)
        assertEquals("d30", drained.last().second[TreebarsConstants.DELIVERY_ID_KEY])
        assertEquals("d11", drained.first().second[TreebarsConstants.DELIVERY_ID_KEY])
    }

    @Test
    fun `a push reported before initialize waits rather than being dropped`() {
        // The SDK has not been initialised in this process: `pushReceipt` must keep the tap.
        Treebars.pushReceipt(context, opened = true, data = mapOf(TreebarsConstants.DELIVERY_ID_KEY to "d9", TreebarsConstants.CAMPAIGN_ID_KEY to "c9"))
        val drained = PendingPushReceipts.drain(context)
        assertEquals(listOf("notification_opened"), drained.map { it.first })
        assertEquals("c9", drained.single().second[TreebarsConstants.CAMPAIGN_ID_KEY])
    }

    /* A cold tap's "open a screen" runs before a React Native bridge can listen; it waits for the listener. */
    @Test
    fun `a screen a push opened before anybody listened is handed to the first listener, once`() {
        val activity = Robolectric.buildActivity(Activity::class.java).get()
        TreebarsPush.setActionListener(null)
        TreebarsPush.performInForeground(activity, JSONObject().put("type", "navigate").put("screen", "Cart"))

        val heard = mutableListOf<Pair<String, Map<String, String>>>()
        TreebarsPush.setActionListener { type, values -> heard += type to values }
        assertEquals(listOf("navigate" to mapOf("screen" to "Cart")), heard)

        TreebarsPush.setActionListener(null)
        TreebarsPush.setActionListener { type, values -> heard += type to values }
        assertEquals("handed over once", 1, heard.size)
        TreebarsPush.setActionListener(null)
    }

    @Test
    fun `copying a push's coupon counts as an open the first time only`() {
        val data = mapOf(TreebarsConstants.DELIVERY_ID_KEY to "coupon-1")
        assertTrue(TreebarsPush.firstCouponCopy(context, data))
        assertFalse(TreebarsPush.firstCouponCopy(context, data))
        assertTrue(TreebarsPush.firstCouponCopy(context, mapOf(TreebarsConstants.DELIVERY_ID_KEY to "coupon-2")))
    }
}
