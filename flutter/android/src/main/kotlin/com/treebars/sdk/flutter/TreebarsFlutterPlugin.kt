package com.treebars.sdk.flutter

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.treebars.sdk.Adoption
import com.treebars.sdk.AppActionHandler
import com.treebars.sdk.AppActionSubscription
import com.treebars.sdk.ClickActionListener
import com.treebars.sdk.InAppButton
import com.treebars.sdk.InAppLifeCycleListener
import com.treebars.sdk.InAppMessage
import com.treebars.sdk.NotificationPage
import com.treebars.sdk.NotificationTopic
import com.treebars.sdk.PushProvider
import com.treebars.sdk.SelfHandledListener
import com.treebars.sdk.Treebars
import com.treebars.sdk.TreebarsEnv
import com.treebars.sdk.TreebarsPush
import com.treebars.sdk.UploadLog
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import org.json.JSONTokener
import java.util.concurrent.ConcurrentHashMap

/**
 * The Android half of the Flutter bridge. Everything below it is `com.treebars.sdk.Treebars`.
 *
 * What lives here is only translation: a method call with JSON text in its arguments, a call on
 * the native SDK, and a result, or an error with a code. The native SDK holds the queue, the
 * retries, sessions, storage and in-app drawing; none of that is decided in this file.
 *
 * **Nothing here swallows.** A payload that will not parse fails with `bad_payload` and names what
 * it was reading. It never passes an empty map onward or answers a plausible value in its place.
 *
 * **What a result here means.** Every write on the native SDK is launched on its own scope and
 * returns before anything is queued, let alone sent. A write's result means the call was
 * accepted, not that anything landed.
 *
 * **Events go out on one stream**, as `{ name, data }` JSON, always on the main thread, which is
 * the only thread Flutter accepts them on.
 */
class TreebarsFlutterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler, ActivityAware {

  private lateinit var context: Context
  private lateinit var methods: MethodChannel
  private lateinit var events: EventChannel

  private val main = Handler(Looper.getMainLooper())
  private var scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

  @Volatile private var sink: EventChannel.EventSink? = null
  private var activity: Activity? = null

  /**
   * Whether `initialize` has run. The bridge's own, because the native SDK answers a call made too
   * early by returning quietly, and passing that on would report an SDK that is working and silent
   * rather than one that was never started.
   */
  @Volatile private var initialized = false

  private var notificationsWatcher: (() -> Unit)? = null
  private var configWatcher: (() -> Unit)? = null

  /** The last page sent, so a watcher that subscribes again is answered at once. */
  @Volatile private var lastNotificationPage: JSONObject? = null

  private var subscribedEvents: Set<String> = emptySet()
  private val appActionSubscriptions = ConcurrentHashMap<Int, AppActionSubscription>()

  /** The self-handled messages handed to Dart, by delivery id, so a report on one finds it. */
  private val selfHandledMessages = LinkedHashMap<String, InAppMessage>()

