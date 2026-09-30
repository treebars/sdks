package com.treebars.sdk

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.treebars.sdk.generated.TreebarsConstants
import java.util.UUID
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The install-referrer latch: asked once per new install, only with consent, and never lost to a
 * busy Play Store.
 *
 * The Play service itself cannot run here, so the source is faked and what is under test is the
 * decision around it — which is where every way of getting this wrong lives. An event sent twice
 * is two installs in a report; a latch cleared on a transient failure is an install whose source
 * is gone for good, and it looks exactly like organic traffic.
 */
@RunWith(RobolectricTestRunner::class)
class AcquisitionTest {

    private fun prefs(pending: Boolean) = ApplicationProvider.getApplicationContext<Context>()
        .getSharedPreferences("acq-${UUID.randomUUID()}", Context.MODE_PRIVATE)
        .also { if (pending) it.edit().putBoolean(TreebarsConstants.KEY_ACQUISITION_PENDING, true).commit() }

    private class Recorder {
        val sent = mutableListOf<Map<String, Any?>>()
        val carried = mutableListOf<String>()
        var reads = 0
    }

    private fun capture(
        prefs: android.content.SharedPreferences,
        recorder: Recorder,
        vararg answers: ReferrerAnswer,
    ): AcquisitionCapture {
        val queue = ArrayDeque(answers.toList())
        return AcquisitionCapture(
            prefs,
            source = {
                recorder.reads += 1
                // A read takes time, which is what lets the concurrency test overlap two.
                delay(10)
                queue.removeFirstOrNull() ?: ReferrerAnswer.NotNow
            },
            send = { recorder.sent += it },
            carried = { recorder.carried += it },
        )
    }

    private val found = ReferrerAnswer.Found(mapOf("referrer" to "utm_source=tiktok&tbrs_click_id=abc"))

    @Test
    fun `nothing is read without consent, and the install stays owed`() = runTest {
        val store = prefs(pending = true)
        val recorder = Recorder()

        assertFalse(capture(store, recorder, found).settle(consented = false))

        assertEquals(0, recorder.reads)
        assertTrue(recorder.sent.isEmpty())
        // Consent given later still finds the read owed — Play keeps the referrer for ninety days.
        assertTrue(store.getBoolean(TreebarsConstants.KEY_ACQUISITION_PENDING, false))
    }

    @Test
    fun `an answer is sent once and the latch is cleared`() = runTest {
        val store = prefs(pending = true)
        val recorder = Recorder()
        val capture = capture(store, recorder, found, found)

        assertTrue(capture.settle(consented = true))
        assertFalse(capture.settle(consented = true))

        assertEquals(listOf(found.properties), recorder.sent)
        assertEquals(1, recorder.reads)
        assertFalse(store.contains(TreebarsConstants.KEY_ACQUISITION_PENDING))
    }

    @Test
    fun `a busy store keeps the latch for the next launch`() = runTest {
        /*
         * The failure this latch exists for. The first launch is exactly when the Play Store is
         * most likely to be updating itself, and an install whose first read was lost would never
         * be asked again — its source gone, filed as organic, with nothing anywhere saying so.
         */
        val store = prefs(pending = true)
        val recorder = Recorder()
        val capture = capture(store, recorder, ReferrerAnswer.NotNow, found)

        assertFalse(capture.settle(consented = true))
        assertTrue(store.getBoolean(TreebarsConstants.KEY_ACQUISITION_PENDING, false))
        assertTrue(recorder.sent.isEmpty())

        assertTrue(capture.settle(consented = true))
        assertEquals(listOf(found.properties), recorder.sent)
    }

    @Test
    fun `a device that will never have one stops asking`() = runTest {
        val store = prefs(pending = true)
        val recorder = Recorder()
        val capture = capture(store, recorder, ReferrerAnswer.Never)

        assertFalse(capture.settle(consented = true))
        assertFalse(capture.settle(consented = true))

        assertEquals(1, recorder.reads)
        assertTrue(recorder.sent.isEmpty())
        assertFalse(store.contains(TreebarsConstants.KEY_ACQUISITION_PENDING))
    }

