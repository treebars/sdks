import Foundation

/*
 * The notification centre.
 *
 * Data, and only data. This SDK draws no list — the app owns its navigation, its safe
 * areas and its typography, and none of those are a dependency's business. What lives here
 * is the part an app cannot write for itself: paging a server-side history, holding the
 * first screen for a tunnel, and making a tap read as read while the write is in flight.
 *
 * Not the same list as `inbox()`. That is the queue of in-app messages authored as rows —
 * still actionable, still styled. This is the history of everything the project sent this
 * person, push included, keeping what expiry and dismissal take out of that queue.
 *
 * Mirrors the Android and web SDKs' notification centres field for field. Separate
 * implementations by design: this package ships into customer apps and depends on nothing
 * else of Treebars'.
 */

/*
 * Everything below decodes tolerantly, on the machinery in `InApp.swift` — `tolerant`,
 * `tolerantList` and `Tolerated`, whose long comment carries the reasoning. It applies here
 * word for word and arguably harder: a page is decoded in one call, so a strict decoder would
 * let a single row missing a single key fail the whole page and answer with the cached one,
 * which reads as a bell that has stopped ringing rather than as a decode that failed.
 */

/// The topic a notification was sent under: one of the project's tabs for the centre, by its `key` (what
/// `Treebars.notifications(topic:)` and `markAllNotificationsRead(topic:)` take) and the `name` a tab shows.
public struct NotificationTopicRef: Codable, Sendable, Equatable {
    public let key: String
    public let name: String
}

/**
 One tab of the centre, with its counts. `key` nil is All, which comes first and counts everything — the sends with no
 topic included — so its `unread` is the badge.
 */
public struct NotificationTopic: Codable, Sendable, Equatable {
    public let key: String?
    public let name: String
    public let unread: Int
    public let total: Int

    public init(key: String?, name: String, unread: Int, total: Int) {
        self.key = key
        self.name = name
        self.unread = unread
        self.total = total
    }

    enum CodingKeys: String, CodingKey {
        case key, name, unread, total
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = container.tolerant(.key)
        name = container.tolerant(.name, or: "")
        unread = container.tolerant(.unread, or: 0)
        total = container.tolerant(.total, or: 0)
    }

    /// All's `key` is written as null rather than left out, which is how the wire says it and how the React Native
    /// types read it.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(name, forKey: .name)
        try container.encode(unread, forKey: .unread)
        try container.encode(total, forKey: .total)
    }

    func with(unread: Int) -> NotificationTopic {
        NotificationTopic(key: key, name: name, unread: unread, total: total)
    }
}

public struct TreebarsNotificationContent: Codable, Sendable {
    public let title: String?
    public let body: String?
    public let image_url: String?
    public let deep_link: String?
    public let in_app: InAppContent?
}

extension TreebarsNotificationContent {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = container.tolerant(.title)
        body = container.tolerant(.body)
        image_url = container.tolerant(.image_url)
        deep_link = container.tolerant(.deep_link)
        in_app = container.tolerant(.in_app)
    }
}

public struct TreebarsNotification: Codable, Sendable {
    /**
     One send, not one row.

     The server records a delivery per push token so an open on the phone does not mark the
     iPad's; this is the id that collapses those back into the one notification a person was
     sent, and the only id a mark will be accepted for. A per-device delivery id belongs to
     the device it was sent to and reaches nowhere else.
     */
    public let group_id: String
    public let campaign_id: String?
    public let channel_type: String
    /// How many of this person's devices this one send reached.
    public let device_count: Int
    public let content: TreebarsNotificationContent
    public let created_at: String
    public let read_at: String?
    public let opened_at: String?
    public let expires_at: String?
    /// In-app rows only, resolved server-side exactly as the in-app sync resolves it.
    public let style: InAppTokens?
    /// Its colours in dark mode, when the message has a dark variant — the feed ships it beside `style` as the sync
    /// does. Declared because the store and the React Native bridge re-encode this struct, and a card drawn from the
    /// render plan on a dark iPhone would otherwise be drawn light where Android draws it dark.
    public var style_dark: InAppTokens? = nil
    /// The topic it was sent under, or nil when it has none.
    public var topic: NotificationTopicRef? = nil
}

