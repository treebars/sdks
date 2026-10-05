package com.treebars.sdk

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.treebars.sdk.generated.TreebarsBridge
import com.treebars.sdk.generated.TreebarsConstants
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/*
 * The two pure halves of in-app on the device: which message may be shown, and when.
 *
 * Both fail silently, which is why they are worth pinning here rather than trusting to an
 * end-to-end run. A trigger that stops matching produces no error anywhere — the message
 * simply never appears, which is indistinguishable from a campaign nobody qualified for.
 * And a cap that miscounts shows too many messages to real people before anyone notices.
 *
 * A message capped at three a day has to mean the same thing on every platform, so these
 * assertions are deliberately the same ones the other SDKs answer to; a divergence would
 * otherwise go unnoticed until somebody compared two screenshots.
 */
@RunWith(RobolectricTestRunner::class)
class InAppTest {

    private val context: Context get() = ApplicationProvider.getApplicationContext()

    // `InAppStore` loads its queue and its ledger in its constructor, so a preferences file
    // shared between tests would let one test's displays decide another's cap.
    private fun store() = InAppStore(context, "treebars.inapp.${UUID.randomUUID()}")

    private fun messageJson(
        deliveryId: String = "del_1",
        expiresAt: String? = null,
        surface: String = "overlay",
        maxDisplays: Int? = null,
    ): JSONObject {
        val inApp = JSONObject()
            .put("surface", surface)
            .put("layout", "modal")
            .put("trigger", JSONObject().put("kind", "session_start"))
        if (maxDisplays != null) inApp.put("max_displays", maxDisplays)
        return JSONObject()
            .put("delivery_id", deliveryId)
            .put("campaign_id", "cmp_1")
            .put("created_at", "2026-01-01T00:00:00.000Z")
            .put("expires_at", expiresAt ?: JSONObject.NULL)
            .put("content", JSONObject().put("title", "Hello").put("in_app", inApp))
    }

    private fun responseJson(
        messages: List<JSONObject> = listOf(messageJson()),
        maxPerDay: Int? = null,
        minGapSeconds: Int? = null,
        shownToday: Int = 0,
        lastShownAt: String? = null,
    ): JSONObject = JSONObject()
        .put("messages", JSONArray().apply { messages.forEach { put(it) } })
        .put(
            "policy",
            JSONObject()
                .put("max_per_day", maxPerDay ?: JSONObject.NULL)
                .put("min_gap_seconds", minGapSeconds ?: JSONObject.NULL)
                .put("messages_shown_today", shownToday)
                .put("last_shown_at", lastShownAt ?: JSONObject.NULL),
        )
        .put("server_time", Iso8601.now())

    /** The parsed message, rather than a hand-built one, so the wire shape is under test too. */
    private fun InAppStore.message(deliveryId: String) = list().first { it.deliveryId == deliveryId }

    // --- inAppTriggerMatches ------------------------------------------------------------

    @Test
    fun `session_start fires on either of the two events that mean the app opened`() {
        val trigger = InAppTrigger("session_start", null, null)

        assertTrue(inAppTriggerMatches(trigger, "session_start", emptyMap(), null))
        assertTrue(inAppTriggerMatches(trigger, "app_open", emptyMap(), null))
        assertFalse(inAppTriggerMatches(trigger, "add_to_cart", emptyMap(), null))
    }

    @Test
    fun `a screen is matched by the name the app reports, case included`() {
        val trigger = InAppTrigger("screen_view", "Cart", null)

        assertTrue(inAppTriggerMatches(trigger, "screen_view", emptyMap(), "Cart"))
        // Not normalised, deliberately: this is the host app's own vocabulary and we are in
        // no position to decide that "cart" meant "Cart".
        assertFalse(inAppTriggerMatches(trigger, "screen_view", emptyMap(), "cart"))
        assertFalse(inAppTriggerMatches(trigger, "screen_view", emptyMap(), "Checkout"))
    }

    @Test
    fun `the screen is read from the properties when the SDK has no current screen`() {
        val trigger = InAppTrigger("screen_view", "Cart", null)

        assertTrue(inAppTriggerMatches(trigger, "screen_view", mapOf("screen_name" to "Cart"), null))
    }

