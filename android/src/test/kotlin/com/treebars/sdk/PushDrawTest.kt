package com.treebars.sdk

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.treebars.sdk.generated.TreebarsConstants
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/*
 * What the SDK posts for a push it draws itself, read back from the system rather than from our
 * own code: a channel the app never created, and more actions than Android draws.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class PushDrawTest {

    private val context = ApplicationProvider.getApplicationContext<Context>()
    private val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun data(options: JSONObject, buttons: JSONArray = JSONArray(), cards: JSONArray = JSONArray()) = mapOf(
        TreebarsConstants.RICH_PUSH_RENDER_KEY to "1",
        TreebarsConstants.RICH_PUSH_TITLE_KEY to "Spring sale",
        TreebarsConstants.RICH_PUSH_BODY_KEY to "Everything 30% off",
        TreebarsConstants.RICH_PUSH_OPTIONS_KEY to options.toString(),
        TreebarsConstants.RICH_PUSH_BUTTONS_KEY to buttons.toString(),
        TreebarsConstants.RICH_PUSH_CAROUSEL_KEY to cards.toString(),
        TreebarsConstants.DELIVERY_ID_KEY to "del_${System.nanoTime()}",
    )

    private fun button(label: String) = JSONObject().put("id", label).put("label", label)
        .put("action", JSONObject().put("type", "deep_link").put("url", "treebarsdemo://$label"))

    @Test
    fun `a channel the app never created falls back to ours rather than posting nothing`() {
        TreebarsPush.post(context, data(JSONObject().put("android_channel_id", "promotionz")), 0)
        val posted = shadowOf(manager).allNotifications.single()
        assertEquals("treebars_default", posted.channelId)
    }

    @Test
    fun `a channel the app did create is used`() {
        manager.createNotificationChannel(NotificationChannel("promotions", "Promotions", NotificationManager.IMPORTANCE_DEFAULT))
        TreebarsPush.post(context, data(JSONObject().put("android_channel_id", "promotions")), 0)
        assertEquals("promotions", shadowOf(manager).allNotifications.single().channelId)
    }

    @Test
    fun `a carousel's arrows, the buttons and the coupon stop at Android's three, in that order`() {
        val cards = JSONArray().put(JSONObject().put("title", "One").put("image_url", ""))
            .put(JSONObject().put("title", "Two").put("image_url", ""))
        val buttons = JSONArray().put(button("Shop")).put(button("Later"))
        TreebarsPush.post(context, data(JSONObject().put("coupon_code", "SPRING"), buttons, cards), 0)
        val actions = shadowOf(manager).allNotifications.single().actions.map { it.title.toString() }
        assertEquals(listOf("‹", "›", "Shop"), actions)
    }

    @Test
    fun `without a carousel, the buttons and then the coupon`() {
        TreebarsPush.post(context, data(JSONObject().put("coupon_code", "SPRING"), JSONArray().put(button("Shop")).put(button("Later"))), 0)
        val actions = shadowOf(manager).allNotifications.single().actions.map { it.title.toString() }
        assertEquals(listOf("Shop", "Later", "Copy SPRING"), actions)
    }

    @Test
    fun `the small icon and its colour come from the app's manifest meta-data, where it used the launcher icon`() {
        val info = shadowOf(context.packageManager).getInternalMutablePackageInfo(context.packageName).applicationInfo!!
        info.metaData = android.os.Bundle().apply {
            putInt(TreebarsPush.NOTIFICATION_ICON_META, android.R.drawable.star_on)
            putInt(TreebarsPush.NOTIFICATION_COLOR_META, android.R.color.holo_purple)
        }
        TreebarsPush.post(context, data(JSONObject()), 0)
        val posted = shadowOf(manager).allNotifications.single()
        assertEquals(android.R.drawable.star_on, posted.smallIcon.resId)
        assertEquals(context.getColor(android.R.color.holo_purple), posted.color)
    }
}
