package com.treebars.sdk

import android.content.Context
import android.net.Uri
import android.content.SharedPreferences
import android.os.Handler
import android.os.Looper
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
import com.treebars.sdk.generated.TreebarsBridge
import com.treebars.sdk.generated.TreebarsConstants
import java.util.UUID

internal object Iso8601 {
    private val format = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }

    /**
     * Reading is tolerant where writing is exact.
     *
     * `SimpleDateFormat` is strict about its pattern: the one above requires milliseconds, so
     * `2020-01-01T00:00:00Z` — an ordinary ISO instant — would not parse with it alone. And null
     * is not "unknown" to the callers of [parseOrNull]: an `expires_at` that failed to parse means
     * a message that never expires, and a `last_shown_at` that failed means no minimum gap has
     * elapsed. Both would fail open, towards showing somebody more than the rules allow, so the
     * second-precision form is read as well. The server writes milliseconds today, but that is not
     * a property of the wire for a parser to depend on. The iOS SDK reads through two formatters
     * for the same reason.
     */
    private val secondsFormat = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }

    fun now(): String = synchronized(format) { format.format(System.currentTimeMillis()) }

    /** For an event stamped into a moment that has already passed; see `session_end`. */
    fun at(millis: Long): String = synchronized(format) { format.format(millis) }

    /** Null for anything unparseable, which is what an absent timestamp arrives as. */
    fun parseOrNull(value: String): Long? {
        if (value.isEmpty() || value == "null") return null
        synchronized(format) { runCatching { format.parse(value)?.time }.getOrNull() }
            ?.let { return it }
        return synchronized(secondsFormat) {
            runCatching { secondsFormat.parse(value)?.time }.getOrNull()
        }
    }
}

internal object TreebarsLogger {
    var debug = false
    fun log(message: String) {
        if (debug) android.util.Log.d("Treebars", message)
    }

    /** Not gated on [debug]: for a setup step the integration skipped, which nobody turns debug on to find. */
    fun warn(message: String) {
        android.util.Log.w("Treebars", message)
    }
}

/**
 * Values a wrapper SDK hands down from a store this core cannot read, for the `adopt` parameter
 * of [Treebars.initialize].
 *
 * Every field is null by default, and each is written only into a key that is currently empty —
 * see `adopt` on [Treebars.initialize] for why that asymmetry is the whole safety property.
 *
 * The in-app ledger crosses as an opaque JSON string rather than as a type: the wrapper's shapes
 * are its own and this core does not parse them. What matters is that the ledger's `done` map
 * survives, because it is what keeps a message somebody already dismissed from being shown again.
 * Without it every still-pending message would be drawn again on the first launch after the
 * upgrade, to people who had already said no.
 */
data class Adoption(
    val deviceId: String? = null,
    val fetchSecret: String? = null,
    val firstSeenAt: String? = null,
    val signedInUser: String? = null,
    val identifiedUser: String? = null,
    val inAppLedgerJson: String? = null,
    /**
     * The wrapper's own name, reported as `sdk_name`: `platform_type` reports the OS, so this is
     * what tells a React Native install from a native one.
     */
    val sdkName: String? = null,
) {
    internal fun applyTo(prefs: SharedPreferences) {
        val edit = prefs.edit()
        var wrote = false

        fun claim(key: String, value: String?) {
            if (value.isNullOrEmpty()) return
            // The guard, and the only one that matters: a key that already holds something is
            // this device's own answer and outranks anything a wrapper remembers.
            if (prefs.contains(key)) return
            edit.putString(key, value)
            wrote = true
        }

        // The device id and its secret are not claimed here: they go to `DeviceIdentityStore` as one
        // pair (`identity()`), because these preferences are what Auto Backup copies.
        claim(TreebarsConstants.KEY_FIRST_SEEN_AT, firstSeenAt)
        claim(TreebarsConstants.KEY_SIGNED_IN_USER, signedInUser)
        claim("identified_user", identifiedUser)
        claim("in_app_ledger", inAppLedgerJson)

        // `commit`, not `apply`: everything below this line in `initialize` reads these keys,
        // and `apply` is asynchronous.
        if (wrote) edit.commit()
    }

    /**
     * The id and secret a wrapper handed down, as the pair `DeviceIdentityStore` takes into an empty
     * store. An id without its secret gets a fresh secret; a secret without an id is ignored.
     */
    internal fun identity(): DeviceIdentity? {
        val id = deviceId?.takeIf { it.isNotEmpty() } ?: return null
        return DeviceIdentity(id, fetchSecret?.takeIf { it.isNotEmpty() } ?: mintDeviceSecret())
    }
}

/**
 * A label for `Treebars.initialize`'s `env`, which the SDK accepts and does not read: the write key is
 * what names the environment.
 */
enum class TreebarsEnv(val value: String) {
    PRODUCTION("production"),
    STAGE("stage"),
    TEST("test"),
}

enum class PushProvider(val value: String) {
    FCM("fcm"),
    APNS("apns"),
}

/**
 * The Treebars Android SDK.
 *
 * Call [initialize] once, from `Application.onCreate`, then [track] what people do, [identify]
 * them when they sign in and [reset] when they sign out. Events wait in a queue on disk that
 * survives process death, and are uploaded in batches — on a timer, when the app leaves the
 * foreground, and whenever [flush] is called — with exponential backoff when an upload fails. The
 * iOS SDK behaves the same way.
 */
object Treebars {

    /**
     * Keys Treebars puts into a push's data so a tap can be traced back to the send. Read by
     * [trackNotificationOpened] and [trackNotificationDismissed], and the same keys the iOS SDK
     * reads.
     */
    const val DELIVERY_ID_KEY = TreebarsConstants.DELIVERY_ID_KEY
    const val CAMPAIGN_ID_KEY = TreebarsConstants.CAMPAIGN_ID_KEY

    /**
     * The defaults [initialize] applies, public so a wrapper SDK can pass them on by name rather
     * than restating the numbers.
     */
    const val DEFAULT_FLUSH_INTERVAL_MS = TreebarsConstants.DEFAULT_FLUSH_INTERVAL_MS
    const val DEFAULT_IN_APP_POLL_INTERVAL_MS = TreebarsConstants.DEFAULT_IN_APP_POLL_INTERVAL_MS

    /**
     * The events the SDK emits on its own. The names are reserved for the SDK: an app's own
     * events should use others.
     */
    const val EVENT_APP_OPEN = "app_open"
    const val EVENT_APP_FOREGROUND = "app_foreground"
    const val EVENT_APP_BACKGROUND = "app_background"
    const val EVENT_SESSION_START = "session_start"
    const val EVENT_SESSION_END = "session_end"
    const val EVENT_SCREEN_VIEW = "screen_view"
    const val EVENT_USER_IDENTIFIED = "user_identified"
    const val EVENT_USER_SIGNED_OUT = "user_signed_out"
    /**
     * Traits a message set with nobody signed in. The values in `traits` go on the person and are not kept with the
     * event; `trait_keys` is what the event keeps, as `user_identified` keeps its keys.
     */
    internal const val EVENT_TRAITS_SET = "traits_set"
    const val EVENT_NOTIFICATION_READ = "notification_read"
    const val EVENT_NOTIFICATION_DISMISSED = "notification_dismissed"
    /** Once per install, with consent. See `Acquisition.kt`. */
    const val EVENT_INSTALL_REFERRER = "install_referrer"

    private const val BATCH_SIZE = TreebarsConstants.BATCH_SIZE
    private const val SDK_VERSION = TreebarsConstants.SDK_VERSION
    internal const val PREFS_NAME = "treebars.prefs"
    /** Under `cacheDir`: the files held messages load, by hash. */
    private const val ASSET_CACHE_DIR = "treebars-assets"

    /** The person's [optOut], in the preferences: their answer travels with a backup, as it should. */
    private const val KEY_OPTED_OUT = "opted_out"

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /**
     * The one hop to the main thread this SDK makes, and the only place it should.
     *
     * Everything else here is deliberately off it — the queue, the uploader, the stores and
     * the trigger matching are bookkeeping and have no business blocking a frame. The
     * exception is handing a message to the host app's renderer, which draws with it.
     */
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * What to call this SDK on the wire, when a wrapper is the thing an integrator installed.
     *
     * Null means this core. The React Native bridge passes `treebars-react-native`: `platform_type`
     * reports the real OS, so `sdk_name` is the only field that says which SDK an install is on,
     * and a bridge reporting `treebars-android` would make every React Native device look native.
     */
    @Volatile
    private var sdkNameOverride: String? = null

    private lateinit var appContext: Context
    private lateinit var queue: EventQueue
    private lateinit var uploader: EventUploader
    private lateinit var triggers: TriggerEvents

    private var writeKey: String? = null
    private var env: TreebarsEnv = TreebarsEnv.PRODUCTION
    private var userId: String? = null
    /**
     * The app's backend's signature of [userId], which an environment that requires signed
     * identities asks for on every content read. Kept beside the id and cleared with it: a
     * signature is only ever a claim about the person it names.
     */
    private var userSignature: String? = null
    /** Whether the app has been told its environment wants a signature. Once per process is enough. */
    @Volatile
    private var warnedSignature = false
    private var client: BackendClient? = null

    private lateinit var sessions: SessionManager
    private val recordMutex = Mutex()

    /**
     * [optOut]: nothing recorded and nothing sent until [optIn]. Kept in the preferences, and set in
     * memory by an [optOut] made before [initialize], which then keeps it.
     */
    @Volatile
    private var optedOut = false

    /**
     * An [optOut] or [optIn] made before [initialize], which it keeps over whatever an earlier launch
     * stored. Either answer, not only a "no": a person who says yes on a device that once said no is
     * recorded again.
     */
    @Volatile
    private var answerBeforeInit: Boolean? = null

    /** `track`'s records not yet on the queue, which a `flush()` waits for. */
    private val recording = InFlight()

    private var autoTrackLifecycle = true
    private var autoTrackSessions = true

    @Volatile
    private var currentScreen: String? = null

    private var foregroundedAt = 0L
    private var backgroundedAt = 0L
    private var firstSeenAt: String? = null
    private var firstLaunch = false

    @Volatile
    private var acquisitionConsent = false
    private lateinit var acquisition: AcquisitionCapture
    private lateinit var deferredDeepLink: DeferredDeepLink

    @Volatile
    private var deepLinkListener: ((String) -> Unit)? = null

    /** The app's own link domains, the only hosts [handleLink] asks about (`initialize`'s `linkHosts`). */
    @Volatile
    private var linkHosts: Set<String> = emptySet()

    /**
     * Milliseconds this app had been idle when this launch began. Zero on a first-ever launch.
     *
     * Read once in [initialize], before `SessionManager` stamps the activity time to now — see the
     * note there. The threshold that turns a gap into a re-engagement is not applied here: the device
     * reports the fact only it can measure and the server decides what it means, so the rule can
     * change without an SDK release.
     */
    private var idleAtLaunchMs: Long = 0L

    /**
     * Whether [initialize] would accept [backendUrl]: https, or plain http to a local development
     * server (`BackendUrl`). For a wrapper SDK, so a refused address can fail its own `init` rather
     * than leave an SDK that is silently off.
     */
    @JvmStatic
    fun acceptsBackendUrl(backendUrl: String): Boolean = BackendUrl.allows(backendUrl)