    @Test
    fun `an event trigger matches on the event name`() {
        val trigger = InAppTrigger("event", null, "purchase")

        assertTrue(inAppTriggerMatches(trigger, "purchase", mapOf("value" to 80), null))
        assertFalse(inAppTriggerMatches(trigger, "refund", mapOf("value" to 80), null))
        // The name is all this case reads: the trigger carries no property filters, and
        // those are pinned in `InAppFilterTest`.
    }

    @Test
    fun `an unrecognised trigger kind is no match rather than a pass`() {
        // A kind added server-side and not ported here must fail closed: showing a message
        // to people who do not qualify is worse than showing it to nobody.
        assertFalse(inAppTriggerMatches(InAppTrigger("geofence", null, null), "purchase", emptyMap(), null))
    }

    // --- InAppStore.allows --------------------------------------------------------------

    // --- the caps this device counts -------------------------------------------------------

    private fun cappedMessage(id: String, kind: String, ignoreMinGap: Boolean = false): JSONObject {
        val json = messageJson(deliveryId = id)
        val inApp = json.getJSONObject("content").getJSONObject("in_app")
        inApp.put("trigger", JSONObject().put("kind", kind).put("event_name", "purchase"))
        if (ignoreMinGap) inApp.put("ignore_min_gap", true)
        return json
    }

    @Test
    fun `the session cap stops a second draw and a new session starts again`() {
        val store = store()
        val response = responseJson(messages = listOf(cappedMessage("a", "screen_view"), cappedMessage("b", "screen_view")))
        response.getJSONObject("policy").put("max_per_session", 1)
        store.accept(response)
        store.recordDisplay(store.message("a"), "s1")
        assertFalse(store.allows(store.message("b"), "s1"))
        assertTrue(store.allows(store.message("b"), "s2"))
    }

    @Test
    fun `a trigger kind's day cap counts messages of that kind only, and a repeat spends nothing`() {
        val store = store()
        val response = responseJson(messages = listOf(cappedMessage("a", "event"), cappedMessage("b", "event"), cappedMessage("c", "session_start")))
        response.getJSONObject("policy").put("trigger_max_per_day", JSONObject().put("event", 1))
        store.accept(response)
        val now = System.currentTimeMillis()
        store.recordDisplay(store.message("a"), "s1", now)
        assertFalse(store.allows(store.message("b"), "s1", now))
        assertTrue(store.allows(store.message("a"), "s1", now))
        assertTrue(store.allows(store.message("c"), "s1", now))
        assertTrue(store.allows(store.message("b"), "s1", now + 36 * 3_600_000L))
    }

    @Test
    fun `a message that ignores the minimum gap is let through it`() {
        val store = store()
        store.accept(responseJson(messages = listOf(cappedMessage("a", "immediate"), cappedMessage("b", "immediate"), cappedMessage("u", "immediate", ignoreMinGap = true)), minGapSeconds = 600))
        store.recordDisplay(store.message("a"), "s1")
        assertFalse(store.allows(store.message("b"), "s1"))
        assertTrue(store.allows(store.message("u"), "s1"))
    }

    @Test
    fun `a test send is drawn past every cap, and still not once it is done`() {
        val store = store()
        val test = cappedMessage("t", "immediate").put("test", true)
        val response = responseJson(messages = listOf(cappedMessage("a", "immediate"), cappedMessage("b", "immediate"), test), maxPerDay = 1, minGapSeconds = 600)
        response.getJSONObject("policy").put("max_per_session", 1).put("trigger_max_per_day", JSONObject().put("immediate", 1))
        store.accept(response)
        store.recordDisplay(store.message("a"), "s1")
        assertFalse(store.allows(store.message("b"), "s1"))
        assertTrue(store.allows(store.message("t"), "s1"))
        store.markDone("t")
        assertEquals("done", store.blockedBy(store.message("t"), "s1"))
    }

    @Test
    fun `an ordinary message is permitted`() {
        val store = store()
        store.accept(responseJson())

        assertTrue(store.allows(store.message("del_1")))
    }

    @Test
    fun `one that has expired is refused without waiting for the server to say so`() {
        val store = store()
        store.accept(responseJson(listOf(messageJson(expiresAt = "2020-01-01T00:00:00.000Z"))))

        assertFalse(store.allows(store.message("del_1")))
    }

