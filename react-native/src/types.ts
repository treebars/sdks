export interface TreebarsConfig {
  /**
   * Public write key (`pk_live_...`). Safe to embed in a shipped binary; it
   * identifies the project, not the user.
   */
  write_key: string;
  /**
   * Where the SDK sends data. Defaults to Treebars' own ingest endpoint, so `{ write_key }`
   * alone is a working configuration.
   *
   * Must be https: plain http is accepted only for a development server on this machine or the
   * local network, and `init()` rejects anything else. The same name as every other Treebars
   * SDK uses (`backendURL` on iOS).
   */
  backendUrl?: string;
  /** @deprecated Renamed to `backendUrl`, which wins when both are given. */
  ingestUrl?: string;
  /** @deprecated Renamed to `backendUrl`. Still honoured, and still beats `ingestUrl`. */
  backend_url?: string;
  /**
   * Which of the project's environments this build reports to. Default `production`; `init()`
   * rejects any value not listed here.
   */
  env?: 'production' | 'stage' | 'test';
  /** Logs what the native SDK is doing to the platform log. Default false. */
  debug?: boolean;
  /**
   * How often queued events are uploaded, in ms. Default 30000 (thirty seconds), the same on
   * every Treebars SDK.
   */
  flush_interval_ms?: number;
  /**
   * Whether to fetch and show in-app messages. Default true. `false` turns both off: nothing
   * is fetched and nothing is drawn.
   */
  in_app_enabled?: boolean;
  /**
   * How often to poll for queued in-app messages, beyond the syncs that already happen on
   * session start and foreground. Default 15 minutes; 0 disables polling entirely, which
   * is the right setting for an app that is only ever open briefly.
   */
  in_app_poll_interval_ms?: number;
  /**
   * @deprecated Ignored. The native SDKs read the running build's version and build number
   * themselves, which is always the build that is actually running.
   */
  app_version?: string;
  /** @deprecated Ignored; see `app_version`. */
  app_build?: string;
  /**
   * Emit `app_open`, `app_foreground` and `app_background` automatically. Default true.
   *
   * Turning this off also turns off the flush that rides on backgrounding, which is the
   * last reliable moment to upload before the OS may kill the process. An app that opts
   * out should call `flush()` from its own background handler.
   */
  auto_track_lifecycle?: boolean;
  /** Emit `session_start` and `session_end` around session boundaries. Default true. */
  auto_track_sessions?: boolean;
  /**
   * Whether this install may report how it arrived: the Play Install Referrer on Android, Apple's
   * AdServices answer on iOS, each sent once per new install. **Default false.**
   *
   * The native SDKs do the reading; this only carries the answer across. Nothing here shows a
   * prompt — an app that asks for consent passes the result here, or to
   * `setAcquisitionConsent()` once it has one, and nothing is lost by waiting. `true` here grants;
   * only the setter withdraws.
   */
  acquisition_consent?: boolean;
  /**
   * **iPhone only, and off by default.** Read the click a Treebars link handed to this device
   * across the App Store, on the first launch of a new install and only with acquisition consent.
   *
   * Nothing survives an App Store install, so this is what makes an install from one of your own
   * links measurable on iPhone at all — and what delivers a deferred deep link to
   * `onDeferredDeepLink` there. It costs one of Apple's "Allow Paste" alerts, which is why it is a
   * decision rather than a default. Android needs none of this: Play carries the click through the
   * install already, and this value is ignored there. The project's Acquisition settings has the
   * other half of the switch; both are needed.
   */
  deferred_handoff?: boolean;
  /**
   * The domains this app declares for Universal Links and App Links — `['open.example.com']` — and
   * the only hosts `handleLink` asks what a link means. Empty or absent asks nothing: a tracker link
   * carrying its click id is still reported, and a link opens the app as it would without the SDK.
   * The same list the app already has in its entitlements and its manifest's intent filters.
   */
  linkHosts?: string[];
  /** Called with a line about each upload the SDK makes, for an app's own debug screen. */
  onUpload?: (log: UploadLog) => void;
}

/**
 * The events the SDK emits on its own. Their names are reserved for the SDK.
 *
 * Exported so an integrator can name one in a funnel or a campaign goal without retyping
 * the string.
 */