    /**
     * Starts the SDK. Call it once, from `Application.onCreate`, before the rest of this API; a
     * consent answer ([optOut], [optIn], [setAcquisitionConsent]) may be given first. Once it has
     * started, later calls are ignored.
     *
     * On the way up it records `app_open` (with `is_first_launch`), reports the device's context
     * when it has changed, uploads whatever an earlier launch left queued and fetches this device's
     * in-app messages — in the background, not on the calling thread.
     *
     * @param context any context; the SDK keeps only the application context.
     * @param writeKey the project's public write key.
     * @param backendUrl the ingest endpoint, such as `https://ingest.treebars.com`. It must be
     *   https; plain http is accepted only for a local development server. An address that is
     *   refused leaves the SDK off, with a warning in logcat, rather than throwing —
     *   [acceptsBackendUrl] answers the same question in advance.
     * @param env accepted and not read: no event or request carries it, and passing a different value
     *   changes nothing this SDK does. The write key is what names the environment — each environment
     *   of a project has its own, so the key an app is built with is the whole of that choice.
     * @param flushIntervalMs how often queued events are uploaded while the app is open.
     * @param debug log what the SDK does to logcat, under the tag `Treebars`. Warnings about a
     *   skipped setup step are logged either way.
     */
    @JvmStatic
    @JvmOverloads
    fun initialize(
        context: Context,
        writeKey: String,
        backendUrl: String,
        env: TreebarsEnv = TreebarsEnv.PRODUCTION,
        flushIntervalMs: Long = DEFAULT_FLUSH_INTERVAL_MS,
        debug: Boolean = false,
        /**
         * Emit `app_open`, `app_foreground` and `app_background` automatically.
         *
         * Turning this off also turns off the flush that rides on backgrounding, which is
         * the last reliable moment to upload before Android may kill the process. An app
         * that opts out should call [flush] from its own lifecycle handler.
         */
        autoTrackLifecycle: Boolean = true,
        /** Emit `session_start` and `session_end` around session boundaries. */
        autoTrackSessions: Boolean = true,
        /**
         * How often to re-pull the in-app queue while the app stays open. Zero disables it.
         *
         * Session start and foreground already sync, so this only catches an app left open
         * for a long time — which is why zero is a reasonable setting for anything opened
         * briefly.
         */
        inAppPollIntervalMs: Long = DEFAULT_IN_APP_POLL_INTERVAL_MS,
        /**
         * Values a wrapper SDK is handing down from its own store, honoured only into an empty one.
         *
         * For the first launch of a wrapper version in which this core takes over the device's
         * identity. Earlier React Native releases kept `device_id`, `fetch_secret`,
         * `first_seen_at` and the two user keys in AsyncStorage — a SQLite database on Android
         * and a manifest file on iOS, neither of which this core can read — so the wrapper reads
         * its own store and passes the values in.
         *
         * Each value matters. The device id and its secret travel as a pair: a missed id splits a
         * person's history across two devices and leaves their push token and inbox with the old
         * one. A missed `first_seen_at` reports `is_first_launch: true` on every existing install
         * at once, which would fire any onboarding campaign filtered on it.
         *
         * **Only into an empty store**, which is what makes this safe to pass on every launch
         * rather than only the first: once the native store holds a value it wins, so a wrapper
         * that keeps handing down a stale copy cannot overwrite it. A caller passes these
         * unconditionally and stops thinking about it.
         */
        adopt: Adoption = Adoption(),
        /**
         * Whether this install may read and report how it arrived — the Play Install Referrer,
         * sent once as `install_referrer`. **Off unless the host app says otherwise.**
         *
         * The referrer carries the click that led to the install, and in some consent regimes
         * reading it needs the person's agreement first, so the default is the one that is
         * never wrong. This never asks anybody anything: an app with a consent prompt passes
         * the answer here, or to [setAcquisitionConsent] once it has one. Nothing is lost by
         * waiting — the read is owed from the first launch and made whenever consent arrives.
         * `true` here grants; only [setAcquisitionConsent] withdraws.
         */
        acquisitionConsent: Boolean = false,
        /**
         * The domains this app declares for App Links — `open.example.com` — and the only hosts
         * [handleLink] asks what a link means. Empty asks nothing: a tracker link carrying its click
         * id is still reported, and an App Link opens the app as it would without this SDK.
         *
         * A list the app already has, in its manifest's intent filters. Asking only these hosts
         * matters because another app can hand this one an intent carrying any URL.
         */
        linkHosts: List<String> = emptyList(),
    ) {
        if (this.writeKey != null) return
        /*
         * https, or plain http to a local development server and nothing else (`BackendUrl`). Refused
         * rather than thrown: an SDK that crashes the app it ships in over a configuration value is
         * worse than one that stays off and says why.
         */
        if (!BackendUrl.allows(backendUrl)) {
            TreebarsLogger.warn(
                "initialize refused: $backendUrl is not https. Plain http is accepted only for a local stack " +
                    "(localhost, 10.0.2.2, a .local name or a private address); nothing will be recorded or sent.",
            )
            return
        }
        this.linkHosts = linkHosts.map(LinkResolve::normalizeHost).filter { it.isNotEmpty() }.toSet()

        // Holding the Activity would leak it; the SDK outlives any single screen.
        appContext = context.applicationContext
        // The screen in front, weakly, for the in-app button that asks for push permission.
        (appContext as? android.app.Application)?.registerActivityLifecycleCallbacks(TreebarsPush.activityTracker)
        this.writeKey = writeKey
        this.env = env
        this.autoTrackLifecycle = autoTrackLifecycle
        this.autoTrackSessions = autoTrackSessions
        // Grant-only: a [setAcquisitionConsent] made before this call must not be undone by a
        // parameter nobody passed. Withdrawing is the setter's job alone.
        if (acquisitionConsent) this.acquisitionConsent = true
        TreebarsLogger.debug = debug

        val prefs = appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        // An answer given before this call is kept and stored; otherwise an earlier launch's is read back.
        val answer = answerBeforeInit
        if (answer == null) {
            optedOut = prefs.getBoolean(KEY_OPTED_OUT, false)
        } else {
            optedOut = answer
            val editor = prefs.edit()
            if (answer) editor.putBoolean(KEY_OPTED_OUT, true) else editor.remove(KEY_OPTED_OUT)
            editor.apply()
        }
        adopt.applyTo(prefs)
        /*
         * The device's id and secret, resolved before anything asks: the one on file, else the pair a
         * wrapper handed down, else a new one (`DeviceIdentityStore`, outside every backup). And any
         * copies an earlier SDK version kept in these preferences are removed: they are what a backup
         * would carry to another phone, and nothing reads them.
         */
        prefs.edit().remove("device_id").remove("fetch_secret").apply()
        deviceIdentity(adopt.identity())
        sdkNameOverride = adopt.sdkName?.takeIf { it.isNotEmpty() }
        /*
         * What another write key left — its unsent events, its sealed batches, the session whose
         * `session_end` the next touch would send — dropped before the idle read, the session
         * manager, the queue or the uploader below can read it, so none of it is sent into this
         * key's project (`WriteKeyStamp`). The in-app and notification stores are emptied once they
         * exist, further down.
         */
        val keyChanged = WriteKeyStamp.claim(prefs, appContext.filesDir, writeKey)
        if (keyChanged) {
            TreebarsLogger.log("the write key changed: what the previous key left unsent, its session and its messages were dropped")
        }
        /*
         * How long this app had been idle, read BEFORE the session manager exists.
         *
         * `SessionManager` stamps `session_last_activity_at` to now the moment it resolves a session,
         * so one line later this number is zero and every re-engagement looks like somebody who was
         * using the app already. Read here, once, and kept for the life of the launch — which is the
         * right scope anyway: the question a return answers is how long they had been away before
         * this launch brought them back, and a link that opens the app IS the launch.
         *
         * Zero for a first-ever launch, which reads as "not idle" and refuses. Correct: that person
         * is installing, not returning, and the install path already credits the link.
         */
        idleAtLaunchMs = prefs.getLong(TreebarsConstants.KEY_SESSION_LAST_ACTIVITY_AT, 0L)
            .let { if (it <= 0L) 0L else (System.currentTimeMillis() - it).coerceAtLeast(0L) }
        sessions = SessionManager(prefs)
        primeFirstSeen(prefs)
        deferredDeepLink = DeferredDeepLink(prefs)
        acquisition = AcquisitionCapture(
            prefs,
            PlayReferrerSource(appContext),
            send = { properties -> record(EVENT_INSTALL_REFERRER, properties) },
            // Written down first, then offered. A listener registered a moment later still gets it,
            // and one registered a launch later still gets it — see `DeferredDeepLink`.
            carried = { path ->
                deferredDeepLink.remember(path)
                deliverDeferredDeepLink()
            },
        )

        /*
         * Who this install was signed in as, read back before anything asks the server.
         *
         * Without it `userId` would be null on every cold start until the app called [identify]
         * again — and in-app messages and the notification centre, which are read for the
         * signed-in person, would be empty until then.
         *
         * Read here rather than in the coroutine below, because [syncInApp] is launched
         * from it and a suspending read would race the request it exists to inform.
         */
        userId = prefs.getString(TreebarsConstants.KEY_SIGNED_IN_USER, null)
        // And the signature that proves it, for the same reason: a live environment refuses the id alone.
        userSignature = userId?.let { prefs.getString(TreebarsConstants.KEY_SIGNED_IN_USER_SIGNATURE, null) }

        /*
         * An install that starts opted out drops what an earlier launch left unsent, before the queue
         * and the uploader read it: an opt-out given before this call had nothing yet to drop it from,
         * and a later [optIn] would otherwise send events recorded before the "no".
         */
        if (optedOut) {
            EventQueue.forget(appContext.filesDir)
            UploaderStore(appContext.filesDir).save(UploaderState())
        }
        queue = EventQueue(appContext.filesDir)
        /*
         * Before the client, because the sync paths read `client` and then `triggers`: built the
         * other way round, a sync started from another thread in between would reach a lateinit
         * that is not set yet. The fetch reads `client` when it runs, not when it is built.
         */
        triggers = TriggerEvents(
            store = TriggerStore(appContext.filesDir),
            fetch = {
                if (optedOut) null
                else kotlinx.coroutines.withContext(Dispatchers.IO) { client?.getTriggerEvents(deviceId()) }
            },
        )
        client = BackendClient(backendUrl, writeKey, deviceSecret = { fetchSecret() })
        // The same directory as the queue, so clearing app data takes a pending batch with the
        // events it came from rather than leaving one to be sent by an install that forgot them.
        uploader = EventUploader(
            queue = queue,
            transport = client!!,
            store = UploaderStore(appContext.filesDir),
            writeKey = writeKey,
            scope = scope,
            triggers = triggers,
            paused = { optedOut },
        )

        inAppStore = InAppStore(appContext, PREFS_NAME)
        notificationStore = NotificationStore(appContext, PREFS_NAME)
        // The cache directory, which the system may empty when space is short: a file it took is fetched again.
        assetCache = InAppAssetCache(File(appContext.cacheDir, ASSET_CACHE_DIR)).also { InAppPictures.assets = it }
        // Fetched under the previous key: never drawn, reported or listed under this one.
        if (keyChanged) {
            inAppStore?.reset()
            notificationStore?.reset()
        }

        startAutoFlush(flushIntervalMs)
        if (autoTrackLifecycle) observeLifecycle()
        if (inAppPollIntervalMs > 0) startInAppPoll(inAppPollIntervalMs)

        // Anything left over from the previous process goes out immediately.
        scope.launch {
            if (autoTrackLifecycle) {
                foregroundedAt = System.currentTimeMillis()
                val opened = mapOf("is_first_launch" to firstLaunch)
                val snapshot = deviceSnapshot()
                record(EVENT_APP_OPEN, opened, snapshot = snapshot)
                /*
                 * Offered to in-app as the iOS SDK offers it. `record` never reaches the matcher — only
                 * `track` does — so without this a message shown "when the app is opened" would appear
                 * only when a new session opened, and never on a relaunch inside the thirty-minute
                 * window. With no renderer yet (React Native mounts its host later) the trigger is held
                 * and replayed when one attaches, as `session_start` is.
                 */
                considerInApp(EVENT_APP_OPEN, opened, eventDimensions(snapshot.device, snapshot.screen, sdkName()))
            }
            reportDeviceContext()
            uploader.flush()
            // So a message queued while the app was closed is in hand before the first
            // screen finishes drawing.
            syncInApp()
            // And a launch trigger that matched an empty store is answered by what the sync brought.
            replayUndrawnTriggers()
        }
        // A push tapped or swiped while the process was dead, before this call. After `app_open` is queued
        // would be the natural order, but `track` launches its own coroutine either way; what matters is that the
        // receipt is sent at all, and that a `push_click` message sees it — held for a renderer if none is attached.
        for ((event, properties) in PendingPushReceipts.drain(appContext)) track(event, properties)
        /*
         * Its own coroutine rather than a step in the one above, because the read binds to the
         * Play Store and may wait up to its ten-second bound — and nothing on the way up should
         * wait on it: not the first upload, and not the in-app sync behind that. It flushes
         * for itself when it has something to send.
         */
        scope.launch { settleAcquisition() }
        /*
         * A path read on an earlier launch, for an app that registered its listener before this
         * call. The referrer is read once per install, so nothing else would ever offer it again —
         * `carried` covers only the launch that reads it, and this covers every launch after.
         */
        deliverDeferredDeepLink()
        TreebarsLogger.log("Initialized")
    }

    /**
     * Report that a link opened this app, so a tracker link that brings somebody back is credited
     * as a return.
     *
     * Call it wherever the app already handles deep links — `onCreate` for a cold start and
     * `onNewIntent` for a warm one, with `intent.data.toString()`. Anything that is not a Treebars
     * tracker link is ignored, so there is no need to test for that first.
     *
     * **An App Link on one of the app's `linkHosts` is asked about.** Android opens the app holding
     * only the link's address — `https://open.example.com/summer-sale` — with no click id and no path,
     * so the core asks that address what it means, reports the return with the click id it gets back,
     * and hands [onPath] the link's deep-link path to route on, if it is a path inside the app. Any
     * other URL — another host, or one given by another app's intent — is not asked, answers [onPath]
     * with null, and the app routes it as it always did. [onPath] runs on the main thread, once.
     *
     * **A return is not an install, and this never becomes one.** The install was decided once, when
     * the app first arrived; the server keeps that decision, does not touch the person's acquisition
     * source, and emits a separate `reengagement_attributed`. Reporting a link is safe on every
     * launch for that reason.
     */
    @JvmStatic
    @JvmOverloads
    fun handleLink(url: String?, onPath: ((String?) -> Unit)? = null) {
        val answer: (String?) -> Unit = { path ->
            onPath?.let { listener -> mainHandler.post { runCatching { listener(path) } } }
        }
        if (writeKey == null) {
            TreebarsLogger.log("handleLink before initialize; ignored")
            answer(null)
            return
        }
        // Opted out: the link is neither reported nor asked about.
        if (optedOut) {
            answer(null)
            return
        }
        val clickId = clickIdFrom(url)
        if (clickId != null) {
            reportLinkOpened(clickId)
            answer(null)
            return
        }
        val address = LinkResolve.candidate(url, linkHosts)
        if (address == null) {
            if (linkHosts.isEmpty()) TreebarsLogger.log("handleLink: initialize was given no linkHosts, so no App Link is asked about")
            return answer(null)
        }
        scope.launch {
            val resolved = kotlinx.coroutines.withContext(Dispatchers.IO) { LinkResolve.ask(address) }
            resolved?.let { reportLinkOpened(it.clickId) }
            answer(resolved?.deepLinkPath)
        }
    }

    /*
     * `idle_seconds` and not a verdict. The gap is a fact only the device holds; whether it makes
     * this a re-engagement is one rule, server side, exactly as the referrer's encoding is.
     */
    private fun reportLinkOpened(clickId: String) {
        track(
            TreebarsConstants.LINK_OPENED_EVENT,
            mapOf(
                "click_id" to clickId,
                "idle_seconds" to idleAtLaunchMs / 1000L,
            ),
        )
    }

    /**
     * The Treebars click id out of a URL, or null for anything that is not a Treebars tracker link.
     *
     * Parsed with `Uri` rather than by hand because a link arrives with whatever the OS gives it —
     * fragments, encoded characters, a custom scheme — and a substring search for the parameter name
     * would match it inside a path or another parameter's value.
     */
    private fun clickIdFrom(url: String?): String? {
        val raw = url?.takeIf { it.isNotBlank() } ?: return null
        return runCatching {
            Uri.parse(raw).getQueryParameter(TreebarsConstants.ACQUISITION_CLICK_ID_PARAM)
        }.getOrNull()?.takeIf { it.isNotBlank() }
    }

    /**
     * Where the link that brought somebody here wanted them to land, after the install.
     *
     * Deferred deep linking, and the half of it the app owns. A tap on a tracker link with a
     * deep-link path sends the person to the Play Store; Play carries the path through the
     * install; this hands it over on the first launch after that, as a path like `/sale/summer`
     * for the app to route on however it routes on any other link.
     *
     * **Called at most once per install, ever**, and only while the install is younger than a day.
     * Both are deliberate: without the first, every launch would reopen the sale somebody bought
     * from three weeks ago, and without the second, adding this listener in a later app version
     * would throw the whole installed base into that sale on release day.
     *
     * Register it wherever the app handles its ordinary deep links, in `onCreate`. Order does not
     * matter — a path that arrived before this call is delivered by it, and one that arrives after
     * is delivered when it does. The listener runs on the main thread, and a throw from it is
     * caught rather than passed on. Null removes the listener; a path not yet delivered waits for
     * the next one.
     *
     * **Android only.** iPhone has no route that carries a destination through an install; Apple's
     * AdServices answer carries none. Calling this on other platforms is not an error, it simply
     * never fires.
     */
    @JvmStatic
    fun onDeferredDeepLink(listener: ((String) -> Unit)?) {
        deepLinkListener = listener
        // Null clears it, which is what a React Native screen unmounting needs. Nothing is lost:
        // the path is only taken when somebody is listening, so it waits for the next one.
        if (listener != null && writeKey != null) deliverDeferredDeepLink()
    }

    /**
     * Hand over whatever is owed, if anybody is listening.
     *
     * Both callers race and neither ordering is wrong — the referrer read finishes when the Play
     * service answers, the app registers when it reaches that line — so both call this and the
     * store decides. Taking is what clears it, so two calls cannot deliver twice.
     */
    private fun deliverDeferredDeepLink() {
        val listener = deepLinkListener ?: return
        val installedAt = firstSeenAt?.let { Iso8601.parseOrNull(it) }
        val path = deferredDeepLink.take(installedAt, System.currentTimeMillis()) ?: return
        mainHandler.post {
            // The host app's code, so it is theirs to get wrong without taking the SDK with it.
            runCatching { listener(path) }
                .onFailure { TreebarsLogger.log("Deferred deep link listener threw: ${it.message}") }
        }
        TreebarsLogger.log("Deferred deep link delivered: $path")
    }

    /**
     * Grants or withdraws consent to read how this install arrived. See `acquisitionConsent`
     * on [initialize], which is where an app that already knows the answer should give it.
     *
     * Withdrawing stops a read that has not happened; it cannot recall a referrer already
     * sent, which is an erasure request's job rather than this switch's.
     */
    @JvmStatic
    fun setAcquisitionConsent(granted: Boolean) {
        acquisitionConsent = granted
        if (granted && writeKey != null) scope.launch { settleAcquisition() }
    }

    private suspend fun settleAcquisition() {
        runCatching {
            if (acquisition.settle(acquisitionConsent)) uploader.flush()
        }.onFailure { TreebarsLogger.log("Install referrer read failed: ${it.message}") }
    }

    /**
     * Reads — or, on the very first launch, mints — when this install was first seen.
     *
     * Two callers want the same fact from opposite directions. `app_open` wants the
     * boolean, and the user profile wants the timestamp, which is the one date about a
     * person the SDK can state and the host app usually cannot.
     */
    private fun primeFirstSeen(prefs: android.content.SharedPreferences) {
        val existing = prefs.getString(TreebarsConstants.KEY_FIRST_SEEN_AT, null)
        if (existing != null) {
            firstSeenAt = existing
            firstLaunch = false
            return
        }

        val now = Iso8601.now()
        /*
         * The install referrer is owed from this moment, and only from this one: written in the
         * same edit as `first_seen_at`, so the two cannot disagree about whether this install is
         * new. An install that already had `first_seen_at` never gets the latch, which is what
         * keeps an app update from reporting every existing install at once.
         */
        prefs.edit()
            .putString(TreebarsConstants.KEY_FIRST_SEEN_AT, now)
            .putBoolean(TreebarsConstants.KEY_ACQUISITION_PENDING, true)
            .apply()
        firstSeenAt = now
        firstLaunch = true
    }

    /**
     * A notification permission that moved since this device last said, reported now — and the device re-stated with it,
     * so its recorded push permission moves too. From `TreebarsPush.activityTracker` on every resume.
     */
    internal fun notePermissionChange() {
        if (writeKey == null || !::appContext.isInitialized) return
        val changed = runCatching { DeviceInfo.pendingPermissionChange(appContext) }.getOrNull() ?: return
        track("notification_permission_changed", mapOf("from" to changed.first, "to" to changed.second))
        reportDeviceContext()
    }

    /**
     * Emits `device_context` when this device's context differs from the last reported one.
     *
     * A reserved event rather than a bespoke endpoint, so it inherits the batching, retry
     * and on-disk queue every other event gets, and costs no cold-start round trip. The
     * hash check is what keeps this rare: after the first launch a device normally reports
     * nothing until the app or OS is upgraded.
     */
    private fun reportDeviceContext(force: Boolean = false) {
        runCatching {
            /*
             * Before the hash gate, not after it, because the two answer different
             * questions. The gate asks whether this device's description is already on
             * file, and it can be true while a permission flipped and flipped back inside
             * one TTL window. It also returns early, so anything below it is skipped on
             * the common path. A transition happened at a moment in time; it is not
             * derivable from the state that follows it.
             */
            DeviceInfo.pendingPermissionChange(appContext)?.let { (from, to) ->
                track("notification_permission_changed", mapOf("from" to from, "to" to to))
            }

            // Not while opted out: the report would be dropped, and remembering it as made would
            // keep the device from describing itself for a week after [optIn].
            if (optedOut) return

            val context = DeviceInfo.context(appContext)
            val hash = DeviceInfo.hashContext(context)
            // `force` skips the hash gate. Its callers are answering a server that asked this
            // device to report itself (`claim_required`), and waiting out the seven-day TTL would
            // leave in-app and the notification centre empty for a week.
            if (!force && !DeviceInfo.shouldReportContext(appContext, hash)) return

            track(
                "device_context",
                context + mapOf("context_hash" to hash, "fetch_secret" to fetchSecret()),
            )
            // After the event is on the queue, never before it: a report that failed to enqueue
            // must not suppress the next seven days' worth without ever having been made.
            DeviceInfo.rememberReportedContext(appContext, hash)
        }.onFailure {
            // Never allowed to break initialize(). A missing device row costs a targeting
            // dimension; a throw here would cost the integrator every event in the session.
            TreebarsLogger.log("Device context report failed: $it")
        }
    }

    /*
     * The public members of this object are `@JvmStatic`, so Java calls them as `Treebars.flush()`
     * rather than through `Treebars.INSTANCE`. The nested interfaces below carry neither that nor
     * `@JvmOverloads`: both are illegal on an interface.
     */
    /**
     * How the host app draws a standard in-app message itself, in place of this SDK's own renderer.
     *
     * A callback rather than a View this SDK inflates: the SDK decides *which* message and *when*, and the app decides
     * what it looks like. Optional: with none registered, this SDK draws a standard body itself from the message's
     * render plan. Registering one is the override, and the SDK then draws no standard body of its own; a markup (HTML)
     * body is drawn by the SDK's WebView host either way.
     *
     * [show] is called on the main thread. Call `onClick` when the person presses a button and `onDismiss` when they
     * close the message: the SDK records both, and a button that ends the message frees the screen for the next one.
     */
    fun interface InAppRenderer {
        fun show(
            message: InAppMessage,
            tokens: InAppTokens?,
            onClick: (InAppButton) -> Unit,
            onDismiss: () -> Unit,
        )
    }