extension TreebarsNotification {
    /**
     `group_id` is required for the reason the field's own comment gives: it is the only id a
     mark is accepted for, and the key both halves of the ledger are filed under. Defaulted to
     "", every id-less row would share one entry — read one and they all read, dismiss one and
     they all vanish — so a row that cannot say which send it is gets dropped instead, and only
     it, because the page decodes row by row.

     `device_count` defaults to 1 rather than 0, matching Android: a send reached at least the
     device reading it, and "sent to 0 devices" is a sentence no screen should be handed.
     `created_at` defaults to empty, which parses to no date at all — so a mark-all watermark
     cannot claim a row whose age nobody stated, and it stays unread rather than being marked
     by a comparison against nothing.
     */
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        group_id = try container.decode(String.self, forKey: .group_id)
        campaign_id = container.tolerant(.campaign_id)
        channel_type = container.tolerant(.channel_type, or: "")
        device_count = container.tolerant(.device_count, or: 1)
        content = container.tolerant(
            .content,
            or: TreebarsNotificationContent(
                title: nil, body: nil, image_url: nil, deep_link: nil, in_app: nil
            )
        )
        created_at = container.tolerant(.created_at, or: "")
        read_at = container.tolerant(.read_at)
        opened_at = container.tolerant(.opened_at)
        expires_at = container.tolerant(.expires_at)
        style = container.tolerant(.style)
        style_dark = container.tolerant(.style_dark)
        topic = container.tolerant(.topic)
    }
}

public struct NotificationPage: Sendable {
    public let notifications: [TreebarsNotification]
    public let unreadCount: Int
    /// Pass back as `cursor` for the next page. Nil when this is the end.
    public let nextCursor: String?
    /**
     True when the network could not be reached and this is what was last persisted.

     Exposed rather than hidden: a list that silently shows yesterday's page is a screen
     lying about a round trip. An app can badge it, or ignore it.
     */
    public let fromCache: Bool
    /**
     The centre's tabs with their counts, All first, on a first page only. Nil when the server sent none — a project with
     no topics, or a server older than them — and a screen then draws no topic tabs.
     */
    public var topics: [NotificationTopic]? = nil
}

struct NotificationWireResponse: Codable {
    let notifications: [TreebarsNotification]
    let unread_count: Int
    let next_cursor: String?
    let topics: [NotificationTopic]?
    let claim_required: Bool?
    let signature_required: Bool?
    let server_time: String
}

/**
 `server_time` is the mark-all watermark, and an empty string is worse than a wrong one.

 It reaches `noteReadThrough`, where `InAppStore.parse("")` answers nil — so `overlay` marks
 nothing while `overlayCount` still takes its `readThrough != nil` branch: a mark-all that the
 badge believes and the list does not. This device's own clock is at least a time, so it
 stands in when the field is missing.
 */
extension NotificationWireResponse {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        notifications = container.tolerantList(.notifications, of: TreebarsNotification.self)
        unread_count = container.tolerant(.unread_count, or: 0)
        next_cursor = container.tolerant(.next_cursor)
        topics = container.tolerant(.topics)
        claim_required = container.tolerant(.claim_required)
        signature_required = container.tolerant(.signature_required)
        server_time = container.tolerant(.server_time, or: Iso8601.now())
    }
}

struct NotificationStateResponse: Codable {
    let unread_count: Int
    let signature_required: Bool?
    let server_time: String
}

extension NotificationStateResponse {
    /// Same watermark, same stand-in as the page above.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        unread_count = container.tolerant(.unread_count, or: 0)
        signature_required = container.tolerant(.signature_required)
        server_time = container.tolerant(.server_time, or: Iso8601.now())
    }
}