    /*
     * One clock per call. A caller that passes `now` is answered against it for every rule, so a moment can be asked
     * about exactly — the instant before an expiry, the second a gap ends — whatever the device's own clock reads.
     * Both expiries below sit far from any date this runs on, one each side of it.
     */
    @Test
    fun `expiry is read against the clock the caller passes`() {
        val store = store()
        val longAgo = 1_000_000_000_000L
        val farAhead = 4_000_000_000_000L
        store.accept(responseJson(listOf(messageJson("old", expiresAt = Iso8601.at(longAgo)), messageJson("new", expiresAt = Iso8601.at(farAhead)))))

        assertNull(store.blockedBy(store.message("old"), now = longAgo - 1))
        assertEquals("expired", store.blockedBy(store.message("old"), now = longAgo))
        assertNull(store.blockedBy(store.message("new"), now = farAhead - 1))
        assertEquals("expired", store.blockedBy(store.message("new"), now = farAhead))
    }

    @Test
    fun `the gap after a display is measured from the clock the display was recorded with`() {
        val store = store()
        store.accept(responseJson(messages = listOf(messageJson("a"), messageJson("b")), minGapSeconds = 600))
        val shownAt = 1_000_000_000_000L
        store.recordDisplay(store.message("a"), "s1", shownAt)

        assertEquals("min_gap", store.blockedBy(store.message("b"), "s1", shownAt + 599_999L))
        assertNull(store.blockedBy(store.message("b"), "s1", shownAt + 600_000L))
    }

    @Test
    fun `displays stop at max_displays for this device`() {
        val store = store()
        store.accept(responseJson(listOf(messageJson(maxDisplays = 2))))
        val message = store.message("del_1")

        assertTrue(store.allows(message))
        store.recordDisplay(message)
        assertTrue(store.allows(message))
        store.recordDisplay(message)
        assertFalse(store.allows(message))
    }

    @Test
    fun `the daily cap counts messages, not showings`() {
        val store = store()
        store.accept(
            responseJson(
                messages = listOf(messageJson("a", maxDisplays = 5), messageJson("b")),
                maxPerDay = 1,
            ),
        )

        store.recordDisplay(store.message("a"))
        // Showing the same message again is not a second message, so the allowance is intact
        // for it — that is what max_displays governs instead.
        assertTrue(store.allows(store.message("a")))
        // A different message would be the second one today, and the cap is one.
        assertFalse(store.allows(store.message("b")))
    }

    @Test
    fun `this device's displays are added to what the server already counted`() {
        val store = store()
        store.accept(
            responseJson(
                messages = listOf(messageJson("a"), messageJson("b")),
                maxPerDay = 2,
                // Another device of theirs showed one earlier; the cap is two.
                shownToday = 1,
            ),
        )

        assertTrue(store.allows(store.message("a")))
        store.recordDisplay(store.message("a"))
        assertFalse(store.allows(store.message("b")))
    }

    @Test
    fun `the minimum gap is taken from whichever device showed one most recently`() {
        val store = store()
        store.accept(
            responseJson(
                messages = listOf(messageJson("a")),
                minGapSeconds = 600,
                shownToday = 1,
                lastShownAt = Iso8601.at(System.currentTimeMillis() - 60_000),
            ),
        )

        assertFalse(store.allows(store.message("a")))
    }

    @Test
    fun `one this device is finished with is refused`() {
        val store = store()
        store.accept(responseJson(listOf(messageJson("a"))))

        store.markDone("a")

        assertFalse(store.allows(store.message("a")))
    }

    // --- InAppStore.accept --------------------------------------------------------------

    @Test
    fun `a sync replaces the queue and keeps the ledger`() {
        val store = store()
        store.accept(responseJson(listOf(messageJson("a", maxDisplays = 1))))
        store.recordDisplay(store.message("a"))

        // The server does not know this device is finished with it — that is device-scoped
        // state — so a re-sync returning the same message must not make it showable again.
        store.accept(responseJson(listOf(messageJson("a", maxDisplays = 1))))

        assertFalse(store.allows(store.message("a")))
    }

    @Test
    fun `the inbox is separated from the overlay surface`() {
        val store = store()
        store.accept(responseJson(listOf(messageJson("a"), messageJson("b", surface = "inbox"))))

        assertEquals(listOf("b"), store.inbox().map { it.deliveryId })
        assertEquals(2, store.list().size)
    }

    // --- a sync that outlives its sign-in ---------------------------------------------------

