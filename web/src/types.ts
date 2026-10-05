export interface TreebarsWebConfig {
  /**
   * Whether to fetch and show in-app messages. Default true, but nothing is drawn until
   * the page also supplies a renderer through `setInAppRenderer`.
   */
  inAppEnabled?: boolean;
  /** Public write key (`pk_live_...`). Safe to ship in page source. */
  writeKey: string;
  /**
   * Which environment these events belong to. Defaults to `production`.
   *
   * Stamped on every event, as the other Treebars SDKs do, so staging, development and test
   * traffic can be kept apart from production.
   */
  env?: 'production' | 'staging' | 'development' | 'test';
  /**
   * Origin of the ingest endpoint. Defaults to Treebars' own (`https://ingest.treebars.com`),
   * so `{ writeKey }` alone is a working configuration. Set it only to point at a different
   * deployment, or at localhost during development.
   *
   * The same name the other Treebars SDKs use (`backendURL` on iOS).
   */
  backendUrl?: string;
  /** @deprecated Renamed to `backendUrl`, which wins when both are given. */
  ingestUrl?: string;
  /**
   * The Treebars frame an HTML in-app message is drawn in on a site whose Content-Security-Policy stops the SDK's own
   * frame. Defaults to `frame.<your ingest host>` (`https://frame.treebars.com/frame/v1/` for Treebars' own); a strict
   * site allows it once with `frame-src`. `null` turns the fallback off, and such a site then shows no HTML message and
   * reports `csp_blocked`.
   */
  frameUrl?: string | null;
  /** Automatically emit `page_view` on load and on history navigation. Default true. */
  autoPageViews?: boolean;
  /**
   * Query parameters `page_view` keeps on its `url`, beyond the campaign labels (`utm_*`) and click
   * ids it always keeps. Default none.
   *
   * Everything else in a query string is dropped before the event leaves the page, and every fragment
   * but a hash router's route, because that is where reset tokens, magic-link codes and emails travel.
   * Name a parameter here only if it is safe to store for months.
   */
  pageUrlParams?: string[];
  /** Emit `session_start` and `session_end` around session boundaries. Default true. */
  autoSessions?: boolean;
  /**
   * Emit `app_open` on load and `app_foreground` / `app_background` as the tab is hidden
   * and shown. Default true.
   *
   * The beacon that saves the queue when the page goes away is not part of this and runs
   * either way: it keeps buffered events from being lost, which is not a tracking preference.
   */
  autoLifecycle?: boolean;
  /** Upload interval in milliseconds. Default `DEFAULT_FLUSH_INTERVAL_MS`: thirty seconds. */
  flushIntervalMs?: number;
  /** Events per upload, and the queue depth that uploads early. Default `BATCH_SIZE`: 50. */
  batchSize?: number;
  /**
   * Opt out of persisting anything to storage. Events are then kept in memory only
   * and lost on navigation, which some consent regimes require before opt-in.
   *
   * Acquisition included: no carried click is remembered or read back, no `tbrs_bs` cookie is set,
   * and a visit from an ad is not recorded, since recording one sends the browser id, time zone and
   * screen size used to match an iPhone install to the visit. A click id on the page's own address is
   * still carried to its store buttons and reported as `link_opened`, once per page load.
   */
  disableStorage?: boolean;
  /**
   * Carry a click id from the page's address onto its Play Store links. Default true.
   *
   * On by default because the id only arrives when a campaign was pointed at one of your own
   * tracking links, so carrying it to the store is what that choice asked for. Set false where a
   * page must not have its outbound links touched at all — the id is then dropped at the store
   * button and those Android installs are measured as organic.
   */
  carryClickToStore?: boolean;
  /** Log what the SDK does to the browser console, prefixed `[treebars]`. */
  debug?: boolean;
}

export interface EventProperties {
  [key: string]: unknown;
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
  PAGE_VIEW: 'page_view',
  USER_IDENTIFIED: 'user_identified',
  USER_SIGNED_OUT: 'user_signed_out',
  NOTIFICATION_READ: 'notification_read',
  NOTIFICATION_DISMISSED: 'notification_dismissed',
  DEVICE_CONTEXT: 'device_context',
} as const;

export type DefaultEventName = (typeof DEFAULT_EVENTS)[keyof typeof DEFAULT_EVENTS];

export interface QueuedEvent {
  event_id: string;
  session_id: string;
  device_id: string;
  user_id?: string;
  event_name: string;
  properties: EventProperties;
  timestamp: string;
  sdk_version: string;
  sdk_name: string;
  env: string;
  platform_type: 'web';
  app_version?: string;
  app_build?: string;
  device_manufacturer?: string;
  device_model?: string;
  device_type?: string;
  os_name?: string;
  os_version?: string;
  locale?: string;
  timezone?: string;
  screen_name?: string;
  network_type?: string;
  /** Device attributes that have no field of their own. */
  device_extra?: Record<string, unknown>;
}
