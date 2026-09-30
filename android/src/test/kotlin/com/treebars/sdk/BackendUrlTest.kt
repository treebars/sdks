package com.treebars.sdk

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Which addresses the SDK will send a write key, a device secret and a signed-in account to. https
 * anywhere; http only to the developer's own machine and network — the addresses a local server,
 * an emulator and a handset on the same Wi-Fi use — and nothing else. The same table as the iOS
 * SDK's `BackendURLTests`.
 */
class BackendUrlTest {

    @Test
    fun acceptsHttpsAnywhere() {
        assertTrue(BackendUrl.allows("https://ingest.treebars.com"))
        assertTrue(BackendUrl.allows("https://ingest.example.com/"))
        assertTrue(BackendUrl.allows("  https://10.0.0.5:8443  "))
    }

    @Test
    fun acceptsHttpToTheLocalStackOnly() {
        for (local in listOf(
            "http://localhost:5156",
            "http://127.0.0.1:5156",
            "http://[::1]:5156",
            // An Android emulator's name for the machine running it.
            "http://10.0.2.2:5156",
            // An mDNS name.
            "http://my-laptop.local:5156",
            // A handset on the same Wi-Fi as the laptop.
            "http://192.168.1.20:5156",
            "http://172.20.10.2:5156",
        )) {
            assertTrue(local, BackendUrl.allows(local))
        }
    }

    @Test
    fun refusesHttpToAnythingElse() {
        for (remote in listOf(
            "http://ingest.treebars.com",
            "http://8.8.8.8:5156",
            // Outside 172.16/12, and a name that merely contains a local one.
            "http://172.32.0.1",
            "http://localhost.evil.example",
            "http://local.example.com",
            "http://192.168.1.20.nip.io",
        )) {
            assertFalse(remote, BackendUrl.allows(remote))
        }
    }

    @Test
    fun refusesWhatIsNotAnAddressAtAll() {
        for (junk in listOf("", "ingest.treebars.com", "ftp://ingest.treebars.com", "https://", "not a url", "http://300.1.1.1")) {
            assertFalse(junk, BackendUrl.allows(junk))
        }
    }
}
