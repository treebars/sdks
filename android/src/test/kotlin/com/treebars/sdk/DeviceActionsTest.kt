package com.treebars.sdk

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf

/**
 * Push's device actions on a typed button, and the HTML bridge's of the same names: one
 * `DeviceActions`. What a device does with a dialer or a review sheet is the device's; this pins what is asked of it.
 */
@RunWith(RobolectricTestRunner::class)
class DeviceActionsTest {

    private val activity: Activity = Robolectric.buildActivity(Activity::class.java).setup().get()
    private val actions = DeviceActions { activity }

    @Test
    fun dialsTheNumberWithoutItsSpaces() {
        assertTrue(actions.dial("+971 50 123 4567"))
        val started = shadowOf(activity).nextStartedActivity
        assertEquals(Intent.ACTION_DIAL, started.action)
        assertEquals("tel:%2B971501234567", started.dataString)
    }

    @Test
    fun copiesTheText() {
        assertTrue(actions.copy("SPRING25", null))
        val clipboard = activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        assertEquals("SPRING25", clipboard.primaryClip?.getItemAt(0)?.text.toString())
    }

    @Test
    fun sharesTheTextThroughTheChooser() {
        assertTrue(actions.share("Look at this"))
        val chooser = shadowOf(activity).nextStartedActivity
        assertEquals(Intent.ACTION_CHOOSER, chooser.action)
        @Suppress("DEPRECATION")
        val sent = chooser.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
        assertEquals("Look at this", sent?.getStringExtra(Intent.EXTRA_TEXT))
    }

    @Test
    fun opensTheListingWhenTheAppCarriesNoPlayReviewLibrary() {
        // The library is not on this classpath, as it is not in an app outside Play: no sheet, and the listing instead.
        assertFalse(PlayReview.request(activity))
        assertTrue(actions.storeReview())
        assertEquals("market://details?id=${activity.packageName}", shadowOf(activity).nextStartedActivity.dataString)
    }

    @Test
    fun endsTheMessageAsAnyCallToActionDoes() {
        for (action in listOf("call", "copy", "share", "store_review")) {
            assertTrue(action, inAppClickEndsMessage(InAppButton(label = "x", action = action, value = null)))
        }
        assertFalse(inAppClickEndsMessage(InAppButton(label = "x", action = "dismiss", value = null)))
    }

    @Test
    fun handsTheListenerALinksValueBesideItsKeyValues() {
        // A link's key-values ride beside its value, never in place of it: an app routes on values["value"].
        val link = InAppButton(label = "Shop", action = "deep_link", value = "app://sale?utm_source=in_app", data = mapOf("utm_source" to "in_app"))
        assertEquals(mapOf("utm_source" to "in_app", "value" to "app://sale?utm_source=in_app"), clickValues(link))
        assertEquals(mapOf("coupon" to "SPRING"), clickValues(InAppButton(label = "Keys", action = "custom", value = null, data = mapOf("coupon" to "SPRING"))))
        assertEquals(mapOf("value" to "app://cart"), clickValues(InAppButton(label = "Cart", action = "deep_link", value = "app://cart")))
    }
}
