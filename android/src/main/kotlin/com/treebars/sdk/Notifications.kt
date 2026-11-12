package com.treebars.sdk

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/*
 * The notification centre.
 *
 * Data, and only data. This SDK draws no list — the app owns its navigation, its insets and
 * its typography, and none of those are a dependency's business. What lives here is the
 * part an app cannot write for itself: paging a server-side history, holding the first
 * screen for a tunnel, and making a tap read as read while the write is still in flight.
 *
 * Not the same list as `inbox()`. That is the queue of in-app messages authored as rows —
 * still actionable, still styled. This is the history of everything the project sent this
 * person, push included, keeping what expiry and dismissal take out of that queue.
 *
 * Mirrors the iOS and web SDKs' notification centres field for field. Separate
 * implementations by design: this package ships into customer apps and depends on nothing
 * else of Treebars'.
 */

/**
 * The topic a notification was sent under: one of the project's tabs for the centre, by its [key] (what
 * [Treebars.notifications] and [Treebars.markAllNotificationsRead] take) and the [name] a tab shows.
 */
data class NotificationTopicRef(val key: String, val name: String)

/**
 * One tab of the centre, with its counts. [key] null is All, which comes first and counts everything — the sends
 * with no topic included — so its [unread] is the badge.
 */
data class NotificationTopic(val key: String?, val name: String, val unread: Int, val total: Int)

data class TreebarsNotification(
    /**
     * One send, not one row.
     *
     * The server records a delivery per push token so an open on the phone does not mark
     * the tablet's; this is the id that collapses them back into the one notification a
     * person was sent, and the only id a mark will be accepted for. A per-device delivery
     * id belongs to the device it was sent to and reaches nowhere else.
     */
    val groupId: String,
    val campaignId: String?,
    val channelType: String,
    /** How many of this person's devices this one send reached. */
    val deviceCount: Int,
    val title: String?,
    val body: String?,
    val imageUrl: String?,
    val deepLink: String?,
    /** In-app rows only; null for a push. */
    val content: InAppContent?,
    val createdAt: Long?,
    val readAt: Long?,
    val openedAt: Long?,
    val expiresAt: Long?,
    /** In-app rows only, resolved server-side exactly as the in-app sync resolves it. */
    val style: InAppTokens?,
    /** Kept so the page can be persisted without re-encoding what the server sent. */
    val raw: JSONObject,
    /** The topic it was sent under, or null when it has none. */
    val topic: NotificationTopicRef? = null,
)

data class NotificationPage(
    val notifications: List<TreebarsNotification>,
    val unreadCount: Int,
    /** Pass back as `cursor` for the next page. Null when this is the end. */
    val nextCursor: String?,
    /**
     * True when the network could not be reached and this is what was last persisted.
     *
     * Exposed rather than hidden: a list that silently shows yesterday's page is a screen
     * lying about a round trip. An app can badge it, or ignore it.
     */
    val fromCache: Boolean,
    /**
     * The centre's tabs with their counts, All first, on a first page only. Null when the server sent none — a
     * project with no topics, or a server older than them — and a screen then draws no topic tabs.
     */
    val topics: List<NotificationTopic>? = null,
)

class NotificationStore(private val context: Context, private val prefsName: String) {
    private var notifications: List<TreebarsNotification> = emptyList()
    private var unreadCount = 0
    private var nextCursor: String? = null
    /** The tabs as they came with the cached rows, so the two are drawn again as one answer. */
    private var topics: List<NotificationTopic>? = null

    /**
     * `userId ?: deviceId` at the moment of the fetch.
     *
     * Checked on every accept and not only in `reset()`, which is the point: an app that
     * calls `identify(b)` on a handset signed in as `a` without an intervening `reset()`
     * would otherwise keep drawing `a`'s notifications under `b`'s name.
     */
    private var owner: String? = null

    /**
     * Moved on by [reset] and [supersede], and read before a fetch so [accept] can drop an answer that was asked for
     * the person who has since signed out or been replaced. Without it their first page would be cached under the next
     * owner's key — the owner is read when the answer lands, not when it was asked for.
     */
    @Volatile
    var generation = 0
        private set

    /** Marks this device has made that the server has not confirmed yet. */
    private val read = mutableSetOf<String>()
    private val dismissed = mutableSetOf<String>()
    private var readThrough: Long? = null
    /** A mark-all of one tab: the server's time it was taken against, by topic key. */
    private val topicReadThrough = mutableMapOf<String, Long>()