export const DEFAULT_EVENTS = {
  APP_OPEN: 'app_open',
  APP_FOREGROUND: 'app_foreground',
  APP_BACKGROUND: 'app_background',
  SESSION_START: 'session_start',
  SESSION_END: 'session_end',
  SCREEN_VIEW: 'screen_view',
  USER_IDENTIFIED: 'user_identified',
  USER_SIGNED_OUT: 'user_signed_out',
  NOTIFICATION_OPENED: 'notification_opened',
  NOTIFICATION_READ: 'notification_read',
  NOTIFICATION_DISMISSED: 'notification_dismissed',
  DEVICE_CONTEXT: 'device_context',
} as const;

export type DefaultEventName = (typeof DEFAULT_EVENTS)[keyof typeof DEFAULT_EVENTS];

/** What `onUpload` is handed: one line about one upload. */
export interface UploadLog {
  type: 'events' | 'user';
  status: 'sending' | 'success' | 'error';
  message: string;
  count?: number;
  eventNames?: string[];
  statusCode?: number;
}

/**
 * An action from a button the person pressed.
 *
 * `in_app` + `custom`: an in-app button set to "Hand the app keys" — `values` are its keys, `delivery_id` the message.
 * `push` + `navigate`: a push's "Open a screen" — `values.screen` and its parameters. `push` + `custom`: a push's keys.
 * An in-app press of any other kind carries its action (`url`, `deep_link`, `track_event`, `set_attribute`, `click`)
 * and `{ value }`.
 */
export interface AppAction {
  source: 'in_app' | 'push';
  type: string;
  values: Record<string, string>;
  delivery_id?: string;
  /** In-app only: which element was pressed, counting from 1 (`button_index`). */
  button_index?: number;
}

/** A message, as the in-app lifecycle events name it. */
export interface InAppCampaignRef {
  delivery_id: string;
  campaign_id?: string;
}

/**
 * `setEventListener`'s events, under the names common engagement SDKs use, and what each hands
 * the listener. `inAppCampaignSelfHandled` changes behaviour: while it is listened to, a message
 * marked self-handled goes here instead of being drawn, and the app reports `selfHandledShown`,
 * `selfHandledClicked` and `selfHandledDismissed`.
 */
export interface TreebarsEvents {
  /** A push's "Open a screen" or its keys (a tap from a closed app is held until this is listened to). */
  pushClicked: AppAction;
  /** A message was shown. */
  inAppCampaignShown: InAppCampaignRef;
  /** Every press in a message, after it is recorded. */
  inAppCampaignClicked: AppAction;
  /** A message was closed. */
  inAppCampaignDismissed: InAppCampaignRef;
  /** A button set to "Hand the app keys". */
  inAppCampaignCustomAction: AppAction;
  /** A self-handled message for the app to draw and report on. */
  inAppCampaignSelfHandled: import('./InApp').InAppMessage;
}

export type TreebarsEventName = keyof TreebarsEvents;

export interface TreebarsUser {
  id: string;
  [key: string]: unknown;
}

export interface EventProperties {
  [key: string]: unknown;
}

/**
 * Keys Treebars puts into a push's data so a tap can be traced back to the send.
 * `trackNotificationOpened` reads them from the payload it is handed; a push without them is
 * not a Treebars push and is ignored.
 */
export const DELIVERY_ID_KEY = 'treebars_delivery_id';
export const CAMPAIGN_ID_KEY = 'treebars_campaign_id';

// A notification can carry an in-app message, so the row shape names its content types.
import type { InAppContent, InAppTokens } from './InApp';

/*
 * ---------------------------------------------------------------------------------------
 * The notification centre's row shape.
 *
 * Public, because this SDK draws no list: every field an app's list reads has to be nameable
 * from outside it.
 * ---------------------------------------------------------------------------------------
 */
export type NotificationChannel = 'push' | 'in_app';

export interface TreebarsNotification {
  /**
   * One notification as the person sees it, across all their devices: a send that reached
   * several of them has one `group_id`. It is the id `markRead`, `markOpened` and `dismiss`
   * take.
   */
  group_id: string;
  campaign_id: string | null;
  channel_type: NotificationChannel;
  /** How many of this person's devices this one send reached. */
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
  /** In-app rows only: the message's resolved style, as an in-app message carries it. */
  style?: InAppTokens;
}

export interface NotificationPage {
  notifications: TreebarsNotification[];
  unreadCount: number;
  /** Pass back as `cursor` for the next page. Null when this is the end. */
  nextCursor: string | null;
  /**
   * True when the network could not be reached and this is what was last persisted.
   *
   * Exposed rather than hidden because a list that silently shows yesterday's page is a
   * screen lying about a round trip. An app can badge it, or ignore it.
   */
  fromCache: boolean;
}