    /*
     * A launch's sync for the previous person that lands after reset() has emptied the store must not put their queue
     * back: the ledger that would have held it back is already gone, and it would be drawn on the signed-out screen.
     */
    @Test
    fun `drops a sync asked for before a sign-out`() {
        val store = store()
        val asked = store.generation
        store.reset()

        assertFalse(store.accept(responseJson(listOf(messageJson("stale"))), asked))
        assertEquals(emptyList<InAppMessage>(), store.list())

        // The next sync, asked after it, is the new person's and lands.
        assertTrue(store.accept(responseJson(listOf(messageJson("fresh"))), store.generation))
        assertEquals(listOf("fresh"), store.list().map { it.deliveryId })
    }

    @Test
    fun `drops a sync asked for before somebody else signed in`() {
        val store = store()
        val asked = store.generation
        store.supersede()
        assertFalse(store.accept(responseJson(listOf(messageJson("previous"))), asked))
        assertEquals(emptyList<InAppMessage>(), store.list())
    }

    @Test
    fun `holds nothing of the last person once somebody else signed in`() {
        val store = store()
        assertTrue(store.accept(responseJson(listOf(messageJson("theirs"))), store.generation))
        assertEquals(listOf("theirs"), store.list().map { it.deliveryId })

        store.supersede()

        assertEquals(emptyList<InAppMessage>(), store.list())
        assertEquals(emptyList<String>(), store.inbox().map { it.deliveryId })
    }

    // --- the self-trigger guard ---------------------------------------------------------

    /*
     * `in_app_displayed` leaves through the same track() as every other event, and a message
     * triggered on `immediate` matches anything. Without the IN_APP_EVENTS guard in
     * Treebars.track, showing one message shows it again, and again — a loop that would look
     * like an SDK bug on a device and like a flood of events on the server.
     */
    @Test
    fun `an immediate trigger would otherwise match the SDK's own display report`() {
        // Proving the hazard is real, so the guard is not cargo-culted.
        assertTrue(inAppTriggerMatches(InAppTrigger("immediate", null, null), "in_app_displayed", emptyMap(), null))
    }

    @Test
    fun `every event the guard has to cover matches an immediate trigger`() {
        // If a fourth in-app event is added and not listed in each SDK's guard, this is the
        // test that should have caught it.
        for (name in listOf("in_app_displayed", "in_app_clicked", "in_app_dismissed")) {
            assertTrue(name, inAppTriggerMatches(InAppTrigger("immediate", null, null), name, emptyMap(), null))
        }
    }

    // The app going away is never a moment to draw: an immediate trigger matches it, so the guard must.
    @Test
    fun `the app's own leaving events are never a moment to draw, though an immediate trigger matches them`() {
        for (name in listOf("app_background", "session_end")) {
            assertTrue(name, inAppTriggerMatches(InAppTrigger("immediate", null, null), name, emptyMap(), null))
            assertTrue(name, isLeavingEvent(name))
        }
        for (name in listOf("app_foreground", "app_open", "session_start", "screen_view", "purchase")) {
            assertFalse(name, isLeavingEvent(name))
        }
    }

    // One overlay at a time, however many threads ask.
    @Test
    fun onlyOneOfManyConcurrentClaimsTakesTheScreen() {
        val slot = PresentationSlot(holdMs = 30_000)
        val granted = java.util.concurrent.atomic.AtomicInteger()
        val start = java.util.concurrent.CountDownLatch(1)
        val threads = (1..32).map {
            Thread {
                start.await()
                if (slot.claim()) granted.incrementAndGet()
            }.also { it.start() }
        }
        start.countDown()
        threads.forEach { it.join() }
        assertEquals(1, granted.get())
        assertTrue(slot.isHeld())
    }

    @Test
    fun theScreenIsFreeAgainOnAnAnswerOrOnceTheHoldIsOut() {
        val slot = PresentationSlot(holdMs = 30_000)
        assertTrue(slot.claim(now = 1_000))
        assertFalse(slot.claim(now = 30_999))
        assertTrue(slot.claim(now = 31_001))
        slot.release()
        assertFalse(slot.isHeld())
        assertTrue(slot.claim())
    }

    // The SDK's own HTML host reports every ending, so its claim outlasts the hold.
    @Test
    fun aClaimUntilReleasedOutlastsTheHold() {
        val slot = PresentationSlot(holdMs = 30_000)
        assertTrue(slot.claim(now = 1_000, untilReleased = true))
        assertTrue(slot.isHeld(now = 3_601_000))
        assertFalse(slot.claim(now = 3_601_000))
        slot.releaseUnpinned()
        assertTrue(slot.isHeld(now = 3_601_000))
        slot.release()
        assertTrue(slot.claim(now = 3_602_000))
        assertFalse(slot.isHeld(now = 3_633_000))
    }

