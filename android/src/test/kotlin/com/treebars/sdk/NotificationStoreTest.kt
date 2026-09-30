package com.treebars.sdk

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/*
 * The one part of the notification centre with logic in it: reconciling what this device just
 * did with what the server last said.
 *
 * Worth testing here rather than trusting a run against a real backend, because every failure
 * is a screen that looks fine. A missing overlay makes a tap appear to do nothing and then undo
 * itself on the next refresh. A ledger entry that is never dropped makes a row read as read
 * forever, including after somebody's account changed hands. And an owner check that ran only
 * in `reset()` would draw one person's notifications under another person's name.
 *
 * This store takes its storage as a preferences file name, so each test gets its own. The
 * ledger it reads in its `init` would otherwise carry one test's `noteDismissed` into every
 * test after it, quietly hiding a row, and a name per test is the cheapest way for that never
 * to be the explanation for a red suite.
 */
@RunWith(RobolectricTestRunner::class)
class NotificationStoreTest {

    private lateinit var store: NotificationStore

    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        store = NotificationStore(context, "treebars.notifications.test.${nextPrefs++}")
    }

    // ---- the overlay -------------------------------------------------------------------

    @Test
    fun `reads a locally-marked row as read before the server has heard`() {
        // The whole point. Without this a tap sets a row from bold to plain, the next refresh
        // sets it back, and the person taps again.
        store.noteRead("grp_1")
        assertNotNull(store.overlay(listOf(notification()))[0].readAt)
    }

    @Test
    fun `hides a locally-dismissed row`() {
        store.noteDismissed("grp_1")
        assertEquals(emptyList<TreebarsNotification>(), store.overlay(listOf(notification())))
    }

    @Test
    fun `leaves everything else alone`() {
        val rows = store.overlay(listOf(notification(), notification(groupId = "grp_2")))
        assertEquals(listOf(null, null), rows.map { it.readAt })
    }

    @Test
    fun `applies a mark-all watermark by time, not by id`() {
        // A list of ids cannot express somebody returning to nine hundred unread. The watermark
        // covers rows this device has never seen, which is why it is an instant.
        store.noteReadThrough("2026-08-02T00:00:00.000Z")
        val rows = store.overlay(
            listOf(
                notification(groupId = "before", createdAt = "2026-08-01T00:00:00.000Z"),
                notification(groupId = "after", createdAt = "2026-08-03T00:00:00.000Z"),
            ),
        )
        assertNotNull(rows.single { it.groupId == "before" }.readAt)
        assertNull(rows.single { it.groupId == "after" }.readAt)
    }

    @Test
    fun `counts against the server's rows, not the overlaid ones`() {
        // The subtraction asks "how many rows the server still calls unread have we marked",
        // which is unanswerable once overlay has stamped readAt on them. Passing the overlaid
        // list would leave the badge on the server's number while the rows read as read.
        store.noteRead("grp_1")
        assertEquals(0, store.overlayCount(1, listOf(notification())))
        assertEquals(1, store.overlayCount(1, store.overlay(listOf(notification()))))
    }

    @Test
    fun `never goes negative`() {
        // A mark the server has already counted must not be subtracted a second time. The row
        // arriving with its own readAt is the confirmed case, and it is safe because a
        // server-read row is never counted as marked.
        assertEquals(0, store.overlayCount(0, listOf(notification(readAt = "2026-08-01T00:00:01.000Z"))))

        // This is the arithmetic that can actually reach -1: an outstanding mark against a page
        // the server has already dropped to zero unread.
        store.noteRead("grp_1")
        assertEquals(0, store.overlayCount(0, listOf(notification())))
    }

    // ---- the ledger --------------------------------------------------------------------

    @Test
    fun `drops an entry once the server agrees with it`() {
        store.noteRead("grp_1")
        store.accept("user_a", page(listOf(notification(readAt = "2026-08-01T00:00:01.000Z")), 0))

        // The row now says read on its own, so the ledger has nothing left to assert — and an
        // entry kept forever would keep asserting it after the account changed hands. The
        // timestamp is the server's, not the instant the overlay would have stamped.
        val cached = store.cached()!!
        assertEquals(Iso8601.parseOrNull("2026-08-01T00:00:01.000Z"), cached.notifications[0].readAt)
        assertEquals(0, cached.unreadCount)
    }

    @Test
    fun `forgets a dismissal once the row is gone from the answer`() {
        store.noteDismissed("grp_1")
        store.accept("user_a", page(listOf(notification(groupId = "grp_2"))))
        // Dismissed rows do not come back in the server's list, so absence IS agreement.
        assertEquals(listOf("grp_2"), store.cached()!!.notifications.map { it.groupId })

        // And having agreed, the store stops hiding it: a page that does list grp_1 again shows
        // it. Without that second half this test passes on a store that never forgets anything,
        // because grp_1 was absent from the page either way.
        store.accept("user_a", page(listOf(notification())))
        assertEquals(listOf("grp_1"), store.cached()!!.notifications.map { it.groupId })
    }

    // ---- the owner check ---------------------------------------------------------------

    @Test
    fun `clears the feed and the ledger when the account changes`() {
        store.accept("user_a", page(listOf(notification(groupId = "a_only"))))
        store.noteRead("a_only")

        // identify(b) without an intervening reset(). This is the case that runs on every accept
        // rather than only in reset(), and the reason is right here: otherwise b reads a's
        // notifications, with a's read marks on them.
        store.accept("user_b", page(listOf(notification(groupId = "b_only"))))

        val cached = store.cached()!!
        assertEquals(listOf("b_only"), cached.notifications.map { it.groupId })
        assertNull(cached.notifications[0].readAt)

        // The store keeps its owner private, so the ledger half is read the only way it can be
        // from outside — a's mark no longer subtracts from anything.
        assertEquals(1, store.overlayCount(1, listOf(notification(groupId = "a_only"))))
    }

    @Test
    fun `keeps the feed for the same account`() {
        store.accept("user_a", page(listOf(notification())))
        store.noteRead("grp_1")
        store.accept("user_a", page(listOf(notification())))
        assertNotNull(store.cached()!!.notifications[0].readAt)
    }

    // ---- the cache ---------------------------------------------------------------------

    @Test
    fun `does its unread arithmetic against the whole page it was given`() {
        /*
         * `markAllRead()` and `unreadCount()` both fetch ONE row — the first only to learn the
         * server's clock. Cached, that one-row probe would replace the real first page, and the
         * count would then be computed against that single row: the badge would read "2 unread"
         * beside a list where every row was already marked read.
         *
         * The store's half of the contract is this: whatever page it accepts is the page it
         * counts against. The SDK's half — cache only a page with no cursor AND no explicit
         * limit — lives in `Treebars.kt`.
         */
        val rows = listOf(
            notification(groupId = "a"),
            notification(groupId = "b"),
            notification(groupId = "c"),
        )
        store.accept("user_a", page(rows, 3))
        store.noteReadThrough(Iso8601.now())

        assertEquals(0, store.cached()!!.unreadCount)

        // A one-row page accepted over it can only account for one row, which is exactly why
        // the SDK must not hand it one.
        store.accept("user_a", page(listOf(rows[0]), 3))
        assertEquals(2, store.cached()!!.unreadCount)
    }

    @Test
    fun `answers nothing before anything has been fetched`() {
        assertNull(store.cached())
    }

    @Test
    fun `is flagged as cached, so a screen can say so rather than imply a round trip`() {
        store.accept("user_a", page(listOf(notification())))
        assertTrue(store.cached()!!.fromCache)
    }

    @Test
    fun `is emptied by reset, because a history belongs to the person`() {
        store.accept("user_a", page(listOf(notification())))
        store.reset()
        assertNull(store.cached())
    }

    @Test
    fun `drops a first page asked for before a sign-out, which would be cached under the next owner`() {
        // The owner is read when the answer lands, so without this a page fetched for user_a would be filed as the device's.
        val asked = store.generation
        store.reset()
        assertEquals(false, store.accept("device_1", page(listOf(notification())), asked))
        assertNull(store.cached())
    }

    // ---- fixtures ----------------------------------------------------------------------

    /**
     * Built from the wire shape rather than by calling the constructor, so every row carries the
     * `raw` object `accept` persists. A hand-made row with an empty `raw` would save a page that
     * cannot be read back, and the first test to reopen a store would fail for that reason
     * rather than for its own.
     */
    private fun notification(
        groupId: String = "grp_1",
        createdAt: String = "2026-08-01T00:00:00.000Z",
        readAt: String? = null,
    ): TreebarsNotification {
        val row = JSONObject()
            .put("group_id", groupId)
            .put("campaign_id", "cmp_1")
            .put("channel_type", "push")
            .put("device_count", 1)
            .put("content", JSONObject().put("title", "Hello").put("body", "There"))
            .put("created_at", createdAt)
        if (readAt != null) row.put("read_at", readAt)
        return parseNotifications(JSONArray().put(row)).single()
    }

    private fun page(
        notifications: List<TreebarsNotification>,
        unreadCount: Int = notifications.size,
    ) = NotificationPage(notifications, unreadCount, null, false)

    private companion object {
        var nextPrefs = 0
    }
}