    /**
     * A renderer that can say whether what it draws would appear, implemented beside [InAppRenderer].
     *
     * Asked on the main thread immediately before each presentation, and nothing is recorded or spent when it says
     * no: the trigger is held and answered on the next Activity resume. A separate interface rather than a default
     * method on the renderer, because a Java lambda cannot implement an interface with two methods. For a renderer that
     * draws somewhere other than the Activity in front — the React Native bridge's Modal draws into the React context's
     * current Activity, which can be null while one is on screen, and would then draw nothing.
     */
    fun interface InAppSurfaceCheck {
        fun canPresent(): Boolean
    }

    /**
     * The SDK's own engagement reports, which must never trigger another message: every `in_app_` name. A prefix rather
     * than a list, so a new report is covered without a change here; a message's own `trackEvent` may not use the prefix.
     */
    private fun isInAppReport(eventName: String): Boolean = eventName.startsWith("in_app_")


    private var inAppStore: InAppStore? = null

    /**
     * The files the held messages load, fetched after each sync and kept by hash: what a markup body is drawn from with
     * its files inlined, and what a standard body's picture is read from when it is here.
     */
    private var assetCache: InAppAssetCache? = null
    private var inAppRenderer: InAppRenderer? = null
    /** The last renderer attached, kept across a detach so re-attaching the same one can be told from a new host. */
    private var lastInAppRenderer: java.lang.ref.WeakReference<InAppRenderer>? = null
    private var inAppEnabled = true

    /** The app's in-app contexts and listeners, and a message waiting out its delay. */
    @Volatile private var appContexts: Set<String> = emptySet()
    @Volatile private var selfHandledListener: SelfHandledListener? = null
    @Volatile private var clickActionListener: ClickActionListener? = null
    private val lifeCycleListeners = java.util.concurrent.CopyOnWriteArraySet<InAppLifeCycleListener>()
    @Volatile private var delayedDelivery: String? = null
    /** The HTML message on screen, drawn by this SDK, or null. Main thread only. */
    private var htmlHost: InAppHtmlHost? = null
    /** The standard message on screen, drawn by this SDK from its plan, or null. Main thread only. */
    private var nativeHost: InAppNativeHost? = null
    /**
     * The nudges on screen: their slots, claimed off the main thread, and their hosts, on it; and
     * where the app last said nudges may appear. A slot of their own beside [presentation], so a modal may be drawn over
     * nudges and neither waits for the other.
     */
    private val nudgeSlots = NudgeSlots(TreebarsBridge.NUDGE_MAX_ON_SCREEN)
    private val nudgeHosts = mutableMapOf<String, InAppHtmlHost>()
    @Volatile private var nudgePlace: NudgePlace? = null
    /** Whether this process has drawn an HTML message: the first one pays for the WebView's start (`cold`). */
    private var htmlDrawnInProcess = false
    @Volatile private var webViewCustomizer: ((android.webkit.WebView) -> Unit)? = null

    /**
     * Registers the app's own renderer for standard in-app messages, or null to have this SDK draw them. See
     * [InAppRenderer]. Attaching one also answers a trigger that fired before anything could draw it.
     */
    @JvmStatic
    fun setInAppRenderer(renderer: InAppRenderer?) {
        inAppRenderer = renderer
        TreebarsLogger.log(
            if (renderer == null) "in-app: renderer detached"
            else "in-app: renderer attached (${if (renderer === lastInAppRenderer?.get()) "the same one again" else "a new one"})",
        )
        /*
         * A NEW renderer is a host that has just mounted, so whatever it was showing went with the view that drew it.
         * The same one again is not: the React Native bridge detaches and re-attaches its one renderer whenever the JS
         * host unmounts and mounts — an Activity rebuilt under a live React context does exactly that — and hands its
         * live presentation back to the new host. Releasing the screen then would let the next event draw a second
         * message over the first.
         */
        if (renderer != null && renderer !== lastInAppRenderer?.get()) presentation.releaseUnpinned()
        // Weakly: a React Native module that detached on `invalidate` must not be kept alive, with its React
        // context, by the reference that only exists to recognise it.
        if (renderer != null) lastInAppRenderer = java.lang.ref.WeakReference(renderer)
        // Attaching one is the moment a trigger that had nowhere to go can finally be answered.
        if (renderer != null) replayUndrawnTriggers()
    }

    /**
     * Answer a trigger that fired before anything could draw. Once.
     *
     * Deliberately not a queue of every missed trigger: `allows` and the frequency policy are
     * still the gate, and replaying a backlog would spend a day's allowance in one launch.
     *
     * Something can always draw — a markup body in the SDK's WebView host, a standard one with the app's renderer or
     * the SDK's own — so the only thing a held trigger waits for is a screen.
     */
    private fun replayUndrawnTriggers() {
        val store = inAppStore ?: return
        if (synchronized(undrawnTriggers) { undrawnTriggers.isEmpty() }) return

        /*
         * Taken and cleared before replaying, not after: `drawInApp` re-adds a trigger if the
         * renderer has gone again, and iterating the map it is writing to is a
         * `ConcurrentModificationException` on the launch path.
         */
        val pending = synchronized(undrawnTriggers) {
            LinkedHashMap(undrawnTriggers).also { undrawnTriggers.clear() }
        }

        for ((eventName, held) in pending) {
            TreebarsLogger.log("in-app: replaying held '$eventName'")
            // Stop at the first message drawn, for the same reason the loop inside does.
            if (drawInApp(eventName, held.properties, held.dimensions, store)) return
        }
    }

    /**
     * An Activity resumed, from `TreebarsPush.activityTracker`: the moment a trigger held for want of a screen can be
     * answered. Posted rather than run in the callback, because the app's callbacks are dispatched from inside
     * `Activity.onResume` before the host's own resume work — React Native sets its current Activity after — and the
     * renderer is asked whether it can draw.
     */
    internal fun noteSurfaceResumed() {
        if (writeKey == null || synchronized(undrawnTriggers) { undrawnTriggers.isEmpty() }) return
        mainHandler.post { replayUndrawnTriggers() }
    }

    /**
     * Whether a presentation handed over now would appear: an Activity resumed, and the renderer — when it
     * can say — able to attach. A renderer that throws is taken at its word as unable.
     */
    private fun inAppSurfaceReady(renderer: InAppRenderer): Boolean {
        if (!TreebarsPush.hasResumedActivity()) return false
        val check = renderer as? InAppSurfaceCheck ?: return true
        return runCatching { check.canPresent() }.getOrDefault(false)
    }

    /**
     * Keep a trigger to answer once something can draw it. Bounded, because this is only ever a launch's worth of
     * events and an unbounded map keyed on event name would grow with a custom vocabulary.
     */
    private fun holdTrigger(eventName: String, properties: Map<String, Any?>, dimensions: Map<String, Any?>?, why: String) {
        if (isInAppReport(eventName)) return
        synchronized(undrawnTriggers) {
            if (undrawnTriggers.size >= 16 || undrawnTriggers.containsKey(eventName)) return
            undrawnTriggers[eventName] = HeldTrigger(properties, dimensions)
        }
        TreebarsLogger.log("in-app: held '$eventName', $why")
    }

    /*
     * The app's in-app API. The names follow the ones engagement SDKs commonly use on Android, so an app moving from
     * another keeps its call sites.
     */

    /**
     * Where somebody is in the app, in its own words: a message naming contexts shows only while one of them is set.
     * Replaces the set; [resetInAppContext] clears it.
     */
    @JvmStatic
    fun setInAppContext(contexts: Set<String>) {
        appContexts = contexts.filter { it.isNotEmpty() }.toSet()
    }

    /** Clears the contexts, so a message naming any is not shown until they are set again. */
    @JvmStatic
    fun resetInAppContext() {
        appContexts = emptySet()
    }

    /**
     * Every press in a message, after it is recorded, and the only place a `custom` button's keys arrive. Return true
     * when the app handled it. Null removes the listener.
     */
    @JvmStatic
    fun setClickActionListener(listener: ClickActionListener?) {
        clickActionListener = listener
    }

    /** Told when a message is shown and when it goes away. */
    @JvmStatic
    fun addInAppLifeCycleListener(listener: InAppLifeCycleListener) {
        lifeCycleListeners.add(listener)
    }

    /** Stops telling a listener added with [addInAppLifeCycleListener]. */
    @JvmStatic
    fun removeInAppLifeCycleListener(listener: InAppLifeCycleListener) {
        lifeCycleListeners.remove(listener)
    }

    private fun notifyShown(message: InAppMessage) = lifeCycleListeners.forEach { listener ->
        runCatching { listener.onShown(message) }.onFailure { TreebarsLogger.log("in-app: lifecycle listener threw: $it") }
    }

    private fun notifyDismissed(message: InAppMessage) = lifeCycleListeners.forEach { listener ->
        runCatching { listener.onDismiss(message) }.onFailure { TreebarsLogger.log("in-app: lifecycle listener threw: $it") }
    }

    /**
     * A message marked self-handled goes here instead of the renderer: the app draws it, and reports
     * [selfHandledShown], [selfHandledClicked] and [selfHandledDismissed]. Without a listener it is drawn like any
     * other.
     */
    @JvmStatic
    fun setSelfHandledListener(listener: SelfHandledListener?) {
        selfHandledListener = listener
    }

    /**
     * The self-handled message this device may show now, on the main thread — or null. Eligible means: marked
     * self-handled, allowed by the caps and the contexts, and triggered by nothing narrower than now or this screen.
     */
    @JvmStatic
    fun getSelfHandledInApp(context: Context, listener: SelfHandledListener) {
        val first = eligibleSelfHandled().firstOrNull()
        mainHandler.post { listener.onSelfHandledAvailable(first) }
    }

    /** Every self-handled message this device may show now. */
    @JvmStatic
    fun getSelfHandledInApps(context: Context, listener: SelfHandledListListener) {
        val all = eligibleSelfHandled()
        mainHandler.post { listener.onSelfHandledAvailable(all) }
    }

    private fun eligibleSelfHandled(): List<InAppMessage> {
        val store = inAppStore ?: return emptyList()
        if (!inAppEnabled) return emptyList()
        return store.list().filter { message ->
            val content = message.content ?: return@filter false
            content.display?.selfHandled == true &&
                content.surface != "inbox" &&
                inAppBlockedBy(message, content, store) == null &&
                when (content.trigger.kind) {
                    "immediate", "session_start" -> true
                    "screen_view" -> content.trigger.screenName == currentScreen
                    else -> false
                }
        }
    }

    /** The app drew a self-handled message: spent and reported as any display is. */
    @JvmStatic
    fun selfHandledShown(context: Context, message: InAppMessage) {
        val store = inAppStore ?: return
        store.recordDisplay(message, sessions.currentId())
        if (message.content?.trigger?.kind == "immediate") store.markDone(message.deliveryId)
        track("in_app_displayed", inAppReceipt(message))
        notifyShown(message)
    }

    /**
     * A self-handled message was pressed; [button] names what, when there is one — its index and label ride on the
     * click as any message's do. A call to action ends the message.
     */
    @JvmStatic
    @JvmOverloads
    fun selfHandledClicked(context: Context, message: InAppMessage, button: InAppButton? = null) {
        track("in_app_clicked", button?.let { inAppClickProperties(message, it) } ?: inAppReceipt(message))
        if (button != null && inAppClickEndsMessage(button)) inAppStore?.markDone(message.deliveryId)
        flush()
    }

    /** A self-handled message went away. */
    @JvmStatic
    fun selfHandledDismissed(context: Context, message: InAppMessage) {
        inAppStore?.markDone(message.deliveryId)
        track("in_app_dismissed", inAppReceipt(message))
        notifyDismissed(message)
    }

    /**
     * Nudges may appear on this screen, until the screen changes. Call `showNudge(context)` in `onStart` or `onResume`
     * of a screen that should have them; nudges never appear anywhere it was not. The nudges this screen brings are
     * asked for at once, as [showInApp] asks for modals.
     */
    @JvmStatic
    fun showNudge(context: Context) {
        if (!inAppEnabled) return
        /*
         * The Activity handed in, not the one in front: apps call it in `onStart`, where the new Activity is not
         * resumed yet and the resumed one is still the previous screen. The pass below finds nothing to draw on until
         * it resumes; [noteNudgeScreenResumed] asks again then.
         */
        nudgePlace = nudgePlaceFor(context as? android.app.Activity ?: TreebarsPush.resumedActivity(), currentScreen)
        nudgesAfterAnswer()
    }

    /** The screen in front, as [showNudge] names it: the Activity and the screen name the app last reported. */
    private fun currentNudgePlace(): NudgePlace = nudgePlaceFor(TreebarsPush.resumedActivity(), currentScreen)

    /**
     * The nudges the screen in front brings, asked for again: after [showNudge], after a sync — the one at launch
     * answers after the screen allowed nudges, and nothing else would ask again until some later event — and when the
     * Activity [showNudge] named resumes. Nothing when nudges are not allowed where the app is.
     */
    private fun nudgesAfterAnswer() {
        if (!inAppEnabled) return
        val store = inAppStore ?: return
        if (nudgePlace == null || nudgePlace != currentNudgePlace()) return
        val screen = currentScreen
        scope.launch { drawNudges(EVENT_SCREEN_VIEW, if (screen != null) mapOf("screen_name" to screen) else emptyMap(), null, store) }
    }

    /** An Activity resumed, from `TreebarsPush.activityTracker`: the one [showNudge] named in `onStart` can draw now. */
    internal fun noteNudgeScreenResumed() {
        if (writeKey == null) return
        mainHandler.post { nudgesAfterAnswer() }
    }

    /**
     * Evaluate the messages for this screen now: an `immediate` message, or one triggered by the screen in front, is
     * shown if the caps allow — as if the screen had just been reported. For a screen the app never reports, or a
     * moment it chooses.
     */
    @JvmStatic
    fun showInApp(context: Context) {
        if (!inAppEnabled) return
        val store = inAppStore ?: return
        val screen = currentScreen
        scope.launch { drawInApp(EVENT_SCREEN_VIEW, if (screen != null) mapOf("screen_name" to screen) else emptyMap(), null, store) }
    }

    /**
     * A form's answers, from the renderer that drew it: `in_app_form_submitted` with the answers, and — for a field
     * the form keeps as an address — `email` or `phone` beside them, which Treebars attaches to the person.
     */
    @JvmStatic
    fun submitInAppForm(message: InAppMessage, responses: Map<String, Any>) {
        val (kept, traits) = formKeeps(message.raw.optJSONObject("content")?.optJSONObject("in_app"), responses)
        if (traits.isNotEmpty()) setMessageTraits(traits)
        // Answered: the message is done on this device and the screen is free, as after a call to action.
        inAppStore?.markDone(message.deliveryId)
        presentation.releaseUnpinned()
        track(
            "in_app_form_submitted",
            inAppReceipt(message).apply {
                put("responses", responses)
                putAll(kept)
            },
        )
        flush()
    }

    /** The same, by delivery id, for a bridge that holds the id rather than the message. Unknown ids are ignored. */
    @JvmStatic
    fun submitInAppForm(deliveryId: String, responses: Map<String, Any>) {
        val message = inAppStore?.list()?.firstOrNull { it.deliveryId == deliveryId } ?: return
        submitInAppForm(message, responses)
    }

    /**
     * The in-app messages authored as inbox rows, for an app that draws a message centre. Data only: pinned cards first,
     * held cards left out. See [notifications] for the history of every message sent, push included.
     */
    @JvmStatic
    fun inbox(): List<InAppMessage> = inAppStore?.inbox() ?: emptyList()

    /** An inbox row came into view: `in_app_displayed`, the card's "viewed". Call it once per showing of the list. */
    @JvmStatic
    fun inboxMessageViewed(deliveryId: String) {
        track("in_app_displayed", inboxReceipt(deliveryId))
    }

    /** An inbox row was tapped: `in_app_clicked`, with where it went. The app does the going. */
    @JvmStatic
    @JvmOverloads
    fun inboxMessageClicked(deliveryId: String, destination: String? = null) {
        track("in_app_clicked", inboxReceipt(deliveryId).apply { destination?.let { put("destination", it) } })
        flush()
    }

    /** An inbox receipt names the campaign as an overlay's does, when the message is still held. */
    private fun inboxReceipt(deliveryId: String): MutableMap<String, Any?> =
        inAppStore?.list()?.firstOrNull { it.deliveryId == deliveryId }?.let(::inAppReceipt)
            ?: mutableMapOf(DELIVERY_ID_KEY to deliveryId)

    /**
     * Removes an inbox row. An inbox dismissal is the person's, not the handset's, so the row is
     * removed on every device they own. An overlay dismissal deliberately does not do that.
     */
    @JvmStatic
    fun dismissInboxMessage(deliveryId: String) {
        val receipt = inboxReceipt(deliveryId)
        inAppStore?.markDone(deliveryId)
        track("in_app_dismissed", receipt)
        flush()
    }

    private var notificationStore: NotificationStore? = null
    private var notificationWatchers = mutableMapOf<String, (NotificationPage) -> Unit>()
    /** Whatever `server_time` the last successful page carried. The mark-all watermark. */
    private var lastNotificationServerTime: String? = null

    private fun startInAppPoll(intervalMs: Long) {
        scope.launch {
            while (isActive) {
                delay(intervalMs)
                syncInApp()
            }
        }
    }

    /**
     * Fetches this device's in-app messages now.
     *
     * The SDK already fetches them at launch, at session start, when the app returns to the
     * foreground and on the `inAppPollIntervalMs` timer; call this when the app knows something
     * new is waiting. Returns at once. Never throws — nothing depends on in-app succeeding.
     */
    @JvmStatic
    fun syncInAppMessages() {
        scope.launch { syncInApp() }
    }