    /*
     * A delayed message whose delay ends while another holds the screen waits, and is judged by
     * the caps once the screen is free.
     */
    @Test
    fun `a delayed message waits for the screen rather than being dropped`() {
        assertEquals(DelayedInApp.Wait, delayedInAppStep(blocked = null, hasRenderer = true, screenHeld = true))
        // Held back by a cap only it would trip is still a wait while the other is up: the screen is asked first.
        assertEquals(DelayedInApp.Wait, delayedInAppStep(blocked = "min_gap", hasRenderer = true, screenHeld = true))
        assertEquals(DelayedInApp.Present, delayedInAppStep(blocked = null, hasRenderer = true, screenHeld = false))
    }

    @Test
    fun `a delayed message the caps or the app refuse is reported, except one already done`() {
        assertEquals(DelayedInApp.Drop("min_gap"), delayedInAppStep(blocked = "min_gap", hasRenderer = true, screenHeld = false))
        assertEquals(DelayedInApp.Drop(null), delayedInAppStep(blocked = "done", hasRenderer = true, screenHeld = false))
        assertEquals(DelayedInApp.Drop("no_renderer"), delayedInAppStep(blocked = null, hasRenderer = false, screenHeld = false))
    }

    /*
     * The loop itself, on a fake clock: a queue of scheduled looks the test runs by hand,
     * and the SDK's state as plain fields. The decision tests above cannot see the loop's own
     * failures — a wait that never re-arms, a present that loses the slot and is forgotten, a cap
     * that closes mid-wait and is never reported.
     */
    private class FakeDelayed {
        val scheduled = ArrayDeque<Pair<Long, () -> Unit>>()
        var waiting = true
        var held = 0
        var blocked: String? = null
        var claimRefusals = 0
        var presented = 0
        val reports = mutableListOf<String>()
        val loop = DelayedInAppLoop(
            schedule = { ms, tick -> scheduled.addLast(ms to tick) },
            stillWaiting = { waiting },
            blockedBy = { blocked },
            hasRenderer = { true },
            // Held for the next `held` looks, then free.
            screenHeld = { (held > 0).also { if (it) held -= 1 } },
            present = { if (claimRefusals > 0) { claimRefusals -= 1; false } else { presented += 1; true } },
            finish = { waiting = false },
            report = { reports += it },
        )

        /** Runs the next scheduled look, asserting it was scheduled at the retry interval. */
        fun advance() {
            val (ms, tick) = scheduled.removeFirst()
            assertEquals(DELAYED_IN_APP_RETRY_MS, ms)
            tick()
        }
    }

    @Test
    fun `the delayed loop waits out a busy screen and presents once`() {
        val fake = FakeDelayed().apply { held = 2 }
        fake.loop.tick()
        assertEquals(0, fake.presented)
        fake.advance()
        assertEquals(0, fake.presented)
        fake.advance()
        assertEquals(1, fake.presented)
        assertFalse(fake.waiting)
        assertTrue(fake.scheduled.isEmpty())
        assertEquals(emptyList<String>(), fake.reports)
    }

    @Test
    fun `the delayed loop reports a cap that closes mid-wait and does not present`() {
        val fake = FakeDelayed().apply { held = 1 }
        fake.loop.tick()
        fake.blocked = "min_gap"
        fake.advance()
        assertEquals(0, fake.presented)
        assertEquals(listOf("min_gap"), fake.reports)
        assertFalse(fake.waiting)
        assertTrue(fake.scheduled.isEmpty())
    }

    @Test
    fun `the delayed loop looks again when another message takes the slot first`() {
        val fake = FakeDelayed().apply { claimRefusals = 1 }
        fake.loop.tick()
        assertEquals(0, fake.presented)
        fake.advance()
        assertEquals(1, fake.presented)
        assertTrue(fake.scheduled.isEmpty())
    }

    @Test
    fun `the delayed loop stops without a word once the message is no longer the one waiting`() {
        val fake = FakeDelayed().apply { held = 1 }
        fake.loop.tick()
        fake.waiting = false // reset(), or a new person, mid-wait
        fake.advance()
        assertEquals(0, fake.presented)
        assertEquals(emptyList<String>(), fake.reports)
        assertTrue(fake.scheduled.isEmpty())
    }

