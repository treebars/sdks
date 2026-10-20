package com.treebars.sdk

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import com.treebars.sdk.generated.TreebarsConstants
import org.json.JSONObject

/**
 * A tapped Treebars push, as the app receives it from [TreebarsPush.setOpenListener].
 *
 * A push's link (`yourapp://orders/42`, or an https address the app opens) is here for the app to route the same way it
 * routes any link it is opened with, so a tapped push lands on the same screen a tapped link does — whether the app was
 * in front, in the background, or not running at all. A screen or an app action the push names reaches `onAction`, as
 * before; this says the push was opened, and which.
 */
data class PushOpen(
    /** The link the push opens, exactly as it was written; null for a push that only opens the app or runs an action. */
    val link: String?,
    /** The pressed button's id, or null for a tap on the notification itself. */
    val buttonId: String? = null,
    val deliveryId: String? = null,
    val campaignId: String? = null,
    /** A test sent from the dashboard: it acts like any push, and is never counted as opened. */
    val isTest: Boolean = false,
    /** The push's own data — the keys its author added — without the SDK's own. */
    val data: Map<String, String> = emptyMap(),
) {
    /** What the bridges hand across as JSON. */
    fun toJson(): JSONObject = JSONObject()
        .put("link", link ?: JSONObject.NULL)
        .put("button_id", buttonId ?: JSONObject.NULL)
        .put("delivery_id", deliveryId ?: JSONObject.NULL)
        .put("campaign_id", campaignId ?: JSONObject.NULL)
        .put("is_test", isTest)
        .put("data", JSONObject(data as Map<*, *>))

    companion object {
        /** The push's own data as its author wrote it, without Firebase's keys or the SDK's. */
        internal fun authored(data: Map<String, String>): Map<String, String> = data.filterKeys { key ->
            !key.startsWith("treebars_") && !key.startsWith("google.") && !key.startsWith("gcm.") &&
                key != "from" && key != "collapse_key" && key != TreebarsConstants.RICH_PUSH_DEEP_LINK_KEY
        }

        internal fun isTest(data: Map<String, String>): Boolean = data[TreebarsConstants.RICH_PUSH_TEST_KEY] == "1"
    }
}

/**
 * The app's listener and the tap held for it.
 *
 * A tap that launches the app reaches the SDK before the app has set a listener — under React Native, always, since it
 * listens from JavaScript once the bridge is up. So the tap is held, one slot, until a listener is set. With a listener
 * the SDK does not open the push's link itself: the listener routes it. Without one, the SDK opens the link with the
 * system, as an app that never set a listener expects; a tap that launched the app waits a few seconds after
 * `initialize` for a listener before that.
 */
internal object PushOpens {
    /** How long a tap that launched the app waits, after `initialize`, for a listener before the SDK opens its link. */
    const val LAUNCH_WAIT_MS = 8_000L

    private var listener: TreebarsPush.OpenListener? = null
    private var held: PushOpen? = null
    private var started = false
    private val main = Handler(Looper.getMainLooper())

    @Synchronized
    fun setListener(listener: TreebarsPush.OpenListener?) {
        this.listener = listener
        val pending = if (listener == null) null else held
        if (listener != null) held = null
        if (listener != null && pending != null) main.post { deliverTo(listener, pending) }
    }

    /**
     * A tap, resolved. To the listener, with the app brought forward; else held while the SDK is not initialised, with
     * the app launched; else its link opened by the system — or the app, when nothing on this device opens the link.
     */
    fun deliver(activity: Activity, open: PushOpen, launch: Boolean = true) {
        val current: TreebarsPush.OpenListener?
        val waiting: Boolean
        synchronized(this) {
            current = listener
            waiting = current == null && !started
            if (waiting) held = open
        }
        when {
            current != null -> {
                if (launch) launchApp(activity)
                main.post { deliverTo(current, open) }
            }
            waiting || open.link == null -> if (launch) launchApp(activity)
            else -> openLink(activity, open.link)
        }
    }

    /** `initialize` ran: a tap that launched the app gets a little longer for a listener, then its link is opened. */
    fun start(context: Context) {
        synchronized(this) {
            if (started) return
            started = true
        }
        val app = context.applicationContext
        main.postDelayed({
            val unclaimed = synchronized(this) {
                val left = if (listener == null) held else null
                if (left != null) held = null
                left
            }
            unclaimed?.link?.let { openLink(app, it) }
        }, LAUNCH_WAIT_MS)
    }

    /** For tests: back to a fresh process. */
    @Synchronized
    fun reset() {
        listener = null
        held = null
        started = false
    }

    private fun deliverTo(listener: TreebarsPush.OpenListener, open: PushOpen) {
        runCatching { listener.onPushOpened(open) }.onFailure { TreebarsLogger.log("push: open listener threw: $it") }
    }

    /** The link, through the system. A link nothing on the device opens launches the app instead of doing nothing. */
    private fun openLink(context: Context, link: String) {
        val view = Intent(Intent.ACTION_VIEW, Uri.parse(link)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val opened = runCatching { context.startActivity(view) }.isSuccess
        if (!opened) {
            TreebarsLogger.log("push: nothing on this device opens $link; opening the app instead")
            launchApp(context)
        }
    }

    private fun launchApp(context: Context) {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return
        // Brought forward as it was left, not started over: the launcher's own flags, without clearing its task.
        runCatching { context.startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)) }
    }
}