    private suspend fun syncInApp() {
        if (optedOut) return
        val transport = client ?: return
        /*
         * With in-app off ([disableInApps]) there is no queue to read — and a full sync marks every
         * pending message as fetched, a stage of the campaign's funnel, for a device that will never
         * draw one — so the sync still owed to the trigger list is the list alone. Turning in-app off
         * must never also turn triggers off.
         */
        if (!inAppEnabled) {
            triggers.refresh()
            return
        }
        val store = inAppStore ?: return

        // The answer carries the trigger list on every outcome, the refusals included, so the list
        // is told a sync is out: an upload answered with a new version meanwhile waits for this.
        triggers.beginSync()
        var list: TriggerList? = null
        // Before the request: a sign-out that lands while it is out makes its answer the previous person's.
        val asked = store.generation
        try {
            val response = transport.getInApp(deviceId(), fetchSecret(), userId, userSignature) ?: return
            list = TriggerList.fromJson(response.optJSONObject("trigger_events"))
            if (response.optBoolean("signature_required", false)) warnSignatureRequired()

            /*
             * The server asked this device to report itself. Waiting out the seven-day context TTL
             * would leave in-app empty until then, so it re-reports now, forced past the hash gate.
             */
            if (response.optBoolean("claim_required", false)) {
                reportDeviceContext(force = true)
                uploader.flush()
                return
            }

            fetchLargeBodies(response, transport, store)
            if (!store.accept(response, asked)) TreebarsLogger.log("in-app: dropped a sync asked for a previous sign-in")
            else {
                prefetchAssets(store)
                // Nudges queued since the screen allowed them: asked for now, not at some later event.
                nudgesAfterAnswer()
            }
        } finally {
            triggers.endSync(list)
        }
    }

    /**
     * Bodies over 64 KiB, which the sync hands over as `html_ref`: each fetched once from
     * `/v1/in-app/body`, checked against its SHA-256 and written into the answer before the store keeps it — or taken
     * from the copy this device already holds. One that never arrives is `asset_download` when it would be drawn.
     */
    private fun fetchLargeBodies(response: JSONObject, transport: BackendClient, store: InAppStore) {
        val messages = response.optJSONArray("messages") ?: return
        val held = store.list().associateBy { it.deliveryId }
        for (i in 0 until messages.length()) {
            val message = messages.optJSONObject(i) ?: continue
            val inApp = message.optJSONObject("content")?.optJSONObject("in_app") ?: continue
            val sha = inApp.optJSONObject("html_ref")?.optString("sha256")?.takeIf { it.isNotEmpty() } ?: continue
            if (inApp.optString("html").isNotEmpty()) continue
            val deliveryId = message.optString("delivery_id")
            val kept = held[deliveryId]?.content
            val body = if (kept?.html != null && kept.htmlRef == sha) kept.html
            else transport.getInAppBody(deviceId(), fetchSecret(), userId, userSignature, deliveryId)?.optString("html")?.takeIf { sha256Hex(it) == sha }
            if (body != null) inApp.put("html", body)
            else TreebarsLogger.log("in-app: the body of $deliveryId did not arrive, or did not match its hash")
        }
    }

    /**
     * The files every held message loads, fetched now and kept by hash, so a message drawn later
     * — offline, or a second after the app opens — has them. Off the sync's own path: the trigger list and the nudges
     * this sync answers do not wait for pictures.
     */
    private fun prefetchAssets(store: InAppStore) {
        val cache = assetCache ?: return
        val held = store.list().map { message -> InAppAssetManifest.from(message.raw.optJSONObject("assets")) to (message.content?.let(::drawsItself) == true) }
        if (held.none { it.first != null }) return
        scope.launch(Dispatchers.IO) { runCatching { cache.prefetch(held) }.onFailure { TreebarsLogger.log("in-app: prefetch failed: $it") } }
    }

    /**
     * A markup body's document with its files inlined, or null when it must not be drawn: a store file it names
     * is gone, or one it inlines could not be had. Blocking — disk, and the network for what the prefetch has not landed
     * yet — so never on the main thread.
     */
    private fun preparedMarkup(message: InAppMessage, html: String): String? {
        val manifest = InAppAssetManifest.from(message.raw.optJSONObject("assets"))
        val cache = assetCache ?: return if (manifest?.missing.isNullOrEmpty()) html else null
        return runCatching { cache.prepare(manifest, html) }.getOrNull()
    }

    private fun sha256Hex(text: String): String =
        java.security.MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

    /**
     * The notification centre: one page of it.
     *
     * Raw rows and a cursor; the app draws the list. Not the same thing as [inbox] — that
     * is the queue of in-app messages authored as rows, still actionable and still styled,
     * while this is the history of everything sent to this person, push included, keeping
     * what expiry and dismissal take out of that queue.
     *
     * Only the default first page (no [limit], no [cursor]) is cached. When the network cannot
     * be reached, a call without a [cursor] returns that cache, and a later page comes back empty
     * with the same cursor for the caller to retry. Empty while opted out.
     *
     * @param limit how many rows to return; null for the default page size.
     * @param cursor [NotificationPage.nextCursor] from the previous page; null for the first.
     * @param channels only rows sent on these channels; null for every channel.
     */
    @JvmStatic
    suspend fun notifications(
        limit: Int? = null,
        cursor: String? = null,
        channels: List<String>? = null,
    ): NotificationPage = notificationPage(limit, cursor, channels)

    /** The unread count, for a badge. One number, at the cost of the same round trip as a page. */
    @JvmStatic
    suspend fun unreadNotificationCount(): Int = notifications(limit = 1).unreadCount

    /** Marks one send read, on every device this person owns. */
    @JvmStatic
    fun markNotificationRead(groupId: String) {
        notificationStore?.noteRead(groupId)
        emitNotificationChange()
        scope.launch { writeNotificationState(read = listOf(groupId)) }
    }

    /**
     * A notification or card tapped in the centre: opened, and read with it — the campaign report's Opened for the
     * send, which a centre row cannot reach through a delivery id because it is never given one.
     */
    @JvmStatic
    fun markNotificationOpened(groupId: String) {
        notificationStore?.noteRead(groupId)
        emitNotificationChange()
        scope.launch { writeNotificationState(opened = listOf(groupId)) }
    }

    /**
     * Marks everything read, on every device this person owns.
     *
     * Sends the server's own `server_time` as a watermark rather than a list of ids: a list
     * cannot express somebody returning to nine hundred unread — a capped one leaves the
     * tail unread and the badge stuck. The server's time rather than the handset's, so a
     * fast clock cannot mark as read what has not been sent yet.
     */
    @JvmStatic
    fun markAllNotificationsRead() {
        scope.launch {
            notificationPage(limit = 1, cursor = null, channels = null)
            val through = lastNotificationServerTime ?: return@launch
            notificationStore?.noteReadThrough(through)
            emitNotificationChange()
            writeNotificationState(readThrough = through)
        }
    }

    /**
     * Removes one send from the centre, for this person rather than this handset.
     *
     * The same dismissal an inbox dismissal makes — so a message deleted here is also gone
     * from the in-app inbox, which is what pressing a bin means.
     */
    @JvmStatic
    fun dismissNotification(groupId: String) {
        notificationStore?.noteDismissed(groupId)
        emitNotificationChange()
        scope.launch { writeNotificationState(dismissed = listOf(groupId)) }
    }

    /**
     * [callback] is called whenever the centre changes — a fetch, a mark, a sign-out — with the
     * current first page.
     *
     * Returns its own unsubscribe. It exists because the alternative is a timer, and a
     * badge driven by one is a badge that is wrong for up to its interval.
     */
    @JvmStatic
    fun onNotificationsChange(callback: (NotificationPage) -> Unit): () -> Unit {
        val token = UUID.randomUUID().toString()
        notificationWatchers[token] = callback
        return { notificationWatchers.remove(token) }
    }

    /** One page, falling back to the cache when the network cannot be reached. */
    private suspend fun notificationPage(
        limit: Int?,
        cursor: String?,
        channels: List<String>?,
    ): NotificationPage {
        val empty = NotificationPage(emptyList(), 0, cursor, true)
        if (optedOut) return empty
        val store = notificationStore ?: return empty
        val transport = client ?: return empty

        // A cursored call has no cache to fall back to — deep pages are network-only,
        // because what a bell needs in a tunnel is its first screen — so it hands the
        // cursor back and the caller retries.
        val fallback = if (cursor != null) empty else store.cached() ?: empty
        // Before the request, so an answer for somebody who has since signed out is not shown as the next person's.
        val asked = store.generation

        /*
         * On Dispatchers.IO, like `identify` already is. `getNotifications` is a blocking
         * HttpURLConnection round trip, and this function is reached from `suspend` callers
         * running on Dispatchers.Default — a pool sized to the CPU count and shared with every
         * other piece of computation in the host app. Blocking one of those threads for the
         * length of a network request is how an unrelated coroutine somewhere else in the app
         * stalls, with nothing pointing back here.
         */
        val body = kotlinx.coroutines.withContext(Dispatchers.IO) {
            transport.getNotifications(
                deviceId(), fetchSecret(), userId, userSignature, limit, cursor, channels,
            )
        } ?: return fallback

        if (asked != store.generation) return store.cached() ?: empty
        if (body.optBoolean("signature_required", false)) warnSignatureRequired()

        if (body.optBoolean("claim_required", false)) {
            scope.launch {
                reportDeviceContext(force = true)
                uploader.flush()
            }
            return fallback
        }

        lastNotificationServerTime = body.optString("server_time").takeIf { it.isNotEmpty() }

        val serverRows = parseNotifications(body.optJSONArray("notifications") ?: JSONArray())
        val page = NotificationPage(
            notifications = store.overlay(serverRows),
            // Counted against the server's own rows, never the overlaid ones.
            unreadCount = store.overlayCount(body.optInt("unread_count", 0), serverRows),
            nextCursor = body.optString("next_cursor").takeIf { it.isNotEmpty() && it != "null" },
            fromCache = false,
        )

        /*
         * Only the DEFAULT first page is cached, and every clause of that matters.
         *
         * A cursored page is a scroll position rather than a screen somebody returns to. And
         * a page with an explicit [limit] is a probe — [unreadNotificationCount] and
         * [markAllNotificationsRead] both ask for one row, the latter only to learn the server's
         * clock. Caching a
         * one-row answer over the real first page leaves the unread arithmetic running
         * against a single row, and the badge then disagrees with the list beside it.
         */
        if (cursor == null && limit == null) {
            if (!store.accept(userId ?: deviceId(), page, asked)) return store.cached() ?: empty
            emitNotificationChange(page)
        }
        return page
    }

    /**
     * Sends the marks, then reports them for analytics.
     *
     * In that order, and both halves matter. The POST is what marks the rows, and it is
     * acknowledged. The events make "how many of our notifications get read" answerable, and
     * they ride the ordinary queue where a drop costs a data point rather than somebody's
     * unread badge.
     */
    private suspend fun writeNotificationState(
        read: List<String> = emptyList(),
        dismissed: List<String> = emptyList(),
        readThrough: String? = null,
        opened: List<String> = emptyList(),
    ) {
        if (optedOut) return
        val transport = client ?: return

        val payload = JSONObject().put("device_id", deviceId())
        userId?.let { payload.put("user_id", it) }
        if (read.isNotEmpty()) payload.put("read", JSONArray(read))
        if (dismissed.isNotEmpty()) payload.put("dismissed", JSONArray(dismissed))
        readThrough?.let { payload.put("read_through", it) }
        if (opened.isNotEmpty()) payload.put("opened", JSONArray(opened))

        // Null means the write did not land. The marks stay in the ledger, so the row still
        // reads as marked on this device and the next successful page reconciles.
        // Same reason as `notificationPage`: a blocking POST does not belong on Dispatchers.Default.
        val body = kotlinx.coroutines.withContext(Dispatchers.IO) {
            transport.postNotificationState(fetchSecret(), userSignature, payload)
        } ?: return
        // Refused, not written: a mark that did not land is not reported as one.
        if (body.optBoolean("signature_required", false)) {
            warnSignatureRequired()
            return
        }
        lastNotificationServerTime = body.optString("server_time").takeIf { it.isNotEmpty() }

        for (groupId in read + opened) {
            track(EVENT_NOTIFICATION_READ, mapOf("notification_group_id" to groupId))
        }
        for (groupId in dismissed) {
            track(EVENT_NOTIFICATION_DISMISSED, mapOf("notification_group_id" to groupId))
        }
        readThrough?.let { track(EVENT_NOTIFICATION_READ, mapOf("read_through" to it)) }
    }

    /**
     * Said out loud, and not only under debug: a missing signature is a setup step the integration
     * skipped, and what it costs — every sign-in unrecorded and every signed-in person's messages
     * withheld, silently — is exactly the kind of absence nobody goes looking for.
     */
    private fun warnSignatureRequired() {
        if (warnedSignature) return
        warnedSignature = true
        TreebarsLogger.warn(
            "This environment requires a signed identity, so sign-ins are not recorded and in-app messages " +
                "and notifications are withheld: pass the signature your backend computes to " +
                "identify(userId, attributes, signature).",
        )
    }

    private fun emitNotificationChange(page: NotificationPage? = null) {
        if (notificationWatchers.isEmpty()) return
        val next = page ?: notificationStore?.cached() ?: return
        for (watcher in notificationWatchers.values.toList()) watcher(next)
    }

    /**
     * Triggers that matched nothing because nothing could draw yet.
     *
     * `session_start` is recorded inside `initialize`, and a React Native host attaches its
     * renderer a few hundred milliseconds later — so without this the one trigger that fires
     * exactly once per launch would fire with nothing able to draw it, and a `session_start`
     * message could never be shown: nothing fires `session_start` twice.
     *
     * In order, deduplicated by name, and bounded. Not only the latest: a cold start fires
     * `session_start`, `app_open`, `screen_view`, `device_context`, `user_identified` and
     * `push_token_registered` within a few hundred milliseconds, and keeping only the last would
     * lose `session_start`, the one a message is most often waiting on, behind five others.
     *
     * Every touch is under its own lock. A launch holds triggers routinely — `app_foreground` on
     * the main thread at every `onStart`, before the Activity resumes, and `device_context` or
     * `user_identified` from a coroutine — while the resume's replay drains it on main and the
     * sync's on a background dispatcher. A plain map copied while another thread puts into it
     * throws `ConcurrentModificationException` on the launch path.
     */
    private val undrawnTriggers = LinkedHashMap<String, HeldTrigger>()

    /**
     * A held trigger keeps the dimensions its event was stamped with, so a replay after the screen or the network has
     * changed answers a dimension row from the values the stored event holds.
     */
    private class HeldTrigger(val properties: Map<String, Any?>, val dimensions: Map<String, Any?>?)

    /**
     * Whether a message is on screen, claimed under one lock ([PresentationSlot]).
     *
     * One at a time across every event, not only within one consideration: a launch fires six
     * events in a few hundred milliseconds, and without a shared slot three queued `immediate`
     * messages would be three displays of which the person saw one. The hold is a duration rather
     * than a flag the host clears, so a renderer that never reports back cannot hold the screen
     * for good.
     */
    private val presentation = PresentationSlot()

    /**
     * Show a queued message, if this event is what it was waiting for.
     *
     * The server settled eligibility before any of these were queued; what is decided here
     * is only *when*, which only the device can know for a screen view or a custom event.
     */
    private fun considerInApp(eventName: String, properties: Map<String, Any?>, dimensions: Map<String, Any?>?) {
        /*
         * Syncing happens whether or not anything can draw an overlay, and the order here
         * is load-bearing. An app that only draws an inbox — or only a notification centre
         * — has no renderer by design, and doing this below the renderer check would mean
         * it never fetched anything at all.
         *
         * And above the in-app switch, for a reason that is not in-app's: the sync carries the
         * trigger list, and a device that draws no messages still needs to know which of its events
         * to send at once. Nor does it depend on the poll — `inAppPollIntervalMs = 0`, which the
         * React Native bridge sets for `in_app_enabled: false`, stops only the timer.
         */
        if (eventName == EVENT_SESSION_START || eventName == EVENT_APP_FOREGROUND) {
            // Replayed after the fetch too, not only when a renderer arrives: the store can be
            // empty at `session_start` and hold the message a round trip later, which is the
            // same miss reached from the other side.
            scope.launch {
                syncInApp()
                replayUndrawnTriggers()
            }
        }

        if (!inAppEnabled) return
        val store = inAppStore ?: return
        drawInApp(eventName, properties, dimensions, store)
    }

