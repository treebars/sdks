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
}

struct NotificationWireResponse: Codable {
    let notifications: [TreebarsNotification]
    let unread_count: Int
    let next_cursor: String?
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
    }
}

/// Marks this device has made that the server has not confirmed yet.
private struct NotificationLedger: Codable {
    var read: [String: Bool] = [:]
    var dismissed: [String: Bool] = [:]
    /// The `server_time` a mark-all was taken against, if one is outstanding.
    var readThrough: String?
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
        let through = ledger.readThrough.flatMap(InAppStore.parse)
        let now = Iso8601.now()

        return notifications.compactMap { notification in
            if ledger.dismissed[notification.group_id] == true { return nil }
            if notification.read_at != nil { return notification }

            var locallyRead = ledger.read[notification.group_id] == true
            if !locallyRead, let through, let created = InAppStore.parse(notification.created_at) {
                locallyRead = created <= through
            }
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
                style_dark: notification.style_dark
            )
        }
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
            nextCursor: page.nextCursor
        )
        forgetConfirmed(page.notifications)
        save()
        return true
    }

    func cached() -> NotificationPage? {
        guard let feed else { return nil }
        // The stored rows are the server's answer as it stood; overlay for display, count
        // against the originals.
        let notifications = overlay(feed.notifications)
        return NotificationPage(
            notifications: notifications,
            unreadCount: overlayCount(feed.unreadCount, feed.notifications),
            nextCursor: feed.nextCursor,
            fromCache: true
        )
    }

    func noteRead(_ groupID: String) {
        ledger.read[groupID] = true
        save()
    }

    func noteReadThrough(_ serverTime: String) {
        ledger.readThrough = serverTime
        save()
    }

    func noteDismissed(_ groupID: String) {
        ledger.dismissed[groupID] = true
        save()
    }

    /// Somebody else is signed in now, without a sign-out between: a fetch in flight was asked for the last one.
    func supersede() {
        generation += 1
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
