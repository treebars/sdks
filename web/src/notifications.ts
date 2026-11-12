import type { InAppContent, InAppTokens } from './in-app';
import { safeGet, safeRemove, safeSet } from './storage';

/*
 * The notification centre, in a browser.
 *
 * Data, and only data — the page draws the list (or mounts the ready-made one in
 * `notification-center.ts`). Written as its own module rather than folded into `in-app.ts`
 * because the two answer different questions: that one holds a queue the SDK matches
 * triggers against, this one pages a history the page scrolls.
 */

const FEED_KEY = 'treebars.notifications.v1';
const LEDGER_KEY = 'treebars.notification_ledger.v1';

export type NotificationChannel = 'push' | 'in_app';

/**
 * The topic a notification was sent under: one of the project's tabs for the centre, by its `key` (what `list` and
 * `markAllRead` take) and the `name` a tab shows.
 */
export interface NotificationTopicRef {
  key: string;
  name: string;
}

/**
 * One tab of the centre, with its counts. `key` null is All, which comes first and counts everything — the sends with
 * no topic included — so its `unread` is the badge.
 */
export interface NotificationTopic {
  key: string | null;
  name: string;
  unread: number;
  total: number;
}

export interface TreebarsNotification {
  /**
   * One send, however many devices it reached.
   *
   * A notification sent to several of a person's devices is delivered to each separately, so
   * an open on one device does not mark another's; this id groups those deliveries back into
   * the one notification the person was sent, and it is the id to pass when marking it read,
   * opened or dismissed.
   */
  group_id: string;
  campaign_id: string | null;
  channel_type: NotificationChannel;
  device_count: number;
  content: {
    title?: string;
    body?: string;
    image_url?: string;
    deep_link?: string;
    data?: Record<string, string>;
    in_app?: InAppContent;
  };
  created_at: string;
  read_at: string | null;
  opened_at: string | null;
  expires_at: string | null;
  style?: InAppTokens;
  /** The topic it was sent under, or null when it has none. Absent on rows kept from before topics existed. */
  topic?: NotificationTopicRef | null;
}

export interface NotificationPage {
  notifications: TreebarsNotification[];
  unreadCount: number;
  nextCursor: string | null;
  /** True when the network could not be reached and this is what was last persisted. */
  fromCache: boolean;
  /**
   * The centre's tabs with their counts, All first, on a first page only. Absent when the server sent none — a
   * project's centre with no topics, or a server older than them — and a page then draws no topic tabs.
   */
  topics?: NotificationTopic[];
}

export interface NotificationWireResponse {
  notifications: TreebarsNotification[];
  unread_count: number;
  next_cursor: string | null;
  topics?: NotificationTopic[];
  claim_required?: boolean;
  /** Set when a live environment wanted a valid `signature` (see `identify`) for the signed-in account id, and the read had none. */
  signature_required?: boolean;
  server_time: string;
}

interface CachedFeed {
  /** `userId ?? deviceId` at the moment of the fetch. See `accept`. */
  owner: string;
  notifications: TreebarsNotification[];
  unreadCount: number;
  nextCursor: string | null;
  /** The tabs as they came with these rows, so the two are drawn again as one answer. */
  topics?: NotificationTopic[];
}

interface Ledger {
  read: Record<string, true>;
  dismissed: Record<string, true>;
  readThrough: string | null;
  /** A mark-all of one tab: the `server_time` it was taken against, by topic key. */
  topicReadThrough: Record<string, string>;
}

/**
 * A function, not a constant.
 *
 * Spreading one shared literal is a shallow copy, so every store built from it would share
 * the same `read` and `dismissed` maps — marking a row read in one would mark it read in all
 * of them. A fresh object each time keeps every store, and every `reset()`, its own.
 */
const emptyLedger = (): Ledger => ({ read: {}, dismissed: {}, readThrough: null, topicReadThrough: {} });

/**
 * Synchronous throughout, like everything else in this package.
 *
 * `localStorage` is synchronous, so making these async would buy nothing and would make
 * every caller `await` for no round trip.
 */
export class NotificationStore {
  private feed: CachedFeed | null = null;
  private ledger: Ledger = emptyLedger();