    @Test
    fun `an install that was never owed is never read`() = runTest {
        // An install that predates this build has `first_seen_at` and no latch. Reading it would
        // report an install from last year as if it had just arrived.
        val recorder = Recorder()

        assertFalse(capture(prefs(pending = false), recorder, found).settle(consented = true))

        assertEquals(0, recorder.reads)
        assertTrue(recorder.sent.isEmpty())
    }

    @Test
    fun `two settles at once read and send once`() = runTest {
        // `initialize` settles on the way up and the host app grants consent a moment later: two
        // callers, one install, and without the lock two reads and two events.
        val store = prefs(pending = true)
        val recorder = Recorder()
        val capture = capture(store, recorder, found, found)

        val results = listOf(async { capture.settle(true) }, async { capture.settle(true) }).awaitAll()

        assertEquals(listOf(true, false), results.sortedDescending())
        assertEquals(1, recorder.reads)
        assertEquals(1, recorder.sent.size)
    }

    @Test
    fun `the event carries the referrer raw and every timestamp Play gives`() {
        val properties = referrerProperties(
            referrer = "utm_source=tiktok&tbrs_click_id=abc",
            clickSeconds = 1_700_000_000,
            installBeginSeconds = 1_700_000_060,
            clickServerSeconds = 1_700_000_001,
            installBeginServerSeconds = 1_700_000_061,
            installVersion = "1.4.0",
            googlePlayInstant = false,
        )

        // Raw: parsed in exactly one place, server side, so two readings cannot drift.
        assertEquals("utm_source=tiktok&tbrs_click_id=abc", properties["referrer"])
        assertEquals(
            setOf(
                "referrer",
                "referrer_click_timestamp_seconds",
                "install_begin_timestamp_seconds",
                "referrer_click_timestamp_server_seconds",
                "install_begin_timestamp_server_seconds",
                "install_version",
                "google_play_instant",
            ),
            properties.keys,
        )
        // A null referrer is an empty string rather than a missing property, so "Play answered
        // with nothing" and "the property was dropped" cannot be confused downstream.
        assertEquals("", referrerProperties(null, 0, 0, 0, 0, null, false)["referrer"])
    }

    // --- Deferred deep linking ------------------------------------------------------------

    @Test
    fun `the path the link carried is read out of the referrer`() {
        // As `URLSearchParams.toString()` writes it: the slashes percent-encoded.
        assertEquals(
            "/sale/summer",
            deepLinkPathFrom("utm_source=tiktok&tbrs_deep_link=%2Fsale%2Fsummer&tbrs_click_id=abc"),
        )
        // A query of its own is the app's business, and an encoded one arrives exactly as stored:
        // encoding the path into the referrer turns its `%20` into `%2520`, and one decode gives it back.
        assertEquals("/search?q=red%20shoes", deepLinkPathFrom("tbrs_deep_link=%2Fsearch%3Fq%3Dred%2520shoes"))
        // A `+` is a space in this encoding, and a path holding a literal space is refused — as
        // Treebars refuses it when a link is saved, and as the iOS SDK would, where `URL(string:)` is
        // nil for one. So a referrer carrying one was not written by Treebars.
        assertEquals(null, deepLinkPathFrom("tbrs_deep_link=%2Fsearch%3Fq%3Dred+shoes"))
        assertEquals(null, deepLinkPathFrom("utm_source=tiktok&tbrs_click_id=abc"))
        assertEquals(null, deepLinkPathFrom(""))
        assertEquals(null, deepLinkPathFrom(null))
    }

