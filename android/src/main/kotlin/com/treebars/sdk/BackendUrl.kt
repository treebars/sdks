package com.treebars.sdk

import java.net.URI

/**
 * Whether an address may carry this SDK's traffic: https anywhere, and plain http only to a
 * machine on the developer's own desk.
 *
 * Every request carries the write key and the device's secret, and a signed-in one carries the
 * account id and the signature that proves it. Over http all four would cross every network between
 * the handset and the server in the clear. Android's own cleartext default is not enough to prevent
 * that: it applies only to apps that have not turned cleartext on, and an app that turns it on for
 * a development server has turned it on for every host.
 *
 * Local means what a development machine and an emulator actually use: loopback, `10.0.2.2` (an
 * emulator's name for the host), a `.local` mDNS name, and the private ranges a handset on the same
 * Wi-Fi reaches a laptop by. Anything else over http is refused and the SDK stays off, saying why —
 * the same answer the iOS SDK's `BackendURL` gives.
 */
internal object BackendUrl {
    fun allows(url: String): Boolean {
        val uri = runCatching { URI(url.trim()) }.getOrNull() ?: return false
        val host = uri.host?.lowercase()?.removePrefix("[")?.removeSuffix("]")
        if (host.isNullOrEmpty()) return false
        return when (uri.scheme?.lowercase()) {
            "https" -> true
            "http" -> isLocal(host)
            else -> false
        }
    }

    /** A host on this machine or its own network — never one a request would cross the internet to reach. */
    fun isLocal(host: String): Boolean {
        if (host == "localhost" || host.endsWith(".localhost") || host.endsWith(".local")) return true
        if (host == "::1") return true
        val parts = host.split('.')
        if (parts.size != 4) return false
        val octets = parts.map { part -> part.toIntOrNull()?.takeIf { it in 0..255 } ?: return false }
        val first = octets[0]
        val second = octets[1]
        return first == 127 ||
            first == 10 ||
            (first == 172 && second in 16..31) ||
            (first == 192 && second == 168)
    }
}
