package com.treebars.sdk

import com.treebars.sdk.generated.TreebarsConstants

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.zip.GZIPOutputStream

/**
 * What an upload got back: the status, and the two headers the upload policy reads.
 *
 * A thrown exception is the other outcome — no answer at all — and the uploader treats the two
 * differently, so a status of zero is never used to stand for "the network failed".
 */
internal data class UploadResponse(
    val status: Int,
    val retryAfter: String? = null,
    /** `X-Treebars-Triggers-Version`, which the server sets on an accepted upload and nothing else. */
    val triggersVersion: String? = null,
)

/** What `/v1/context-token` answered; see [BackendClient.postContextToken]. */
internal data class ContextTokenAnswer(val token: String?, val signatureRequired: Boolean = false)

/**
 * The account id as `X-Treebars-User-Id` carries it: UTF-8, percent-encoded, so that nothing but ASCII
 * letters, digits and a few marks is sent as itself. A header value is Latin-1 at best and an account id
 * is whatever the customer chose — OkHttp, under `HttpURLConnection` here, refuses a non-ASCII value, and a
 * refused request would lose that person's in-app messages and inbox. The server decodes it; any valid
 * percent-encoding reads the same there, so the three SDKs need not agree on which marks they leave alone —
 * only that none sends a raw non-ASCII byte or a bare `%`.
 */
internal fun userIdHeaderValue(userId: String): String =
    // `URLEncoder` is form encoding, which writes a space as `+`; a literal `+` it writes as `%2B`.
    URLEncoder.encode(userId, "UTF-8").replace("+", "%20")

/**
 * The seam between the upload policy and HTTP.
 *
 * An interface for exactly one reason: the shared scenarios drive [EventUploader] with scripted
 * answers, and a policy that could only be exercised through a socket could only be tested by
 * standing up a server that misbehaves on cue.
 */
internal fun interface EventTransport {
    /** Blocking. Throws when no HTTP answer arrived. */
    fun postEvents(batch: JSONObject): UploadResponse
}

/**
 * Transport for the ingest endpoint.
 *
 * Built on `HttpURLConnection` rather than OkHttp deliberately: an analytics SDK is
 * a dependency in someone else's app, and forcing a networking library on every
 * integrator risks version conflicts for no benefit at this request volume.
 *
 * The public write key is sent on every request; there is no token exchange, since
 * the key ships inside the APK regardless.
 */
