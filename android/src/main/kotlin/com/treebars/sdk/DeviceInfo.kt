package com.treebars.sdk

import com.treebars.sdk.generated.TreebarsConstants

import android.annotation.SuppressLint
import android.app.NotificationManager
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import java.util.Locale
import java.util.TimeZone

/**
 * Device information, split by how often it is worth sending.
 *
 * [dimensions] rides on every event. That looks redundant next to a device registry, but
 * events are append-only: an event has to record the context it happened under, or a
 * user upgrading Android or the app would retroactively relabel their whole history and
 * every version-adoption chart with it. A value repeated on every event compresses to
 * almost nothing.
 *
 * [context] is the heavier half, sent only when [hashContext] changes: screen geometry
 * and anything else nothing ever asks the historical value of.
 */
internal object DeviceInfo {

    /**
     * Read once and cached. `Build` fields are constants, the package lookup is a binder
     * call, and [Treebars.buildEvent] runs on every event.
     */
    @Volatile
    private var cached: Map<String, String>? = null

    fun dimensions(context: Context): Map<String, String> {
        cached?.let { return it + networkDimension(context) }

        val values = mutableMapOf(
            "platform_type" to "android",
            "os_name" to "Android",
            // Both are reported: RELEASE is what a human recognises ("14"), SDK_INT is
            // what a compatibility question is actually asked in ("34"), and neither is
            // derivable from the other.
            "os_version" to Build.VERSION.RELEASE.orEmpty(),
            "device_manufacturer" to Build.MANUFACTURER.orEmpty(),
            // The model alone, apart from the manufacturer, so a breakdown by either needs
            // no string surgery.
            "device_model" to Build.MODEL.orEmpty(),
            "device_type" to deviceType(context),
            "locale" to Locale.getDefault().toLanguageTag(),
            "timezone" to TimeZone.getDefault().id,
        )

        values["os_api_level"] = Build.VERSION.SDK_INT.toString()

        runCatching {
            val info = context.packageManager.getPackageInfo(context.packageName, 0)
            info.versionName?.let { values["app_version"] = it }
            val code =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode
                else @Suppress("DEPRECATION") info.versionCode.toLong()
            values["app_build"] = code.toString()
        }

        val frozen = values.filterValues { it.isNotEmpty() }
        cached = frozen
        return frozen + networkDimension(context)
    }

    /**
     * The app's name as the launcher shows it, or null when it cannot be read or is blank — the
     * `name` the three lifecycle events carry, so a list of them says which app each row is.
     *
     * Not cached with the rest: a label follows the device's language, which can change while the
     * process runs, and the events that carry it are a handful per visit.
     */
    fun appName(context: Context): String? = runCatching {
        context.applicationInfo.loadLabel(context.packageManager).toString().trim().takeIf { it.isNotEmpty() }
    }.getOrNull()

    /**
     * Not cached with the rest: this is the one dimension that changes while the process
     * runs. Requires ACCESS_NETWORK_STATE, which the SDK's manifest declares; if it is
     * somehow absent the read fails closed and the dimension is simply omitted.
     */
    @SuppressLint("MissingPermission")
    private fun networkDimension(context: Context): Map<String, String> = runCatching {
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return@runCatching emptyMap()

        val capabilities = manager.getNetworkCapabilities(manager.activeNetwork)
            ?: return@runCatching mapOf("network_type" to "none")

        val type = when {
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            else -> return@runCatching emptyMap()
        }
        mapOf("network_type" to type)
    }.getOrDefault(emptyMap())

