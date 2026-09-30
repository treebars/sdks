package com.treebars.sdk

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.drawable.ColorDrawable
import android.os.SystemClock
import android.view.View
import android.widget.Chronometer
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.ProgressBar
import android.widget.TextView
import androidx.test.core.app.ApplicationProvider
import com.treebars.sdk.generated.TreebarsConstants
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/*
 * Push templates on Android: the wire read as the server writes it — the same fixture the server is tested
 * against — and each layout drawn into real views and read back, colours, countdown and progress
 * included. What an OEM's launcher then makes of a custom notification is a device's question, not this one's.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class PushTemplatesTest {

    private val context = ApplicationProvider.getApplicationContext<Context>()
    private val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    @After
    fun reset() {
        PushTemplates.canTick = { true }
        TreebarsPush.setBackgroundUpdateListener(null)
    }

    private fun fixture(): JSONObject = JSONObject(
        requireNotNull(javaClass.classLoader?.getResource("bridge/push-template-wire.json")) {
            "the shared fixture bridge/push-template-wire.json is missing from the test resources"
        }.readText(),
    )

    private fun nullableInt(json: JSONObject, key: String): Int? = if (json.isNull(key)) null else json.getInt(key)
    private fun nullableLong(json: JSONObject, key: String): Long? = if (json.isNull(key)) null else json.getLong(key)

    @Test
    fun `every case on the wire reads as the fixture says`() {
        val cases = fixture().getJSONArray("cases")
        assertTrue(cases.length() >= 4)
        for (index in 0 until cases.length()) {
            val case = cases.getJSONObject(index)
            val name = case.getString("name")
            val spec = PushTemplateSpec.parse(case.getJSONObject("wire").toString())
            assertNotNull(name, spec)
            val parsed = case.getJSONObject("parsed")
            assertEquals(name, parsed.getString("kind"), spec!!.kind)
            assertEquals(name, nullableInt(parsed, "background"), spec.background)
            assertEquals(name, nullableInt(parsed, "title"), spec.title)
            assertEquals(name, nullableInt(parsed, "body"), spec.body)
            assertEquals(name, nullableInt(parsed, "appName"), spec.appName)
            assertEquals(name, parsed.getBoolean("controlsLight"), spec.controlsLight)
            assertEquals(name, parsed.getBoolean("textOverlay"), spec.textOverlay)
            assertEquals(name, if (parsed.isNull("collapsedImage")) null else parsed.getString("collapsedImage"), spec.collapsedImage)
            assertEquals(name, parsed.getBoolean("fit"), spec.fit)
            assertEquals(name, nullableInt(parsed, "timerColor"), spec.timerColor)
            assertEquals(name, nullableLong(parsed, "startsAt"), spec.startsAt)
            assertEquals(name, nullableLong(parsed, "endsAt"), spec.endsAt)
        }
    }

    @Test
    fun `what cannot be drawn is no template, and the basic push draws instead`() {
        assertNull(PushTemplateSpec.parse(null))
        assertNull(PushTemplateSpec.parse("not json"))
        assertNull(PushTemplateSpec.parse("""{"kind":"hologram"}"""))
        // A timer without its two moments cannot count down to anything.
        assertNull(PushTemplateSpec.parse("""{"kind":"timer"}"""))
        assertNull(PushTemplateSpec.parse("""{"kind":"timer","starts_at":10,"ends_at":5}"""))
        // A colour that is not #RRGGBB is the system's own, not a guess.
        assertNull(PushTemplateSpec.parse("""{"kind":"stylized","background_color":"navy"}""")!!.background)
    }

    private fun inflate(views: android.widget.RemoteViews): View = views.apply(context, FrameLayout(context))

    @Test
    fun `a stylised push draws its background and colours into its own views`() {
        val spec = PushTemplateSpec.parse("""{"kind":"stylized","background_color":"#1F2937","title_color":"#FFFFFF","body_color":"#E5E7EB"}""")!!
        val (collapsed, expanded) = PushTemplates.views(context, spec, "Spring sale", "Everything 30% off", null, null, 0L, progress = false)
        for (view in listOf(inflate(collapsed), inflate(expanded))) {
            val root = view.findViewById<View>(R.id.treebars_push_root)
            assertEquals(0xFF1F2937.toInt(), (root.background as ColorDrawable).color)
            val title = view.findViewById<TextView>(R.id.treebars_push_title)
            assertEquals("Spring sale", title.text.toString())
            assertEquals(0xFFFFFFFF.toInt(), title.currentTextColor)
            assertEquals(0xFFE5E7EB.toInt(), view.findViewById<TextView>(R.id.treebars_push_body).currentTextColor)
            assertEquals(View.GONE, view.findViewById<View>(R.id.treebars_push_timer).visibility)
        }
    }

    @Test
    fun `controls light or dark colour the words the author left alone`() {
        val light = PushTemplateSpec.parse("""{"kind":"stylized","background_color":"#000000","controls":"light"}""")!!
        val view = inflate(PushTemplates.views(context, light, "T", "B", null, null, 0L, progress = false).first)
        assertEquals(0xFFFFFFFF.toInt(), view.findViewById<TextView>(R.id.treebars_push_title).currentTextColor)
    }

    @Test
    fun `an image banner puts the words over the picture when asked, under it otherwise`() {
        val picture = Bitmap.createBitmap(40, 20, Bitmap.Config.ARGB_8888)
        val over = PushTemplateSpec.parse("""{"kind":"image_banner","text_overlay":true}""")!!
        val overView = inflate(PushTemplates.views(context, over, "New in", "Autumn coats", picture, null, 0L, progress = false).second)
        assertEquals(View.VISIBLE, overView.findViewById<View>(R.id.treebars_push_overlay).visibility)
        assertEquals(View.GONE, overView.findViewById<View>(R.id.treebars_push_below).visibility)
        assertEquals("New in", overView.findViewById<TextView>(R.id.treebars_push_overlay_title).text.toString())
        // White over a picture unless the author said otherwise: the picture decides what is behind the words.
        assertEquals(0xFFFFFFFF.toInt(), overView.findViewById<TextView>(R.id.treebars_push_overlay_title).currentTextColor)
        assertNotNull(overView.findViewById<ImageView>(R.id.treebars_push_image).drawable)

        val under = PushTemplateSpec.parse("""{"kind":"image_banner","image_scale":"fit"}""")!!
        val underView = inflate(PushTemplates.views(context, under, "New in", "Autumn coats", picture, null, 0L, progress = false).second)
        assertEquals(View.GONE, underView.findViewById<View>(R.id.treebars_push_overlay).visibility)
        assertEquals("Autumn coats", underView.findViewById<TextView>(R.id.treebars_push_body).text.toString())
        // "Fit" is the second image, since a RemoteViews cannot set a scale type.
        assertEquals(View.VISIBLE, underView.findViewById<View>(R.id.treebars_push_image_fit).visibility)
        assertEquals(View.GONE, underView.findViewById<View>(R.id.treebars_push_image).visibility)
    }

    @Test
    fun `a banner collapses to its own image when it has one, to its words when not`() {
        val picture = Bitmap.createBitmap(40, 20, Bitmap.Config.ARGB_8888)
        val spec = PushTemplateSpec.parse("""{"kind":"image_banner","collapsed_image_url":"https://cdn.example.com/s.png"}""")!!
        val withImage = inflate(PushTemplates.views(context, spec, "T", "B", picture, picture, 0L, progress = false).first)
        assertNull(withImage.findViewById<View>(R.id.treebars_push_title))
        assertNotNull(withImage.findViewById<ImageView>(R.id.treebars_push_image).drawable)
        val withoutImage = inflate(PushTemplates.views(context, spec, "T", "B", picture, null, 0L, progress = false).first)
        assertEquals("T", withoutImage.findViewById<TextView>(R.id.treebars_push_title).text.toString())
    }

    @Test
    fun `a timer counts down to its end, and a progress bar shows how far it has run`() {
        val start = 1_000_000L
        val end = start + 60 * 60_000L
        val spec = PushTemplateSpec.parse("""{"kind":"timer_progress","timer_color":"#DC2626","starts_at":$start,"ends_at":$end}""")!!
        val now = start + 15 * 60_000L
        val view = inflate(PushTemplates.views(context, spec, "Flash sale", "Ends soon", null, null, now, progress = true).second)
        val timer = view.findViewById<Chronometer>(R.id.treebars_push_timer)
        assertEquals(View.VISIBLE, timer.visibility)
        assertTrue(timer.isCountDown)
        // The base is when it reaches zero, on the elapsed-time clock: 45 minutes from now.
        val left = timer.base - SystemClock.elapsedRealtime()
        assertTrue("left $left", left in (45 * 60_000L - 5_000L)..(45 * 60_000L))
        assertEquals(0xFFDC2626.toInt(), timer.currentTextColor)
        val bar = view.findViewById<ProgressBar>(R.id.treebars_push_progress)
        assertEquals(View.VISIBLE, bar.visibility)
        assertEquals(250, bar.progress)

        // Without an exact alarm the bar cannot move, so it is not drawn: just a timer.
        val noBar = inflate(PushTemplates.views(context, spec, "Flash sale", "Ends soon", null, null, now, progress = false).second)
        assertEquals(View.GONE, noBar.findViewById<View>(R.id.treebars_push_progress).visibility)
    }

    private fun push(template: String?, options: JSONObject = JSONObject(), delivery: String = "del_${System.nanoTime()}") = buildMap {
        put(TreebarsConstants.RICH_PUSH_RENDER_KEY, "1")
        put(TreebarsConstants.RICH_PUSH_TITLE_KEY, "Flash sale")
        put(TreebarsConstants.RICH_PUSH_BODY_KEY, "Ends soon")
        put(TreebarsConstants.RICH_PUSH_OPTIONS_KEY, options.toString())
        put(TreebarsConstants.DELIVERY_ID_KEY, delivery)
        template?.let { put(TreebarsConstants.RICH_PUSH_TEMPLATE_KEY, it) }
    }

    @Test
    fun `a template is posted in the system's decoration, and a timer leaves the tray at its end`() {
        val now = System.currentTimeMillis()
        TreebarsPush.post(context, push("""{"kind":"timer","starts_at":$now,"ends_at":${now + 30 * 60_000L}}"""), 0)
        val posted = shadowOf(manager).allNotifications.single()
        assertEquals(Notification.DecoratedCustomViewStyle::class.java.name, posted.extras.getString(Notification.EXTRA_TEMPLATE))
        assertNotNull(posted.contentView)
        assertTrue("timeout ${posted.timeoutAfter}", posted.timeoutAfter in (29 * 60_000L)..(30 * 60_000L))
    }

    @Test
    fun `a timer that ended before it arrived is not shown`() {
        val now = System.currentTimeMillis()
        TreebarsPush.post(context, push("""{"kind":"timer","starts_at":${now - 60_000L},"ends_at":${now - 1_000L}}"""), 0)
        assertTrue(shadowOf(manager).allNotifications.isEmpty())
    }

    @Test
    fun `a progress bar schedules its next step only where exact alarms are allowed`() {
        val alarms = shadowOf(context.getSystemService(Context.ALARM_SERVICE) as AlarmManager)
        val now = System.currentTimeMillis()
        val template = """{"kind":"timer_progress","starts_at":$now,"ends_at":${now + 60 * 60_000L}}"""
        PushTemplates.canTick = { false }
        TreebarsPush.post(context, push(template, delivery = "no-tick"), 0)
        assertNull(alarms.nextScheduledAlarm)
        PushTemplates.canTick = { true }
        TreebarsPush.post(context, push(template, delivery = "tick"), 0)
        val next = alarms.nextScheduledAlarm
        assertNotNull(next)
        assertEquals(AlarmManager.RTC, next!!.getType())
        // A hundred steps over an hour is 36 seconds; never more often than once a minute.
        assertTrue("at ${next.triggerAtMs - now}", next.triggerAtMs - now in PushTemplates.MIN_TICK_MS..(PushTemplates.MIN_TICK_MS + 5_000L))
    }

    @Test
    fun `auto-dismiss takes it off the tray, a template or not`() {
        TreebarsPush.post(context, push(null, JSONObject().put("auto_dismiss_seconds", 600)), 0)
        assertEquals(600_000L, shadowOf(manager).allNotifications.single().timeoutAfter)
    }

    @Test
    fun `a channel the registry declares is created with its name and importance`() {
        val options = JSONObject().put("android_channel_id", "offers").put("android_channel_name", "Offers").put("android_channel_importance", "urgent")
        TreebarsPush.post(context, push(null, options), 0)
        assertEquals("offers", shadowOf(manager).allNotifications.single().channelId)
        val created = manager.getNotificationChannel("offers")!!
        assertEquals("Offers", created.name.toString())
        assertEquals(NotificationManager.IMPORTANCE_HIGH, created.importance)
    }

    @Test
    fun `a channel the app already made keeps the app's importance`() {
        manager.createNotificationChannel(NotificationChannel("offers", "App's offers", NotificationManager.IMPORTANCE_LOW))
        val options = JSONObject().put("android_channel_id", "offers").put("android_channel_name", "Offers").put("android_channel_importance", "urgent")
        TreebarsPush.post(context, push(null, options), 0)
        assertEquals(NotificationManager.IMPORTANCE_LOW, manager.getNotificationChannel("offers")!!.importance)
    }

    @Test
    fun `a background update goes to the app's listener and draws nothing`() {
        var received: Map<String, String>? = null
        val data = mapOf(TreebarsConstants.RICH_PUSH_BACKGROUND_KEY to "1", "sync" to "orders", TreebarsConstants.DELIVERY_ID_KEY to "d1")
        // With nobody listening it is not ours: the app's own service handles its data message.
        assertFalse(TreebarsPush.handle(context, data))
        TreebarsPush.setBackgroundUpdateListener { received = it }
        assertTrue(TreebarsPush.handle(context, data))
        assertEquals(mapOf("sync" to "orders", TreebarsConstants.DELIVERY_ID_KEY to "d1"), received)
        assertTrue(shadowOf(manager).allNotifications.isEmpty())
    }
}
