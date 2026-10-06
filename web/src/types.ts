export interface TreebarsWebConfig {
  /**
   * Whether to fetch and show in-app messages. Default true: a page that calls `init` asks for its messages as it
   * opens and the SDK draws them itself, with nothing more to call.
   *
   * False fetches none and draws none; the page still learns which events a live campaign or journey is waiting on,
   * so those are uploaded promptly. To keep fetching — for the inbox, say — and draw overlays yourself, or not at all,
   * leave this on and call `setInAppRenderer` with a function, or with `null`.
   */
  inAppEnabled?: boolean;
  /** Public write key (`pk_live_...`). Safe to ship in page source. */
  writeKey: string;
  /**
   * A label for the environment these events come from. Defaults to `production`.
   *
   * This SDK stamps it on every event it queues, and reads it nowhere else. The write key is what
   * names the environment — each environment of a project has its own, so the key a page is built
   * with is the whole of that choice.
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
   * Emit `app_open` on load, `app_background` when the page is hidden and stays hidden, and
   * `app_foreground` when it is shown again after that. Default true.
   *
   * A page hidden and shown again within two seconds records neither: a glance at another tab is
   * not somebody leaving, and the time it took counts as time in the foreground. A hide that lasts
   * is recorded with the time the page was hidden; `foreground_ms` is how long the page had been
   * in the foreground by then, and `background_ms` how long it then stayed hidden. A page that is
   * discarded while hidden has its `app_background` recorded by the next page load on the site,
   * still with the time it was hidden.
   *
   * The beacon that saves the queue when the page goes away is not part of this and runs
   * either way: it keeps buffered events from being lost, which is not a tracking preference.
   */
  autoLifecycle?: boolean;
  /**
   * What `app_open`, `app_foreground` and `app_background` call this site, as their `name` property — so a list of
   * events reads "app_open · Acme Shop" rather than rows nobody can tell apart. Defaults to the page's hostname.
   */
  appName?: string;
  /**
   * The least time between two uploads while the page is busy, in milliseconds. Leave it unset for the SDK's own
   * pace.
   *
   * Either way, an event on a quiet page is uploaded about a second after it happens, and a burst inside that second
   * is one upload. What this sets is how soon the NEXT upload may follow on a page that keeps producing events: it
   * waits until this long after the last one began. Unset, that is a few seconds, and Treebars can tune it for your
   * project in its answer to each upload; under a `pk_test_` key it is a second, so what you do shows up as you do
   * it. Set, it is your number, never less than a second.
   *
   * It never holds back a full batch (`batchSize`), the upload as the page is hidden, a `flush()` you call, or an
   * event a live campaign or journey is waiting on. And a browser asked to save data keeps thirty seconds between
   * uploads whatever is set here.
   */
  flushIntervalMs?: number;
  /** Events per upload, and the queue depth that uploads at once, whatever `flushIntervalMs` says. Default `BATCH_SIZE`: 50. */
  batchSize?: number;
  /**
   * Opt out of persisting anything to storage. Events are then kept in memory only
   * and lost on navigation, which some consent regimes require before opt-in.
   *
   * Acquisition included: no carried click is remembered or read back, no `tbrs_bs` cookie is set,
   * and a visit from an ad is not recorded, since recording one sends the browser id, time zone and
   * screen size used to match an iPhone install to the visit. A click id on the page's own address is
   * still carried to its store buttons and reported as `link_opened`, once per page load.
   *
   * And the device cookie of `shareAcrossSubdomains`: it is neither set nor read.
   */
  disableStorage?: boolean;
  /**
   * Be one device across your site's subdomains. Default true.
   *
   * Browser storage belongs to one origin, so on its own `example.com` and `app.example.com` would each mint a
   * device, and one visitor in one browser would be two anonymous people. With this on, the device id and its secret
   * are also kept in a first-party cookie on the parent domain — `tbrs_dv_live`, or `tbrs_dv_test` under a
   * `pk_test_` key — and every subdomain running this SDK adopts the device it finds there. An origin that already
   * had a device of its own moves to the shared one on its next load, and a person signed in there is signed in again
   * on it. Sites on unrelated domains are never joined.
   *
   * **The cookie carries the device's secret**, which is what this browser proves itself with when it reads its
   * in-app messages and notifications or signs somebody in. Like any cookie a page sets, it can be read, and
   * replaced, by scripts on every subdomain of the parent domain, and is sent to those subdomains' servers with each
   * request. Set this to false when that parent domain is shared with sites you do not control — a subdomain of a
   * university's or an employer's domain, or of a hosting platform's that browsers do not treat as a public suffix.
   * The device then lives in this origin's storage alone, and a cookie another subdomain set is neither read nor
   * removed.
   *
   * Neither set nor read with `disableStorage`, or for a visitor who has opted out.
   */
  shareAcrossSubdomains?: boolean;
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