/// The first page as last fetched, with the account it was fetched for.
private struct CachedFeed: Codable {
    /**
     `userId ?? deviceId` at the moment of the fetch.

     Checked on every accept and not only in `reset()`, which is the point: an app that
     calls `identify(b)` on a handset signed in as `a` without an intervening `reset()`
     would otherwise keep drawing `a`'s notifications under `b`'s name.
     */
    let owner: String
    let notifications: [TreebarsNotification]
    let unreadCount: Int
    let nextCursor: String?
    /// The tabs as they came with these rows, so the two are drawn again as one answer.
    let topics: [NotificationTopic]?
}

extension CachedFeed {
    /// `owner` is required, and unlike the two ids it guards a throw here costs the WHOLE
    /// feed rather than one row — which is the answer this one field deserves. `cached()`
    /// hands this page straight to the screen and never re-checks whose it is; only `accept`
    /// does. So a feed that cannot say who it belongs to must not survive being read: no
    /// cache costs a round trip, where an owner of "" draws one person's notifications under
    /// another person's name.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        owner = try container.decode(String.self, forKey: .owner)
        notifications = container.tolerantList(.notifications, of: TreebarsNotification.self)
        unreadCount = container.tolerant(.unreadCount, or: 0)
        nextCursor = container.tolerant(.nextCursor)
        topics = container.tolerant(.topics)
    }
}

/// Marks this device has made that the server has not confirmed yet.
private struct NotificationLedger: Codable {
    var read: [String: Bool] = [:]
    var dismissed: [String: Bool] = [:]
    /// The `server_time` a mark-all was taken against, if one is outstanding.
    var readThrough: String?
    /// A mark-all of one tab: the `server_time` it was taken against, by topic key.
    var topicReadThrough: [String: String] = [:]
}

extension NotificationLedger {
    /// Read off disk, so the same argument as `Ledger` in `InApp.swift`: the defaults above are
    /// invisible to a synthesized decoder, and a ledger thrown away is every unconfirmed mark
    /// on this device coming back unread the next time the app opens.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        read = container.tolerant(.read, or: [:])
        dismissed = container.tolerant(.dismissed, or: [:])
        readThrough = container.tolerant(.readThrough)
        topicReadThrough = container.tolerant(.topicReadThrough, or: [:])
    }
}

final class NotificationStore {
    private let feedKey = "treebars.notifications"
    private let ledgerKey = "treebars.notification_ledger"

    private var feed: CachedFeed?
    private var ledger = NotificationLedger()

    /// Moved on by `reset()` and `supersede()`, and read before a fetch so `accept` can drop an answer asked for the
    /// person who has since signed out or been replaced. Without it their first page could be cached under the next
    /// owner — the owner is read when the answer lands, not when it was asked for.
    private(set) var generation = 0

    init() {
        if let data = UserDefaults.standard.data(forKey: feedKey),
           let decoded = try? JSONDecoder().decode(CachedFeed.self, from: data) {
            feed = decoded
        }
        if let data = UserDefaults.standard.data(forKey: ledgerKey),
           let decoded = try? JSONDecoder().decode(NotificationLedger.self, from: data) {
            ledger = decoded
        }
    }

    /**
     Overlays what this device has done onto what the server just said.

     Without it a tap sets a row from unread to read, the next refresh sets it back, and the
     person taps again. Entries are dropped as soon as the server's own row agrees, which is
     what keeps the ledger from growing without bound.
     */
    func overlay(_ notifications: [TreebarsNotification]) -> [TreebarsNotification] {
        let now = Iso8601.now()

        return notifications.compactMap { notification in
            if ledger.dismissed[notification.group_id] == true { return nil }
            if notification.read_at != nil { return notification }

            let locallyRead = ledger.read[notification.group_id] == true || coveredByWatermark(notification)
            guard locallyRead else { return notification }

            return TreebarsNotification(
                group_id: notification.group_id,
                campaign_id: notification.campaign_id,
                channel_type: notification.channel_type,
                device_count: notification.device_count,
                content: notification.content,
                created_at: notification.created_at,
                read_at: now,
                opened_at: notification.opened_at,
                expires_at: notification.expires_at,
                style: notification.style,
                style_dark: notification.style_dark,
                topic: notification.topic
            )
        }
    }