    /**
     * The half that needs somewhere to draw. Split out so a replay does not re-sync.
     *
     * Returns whether a message was actually shown, which is what stops a replay after the
     * first draw — the loop below already refuses to stack two overlays, and a replay pass
     * must not get round that by calling it once per held trigger.
     */
    private fun drawInApp(
        eventName: String,
        properties: Map<String, Any?>,
        dimensions: Map<String, Any?>?,
        store: InAppStore,
    ): Boolean {
        // Nor held for a renderer: a trigger replayed later would be the same spend on a screen that has gone.
        if (isLeavingEvent(eventName)) return false
        /*
         * A self-handled message is the app's to draw: handed to its listener whether or not a renderer exists — an
         * app that draws only its own messages sets no renderer at all — and never to the renderer while a listener is
         * set. Nothing is spent here; the app's `selfHandledShown` is the display.
         */
        val selfHandled = selfHandledListener
        if (selfHandled != null && !isInAppReport(eventName)) {
            for (message in store.list().sortedByDescending { it.content?.display?.priority ?: 5 }) {
                val content = message.content ?: continue
                if (content.surface != "overlay" || content.display?.selfHandled != true) continue
                if (!inAppTriggerMatches(content.trigger, eventName, properties, currentScreen, dimensions)) continue
                if (inAppBlockedBy(message, content, store) != null) continue
                TreebarsLogger.log("in-app: ${message.deliveryId} is self-handled; handed to the app")
                mainHandler.post { runCatching { selfHandled.onSelfHandledAvailable(message) } }
                return true
            }
        }
        /*
         * No hold here for a missing app renderer: a markup body is this SDK's to draw, and so is a standard one when the
         * app registered no renderer, so the only thing left to wait for is a screen.
         */
        val renderer = inAppRenderer
        /*
         * Somewhere to draw, but nowhere for it to appear: no Activity in front — the app is in the
         * background, or initialising in `Application.onCreate` before one exists — or a renderer that says it cannot
         * attach. Held exactly as for a missing renderer, and answered on the next resume by the same replay, which
         * asks the caps, the trigger and the store again rather than trusting a message chosen minutes ago. Above the
         * clear below, or the trigger would be wiped before it was kept.
         */
        if (if (renderer != null) !inAppSurfaceReady(renderer) else !TreebarsPush.hasResumedActivity()) {
            holdTrigger(eventName, properties, dimensions, "no screen to draw on")
            return false
        }
        synchronized(undrawnTriggers) { undrawnTriggers.clear() }

        /*
         * Something is already on screen, and it has not been answered. Returning here leaves
         * the message in the store with nothing spent, so the next event after the person
         * deals with this one is its opportunity.
         */
        // Nudges first, in their own slot: a modal on screen holds back the next modal, not a nudge.
        if (!isInAppReport(eventName)) drawNudges(eventName, properties, dimensions, store)
        if (presentation.isHeld()) {
            TreebarsLogger.log("in-app: '$eventName' ignored, a message is still on screen")
            return false
        }

        // Never off the SDK's own reports: in_app_displayed goes through the same track() as
        // everything else, and a message triggered on "immediate" matches anything — so
        // without this, showing one message would show it again, forever.
        if (isInAppReport(eventName)) return false

        /*
         * Say why, for each candidate. An in-app that does not appear has half a dozen equally
         * plausible causes — wrong surface, an unmatched trigger, the frequency policy, an
         * expiry, a `done` entry from a dismissal — and a line each is what tells them apart
         * without reading preferences out of the device. Only under `debug`, and one line per
         * skipped message.
         */
        // Highest priority first; the list is newest first and the sort is stable, so that holds among equals.
        for (message in store.list().sortedByDescending { it.content?.display?.priority ?: 5 }) {
            val content = message.content ?: continue
            // An inbox message is a row in a list the app draws; nothing is shown over
            // anything, so there is no trigger to fire.
            if (content.surface != "overlay") continue
            // A nudge has its own pass, above, and its own slot.
            if (isNudge(message)) continue
            // The app's own, above, while it listens for them.
            if (content.display?.selfHandled == true && selfHandled != null) continue
            if (!inAppTriggerMatches(content.trigger, eventName, properties, currentScreen, dimensions)) {
                TreebarsLogger.log(
                    "in-app: ${message.deliveryId} trigger ${content.trigger.kind} " +
                        "does not match '$eventName'",
                )
                continue
            }
            // Already waiting out its delay: the trigger firing again is not a second message.
            if (delayedDelivery == message.deliveryId) return false
            val blocked = inAppBlockedBy(message, content, store)
            if (blocked != null) {
                TreebarsLogger.log("in-app: ${message.deliveryId} matched but is held back ($blocked)")
                if (blocked != "done") reportInAppFailure(message, blocked, store)
                continue
            }

            // A delay. Asked again when it is up — a cap may have been spent, or the context left, meanwhile.
            val delay = content.display?.takeIf { it.on == "delay" }?.delaySeconds ?: 0
            if (delay > 0) {
                if (delayedDelivery != null) return false
                delayedDelivery = message.deliveryId
                mainHandler.postDelayed({ presentDelayed(message, content, store) }, delay * 1000L)
                return true
            }

            // One at a time: two overlays at once is two messages nobody reads. False when another
            // consideration claimed the screen first; this message stays queued, unspent.
            val noSurface = { holdTrigger(eventName, properties, dimensions, "the screen went before the message could be drawn") }
            if (drawsItself(content)) return presentHtml(message, content, store, noSurface)
            // A standard body is the app's renderer's when it registered one, and the SDK's own plan's otherwise.
            val draw = renderer ?: return presentNative(message, store, noSurface)
            return presentInApp(message, content, draw, store, noSurface)
        }
        return false
    }

    /**
     * A delayed message whose delay is up, or which is waiting for the screen.
     *
     * A message whose delay ends while another holds the screen is not refused and dropped — which
     * for a `session_start + 10s` message would put it off to the next session. It waits for the
     * screen, looking again every [DELAYED_IN_APP_RETRY_MS], and asks the caps again each time
     * (`delayedInAppStep`): shown once the other message is answered or its hold lapses, or reported
     * as not shown when a cap closes on it meanwhile — the minimum gap, typically, since the other
     * message was just drawn. [delayedDelivery] stays set while it waits, so the trigger firing
     * again is still not a second message; [reset] clears it, and a waiting message whose person
     * signed out goes with it.
     */
    private fun presentDelayed(message: InAppMessage, content: InAppContent, store: InAppStore) {
        DelayedInAppLoop(
            schedule = { delayMs, tick -> mainHandler.postDelayed({ tick() }, delayMs) },
            stillWaiting = { delayedDelivery == message.deliveryId },
            blockedBy = { inAppBlockedBy(message, content, store) },
            // Always something: a markup body is the WebView host's and a standard one the app's renderer's or, with
            // none, the SDK's own. `no_renderer` is a drop this core cannot reach.
            hasRenderer = { true },
            // No screen to draw on waits as a taken one does: the message is shown once there is one. What the
            // core draws itself needs an Activity in front; the app's renderer is asked whether it can attach.
            screenHeld = {
                val renderer = inAppRenderer
                presentation.isHeld() ||
                    (if (drawsItself(content) || renderer == null) !TreebarsPush.hasResumedActivity() else !inAppSurfaceReady(renderer))
            },
            // Another consideration can still claim the slot between the look and the claim; then it waits again.
            present = {
                val again: () -> Unit = {
                    // The screen went between the look and the draw: wait for it again, unspent.
                    delayedDelivery = message.deliveryId
                    mainHandler.postDelayed({ presentDelayed(message, content, store) }, DELAYED_IN_APP_RETRY_MS)
                }
                if (drawsItself(content)) presentHtml(message, content, store, again)
                else inAppRenderer?.let { presentInApp(message, content, it, store, again) } ?: presentNative(message, store, again)
            },
            finish = { delayedDelivery = null },
            report = { reportInAppFailure(message, it, store) },
        ).tick()
    }

    /**
     * The nudges this event brings: only on the screen the app allowed them on ([showNudge]), each
     * matching one drawn at once, up to three, outside the channel's caps ([isNudge]) but inside every rule of its own. The
     * on-app moment (a delay) is not waited for: a nudge that has to wait is a modal.
     */
    private fun drawNudges(eventName: String, properties: Map<String, Any?>, dimensions: Map<String, Any?>?, store: InAppStore) {
        val place = nudgePlace ?: return
        if (place != currentNudgePlace()) return
        for (message in store.list().sortedByDescending { it.content?.display?.priority ?: 5 }) {
            if (!nudgeSlots.hasRoom()) return
            val content = message.content ?: continue
            if (content.surface != "overlay" || !isNudge(message) || !drawsItself(content)) continue
            if (nudgeSlots.holds(message.deliveryId)) continue
            if (!inAppTriggerMatches(content.trigger, eventName, properties, currentScreen, dimensions)) continue
            val blocked = inAppBlockedBy(message, content, store)
            if (blocked != null) {
                if (blocked != "done") reportInAppFailure(message, blocked, store)
                continue
            }
            presentNudge(message, content, store)
        }
    }

    /** Draws one nudge in its edge's column over the screen in front, which stays usable around it. */
    private fun presentNudge(message: InAppMessage, content: InAppContent, store: InAppStore) {
        if (!nudgeSlots.claim(message.deliveryId)) return
        scope.launch(Dispatchers.IO) {
            val prepared = content.html?.takeIf { it.isNotEmpty() }?.let { preparedMarkup(message, it) }
            mainHandler.post { drawNudge(message, content, store, prepared) }
        }
    }

    /** The nudge's drawing, on the main thread, with its document prepared ([preparedMarkup]). */
    private fun drawNudge(message: InAppMessage, content: InAppContent, store: InAppStore, prepared: String?) {
        val activity = TreebarsPush.resumedActivity()
        if (activity == null || content.html.isNullOrEmpty() || prepared == null) {
            nudgeSlots.release(message.deliveryId)
            // No body (a large one whose fetch never landed) or a file it needs: `asset_download`, never a hole.
            if (activity != null) reportInAppFailure(message, if (content.htmlRef != null || !content.html.isNullOrEmpty()) "asset_download" else "render_error", store)
            return
        }
        TreebarsLogger.log("in-app: drawing ${message.deliveryId} (nudge)")
        val started = android.os.SystemClock.elapsedRealtime()
        var drawn: InAppHtmlHost? = null
        val display = BridgeDisplay(message, bridgeSdk(message, store) { drawn }) { delay, run -> mainHandler.postDelayed(run, delay) }
        val host = InAppHtmlHost(
            activity = activity,
            message = message,
            content = content,
            html = prepared,
            tokens = store.tokensFor(message),
            display = display,
            onShown = {
                store.recordDisplay(message, sessions.currentId())
                // Counted in the ledger first, then no longer in flight: never neither.
                nudgeSlots.shown(message.deliveryId)
                if (content.trigger.kind == "immediate") store.markDone(message.deliveryId)
                track("in_app_displayed", inAppReceipt(message) + mapOf("render_ms" to android.os.SystemClock.elapsedRealtime() - started))
                notifyShown(message)
            },
            onFailed = { reason ->
                nudgeHosts.remove(message.deliveryId)
                nudgeSlots.release(message.deliveryId)
                if (reason == "render_error") store.markDone(message.deliveryId)
                reportInAppFailure(message, reason, store)
            },
            onPersonClosed = { display.dismiss() },
            customizer = webViewCustomizer,
        )
        drawn = host
        nudgeHosts[message.deliveryId] = host
        host.show()
    }

    /** Every nudge taken down, on the main thread: the screen they were allowed on went, or in-app did. Nothing is spent. */
    private fun closeNudges(owner: android.app.Activity? = null) {
        mainHandler.post {
            for ((id, host) in nudgeHosts.toMap()) {
                if (owner != null && host.owner !== owner) continue
                host.destroy()
                nudgeHosts.remove(id)
                nudgeSlots.release(id)
            }
        }
    }

    /** The store's caps, then the app's contexts, as one answer: why not, or null. */
    private fun inAppBlockedBy(message: InAppMessage, content: InAppContent, store: InAppStore): String? {
        store.blockedBy(message, sessions.currentId(), nudgesInFlight = if (isNudge(message)) nudgeSlots.inFlight() else 0)?.let { return it }
        val contexts = content.display?.contexts.orEmpty()
        if (contexts.isNotEmpty() && contexts.none { it in appContexts }) return "context"
        // Read only for a message that asks, and each time: a primer is for people who can still be asked.
        if (content.display?.onlyWhenPushAskable == true) pushAskableBlock(content.display, TreebarsPush.pushStatus(appContext))?.let { return it }
        return null
    }

    /** `in_app_failed`: once per message, reason and day, for the campaign's failure report. */
    private fun reportInAppFailure(message: InAppMessage, reason: String, store: InAppStore) {
        val campaignId = message.campaignId ?: return
        if (!store.claimFailureReport(message.deliveryId, reason)) return
        track("in_app_failed", mapOf(DELIVERY_ID_KEY to message.deliveryId, CAMPAIGN_ID_KEY to campaignId, "reason" to reason))
    }

    /**
     * Claims the screen and hands the message to the app, and says whether the screen was claimed. [noSurface] runs,
     * on the main thread, when the screen turned out to have gone by the time the handing-over ran; nothing is spent
     * then, and the caller keeps what it needs to try again.
     */
    private fun presentInApp(
        message: InAppMessage,
        content: InAppContent,
        renderer: InAppRenderer,
        store: InAppStore,
        noSurface: () -> Unit,
    ): Boolean {
        // Claimed before anything is spent or reported, and in one step with the check: see [PresentationSlot].
        if (!presentation.claim()) {
            TreebarsLogger.log("in-app: ${message.deliveryId} not shown, another message took the screen first")
            return false
        }
        val draw = renderer

        /*
         * On the main thread, because the host app draws with it.
         *
         * `considerInApp` is a plain function called synchronously from `track()`, so without
         * the hop the renderer would run on whatever thread called it — a background coroutine,
         * an HTTP callback, the React Native bridge's native-modules thread. An app that inflates
         * a View or touches a Dialog there crashes with `CalledFromWrongThreadException`, and one
         * that only sets state gets a silent race instead, which is worse. The iOS SDK hops the
         * same way.
         *
         * The spend is inside the post too. The surface is asked once more here, on the thread that
         * draws, and the message is recorded as displayed only when it is handed to something that
         * can show it — so a screen that goes in between, or a renderer that cannot attach, leaves
         * the message unspent rather than reported as seen by nobody. The trigger match and the caps
         * above stay off the main thread; this is two preference writes.
         */
        mainHandler.post {
            if (!inAppSurfaceReady(draw)) {
                presentation.release()
                TreebarsLogger.log("in-app: ${message.deliveryId} not shown, no screen to draw on; nothing spent")
                noSurface()
                return@post
            }
            TreebarsLogger.log("in-app: showing ${message.deliveryId}")
            store.recordDisplay(message, sessions.currentId())
            /*
             * "Any event is an opportunity; the first one after a sync wins" (see the trigger
             * matcher) is only true if showing it also spends it. `recordDisplay` alone marks a
             * message done once `max_displays` is reached, which an immediate-trigger message
             * rarely sets — a test send never does — so without this, every later event in the
             * same session would match `immediate` again and redraw the same message, once per
             * event. The [isInAppReport] guard does not cover it: that only stops the SDK
             * re-triggering off its own reports.
             */
            if (content.trigger.kind == "immediate") store.markDone(message.deliveryId)
            track("in_app_displayed", inAppReceipt(message))
            notifyShown(message)
            draw.show(
                message,
                store.tokensFor(message),
                { button ->
                    // The two-step push opt-in: this link asks for permission rather than opening anything.
                    if (button.value == TreebarsConstants.PUSH_PERMISSION_LINK) TreebarsPush.requestPermissionFromForeground()
                    // Reported before the app is handed the destination, so a tap that
                    // leaves the app is still recorded.
                    track("in_app_clicked", inAppClickProperties(message, button))
                    // A call to action spends the message as a dismissal does, and frees the screen: see
                    // `inAppClickEndsMessage`. Before the action, which may track an event that draws the next one.
                    if (inAppClickEndsMessage(button)) {
                        presentation.releaseUnpinned()
                        store.markDone(message.deliveryId)
                    }
                    inAppButtonAction(message, button)
                    flush()
                },
                {
                    // Free again the moment the person answers, so a dismiss and the next
                    // message are not separated by the hold.
                    presentation.releaseUnpinned()
                    store.markDone(message.deliveryId)
                    track("in_app_dismissed", inAppReceipt(message))
                    notifyDismissed(message)
                },
            )
        }
        return true
    }

    /**
     * Claims the screen and draws a standard body itself, from its render plan, for an app that registered no renderer.
     * Held until the host says the message ended, as the markup host's claim is: it reports every ending itself, and a
     * person still reading a form's thanks must not have the next message drawn over them. [noSurface] runs, and nothing
     * is spent, when the screen went before the draw or the window could not attach.
     */
    private fun presentNative(message: InAppMessage, store: InAppStore, noSurface: () -> Unit): Boolean {
        if (!presentation.claim(untilReleased = true)) {
            TreebarsLogger.log("in-app: ${message.deliveryId} not shown, another message took the screen first")
            return false
        }
        mainHandler.post {
            val activity = TreebarsPush.resumedActivity()
            if (activity == null) {
                presentation.release()
                TreebarsLogger.log("in-app: ${message.deliveryId} not shown, no screen to draw on; nothing spent")
                noSurface()
                return@post
            }
            // The environment as it is now, on the screen it will be drawn on: dark or light, phone or tablet.
            val plan = inAppRenderPlan(message.raw, inAppRenderEnvFor(activity.resources.configuration, store.tokens))
            if (plan !is InAppRenderPlan.Overlay) {
                // Not reachable from the loop that calls this — an overlay with a standard body plans as one — but a plan
                // that says otherwise will say it again on the next event, so it is spent and reported, not retried.
                presentation.release()
                store.markDone(message.deliveryId)
                reportInAppFailure(message, "render_error", store)
                return@post
            }
            TreebarsLogger.log("in-app: drawing ${message.deliveryId} (${plan.shape})")
            var drawn: InAppNativeHost? = null
            val host = InAppNativeHost(activity, plan, nativeCore(message, store) { drawn })
            drawn = host
            nativeHost = host
            val appeared = try {
                host.show()
            } catch (error: Throwable) {
                // A plan the views could not be built from will not build on the next event either.
                TreebarsLogger.log("in-app: ${message.deliveryId} could not be drawn: $error")
                closeNative(host)
                store.markDone(message.deliveryId)
                reportInAppFailure(message, "render_error", store)
                return@post
            }
            if (!appeared) {
                closeNative(host)
                TreebarsLogger.log("in-app: ${message.deliveryId} not shown, the window would not attach; nothing spent")
                noSurface()
            }
        }
        return true
    }