    init {
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        runCatching {
            prefs.getString("notifications", null)?.let { restoreFeed(JSONObject(it)) }
            prefs.getString("notification_ledger", null)?.let { restoreLedger(JSONObject(it)) }
        }
        // A corrupt cache is an empty cache. This runs while a screen is mounting a list.
    }

    /**
     * Overlays what this device has done onto what the server just said.
     *
     * Without it a tap sets a row from unread to read, the next refresh sets it back, and
     * the person taps again. Entries are dropped as soon as the server's own row agrees.
     */
    @Synchronized
    fun overlay(incoming: List<TreebarsNotification>): List<TreebarsNotification> {
        val now = System.currentTimeMillis()
        return incoming
            .filterNot { it.groupId in dismissed }
            .map { notification ->
                if (notification.readAt != null) return@map notification
                if (notification.groupId in read || coveredByWatermark(notification)) {
                    notification.copy(readAt = now)
                } else {
                    notification
                }
            }
    }

    /** Whether a mark-all this device made — of everything, or of this row's own tab — reaches back to this row. */
    private fun coveredByWatermark(notification: TreebarsNotification): Boolean {
        val created = notification.createdAt ?: return false
        readThrough?.let { if (created <= it) return true }
        val tab = notification.topic?.key?.let { topicReadThrough[it] } ?: return false
        return created <= tab
    }

    /**
     * The server's tabs with this device's unwritten marks taken off them, as nearly as one answer allows.
     *
     * A mark-all of everything empties every tab, and a mark-all of one tab empties that tab and takes its unread off
     * All. A row marked on its own is taken off its tab and off All only when it came in the same answer as the tabs —
     * a tab's other rows are not here to look at, and the write that marks it is usually acknowledged before anybody
     * reads the tabs again. [badge] is the page's own unread count, and All is never more than it, so the two agree.
     */
    @Synchronized
    fun overlayTopics(
        serverTabs: List<NotificationTopic>,
        serverRows: List<TreebarsNotification>,
        badge: Int,
    ): List<NotificationTopic> {
        val everything = readThrough != null
        fun watermarked(key: String) = everything || key in topicReadThrough
        val offTab = mutableMapOf<String, Int>()
        var offAll = 0
        for (tab in serverTabs) {
            val key = tab.key ?: continue
            if (watermarked(key)) {
                offTab[key] = tab.unread
                offAll += tab.unread
            }
        }
        for (row in serverRows) {
            if (row.readAt != null || !(row.groupId in read || row.groupId in dismissed)) continue
            val key = row.topic?.key
            if (key != null && watermarked(key)) continue
            offAll += 1
            if (key != null) offTab[key] = (offTab[key] ?: 0) + 1
        }
        return serverTabs.map { tab ->
            val key = tab.key
            if (key == null) {
                val unread = if (everything) 0 else maxOf(0, tab.unread - offAll)
                tab.copy(unread = minOf(unread, badge))
            } else {
                tab.copy(unread = maxOf(0, tab.unread - (offTab[key] ?: 0)))
            }
        }
    }

    /**
     * Forgets a tab's mark-all once the server agrees there is nothing unread in it, or no longer has the tab.
     *
     * Kept apart from the rows' own reconciliation because a first page may hold no row of that tab at all, and
     * "every row of it is read" is then true of nothing — which would drop the mark while its write is in flight.
     */
    @Synchronized
    fun settleTopics(serverTabs: List<NotificationTopic>) {
        val unreadByKey = serverTabs.associate { it.key to it.unread }
        val confirmed = topicReadThrough.keys.filter { (unreadByKey[it] ?: 0) == 0 }
        if (confirmed.isEmpty()) return
        confirmed.forEach { topicReadThrough.remove(it) }
        save()
    }

    /** The rows, the badge and the tabs as this device should draw them, from one answer of the server's. */
    @Synchronized
    fun present(
        serverRows: List<TreebarsNotification>,
        serverCount: Int,
        serverTabs: List<NotificationTopic>?,
        nextCursor: String?,
        fromCache: Boolean,
    ): NotificationPage {
        val count = overlayCount(serverCount, serverRows)
        val tabs = serverTabs?.let { overlayTopics(it, serverRows, count) }
        // All's tab is the badge; when the tabs know of more marked than the rows do, the badge follows them.
        val badge = tabs?.firstOrNull()?.takeIf { it.key == null }?.let { minOf(count, it.unread) } ?: count
        return NotificationPage(overlay(serverRows), badge, nextCursor, fromCache, tabs)
    }

