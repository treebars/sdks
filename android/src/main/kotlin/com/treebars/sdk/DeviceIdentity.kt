package com.treebars.sdk

import java.io.File
import java.security.SecureRandom
import java.util.UUID

/** The device's pseudonymous id and the secret that proves it — one pair, kept and lost together. */
internal data class DeviceIdentity(val id: String, val secret: String)

/** A first-party random id, not a hardware identifier: clearing app data genuinely resets it. */
internal fun mintDeviceId(): String = "dev_${UUID.randomUUID()}"

/** 32 bytes from the platform CSPRNG, as hex: what the content routes are read with. */
internal fun mintDeviceSecret(): String {
    val bytes = ByteArray(32)
    SecureRandom().nextBytes(bytes)
    return bytes.joinToString("") { "%02x".format(it) }
}

/**
 * Where the pair lives: one file in `noBackupFilesDir`, which Android's Auto Backup and its
 * device-to-device transfer both leave behind.
 *
 * Not SharedPreferences, which Auto Backup copies by default: restored onto a second phone, the pair
 * would make two handsets one device — both sending events under one id, reading one in-app queue
 * and notification history, with their push tokens registered against one device. A library cannot
 * set the app's backup rules; it can keep its own state out of them, and this is the directory
 * Android provides for it.
 *
 * One file for both, so they can only ever be lost together: an id without the secret that goes
 * with it cannot read that device's content. A phone restored from a backup starts as a new
 * device, which is what it is.
 */
internal class DeviceIdentityStore(private val dir: File) {
    private val file: File get() = File(dir, FILE_NAME)

    /** The pair on file, or null — nothing there, or nothing readable, which a caller cannot tell apart. */
    fun read(): DeviceIdentity? = runCatching {
        if (!file.exists()) return null
        val lines = file.readLines().map(String::trim)
        val id = lines.getOrNull(0)?.takeIf { it.isNotEmpty() } ?: return null
        val secret = lines.getOrNull(1)?.takeIf { it.isNotEmpty() } ?: return null
        DeviceIdentity(id, secret)
    }.getOrNull()

    /**
     * Written whole or not at all: a half-written pair would be a device without its secret. False when
     * it did not land — a full disk, a directory that cannot be made — and never an exception: this runs
     * inside `initialize`, where one would be the host app's crash at launch.
     */
    fun write(identity: DeviceIdentity): Boolean = runCatching {
        dir.mkdirs()
        val temp = File(dir, "$FILE_NAME.tmp")
        temp.writeText("${identity.id}\n${identity.secret}\n")
        if (!temp.renameTo(file)) {
            file.writeText(temp.readText())
            temp.delete()
        }
    }.isSuccess

    fun erase() {
        file.delete()
    }

    /**
     * This device's pair: the one on file, else [adopted] — what a wrapper handed down from a store
     * this core cannot read — else a new one. Written before it is returned, so everything that
     * reads it afterwards agrees. The second value says whether the pair is new to this install.
     */
    fun resolve(adopted: DeviceIdentity? = null): Pair<DeviceIdentity, Boolean> {
        read()?.let { return it to false }
        val identity = adopted ?: DeviceIdentity(mintDeviceId(), mintDeviceSecret())
        // Unsaved, it is still this process's pair; the next launch starts as a new device, as on iOS.
        if (!write(identity)) {
            TreebarsLogger.warn("the device identity could not be written; this install will be a new device next launch")
        }
        return identity to true
    }

    companion object {
        const val FILE_NAME = "treebars_device_identity"
    }
}