    /**
     * What one natively drawn message does to the core — the receipts [presentInApp] hands an app's renderer, in the
     * same words, so a report cannot tell which drew it.
     */
    private fun nativeCore(message: InAppMessage, store: InAppStore, host: () -> InAppNativeHost?): InAppNativeCore = object : InAppNativeCore {
        override fun shown() {
            store.recordDisplay(message, sessions.currentId())
            // Spent as it is shown, as [presentInApp] spends it: an `immediate` trigger matches every later event.
            if (message.content?.trigger?.kind == "immediate") store.markDone(message.deliveryId)
            track("in_app_displayed", inAppReceipt(message))
            notifyShown(message)
        }

        /*
         * Recorded, then closed, then done — and the close comes before the action rather than after it, which is the
         * one place this differs from reading the contract's sentence in order. The screen is held until this host
         * releases it, so a `track_event` press whose event triggers the next message would find it still taken, and a
         * trigger that finds the screen taken is ignored rather than held: the next message would be lost. An app's
         * renderer frees the screen before the action for the same reason.
         */
        override fun pressed(button: InAppPlanButton) {
            val tapped = InAppButton(
                label = button.label,
                action = button.action,
                value = button.value,
                eventName = button.eventName,
                key = button.key,
                data = button.data,
                index = button.index,
            )
            // The two-step push opt-in: this link asks for permission rather than opening anything.
            if (tapped.value == TreebarsConstants.PUSH_PERMISSION_LINK) TreebarsPush.requestPermissionFromForeground()
            track("in_app_clicked", inAppClickProperties(message, tapped))
            if (inAppClickEndsMessage(tapped)) store.markDone(message.deliveryId)
            closeNative(host())
            inAppButtonAction(message, tapped)
            flush()
            // A link or a page only: the plan's destination is never a trait's value or the push opt-in link.
            button.destination?.let { deviceActions.open(it) }
        }

        override fun dismissed() {
            store.markDone(message.deliveryId)
            track("in_app_dismissed", inAppReceipt(message))
            closeNative(host())
            notifyDismissed(message)
        }

        // Answered: done on this device and reported now; the host keeps the thanks up and the screen held till it goes.
        override fun submitted(answers: Map<String, Any>) = submitInAppForm(message, answers)

        override fun answered() = closeNative(host())
    }

    /** Takes a native message down and frees the screen — only if it still holds it, so a late call frees nobody else's. */
    private fun closeNative(host: InAppNativeHost?) {
        host ?: return
        host.destroy()
        if (nativeHost !== host) return
        nativeHost = null
        presentation.release()
    }

    /**
     * Another of the app's screens came in front of the one a standard message this SDK drew is on, from
     * `TreebarsPush.activityTracker`: that message is taken down quietly, as for a destroyed screen — the display was
     * counted, nothing more is recorded, and the screen is freed. An HTML banner the same.
     *
     * A banner is the reason. It is the one shape that leaves the app usable, so a person can tap through to another
     * screen under it; left on the first screen's decor view with the screen still claimed until it is released, it would
     * hold back every message on every other screen until they went back and closed it — for a root Activity, possibly
     * never. A standard modal is taken down too, for an app that starts a screen of its own while one is up; an HTML
     * modal or fullscreen is left as it was, in a Dialog nobody navigates under. Not on `onStop`: that is also the app going to the
     * background, and somebody who switched apps halfway through a form would come back to find it gone. A permission
     * dialog, a share sheet or a date picker is not one of the app's screens, and resumes nothing here.
     */
    internal fun noteScreenInFront(activity: android.app.Activity) {
        nativeHost?.takeIf { it.owner !== activity }?.let(::closeNative)
        val html = htmlHost ?: return
        if (!html.isBanner || html.owner === activity) return
        html.destroy()
        htmlHost = null
        presentation.release()
    }

    /** The standard message this SDK is drawing, for a test. */
    internal val nativeInAppHost: InAppNativeHost? get() = nativeHost

    /** The markup body on screen, for a test. */
    internal val htmlInAppHost: InAppHtmlHost? get() = htmlHost

    /**
     * Everything this SDK drew taken down and the screen freed, for a test. `Treebars` is a process singleton that
     * Robolectric shares across test classes, and a message left on screen holds the slot for every class after it.
     * Not [disableInApps], which switches in-app off for the rest of the process. Main thread.
     */
    internal fun takeDownInAppForTest() {
        closeNative(nativeHost)
        htmlHost?.destroy()
        htmlHost = null
        presentation.release()
    }

    /** A markup body: this SDK's to draw, in a WebView with the `treebars` bridge. */
    private fun drawsItself(content: InAppContent): Boolean = content.bodyMode == "html" && content.surface == "overlay"

    /**
     * Claims the screen and draws a markup body itself, the Android half of the web SDK's
     * `renderMarkup`. Counted as displayed when the page says it is running (`onShown`), not when the WebView is made:
     * a WebView that cannot be made (`webview_unavailable`) or a page that never runs (`render_error`) is not a display
     * and spends nothing but its report. A body over 64 KiB whose fetch never landed is `asset_download`.
     */
    private fun presentHtml(message: InAppMessage, content: InAppContent, store: InAppStore, noSurface: () -> Unit): Boolean {
        // Held until the host says the message ended, which it does on every path: see [PresentationSlot].
        if (!presentation.claim(untilReleased = true)) {
            TreebarsLogger.log("in-app: ${message.deliveryId} not shown, another message took the screen first")
            return false
        }
        /*
         * The document is prepared first, off the main thread: its files read from disk — or fetched, when the
         * prefetch this session's sync started has not landed them — and inlined. The screen is already claimed, so
         * nothing else is drawn meanwhile, and `render_ms` still starts at the draw.
         */
        scope.launch(Dispatchers.IO) {
            val prepared = content.html?.takeIf { it.isNotEmpty() }?.let { preparedMarkup(message, it) }
            mainHandler.post { drawHtml(message, content, store, noSurface, prepared) }
        }
        return true
    }

    /** The markup body's drawing, on the main thread, with its document prepared ([preparedMarkup]). */
    private fun drawHtml(message: InAppMessage, content: InAppContent, store: InAppStore, noSurface: () -> Unit, prepared: String?) {
        val activity = TreebarsPush.resumedActivity()
        if (activity == null) {
            presentation.release()
            TreebarsLogger.log("in-app: ${message.deliveryId} not shown, no screen to draw on; nothing spent")
            noSurface()
            return
        }
        if (content.html.isNullOrEmpty() || prepared == null) {
            presentation.release()
            // A large body whose fetch never landed, or a file the body needs that is gone or could not be had.
            reportInAppFailure(message, if (content.htmlRef != null || !content.html.isNullOrEmpty()) "asset_download" else "render_error", store)
            return
        }
        TreebarsLogger.log("in-app: drawing ${message.deliveryId} (markup)")
        // How long the page took to run and show, from here; and whether this is the process's first WebView.
        val started = android.os.SystemClock.elapsedRealtime()
        val cold = !htmlDrawnInProcess
        htmlDrawnInProcess = true
        var drawn: InAppHtmlHost? = null
        val display = BridgeDisplay(message, bridgeSdk(message, store) { drawn }) { delay, run -> mainHandler.postDelayed(run, delay) }
        val host = InAppHtmlHost(
            activity = activity,
            message = message,
            content = content,
            html = prepared,
            tokens = store.tokensFor(message),
            display = display,
            onShown = {
                store.recordDisplay(message, sessions.currentId())
                if (content.trigger.kind == "immediate") store.markDone(message.deliveryId)
                track("in_app_displayed", inAppReceipt(message) + mapOf("render_ms" to android.os.SystemClock.elapsedRealtime() - started, "cold" to cold))
                notifyShown(message)
            },
            onFailed = { reason ->
                htmlHost = null
                presentation.release()
                // A page that would not run will not run on the next event either; a WebView that is updating may.
                if (reason == "render_error") store.markDone(message.deliveryId)
                reportInAppFailure(message, reason, store)
            },
            onPersonClosed = { display.dismiss() },
            customizer = webViewCustomizer,
        )
        drawn = host
        htmlHost = host
        host.show()
    }

    /** What one HTML display may ask of this SDK (`BridgeSdk`). */
    private fun bridgeSdk(message: InAppMessage, store: InAppStore, host: () -> InAppHtmlHost?): BridgeSdk = object : BridgeSdk {
        private val context: Context get() = TreebarsPush.resumedActivity() ?: appContext

        private fun start(intent: android.content.Intent): Boolean {
            val from = context
            if (from !is android.app.Activity) intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            return runCatching { from.startActivity(intent) }.onFailure { TreebarsLogger.log("in-app bridge: could not open $intent: $it") }.isSuccess
        }

        override fun track(name: String, properties: Map<String, Any?>) = Treebars.track(name, properties)

        /*
         * Off the main thread: a blocking round trip, answered back on it where the display lives. Asked again after a
         * 429, a 503 or no answer, within a few seconds (`RewardClaim.kt`); a claim is answered once per person, so
         * asking again is safe.
         */
        override fun claimReward(pool: String, deliveryId: String, answer: (Map<String, Any?>) -> Unit) {
            val transport = client ?: return answer(BridgeDisplay.refuse("not_available"))
            scope.launch(Dispatchers.IO) {
                val last = claimWithRetries(ask = { transport.postInAppReward(deviceId(), fetchSecret(), userId, userSignature, deliveryId, pool) })
                val result = last.answer?.let { BridgeDisplay.toMap(it) } ?: BridgeDisplay.refuse(rewardRefusalReason(last))
                mainHandler.post { answer(result) }
            }
        }

        override fun setTraits(traits: Map<String, Any?>): Map<String, Any?> {
            setMessageTraits(traits)
            return BridgeDisplay.OK
        }

        override fun requestPushPermission(answer: (String) -> Unit) {
            val manager = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as? android.app.NotificationManager
            val enabled = { manager?.areNotificationsEnabled() == true }
            if (android.os.Build.VERSION.SDK_INT < 33 || enabled()) return answer(if (enabled()) "granted" else "denied")
            val activity = TreebarsPush.resumedActivity() ?: return answer("unsupported")
            TreebarsPush.requestPermission(activity)
            // The answer arrives when the dialog closes and the screen resumes; read then, or after a minute.
            var paused = false
            val started = System.currentTimeMillis()
            fun look() {
                val resumed = TreebarsPush.hasResumedActivity()
                if (!resumed) paused = true
                if ((paused && resumed) || System.currentTimeMillis() - started > 60_000) answer(if (enabled()) "granted" else "denied")
                else mainHandler.postDelayed({ look() }, 300)
            }
            mainHandler.postDelayed({ look() }, 300)
        }

        override fun clicked(action: String, values: Map<String, Any?>, fields: Map<String, Any?>) {
            val listener = clickActionListener ?: return
            val strings = values.mapValues { (_, value) -> value?.toString().orEmpty() }
            val button = InAppButton(
                label = fields[TreebarsConstants.IN_APP_BUTTON_LABEL_KEY]?.toString() ?: fields["element"]?.toString().orEmpty(),
                action = action,
                value = fields["destination"]?.toString(),
                data = strings,
                index = (fields[TreebarsConstants.IN_APP_BUTTON_INDEX_KEY] as? Number)?.toInt(),
            )
            runCatching { listener.onClick(InAppClickAction(action, strings, button), message) }
                .onFailure { TreebarsLogger.log("in-app: click listener threw: $it") }
        }

        /**
         * A press that leads somewhere takes the message with it, as the page going does on the web: spent and the screen
         * freed while it stayed drawn was a message nothing could stop another from being drawn over.
         */
        override fun spent() {
            // The slot this message took: a nudge's place, or the screen a modal holds.
            if (isNudge(message)) nudgeSlots.release(message.deliveryId) else presentation.release()
            store.markDone(message.deliveryId)
            host()?.let { drawn ->
                drawn.destroy()
                if (htmlHost === drawn) htmlHost = null
                if (nudgeHosts[message.deliveryId] === drawn) nudgeHosts.remove(message.deliveryId)
            }
        }

        override fun dismissed() {
            if (isNudge(message)) {
                nudgeHosts.remove(message.deliveryId)
                nudgeSlots.release(message.deliveryId)
            } else {
                htmlHost = null
                presentation.release()
            }
            store.markDone(message.deliveryId)
            notifyDismissed(message)
        }

        override fun flush() = Treebars.flush()

        override fun open(url: String, via: String): Boolean {
            // A deep link is the app's own to route; a web address and a landing page leave for the browser.
            if (url == TreebarsConstants.PUSH_PERMISSION_LINK) {
                TreebarsPush.requestPermissionFromForeground()
                return true
            }
            return deviceActions.open(url)
        }

        // The device's own acts, shared with a typed button's: `DeviceActions`.
        override fun copy(text: String, toast: String?): Boolean = deviceActions.copy(text, toast)

        override fun dial(number: String): Boolean = deviceActions.dial(number)

        override fun sms(number: String, body: String?): Boolean = deviceActions.sms(number, body)

        override fun share(text: String): Boolean = deviceActions.share(text)

        override fun settings(notifications: Boolean): Boolean {
            val pkg = appContext.packageName
            return if (notifications && android.os.Build.VERSION.SDK_INT >= 26) {
                start(android.content.Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, pkg))
            } else {
                start(android.content.Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$pkg")))
            }
        }

        // Play's own review sheet where the app carries Play's review library, the listing otherwise.
        override fun storeReview(): Boolean = deviceActions.storeReview()

        override fun alert(message: String) {
            val activity = TreebarsPush.resumedActivity() ?: return
            runCatching { android.app.AlertDialog.Builder(activity).setMessage(message).setPositiveButton(android.R.string.ok, null).show() }
        }

        override fun context(): Map<String, Any?> {
            val insets = host()?.currentInsets()
            return mapOf(
                "locale" to localeTag(),
                "theme" to if (host()?.isNight() == true) "dark" else "light",
                "insets" to mapOf("top" to (insets?.top ?: 0), "right" to (insets?.right ?: 0), "bottom" to (insets?.bottom ?: 0), "left" to (insets?.left ?: 0)),
            )
        }

        override fun log(line: String) = TreebarsLogger.log(line)
    }

    /**
     * The screen an HTML message is drawn on is going, from `TreebarsPush.activityTracker`: its Dialog, or a banner on
     * its view tree, goes with it. The display was counted when it appeared, so nothing more is recorded; the screen is
     * freed. The same for a standard message this SDK drew, whose Dialog or banner belongs to that screen too.
     */
    internal fun noteActivityDestroyed(activity: android.app.Activity) {
        closeNudges(activity)
        nativeHost?.takeIf { it.owner === activity }?.let(::closeNative)
        val host = htmlHost ?: return
        if (host.owner !== activity) return
        host.destroy()
        htmlHost = null
        presentation.release()
    }

    /**
     * No in-app message is synced or shown on this device for the rest of the process: the one on screen is taken down.
     * The same as the iOS SDK's `disableInApps`. The React Native bridge calls it for `in_app_enabled: false`, because
     * this SDK draws messages itself and a missing renderer does not mean nothing is drawn.
     */
    @JvmStatic
    fun disableInApps() {
        inAppEnabled = false
        mainHandler.post {
            closeNative(nativeHost)
            htmlHost?.destroy()
            htmlHost = null
            presentation.release()
        }
        closeNudges()
    }

    /**
     * The WebView an HTML in-app message is drawn in, handed to the app before the page loads — its settings, a
     * debugging flag, a download listener. The SDK's own settings (JavaScript on,
     * storage, file and content access off, no second window) are applied first, and the bridge is not the app's.
     */
    @JvmStatic
    fun setInAppWebViewCustomizer(customizer: ((android.webkit.WebView) -> Unit)?) {
        webViewCustomizer = customizer
    }

    /**
     * The app's configuration changed under an HTML message it did not recreate its Activity for — an Activity that
     * handles `orientation|screenSize` itself: the message measures its box again.
     * An Activity that is recreated takes its message with it instead (`noteActivityDestroyed`).
     */
    @JvmStatic
    fun onConfigurationChanged() {
        mainHandler.post {
            htmlHost?.reconfigure()
            nudgeHosts.values.forEach { it.reconfigure() }
        }
    }

    /** What a press asks of the device beyond a link: the screen in front when there is one, the app otherwise. */
    private val deviceActions = DeviceActions { TreebarsPush.resumedActivity() ?: appContext }

    /** What a button does beyond reporting the tap: an event, a trait, keys for the app, or a device action. */
    private fun inAppButtonAction(message: InAppMessage, button: InAppButton) {
        val campaign = message.campaignId?.let { mapOf(CAMPAIGN_ID_KEY to it) } ?: emptyMap()
        when (button.action) {
            "track_event" -> button.eventName?.let { track(it, campaign) }
            "set_attribute" -> button.key?.let { setMessageTraits(mapOf(it to (button.value ?: ""))) }
            /*
             * Push's device actions, done here by the core, as the HTML bridge's are — so the app's renderer draws the
             * button and a React Native one only forwards the press. The same `DeviceActions`.
             */
            "call" -> button.value?.let { deviceActions.dial(it) }
            "copy" -> button.value?.let { deviceActions.copy(it, null) }
            "share" -> button.value?.let { deviceActions.share(it) }
            "store_review" -> deviceActions.storeReview()
            else -> Unit
        }
        // Every press goes to the app's click listener after it is recorded; a `custom` button's keys arrive
        // only here. `dismiss` is a dismissal, not a press.
        val listener = clickActionListener ?: return
        if (button.action == "dismiss") return
        val values = clickValues(button)
        runCatching { listener.onClick(InAppClickAction(button.action, values, button), message) }
            .onFailure { TreebarsLogger.log("in-app: click listener threw: $it") }
    }