    /**
     * The unread count with this device's unconfirmed marks taken off it.
     *
     * **Takes the server's rows, not the overlaid ones.** The subtraction is "how many rows
     * the server still counts as unread have we already marked", which is unanswerable once
     * [overlay] has stamped `readAt` on them: every row looks read, nothing is subtracted,
     * and the badge keeps the server's number while the list shows them read.
     */
    @Synchronized
    fun overlayCount(serverCount: Int, serverRows: List<TreebarsNotification>): Int {
        if (readThrough != null) {
            // A watermark may cover rows this device has never seen, so it is not countable
            // from one page; what is safe is that it cannot exceed either bound.
            val unmarked = serverRows.count { it.readAt == null }
            return maxOf(0, minOf(serverCount, serverCount - unmarked))
        }
        val marked = serverRows.count {
            it.readAt == null && (it.groupId in read || it.groupId in dismissed)
        }
        return maxOf(0, serverCount - marked)
    }

    /** Replaces the cached first page, clearing it first if it belongs to somebody else. */
    @Synchronized
    fun accept(owner: String, page: NotificationPage, askedAt: Int = generation): Boolean {
        if (askedAt != generation) return false
        if (this.owner != null && this.owner != owner) {
            notifications = emptyList()
            topics = null
            read.clear()
            dismissed.clear()
            readThrough = null
            topicReadThrough.clear()
        }
        this.owner = owner
        notifications = page.notifications
        unreadCount = page.unreadCount
        nextCursor = page.nextCursor
        topics = page.topics
        forgetConfirmed(page.notifications)
        save()
        return true
    }

    @Synchronized
    fun cached(): NotificationPage? {
        if (owner == null) return null
        // The stored rows are the server's answer as it stood; overlay for display, count
        // against the originals.
        return present(notifications, unreadCount, topics, nextCursor, fromCache = true)
    }

    /**
     * One tab's rows out of the cached first page, for when the network cannot answer for that tab. Only what the
     * first page held, and no cursor: a tab's own pages are network-only.
     */
    @Synchronized
    fun cachedTopic(topic: String): NotificationPage? {
        val page = cached() ?: return null
        return page.copy(notifications = page.notifications.filter { it.topic?.key == topic }, nextCursor = null)
    }

    @Synchronized
    fun noteRead(groupId: String) {
        read.add(groupId)
        save()
    }

    /** A mark-all, of everything or of one tab ([topic]), taken against the server's own clock. */
    @Synchronized
    fun noteReadThrough(serverTime: String, topic: String? = null) {
        val at = Iso8601.parseOrNull(serverTime)
        if (topic != null) {
            if (at != null) topicReadThrough[topic] = at
        } else {
            readThrough = at
        }
        save()
    }

    @Synchronized
    fun noteDismissed(groupId: String) {
        dismissed.add(groupId)
        save()
    }

    /**
     * Somebody else is signed in now, without a sign-out between. The cached page and the marks are the last person's,
     * as a fetch in flight is: all of it goes, so [cached] has nothing of theirs to answer the next person with.
     */
    @Synchronized
    fun supersede() {
        reset()
    }

    /** Drops everything. Called from `reset()`; the device secret deliberately survives. */
    @Synchronized
    fun reset() {
        generation += 1
        notifications = emptyList()
        unreadCount = 0
        nextCursor = null
        topics = null
        owner = null
        read.clear()
        dismissed.clear()
        readThrough = null
        topicReadThrough.clear()
        context.getSharedPreferences(prefsName, Context.MODE_PRIVATE).edit()
            .remove("notifications")
            .remove("notification_ledger")
            .apply()
    }

    private fun forgetConfirmed(incoming: List<TreebarsNotification>) {
        for (notification in incoming) {
            if (notification.readAt != null) read.remove(notification.groupId)
        }
        if (readThrough != null && incoming.all { it.readAt != null }) readThrough = null
        val live = incoming.map { it.groupId }.toSet()
        dismissed.retainAll(live)
    }

