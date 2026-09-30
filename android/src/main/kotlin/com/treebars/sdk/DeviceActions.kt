package com.treebars.sdk

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.Toast
import java.lang.reflect.Proxy

/**
 * What a press can ask of the device beyond a link: dial a number, copy a text, share one, and ask
 * for a store review. One place for the HTML bridge's `call`, `copyText`, `share` and `requestStoreReview` and a typed
 * button's `call`, `copy`, `share` and `store_review` — the same act, so it is written once. Main thread.
 *
 * `context` is the screen in front when there is one, so a chooser and a review sheet sit over the app; the application
 * otherwise, which needs a new task to start anything.
 */
internal class DeviceActions(private val context: () -> Context) {

    private fun start(intent: Intent): Boolean {
        val from = context()
        if (from !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return runCatching { from.startActivity(intent) }.onFailure { TreebarsLogger.log("in-app: could not open $intent: $it") }.isSuccess
    }

    fun open(url: String): Boolean = start(Intent(Intent.ACTION_VIEW, Uri.parse(url)))

    fun dial(number: String): Boolean = start(Intent(Intent.ACTION_DIAL, Uri.parse("tel:${Uri.encode(number.filter { !it.isWhitespace() })}")))

    fun sms(number: String, body: String?): Boolean =
        start(Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:${Uri.encode(number)}")).apply { body?.let { putExtra("sms_body", it) } })

    fun copy(text: String, toast: String?): Boolean {
        val from = context()
        val clipboard = from.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return false
        clipboard.setPrimaryClip(ClipData.newPlainText("", text))
        toast?.let { Toast.makeText(from, it, Toast.LENGTH_SHORT).show() }
        return true
    }

    fun share(text: String): Boolean = start(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text), null))

    /**
     * Google Play's own review sheet over the app, where the app carries Play's review library
     * (`com.google.android.play:review`); the store's listing otherwise. Reached by reflection, so this SDK adds no Play
     * dependency to apps outside Play.
     *
     * Play decides whether the sheet shows at all (a quota it does not publish), and says nothing either way; a request
     * that reached Play counts as done. Only a missing library, or one that threw, falls back to the listing.
     */
    fun storeReview(): Boolean {
        val front = context() as? Activity
        if (front != null && PlayReview.request(front)) return true
        val pkg = front?.packageName ?: context().packageName
        return start(Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$pkg"))) ||
            start(Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=$pkg")))
    }
}

/**
 * Play's in-app review, by name. `ReviewManagerFactory.create(activity).requestReviewFlow()` answers a task; on success,
 * `launchReviewFlow(activity, info)` shows the sheet. The task's listener type is read off the task itself, because the
 * library moved it — `com.google.android.play.core.tasks` before review 2.0, `com.google.android.gms.tasks` since — and
 * one name would miss the other. False when the library is not in the app, so the caller opens the listing instead.
 */
internal object PlayReview {
    fun request(activity: Activity): Boolean = runCatching {
        val factory = Class.forName("com.google.android.play.core.review.ReviewManagerFactory")
        val manager = factory.getMethod("create", Context::class.java).invoke(null, activity) ?: return false
        val task = manager.javaClass.getMethod("requestReviewFlow").invoke(manager) ?: return false
        val listen = task.javaClass.methods.first { it.name == "addOnCompleteListener" && it.parameterTypes.size == 1 }
        val listenerType = listen.parameterTypes[0]
        val listener = Proxy.newProxyInstance(listenerType.classLoader, arrayOf(listenerType)) { proxy, method, args ->
            when (method.name) {
                "onComplete" -> {
                    val done = args?.getOrNull(0)
                    val ok = done?.javaClass?.getMethod("isSuccessful")?.invoke(done) as? Boolean ?: false
                    if (ok && !activity.isFinishing) {
                        val info = done?.javaClass?.getMethod("getResult")?.invoke(done)
                        manager.javaClass.methods.firstOrNull { it.name == "launchReviewFlow" && it.parameterTypes.size == 2 }?.invoke(manager, activity, info)
                    }
                    null
                }
                // A proxy answers Object's own methods too, or logging it throws.
                "hashCode" -> System.identityHashCode(proxy)
                "equals" -> proxy === args?.getOrNull(0)
                "toString" -> "PlayReview.listener"
                else -> null
            }
        }
        listen.invoke(task, listener)
        true
    }.getOrElse {
        if (it !is ClassNotFoundException) TreebarsLogger.log("in-app: Play's review sheet could not be asked for: $it")
        false
    }
}