    /// Whether a mark-all this device made — of everything, or of this row's own tab — reaches back to this row.
    private func coveredByWatermark(_ notification: TreebarsNotification) -> Bool {
        guard let created = InAppStore.parse(notification.created_at) else { return false }
        if let through = ledger.readThrough.flatMap(InAppStore.parse), created <= through { return true }
        guard let key = notification.topic?.key,
              let tab = ledger.topicReadThrough[key].flatMap(InAppStore.parse)
        else { return false }
        return created <= tab
    }

    /**
     The server's tabs with this device's unwritten marks taken off them, as nearly as one answer allows.

     A mark-all of everything empties every tab, and a mark-all of one tab empties that tab and takes its unread off
     All. A row marked on its own is taken off its tab and off All only when it came in the same answer as the tabs — a
     tab's other rows are not here to look at, and the write that marks it is usually acknowledged before anybody reads
     the tabs again. `badge` is the page's own unread count, and All is never more than it, so the two agree.
     */
    func overlayTopics(
        _ serverTabs: [NotificationTopic],
        _ serverRows: [TreebarsNotification],
        badge: Int
    ) -> [NotificationTopic] {
        let everything = ledger.readThrough != nil
        let watermarked = { (key: String) in everything || self.ledger.topicReadThrough[key] != nil }
        var offTab: [String: Int] = [:]
        var offAll = 0
        for tab in serverTabs {
            guard let key = tab.key, watermarked(key) else { continue }
            offTab[key] = tab.unread
            offAll += tab.unread
        }
        for row in serverRows {
            guard row.read_at == nil,
                  ledger.read[row.group_id] == true || ledger.dismissed[row.group_id] == true
            else { continue }
            let key = row.topic?.key
            if let key, watermarked(key) { continue }
            offAll += 1
            if let key { offTab[key, default: 0] += 1 }
        }
        return serverTabs.map { tab in
            guard let key = tab.key else {
                let unread = everything ? 0 : max(0, tab.unread - offAll)
                return tab.with(unread: min(unread, badge))
            }
            return tab.with(unread: max(0, tab.unread - (offTab[key] ?? 0)))
        }
    }

    /**
     Forgets a tab's mark-all once the server agrees there is nothing unread in it, or no longer has the tab.

     Kept apart from the rows' own reconciliation because a first page may hold no row of that tab at all, and "every
     row of it is read" is then true of nothing — which would drop the mark while its write is still in flight.
     */
    func settleTopics(_ serverTabs: [NotificationTopic]) {
        var unreadByKey: [String: Int] = [:]
        for tab in serverTabs { if let key = tab.key { unreadByKey[key] = tab.unread } }
        let confirmed = ledger.topicReadThrough.keys.filter { (unreadByKey[$0] ?? 0) == 0 }
        guard !confirmed.isEmpty else { return }
        for key in confirmed { ledger.topicReadThrough.removeValue(forKey: key) }
        save()
    }

    /// The rows, the badge and the tabs as this device should draw them, from one answer of the server's.
    func present(
        _ serverRows: [TreebarsNotification],
        serverCount: Int,
        serverTabs: [NotificationTopic]?,
        nextCursor: String?,
        fromCache: Bool
    ) -> NotificationPage {
        let count = overlayCount(serverCount, serverRows)
        let tabs = serverTabs.map { overlayTopics($0, serverRows, badge: count) }
        // All's tab is the badge; when the tabs know of more marked than the rows do, the badge follows them.
        var badge = count
        if let all = tabs?.first, all.key == nil { badge = min(count, all.unread) }
        return NotificationPage(
            notifications: overlay(serverRows),
            unreadCount: badge,
            nextCursor: nextCursor,
            fromCache: fromCache,
            topics: tabs
        )
    }

