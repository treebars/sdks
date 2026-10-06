package com.treebars.sdk.rn

import android.util.Log
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.annotations.ReactModule
import com.treebars.sdk.Adoption
import com.treebars.sdk.InAppButton
import com.treebars.sdk.InAppMessage
import com.treebars.sdk.InAppTokens
import com.treebars.sdk.NotificationPage
import com.treebars.sdk.PushProvider
import com.treebars.sdk.Treebars
import com.treebars.sdk.TreebarsPush
import com.treebars.sdk.TreebarsEnv
import com.treebars.sdk.UploadLog
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.util.UUID

/**
 * The Android half of the bridge. Everything below it is `com.treebars.sdk.Treebars`.
 *
 * `NativeTreebars.ts` is the spec and carries the reasoning for the shape of every method;
 * what lives here is only the translation — JSON in, a core call, JSON or a rejection out.
 * The one thing this file *decides* is the presentation protocol, which has no equivalent on
 * either side of it. See `renderer` below.
 *
 * **Nothing here swallows.** A payload that will not parse rejects with `bad_payload` and
 * names what it was reading. It does not pass an empty map onward and it does not fabricate a
 * return value: `notificationsMarkRead`'s promise is documented as "the write was accepted"
 * and `inboxList`'s as "this is the inbox", and a bridge that answered `{}` on a parse failure
 * would make a transport bug indistinguishable from an empty inbox.
 *
 * **What a promise here means, exactly.** Every write on the core — `track`, `flush`,
 * `registerPushToken`, `markNotificationRead` — is launched on the core's own scope and returns
 * before anything has been queued, let alone uploaded; the only suspending members it exposes
 * are `notifications`, `pendingCount` and `contextToken`, and those are awaited below. So for
 * the rest, resolution means the core accepted the call, not that the write landed, and no
 * caller should read one of these resolutions as delivery confirmation.
 */