    @Test
    fun `a referrer naming somewhere OUTSIDE the app is refused`() {
        /*
         * The check that matters. The referrer arrives from a service on a device the app does not
         * control, and the app routes on whatever it is handed — so a value that is a URL rather
         * than a path would turn a link's own settings field into a way out of the app, aimed at
         * everybody who installs from it.
         */
        for (hostile in listOf(
            "https%3A%2F%2Fevil.example%2Fx",
            "intent%3A%2F%2Fevil",
            "%2F%2Fevil.example%2Fx",
            "sale%2Fsummer",
            "%5Cevil",
            "%2Fsale%2F%09summer",
        )) {
            assertNull(hostile, deepLinkPathFrom("tbrs_deep_link=$hostile"))
        }
        // A path longer than the cap a link's destination is held to, and a broken escape sequence.
        assertEquals(null, deepLinkPathFrom("tbrs_deep_link=%2F" + "a".repeat(600)))
        assertEquals(null, deepLinkPathFrom("tbrs_deep_link=%2"))
    }

    @Test
    fun `the destination is handed over before the event is queued`() = runTest {
        // Before, because the person is waiting on this and not on the event — and a send that
        // threw must not be what decides whether they land on the right screen.
        val store = prefs(pending = true)
        val recorder = Recorder()
        val withPath = ReferrerAnswer.Found(mapOf("referrer" to "tbrs_click_id=abc&tbrs_deep_link=%2Fsale"))

        assertTrue(capture(store, recorder, withPath).settle(consented = true))

        assertEquals(listOf("/sale"), recorder.carried)
        assertEquals(1, recorder.sent.size)
    }

    @Test
    fun `a referrer with no destination hands over nothing`() = runTest {
        val recorder = Recorder()
        assertTrue(capture(prefs(pending = true), recorder, found).settle(consented = true))
        assertTrue(recorder.carried.isEmpty())
    }

    @Test
    fun `the destination is delivered once, and never again`() {
        // Without this every launch reopens the sale somebody bought from three weeks ago.
        val store = prefs(pending = false)
        val link = DeferredDeepLink(store)
        val installedAt = 1_700_000_000_000L

        link.remember("/sale/summer")

        assertEquals("/sale/summer", link.take(installedAt, installedAt + 60_000))
        assertEquals(null, link.take(installedAt, installedAt + 120_000))
    }

    @Test
    fun `a second destination never displaces the one already waiting`() {
        // There is only one install, so there is only one answer to where it came from.
        val link = DeferredDeepLink(prefs(pending = false))
        link.remember("/sale/summer")
        link.remember("/something/else")
        assertEquals("/sale/summer", link.take(1_000L, 2_000L))
    }

    @Test
    fun `a destination older than the window is dropped rather than opened`() {
        /*
         * The other half of "once". An app that adds a listener in a later version must not throw
         * its whole installed base into a sale that ended — so the window is the install's age,
         * and it is checked when the path is taken rather than when it was stored.
         */
        val link = DeferredDeepLink(prefs(pending = false))
        val installedAt = 1_700_000_000_000L
        link.remember("/sale/summer")

        assertEquals(null, link.take(installedAt, installedAt + TreebarsConstants.DEFERRED_DEEP_LINK_WINDOW_MS + 1))
        // And dropped for good, rather than re-deciding the same expiry on every launch forever.
        assertEquals(null, link.take(installedAt, installedAt + 1_000))
    }

    @Test
    fun `an install with no first-seen moment is not inside any window`() {
        // The two are written in one edit, so this cannot happen — and guessing would be the
        // expensive side of a pair where refusing costs one deep link.
        val link = DeferredDeepLink(prefs(pending = false))
        link.remember("/sale/summer")
        assertEquals(null, link.take(null, 1_700_000_000_000L))
    }

    @Test
    fun `a stored value that is not a path is refused on the way out too`() {
        /*
         * Belt and braces, and the braces are the point: the check on the way IN is the only thing
         * standing between a store's answer and the host app's router, and a stored value can also
         * be reached by anything with this app's preferences.
         */
        val store = prefs(pending = false)
        store.edit().putString(TreebarsConstants.KEY_DEFERRED_DEEP_LINK, "https://evil.example/x").commit()
        assertEquals(null, DeferredDeepLink(store).take(1_000L, 2_000L))
    }
}