    /* Every receipt names the campaign; only a link is a destination. */
    @Test
    fun `a click names the campaign, and a destination only for a button that goes somewhere`() {
        val store = store().apply { accept(responseJson()) }
        val message = store.message("del_1")
        val link = inAppClickProperties(message, InAppButton("Shop", "deep_link", "treebarsdemo://shop"))
        assertEquals("cmp_1", link[TreebarsConstants.CAMPAIGN_ID_KEY])
        assertEquals("del_1", link[TreebarsConstants.DELIVERY_ID_KEY])
        assertEquals("treebarsdemo://shop", link["destination"])
        assertEquals("https://x.example", inAppClickProperties(message, InAppButton("Web", "url", "https://x.example"))["destination"])
        // A trait's value is not a place: a "Join newsletter" button reporting `destination: yes` would be routed to.
        val trait = inAppClickProperties(message, InAppButton("Join", "set_attribute", "yes", key = "newsletter"))
        assertFalse(trait.containsKey("destination"))
        assertEquals("cmp_1", trait[TreebarsConstants.CAMPAIGN_ID_KEY])
        assertEquals("cmp_1", inAppReceipt(message)[TreebarsConstants.CAMPAIGN_ID_KEY])
    }

    /* A click says which element was pressed — a typed button's place, a markup body's `<n>`. */
    @Test
    fun `a click says which button was pressed, numbered from 1, with a typed button's label`() {
        val json = messageJson(deliveryId = "d2")
        json.getJSONObject("content").getJSONObject("in_app").put(
            "buttons",
            JSONArray().put(JSONObject().put("label", "Shop now").put("action", "url").put("value", "https://x.example"))
                .put(JSONObject().put("label", "Later").put("action", "dismiss")),
        )
        val store = store().apply { accept(responseJson(messages = listOf(json))) }
        val message = store.message("d2")
        val typed = message.content!!.buttons.first()
        val pressed = inAppClickProperties(message, typed)
        assertEquals(1, pressed[TreebarsConstants.IN_APP_BUTTON_INDEX_KEY])
        assertEquals("Shop now", pressed[TreebarsConstants.IN_APP_BUTTON_LABEL_KEY])
        assertEquals(2, message.content!!.buttons[1].index)
        // A markup body's `treebars://click/2`, as the React Native host sends it: the number, and no invented label.
        val markup = inAppClickProperties(message, InAppButton("", "click", null, index = 2))
        assertEquals(2, markup[TreebarsConstants.IN_APP_BUTTON_INDEX_KEY])
        assertFalse(markup.containsKey(TreebarsConstants.IN_APP_BUTTON_LABEL_KEY))
    }

    /* A call to action spends the message; a dismiss spends it through its own dismissal; a report does not. */
    @Test
    fun `a call to action ends the message, and a bare report of a press does not`() {
        for (action in listOf("url", "deep_link", "track_event", "set_attribute", "custom")) {
            assertTrue(action, inAppClickEndsMessage(InAppButton("Go", action, "x")))
        }
        assertFalse(inAppClickEndsMessage(InAppButton("Later", "dismiss", null)))
        // A markup body's `treebars://click/<n>`: the message is still on screen.
        assertFalse(inAppClickEndsMessage(InAppButton("Button 0", "click", null)))
    }

    /* The direction the server resolved, passed through for the app's renderer; absent is null. */
    @Test
    fun `a message's direction is carried through, and absent is absent`() {
        val base = JSONObject().put("surface", "overlay").put("layout", "modal").put("trigger", JSONObject().put("kind", "immediate"))
        assertEquals("rtl", parseInAppContent(JSONObject(base.toString()).put("direction", "rtl")).direction)
        assertEquals("ltr", parseInAppContent(JSONObject(base.toString()).put("direction", "ltr")).direction)
        assertEquals(null, parseInAppContent(base).direction)
        assertEquals(null, parseInAppContent(JSONObject(base.toString()).put("direction", JSONObject.NULL)).direction)
    }