    private fun restoreFeed(stored: JSONObject) {
        owner = stored.optString("owner").takeIf { it.isNotEmpty() }
        unreadCount = stored.optInt("unread_count", 0)
        nextCursor = stored.optString("next_cursor").takeIf { it.isNotEmpty() }
        notifications = parseNotifications(stored.optJSONArray("notifications") ?: JSONArray())
        topics = stored.optJSONArray("topics")?.let(::parseNotificationTopics)
    }

    private fun restoreLedger(stored: JSONObject) {
        stored.optJSONArray("read")?.let { array ->
            for (i in 0 until array.length()) read.add(array.optString(i))
        }
        stored.optJSONArray("dismissed")?.let { array ->
            for (i in 0 until array.length()) dismissed.add(array.optString(i))
        }
        readThrough = if (stored.isNull("read_through")) null else stored.optLong("read_through")
        stored.optJSONObject("topic_read_through")?.let { byTopic ->
            for (key in byTopic.keys()) {
                if (!byTopic.isNull(key)) topicReadThrough[key] = byTopic.optLong(key)
            }
        }
    }

    private fun save() {
        val feed = JSONObject()
            .put("owner", owner)
            .put("unread_count", unreadCount)
            .put("next_cursor", nextCursor)
            .put("notifications", JSONArray(notifications.map { it.raw }))
        topics?.let { feed.put("topics", notificationTopicsJson(it)) }
        val ledger = JSONObject()
            .put("read", JSONArray(read.toList()))
            .put("dismissed", JSONArray(dismissed.toList()))
            .put("read_through", readThrough)
            .put("topic_read_through", JSONObject(topicReadThrough.toMap()))

        context.getSharedPreferences(prefsName, Context.MODE_PRIVATE).edit()
            .putString("notifications", feed.toString())
            .putString("notification_ledger", ledger.toString())
            .apply()
    }
}

/**
 * Reads the wire shape.
 *
 * `raw` is kept on every row so persisting the page is re-storing what the server sent,
 * rather than re-encoding a parse of it — the same reason `InAppMessage` keeps one.
 */
internal fun parseNotifications(array: JSONArray): List<TreebarsNotification> =
    (0 until array.length()).mapNotNull { index ->
        val row = array.optJSONObject(index) ?: return@mapNotNull null
        val content = row.optJSONObject("content") ?: JSONObject()
        TreebarsNotification(
            groupId = row.optString("group_id"),
            campaignId = row.optString("campaign_id").takeIf { it.isNotEmpty() && it != "null" },
            channelType = row.optString("channel_type"),
            deviceCount = row.optInt("device_count", 1),
            title = content.optString("title").takeIf { it.isNotEmpty() },
            body = content.optString("body").takeIf { it.isNotEmpty() },
            imageUrl = content.optString("image_url").takeIf { it.isNotEmpty() },
            deepLink = content.optString("deep_link").takeIf { it.isNotEmpty() },
            content = content.optJSONObject("in_app")?.let(::parseInAppContent),
            createdAt = Iso8601.parseOrNull(row.optString("created_at", "")),
            readAt = Iso8601.parseOrNull(row.optString("read_at", "")),
            openedAt = Iso8601.parseOrNull(row.optString("opened_at", "")),
            expiresAt = Iso8601.parseOrNull(row.optString("expires_at", "")),
            style = row.optJSONObject("style")?.let(::parseInAppTokens),
            raw = row,
            topic = row.optJSONObject("topic")?.let { topic ->
                val key = topic.optString("key")
                if (topic.isNull("key") || key.isEmpty()) null else NotificationTopicRef(key, topic.optString("name", key))
            },
        )
    }

/** Reads the tabs, All first. A tab whose `key` is JSON null is All — never the string "null". */
internal fun parseNotificationTopics(array: JSONArray): List<NotificationTopic> =
    (0 until array.length()).mapNotNull { index ->
        val tab = array.optJSONObject(index) ?: return@mapNotNull null
        NotificationTopic(
            key = if (tab.isNull("key")) null else tab.optString("key").takeIf { it.isNotEmpty() },
            name = tab.optString("name"),
            unread = tab.optInt("unread", 0),
            total = tab.optInt("total", 0),
        )
    }

/** The tabs in the wire's own shape, All's `key` as JSON null rather than left out. */
internal fun notificationTopicsJson(topics: List<NotificationTopic>): JSONArray = JSONArray().apply {
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