  // -------------------------------------------------------------------------------------------
  // Plugin lifecycle
  // -------------------------------------------------------------------------------------------

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    methods = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also { it.setMethodCallHandler(this) }
    events = EventChannel(binding.binaryMessenger, EVENT_CHANNEL).also { it.setStreamHandler(this) }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    methods.setMethodCallHandler(null)
    events.setStreamHandler(null)
    notificationsWatcher?.invoke()
    notificationsWatcher = null
    configWatcher?.invoke()
    configWatcher = null
    Treebars.setUploadListener(null)
    Treebars.onDeferredDeepLink(null)
    Treebars.setClickActionListener(null)
    Treebars.setSelfHandledListener(null)
    Treebars.removeInAppLifeCycleListener(lifeCycle)
    TreebarsPush.setActionListener(null)
    TreebarsPush.setOpenListener(null)
    appActionSubscriptions.values.forEach { it.cancel() }
    appActionSubscriptions.clear()
    scope.cancel()
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
    sink = events
  }

  override fun onCancel(arguments: Any?) {
    sink = null
  }

  /*
   * The Activity in front. Flutter starts the SDK from Dart, which runs only once its Activity is
   * up, so the native SDK's own tracker never saw it resume; without telling it, the first message
   * it draws would wait for the app's next resume.
   */
  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activity = binding.activity
    if (initialized) TreebarsPush.noteResumedActivity(binding.activity)
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

  override fun onDetachedFromActivityForConfigChanges() {
    activity = null
  }

  override fun onDetachedFromActivity() {
    activity = null
  }

  // -------------------------------------------------------------------------------------------
  // Calls
  // -------------------------------------------------------------------------------------------

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    try {
      dispatch(call, result)
    } catch (error: BridgeFailure) {
      result.error(error.code, error.message, null)
    } catch (error: Throwable) {
      Log.w(TAG, "Treebars: ${call.method} failed", error)
      result.error(UNEXPECTED, "Treebars: ${call.method} failed. ${error.message}", null)
    }
  }

  private fun dispatch(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      // Lifecycle
      "initialize" -> initialize(readObject(call.string("config"), "the Treebars config"), result)
      "reset" -> ready { Treebars.reset() }.also { result.success(null) }
      "flush" -> ready { Treebars.flush() }.also { result.success(null) }
      "optOut" -> Treebars.optOut().also { result.success(null) }
      "optIn" -> Treebars.optIn().also { result.success(null) }
      "isOptedOut" -> result.success(Treebars.isOptedOut())
      "contextToken" -> answer(result, "the context token") { Treebars.contextToken() }
      "wipeLocalData" -> ready { Treebars.wipeLocalData() }.also { result.success(null) }
      "setAcquisitionConsent" -> Treebars.setAcquisitionConsent(call.bool("granted")).also { result.success(null) }
      "handleLink" -> Treebars.handleLink(call.string("url")) { path -> main.post { result.success(path) } }

      // Events
      "track" -> ready {
        val name = call.string("name")
        Treebars.track(name, readObject(call.string("properties"), "the properties of \"$name\"").toValueMap())
      }.also { result.success(null) }
      "screen" -> ready {
        val name = call.string("name")
        Treebars.screen(name, readObject(call.string("properties"), "the properties of screen \"$name\"").toValueMap())
      }.also { result.success(null) }
      "identify" -> ready {
        val userId = call.argument<String>("userId")
        val attributes = readObject(call.string("attributes"), "the attributes of \"$userId\"").toValueMap()
        Treebars.identify(userId, attributes, call.argument<String>("signature"))
      }.also { result.success(null) }

      // Push
      "registerPushToken" -> ready {
        val provider = when (val name = call.string("provider")) {
          PushProvider.FCM.value -> PushProvider.FCM
          PushProvider.APNS.value -> PushProvider.APNS
          else -> throw BridgeFailure(BAD_PAYLOAD, "Treebars: \"$name\" is not a push provider. Use fcm or apns.")
        }
        Treebars.registerPushToken(call.string("token"), provider)
      }.also { result.success(null) }
      "trackNotificationOpened" -> ready {
        Treebars.trackNotificationOpened(readObject(call.string("payload"), "the push payload").toStringMap())
      }.also { result.success(null) }
      "trackNotificationDismissed" -> ready {
        Treebars.trackNotificationDismissed(readObject(call.string("payload"), "the push payload").toStringMap())
      }.also { result.success(null) }
      // No `initialize` needed: an app may call it from a background message handler.
      "handleRemotePush" -> {
        val payload = readObject(call.string("payload"), "the push payload").toStringMap()
        answer(result, "the push") { TreebarsPush.handle(context, payload) }
      }
      "requestPushPermission" -> ready {
        activity?.let { TreebarsPush.requestPermission(it) }
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? android.app.NotificationManager
        result.success(manager?.areNotificationsEnabled() ?: false)
      }
      "setEventsSubscribed" -> setEventsSubscribed(call.string("names")).also { result.success(null) }
      "subscribeAppAction" -> subscribeAppAction(call.int("id"), call.argument<String>("name")).also { result.success(null) }
      "unsubscribeAppAction" -> appActionSubscriptions.remove(call.int("id"))?.cancel().also { result.success(null) }

      // In-app
      "syncInAppMessages" -> ready { Treebars.syncInAppMessages() }.also { result.success(null) }
      "setInAppContext" -> ready {
        val list = readArray(call.string("contexts"), "the app contexts")
        Treebars.setInAppContext((0 until list.length()).mapNotNull { list.optString(it).takeIf(String::isNotEmpty) }.toSet())
      }.also { result.success(null) }
      "resetInAppContext" -> ready { Treebars.resetInAppContext() }.also { result.success(null) }
      "showInApp" -> ready { Treebars.showInApp(context) }.also { result.success(null) }
      "holdInApp" -> Treebars.holdInApp().also { result.success(null) }
      "releaseInApp" -> Treebars.releaseInApp().also { result.success(null) }
      "showNudge" -> ready { Treebars.showNudge(context) }.also { result.success(null) }
      "getSelfHandledInApps" -> ready {
        Treebars.getSelfHandledInApps(context) { messages ->
          messages.forEach(::rememberSelfHandled)
          val json = JSONArray().apply { messages.forEach { put(it.raw) } }.toString()
          main.post { result.success(json) }
        }
      }
      "selfHandledShown" -> ready {
        Treebars.selfHandledShown(context, selfHandled(call.string("deliveryId")))
      }.also { result.success(null) }
      "selfHandledClicked" -> ready {
        val message = selfHandled(call.string("deliveryId"))
        val button = call.string("button").takeIf { it.isNotEmpty() }
          ?.let { buttonFrom(readObject(it, "an in-app button"), actionWhenAbsent = "click") }
        Treebars.selfHandledClicked(context, message, button)
      }.also { result.success(null) }
      "selfHandledDismissed" -> ready {
        Treebars.selfHandledDismissed(context, selfHandled(call.string("deliveryId")))
      }.also { result.success(null) }
      "submitInAppForm" -> ready {
        val responses = readObject(call.string("responses"), "the form's answers")
        Treebars.submitInAppForm(call.string("deliveryId"), responses.keys().asSequence().associateWith { responses.get(it) })
      }.also { result.success(null) }
      "inboxList" -> ready {
        result.success(JSONArray().apply { Treebars.inbox().forEach { put(it.raw) } }.toString())
      }
      "inboxDismiss" -> ready { Treebars.dismissInboxMessage(call.string("deliveryId")) }.also { result.success(null) }
      "inboxViewed" -> ready { Treebars.inboxMessageViewed(call.string("deliveryId")) }.also { result.success(null) }
      "inboxClicked" -> ready {
        Treebars.inboxMessageClicked(call.string("deliveryId"), call.string("destination").ifEmpty { null })
      }.also { result.success(null) }

      // The notification centre
      "notificationsList" -> ready {
        val options = readObject(call.string("options"), "the notification list options")
        val limit = if (options.isNull("limit")) null else options.optInt("limit")
        val channels = options.optJSONArray("channels")?.let { array ->
          (0 until array.length()).mapNotNull { array.optString(it).takeIf(String::isNotEmpty) }
        }
        answer(result, "the notification page") {
          pageJson(Treebars.notifications(limit, options.stringOrNull("cursor"), channels, options.stringOrNull("topic"))).toString()
        }
      }
      "notificationsTopics" -> ready {
        answer(result, "the notification topics") { topicsJson(Treebars.notificationTopics()).toString() }
      }
      "notificationsMarkRead" -> ready { Treebars.markNotificationRead(call.string("groupId")) }.also { result.success(null) }
      "notificationsMarkOpened" -> ready { Treebars.markNotificationOpened(call.string("groupId")) }.also { result.success(null) }
      "notificationsMarkAllRead" -> ready {
        Treebars.markAllNotificationsRead(call.argument<String>("topic")?.takeIf { it.isNotEmpty() })
      }.also { result.success(null) }
      "notificationsDismiss" -> ready { Treebars.dismissNotification(call.string("groupId")) }.also { result.success(null) }
      "setNotificationsSubscribed" -> ready { setNotificationsSubscribed(call.bool("subscribed")) }.also { result.success(null) }
      "setDeferredDeepLinkSubscribed" -> {
        if (call.bool("subscribed")) Treebars.onDeferredDeepLink { path -> emit("deferredDeepLink", path) }
        else Treebars.onDeferredDeepLink(null)
        result.success(null)
      }

      // Telemetry
      "pendingCount" -> ready { answer(result, "the pending count") { Treebars.pendingCount() } }
      "msUntilNextFlush" -> result.success(Treebars.msUntilNextFlush() ?: -1L)

      // Remote config: none of these needs `initialize`, as the native SDK answers the fallback until it has started.
      "configBoolean" -> result.success(Treebars.getConfigBoolean(call.string("key"), call.bool("fallback")))
      "configString" -> result.success(Treebars.getConfigString(call.string("key"), call.string("fallback")))
      "configNumber" -> result.success(Treebars.getConfigNumber(call.string("key"), call.double("fallback")))
      "configJson" -> result.success(Treebars.getConfigJson(call.string("key"), null))
      "configValue" -> {
        val key = call.string("key")
        result.success(
          when (call.string("kind")) {
            "boolean" -> Treebars.getConfigBoolean(key)?.toString()
            "string" -> Treebars.getConfigString(key)?.let(JSONObject::quote)
            "number" -> Treebars.getConfigNumber(key)?.let(JSONObject::numberToString)
            "json" -> Treebars.getConfigJson(key)
            else -> null
          },
        )
      }
      "allConfig" -> result.success(JSONObject(Treebars.allConfig()).toString())
      "activateConfig" -> result.success(Treebars.activateConfig())
      "fetchConfig" -> answer(result, "the config values") { Treebars.fetchConfig() }
      "configReady" -> answer(result, "the config values") { Treebars.configReady(call.int("timeoutMs").toLong()) }
      "setConfigAttributes" -> {
        Treebars.setConfigAttributes(readObject(call.string("attributes"), "the config attributes").toValueMap())
        result.success(null)
      }
      "setConfigOverride" -> {
        val raw = call.argument<String>("value")
        val value = if (raw == null) null else try {
          JSONTokener(raw).nextValue().takeUnless { it == JSONObject.NULL }
        } catch (error: JSONException) {
          throw BridgeFailure(BAD_PAYLOAD, "Treebars: the config override was not readable JSON. ${error.message}")
        }
        Treebars.setConfigOverride(call.string("key"), value)
        result.success(null)
      }

      else -> result.notImplemented()
    }
  }

  private fun initialize(config: JSONObject, result: MethodChannel.Result) {
    val writeKey = config.stringOrNull("write_key")
      ?: throw BridgeFailure(BAD_CONFIG, "Treebars: the config carried no write_key.")
    val backendUrl = config.stringOrNull("backend_url")
      ?: throw BridgeFailure(BAD_CONFIG, "Treebars: the config carried no backend_url.")
    // Refused here as well as in the native SDK, so `init` fails and says why rather than starting an SDK that sends nothing.
    if (!Treebars.acceptsBackendUrl(backendUrl)) {
      throw BridgeFailure(
        BAD_CONFIG,
        "Treebars: $backendUrl is not https. Plain http is accepted only for a local stack " +
          "(localhost, 10.0.2.2, a .local name or a private address).",
      )
    }
    // An unknown env is refused, never defaulted: a one-letter typo would send a test build's traffic to production.
    val envName = config.stringOrNull("env") ?: TreebarsEnv.PRODUCTION.value
    val env = TreebarsEnv.entries.firstOrNull { it.value == envName }
      ?: throw BridgeFailure(BAD_CONFIG, "Treebars: \"$envName\" is not an environment. Use production, stage or test.")

    val inAppEnabled = config.optBoolean("in_app_enabled", true)
    val pollIntervalMs =
      if (!inAppEnabled) 0L else config.optLong("in_app_poll_interval_ms", Treebars.DEFAULT_IN_APP_POLL_INTERVAL_MS)

    // Before `initialize`, so the first values this launch is given cannot arrive ahead of the listener.
    if (configWatcher == null) configWatcher = Treebars.onConfigChange { emit("configChange", JSONObject.NULL) }

    val adopt = config.optJSONObject("adopt")
    Treebars.initialize(
      context = context,
      writeKey = writeKey,
      backendUrl = backendUrl,
      env = env,
      // Absent is the native SDK's own pace, not a number written here.
      flushIntervalMs = config.optLong("flush_interval_ms", Treebars.SDK_PACE),
      debug = config.optBoolean("debug", false),
      autoTrackLifecycle = config.optBoolean("auto_track_lifecycle", true),
      autoTrackSessions = config.optBoolean("auto_track_sessions", true),
      inAppPollIntervalMs = pollIntervalMs,
      adopt = Adoption(sdkName = adopt?.stringOrNull("sdkName")),
      acquisitionConsent = config.optBoolean("acquisition_consent", true),
      linkHosts = config.optJSONArray("link_hosts")
        ?.let { hosts -> (0 until hosts.length()).mapNotNull { hosts.optString(it).takeIf(String::isNotBlank) } }
        ?: emptyList(),
    )
    initialized = true

    activity?.let { TreebarsPush.noteResumedActivity(it) }
    if (!inAppEnabled) Treebars.disableInApps()

    // After `initialize`: the listener is written through the uploader `initialize` builds.
    Treebars.setUploadListener { log -> emit("uploadLog", uploadLogJson(log)) }
    result.success(null)
  }

  // -------------------------------------------------------------------------------------------
  // Listeners
  // -------------------------------------------------------------------------------------------

  private val lifeCycle = object : InAppLifeCycleListener {
    override fun onShown(message: InAppMessage) = emit("inAppCampaignShown", campaignRef(message))
    override fun onDismiss(message: InAppMessage) = emit("inAppCampaignDismissed", campaignRef(message))
  }

  /**
   * Installs the native listeners for the events Dart listens to and removes the rest. A push
   * action that arrived before anybody listened is held by the native SDK and delivered here.
   */
  private fun setEventsSubscribed(namesJson: String) {
    val list = readArray(namesJson, "the event names")
    val names = (0 until list.length()).map { list.optString(it) }.toSet()
    subscribedEvents = names

    val wantsClicks = "inAppCampaignClicked" in names || "inAppCampaignCustomAction" in names
    Treebars.setClickActionListener(
      if (!wantsClicks) null else ClickActionListener { action, message ->
        val payload = JSONObject()
          .put("source", "in_app")
          .put("type", action.type)
          .put("values", JSONObject(action.values))
          .put("delivery_id", message.deliveryId)
          .apply { action.button.index?.let { put("button_index", it) } }
        if ("inAppCampaignClicked" in subscribedEvents) emit("inAppCampaignClicked", payload)
        if (action.type == "custom" && "inAppCampaignCustomAction" in subscribedEvents) emit("inAppCampaignCustomAction", payload)
        // Not handled here: the native SDK still carries out the press.
        false
      },
    )

    Treebars.removeInAppLifeCycleListener(lifeCycle)
    if ("inAppCampaignShown" in names || "inAppCampaignDismissed" in names) Treebars.addInAppLifeCycleListener(lifeCycle)

    Treebars.setSelfHandledListener(
      if ("inAppCampaignSelfHandled" !in names) null else SelfHandledListener { message ->
        if (message == null) return@SelfHandledListener
        rememberSelfHandled(message)
        emit("inAppCampaignSelfHandled", message.raw)
      },
    )

    TreebarsPush.setActionListener(
      if ("pushClicked" !in names) null else TreebarsPush.ActionListener { type, values ->
        emit("pushClicked", JSONObject().put("source", "push").put("type", type).put("values", JSONObject(values)))
      },
    )
    TreebarsPush.setOpenListener(
      if ("pushOpened" !in names) null else TreebarsPush.OpenListener { open -> emit("pushOpened", open.toJson()) },
    )
  }

  private fun subscribeAppAction(id: Int, name: String?) {
    val handler = AppActionHandler { action ->
      val source = JSONObject().put("kind", action.source.kind)
        .put("campaign_id", action.source.campaignId ?: JSONObject.NULL)
        .put("message_id", action.source.messageId ?: JSONObject.NULL)
      val json = JSONObject()
        .put("name", action.name)
        .put("payload", JSONObject.wrap(action.payload) ?: JSONObject())
        .put("source", source)
      emit("appAction", JSONObject().put("id", id).put("action", json))
    }
    val made = if (name == null) Treebars.onAction(handler) else Treebars.onAction(name, handler)
    appActionSubscriptions.put(id, made)?.cancel()
  }

  /**
   * The watch is installed once and the last page is kept, so a watcher that goes and comes back —
   * a tab change, a hot reload — is answered at once rather than showing an empty badge until
   * something else changes the centre.
   */
  private fun setNotificationsSubscribed(subscribed: Boolean) {
    if (!subscribed) {
      notificationsWatcher?.invoke()
      notificationsWatcher = null
      return
    }
    if (notificationsWatcher == null) {
      notificationsWatcher = Treebars.onNotificationsChange { page ->
        val json = pageJson(page)
        lastNotificationPage = json
        emit("notificationsChange", json)
      }
    }
    lastNotificationPage?.let { emit("notificationsChange", it) }
  }

  private fun rememberSelfHandled(message: InAppMessage) = synchronized(selfHandledMessages) {
    if (selfHandledMessages.size >= SELF_HANDLED_KEPT) selfHandledMessages.remove(selfHandledMessages.keys.first())
    selfHandledMessages[message.deliveryId] = message
  }

  private fun selfHandled(deliveryId: String): InAppMessage =
    synchronized(selfHandledMessages) { selfHandledMessages[deliveryId] }
      ?: throw BridgeFailure(BAD_PAYLOAD, "Treebars: no self-handled message $deliveryId was handed to Dart")

  private fun campaignRef(message: InAppMessage) = JSONObject().put("delivery_id", message.deliveryId).apply {
    message.campaignId?.let { put("campaign_id", it) }
  }

  /**
   * Sends one event to Dart. The native SDK calls these from threads this file does not own, and
   * Flutter accepts events only on the main thread; a send into an engine that has gone is a
   * dropped event, never an exception on a thread with nothing above it.
   */
  private fun emit(name: String, data: Any) {
    val payload = runCatching { JSONObject().put("name", name).put("data", data).toString() }
      .onFailure { Log.w(TAG, "Treebars: could not encode $name", it) }
      .getOrNull() ?: return
    main.post {
      runCatching { sink?.success(payload) }.onFailure { Log.w(TAG, "Treebars: could not send $name", it) }
    }
  }

  // -------------------------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------------------------

  private inline fun ready(body: () -> Unit) {
    if (!initialized) throw BridgeFailure(NOT_INITIALIZED, "Treebars: init() has not run.")
    body()
  }

  /** Runs a suspending read on the bridge's scope and answers on the main thread. */
  private fun answer(result: MethodChannel.Result, what: String, produce: suspend () -> Any?) {
    scope.launch {
      val value = try {
        produce()
      } catch (cancelled: CancellationException) {
        throw cancelled
      } catch (error: Throwable) {
        main.post { result.error(UNEXPECTED, "Treebars: $what could not be read. ${error.message}", null) }
        return@launch
      }
      main.post { result.success(value) }
    }
  }

  private fun readObject(raw: String, what: String): JSONObject = try {
    JSONObject(raw)
  } catch (error: JSONException) {
    throw BridgeFailure(BAD_PAYLOAD, "Treebars: $what was not readable JSON. ${error.message}")
  }

  private fun readArray(raw: String, what: String): JSONArray = try {
    JSONArray(raw)
  } catch (error: JSONException) {
    throw BridgeFailure(BAD_PAYLOAD, "Treebars: $what was not a JSON list. ${error.message}")
  }

  private fun MethodCall.string(key: String): String =
    argument<String>(key) ?: throw BridgeFailure(BAD_PAYLOAD, "Treebars: $method was called without $key.")

  private fun MethodCall.bool(key: String): Boolean =
    argument<Boolean>(key) ?: throw BridgeFailure(BAD_PAYLOAD, "Treebars: $method was called without $key.")

  private fun MethodCall.int(key: String): Int =
    argument<Number>(key)?.toInt() ?: throw BridgeFailure(BAD_PAYLOAD, "Treebars: $method was called without $key.")

  private fun MethodCall.double(key: String): Double =
    argument<Number>(key)?.toDouble() ?: throw BridgeFailure(BAD_PAYLOAD, "Treebars: $method was called without $key.")

  /** A button as Dart sends it: one reading, so what the native SDK reports and does cannot disagree. */
  private fun buttonFrom(json: JSONObject, actionWhenAbsent: String): InAppButton = InAppButton(
    label = json.stringOrNull("label").orEmpty(),
    action = json.stringOrNull("action") ?: actionWhenAbsent,
    value = json.stringOrNull("value"),
    eventName = json.stringOrNull("event_name"),
    key = json.stringOrNull("key"),
    data = json.optJSONObject("data")?.let { data -> data.keys().asSequence().associateWith { name -> data.optString(name) } },
    index = if (json.has("index")) json.optInt("index").takeIf { it > 0 } else null,
  )

  private fun pageJson(page: NotificationPage): JSONObject = JSONObject()
    .put("notifications", JSONArray().apply { page.notifications.forEach { put(it.raw) } })
    .put("unreadCount", page.unreadCount)
    .put("nextCursor", page.nextCursor ?: JSONObject.NULL)
    .put("fromCache", page.fromCache)
    .apply { page.topics?.let { put("topics", topicsJson(it)) } }

  /** The tabs in the wire's own shape, All's `key` as JSON null. */
  private fun topicsJson(topics: List<NotificationTopic>): JSONArray = JSONArray().apply {
    for (tab in topics) {
      put(
        JSONObject()
          .put("key", tab.key ?: JSONObject.NULL)
          .put("name", tab.name)
          .put("unread", tab.unread)
          .put("total", tab.total),
      )
    }
  }

  private fun uploadLogJson(log: UploadLog): JSONObject = JSONObject()
    .put("type", log.type)
    .put("status", log.status)
    .put("message", log.message)
    .apply {
      log.count?.let { put("count", it) }
      log.eventNames?.let { put("eventNames", JSONArray(it)) }
      log.statusCode?.let { put("statusCode", it) }
    }

  private fun JSONObject.stringOrNull(key: String): String? =
    if (isNull(key)) null else optString(key).takeIf { it.isNotEmpty() }

  private fun JSONObject.toValueMap(): Map<String, Any?> {
    val values = mutableMapOf<String, Any?>()
    for (key in keys()) values[key] = if (isNull(key)) null else opt(key)
    return values
  }

  private fun JSONObject.toStringMap(): Map<String, String> {
    val values = mutableMapOf<String, String>()
    for (key in keys()) if (!isNull(key)) values[key] = optString(key)
    return values
  }

  private class BridgeFailure(val code: String, override val message: String) : Exception(message)

  private companion object {
    const val METHOD_CHANNEL = "com.treebars.sdk/flutter"
    const val EVENT_CHANNEL = "com.treebars.sdk/flutter/events"
    const val TAG = "Treebars"
    const val BAD_PAYLOAD = "bad_payload"
    const val BAD_CONFIG = "bad_config"
    const val NOT_INITIALIZED = "not_initialized"
    const val UNEXPECTED = "unexpected"
    const val SELF_HANDLED_KEPT = 32
  }
}
