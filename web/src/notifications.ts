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
}

export interface NotificationPage {
  notifications: TreebarsNotification[];
  unreadCount: number;
  nextCursor: string | null;
  /** True when the network could not be reached and this is what was last persisted. */
  fromCache: boolean;
}

export interface NotificationWireResponse {
  notifications: TreebarsNotification[];
  unread_count: number;
  next_cursor: string | null;
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
}

interface Ledger {
  read: Record<string, true>;
  dismissed: Record<string, true>;
  readThrough: string | null;
}

/**
 * A function, not a constant.
 *
 * Spreading one shared literal is a shallow copy, so every store built from it would share
 * the same `read` and `dismissed` maps — marking a row read in one would mark it read in all
 * of them. A fresh object each time keeps every store, and every `reset()`, its own.
 */
const emptyLedger = (): Ledger => ({ read: {}, dismissed: {}, readThrough: null });

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
    const through = this.ledger.readThrough ? Date.parse(this.ledger.readThrough) : 0;
    return notifications
      .filter((notification) => !this.ledger.dismissed[notification.group_id])
      .map((notification) => {
        if (notification.read_at) return notification;
        const locallyRead =
          this.ledger.read[notification.group_id] ||
          (through > 0 && Date.parse(notification.created_at) <= through);
        return locallyRead ? { ...notification, read_at: new Date().toISOString() } : notification;
      });
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
    };
    this.forgetConfirmed(page.notifications);
    this.write();
  }

  cached(): NotificationPage | null {
    if (!this.feed) return null;
    // The stored rows are the server's answer as it stood; overlay for display, count
    // against the originals.
    const notifications = this.overlay(this.feed.notifications);
    return {
      notifications,
      unreadCount: this.overlayCount(this.feed.unreadCount, this.feed.notifications),
      nextCursor: this.feed.nextCursor,
      fromCache: true,
    };
  }

  noteRead(groupId: string): void {
    this.ledger.read[groupId] = true;
    this.write();
  }

  noteReadThrough(serverTime: string): void {
    this.ledger.readThrough = serverTime;
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