    /**
     * The name on the box, when the manufacturer publishes one — `Redmi Note 13 Pro`
     * where `Build.MODEL` says `2312DRA50G`.
     *
     * Android has no API for this and no equivalent of Apple's identifier table, so a
     * codename is all `Build.MODEL` can offer for most of the market. Some manufacturers
     * do set a system property, and where they do it is the device's own answer rather
     * than anybody's guess — the only kind of name worth printing. Xiaomi, Redmi, POCO,
     * Oppo, Realme and newer OnePlus use `ro.product.marketname`; Huawei and Honor use
     * `ro.config.marketing_name`; Oppo's stack also carries `ro.vendor.oplus.market.name`.
     *
     * Samsung and Google publish none of these, so their handsets go on reporting a
     * codename and the dashboard prints it raw. Naming them would need Google Play's
     * device catalogue; a name typed from memory is not the alternative.
     *
     * `SystemProperties` is a hidden class, so this is reflection, and reflection at a
     * non-SDK interface is exactly the thing Android is allowed to stop honouring. It
     * fails to an empty string, which is filtered out — no worse than a device that
     * publishes no property at all, which is most of them.
     */
    private fun marketingName(): String? {
        val value = PROPERTY_NAMES.firstNotNullOfOrNull { systemProperty(it) } ?: return null
        // A property echoing the model tells nobody anything.
        return value.takeIf { !it.equals(Build.MODEL, ignoreCase = true) }
    }

    private fun systemProperty(name: String): String? = runCatching {
        @Suppress("PrivateApi")
        val get = Class.forName("android.os.SystemProperties").getMethod("get", String::class.java)
        (get.invoke(null, name) as? String)?.trim()?.takeIf { it.isNotEmpty() }
    }.getOrNull()

    /** Checked in order; the first that answers wins. See `marketingName`. */
    private val PROPERTY_NAMES = listOf(
        "ro.product.marketname",
        "ro.vendor.oplus.market.name",
        "ro.config.marketing_name",
    )

    /**
     * Google's own threshold: 600dp of smallest width is what the platform treats as a
     * tablet layout, so it is the definition a product question about tablets means.
     */
    private fun deviceType(context: Context): String =
        if (context.resources.configuration.smallestScreenWidthDp >= 600) "tablet" else "phone"

    /**
     * Everything worth knowing about a device once. Values are typed rather than
     * stringified because anything without a field of its own is kept among the device's
     * attributes, where a number should stay a number.
     */
    fun context(context: Context): Map<String, Any> {
        val values = mutableMapOf<String, Any>()
        values.putAll(dimensions(context))

        // The application's own id. Here and not in `dimensions()`: it is a fact about the
        // build, so a copy on every event is the same string a million times. It is kept
        // among the device's attributes.
        values["app_id"] = context.packageName

        // The retail name, where the manufacturer publishes one. BESIDE `device_model` and
        // never instead of it: the model is the stable breakdown dimension, and a device
        // that started reporting a different string for it would split its own history in
        // two. Here rather than in `dimensions()` for the same reason as `app_id` — it
        // cannot change while the process runs.
        marketingName()?.let { values["device_model_name"] = it }

        // Whether the OS will draw this app's notifications.
        notificationPermission(context)?.let { values["notification_permission"] = it }

        val metrics = context.resources.displayMetrics
        values["screen_width"] = metrics.widthPixels
        values["screen_height"] = metrics.heightPixels
        values["screen_scale"] = metrics.density.toDouble()

        values["is_emulator"] = isEmulator(
            fingerprint = Build.FINGERPRINT.orEmpty(),
            model = Build.MODEL.orEmpty(),
            product = Build.PRODUCT.orEmpty(),
            hardware = Build.HARDWARE.orEmpty(),
            manufacturer = Build.MANUFACTURER.orEmpty(),
            brand = Build.BRAND.orEmpty(),
            device = Build.DEVICE.orEmpty(),
        )

        return values
    }

    /**
     * What `device_context` says of this app's in-app messages, as `in_app_display`: `off` when nothing will be
     * drawn — in-app is switched off ([Treebars.disableInApps]) — `app` when the app registered its own renderer
     * ([Treebars.setInAppRenderer]), and `sdk` when this SDK draws them, which is the default.
     *
     * The same three words in every Treebars SDK. Not part of [context]: that is what the device says of itself,
     * and this is what the app's code has said, so it is read from the two values a draw is decided by at the moment
     * a report is built, and kept nowhere.
     */
    fun inAppDisplay(enabled: Boolean, ownRenderer: Boolean): String = when {
        !enabled -> "off"
        ownRenderer -> "app"
        else -> "sdk"
    }