@ReactModule(name = TreebarsNativeModule.NAME)
class TreebarsNativeModule(reactContext: ReactApplicationContext) :
  NativeTreebarsSpec(reactContext) {

  /**
   * For the core members that suspend. Cancelled in [invalidate], so a page fetch that
   * outlives the React context cannot resolve a promise into a runtime that has gone.
   */
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

  /**
   * Whether [initialize] has crossed. Ours rather than the core's, because the core answers
   * a call made too early by returning quietly — `track` logs and drops, `pendingCount` says
   * zero — and a bridge that passed that on would report an SDK that is working and silent
   * rather than one that was never started.
   */
  @Volatile
  private var initialized = false

  /** The one live presentation. See [renderer]; both cores show one overlay at a time. */
  @Volatile
  private var presentation: Presentation? = null

  /** The core's own unsubscribe, held so 1→0 can hand it back. */
  private var notificationsWatcher: (() -> Unit)? = null

  /**
   * The last page emitted, kept across an unsubscribe so a re-subscribe can be answered.
   *
   * The core replays nothing and `EventEmitter` has no replay of its own, so without this a
   * bell that unmounts and remounts — a tab change, a fast refresh — shows an empty badge
   * until something independently changes the centre.
   */
  @Volatile
  private var lastNotificationPage: String? = null

  override fun getName(): String = NAME

  // -----------------------------------------------------------------------------------------
  // Lifecycle
  // -----------------------------------------------------------------------------------------

  override fun initialize(configJson: String, promise: Promise) {
    val config = readObject(configJson, "the Treebars config", promise) ?: return

    val writeKey = config.stringOrNull("write_key")
      ?: return promise.reject(BAD_CONFIG, "Treebars: the config carried no write_key.")
    val backendUrl = config.stringOrNull("backend_url")
      ?: return promise.reject(BAD_CONFIG, "Treebars: the config carried no backend_url.")
    /*
     * Refused here as well as in the core, so `init()` rejects and says why. The core alone would
     * stay off and warn in logcat, and the promise would resolve on an SDK that sends nothing.
     */
    if (!Treebars.acceptsBackendUrl(backendUrl)) {
      return promise.reject(
        BAD_CONFIG,
        "Treebars: $backendUrl is not https. Plain http is accepted only for a local stack " +
          "(localhost, 10.0.2.2, a .local name or a private address).",
      )
    }

    /*
     * An unrecognised env is refused rather than defaulted. Defaulting means a typo in one
     * character sends a whole test build's traffic to production, where nothing distinguishes
     * it from the real thing and no later filter can take it back out.
     */
    val envName = config.stringOrNull("env") ?: TreebarsEnv.PRODUCTION.value
    val env = TreebarsEnv.entries.firstOrNull { it.value == envName }
      ?: return promise.reject(
        BAD_CONFIG,
        "Treebars: \"$envName\" is not an environment. Use production, stage or test.",
      )

    /*
     * `in_app_enabled: false` is honoured twice: never poll here, and `Treebars.disableInApps()` below, which stops the
     * sync that rides on session start and foreground and every presentation — the core draws an HTML message itself,
     * so whether a renderer is installed does not decide what is drawn.
     */
    val pollIntervalMs =
      if (!config.optBoolean("in_app_enabled", true)) 0L
      else config.optLong("in_app_poll_interval_ms", Treebars.DEFAULT_IN_APP_POLL_INTERVAL_MS)

    /*
     * `app_version` and `app_build` are deliberately ignored: this core reads both from
     * `PackageManager` itself, and its answer is the build that is actually running rather than
     * a literal somebody last updated by hand.
     *
     * Neither interval is a number written here. `optLong` has to be handed a value for an absent
     * key, and a number of this file's own would be a second copy of the core's policy, left behind
     * the day the core changed it. So an absent poll interval is the core's public default, and an
     * absent flush interval is the core's own name for "the app chose none": JavaScript sends the
     * key only when the app set it, and without it the core keeps its own pace.
     */
    Treebars.initialize(
      context = reactApplicationContext,
      writeKey = writeKey,
      backendUrl = backendUrl,
      env = env,
      flushIntervalMs = config.optLong("flush_interval_ms", Treebars.SDK_PACE),
      debug = config.optBoolean("debug", false),
      autoTrackLifecycle = config.optBoolean("auto_track_lifecycle", true),
      autoTrackSessions = config.optBoolean("auto_track_sessions", true),
      inAppPollIntervalMs = pollIntervalMs,
      adopt = adoption(config.optJSONObject("adopt")),
      // Absent is false, the core's own default: consent is never assumed on anybody's behalf.
      acquisitionConsent = config.optBoolean("acquisition_consent", false),
      // The app's own App Link domains; absent asks nothing, the core's own default.
      linkHosts = config.optJSONArray("link_hosts")
        ?.let { hosts -> (0 until hosts.length()).mapNotNull { hosts.optString(it).takeIf(String::isNotBlank) } }
        ?: emptyList(),
    )
    initialized = true
    owner = this

    /*
     * The screen in front, which the core's Activity tracker never saw resume: React Native initialises from JavaScript,
     * which runs only once its Activity is up. The core draws an HTML message on it; without this the first one would
     * wait for the app's next resume.
     */
    reactApplicationContext.currentActivity?.let { TreebarsPush.noteResumedActivity(it) }
    // `in_app_enabled: false` is nothing drawn and nothing polled — the core draws HTML itself, renderer or none.
    if (!config.optBoolean("in_app_enabled", true)) Treebars.disableInApps()

    /*
     * After `Treebars.initialize` and it cannot be before it: `setUploadListener` returns
     * early while the write key is null, and the uploader it writes to is `lateinit` until
     * that call builds one. So the flush the core launches from inside `initialize` — the one
     * that drains whatever the last process left behind — can complete before this line runs,
     * and the listener misses that batch. It is one log line at cold start and nothing is lost
     * but the line; an upload log spends no state, which is why this emitter needs no subscribe
     * gate.
     */
    Treebars.setUploadListener { log ->
      // The core calls this on its flush coroutine and catches nothing on our behalf beyond
      // its own frame; a throw here is a throw on a thread with nothing above it.
      guarded("upload log") { emitOnUploadLog(uploadLogJson(log).toString()) }
    }

    promise.resolve(null)
  }

  override fun reset(promise: Promise) {
    if (!ready(promise)) return
    /*
     * The presentation slot survives a reset on purpose. An overlay that is on screen when
     * somebody signs out is still on screen afterwards, and the dismiss that follows still has
     * to mark the message done — dropping the slot here would leave that dismiss stale, which
     * is the one outcome the whole protocol exists to prevent.
     */
    Treebars.reset()
    promise.resolve(null)
  }

  override fun flush(promise: Promise) {
    if (!ready(promise)) return
    Treebars.flush()
    promise.resolve(null)
  }

  // No started gate: the core keeps an opt-out made before `initialize`, as it keeps a consent grant.
  override fun optOut(promise: Promise) {
    Treebars.optOut()
    promise.resolve(null)
  }

  override fun optIn(promise: Promise) {
    Treebars.optIn()
    promise.resolve(null)
  }

  /*
   * No started gate: the core answers null before `initialize`, and null is this call's documented
   * "go ahead without one". A rejection here would put an SDK's start-up order in front of
   * somebody's purchase.
   */
  override fun contextToken(promise: Promise) {
    scope.launch { answer(promise, "the context token") { Treebars.contextToken() } }
  }

  override fun isOptedOut(promise: Promise) {
    promise.resolve(Treebars.isOptedOut())
  }

  override fun wipeLocalData(promise: Promise) {
    if (!ready(promise)) return
    Treebars.wipeLocalData()
    promise.resolve(null)
  }

  /*
   * No `ready` gate, unlike its neighbours: the core accepts a grant before `initialize` and holds
   * it, so an app whose consent prompt resolves first loses nothing. Refusing here would make the
   * bridge stricter than the thing it bridges.
   */
  override fun setAcquisitionConsent(granted: Boolean, promise: Promise) {
    Treebars.setAcquisitionConsent(granted)
    promise.resolve(null)
  }

  /**
   * A link opened the app. The core parses it, asks a link host what an App Link means, measures the
   * idle gap and decides whether to report; the promise settles with the link's deep-link path, or
   * null for a URL the app routes itself.
   *
   * No started gate and no parse here, for the two reasons this file keeps repeating: the core
   * already refuses a call before `initialize` and says so, and a URL parser written on this side
   * would be a third implementation of a rule that exists in Kotlin and Swift already.
   */
  override fun handleLink(url: String, promise: Promise) {
    Treebars.handleLink(url) { path -> promise.resolve(path) }
  }

  // -----------------------------------------------------------------------------------------
  // Events
  // -----------------------------------------------------------------------------------------

  override fun track(eventName: String, propertiesJson: String, promise: Promise) {
    if (!ready(promise)) return
    val properties = readObject(propertiesJson, "the properties of \"$eventName\"", promise)
      ?: return
    Treebars.track(eventName, properties.toValueMap())
    promise.resolve(null)
  }

  override fun screen(name: String, propertiesJson: String, promise: Promise) {
    if (!ready(promise)) return
    val properties = readObject(propertiesJson, "the properties of screen \"$name\"", promise)
      ?: return
    Treebars.screen(name, properties.toValueMap())
    promise.resolve(null)
  }

  override fun identify(userId: String, attributesJson: String, signature: String?, promise: Promise) {
    if (!ready(promise)) return
    val attributes = readObject(attributesJson, "the attributes of \"$userId\"", promise) ?: return
    Treebars.identify(userId, attributes.toValueMap(), signature)
    promise.resolve(null)
  }

  override fun registerPushToken(token: String, provider: String, promise: Promise) {
    if (!ready(promise)) return
    // Not defaulted to FCM. A token registered under the wrong provider is accepted by every
    // layer and fails only at the far end, as a device that is never reached.
    val push = when (provider) {
      PushProvider.FCM.value -> PushProvider.FCM
      PushProvider.APNS.value -> PushProvider.APNS
      else -> return promise.reject(
        BAD_PAYLOAD,
        "Treebars: \"$provider\" is not a push provider. Use fcm or apns.",
      )
    }
    Treebars.registerPushToken(token, push)
    promise.resolve(null)
  }

  override fun trackNotificationOpened(payloadJson: String, promise: Promise) {
    if (!ready(promise)) return
    val payload = readObject(payloadJson, "the push payload", promise) ?: return
    Treebars.trackNotificationOpened(payload.toStringMap())
    promise.resolve(null)
  }

  // A swipe-away, for an app whose own notification library sees one; the core reports `push_dismissed`.
  override fun trackNotificationDismissed(payloadJson: String, promise: Promise) {
    if (!ready(promise)) return
    val payload = readObject(payloadJson, "the push payload", promise) ?: return
    Treebars.trackNotificationDismissed(payload.toStringMap())
    promise.resolve(null)
  }

  /*
   * A push the SDK draws, handed over from the app's messaging library. React Native Firebase owns the
   * `FirebaseMessagingService`, so this is how an RN app reaches the core's rich-push drawing. No `ready` gate: this
   * runs from RNFB's background handler in a headless JS task, before — or without — `initialize`, and drawing needs
   * no write key. The receipts of the push the core drew wait for `initialize` if they must.
   */
  override fun handleRemotePush(payloadJson: String, promise: Promise) {
    val payload = readObject(payloadJson, "the push payload", promise) ?: return
    // Off the modules thread: drawing fetches the push's images, up to its eight-second bound.
    scope.launch { promise.resolve(TreebarsPush.handle(reactApplicationContext, payload.toStringMap())) }
  }

  /*
   * `setEventListener`'s events, forwarded from the core's listeners and nothing more: the core
   * decides what happened, this marshals it. Each event kind is subscribed on its own, because one of them changes
   * behaviour — while JavaScript listens to `inAppCampaignSelfHandled`, a self-handled message goes there instead of the
   * renderer — and a push action that arrived before anybody listened is held by the core and delivered on subscribing.
   * No `ready` gate, for the reason `setDeferredDeepLinkSubscribed` has none.
   */
  private var subscribedEvents: Set<String> = emptySet()

  /** Self-handled messages handed to JavaScript, by delivery id, so its reports can name them. Bounded to 32. */
  private val selfHandledMessages = LinkedHashMap<String, InAppMessage>()

  private fun rememberSelfHandled(message: InAppMessage) = synchronized(selfHandledMessages) {
    if (selfHandledMessages.size >= 32) selfHandledMessages.remove(selfHandledMessages.keys.first())
    selfHandledMessages[message.deliveryId] = message
  }

  private val lifeCycle = object : com.treebars.sdk.InAppLifeCycleListener {
    override fun onShown(message: InAppMessage) = emitEvent("inAppCampaignShown", campaignRef(message))
    override fun onDismiss(message: InAppMessage) = emitEvent("inAppCampaignDismissed", campaignRef(message))
  }

  private fun campaignRef(message: InAppMessage) = JSONObject().put("delivery_id", message.deliveryId).apply {
    message.campaignId?.let { put("campaign_id", it) }
  }

  private fun emitEvent(name: String, data: Any) {
    guarded(name) { emitOnTreebarsEvent(JSONObject().put("name", name).put("data", data).toString()) }
  }

  override fun setEventsSubscribed(namesJson: String, promise: Promise) {
    val names = runCatching { org.json.JSONArray(namesJson) }.getOrNull()
      ?.let { list -> (0 until list.length()).map { list.optString(it) }.toSet() }
      ?: return promise.reject(BAD_PAYLOAD, "Treebars: the event names were not a JSON list")
    subscribedEvents = names

    val wantsClicks = "inAppCampaignClicked" in names || "inAppCampaignCustomAction" in names
    Treebars.setClickActionListener(
      if (!wantsClicks) null else com.treebars.sdk.ClickActionListener { action, message ->
        val payload = JSONObject()
          .put("source", "in_app")
          .put("type", action.type)
          .put("values", JSONObject(action.values))
          .put("delivery_id", message.deliveryId)
          .apply { action.button.index?.let { put("button_index", it) } }
        if ("inAppCampaignClicked" in subscribedEvents) emitEvent("inAppCampaignClicked", payload)
        if (action.type == "custom" && "inAppCampaignCustomAction" in subscribedEvents) emitEvent("inAppCampaignCustomAction", payload)
        false
      },
    )

    Treebars.removeInAppLifeCycleListener(lifeCycle)
    if ("inAppCampaignShown" in names || "inAppCampaignDismissed" in names) Treebars.addInAppLifeCycleListener(lifeCycle)

    Treebars.setSelfHandledListener(
      if ("inAppCampaignSelfHandled" !in names) null else com.treebars.sdk.SelfHandledListener { message ->
        if (message == null) return@SelfHandledListener
        rememberSelfHandled(message)
        emitEvent("inAppCampaignSelfHandled", message.raw)
      },
    )

    TreebarsPush.setActionListener(
      if ("pushClicked" !in names) null else TreebarsPush.ActionListener { type, values ->
        emitEvent("pushClicked", JSONObject().put("source", "push").put("type", type).put("values", JSONObject(values)))
      },
    )
    promise.resolve(null)
  }

  override fun getSelfHandledInApps(promise: Promise) {
    if (!ready(promise)) return
    Treebars.getSelfHandledInApps(reactApplicationContext) { messages ->
      messages.forEach(::rememberSelfHandled)
      promise.resolve(org.json.JSONArray().apply { messages.forEach { put(it.raw) } }.toString())
    }
  }

  private fun selfHandled(deliveryId: String, promise: Promise): InAppMessage? {
    val message = synchronized(selfHandledMessages) { selfHandledMessages[deliveryId] }
    if (message == null) promise.reject(BAD_PAYLOAD, "Treebars: no self-handled message $deliveryId was handed to JavaScript")
    return message
  }

  override fun selfHandledShown(deliveryId: String, promise: Promise) {
    if (!ready(promise)) return
    val message = selfHandled(deliveryId, promise) ?: return
    Treebars.selfHandledShown(reactApplicationContext, message)
    promise.resolve(null)
  }

  override fun selfHandledClicked(deliveryId: String, buttonJson: String, promise: Promise) {
    if (!ready(promise)) return
    val message = selfHandled(deliveryId, promise) ?: return
    // The whole button, as a renderer's press carries it. A button naming no action is a press recorded and nothing
    // more (`click`), which leaves the message where it is.
    val button = buttonJson.takeIf { it.isNotEmpty() }?.let { runCatching { JSONObject(it) }.getOrNull() }
      ?.let { json -> buttonFrom(json, actionWhenAbsent = "click") }
    Treebars.selfHandledClicked(reactApplicationContext, message, button)
    promise.resolve(null)
  }

  override fun selfHandledDismissed(deliveryId: String, promise: Promise) {
    if (!ready(promise)) return
    val message = selfHandled(deliveryId, promise) ?: return
    Treebars.selfHandledDismissed(reactApplicationContext, message)
    promise.resolve(null)
  }

  override fun showInApp(promise: Promise) {
    if (!ready(promise)) return
    Treebars.showInApp(reactApplicationContext)
    promise.resolve(null)
  }

  // `position` is ignored: the Android core's `showNudge` takes no edge, so a nudge may appear at any.
  override fun showNudge(position: String, promise: Promise) {
    if (!ready(promise)) return
    Treebars.showNudge(reactApplicationContext)
    promise.resolve(null)
  }

  /*
   * The core asks on the screen in front. Android has no provisional grant, so the flag is iOS's alone.
   *
   * Resolves whether pushes are allowed now, which is before the person has answered: Android hands the answer to the
   * Activity that asked, and that is the app's, so there is nothing here to wait on. The core reads the answer when
   * that screen resumes and reports it as an event. Asking through React Native's own permission listener instead
   * would go around the core, which keeps the record of having asked that tells "never asked" from "refused for good".
   */
  override fun requestPushPermission(provisional: Boolean, promise: Promise) {
    if (!ready(promise)) return
    reactApplicationContext.currentActivity?.let { TreebarsPush.requestPermission(it) }
    val manager = reactApplicationContext.getSystemService(android.content.Context.NOTIFICATION_SERVICE) as? android.app.NotificationManager
    promise.resolve(manager?.areNotificationsEnabled() ?: false)
  }

  // -----------------------------------------------------------------------------------------
  // Queue telemetry, for an app's own debug screen
  // -----------------------------------------------------------------------------------------

  override fun pendingCount(promise: Promise) {
    if (!ready(promise)) return
    scope.launch { answer(promise, "the pending count") { Treebars.pendingCount().toDouble() } }
  }

  /**
   * The only synchronous method, and the only one that cannot answer with a rejection.
   *
   * `-1` is the wire's spelling of "nothing is scheduled", which is a different sentence from
   * "a flush is due right now" — a screen showing `0` for both would be lying about one of
   * them. It is what a caller gets while no event is waiting for an upload, and before
   * `initialize`, which is true rather than an error: nothing is armed, so nothing is due.
   */
  override fun msUntilNextFlush(): Double =
    runCatching { Treebars.msUntilNextFlush()?.toDouble() ?: -1.0 }
      .onFailure { Log.w(TAG, "msUntilNextFlush failed", it) }
      .getOrDefault(-1.0)

  // -----------------------------------------------------------------------------------------
  // In-app
  // -----------------------------------------------------------------------------------------

  override fun syncInAppMessages(promise: Promise) {
    if (!ready(promise)) return
    Treebars.syncInAppMessages()
    promise.resolve(null)
  }

  override fun inboxList(promise: Promise) {
    if (!ready(promise)) return
    // `raw` is the server's own row, which is exactly the shape `InAppMessage` is declared as
    // in JS. Re-encoding the parsed fields would be a second answer to a question the wire
    // already answered, and the two would differ the first time the server adds a key.
    val rows = JSONArray().apply { Treebars.inbox().forEach { put(it.raw) } }
    promise.resolve(rows.toString())
  }

  override fun inboxDismiss(deliveryId: String, promise: Promise) {
    if (!ready(promise)) return
    Treebars.dismissInboxMessage(deliveryId)
    promise.resolve(null)
  }

  // A card came into view, or was tapped (an empty destination is none), and a centre row was opened.
  override fun inboxViewed(deliveryId: String, promise: Promise) {
    if (!ready(promise)) return
    Treebars.inboxMessageViewed(deliveryId)
    promise.resolve(null)
  }

  override fun inboxClicked(deliveryId: String, destination: String, promise: Promise) {
    if (!ready(promise)) return
    Treebars.inboxMessageClicked(deliveryId, destination.ifEmpty { null })
    promise.resolve(null)
  }

  override fun notificationsMarkOpened(groupId: String, promise: Promise) {
    if (!ready(promise)) return
    Treebars.markNotificationOpened(groupId)
    promise.resolve(null)
  }

  override fun setInAppRendererEnabled(enabled: Boolean, promise: Promise) {
    if (!ready(promise)) return
    if (enabled) {
      Treebars.setInAppRenderer(renderer)
      /*
       * Re-emitted, never cleared. Metro's fast refresh rebuilds the JS listener set while
       * this module stays alive, and by then `recordDisplay`, the `in_app_displayed` report
       * and — for an immediate trigger — `markDone` have all been spent on this message.
       * Dropping it would leave an overlay that can never be drawn again and a dismiss that
       * can never arrive, so the message is both spent and unseen.
       */
      presentation?.let { live ->
        guarded("in-app presentation") { emitOnInAppPresent(live.payload) }
      }
    } else {
      // Hands drawing back to the core, which draws a standard message natively when no
      // renderer is installed.
      Treebars.setInAppRenderer(null)
    }
    promise.resolve(null)
  }

  override fun inAppClick(presentationId: String, buttonJson: String, promise: Promise) {
    if (!ready(promise)) return
    val button = readObject(buttonJson, "an in-app button", promise) ?: return

    val live = presentation
    if (live == null || live.id != presentationId) {
      // Not an error. A markup body can fire a click after its own dismiss, and an overlay
      // superseded by a second message answers for a slot that has moved on.
      Log.i(TAG, "Ignoring a click on presentation $presentationId, which is no longer live")
      return promise.resolve(null)
    }

    /*
     * The slot stays live, and this is the subtle half of the protocol. A renderer that reports
     * a click, such as a markup body's `treebars://click/<n>`, keeps its overlay up — closing it
     * here would make click a third spelling of dismiss — and a markup body fires click and then
     * dismiss on the same presentation. Clearing on click would drop that dismiss as stale,
     * losing both `in_app_dismissed` and `markDone`, and the message would be redrawn on the
     * next matching event. Repeated clicks are therefore expected and safe.
     */
    live.onClick(buttonFrom(button, actionWhenAbsent = "dismiss"))
    promise.resolve(null)
  }

  // The app's contexts, and a form's answers, straight to the core.
  override fun setInAppContext(contextsJson: String, promise: Promise) {
    if (!ready(promise)) return
    val list = runCatching { org.json.JSONArray(contextsJson) }.getOrNull()
      ?: return promise.reject(BAD_PAYLOAD, "Treebars: the app contexts were not a JSON list")
    Treebars.setInAppContext((0 until list.length()).mapNotNull { list.optString(it).takeIf { name -> name.isNotEmpty() } }.toSet())
    promise.resolve(null)
  }

  override fun resetInAppContext(promise: Promise) {
    if (!ready(promise)) return
    Treebars.resetInAppContext()
    promise.resolve(null)
  }

  override fun submitInAppForm(deliveryId: String, responsesJson: String, promise: Promise) {
    if (!ready(promise)) return
    val responses = readObject(responsesJson, "the form's answers", promise) ?: return
    Treebars.submitInAppForm(deliveryId, responses.keys().asSequence().associateWith { responses.get(it) })
    promise.resolve(null)
  }

  override fun inAppDismiss(presentationId: String, promise: Promise) {
    if (!ready(promise)) return

    val live = presentation
    if (live == null || live.id != presentationId) {
      Log.i(TAG, "Ignoring a dismiss of presentation $presentationId, which is no longer live")
      return promise.resolve(null)
    }

    // Cleared before the callback, not after: `onDismiss` tracks `in_app_dismissed`, which
    // runs the trigger matcher again, and a second message chosen from inside this call would
    // otherwise fill a slot this line then empties.
    presentation = null
    live.onDismiss()
    promise.resolve(null)
  }

  /**
   * The crux of this file: two closures the core hands out, and a bridge that cannot pass one.
   *
   * `InAppRenderer.show` is called with `(onClick, onDismiss)` bound to this message's
   * bookkeeping — the display ledger, the `in_app_dismissed` report, `markDone`. A TurboModule
   * cannot give JS a function, so what crosses is an id: the callbacks are held here against
   * it, and JS names it again on the way back.
   *
   * One slot rather than a map, because both cores draw one overlay at a time. A second
   * presentation supersedes the first rather than ending it — calling the superseded
   * `onDismiss` would report a dismissal nobody performed and mark done a message nobody read.
   *
   * The core posts this to the main thread, so a throw here is a throw on the app's own looper
   * with nothing above it. [guarded] is the difference between a lost overlay and a crash.
   */
  private val renderer = object : Treebars.InAppRenderer, Treebars.InAppSurfaceCheck {
    /*
     * Whether a React Native Modal would appear now. It draws into the React context's current Activity
     * and, when that is null or finishing, skips `dialog.show()` without a word (`ReactModalHostView`) — while the
     * JavaScript side renders it happily. So the answer has to come from here, and it is the whole of what this adds:
     * the core decides what a "no" means.
     */
    override fun canPresent(): Boolean {
      val activity = reactApplicationContext.currentActivity ?: return false
      return !activity.isFinishing && !activity.isDestroyed
    }

    override fun show(
      message: InAppMessage,
      tokens: InAppTokens?,
      onClick: (InAppButton) -> Unit,
      onDismiss: () -> Unit,
    ) = present(message, tokens, onClick, onDismiss)
  }

  private fun present(
    message: InAppMessage,
    tokens: InAppTokens?,
    onClick: (InAppButton) -> Unit,
    onDismiss: () -> Unit,
  ) {
    guarded("in-app presentation") {
      val id = "pres_${UUID.randomUUID()}"
      val payload = JSONObject()
        .put("presentationId", id)
        .put("message", message.raw)
        // The resolved pair — this message's own tokens, or the project default from the last
        // sync. JS receives one answer because the second half of that fallback never crosses.
        .put("tokens", tokens?.let(::tokensJson) ?: JSONObject.NULL)
        .toString()

      // Held before the emit. An emit into a runtime that has gone still leaves a presentation
      // this module can answer for, and `setInAppRendererEnabled(true)` hands it back.
      presentation = Presentation(id, payload, onClick, onDismiss)
      emitOnInAppPresent(payload)
    }
  }

  // -----------------------------------------------------------------------------------------
  // The notification centre
  // -----------------------------------------------------------------------------------------

  override fun notificationsList(optionsJson: String, promise: Promise) {
    if (!ready(promise)) return
    val options = readObject(optionsJson, "the notification list options", promise) ?: return

    val limit = if (options.isNull("limit")) null else options.optInt("limit")
    val cursor = options.stringOrNull("cursor")
    val channels = options.optJSONArray("channels")?.let { array ->
      (0 until array.length()).mapNotNull { array.optString(it).takeIf(String::isNotEmpty) }
    }

    scope.launch {
      answer(promise, "the notification page") {
        pageJson(Treebars.notifications(limit, cursor, channels)).toString()
      }
    }
  }

  override fun notificationsMarkRead(groupId: String, promise: Promise) {
    if (!ready(promise)) return
    Treebars.markNotificationRead(groupId)
    promise.resolve(null)
  }

  override fun notificationsMarkAllRead(promise: Promise) {
    if (!ready(promise)) return
    Treebars.markAllNotificationsRead()
    promise.resolve(null)
  }

  override fun notificationsDismiss(groupId: String, promise: Promise) {
    if (!ready(promise)) return
    Treebars.dismissNotification(groupId)
    promise.resolve(null)
  }

  /**
   * Whether JS is watching for the link that brought somebody here.
   *
   * The bell's rule, and here it is the whole feature rather than a saving: the core hands the
   * path over ONCE and forgets it, so registering at `initialize` would spend that one delivery
   * on a JS runtime whose effects had not run. Nothing is held on this side — the core's own
   * store already survives the race and the process, so there is nothing to re-emit.
   *
   * No `ready` gate: subscribing before `initialize` is the ordinary React ordering, and the core
   * takes the listener either way. Refusing here would make the bridge stricter than what it
   * bridges, exactly as it would for `setAcquisitionConsent`.
   */
  override fun setDeferredDeepLinkSubscribed(subscribed: Boolean, promise: Promise) {
    if (subscribed) {
      Treebars.onDeferredDeepLink { path ->
        // The core posts this to the main thread and catches a throw from us; the guard is for
        // the emit itself, into a runtime that may have gone.
        guarded("deferred deep link") { emitOnDeferredDeepLink(path) }
      }
    } else {
      Treebars.onDeferredDeepLink(null)
    }
    promise.resolve(null)
  }

  override fun setNotificationsSubscribed(subscribed: Boolean, promise: Promise) {
    if (!ready(promise)) return

    if (subscribed) {
      if (notificationsWatcher == null) {
        notificationsWatcher = Treebars.onNotificationsChange { page ->
          // The core iterates its watchers inline from `markNotificationRead` and friends and
          // catches nothing; a throw here would take the caller's own call down with it.
          guarded("notification page") {
            val payload = pageJson(page).toString()
            lastNotificationPage = payload
            emitOnNotificationsChange(payload)
          }
        }
      }
      // The re-subscribe half of the rule. A remounted bell would otherwise draw an empty
      // badge until something independently changed the centre.
      lastNotificationPage?.let { page ->
        guarded("notification page") { emitOnNotificationsChange(page) }
      }
    } else {
      notificationsWatcher?.invoke()
      notificationsWatcher = null
    }
    promise.resolve(null)
  }

  // -----------------------------------------------------------------------------------------
  // Teardown
  // -----------------------------------------------------------------------------------------

  /**
   * The React context is going away; the core is a process singleton and is not.
   *
   * So the renderer and the upload listener have to be handed back, or they go on holding a
   * module whose JS runtime has gone — and the next context's module would emit into nothing
   * while this one's closures quietly answered instead.
   *
   * **Only if we are still the owner.** A reload can build the next module before this one is
   * torn down, and an unconditional `setInAppRenderer(null)` here would then clear the live
   * module's renderer — after which overlays simply stop, with every screen still working.
   * The watcher is different: it is our own registration in a list that only grows, so it is
   * always handed back.
   */
  override fun invalidate() {
    notificationsWatcher?.invoke()
    notificationsWatcher = null

    if (owner === this) {
      Treebars.setInAppRenderer(null)
      Treebars.setUploadListener(null)
      // A single slot like the renderer, not a list like the watcher, so it goes here for the
      // same reason: clearing it unconditionally would take the live module's listener with it.
      Treebars.onDeferredDeepLink(null)
      Treebars.setClickActionListener(null)
      Treebars.setSelfHandledListener(null)
      Treebars.removeInAppLifeCycleListener(lifeCycle)
      TreebarsPush.setActionListener(null)
      owner = null
    }

    scope.cancel()
    super.invalidate()
  }

  // -----------------------------------------------------------------------------------------
  // Marshalling
  // -----------------------------------------------------------------------------------------

  private class Presentation(
    val id: String,
    /** The exact bytes emitted, so a re-emit cannot differ from what JS first saw. */
    val payload: String,
    val onClick: (InAppButton) -> Unit,
    val onDismiss: () -> Unit,
  )

  private fun ready(promise: Promise): Boolean {
    if (initialized) return true
    promise.reject(NOT_INITIALIZED, "Treebars: initialize() has not run on the native side.")
    return false
  }

  /**
   * Answers a promise from inside a coroutine, where nothing else will.
   *
   * A Promise method that throws is auto-rejected by the TurboModule machinery above it, and
   * the suspending members of the core sit on the far side of that frame: an exception in
   * a launched coroutine reaches the thread's uncaught handler — a crash — and leaves the JS
   * promise pending for the life of the app besides.
   *
   * Cancellation is the one failure with nothing to answer. [invalidate] cancels this scope,
   * and by then the runtime holding the promise has gone; rejecting into it is at best noise
   * and at worst the very throw this function exists to prevent. Which is also why the
   * answering calls themselves are guarded rather than trusted.
   */
  private suspend fun answer(promise: Promise, what: String, produce: suspend () -> Any?) {
    val value = try {
      produce()
    } catch (cancelled: CancellationException) {
      throw cancelled
    } catch (error: Throwable) {
      runCatching { promise.reject(UNEXPECTED, "Treebars: $what could not be read.", error) }
        .onFailure { Log.w(TAG, "Treebars: could not reject $what", it) }
      return
    }
    runCatching { promise.resolve(value) }
      .onFailure { Log.w(TAG, "Treebars: could not resolve $what", it) }
  }

  /** One parse per call, and a rejection rather than an empty object when it fails. */
  private fun readObject(raw: String, what: String, promise: Promise): JSONObject? = try {
    JSONObject(raw)
  } catch (error: JSONException) {
    promise.reject(BAD_PAYLOAD, "Treebars: $what was not readable JSON. ${error.message}", error)
    null
  }

  /**
   * Runs something that has no promise to reject into.
   *
   * Every one of these is a callback the core invokes from a thread this file does not own —
   * the app's looper for the renderer, the flush coroutine for an upload log, whatever called
   * `markNotificationRead` for a page. A Promise method that throws is auto-rejected by the
   * TurboModule machinery; nothing catches these, so an emit into a torn-down runtime would
   * be an uncaught exception rather than a dropped event.
   */
  private inline fun guarded(what: String, body: () -> Unit) {
    runCatching(body).onFailure { Log.w(TAG, "Treebars: could not emit $what", it) }
  }

  private fun adoption(json: JSONObject?): Adoption {
    if (json == null) return Adoption()
    /*
     * The core writes each of these only into a key it does not already hold, which is what
     * makes handing them down on every launch safe. The field names are camelCase because
     * `adoption.ts` names them after this data class rather than after the AsyncStorage keys —
     * a mismatch here is silent, and the device loses its identity and starts again as a new
     * one.
     */
    return Adoption(
      deviceId = json.stringOrNull("deviceId"),
      fetchSecret = json.stringOrNull("fetchSecret"),
      firstSeenAt = json.stringOrNull("firstSeenAt"),
      signedInUser = json.stringOrNull("signedInUser"),
      identifiedUser = json.stringOrNull("identifiedUser"),
      inAppLedgerJson = json.stringOrNull("inAppLedgerJson"),
      sdkName = json.stringOrNull("sdkName"),
    )
  }

  /**
   * A button as JavaScript sends it, every field of it.
   *
   * One reading for a renderer's press and a self-handled one, so the two cannot come to disagree about what a button
   * carries: what the core reports — the label, the index, where a link goes — and what says what a press does — a
   * `track_event`'s event, a `set_attribute`'s trait, a `custom` button's keys. [actionWhenAbsent] is the one thing the
   * callers differ on: what a button naming no action means to each.
   */
  private fun buttonFrom(json: JSONObject, actionWhenAbsent: String): InAppButton = InAppButton(
    label = json.stringOrNull("label").orEmpty(),
    action = json.stringOrNull("action") ?: actionWhenAbsent,
    value = json.stringOrNull("value"),
    eventName = json.stringOrNull("event_name"),
    key = json.stringOrNull("key"),
    data = json.optJSONObject("data")?.let { data -> data.keys().asSequence().associateWith { name -> data.optString(name) } },
    // Which element was pressed: the host's `treebars://click/<n>`, or a typed button's place.
    index = if (json.has("index")) json.optInt("index").takeIf { it > 0 } else null,
  )

  private fun pageJson(page: NotificationPage): JSONObject = JSONObject()
    .put("notifications", JSONArray().apply { page.notifications.forEach { put(it.raw) } })
    .put("unreadCount", page.unreadCount)
    .put("nextCursor", page.nextCursor ?: JSONObject.NULL)
    .put("fromCache", page.fromCache)

  /**
   * The wire's own spelling, which is snake_case and not this data class's.
   *
   * The exact inverse of `parseInAppTokens` in the core. JS declares `InAppTokens` in the
   * server's shape, so a camelCase copy here would read as nine absent tokens — every overlay
   * drawn in the renderer's fallback colours, with nothing failing.
   */
  private fun tokensJson(tokens: InAppTokens): JSONObject = JSONObject()
    .put("accent", tokens.accent)
    .put("on_accent", tokens.onAccent)
    .put("surface", tokens.surface)
    .put("on_surface", tokens.onSurface)
    .put("on_surface_muted", tokens.onSurfaceMuted)
    .put("backdrop", tokens.backdrop)
    .put("radius", tokens.radius)
    .put("font_family", tokens.fontFamily)
    .put("button_shape", tokens.buttonShape)

  private fun uploadLogJson(log: UploadLog): JSONObject = JSONObject()
    .put("type", log.type)
    .put("status", log.status)
    .put("message", log.message)
    .apply {
      // Omitted rather than nulled: `count` and `eventNames` are absent on anything that is
      // not an event batch, and a log that printed "0 events" for a user sync would be
      // describing a batch that never existed.
      log.count?.let { put("count", it) }
      log.eventNames?.let { put("eventNames", JSONArray(it)) }
      log.statusCode?.let { put("statusCode", it) }
    }

  private fun JSONObject.stringOrNull(key: String): String? =
    if (isNull(key)) null else optString(key).takeIf { it.isNotEmpty() }

  /**
   * Event properties, with nested objects and arrays left as `JSONObject`/`JSONArray`.
   *
   * `buildEvent` puts this map through `JSONObject(Map)`, whose `wrap` passes both through
   * untouched — so nesting survives without this file walking it. A JSON `null` becomes a
   * Kotlin null rather than `JSONObject.NULL`, because the trigger matcher compares these
   * values and `NULL` is an object that equals nothing.
   */
  private fun JSONObject.toValueMap(): Map<String, Any?> {
    val values = mutableMapOf<String, Any?>()
    for (key in keys()) values[key] = if (isNull(key)) null else opt(key)
    return values
  }

  /** The push data map, which the core reads two known keys out of and ignores the rest. */
  private fun JSONObject.toStringMap(): Map<String, String> {
    val values = mutableMapOf<String, String>()
    for (key in keys()) if (!isNull(key)) values[key] = optString(key)
    return values
  }

  companion object {
    /**
     * The name JS asks for; it must match `TurboModuleRegistry.get` in `src/NativeTreebars.ts`
     * and the iOS class name. Two modules answering to one name would break startup, which is
     * why `TreebarsSdkPackage` refuses to override an existing module.
     */
    const val NAME = "TreebarsNative"

    private const val TAG = "Treebars"

    /** A payload that would not parse, or an argument that named nothing real. */
    private const val BAD_PAYLOAD = "bad_payload"

    /** A config that parsed and cannot be used: no write key, no backend, an unknown env. */
    private const val BAD_CONFIG = "bad_config"

    private const val NOT_INITIALIZED = "not_initialized"

    /** Only ever from inside a coroutine, where nothing else would answer the promise. */
    private const val UNEXPECTED = "unexpected"

    /**
     * Which module instance installed the core's renderer and upload listener.
     *
     * The core outlives any React context, so teardown has to be able to ask "is this still
     * mine". See [invalidate] for what goes wrong without it.
     */
    @Volatile
    private var owner: TreebarsNativeModule? = null
  }
}