    /**
     The unread count with this device's unconfirmed marks taken off it.

     **Takes the server's rows, not the overlaid ones.** The subtraction is "how many rows
     the server still counts as unread have we already marked", which is unanswerable once
     `overlay` has stamped `read_at` on them: every row looks read, nothing is subtracted,
     and the badge keeps the server's number while the list shows them read.
     */
    func overlayCount(_ serverCount: Int, _ serverRows: [TreebarsNotification]) -> Int {
        if ledger.readThrough != nil {
            // A watermark may cover rows this device has never seen, so it is not countable
            // from one page; what is safe is that it cannot exceed either bound.
            let unmarked = serverRows.filter { $0.read_at == nil }.count
            return max(0, min(serverCount, serverCount - unmarked))
        }
        let marked = serverRows.filter {
            $0.read_at == nil
                && (ledger.read[$0.group_id] == true || ledger.dismissed[$0.group_id] == true)
        }.count
        return max(0, serverCount - marked)
    }

    /// Replaces the cached first page, clearing it first if it belongs to somebody else.
    @discardableResult
    func accept(owner: String, page: NotificationPage, askedAt: Int? = nil) -> Bool {
        if let askedAt, askedAt != generation { return false }
        if let feed, feed.owner != owner {
            self.feed = nil
            ledger = NotificationLedger()
        }
        feed = CachedFeed(
            owner: owner,
            notifications: page.notifications,
            unreadCount: page.unreadCount,
            nextCursor: page.nextCursor,
            topics: page.topics
        )
        forgetConfirmed(page.notifications)
        save()
        return true
    }

    func cached() -> NotificationPage? {
        guard let feed else { return nil }
        // The stored rows are the server's answer as it stood; overlay for display, count
        // against the originals.
        return present(
            feed.notifications,
            serverCount: feed.unreadCount,
            serverTabs: feed.topics,
            nextCursor: feed.nextCursor,
            fromCache: true
        )
    }

    /// One tab's rows out of the cached first page, for when the network cannot answer for that tab. Only what the
    /// first page held, and no cursor: a tab's own pages are network-only.
    func cachedTopic(_ topic: String) -> NotificationPage? {
        guard let page = cached() else { return nil }
        return NotificationPage(
            notifications: page.notifications.filter { $0.topic?.key == topic },
            unreadCount: page.unreadCount,
            nextCursor: nil,
            fromCache: true,
            topics: page.topics
        )
    }

    func noteRead(_ groupID: String) {
        ledger.read[groupID] = true
        save()
    }

    /// A mark-all, of everything or of one tab (`topic`), taken against the server's own clock.
    func noteReadThrough(_ serverTime: String, topic: String? = nil) {
        if let topic {
            ledger.topicReadThrough[topic] = serverTime
        } else {
            ledger.readThrough = serverTime
        }
        save()
    }

    func noteDismissed(_ groupID: String) {
        ledger.dismissed[groupID] = true
        save()
    }

    /// Somebody else is signed in now, without a sign-out between. The cached page and the marks are the last person's,
    /// as a fetch in flight is: all of it goes, so `cached()` has nothing of theirs to answer the next person with.
    func supersede() {
        reset()
    }

    /// Drops everything. Called from `reset()`; the device secret deliberately survives.
    func reset() {
        generation += 1
        feed = nil
        ledger = NotificationLedger()
        UserDefaults.standard.removeObject(forKey: feedKey)
        UserDefaults.standard.removeObject(forKey: ledgerKey)
    }

    private func forgetConfirmed(_ notifications: [TreebarsNotification]) {
        for notification in notifications where notification.read_at != nil {
            ledger.read.removeValue(forKey: notification.group_id)
        }
        if ledger.readThrough != nil, notifications.allSatisfy({ $0.read_at != nil }) {
            ledger.readThrough = nil
        }
        let live = Set(notifications.map(\.group_id))
        ledger.dismissed = ledger.dismissed.filter { live.contains($0.key) }
    }

    private func save() {
        if let feed, let data = try? JSONEncoder().encode(feed) {
            UserDefaults.standard.set(data, forKey: feedKey)
        }
        if let data = try? JSONEncoder().encode(ledger) {
            UserDefaults.standard.set(data, forKey: ledgerKey)
        }
    }
}