    /**
     * Whether these build facts describe an emulator — read from `Build`, so no permission and
     * no native call.
     *
     * The heuristic from the older `generic` images — a fingerprint starting `generic` or naming
     * `vbox`/`emulator`, a model naming `Emulator` or `Android SDK built for` — matches none of
     * Google's images since API 30: the fingerprint is `google/sdk_gphone16k_arm64/emu64a16k:…`,
     * the model `sdk_gphone16k_arm64`, the hardware `ranchu`. So both generations are checked, or
     * a modern emulator would be counted as a real handset wherever the flag is read.
     *
     * `ranchu` and `goldfish` are the emulator's own virtual boards, the most reliable single fact
     * and the one no shipping phone reports; `vbox86` is Genymotion's. Model and product carry
     * `sdk_gphone` / `google_sdk` / a leading `sdk_` on every Google image. Deliberately NOT a bare
     * substring like `emu` or `sdk` anywhere in the fingerprint: a real device's codename can
     * contain those letters, and a phone reported as an emulator is the worse error — it is the
     * one that gets filtered out of a customer's numbers. `ro.kernel.qemu` is not read: it needs
     * a hidden API.
     */
    internal fun isEmulator(
        fingerprint: String,
        model: String,
        product: String,
        hardware: String,
        manufacturer: String,
        brand: String,
        device: String,
    ): Boolean {
        val googleImage = listOf(model, product).any {
            it.contains("sdk_gphone") || it.contains("google_sdk") || it.startsWith("sdk_") || it == "sdk"
        }
        return hardware == "ranchu" || hardware == "goldfish" || hardware == "vbox86" ||
            googleImage ||
            fingerprint.startsWith("generic") ||
            fingerprint.startsWith("google/sdk_gphone") ||
            fingerprint.contains("vbox") ||
            fingerprint.contains("emulator") ||
            model.contains("Emulator") ||
            model.contains("Android SDK built for") ||
            manufacturer.contains("Genymotion") ||
            (brand.startsWith("generic") && device.startsWith("generic"))
    }

    /**
     * A stable 32-bit FNV-1a over the sorted context.
     *
     * Not a cryptographic hash: it only has to change when the context does. FNV rather
     * than MessageDigest because the same comparison runs in four SDKs and no digest API
     * is common to all of them, whereas this is identical everywhere by construction.
     */
    fun hashContext(context: Map<String, Any>): String {
        val canonical = context.keys.sorted().joinToString(" ") { "$it=${context[it] ?: ""}" }

        var hash = TreebarsConstants.FNV_OFFSET_BASIS
        for (byte in canonical.toByteArray(Charsets.UTF_8)) {
            hash = hash xor (byte.toInt() and 0xFF)
            hash *= TreebarsConstants.FNV_PRIME
        }
        return String.format("%08x", hash)
    }

    /**
     * Whether this context needs reporting, recording it if so.
     *
     * False is the common case after the first launch, which is the point: the registry
     * is fed a handful of events per install, not one per app open.
     *
     * True also when the last report has aged past the TTL. The hash alone would be a
     * one-way promise: this device remembers having registered, but the record it
     * registered lives on the server, where a privacy erasure or a project reset can
     * remove it. Without the TTL such a device would never report itself again while it
     * carried on sending events, and would be missing from every broadcast audience with
     * nothing here able to notice.
     *
     * Hash and timestamp are one value rather than two keys, so a write that only half
     * lands cannot leave a hash that never expires — the failure the TTL exists to end.
     */
    fun shouldReportContext(context: Context, hash: String): Boolean {
        val prefs = context.getSharedPreferences(Treebars.PREFS_NAME, Context.MODE_PRIVATE)
        val stored = prefs.getString("device_context_hash", null)
        return stored == null || isStale(stored, hash)
    }

    /**
     * Whether this device has reported its context before, whatever it said then.
     *
     * A device that has not is one nobody has heard from: its first report is what registers it, so that one is made
     * at once, where every later one waits until the launch has settled.
     */
    fun hasReportedContext(context: Context): Boolean =
        context.getSharedPreferences(Treebars.PREFS_NAME, Context.MODE_PRIVATE).contains("device_context_hash")