internal class BackendClient(
    private val baseUrl: String,
    private val writeKey: String,
    /**
     * This device's secret, sent with every post so that the ones that name the device — a sign-in,
     * and an upload that may carry a push token — come with proof of it. Null in tests that drive the
     * upload policy alone.
     */
    private val deviceSecret: (() -> String)? = null,
) : EventTransport {

    private fun gzip(body: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        GZIPOutputStream(out).use { it.write(body) }
        return out.toByteArray()
    }

    private fun post(path: String, body: ByteArray, compressed: Boolean): UploadResponse {
        val connection = URL("${baseUrl.trimEnd('/')}$path").openConnection() as HttpURLConnection

        return try {
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.connectTimeout = 15_000
            connection.readTimeout = 30_000
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty(TreebarsConstants.WRITE_KEY_HEADER, writeKey)
            deviceSecret?.let { connection.setRequestProperty(TreebarsConstants.DEVICE_AUTH_HEADER, it()) }
            if (compressed) connection.setRequestProperty("Content-Encoding", "gzip")

            connection.outputStream.use { it.write(body) }
            // Read before disconnecting: the headers live on the connection, and a 429 without its
            // wait is a different instruction from a 429 with it.
            UploadResponse(
                connection.responseCode,
                connection.getHeaderField("Retry-After"),
                connection.getHeaderField(TreebarsConstants.TRIGGERS_VERSION_HEADER),
            )
        } finally {
            connection.disconnect()
        }
    }

    override fun postEvents(batch: JSONObject): UploadResponse {
        val raw = batch.toString().toByteArray()

        // Fall back to the uncompressed body if compression fails rather than
        // dropping the batch; the server accepts both.
        val compressed = runCatching { gzip(raw) }.getOrNull()
        return post(TreebarsConstants.EVENTS_PATH, compressed ?: raw, compressed != null)
    }

    /**
     * A sign-in, and whether the server refused it for want of a signature (403 `signature_required`).
     *
     * Its own connection rather than [post], because the answer that matters here is in a refusal's
     * body: when a signature is required and none was sent, [Treebars] says so once instead of
     * letting a best-effort call swallow it.
     */
    fun postIdentify(payload: JSONObject, signature: String?): Boolean {
        val (status, body) = postAsDevice(TreebarsConstants.IDENTIFY_PATH, payload, signature, 15_000, 30_000)
        return status == 403 && body.contains("signature_required")
    }

    /**
     * A context token for this device, minted by the server: the token, or null with whether the refusal
     * was for want of a signature. Throws when no answer arrived, as [postIdentify] does.
     *
     * Five seconds each way where a sign-in waits thirty: this sits in front of somebody pressing Buy,
     * and a purchase that goes ahead without a token only loses the session it would have been filed in.
     */
    fun postContextToken(payload: JSONObject, signature: String?): ContextTokenAnswer {
        val (status, body) = postAsDevice(TreebarsConstants.CONTEXT_TOKEN_PATH, payload, signature, 5_000, 5_000)
        if (status == 200 || status == 201) {
            val token = runCatching { JSONObject(body).opt("token") as? String }.getOrNull()
            return ContextTokenAnswer(token?.trim()?.lowercase(java.util.Locale.ROOT)?.takeIf { it.isNotEmpty() })
        }
        TreebarsLogger.log("context token refused $status")
        val reason = runCatching { JSONObject(body).optString("error") }.getOrNull()
        return ContextTokenAnswer(null, signatureRequired = status == 403 && reason == "signature_required")
    }

    /**
     * A post that proves who is asking as a sign-in proves it: the write key, this device's secret, and
     * the backend's signature of the account when one is held.
     *
     * Shared by [postIdentify] and [postContextToken] because a token asks for exactly the credentials a
     * sign-in does, so the headers that pass one have to be the headers that pass the other, and two
     * copies of them would drift the first time either moved.
     *
     * Its own connection rather than [post], because both callers read a refusal's body.
     *
     * @return the status, and the body whichever stream it came on.
     */
    private fun postAsDevice(
        path: String,
        payload: JSONObject,
        signature: String?,
        connectTimeoutMs: Int,
        readTimeoutMs: Int,
    ): Pair<Int, String> {
        val connection = URL("${baseUrl.trimEnd('/')}$path").openConnection() as HttpURLConnection

        return try {
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.connectTimeout = connectTimeoutMs
            connection.readTimeout = readTimeoutMs
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty(TreebarsConstants.WRITE_KEY_HEADER, writeKey)
            deviceSecret?.let { connection.setRequestProperty(TreebarsConstants.DEVICE_AUTH_HEADER, it()) }
            signature?.let { connection.setRequestProperty(TreebarsConstants.USER_SIGNATURE_HEADER, it) }
            connection.outputStream.use { it.write(payload.toString().toByteArray()) }

            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            status to (stream?.bufferedReader()?.use { it.readText() } ?: "")
        } finally {
            connection.disconnect()
        }
    }

    /*
     * The reads: the in-app queue, in-app bodies, the trigger list and notification history.
     *
     * A read carries the write key *and* a per-device secret. The key is public — it ships
     * in the APK — and these routes return content: rendered messages carrying whatever
     * personalization a campaign put in them, and a person's notification history.
     *
     * Still `HttpURLConnection`, for the reason at the top of this file: an analytics SDK
     * is a dependency in somebody else's app, and adding OkHttp for one GET would risk a
     * version conflict for nothing.
     */

    /**
     * A content read, or null on any refusal. Never throws at the caller.
     *
     * @param secret the device secret, or null for the one read that authenticates nothing with it —
     *   the trigger list, which belongs to the environment.
     * @param userId the signed-in person's account id, when there is one, and [signature] the
     *   signature from the app's backend that goes with it. Both headers rather than parameters, so
     *   neither sits in a URL a log or a proxy keeps — an account id is often an email.
     */
    private fun get(
        path: String,
        query: Map<String, String>,
        secret: String?,
        userId: String? = null,
        signature: String? = null,
    ): JSONObject? {
        val encoded = query.entries.joinToString("&") { (key, value) ->
            "$key=${URLEncoder.encode(value, "UTF-8")}"
        }
        val connection =
            URL("${baseUrl.trimEnd('/')}$path?$encoded").openConnection() as HttpURLConnection

        return try {
            connection.requestMethod = "GET"
            connection.connectTimeout = 10_000
            connection.readTimeout = 15_000
            connection.setRequestProperty(TreebarsConstants.WRITE_KEY_HEADER, writeKey)
            secret?.let { connection.setRequestProperty(TreebarsConstants.DEVICE_AUTH_HEADER, it) }
            userId?.let { connection.setRequestProperty(TreebarsConstants.USER_ID_HEADER, userIdHeaderValue(it)) }
            signature?.let { connection.setRequestProperty(TreebarsConstants.USER_SIGNATURE_HEADER, it) }

            if (connection.responseCode != 200) {
                // Logged rather than swallowed: a refused read is not an empty answer, and a
                // silent catch would make the two look the same.
                TreebarsLogger.log("read refused ${connection.responseCode} for $path")
                null
            } else {
                JSONObject(connection.inputStream.bufferedReader().use { it.readText() })
            }
        } catch (error: Exception) {
            TreebarsLogger.log("read failed for $path: $error")
            null
        } finally {
            connection.disconnect()
        }
    }

    /** This device's queued in-app messages. */
    fun getInApp(deviceId: String, secret: String, userId: String?, signature: String?): JSONObject? {
        val query = mapOf("device_id" to deviceId)
        return get(TreebarsConstants.IN_APP_PATH, query, secret, userId, signature.takeIf { userId != null })
    }

    /**
     * One in-app body the sync handed over by reference (`html_ref`): `{ "html": … }`, behind the
     * same device gate as the sync.
     */
    fun getInAppBody(deviceId: String, secret: String, userId: String?, signature: String?, deliveryId: String): JSONObject? {
        val query = mapOf("device_id" to deviceId, "delivery_id" to deliveryId)
        return get(TreebarsConstants.IN_APP_BODY_PATH, query, secret, userId, signature.takeIf { userId != null })
    }

    /**
     * A game's answer: `claimReward(pool)` for this device's person, in the campaign of [deliveryId] —
     * `{ won, prize?, prize_id?, code?, empty? }` with the status that answered it, or no answer and the status that
     * refused it (-1 when there was no answer), with its `Retry-After` for [claimWithRetries]. A POST behind the sync's
     * gate: the device secret, and the signed-in account. One attempt; asking again is the caller's.
     */
    fun postInAppReward(deviceId: String, secret: String, userId: String?, signature: String?, deliveryId: String, pool: String): RewardAttempt {
        val connection = URL("${baseUrl.trimEnd('/')}${TreebarsConstants.IN_APP_REWARD_PATH}").openConnection() as HttpURLConnection
        return try {
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.connectTimeout = 10_000
            connection.readTimeout = 15_000
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty(TreebarsConstants.WRITE_KEY_HEADER, writeKey)
            connection.setRequestProperty(TreebarsConstants.DEVICE_AUTH_HEADER, secret)
            userId?.let { connection.setRequestProperty(TreebarsConstants.USER_ID_HEADER, userIdHeaderValue(it)) }
            if (userId != null) signature?.let { connection.setRequestProperty(TreebarsConstants.USER_SIGNATURE_HEADER, it) }
            val body = JSONObject().put("device_id", deviceId).put("delivery_id", deliveryId).put("pool", pool)
            connection.outputStream.use { it.write(body.toString().toByteArray()) }
            val status = connection.responseCode
            // Read before `disconnect`, which takes the headers with it.
            val retryAfter = connection.getHeaderField("Retry-After")
            if (status != 200) {
                TreebarsLogger.log("reward refused $status for $pool")
                RewardAttempt(status, retryAfter)
            } else {
                // A 200 whose body is not an answer is `failed`, not `offline`: it was answered, and asking again would
                // not help. So it is caught here rather than falling into the catch below as no answer at all.
                val answer = runCatching { JSONObject(connection.inputStream.bufferedReader().use { it.readText() }) }.getOrNull()
                RewardAttempt(status, retryAfter, answer)
            }
        } catch (error: Exception) {
            TreebarsLogger.log("reward failed for $pool: $error")
            RewardAttempt(-1)
        } finally {
            connection.disconnect()
        }
    }

    /**
     * The environment's trigger list alone: `triggers_only=1`, which returns the list without
     * touching this device's queue or marking any message fetched.
     *
     * No device secret and no user id: the list belongs to the environment, so neither would
     * authenticate anything, and a secret sent where it is not needed is one more place it can leak
     * from.
     */
    fun getTriggerEvents(deviceId: String): TriggerList? {
        val query = mapOf("device_id" to deviceId, "triggers_only" to "1")
        return TriggerList.fromJson(get(TreebarsConstants.IN_APP_PATH, query, secret = null)?.optJSONObject("trigger_events"))
    }

    /** One page of this device's notification history. */
    fun getNotifications(
        deviceId: String,
        secret: String,
        userId: String?,
        signature: String?,
        limit: Int?,
        cursor: String?,
        channels: List<String>?,
    ): JSONObject? {
        val query = buildMap {
            put("device_id", deviceId)
            limit?.let { put("limit", it.toString()) }
            cursor?.let { put("cursor", it) }
            if (!channels.isNullOrEmpty()) put("channels", channels.joinToString(","))
        }
        return get(TreebarsConstants.NOTIFICATIONS_PATH, query, secret, userId, signature.takeIf { userId != null })
    }

    /**
     * Read and dismissal, as an acknowledged write.
     *
     * Not an event, deliberately: the event queue drops a batch the server refuses as
     * malformed, to keep moving, so a lost read-mark would leave a notification unread for good.
     * This write is acknowledged and carries the device secret, because "mark everything before
     * now" cannot be taken back.
     */
    fun postNotificationState(secret: String, signature: String?, payload: JSONObject): JSONObject? {
        val connection =
            URL("${baseUrl.trimEnd('/')}/v1/notifications/state").openConnection() as HttpURLConnection

        return try {
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.connectTimeout = 10_000
            connection.readTimeout = 15_000
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty(TreebarsConstants.WRITE_KEY_HEADER, writeKey)
            connection.setRequestProperty(TreebarsConstants.DEVICE_AUTH_HEADER, secret)
            if (payload.has("user_id")) {
                signature?.let { connection.setRequestProperty(TreebarsConstants.USER_SIGNATURE_HEADER, it) }
            }
            connection.outputStream.use { it.write(payload.toString().toByteArray()) }

            if (connection.responseCode != 200) {
                TreebarsLogger.log("notifications: state write refused ${connection.responseCode}")
                null
            } else {
                JSONObject(connection.inputStream.bufferedReader().use { it.readText() })
            }
        } catch (error: Exception) {
            TreebarsLogger.log("notifications: state write failed: $error")
            null
        } finally {
            connection.disconnect()
        }
    }
}