    /**
     * Records an event.
     *
     * The event is stamped with this device, the session, the current screen ([screen]) and the
     * signed-in person ([identify]), written to the queue on disk, and uploaded with the next
     * batch. [properties] are sent as JSON. The event can also show an in-app message that was
     * waiting for it.
     *
     * Safe to call from any thread; returns at once. Dropped before [initialize] and while opted
     * out ([optOut]).
     */
    @JvmStatic
    @JvmOverloads
    fun track(eventName: String, properties: Map<String, Any?> = emptyMap()) {
        val key = writeKey
        if (key == null) {
            TreebarsLogger.log("Dropped event; Treebars.initialize has not been called")
            return
        }
        if (optedOut) return

        /*
         * One read of the device for this event. `considerInApp` runs now and `buildEvent`
         * runs later inside `record`, so two reads would be two answers: the network type is read fresh on
         * every call, and the screen can change in between. Both take this snapshot, and a trigger's
         * dimension row reads exactly what the event is stamped with.
         */
        val snapshot = deviceSnapshot()
        // Remembered until it lands, so a flush() on the next line waits for it (`InFlight`).
        recording.add(scope.launch { record(eventName, properties, snapshot = snapshot) })

        // The one hook in-app needs, where every event already passes through. Not inside
        // record(): drawing a message must never sit between an event and its queue.
        considerInApp(eventName, properties, eventDimensions(snapshot.device, snapshot.screen, sdkName()))
    }

    /**
     * Records a screen view (`screen_view`), and remembers the screen for everything that follows.
     *
     * The name lands in `screen_name`, a field of its own rather than a property, so a
     * breakdown can group by it, and the view carries `previous_screen` as well. Every later
     * event carries the same value until the next [screen] call — which is what makes "where
     * did this happen" a question you can ask of an arbitrary event, not just of the view
     * itself. Moving to another screen also takes down the nudges [showNudge] allowed.
     */
    @JvmStatic
    @JvmOverloads
    fun screen(name: String, properties: Map<String, Any?> = emptyMap()) {
        val previous = currentScreen
        currentScreen = name
        // The nudges belonged to the screen they were allowed on: a new screen asks for its own with `showNudge`.
        if (previous != name && nudgePlace != null) {
            nudgePlace = null
            closeNudges()
        }

        val enriched = buildMap<String, Any?> {
            put("screen_name", name)
            previous?.let { put("previous_screen", it) }
            putAll(properties)
        }
        track(EVENT_SCREEN_VIEW, enriched)
    }

    /**
     * Puts one event on the queue, with the session boundaries it revealed ahead of it.
     *
     * Serialised on [recordMutex] because the ordering is the point: the old session has
     * to close and the new one open before the event that exposed the gap lands inside it,
     * and two concurrent `track` coroutines would otherwise interleave those three writes.
     * The flush is deliberately outside the lock — it is network work, not queue work.
     */
    private suspend fun record(
        eventName: String,
        properties: Map<String, Any?>,
        userIdOverride: String? = null,
        /** The device as `track` read it; a caller that is not `track` has it read here, once. */
        snapshot: DeviceSnapshot? = null,
    ) {
        // Every event passes through here — the app's, the lifecycle's, the install referrer's.
        if (optedOut) return
        val device = snapshot ?: deviceSnapshot()

        val step = recordMutex.withLock {
            // Again under the lock: an opt-out that cleared the queue while this waited wins.
            if (optedOut) return
            val step = advanceSession(device, isEvent = true)
            queue.append(
                buildEvent(
                    eventName,
                    properties,
                    sessionId = step.sessionId,
                    userIdOverride = userIdOverride,
                    snapshot = device,
                ),
            )
            step
        }

        announceQueued(step, device, eventName)
    }

    /** What [advanceSession] did: the session now current, and the boundaries it queued ahead of whatever moved it. */
    private class SessionStep(
        val sessionId: String,
        /** `session_end` and `session_start`, in the order queued; empty while a session merely continues. */
        val boundaries: List<String>,
        /** `session_start`'s properties when one opened, for the in-app layer. */
        val opened: Map<String, Any?>?,
    )

    /**
     * Moves the session to now as the next event would, and queues the boundaries that revealed.
     * The caller holds [recordMutex] and calls [announceQueued] once it has let go.
     *
     * One copy, for [record] and [contextToken] both. A token asked for after the thirty minutes
     * names the session the purchase will be filed in, so it has to be the session the next event
     * lands in too — and a second copy of this block would be a second place `session_end`'s
     * backdating and `session_start`'s properties could each quietly go wrong.
     *
     * @param isEvent false for a token, which moves the session and is not one of its events.
     */
    private suspend fun advanceSession(device: DeviceSnapshot, isEvent: Boolean): SessionStep {
        val touch = sessions.touch(isEvent)
        if (!autoTrackSessions) return SessionStep(touch.sessionId, emptyList(), null)

        val boundaries = mutableListOf<String>()
        var opened: Map<String, Any?>? = null
        touch.expired?.let { expired ->
            queue.append(
                buildEvent(
                    EVENT_SESSION_END,
                    mapOf("duration_ms" to expired.durationMs, "event_count" to expired.eventCount),
                    sessionId = expired.id,
                    // The session's own last moment, not this one. A user who closed
                    // the app at nine and reopened at noon had a session that ended
                    // at nine.
                    timestamp = Iso8601.at(expired.endedAt),
                    detached = true,
                    snapshot = device,
                ),
            )
            boundaries += EVENT_SESSION_END
        }

        if (touch.isNew) {
            val sessionProperties = mapOf<String, Any?>(
                "is_first_session" to touch.isFirstSession,
            )
            queue.append(
                buildEvent(
                    EVENT_SESSION_START,
                    sessionProperties,
                    sessionId = touch.sessionId,
                    snapshot = device,
                ),
            )
            boundaries += EVENT_SESSION_START
            opened = sessionProperties
        }
        return SessionStep(touch.sessionId, boundaries, opened)
    }

    /**
     * What follows a [SessionStep] once [recordMutex] is let go: the uploader and the in-app layer
     * told what was queued. [eventName] is the event queued behind the boundaries — null for a
     * token, which queued none of its own.
     */
    private suspend fun announceQueued(step: SessionStep, device: DeviceSnapshot, eventName: String?) {
        /*
         * Every event this call put on the queue, the session boundaries included — a journey can
         * start on `session_start` as readily as on anything the app tracks. After the lock and
         * after the append, so the flush a listed one asks for finds it there.
         */
        for (name in step.boundaries) uploader.eventLogged(name)
        eventName?.let { uploader.eventLogged(it) }

        /*
         * Show the in-app layer the session it would not otherwise see.
         *
         * `session_start` is APPENDED here rather than tracked, so it never passes through
         * `considerInApp` by itself — and two things depend on it doing so: a message triggered
         * on `session_start`, which is the natural way to greet somebody opening the app, and
         * the sync `considerInApp` runs for `session_start`.
         *
         * After the lock, deliberately. Drawing must never sit between an event and its queue
         * (see `track`), and by here the event is queued.
         */
        step.opened?.let { considerInApp(EVENT_SESSION_START, it, eventDimensions(device.device, device.screen, sdkName())) }

        if (queue.size() >= BATCH_SIZE) uploader.flush()
    }

    /**
     * Associates this device, and every event from here on, with a signed-in person, and updates
     * their profile. Call it after [initialize], when somebody signs in, and again whenever their
     * attributes change; the sign-in is remembered across launches until [reset].
     *
     * [attributes] are written to the person's profile. Underneath them the SDK adds what it
     * already knows — the platform, locale, timezone, app version and when this install was first
     * seen — and the app's values win. The `user_identified` event this records carries the
     * attribute keys, never their values.
     *
     * [signature] is the hex HMAC-SHA256 of [userId] under the environment's identity secret,
     * computed by the app's own backend — never on the handset, because the secret must not ship in
     * an APK. An environment that requires signed identities refuses the sign-in without it, and
     * withholds the person's in-app messages and notifications. Calling again for the same person
     * without one keeps the signature already held, so an app that re-identifies to update
     * attributes does not quietly lose its sign-in.
     *
     * Identifying a different person while somebody is signed in clears what this device held for
     * the last one — queued in-app messages, the nudges on screen and the notification centre's
     * history — before anything is drawn for the new one. [reset] is still the call for a sign-out:
     * it also records it and starts a new session.
     *
     * Ignored while opted out.
     */
    @JvmStatic
    @JvmOverloads
    fun identify(userId: String, attributes: Map<String, Any?> = emptyMap(), signature: String? = null) {
        // Before initialize there is no storage to write the person to, and throwing would crash the app.
        if (writeKey == null) {
            TreebarsLogger.log("Ignored identify; Treebars.initialize has not been called")
            return
        }
        if (optedOut) return
        userSignature = signature ?: userSignature.takeIf { userId == this.userId }
        /*
         * Somebody else, with no sign-out between. What this device holds is the last person's — the queued messages,
         * one waiting out its delay, a trigger held for a renderer, the nudges on screen, the notification history —
         * and so is a read in flight: all of it goes here, before this sign-in's own events can draw any of it. Not
         * the same one identified again, which every launch does, and not a first sign-in from anonymous, whose queue
         * is the same person's — either would drop what was right.
         */
        var replaced = false
        if (this.userId != null && userId != this.userId) {
            inAppStore?.supersede()
            notificationStore?.supersede()
            delayedDelivery = null
            synchronized(undrawnTriggers) { undrawnTriggers.clear() }
            lastNotificationServerTime = null
            closeNudges()
            replaced = true
        }
        this.userId = userId
        // Told once the new person is the one signed in, so a list that fetches again on a change asks as them.
        if (replaced) emitNotificationChange(NotificationPage(emptyList(), 0, null, true))
        // So the next cold start knows who this is, and can prove it. `apply()` rather than
        // `commit()`: it is a cache of the two fields set above.
        val editor = appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(TreebarsConstants.KEY_SIGNED_IN_USER, userId)
        // Also what this call signs with, whatever a later identify does to the field meanwhile.
        val held = userSignature
        if (held != null) editor.putString(TreebarsConstants.KEY_SIGNED_IN_USER_SIGNATURE, held)
        else editor.remove(TreebarsConstants.KEY_SIGNED_IN_USER_SIGNATURE)
        editor.apply()

        scope.launch {
            /*
             * What the SDK knows, underneath what the app said.
             *
             * A profile that arrives carrying nothing but an id renders as an empty card,
             * even though locale and timezone were in the device dimensions the whole
             * time. The app's own values always win: passing `locale` is a claim about the
             * person's preference, which outranks the handset's setting.
             */
            val merged = defaultUserAttributes() + attributes

            val payload = JSONObject()
                .put("user_id", userId)
                .put("device_id", deviceId())
                .put("attributes", JSONObject(merged))

            val refused = runCatching {
                kotlinx.coroutines.withContext(Dispatchers.IO) { client?.postIdentify(payload, held) }
            }.getOrNull() == true
            if (refused) warnSignatureRequired()

            // Re-reported so the device row picks up the identity it was registered
            // without. Forced rather than left to shouldReportContext, whose hash covers
            // the device's own attributes and is unchanged by a login.
            runCatching {
                val context = DeviceInfo.context(appContext)
                track(
                    "device_context",
                    context + mapOf(
                        "context_hash" to DeviceInfo.hashContext(context),
                        "fetch_secret" to fetchSecret(),
                    ),
                )
            }

            reportUserIdentified(userId, merged)
        }
    }

    /**
     * A token for whatever will report the purchase about to happen, so the event it sends is filed under this device,
     * this person and — within thirty minutes — this session. Hand it to the app's backend as `context.treebars` on the
     * server events API, to Play as `setObfuscatedAccountId(it)`, or into Stripe's or RevenueCat's metadata.
     *
     * **Issued by the server, never assembled on the device.** The device proves itself when it asks, as it does for a
     * sign-in — its secret, and the backend's signature where the environment requires one — so an event carrying a
     * token shows that this device asked for it. It works for a guest as well as for a signed-in person, since most
     * purchases start as a guest's.
     *
     * A lower-case UUID because StoreKit's `appAccountToken` is one, and one shape everywhere is what lets a single
     * call serve every store; Play's field takes up to 64 characters, so the same token fits there as it is.
     *
     * **Once per purchase, just before it.** Asking moves the session as an event would — an expired one is closed
     * and a new one opened, so the token names the session the sale lands in — though it adds no event of its own.
     *
     * Null before [initialize], while opted out, and on any failure: go ahead with the purchase without it. The
     * sale is still reported; it only loses the device and session it would have been filed under. Never throws.
     */
    @JvmStatic
    suspend fun contextToken(): String? {
        if (writeKey == null || optedOut) return null
        return try {
            val device = deviceSnapshot()
            val step = recordMutex.withLock {
                if (optedOut) return null
                advanceSession(device, isEvent = false)
            }
            // Launched, not awaited: it may start an upload, and somebody pressing Buy should not wait on one.
            if (step.boundaries.isNotEmpty()) scope.launch { announceQueued(step, device, eventName = null) }

            // Off the lock: a slow answer must not hold every event behind it.
            val signedIn = userId
            val payload = JSONObject()
                .put("device_id", deviceId())
                .put("session_id", step.sessionId)
            signedIn?.let { payload.put("user_id", it) }
            val answer = kotlinx.coroutines.withContext(Dispatchers.IO) {
                client?.postContextToken(payload, userSignature.takeIf { signedIn != null })
            } ?: return null
            if (answer.signatureRequired) warnSignatureRequired()
            answer.token
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            TreebarsLogger.log("context token failed: $error")
            null
        }
    }

    /** The handful of profile attributes the SDK can fill in before the app says anything. */
    private fun defaultUserAttributes(): Map<String, Any?> {
        val dimensions = DeviceInfo.dimensions(appContext)

        return buildMap {
            put("platform", "android")
            dimensions["locale"]?.let { put("locale", it) }
            dimensions["timezone"]?.let { put("timezone", it) }
            dimensions["app_version"]?.let { put("app_version", it) }
            firstSeenAt?.let { put("first_seen_at", it) }
        }
    }

    /**
     * Records the moment somebody stopped being anonymous.
     *
     * `/v1/identify` writes the profile, but it is not an event — so without this the single
     * most interesting transition in an app's funnel would be invisible to analytics, to
     * retention cohorts, to journey triggers and to campaign goals. The endpoint call stays:
     * this is an addition to it, not a replacement.
     *
     * Attribute *keys*, never values. Events are stored apart from the profile, with their own
     * retention, and are not revised once written; a name or an email belongs in the profile
     * the identify call just wrote, not copied into an event.
     */
    private fun reportUserIdentified(userId: String, attributes: Map<String, Any?>) {
        val prefs = appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val previousUserId = prefs.getString("identified_user", null)
        prefs.edit().putString("identified_user", userId).apply()

        val properties = buildMap<String, Any?> {
            put("user_id", userId)
            // "First on this device", which is the only version of the question the SDK
            // can answer. Whether the account itself is new is the server's to know.
            put("is_first_identify", previousUserId == null)
            if (previousUserId != null && previousUserId != userId) {
                put("previous_user_id", previousUserId)
            }
            put("attribute_keys", org.json.JSONArray(attributes.keys.sorted()))
        }
        track(EVENT_USER_IDENTIFIED, properties)
    }

    /**
     * Registers a push token so campaigns and journeys can reach this device. Pass the token
     * whenever the provider issues one — at launch, and again when it changes — and it is sent at
     * once.
     *
     * Sent as an ordinary event (`push_token_registered`) rather than through a bespoke
     * endpoint, so it shares the queue's retries and the same server path handles
     * registration for every platform.
     */
    @JvmStatic
    @JvmOverloads
    fun registerPushToken(token: String, provider: PushProvider = PushProvider.FCM) {
        track("push_token_registered", mapOf("token" to token, "provider" to provider.value))
        flush()
    }

    /**
     * Reports that somebody tapped a notification sent by a campaign.
     *
     * Hand it the message's data map — `RemoteMessage.getData()` — and it picks out the
     * identifiers Treebars put there. Nothing happens when they are absent, so it is safe
     * to call for every notification the app handles, including ones Treebars did not send.
     *
     * The app passes the data in rather than the SDK reading it, so this module keeps
     * needing network access and nothing else: taking a Firebase dependency to receive a
     * map the host already holds would put Firebase in the dependency tree of every app
     * that integrates this SDK, whether or not it uses push.
     *
     * Call it only for a real tap. A notification arriving while the app is open has not
     * been opened by anyone, and counting it would put opens above sends.
     */
    @JvmStatic
    fun trackNotificationOpened(data: Map<String, String>) {
        val properties = openedProperties(data) ?: return
        track("notification_opened", properties)
        // Flushed rather than batched: this runs as the app is being brought up, which
        // is exactly when the process is most likely to be killed again.
        flush()
    }

    private fun openedProperties(data: Map<String, String>): Map<String, Any>? {
        val deliveryId = data[DELIVERY_ID_KEY]
        if (deliveryId.isNullOrEmpty()) return null
        val properties = mutableMapOf<String, Any>(DELIVERY_ID_KEY to deliveryId)
        data[CAMPAIGN_ID_KEY]?.takeIf { it.isNotEmpty() }?.let { properties[CAMPAIGN_ID_KEY] = it }
        // Which of a push's buttons was pressed, when it was one.
        data[TreebarsConstants.RICH_PUSH_BUTTON_ID_KEY]?.takeIf { it.isNotEmpty() }?.let { properties[TreebarsConstants.RICH_PUSH_BUTTON_ID_KEY] = it }
        return properties
    }

    private fun dismissedProperties(data: Map<String, String>): Map<String, Any>? {
        val deliveryId = data[DELIVERY_ID_KEY]
        if (deliveryId.isNullOrEmpty()) return null
        val properties = mutableMapOf<String, Any>(DELIVERY_ID_KEY to deliveryId)
        data[CAMPAIGN_ID_KEY]?.takeIf { it.isNotEmpty() }?.let { properties[CAMPAIGN_ID_KEY] = it }
        return properties
    }

    /**
     * A receipt from an SDK-drawn push, which may arrive in a process `initialize` has not reached yet: then it is
     * kept, and `initialize` sends it — see [PendingPushReceipts].
     */
    internal fun pushReceipt(context: Context, opened: Boolean, data: Map<String, String>) {
        val properties = (if (opened) openedProperties(data) else dismissedProperties(data)) ?: return
        val event = if (opened) "notification_opened" else "push_dismissed"
        if (writeKey == null) {
            PendingPushReceipts.add(context.applicationContext, event, properties)
            return
        }
        track(event, properties)
        if (opened) flush()
    }