    /**
     * Records that the report was made — separately, and after it was.
     *
     * Not part of [shouldReportContext], so that asking the question does not answer it: a
     * hash stored before the event existed, for a `device_context` that then failed to
     * enqueue, would leave a device silent for the whole seven-day TTL, having never
     * reported once — and nothing above could tell that from a device whose context
     * genuinely had not changed.
     *
     * Hash and timestamp stay one value rather than two keys, so a write that only half
     * lands cannot leave a hash that never expires — the failure the TTL exists to end.
     */
    fun rememberReportedContext(context: Context, hash: String) {
        context.getSharedPreferences(Treebars.PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString("device_context_hash", "$hash:${System.currentTimeMillis()}")
            .apply()
    }

    /**
     * Forgets that a report was made, for a device new to this install (`DeviceIdentityStore`).
     *
     * The preferences are backed up and the device's identity is not, so a phone restored from
     * another's backup starts as a new device carrying the old one's hash — and would stay out of the
     * registry, unreachable by every broadcast, for the whole TTL. A new device reports itself.
     */
    fun forgetReportedContext(context: Context) {
        context.getSharedPreferences(Treebars.PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .remove("device_context_hash")
            .apply()
    }

    /**
     * Whether this app may show a notification.
     *
     * The reason this exists: a device can hold a live push token with notifications
     * switched off, and every layer above reports success — FCM accepts the send, returns
     * 200, and nothing is ever drawn. No provider signal distinguishes that from a
     * delivered push, so the SDK is the only place the fact can come from.
     *
     * Synchronous, unlike iOS, and needing no cache or observer: it answers correctly
     * straight after a trip to Settings, which is the case this whole thing is for.
     *
     * **Two states, not five.** On API 33+ a fresh install reads `false` until
     * `POST_NOTIFICATIONS` is granted, and Android offers no way to tell that apart from a
     * person who refused — `shouldShowRequestPermissionRationale` is false in both, and
     * needs an Activity besides. So never-asked reports as `denied`, and the docs say so
     * rather than this inventing a `not_determined` it cannot know. Below API 33 the value
     * is exact: notifications default to on, so `false` means somebody turned them off.
     *
     * The platform's own NotificationManager rather than NotificationManagerCompat:
     * `areNotificationsEnabled` is API 24 and minSdk is 24, so the compat wrapper buys
     * nothing and would add an androidx dependency to a library that has none.
     */
    private fun notificationPermission(context: Context): String? = runCatching {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return@runCatching null
        if (manager.areNotificationsEnabled()) "authorized" else "denied"
    }.getOrNull()

    /**
     * The transition to report, if there is one, and the bookkeeping that goes with it.
     *
     * **The first observation is never a change.** A device seeing its own permission for
     * the first time records it and reports nothing: `device_context` already carries the
     * state, and treating first sight as a transition would stamp one on every install in
     * the fleet the day this ships.
     *
     * Recorded before the caller enqueues anything, which is the opposite of what
     * `shouldReportContext` does, and deliberately. A lost context report leaves a device
     * missing from the registry and unreachable by every broadcast, so it must be retried;
     * a lost change event leaves one gap in a series. Double-counting an opt-out would be
     * worse than missing one.
     */
    fun pendingPermissionChange(context: Context): Pair<String, String>? {
        val current = notificationPermission(context) ?: return null

        val prefs = context.getSharedPreferences(Treebars.PREFS_NAME, Context.MODE_PRIVATE)
        val previous = prefs.getString(PERMISSION_KEY, null)
        if (previous == current) return null

        prefs.edit().putString(PERMISSION_KEY, current).apply()
        return previous?.let { it to current }
    }

    /**
     * Its own key rather than something derived from the context hash: the hash says the
     * context moved, never which part of it did, and an OS upgrade moves it too.
     */
    private const val PERMISSION_KEY = "notification_permission"

    /** A week: one extra event per device per week, and a registry that repairs itself. */
    private const val CONTEXT_REPORT_TTL_MS = TreebarsConstants.CONTEXT_REPORT_TTL_MS

    private fun isStale(stored: String, hash: String): Boolean {
        // A record without a timestamp — one an older version of the SDK wrote — re-reports
        // once, which is what refreshes it.
        val separator = stored.lastIndexOf(':')
        if (separator == -1) return true

        val reportedAt = stored.substring(separator + 1).toLongOrNull() ?: return true

        return stored.substring(0, separator) != hash ||
            System.currentTimeMillis() - reportedAt >= CONTEXT_REPORT_TTL_MS
    }
}