  constructor(private persist: boolean) {
    if (!persist) return;
    try {
      const feed = safeGet(FEED_KEY);
      if (feed) this.feed = JSON.parse(feed) as CachedFeed;
      const ledger = safeGet(LEDGER_KEY);
      if (ledger) this.ledger = { ...emptyLedger(), ...(JSON.parse(ledger) as Ledger) };
    } catch {
      // A corrupt cache is an empty cache. This runs while a page is mounting a list.
      this.feed = null;
      this.ledger = emptyLedger();
    }
  }

  /**
   * Overlays what this browser has done onto what the server just said.
   *
   * Without it a click sets a row from unread to read, the next refresh sets it back, and
   * the reader clicks again. Entries are dropped as soon as the server's own row agrees.
   */
  overlay(notifications: TreebarsNotification[]): TreebarsNotification[] {
    return notifications
      .filter((notification) => !this.ledger.dismissed[notification.group_id])
      .map((notification) => {
        if (notification.read_at) return notification;
        const locallyRead = this.ledger.read[notification.group_id] || this.coveredByWatermark(notification);
        return locallyRead ? { ...notification, read_at: new Date().toISOString() } : notification;
      });
  }

  /** Whether a mark-all this browser made — of everything, or of this row's own tab — reaches back to this row. */
  private coveredByWatermark(notification: TreebarsNotification): boolean {
    const created = Date.parse(notification.created_at);
    if (Number.isNaN(created)) return false;
    const all = this.ledger.readThrough ? Date.parse(this.ledger.readThrough) : 0;
    if (all > 0 && created <= all) return true;
    const key = notification.topic?.key;
    const tab = key ? this.ledger.topicReadThrough[key] : undefined;
    return tab !== undefined && created <= Date.parse(tab);
  }

  /**
   * The server's tabs with this browser's unwritten marks taken off them, as nearly as one answer allows.
   *
   * A mark-all of everything empties every tab, and a mark-all of one tab empties that tab and takes its unread off
   * All. A row marked on its own is taken off its tab and off All only when it came in the same answer as the tabs —
   * a tab's other rows are not here to look at, and the write that marks it is usually acknowledged before anybody
   * reads the tabs again. `badge` is the page's own unread count, and All is never more than it, so the two agree.
   */
  overlayTopics(serverTabs: NotificationTopic[], serverRows: TreebarsNotification[], badge: number): NotificationTopic[] {
    const everything = this.ledger.readThrough !== null;
    const watermarked = (key: string) => everything || this.ledger.topicReadThrough[key] !== undefined;
    const offTab = new Map<string, number>();
    let offAll = 0;
    for (const tab of serverTabs) {
      if (tab.key !== null && watermarked(tab.key)) {
        offTab.set(tab.key, tab.unread);
        offAll += tab.unread;
      }
    }
    for (const row of serverRows) {
      if (row.read_at || !(this.ledger.read[row.group_id] || this.ledger.dismissed[row.group_id])) continue;
      const key = row.topic?.key ?? null;
      if (key !== null && watermarked(key)) continue;
      offAll += 1;
      if (key !== null) offTab.set(key, (offTab.get(key) ?? 0) + 1);
    }
    return serverTabs.map((tab) => {
      if (tab.key === null) {
        const unread = everything ? 0 : Math.max(0, tab.unread - offAll);
        return { ...tab, unread: Math.min(unread, badge) };
      }
      return { ...tab, unread: Math.max(0, tab.unread - (offTab.get(tab.key) ?? 0)) };
    });
  }

  /**
   * Forgets a tab's mark-all once the server agrees there is nothing unread in it, or no longer has the tab.
   *
   * Kept apart from the rows' own reconciliation because a first page may hold no row of that tab at all, and "every
   * row of it is read" is then true of nothing — which would drop the mark while its write is still in flight.
   */
  settleTopics(serverTabs: NotificationTopic[]): void {
    const unreadByKey = new Map(serverTabs.map((tab) => [tab.key, tab.unread]));
    let changed = false;
    for (const key of Object.keys(this.ledger.topicReadThrough)) {
      const unread = unreadByKey.get(key);
      if (unread === undefined || unread === 0) {
        delete this.ledger.topicReadThrough[key];
        changed = true;
      }
    }
    if (changed) this.write();
  }