    /**
     * A push button's "set a trait", on the person as any message's trait is: through `identify` for whoever is signed
     * in, on the anonymous person otherwise. A button pressed in a process the app has not initialised yet sets nothing
     * — the tap itself is still recorded, and a pending store for a trait would be a second queue beside the one
     * `initialize` opens.
     */
    internal fun setAttributeFromPush(key: String, value: String) {
        if (writeKey == null || key.isEmpty()) return
        setMessageTraits(mapOf(key to value))
    }

    /**
     * Traits a message set — a form's answer kept as a trait, a button's "set a trait", an HTML message's
     * `setUserAttribute` family and `data-tb-save`, a push button's — on the person, signed in or not.
     *
     * Signed in, through [identify]. With nobody signed in there is still a person — the anonymous identity this device
     * resolves to — so the traits go on it and travel with it at `identify()`, where that identity becomes the account
     * or is absorbed into one. That keeps an onboarding survey's answers for exactly the people an onboarding survey is
     * shown to. `/v1/identify` needs an account id, so they ride the event queue as `traits_set`, with its retries and
     * its copy on disk across a kill. Which traits are allowed (declared, not reserved) is the caller's to decide; this
     * decides only where an allowed trait goes.
     */
    internal fun setMessageTraits(traits: Map<String, Any?>) {
        if (traits.isEmpty()) return
        val user = userId
        if (user != null) {
            identify(user, traits)
            return
        }
        track(EVENT_TRAITS_SET, mapOf("trait_keys" to org.json.JSONArray(traits.keys.sorted()), "traits" to traits))
    }

    /**
     * Reports that somebody swiped away a notification sent by a campaign without opening it.
     *
     * A push the SDK draws itself (`TreebarsPush.handle`) reports its own dismissal through its delete intent.
     * This is for the rest: an app that builds its own notification sets a delete intent on it
     * (`NotificationCompat.Builder.setDeleteIntent`) and calls this from the receiver with the message's data. A
     * notification Firebase drew by itself offers no such hook. Nothing happens for one Treebars did not send.
     */
    @JvmStatic
    fun trackNotificationDismissed(data: Map<String, String>) {
        track("push_dismissed", dismissedProperties(data) ?: return)
    }

    /**
     * Watch what the uploader is doing: each attempt, as an [UploadLog]. Null removes the listener.
     * Call it after [initialize]; before, it does nothing.
     *
     * For an app that wants to show upload activity on screen — `debug` logging goes to logcat,
     * which is a developer reading a console rather than something an app can render. The React
     * Native SDK forwards it as `onUpload`.
     *
     * Called on the flush coroutine, not the main thread. A listener that touches UI is the
     * caller's job to post; a listener that throws is caught, because losing a batch to the
     * host app's callback would be this SDK's bug.
     */
    @JvmStatic
    fun setUploadListener(listener: ((UploadLog) -> Unit)?) {
        if (writeKey == null) return
        uploader.listener = listener
    }

    /**
     * How many events are waiting to be uploaded. Zero before [initialize].
     *
     * The queue and the sealed batches both, because a batch leaves the queue when it is sealed
     * rather than when it is acknowledged: counting the queue alone would show a failing upload
     * as an empty one.
     */
    @JvmStatic
    suspend fun pendingCount(): Int =
        if (writeKey == null) 0 else queue.size() + uploader.pendingEvents()

    /**
     * Milliseconds until the auto-flush next runs, or null when nothing is scheduled.
     *
     * Null rather than zero when the loop is not running, which is the distinction a caller
     * needs: "no flush is scheduled" and "a flush is due right now" are different sentences
     * and a screen that showed 0 for both would be lying about one of them. Clamped at zero
     * on the low side, because a negative countdown reads as a bug.
     */
    @JvmStatic
    fun msUntilNextFlush(): Long? = nextFlushAt?.let { maxOf(0L, it - System.currentTimeMillis()) }

    /**
     * Uploads what is queued now, including every event tracked before this call. Returns at once;
     * the upload runs in the background. Does nothing while opted out.
     *
     * The records still in flight are captured HERE, synchronously, and joined before the drain,
     * so an event tracked on the line before goes in this upload rather than waiting for the next.
     */
    @JvmStatic
    fun flush() {
        // Nothing can be queued before initialize, and the uploader does not exist yet.
        if (writeKey == null || optedOut) return
        val tracked = recording.snapshot()
        scope.launch {
            tracked.joinAll()
            uploader.flush()
        }
    }

    /**
     * Signs the current person out of this device. Call it after [initialize], when somebody signs
     * out.
     *
     * Records `user_signed_out`, starts a new session, and clears the signed-in person, their
     * in-app messages and their notification history from this device. Events already queued are
     * kept and still uploaded: they were captured while that person was signed in. The device id
     * stays — it belongs to the handset, not the person; [wipeLocalData] is what forgets it.
     *
     * Does nothing when nobody is signed in, so an app may call it defensively.
     */
    @JvmStatic
    fun reset() {
        /*
         * Captured before the clear, emitted after it, in one coroutine.
         *
         * `buildEvent` reads `userId` inside `scope.launch`, so a plain "emit then clear"
         * written as two statements loses the race — the synchronous clear wins and the
         * sign-out goes out with no user id. That costs more than the timeline entry: a
         * sign-out with no user id is not found by an erasure of the person who signed out.
         *
         * Only when there was somebody signed in. An app calling reset() defensively on
         * launch must not stamp a sign-out on every anonymous person.
         */
        // Before initialize nobody can be signed in, and there is no storage to clear.
        if (writeKey == null) return
        val signedOutUserId = userId
        /*
         * `identified_user` is history and deliberately stays — it is what `previous_user_id`
         * is computed from. This one is current state, and a sign-out that failed to clear it
         * would let the next launch present the previous person's `user_id` on the read routes
         * and fetch their queued messages. Cleared whoever is held, so a reset() that runs
         * before anything was restored still clears it.
         */
        appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .remove(TreebarsConstants.KEY_SIGNED_IN_USER)
            .remove(TreebarsConstants.KEY_SIGNED_IN_USER_SIGNATURE)
            .apply()
        /*
         * Nobody signed in, so there is no sign-in to end and nothing below applies. An app calling reset()
         * defensively on launch must not split the person's session or wipe their in-app queue and the ledger of what
         * they have already seen and answered — the next sync would offer those messages again. The anonymous person
         * before the call is the same one after it.
         */
        if (signedOutUserId == null) return
        userId = null
        userSignature = null
        currentScreen = null
        // The previous person's nudges, and where they were allowed.
        nudgePlace = null
        closeNudges()

        scope.launch {
            record(
                EVENT_USER_SIGNED_OUT,
                mapOf("user_id" to signedOutUserId),
                userIdOverride = signedOutUserId,
            )
            uploader.flush()
            // Inside the coroutine and after the record, not synchronously: torn down first,
            // the sign-out would land in a freshly minted session preceded by a spurious
            // session_start.
            sessions.reset()
        }

        /*
         * The queued messages and the notification history both go — they were addressed to
         * whoever was signed in.
         *
         * The device id and its secret deliberately survive: both belong to the handset rather
         * than the person, and they are only ever replaced together ([wipeLocalData]).
         */
        inAppStore?.reset()
        delayedDelivery = null
        // A trigger held for a renderer is the previous person's moment, replayed against the next one's queue.
        synchronized(undrawnTriggers) { undrawnTriggers.clear() }
        notificationStore?.reset()
        lastNotificationServerTime = null
        emitNotificationChange(NotificationPage(emptyList(), 0, null, true))
    }

    /**
     * Stops this SDK recording or sending anything from this device — events, sign-ins, content reads,
     * link questions, push-token registrations — until [optIn], and on every later launch: the answer
     * is kept. What was waiting to be sent is dropped with it. Call it before [initialize] when a
     * consent prompt answers first.
     *
     * Nothing already sent is touched: erasing a person's data on the server is the API's
     * `/privacy/delete`, which the app's backend calls. And opting out is not signing out — [reset]
     * is that.
     */
    @JvmStatic
    fun optOut() {
        optedOut = true
        if (writeKey == null) {
            answerBeforeInit = true
            return
        }
        appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit().putBoolean(KEY_OPTED_OUT, true).apply()
        scope.launch { discardUnsent() }
    }

    /** Undoes [optOut]: recording resumes with the next event, and nothing dropped comes back. */
    @JvmStatic
    fun optIn() {
        optedOut = false
        if (writeKey == null) {
            answerBeforeInit = false
            return
        }
        appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit().remove(KEY_OPTED_OUT).apply()
    }

    /** Whether [optOut] is in effect on this device. */
    @JvmStatic
    fun isOptedOut(): Boolean = optedOut

    /**
     * Forgets this device, here: the device id and its secret, who is signed in and who had been,
     * the queue and every batch waiting to be sent, the session, the in-app ledger and the
     * notification history. Nothing is sent on the way — not even the sign-out [reset] records — and
     * from the next event on this is a device the server has never seen, with a new id and a new
     * secret. The opt-out stays: it is the person's answer, not data about them, so a person who
     * wants to be forgotten and not recorded again calls [optOut] as well.
     *
     * Nothing on the server is touched: what was already sent is erased by the API's
     * `/privacy/delete`, which the app's backend calls.
     */
    @JvmStatic
    fun wipeLocalData() {
        if (writeKey == null) return
        scope.launch {
            discardUnsent()
            recordMutex.withLock {
                userId = null
                userSignature = null
                appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit()
                    .remove(TreebarsConstants.KEY_SIGNED_IN_USER)
                    .remove(TreebarsConstants.KEY_SIGNED_IN_USER_SIGNATURE)
                    .remove("identified_user")
                    .commit()
                forgetDeviceIdentity()
                sessions.reset()
            }
            inAppStore?.reset()
            notificationStore?.reset()
            // The files its messages loaded: a forgotten device keeps nothing it was sent.
            assetCache?.clear()
            lastNotificationServerTime = null
            emitNotificationChange(NotificationPage(emptyList(), 0, null, true))
        }
    }

    /** The queue and every sealed batch: what an opt-out or a wipe says must not be sent. */
    private suspend fun discardUnsent() {
        recordMutex.withLock { queue.clear() }
        uploader.discardPending()
    }

    /**
     * The pair erased, so the next caller mints a new one — id and secret together, never a new secret
     * under the old id — and the context report forgotten, so the new device reports itself.
     */
    @Synchronized
    private fun forgetDeviceIdentity() {
        DeviceIdentityStore(appContext.noBackupFilesDir).erase()
        identity = null
        DeviceInfo.forgetReportedContext(appContext)
    }

    /** This process's answer, once `DeviceIdentityStore` has given one. */
    @Volatile
    private var identity: DeviceIdentity? = null

    /**
     * The device's pseudonymous id and the secret that proves it, one pair from one file in
     * `noBackupFilesDir` (`DeviceIdentityStore`) — never from SharedPreferences, which Auto Backup
     * carries to whatever phone the backup is restored on.
     *
     * Synchronized because resolving is a read-modify-write: two callers that overlap would both find
     * nothing stored and both mint, and the loser of the write would already have handed its value to
     * an event — one handset reported as two devices. `identify()` calls this outside [recordMutex],
     * so the window is real.
     *
     * A pair new to this install is a device the server has never heard from, so what the
     * preferences say was reported — restored, perhaps, from another phone's backup — is forgotten,
     * and the device reports itself.
     */
    @Synchronized
    private fun deviceIdentity(adopted: DeviceIdentity? = null): DeviceIdentity {
        identity?.let { return it }
        val (resolved, isNew) = DeviceIdentityStore(appContext.noBackupFilesDir).resolve(adopted)
        if (isNew) DeviceInfo.forgetReportedContext(appContext)
        identity = resolved
        return resolved
    }

    /** This install's id: a random id the SDK mints, not a hardware identifier. Sent with every event. */
    private fun deviceId(): String = deviceIdentity().id

    /**
     * What this device proves itself with: sent as a header on the requests that need it, and in its `device_context`
     * report, but never with any other event.
     */
    private fun fetchSecret(): String = deviceIdentity().secret

    /**
     * @param detached suppresses the current screen. Only `session_end` uses it: that
     *   event is stamped into a session that closed before this process started, so
     *   labelling it with a screen the user is looking at now would be a false statement
     *   about where it happened.
     */
    private fun buildEvent(
        eventName: String,
        properties: Map<String, Any?>,
        sessionId: String,
        timestamp: String = Iso8601.now(),
        detached: Boolean = false,
        /**
         * Stamps an event with a user id the SDK no longer holds.
         *
         * One caller: [reset], whose event is about the sign-in that just ended. The
         * identity clears synchronously, but `buildEvent` runs inside a coroutine and would
         * otherwise read the already-null field.
         */
        userIdOverride: String? = null,
        /** The one read of the device this event is stamped from; see [track]. */
        snapshot: DeviceSnapshot,
    ): JSONObject {
        val event = JSONObject()
            .put("event_id", UUID.randomUUID().toString())
            .put("session_id", sessionId)
            .put("device_id", deviceId())
            .put("event_name", eventName)
            .put("properties", JSONObject(properties))
            .put("timestamp", timestamp)

        (userIdOverride ?: userId)?.let { event.put("user_id", it) }

        // The same function `track` hands the in-app evaluator, over the same snapshot: the stamped
        // dimensions and the ones a trigger reads cannot differ.
        val screen = if (detached) null else snapshot.screen
        for ((key, value) in eventDimensions(snapshot.device, screen, sdkName())) event.put(key, value)
        // os_api_level has no field of its own; it travels in `device_extra`, the forward-compatible bag for
        // device details that have none, rather than being dropped.
        snapshot.device["os_api_level"]?.let {
            event.put("device_extra", JSONObject().put("os_api_level", it))
        }

        return event
    }

    /** The device and the current screen, read once. `DeviceInfo` caches all but the network type. */
    private fun deviceSnapshot() = DeviceSnapshot(DeviceInfo.dimensions(appContext), currentScreen)

    private fun sdkName() = sdkNameOverride ?: TreebarsConstants.SDK_NAME

    /**
     * When the auto-flush loop is next due, as epoch millis. Null when it is not running.
     *
     * Recorded rather than derived, because a bare `while { delay; flush }` keeps no state a
     * caller of [msUntilNextFlush] could read. Written before each sleep, so a caller reading it
     * mid-upload gets the next fire rather than one in the past.
     */
    @Volatile
    private var nextFlushAt: Long? = null

    private fun startAutoFlush(intervalMs: Long) {
        scope.launch {
            while (isActive) {
                nextFlushAt = System.currentTimeMillis() + intervalMs
                delay(intervalMs)
                uploader.flush()
            }
        }
    }

    /**
     * Watches the app move between foreground and background.
     *
     * `ProcessLifecycleOwner` rather than per-Activity callbacks, because a rotation or a
     * move between two Activities is not the user leaving the app, and this owner already
     * debounces exactly that.
     *
     * The background transition carries the flush, and that is the more important half:
     * it is the last reliable moment to upload before Android may kill the process.
     */
    private fun observeLifecycle() {
        /*
         * On the main thread, always, because `addObserver` demands it — it throws
         * `IllegalStateException: Method addObserver must be called on the main thread`
         * otherwise, and `runCatching` below would turn that into one debug line.
         *
         * `initialize` is not always called on the main thread: `Application.onCreate` is, but
         * the React Native bridge calls it from the native modules thread. Registered off-main,
         * the observer would fail quietly and take `app_foreground`, `app_background`, the
         * context re-report on resume and the flush on the way to the background with it —
         * the last reliable moment to upload before Android may kill the process — while every
         * screen went on working.
         *
         * `post` rather than "post only if we are not already on main": the observer is
         * registered once at startup, so the extra loop turn costs nothing worth the branch.
         */
        mainHandler.post {
            observeLifecycleOnMain()
        }
    }

    private fun observeLifecycleOnMain() {
        runCatching {
            ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
                override fun onStart(owner: LifecycleOwner) {
                    val now = System.currentTimeMillis()
                    // Skipped for the launch itself, which `app_open` already reported.
                    if (backgroundedAt > 0) {
                        track(EVENT_APP_FOREGROUND, mapOf("background_ms" to now - backgroundedAt))

                        /*
                         * And re-state the context, because coming back is the one moment
                         * it can have changed without this process seeing it happen.
                         * Notification permission is the reason — it moves in the Settings
                         * app — but an OS upgrade and a locale change arrive the same way,
                         * and both would otherwise wait for a cold launch or the seven-day TTL.
                         *
                         * Nearly free: `reportDeviceContext` short-circuits on the stored
                         * hash, so a foreground where nothing moved costs a preferences
                         * read and no network.
                         */
                        reportDeviceContext()
                    }
                    foregroundedAt = now
                }

                override fun onStop(owner: LifecycleOwner) {
                    val now = System.currentTimeMillis()
                    val foregroundMs = now - foregroundedAt
                    backgroundedAt = now

                    // One coroutine, not a track() followed by a flush(): those are two
                    // independent launches, and the flush could win the race and upload a
                    // batch that did not yet contain the event.
                    scope.launch {
                        if (foregroundedAt > 0) {
                            record(EVENT_APP_BACKGROUND, mapOf("foreground_ms" to foregroundMs))
                        }
                        uploader.flush()
                    }
                }
            })
        }.onFailure {
            /*
             * Name the cause. Without it `app_foreground` and `app_background` simply stop
             * arriving; with it, a `NoClassDefFoundError` for `ProcessLifecycleOwner` says at
             * once that a dependency is missing rather than that a device is odd.
             */
            TreebarsLogger.log(
                "Lifecycle observation unavailable (${it::class.java.simpleName}: ${it.message}); " +
                    "relying on the periodic flush",
            )
        }
    }
}