    // A primer is held back from anybody the app cannot ask, and asked again each time.
    @Test
    fun aPrimerWaitsForPeopleWhoCanStillBeAsked() {
        val primer = InAppDisplay(on = null, delaySeconds = null, contexts = emptyList(), priority = 5, autoDismissSeconds = null, selfHandled = false, onlyWhenPushAskable = true)
        for (status in listOf("not_determined", "provisional", "denied_askable")) assertEquals(status, null, pushAskableBlock(primer, status))
        for (status in listOf("authorized", "ephemeral", "denied", "unsupported", null)) assertEquals(status, "push_answered", pushAskableBlock(primer, status))
        // A message that did not ask is never held back by it.
        assertEquals(null, pushAskableBlock(primer.copy(onlyWhenPushAskable = false), "authorized"))
        assertEquals(null, pushAskableBlock(null, "authorized"))
    }

    @Test
    fun androidPushStateInTheSharedWords() {
        assertEquals("authorized", androidPushStatus(34, enabled = true, asked = true, rationale = false))
        // Below 13 there is no prompt: off means turned off in Settings.
        assertEquals("denied", androidPushStatus(32, enabled = false, asked = false, rationale = false))
        assertEquals("not_determined", androidPushStatus(34, enabled = false, asked = false, rationale = false))
        assertEquals("denied_askable", androidPushStatus(34, enabled = false, asked = true, rationale = true))
        assertEquals("denied", androidPushStatus(34, enabled = false, asked = true, rationale = false))
    }

    @Test
    fun readsWhetherItWaitsForPeopleWhoCanBeAsked() {
        val json = JSONObject().put("surface", "overlay").put("layout", "modal").put("trigger", JSONObject().put("kind", "immediate"))
        assertFalse(parseInAppContent(json).display?.onlyWhenPushAskable ?: false)
        val asked = JSONObject(json.toString()).put("display", JSONObject().put("only_when_push_askable", true))
        assertTrue(parseInAppContent(asked).display!!.onlyWhenPushAskable)
    }

    // A nudge is outside the channel's caps, neither waiting on them nor spending them.
    @Test
    fun `a nudge neither waits on the caps nor spends them`() {
        val store = store()
        val nudge = cappedMessage("n", "immediate").also { it.getJSONObject("content").getJSONObject("in_app").put("layout", "nudge") }
        val response = responseJson(messages = listOf(cappedMessage("a", "immediate"), cappedMessage("b", "immediate"), nudge), minGapSeconds = 600)
        response.getJSONObject("policy").put("max_per_session", 1)
        store.accept(response)
        store.recordDisplay(store.message("a"), "s1")
        // The modal spent the session and the gap: another modal waits, the nudge does not.
        assertFalse(store.allows(store.message("b"), "s1"))
        assertTrue(store.allows(store.message("n"), "s1"))
        // And a nudge drawn spends nothing a modal waits on.
        val fresh = store()
        fresh.accept(responseJson(messages = listOf(cappedMessage("a", "immediate"), nudge), minGapSeconds = 600).also { it.getJSONObject("policy").put("max_per_session", 1) })
        fresh.recordDisplay(fresh.message("n"), "s1")
        assertTrue(fresh.allows(fresh.message("a"), "s1"))
    }

    @Test
    fun `nudge slots hold three, each once, and free only their own`() {
        val slots = NudgeSlots(TreebarsBridge.NUDGE_MAX_ON_SCREEN)
        assertTrue(slots.claim("a"))
        assertFalse(slots.claim("a"))
        assertTrue(slots.claim("b"))
        assertTrue(slots.claim("c"))
        assertFalse(slots.hasRoom())
        assertFalse(slots.claim("d"))
        slots.release("b")
        assertTrue(slots.claim("d"))
        assertEquals(listOf("a", "c", "d"), slots.clear())
        assertTrue(slots.hasRoom())
    }

    // Apps call `showNudge` in `onStart`, before the Activity is resumed: the place is the one handed in.
    @Test
    fun `a nudge place is the Activity handed in, named before it resumes`() {
        val controller = org.robolectric.Robolectric.buildActivity(android.app.Activity::class.java).create().start()
        val activity = controller.get()
        val place = nudgePlaceFor(activity, "Home")
        controller.resume()
        assertEquals(place, nudgePlaceFor(activity, "Home"))
        // Another screen name on the same Activity is another place, as is another Activity.
        assertFalse(place == nudgePlaceFor(activity, "Search"))
        val other = org.robolectric.Robolectric.buildActivity(android.app.Activity::class.java).create().start().resume().get()
        assertFalse(place == nudgePlaceFor(other, "Home"))
    }
}