  /** The rows, the badge and the tabs as this browser should draw them, from one answer of the server's. */
  present(
    serverRows: TreebarsNotification[],
    serverCount: number,
    serverTabs: NotificationTopic[] | undefined,
  ): Pick<NotificationPage, 'notifications' | 'unreadCount' | 'topics'> {
    const unreadCount = this.overlayCount(serverCount, serverRows);
    if (!serverTabs) return { notifications: this.overlay(serverRows), unreadCount };
    const topics = this.overlayTopics(serverTabs, serverRows, unreadCount);
    return {
      notifications: this.overlay(serverRows),
      // All's tab is the badge; when the tabs know of more marked than the rows do, the badge follows them.
      unreadCount: Math.min(unreadCount, topics[0]?.key === null ? topics[0].unread : unreadCount),
      topics,
    };
  }

  /**
   * **Takes the server's rows, not the overlaid ones.**
   *
   * The subtraction is "how many rows the server still counts as unread has this browser
   * already marked", which is unanswerable once `overlay` has stamped `read_at` on them:
   * every row looks read, nothing is subtracted, and the badge keeps the server's number
   * while the list shows them as read.
   */
  overlayCount(serverCount: number, serverRows: TreebarsNotification[]): number {
    if (this.ledger.readThrough) {
      const unmarked = serverRows.filter((row) => !row.read_at).length;
      return Math.max(0, Math.min(serverCount, serverCount - unmarked));
    }
    const marked = serverRows.filter(
      (row) =>
        !row.read_at && (this.ledger.read[row.group_id] || this.ledger.dismissed[row.group_id]),
    ).length;
    return Math.max(0, serverCount - marked);
  }

  /**
   * Replaces the cached first page.
   *
   * The check of whose list this is runs here and not only in `reset()`, and that is the point: when a page
   * calls `identify(b)` on a browser that was signed in as `a` without an intervening
   * `reset()`, `a`'s cached notifications and marks are dropped here, so they are never
   * drawn under `b`'s name.
   */
  accept(owner: string, page: NotificationPage): void {
    if (this.feed && this.feed.owner !== owner) {
      this.feed = null;
      this.ledger = emptyLedger();
    }
    this.feed = {
      owner,
      notifications: page.notifications,
      unreadCount: page.unreadCount,
      nextCursor: page.nextCursor,
      ...(page.topics ? { topics: page.topics } : {}),
    };
    this.forgetConfirmed(page.notifications);
    this.write();
  }

  cached(): NotificationPage | null {
    if (!this.feed) return null;
    // The stored rows are the server's answer as it stood; overlay for display, count
    // against the originals.
    return {
      ...this.present(this.feed.notifications, this.feed.unreadCount, this.feed.topics),
      nextCursor: this.feed.nextCursor,
      fromCache: true,
    };
  }

  /**
   * One tab's rows out of the cached first page, for when the network cannot answer for that tab. Only what the first
   * page held, and no cursor: a tab's own pages are network-only.
   */
  cachedTopic(topic: string): NotificationPage | null {
    const page = this.cached();
    if (!page) return null;
    return { ...page, notifications: page.notifications.filter((row) => row.topic?.key === topic), nextCursor: null };
  }

  noteRead(groupId: string): void {
    this.ledger.read[groupId] = true;
    this.write();
  }

  /** A mark-all, of everything or of one tab (`topic`), taken against the server's own clock. */
  noteReadThrough(serverTime: string, topic?: string | null): void {
    if (topic) this.ledger.topicReadThrough[topic] = serverTime;
    else this.ledger.readThrough = serverTime;
    this.write();
  }

  noteDismissed(groupId: string): void {
    this.ledger.dismissed[groupId] = true;
    this.write();
  }

  reset(): void {
    this.feed = null;
    this.ledger = emptyLedger();
    this.write();
  }

  private forgetConfirmed(notifications: TreebarsNotification[]): void {
    for (const notification of notifications) {
      if (notification.read_at) delete this.ledger.read[notification.group_id];
    }
    if (this.ledger.readThrough && notifications.every((n) => n.read_at)) {
      this.ledger.readThrough = null;
    }
    const live = new Set(notifications.map((n) => n.group_id));
    for (const id of Object.keys(this.ledger.dismissed)) {
      if (!live.has(id)) delete this.ledger.dismissed[id];
    }
  }

  private write(): void {
    if (!this.persist) return;
    // An emptied feed is removed, not left: the stored copy is what the next page load reads back, and `cached()`
    // hands that over without asking whose it is.
    if (this.feed) safeSet(FEED_KEY, JSON.stringify(this.feed));
    else safeRemove(FEED_KEY);
    safeSet(LEDGER_KEY, JSON.stringify(this.ledger));
  }
}
