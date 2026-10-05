import {
  defaultUserAttributes,
  getWebDeviceContext,
  getWebDeviceDimensions,
  hashDeviceContext,
} from './device';
import { SessionManager } from './session';
import {
  carriedClick,
  deviceSignals,
  forgetSharedBrowserId,
  hasAdClick,
  rememberClick,
  sharedBrowserId,
  watchStoreLinks,
} from './acquisition';
import { analyticsReferrer, analyticsUrl } from './page-url';
import {
  EventStore,
  canMintSecrets,
  getDeviceId,
  getFetchSecret,
  readFirstSeen,
  readOptedOut,
  dropStoredQueue,
  wipeStoredData,
  claimStoredData,
  writeOptedOut,
  clearSignedInUser,
  readIdentifiedUser,
  readSignedInUser,
  readSignedInUserSignature,
  writeSignedInUser,
  shouldReportContext,
  writeIdentifiedUser,
} from './storage';
import {
  InAppStore,
  clickValues,
  formKeeps,
  inAppClickEndsMessage,
  inAppClickProperties,
  inAppReceipt,
  isNudge,
  triggerMatches,
  type InAppButton,
  type InAppMessage,
  type InAppSyncResponse,
  type InAppTokens,
} from './in-app';
import { IN_APP_CONTAINER } from './generated/bridge';
import {
  byPriority,
  contextsMatch,
  deviceClass,
  pageRulesMatch,
  renderBuiltIn,
  sessionRulesMatch,
  pushAskableBlock,
  type InAppFailureReason,
} from './on-site';
import { safeGet, safeSet } from './storage';
import { BridgeDisplay } from './bridge-calls';
import type { FrameMode } from './bridge-host';
import {
  NotificationStore,
  type NotificationChannel,
  type NotificationPage,
  type NotificationWireResponse,
} from './notifications';

/**
 * The SDK's own engagement reports, which must never trigger another message: every `in_app_` name. A prefix rather
 * than a list, so a new report is covered without a change here; a template's own `trackEvent` may not use the prefix,
 * so none of the site's own events is caught by it.
 */
const isInAppReport = (eventName: string): boolean => eventName.startsWith('in_app_');
/**
 * Traits a message set with nobody signed in, sent on the event queue because `/v1/identify` needs an account id. The
 * name is reserved for the SDK.
 */
const TRAITS_SET_EVENT = 'traits_set';
/** A string's SHA-256 as lowercase hex: how a large in-app body is checked against its `html_ref`. */
async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
}

/** Whether this session found `srcdoc` frames stopped by the site's policy, and so uses the Treebars frame. */
const FRAME_MODE_KEY = 'treebars.in_app_frame.v1';

/**
 * The Treebars frame for an ingest origin: `frame.` in place of a leading `ingest.` (`https://frame.treebars.com/frame/v1/`
 * for `https://ingest.treebars.com`), and the ingest origin itself for any other host — a proxy, a local server — which
 * serves the same page at the same path. Null when `backendUrl` is not a URL.
 */
export function frameUrlFor(backendUrl: string): string | null {
  try {
    const origin = new URL(backendUrl);
    if (origin.hostname.startsWith('ingest.')) origin.hostname = `frame.${origin.hostname.slice('ingest.'.length)}`;
    return `${origin.origin}/frame/v1/`;
  } catch {
    return null;
  }
}

/** `<delivery>:<reason>` → the local day it was last reported, so a held-back message is counted once a day. */
const FAILED_KEY = 'treebars.in_app_failed.v1';
/** The id of this browser's first session, which is what a "new visitor" session rule asks about. */
const FIRST_SESSION_KEY = 'treebars.first_session.v1';
/** How often a previewed draft asks whether it was saved again: a save in the editor shows within this long. */
const PREVIEW_POLL_MS = 2_000;
/** How long `contextToken()` waits for the server: a checkout is waiting on the answer, and without one it goes ahead unlinked. */
const CONTEXT_TOKEN_TIMEOUT_MS = 5_000;
/**
 * Whether the tab is hidden. `visibilityState` and not `document.hidden`: the second is `true` under a DOM with no
 * rendering (jsdom), which would read every test page as one nobody can see.
 */
const pageHidden = (): boolean => typeof document !== 'undefined' && document.visibilityState === 'hidden';
import { DEFAULT_EVENTS } from './types';
import type { TreebarsWebConfig, EventProperties, QueuedEvent } from './types';
import { TriggerEvents, readTriggerList, type TriggerList } from './triggers';
import { Uploader, UploaderStore, type PendingBatch, type UploadResponse } from './uploader';
import { claimWithRetries, rewardRefusal, type RewardAttempt } from './reward-claim';
import { BATCH_SIZE, DEFAULT_BACKEND_URL, DEFAULT_FLUSH_INTERVAL_MS, ENDPOINTS, HEADERS, SDK_NAME, SDK_VERSION, ACQUISITION, IN_APP_PRESENTATION_HOLD_MS, PUSH_PERMISSION_LINK, WEB_EVENTS } from './generated/constants';

/**
 * The SDK's own reports that the page is going away, which are never a moment to show anything.
 *
 * An `immediate` trigger matches every event, and `app_background` is tracked on the way out — so a message drawn then
 * would be drawn on the page being left: counted as displayed and its caps spent, with nobody to see it and nothing
 * left for the next page to draw. `session_end` is history, sent for a session that has already ended.
 */
const LEAVING_EVENTS = new Set<string>([DEFAULT_EVENTS.APP_BACKGROUND, DEFAULT_EVENTS.SESSION_END]);

export type { TreebarsWebConfig, EventProperties } from './types';
export type {
  InAppBodyMode,
  InAppButton,
  InAppContent,
  InAppHtmlAction,
  InAppMessage,
  InAppShape,
  InAppTokens,
  InAppTrigger,
} from './in-app';
/*
 * Exported because the host page draws the message and therefore has to read it the same
 * way this SDK does. `layout` alone does not answer "where does this go" once custom HTML
 * can be a body rather than a shape, and `treebars://` is the only channel sandboxed
 * markup has back into the SDK.
 */
export { inAppBodyMode, inAppShape, readInAppHtmlAction } from './in-app';

/* The notification centre's row shape, because the page is the renderer. */
export type {
  NotificationChannel,
  NotificationPage,
  TreebarsNotification,
} from './notifications';
import { WebPush } from './push';
import { mountNotificationCenter, type NotificationCenterOptions } from './notification-center';
export type { NotificationCenterOptions } from './notification-center';
export type { InAppCard } from './in-app';

/**
 * How the host page draws an overlay.
 *
 * A callback rather than markup this package injects: the SDK decides *which* message and
 * *when*, and the page decides what it looks like. Injecting a DOM node would mean owning
 * z-index, focus trapping and the page's own styling, all of which belong to the page.
 */
export type WebInAppRenderer = (view: InAppView) => void;

/**
 * What a renderer is handed: the message, its style tokens, and the callbacks that report what happened to it.
 * `onSubmit` is for a message with a form: the answers by field id, which the SDK reports as `in_app_form_submitted` —
 * and an email or phone field the form keeps becomes the person's address.
 */
export interface InAppView {
  message: InAppMessage;
  tokens: InAppTokens | null;
  onClick: (button: InAppButton) => void;
  /** `auto` when the message closed itself after `auto_dismiss_seconds`. */
  onDismiss: (reason?: 'auto') => void;
  onSubmit: (responses: Record<string, string | number>) => void;
  /**
   * The built-in renderer's: the message is on screen — for an HTML body, when its bridge says it is running. A page's
   * own renderer need not call it; the SDK counts the display when the renderer returns.
   */
  onShown?: (drawn?: { pushedDown?: number }) => void;
  /** The built-in renderer's: an HTML body could not be shown after all (`csp_blocked`). */
  onFailed?: (reason: InAppFailureReason) => void;
  /**
   * An HTML body's `treebars` bridge: each call from the page, answered. A page drawing HTML itself can host the bridge
   * by handing its frame's calls here; `close` takes the message down without a report.
   */
  bridge?: (method: string, args: unknown[], close: () => void) => unknown;
  /** The Treebars frame for a site with a strict Content-Security-Policy, and which frame this session found works. */
  frame?: { url: string | null; mode: FrameMode; remember: (mode: FrameMode) => void };
}

/**
 * `treebars.onsite`: self-handled messages, which the page draws itself and reports on. The method names match those
 * common engagement SDKs use, so a migration keeps its call sites.
 */
export interface TreebarsOnsite {
  /**
   * Hands `callback` the self-handled message eligible now, at once when there is one, and every one that triggers after
   * this — instead of passing them to the renderer. `null` stops listening. Nothing counts as displayed until the page
   * calls `selfHandledShown`.
   */
  getSelfHandledOSM(callback: ((message: InAppMessage) => void) | null): void;
  /** Call when the page has shown the message: it is counted as displayed and spends its caps, as any display does. */
  selfHandledShown(message: InAppMessage): void;
  /** Call when the message was pressed; `button` names what, when there is one. A call to action ends the message. */
  selfHandledClicked(message: InAppMessage, button?: InAppButton): void;
  /** Call when the message was dismissed. It is not offered again in this browser. */
  selfHandledDismissed(message: InAppMessage): void;
}
export { urlRuleMatches, sessionRulesMatch, pageRulesMatch, countdownText } from './on-site';
export type { InAppDisplayRules, InAppFailureReason, InAppForm, InAppFormField, InAppSessionRule, InAppSlide, InAppUrlRule } from './on-site';
export { DEFAULT_EVENTS } from './types';
export type { PromptResult, PushPromptOptions, SubscribeResult, WebPushOptions } from './push';

/**
 * The largest upload body sent with `keepalive`, in bytes.
 *
 * A keepalive request whose body would take the page's in-flight keepalive total past 64 KiB is
 * refused before it reaches the network — in Chromium, 65,536 bytes go through and 65,537 fail with
 * `TypeError: Failed to fetch`, the same bytes without `keepalive` go through, and a smaller
 * request sent while a large one is still settling fails too. Fifty events can reach that size,
 * and the refusal looks like a network error, which would retry the same bytes indefinitely.
 *
 * Under the line keepalive is kept, because it is what lets an upload started just before a
 * navigation finish. Over it the request goes without, and a navigation that cancels it costs
 * nothing: the batch is still pending in storage and the next page load sends it. The margin
 * under 64 KiB is for anything else in flight on the same quota, including this page's own
 * beacons.
 */
const KEEPALIVE_MAX_BYTES = 60_000;

/**
 * Bodies shorter than this go uncompressed: gzip's header and dictionary make a short body longer,
 * and a batch that small is an event or two nobody is waiting on.
 */
const GZIP_MIN_BYTES = 1_024;

/**
 * A batch's JSON, gzipped, or null when it is too small to be worth it or the browser cannot.
 *
 * Batches are JSON with the same keys fifty times over, so they shrink several-fold — which is
 * bytes off a phone's data plan, and more batches under the keepalive quota above, which a
 * compressed body is measured against. The Android and iOS SDKs compress their batches too.
 */
async function gzip(json: string): Promise<ArrayBuffer | null> {
  const bytes = new TextEncoder().encode(json);
  if (bytes.byteLength < GZIP_MIN_BYTES || typeof CompressionStream === 'undefined') return null;
  try {
    const stream = new Blob([bytes]).stream().pipeThrough(new CompressionStream('gzip'));
    return await new Response(stream).arrayBuffer();
  } catch {
    // A browser that has the class and refuses to run it still gets its batch sent, plainly.
    return null;
  }
}

/**
 * The browser SDK.
 *
 * Two constraints drive the design. First, a page can be closed mid-flush, so the
 * queue is persistent and the final upload is a `keepalive` fetch, which the browser
 * completes after the document is gone. Second, analytics must never break the host
 * page, so every storage and network call is guarded and failures degrade to
 * dropping data rather than throwing into application code.
 */
class TreebarsWeb {
  /**
   * The gzip copy of the batch last sent, for the beacon — which runs as the page goes away and
   * cannot wait for a compression to finish. A batch is resent under its own id until it is
   * answered, so the copy a flush made is the copy a beacon may reuse.
   */
  private compressed: { batchId: string; bytes: ArrayBuffer } | null = null;
  private config: TreebarsWebConfig | null = null;
  private store: EventStore | null = null;
  private sessions: SessionManager | null = null;
  private deviceId = '';
  /*
   * Read once, beside the device id, and held. `getFetchSecret` mints a new one per call when storage
   * is off, and every request this page makes has to present the same secret.
   */
  private fetchSecret = '';
  /**
   * Which sign-in a content read belongs to: bumped whenever the signed-in person changes.
   *
   * A read is an await, and `reset()` or `identify()` for somebody else can land inside it. A read whose epoch has
   * moved on is dropped, so what comes back for the previous person is never stored or shown to the next.
   */
  private identityEpoch = 0;
  private inApp: InAppStore | null = null;
  /*
   * Always constructed, unlike the overlay renderer: reading a history draws nothing over
   * anybody's page, and a site that never calls `notifications.list()` pays one
   * localStorage read for it.
   */
  private notificationStore: NotificationStore | null = null;
  private notificationWatchers = new Set<(page: NotificationPage) => void>();
  /** Whatever `server_time` the last successful page carried. The `markAllRead` watermark. */
  private lastNotificationServerTime: string | null = null;
  private renderer: WebInAppRenderer | 'builtin' | null = null;
  /** The page's contexts (`setInAppContext`). */
  private appContexts = new Set<string>();
  /** Whether TREEBARS_LIFECYCLE's SETTINGS_FETCHED has been announced, which it is once. */
  private settingsAnnounced = false;
  /** Where a self-handled message goes, set by `onsite.getSelfHandledOSM`. */
  private selfHandledCallback: ((message: InAppMessage) => void) | null = null;
  /** The one message waiting for its on-site moment — a delay, a scroll depth, an exit — and how to stop waiting. */
  private pendingDisplay: { deliveryId: string; cancel: () => void } | null = null;
  /**
   * When the overlay on screen was drawn, or null when none is.
   *
   * One at a time across events, not only within one: a product page fires `page_view`, `screen_view` and the page's
   * own event within milliseconds, and each could otherwise draw a queued message over the last. The screen is held
   * from the draw until the person answers — a dismissal, a call to action, a form — or `IN_APP_PRESENTATION_HOLD_MS`
   * has passed, the same ceiling the iOS and Android SDKs use for a renderer that never reports back.
   */
  private presentingSince: number | null = null;
  /**
   * The nudges on screen, by delivery, each with its close: a slot of their own beside the one a modal takes, so a
   * modal may be drawn over them and neither waits for the other.
   */
  private readonly nudges = new Map<string, () => void>();
  /**
   * Of those, the ones drawn and not yet on screen: a nudge is counted when shown, and three drawn by one event are
   * three before any of them reports, so the nudge caps count these too. Every way a slot is freed clears one.
   */
  private readonly nudgesInFlight = new Set<string>();
  /**
   * Held until the screen is freed rather than for the hold: a markup body this SDK draws itself says when it ends on
   * every path, and a person partway through a multi-screen message must not have the next one drawn over it.
   */
  private presentingPinned = false;
  /** Whether this page has drawn a markup body: the first frame pays for its own start (`cold` on `in_app_displayed`). */
  private markupDrawn = false;
  /** The Treebars frame an HTML body falls back to on a strict-CSP site, or null for none; see `frameUrlFor`. */
  private frameUrl: string | null = null;
  /** Which frame worked on this page, before sessionStorage is asked. */
  private frameModeSeen: FrameMode | null = null;
  private currentSessionId: string | null = null;
  private inAppEnabled = true;
  private userId: string | undefined;
  /**
   * The customer's backend's signature of `userId`, which an environment that requires signed
   * identities asks for on every content read. Kept beside the id and cleared with it: a signature is
   * only ever a claim about the person it names.
   */
  private userSignature: string | undefined;
  /** Whether the page has been told its environment wants a signature. Once per load is enough. */
  private warnedSignature = false;
  private timer: ReturnType<typeof setInterval> | null = null;
  private uploader: Uploader | null = null;
  private triggers: TriggerEvents | null = null;
  /** The one-shot wake the uploader asks for: a retry falling due, or a listed event's debounce. */
  private wakeTimer: ReturnType<typeof setTimeout> | null = null;
  private started = false;
  /** Removes the store-link listener. Only `shutdown` calls it. */
  private stopStoreLinks: (() => void) | null = null;
  private persist = true;
  private firstSeenAt: string | undefined;
  /** When the tab last changed visibility, so a transition can say how long it lasted. */
  private visibilityChangedAt = Date.now();
  private previewing = false;
  /** A draft from the editor's "Test on device" being shown, and the loop that redraws it. */
  private inAppPreview: { session: string; revision: string; timer: ReturnType<typeof setInterval> | null } | null = null;
  /** Takes the drawn preview down, so a saved draft replaces it rather than stacking on it. */
  private previewClose: (() => void) | null = null;
  /** The ingest endpoint's origin, trailing slash already removed. Set in `init`. */
  private backendUrl = DEFAULT_BACKEND_URL;
  /**
   * `optOut()`: nothing recorded and nothing sent from this browser until `optIn()`. Set before `init`
   * when a consent prompt answers first, and read back from storage by it.
   */
  private optedOut = false;
  /**
   * An answer given before `init`, which it keeps over whatever an earlier visit stored — and stores
   * only then, once it knows whether the page allows storage at all (`disableStorage`).
   */
  private answerBeforeInit: boolean | null = null;
  /** Whether the page lets this SDK use storage at all (`disableStorage`), which the opt-out obeys too. */
  private storageAllowed = true;

  /**
   * Web push for this browser. Call `treebars.push.subscribe({ vapidPublicKey })` from a click handler, or
   * `treebars.push.prompt({ ... })` to explain first with a soft prompt and ask the browser only after a yes. The site
   * serves the service worker (`treebars-sw.js`) from its own origin. See `./push`.
   */
  readonly push = new WebPush({
    track: (event, properties) => this.track(event, properties as EventProperties),
    flush: () => this.flush(),
    persist: () => this.persist,
  });

  /**
   * Starts the SDK. Call it once, as early in the page as you can; later calls are ignored.
   *
   * Only `writeKey` is required, and `init` throws without it. A browser without `crypto.getRandomValues` gets a
   * console warning and the SDK stays off. Unless the config turns them off, `init` records `app_open` and the first
   * `page_view`, records a `page_view` on each history navigation of a single-page app, uploads on a timer and whenever
   * `batchSize` events are waiting, and sends at once anything an earlier page load left unsent.
   *
   * Call `optOut()` before `init` when a consent prompt answers first; `init` keeps that answer.
   */
  init(config: TreebarsWebConfig): void {
    if (this.started) return;
    if (!config.writeKey) throw new Error('Treebars: `writeKey` is required');
    if (!canMintSecrets()) {
      // Off, rather than running with a device secret anybody could reproduce (`canMintSecrets`).
      console.warn('Treebars: this browser has no crypto.getRandomValues, so the SDK stays off.');
      return;
    }

    this.config = config;
    // Resolved once, so the three places that build a URL cannot disagree about the default.
    this.backendUrl = (config.backendUrl ?? config.ingestUrl ?? DEFAULT_BACKEND_URL).replace(
      /\/$/,
      '',
    );
    this.frameUrl = config.frameUrl === undefined ? frameUrlFor(this.backendUrl) : config.frameUrl;
    this.storageAllowed = !config.disableStorage;
    if (this.answerBeforeInit === null) {
      this.optedOut = readOptedOut(this.storageAllowed);
    } else {
      this.optedOut = this.answerBeforeInit;
      writeOptedOut(this.answerBeforeInit, this.storageAllowed);
    }
    /*
     * An opted-out browser keeps nothing: every store runs in memory, as `disableStorage` has them, so
     * no device id or secret is minted into the browser of a person who said no. And what an earlier
     * visit left unsent goes, since these stores will never read it (`dropStoredQueue`).
     */
    if (this.optedOut && this.storageAllowed) dropStoredQueue();
    const persist = this.storageAllowed && !this.optedOut;
    /*
     * Before any store is built, because each reads what it holds once, as it is built: what another write key left —
     * its unsent events, its session, its in-app queue — is dropped rather than sent or drawn under this one
     * (`claimStoredData`).
     */
    if (persist && claimStoredData(config.writeKey)) {
      this.log('the write key changed: what the previous key left unsent, its session and its messages were dropped');
    }

    this.store = new EventStore(persist);
    this.triggers = new TriggerEvents({
      persist,
      fetch: () => this.fetchTriggerEvents(),
      log: (message) => this.log(message),
    });
    this.uploader = new Uploader({
      queue: this.store,
      store: new UploaderStore(persist),
      transport: (batch) => this.sendBatch(batch),
      writeKey: config.writeKey,
      batchSize: config.batchSize,
      log: (message) => this.log(message),
      wake: (at) => this.wake(at),
      triggers: this.triggers,
    });
    this.sessions = new SessionManager(persist);
    this.deviceId = getDeviceId(persist);
    this.fetchSecret = getFetchSecret(persist);

    /*
     * Off unless the page supplies a renderer: an SDK that started drawing over somebody
     * else's page because a campaign was published would be the wrong default, and there
     * is nothing sensible to draw without knowing the page's own layout.
     */
    this.inAppEnabled = config.inAppEnabled !== false;
    this.inApp = new InAppStore(persist);
    this.notificationStore = new NotificationStore(persist);
    this.started = true;

    const firstSeen = readFirstSeen(persist);
    this.persist = persist;
    this.firstSeenAt = firstSeen.firstSeenAt;

    /*
     * Who this browser was signed in as, and that sign-in's signature, read back before
     * anything asks the server — so the in-app and notification reads a reload makes before
     * the page calls `identify()` again are made as that person, and find their messages.
     *
     * Not `readIdentifiedUser`, which is history: it survives `reset()` on purpose, so
     * restoring from it would hand a signed-out browser the previous person's messages.
     */
    this.userId = readSignedInUser(persist) ?? undefined;
    this.userSignature = this.userId ? (readSignedInUserSignature(persist) ?? undefined) : undefined;

    if (typeof window !== 'undefined') {
      this.installLifecycleHooks();
      // The editor's "Test on device" link: `?treebars_preview_code=`, taken out of the URL once read, so a reload or a
      // shared address does not try the spent code again.
      const previewCode = typeof location !== 'undefined' ? new URL(location.href).searchParams.get('treebars_preview_code') : null;
      if (previewCode && typeof history !== 'undefined') {
        const clean = new URL(location.href);
        clean.searchParams.delete('treebars_preview_code');
        history.replaceState(history.state, '', clean.toString());
        void this.previewInApp(previewCode);
      }
      // A page a web push opened says which delivery it came from; reported once, then taken out of the URL.
      this.push.trackOpened();
      // The permission and the subscription as they are on this load, reported only where they changed.
      void this.push.refresh();
      // Before the first page view, so the sequence reads the way it happened: the
      // session opens, the visit is recorded, and then the page they landed on.
      if (config.autoLifecycle !== false) {
        this.track(DEFAULT_EVENTS.APP_OPEN, { is_first_launch: firstSeen.isFirstVisit });
      }
      if (config.autoPageViews !== false) this.installPageViewTracking();
      /*
       * On by default: a click id only reaches this page because the site made one of its links a
       * tracker and pointed a campaign at it, so the choice to measure it was already made. Off by
       * default, a site that did all the setup would silently measure nothing. `carryClickToStore:
       * false` leaves the page's outbound links untouched.
       */
      // Not for a person who opted out: carrying an ad's click into the store link is measurement too.
      if (config.carryClickToStore !== false && !this.optedOut) this.installStoreLinkCarrier();
    }

    // The generated default, which the iOS and Android SDKs share: a browser uploads on the same schedule as a phone.
    this.timer = setInterval(
      () => void this.flush(),
      config.flushIntervalMs ?? DEFAULT_FLUSH_INTERVAL_MS,
    );

    this.reportDeviceContext(persist);

    // Anything left over from a previous page load goes out immediately.
    void this.flush();
    // TREEBARS_LIFECYCLE: the SDK is ready for the page's calls.
    this.announce(WEB_EVENTS.initialised, {}, WEB_EVENTS.lifecycle);
  }

  /**
   * Emits `device_context` when this browser's coarse context has changed.
   *
   * Skipped entirely when storage is disabled: without somewhere to remember the hash
   * every page load would re-report, and a consent-gated visitor should be registering
   * less data, not more. See shouldReportContext in ./storage.
   */
  private reportDeviceContext(persist: boolean, force = false): void {
    try {
      const context = getWebDeviceContext();
      const hash = hashDeviceContext(context);
      // `force` is the claim path: the server answered that this browser's secret is not
      // registered yet, and waiting out the seven-day hash TTL would leave in-app messages
      // and notifications unavailable for a week.
      if (!force && !shouldReportContext(hash, persist)) return;

      this.track('device_context', {
        ...context,
        context_hash: hash,
        // Registers this browser's secret; see getFetchSecret for why it lives beside the id.
        fetch_secret: this.fetchSecret,
      });
    } catch {
      // Analytics must never break the host page; a missing device row is the cost.
    }
  }

  /**
   * Records an event, with optional properties.
   *
   * The event is queued in this browser — in storage, unless `disableStorage` is set — and uploaded in batches: on a
   * timer, as soon as `batchSize` events are waiting, and as the page is hidden or left. It opens a new session first
   * when the last one has expired, and it is the moment a queued in-app message waiting on this event is shown. Does
   * nothing before `init` or after `optOut()`.
   */
  track(eventName: string, properties: EventProperties = {}): void {
    if (!this.started || !this.store || !this.sessions || this.optedOut) return;

    const { sessionId, isNew } = this.advanceSession(true);

    // The dimensions this event was stamped with, which a trigger's dimension row reads.
    const dimensions = this.enqueue(eventName, properties, sessionId);

    /*
     * The sync, at session start and on coming back to the tab — and above the in-app switch,
     * because it carries the trigger list, which this page needs whether or not it draws messages.
     *
     * Keyed on the session opening rather than on an event name: `session_start` is enqueued by
     * `advanceSession` and never passes through here.
     */
    if (isNew || eventName === DEFAULT_EVENTS.APP_FOREGROUND) void this.sync();

    // The one hook in-app needs, at the point every event already passes through.
    this.considerInApp(eventName, properties, dimensions, sessionId);

    if (this.store.size >= (this.config?.batchSize ?? BATCH_SIZE)) {
      void this.flush();
    }
  }

  /**
   * The session the next thing happens in, with its boundaries reported — one place, for an event and for a context
   * token alike. A token asked for after half an hour away belongs to a NEW session, and the purchase it is for will be
   * filed in that one, so the old session has to close and the new one open exactly as an event would have made them.
   */
  private advanceSession(countsAsEvent: boolean): { sessionId: string; isNew: boolean } {
    const { sessionId, isNew, expired } = this.sessions!.touch(countsAsEvent);
    this.currentSessionId = sessionId;

    if (this.config?.autoSessions !== false) {
      /*
       * Both boundaries go out before the event that revealed them, so the stored events read
       * in the order things happened: the old session closes, the new one opens, and only
       * then does the event that triggered all this land inside it.
       */
      if (expired) {
        this.enqueue(
          DEFAULT_EVENTS.SESSION_END,
          { duration_ms: expired.durationMs, event_count: expired.eventCount },
          expired.id,
          // The session's own last moment, not this one. Somebody who closed the tab at
          // nine and came back at noon had a session that ended at nine.
          new Date(expired.endedAt).toISOString(),
        );
      }
      if (isNew) {
        /*
         * `is_first_session`, as the iOS and Android SDKs report it, tells a browser's very
         * first session from a returning browser's first session of the day. `everStarted` is
         * the persisted latch, read before it is set, so the first session of an install
         * reports true exactly once.
         */
        const first = this.sessions?.claimFirstSession() ?? false;
        if (first && this.persist) safeSet(FIRST_SESSION_KEY, sessionId);
        this.enqueue(DEFAULT_EVENTS.SESSION_START, { is_first_session: first }, sessionId);
      }
    }
    return { sessionId, isNew };
  }

  /**
   * A context token for this browser and its current session, to hand to whatever will report a purchase from your
   * backend: your backend puts it in `context.treebars` when it calls `/v1/track`, and Stripe carries it as
   * `metadata.treebars_context`. The event that comes back is filed under this person and this browser — a guest
   * included — and, within half an hour, in this session.
   *
   * **The server issues it; the SDK only asks.** The request carries this browser's secret, and the identity signature
   * when somebody is signed in, so a token is proof that this browser asked — a string built in the page would be a claim
   * any page holding the public write key could make about anybody. So this is a network call, and it resolves to null
   * when the call could not be made, or took longer than five seconds: go ahead without it, and the event is filed by
   * the account id your backend names.
   *
   * **Once per purchase, not per request.** Asking counts as activity, which keeps the session open, and every token is
   * stored.
   *
   * Resolves to null before `init` and after `optOut()`.
   */
  async contextToken(): Promise<string | null> {
    if (!this.started || !this.config || !this.sessions || this.optedOut) return null;
    const { sessionId, isNew } = this.advanceSession(false);
    if (isNew) void this.sync();
    try {
      const response = await fetch(`${this.backendUrl}${ENDPOINTS.contextToken}`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          [HEADERS.writeKey]: this.config.writeKey,
          // This browser, proven with its secret, as a sign-in is.
          [HEADERS.deviceAuth]: this.fetchSecret,
          ...(this.userId && this.userSignature ? { [HEADERS.userSignature]: this.userSignature } : {}),
        },
        body: JSON.stringify({ device_id: this.deviceId, session_id: sessionId, ...(this.userId ? { user_id: this.userId } : {}) }),
        ...(typeof AbortSignal !== 'undefined' && 'timeout' in AbortSignal ? { signal: AbortSignal.timeout(CONTEXT_TOKEN_TIMEOUT_MS) } : {}),
      });
      const body = (await response.json().catch(() => null)) as { token?: unknown; error?: unknown } | null;
      if (response.status === 403 && body?.error === 'signature_required') this.warnSignatureRequired();
      return response.ok && typeof body?.token === 'string' ? body.token.toLowerCase() : null;
    } catch {
      // Unreachable, or too slow for a checkout to wait on: the purchase goes ahead, unlinked.
      return null;
    }
  }

  /**
   * Records a `page_view` for the current address: its path, its URL, the referrer, and `name` — or the document's
   * title — as `title`. `properties` are added last, so they override any of those.
   *
   * The URL is trimmed before it leaves the page: query parameters other than campaign labels (`utm_*`), click ids and
   * `pageUrlParams` are dropped, and so is any fragment but a hash router's route. The referrer is sent as origin and
   * path only. Called by the SDK on load and on each history navigation unless `autoPageViews` is false; call it
   * yourself for anything else that should count as a page.
   */
  page(name?: string, properties: EventProperties = {}): void {
    if (typeof document === 'undefined') return;
    this.track('page_view', {
      path: window.location.pathname,
      // Trimmed before it leaves the page (`page-url.ts`): a query or a fragment carries reset tokens,
      // magic-link codes and emails as often as it carries campaign labels.
      url: analyticsUrl(window.location.href, this.config?.pageUrlParams),
      referrer: analyticsReferrer(document.referrer),
      title: name ?? document.title,
      ...properties,
    });
  }

  /**
   * Signs a known user in on this browser: every event from here on carries `userId`, and their profile is updated with
   * `attributes`. The SDK adds what it knows about the browser — platform, locale, time zone, when it was first seen —
   * beneath `attributes`, and values you pass win. Records `user_identified`. Call `reset()` when the person signs out.
   *
   * `signature` is the hex HMAC-SHA256 of `userId` under the environment's identity secret, computed by your backend —
   * never in the page, because the secret must not reach a browser. An environment that requires signed identities
   * refuses the sign-in without it, and withholds the person's in-app messages and notifications; the SDK warns once in
   * the console when that happens. Calling again for the same person without one keeps the signature already held, so a
   * page that re-identifies to update attributes does not lose its sign-in.
   *
   * Does nothing before `init` or after `optOut()`.
   */
  identify(userId: string, attributes: EventProperties = {}, signature?: string): void {
    if (!this.started || !this.config || this.optedOut) return;
    this.userSignature = signature ?? (userId === this.userId ? this.userSignature : undefined);
    /*
     * Only a different person, with no sign-out between. Not the same one identified again on every page load, and
     * not a first sign-in from anonymous, whose queue is the same person's — either would drop a read that was right.
     */
    if (this.userId !== undefined && userId !== this.userId) this.identityEpoch += 1;
    this.userId = userId;
    // So the next page load knows who this is, and can prove it.
    writeSignedInUser(userId, this.persist, this.userSignature);

    /*
     * What the SDK knows, underneath what the page said.
     *
     * A profile that arrives carrying nothing but an id renders as an empty card, even
     * though locale and timezone are in every event's dimensions. The page's own
     * values always win: passing `locale` is a claim about the person's preference, which
     * outranks the browser's setting.
     */
    const merged = { ...defaultUserAttributes(this.firstSeenAt), ...attributes };

    void this.post(
      ENDPOINTS.identify,
      { user_id: userId, device_id: this.deviceId, attributes: merged },
      {
        // The device this sign-in names, proven with its secret.
        [HEADERS.deviceAuth]: this.fetchSecret,
        ...(this.userSignature ? { [HEADERS.userSignature]: this.userSignature } : {}),
      },
    )
      .then(async (response) => {
        // A live environment's refusal of an unsigned sign-in, said once rather than swallowed below.
        if (response.status !== 403) return;
        const body = (await response.json().catch(() => null)) as { error?: string } | null;
        if (body?.error === 'signature_required') this.warnSignatureRequired();
      })
      .catch(() => {
        // Identity sync is best effort; events still carry the user id.
      });

    this.reportUserIdentified(userId, merged);
  }

  /**
   * Records the moment somebody stopped being anonymous.
   *
   * `/v1/identify` writes the profile and links the identities, but it is not an event —
   * so without this the single most interesting transition in a funnel would be
   * invisible to analytics, to retention cohorts, to journey triggers and to campaign
   * goals. The endpoint call stays: this is an addition to it, not a replacement.
   *
   * Attribute *keys*, never values. Event properties are stored as append-only history,
   * with different retention and deletion from the profile; a name or an email belongs
   * in the profile the identify call just wrote, not duplicated into an event nobody can
   * revise.
   */
  private reportUserIdentified(userId: string, attributes: EventProperties): void {
    const previousUserId = readIdentifiedUser(this.persist);
    writeIdentifiedUser(userId, this.persist);

    this.track(DEFAULT_EVENTS.USER_IDENTIFIED, {
      user_id: userId,
      // "First in this browser", which is the only version of the question the SDK can
      // answer. Whether the account itself is new is the server's to know.
      is_first_identify: !previousUserId,
      ...(previousUserId && previousUserId !== userId ? { previous_user_id: previousUserId } : {}),
      attribute_keys: Object.keys(attributes).sort(),
    });
  }

  /**
   * Signs the current user out of this browser, keeping the events already captured.
   *
   * Records `user_signed_out` and starts uploading it, then clears the signed-in id and its signature, starts a new
   * session, and clears what belonged to that person here: queued in-app messages and the notification centre's
   * history. The device id stays. Does nothing when nobody is signed in, so calling it
   * defensively on load is safe.
   *
   * Synchronous: the sign-out is queued under this user and session before either is cleared, and the upload is not
   * waited for, since a tab is often navigated away from right after a sign-out.
   */
  reset(): void {
    /*
     * `readIdentifiedUser`'s key is history and deliberately stays — it is what
     * `previous_user_id` is computed from. This one is current state, and a sign-out that
     * failed to clear it would let the next page load present the previous person's
     * `user_id` on the read routes and fetch their queued messages. Cleared whoever is held,
     * so a reset() that runs before anything was restored still clears it.
     */
    clearSignedInUser(this.persist);
    /*
     * No user id means there was no sign-in to end, and then nothing below applies. An app that calls reset()
     * defensively on load must not record a sign-out for every anonymous visitor, split their session, or wipe their
     * in-app queue and the ledger of what they have already seen and answered. The anonymous visitor before the call
     * is the same one after it.
     */
    if (!this.userId) return;
    this.track(DEFAULT_EVENTS.USER_SIGNED_OUT, { user_id: this.userId });
    void this.flush();

    this.userId = undefined;
    this.userSignature = undefined;
    // Whatever a read in flight brings back was the previous person's.
    this.identityEpoch += 1;
    this.sessions?.reset();
    /*
     * The queued messages go — they were addressed to whoever was signed in. The device id
     * and its secret stay: they belong to the browser rather than the person, and the two
     * are only ever replaced together (`wipeLocalData`).
     */
    this.inApp?.reset();
    // A message waiting for its moment was the previous person's.
    this.pendingDisplay?.cancel();
    this.pendingDisplay = null;
    this.freeScreen();
    this.closeNudges();
    /*
     * And the notification centre, for the same reason: a history belongs to the person,
     * not the browser. The device secret and the device id still survive — see above.
     */
    this.notificationStore?.reset();
    this.lastNotificationServerTime = null;
    // What this browser was shown was the previous person's to convert, and a goal the next person reaches must not
    // credit it.
    this.emitNotificationChange({
      notifications: [],
      unreadCount: 0,
      nextCursor: null,
      fromCache: true,
    });
  }

  /**
   * Uploads the events waiting in this browser now, rather than on the next timer.
   *
   * A batch keeps its id until the server acknowledges it, so a retry is recognised rather than counted twice; one flush
   * sends up to ten batches; failures back off with jitter or wait out the server's `Retry-After`; and a refused write
   * key waits before it is tried again. Never throws. Does nothing before `init` or after `optOut()`.
   */
  async flush(): Promise<void> {
    if (!this.started || !this.uploader || this.optedOut) return;
    await this.uploader.flush();
  }

  /**
   * Stops this SDK recording or sending anything from this browser — events, sign-ins, reads, the
   * visit from an ad — from now until `optIn()`, and on every later visit: the answer is kept, where
   * storage is allowed, and read back by `init`. What was waiting to be sent is dropped with it. Call
   * it before `init` when a consent prompt answers first; an opted-out page load writes nothing into
   * the browser at all.
   *
   * Nothing already sent is touched: erasing a person's data on the server is the API's
   * `/privacy/delete`, which the site's backend calls. And a person who opted out is not signed out —
   * `reset()` is that.
   */
  optOut(): void {
    this.optedOut = true;
    if (!this.started) {
      this.answerBeforeInit = true;
      return;
    }
    writeOptedOut(true, this.storageAllowed);
    this.uploader?.discard();
  }

  /**
   * Undoes `optOut()`: recording resumes with the next event. Nothing dropped comes back, and on a page
   * loaded opted out the stores stay in memory until the next load.
   */
  optIn(): void {
    this.optedOut = false;
    if (!this.started) {
      this.answerBeforeInit = false;
      return;
    }
    writeOptedOut(false, this.storageAllowed);
  }

  /** Whether `optOut()` is in effect for this browser. */
  isOptedOut(): boolean {
    return this.optedOut;
  }

  /**
   * Forgets this browser, here: the device id and its secret, who is signed in and who had been, the
   * queue and everything waiting to be sent, the session, the in-app and notification stores, the
   * trigger list, the carried click and the `tbrs_bs` cookie. Nothing is sent on the way — not even
   * the sign-out `reset()` records — and from the next event on this is a browser the server has never
   * seen, with a new id and a new secret. The opt-out stays: it is the person's answer, not data about
   * them, so a person who wants to be forgotten and not recorded again calls `optOut()` as well.
   *
   * Nothing on the server is touched: what was already sent is erased by the API's `/privacy/delete`,
   * which the site's backend calls.
   */
  wipeLocalData(): void {
    this.uploader?.discard();
    this.userId = undefined;
    this.userSignature = undefined;
    this.sessions?.reset();
    this.inApp?.reset();
    this.notificationStore?.reset();
    this.lastNotificationServerTime = null;
    // After the stores above have written their empty selves, so nothing they wrote survives it.
    wipeStoredData();
    forgetSharedBrowserId();
    this.emitNotificationChange({ notifications: [], unreadCount: 0, nextCursor: null, fromCache: true });
    if (!this.started) return;
    /*
     * A new browser from here: a new id and secret, together, kept where storage is allowed — and
     * not at all for a person who opted out. Reported with the next page's context, or at once if a
     * read finds it unclaimed (`claim_required`); nothing is sent from here.
     */
    const keep = this.persist && !this.optedOut;
    this.deviceId = getDeviceId(keep);
    this.fetchSecret = getFetchSecret(keep);
  }

  /**
   * The one wake the uploader asks for, at the moment it asks for.
   *
   * Without it a two-second backoff would wait for the thirty-second timer and the jitter would be
   * decoration — and a listed event would wait for it too, which is the whole thing a trigger
   * list exists to stop. Always rearmed: the uploader already asks only when the earliest moment
   * it needs has moved, so a repeat here is a real change.
   */
  private wake(at: number): void {
    if (this.wakeTimer !== null) clearTimeout(this.wakeTimer);
    this.wakeTimer = setTimeout(() => {
      this.wakeTimer = null;
      if (this.started) void this.uploader?.woken();
    }, Math.max(0, at - Date.now()));
  }

  /**
   * The session's sync: the whole in-app sync when in-app is on, and the trigger list alone when
   * it is off. Never the whole sync with in-app off: it stamps every pending message fetched, a
   * stage of the campaign's funnel, for a page that will never draw one.
   */
  private sync(): Promise<void> {
    if (this.inAppEnabled) return this.syncInAppMessages();
    return this.triggers?.refresh() ?? Promise.resolve();
  }

  /**
   * The trigger list alone (`triggers_only=1`), which reads nothing about the device and marks no
   * message fetched.
   *
   * The write key and the device id and nothing else. The list belongs to the environment, so the
   * device secret would authenticate nothing here, and a secret sent where it is not needed is one
   * more place it can leak from.
   */
  private async fetchTriggerEvents(): Promise<TriggerList | null> {
    if (!this.config || this.optedOut) return null;
    const params = new URLSearchParams({ device_id: this.deviceId, triggers_only: '1' });
    try {
      const response = await fetch(`${this.backendUrl}${ENDPOINTS.inApp}?${params.toString()}`, {
        headers: { [HEADERS.writeKey]: this.config.writeKey },
      });
      if (!response.ok) {
        this.log(`trigger list refused (${response.status})`);
        return null;
      }
      return readTriggerList(((await response.json()) as { trigger_events?: unknown }).trigger_events);
    } catch (error) {
      this.log(`trigger list fetch failed: ${String(error)}`);
      return null;
    }
  }

  /**
   * Show a queued in-app message, if this event is what it was waiting for.
   *
   * The server decides eligibility before a message is queued, and again at every sync. What is decided here is *when*,
   * and on which page: the caps, the page's contexts, the page and session rules, and then the on-site moment. Highest
   * priority first; one message at a time.
   */
  private considerInApp(eventName: string, properties: EventProperties, dimensions: Record<string, unknown>, sessionId: string): void {
    if (!this.inAppEnabled || !this.inApp) return;
    /*
     * Never off the SDK's own reports. `in_app_displayed` goes out through the same track()
     * every other event does, and a message triggered on `immediate` matches anything —
     * so without this, showing one message would show it again, forever.
     */
    if (isInAppReport(eventName)) return;
    /*
     * Nor on the way out, by name or by state: a customer's own event sent from `pagehide`, or anything tracked while
     * the tab is in the background, would spend a message nobody can see. The queue waits, unspent, for the next event
     * on a visible page.
     */
    if (LEAVING_EVENTS.has(eventName) || pageHidden()) return;
    // Nudges first, in their own slot: a modal on screen holds back the next modal, not a nudge.
    this.considerNudges(eventName, properties, dimensions, sessionId);
    // Something is on screen and unanswered: the queue waits, unspent, for the next event after it.
    if (this.screenHeld()) return;

    for (const message of byPriority(this.inApp.list())) {
      const content = message.content.in_app;
      // An inbox message is a row in a list the page draws; nothing is shown over
      // anything, so there is no trigger to fire.
      if (!content || content.surface !== 'overlay') continue;
      if (isNudge(message)) continue;
      const screen = typeof document !== 'undefined' ? document.title : null;
      if (!triggerMatches(content.trigger, eventName, properties, { screen, dimensions })) continue;
      // Already waiting for its moment: the trigger firing again is not a second message.
      if (this.pendingDisplay?.deliveryId === message.delivery_id) return;
      const blocked = this.displayBlockedBy(message, sessionId);
      if (blocked) {
        if (blocked !== 'done') this.reportFailure(message, blocked);
        continue;
      }
      // A self-handled message is the page's: handed over, not drawn, while the page listens. Nothing is spent until it
      // reports `onsite.selfHandledShown`.
      if (content.display?.self_handled && this.selfHandledCallback) {
        this.handSelfHandled(message);
        return;
      }
      // Nothing to draw with. The queue above is still worth having: the inbox reads it.
      if (!this.renderer) {
        this.reportFailure(message, 'no_renderer');
        return;
      }
      if (this.pendingDisplay) return;
      this.scheduleDisplay(message, sessionId);
      // One at a time: two overlays at once is two messages nobody reads.
      return;
    }
  }

  /**
   * The nudges this event brings: each matching one drawn at once, up to three on screen, outside the channel's caps
   * (`isNudge`) but inside every rule of its own — expiry, contexts, page and session rules, a primer's push rule. On the
   * web a nudge may appear on any page its rules allow; there is no `showNudge` call. Drawn by this SDK's own renderer
   * only, which is the one that knows how they stack; a page's own renderer is handed modals alone. The on-site moment (a delay, a scroll depth) is not waited for: a nudge that has to wait is a modal.
   */
  private considerNudges(eventName: string, properties: EventProperties, dimensions: Record<string, unknown>, sessionId: string): void {
    for (const message of byPriority(this.inApp!.list())) {
      if (this.nudges.size >= IN_APP_CONTAINER.nudge.maxOnScreen) return;
      const content = message.content.in_app;
      if (!content || content.surface !== 'overlay' || !isNudge(message)) continue;
      if (this.nudges.has(message.delivery_id)) continue;
      const screen = typeof document !== 'undefined' ? document.title : null;
      if (!triggerMatches(content.trigger, eventName, properties, { screen, dimensions })) continue;
      const blocked = this.displayBlockedBy(message, sessionId);
      if (blocked) {
        if (blocked !== 'done') this.reportFailure(message, blocked);
        continue;
      }
      if (this.renderer !== 'builtin') {
        this.reportFailure(message, 'no_renderer');
        continue;
      }
      this.showInApp(message, sessionId);
    }
  }

  /** The device's caps, then the display rules, as one answer: why not, or null. */
  private displayBlockedBy(message: InAppMessage, sessionId: string | null): InAppFailureReason | 'done' | null {
    const blocked = this.inApp!.blockedBy(message, sessionId, Date.now(), isNudge(message) ? this.nudgesInFlight.size : 0);
    if (blocked) return blocked;
    const display = message.content.in_app?.display;
    if (!display) return null;
    if (!contextsMatch(display.contexts, this.appContexts)) return 'context';
    const href = typeof location !== 'undefined' ? location.href : '';
    if (!pageRulesMatch(display, href)) return 'page_rule';
    const firstSession = this.persist ? safeGet(FIRST_SESSION_KEY) : null;
    const facts = {
      href,
      isNewVisitor: firstSession !== null && firstSession === sessionId,
      now: new Date(),
      country: this.inApp!.country,
      device: deviceClass(),
    };
    if (!sessionRulesMatch(display.session_rules, facts)) return 'session_rule';
    // A push primer is for people who can still be asked, read at each look.
    return pushAskableBlock(display, this.push.status());
  }

  /**
   * The on-site moment: at once, after a delay, at a scroll depth, or as the pointer leaves for the tab bar. The
   * rules are asked again when the moment comes — a page a single-page app has since moved to may no longer match.
   */
  private scheduleDisplay(message: InAppMessage, sessionId: string): void {
    const display = message.content.in_app?.display;
    const on = typeof window === 'undefined' ? 'load' : (display?.on ?? 'load');
    const fire = () => {
      // Its moment came while another message held the screen, or while the tab was hidden: look again in a second,
      // still the one waiting.
      if (this.screenHeld() || pageHidden()) {
        const timer = setTimeout(fire, 1000);
        this.pendingDisplay = { deliveryId: message.delivery_id, cancel: () => clearTimeout(timer) };
        return;
      }
      this.pendingDisplay = null;
      const blocked = this.displayBlockedBy(message, this.currentSessionId ?? sessionId);
      if (blocked) {
        if (blocked !== 'done') this.reportFailure(message, blocked);
        return;
      }
      this.showInApp(message, this.currentSessionId ?? sessionId);
    };
    if (on === 'load') {
      fire();
      return;
    }
    if (on === 'delay') {
      const timer = setTimeout(fire, (display?.delay_seconds ?? 5) * 1000);
      this.pendingDisplay = { deliveryId: message.delivery_id, cancel: () => clearTimeout(timer) };
      return;
    }
    if (on === 'scroll') {
      const depth = display?.scroll_percent ?? 50;
      const listener = () => {
        const doc = document.documentElement;
        const scrollable = doc.scrollHeight - window.innerHeight;
        const reached = scrollable <= 0 ? 100 : ((window.scrollY || doc.scrollTop) / scrollable) * 100;
        if (reached < depth) return;
        window.removeEventListener('scroll', listener);
        fire();
      };
      window.addEventListener('scroll', listener, { passive: true });
      this.pendingDisplay = { deliveryId: message.delivery_id, cancel: () => window.removeEventListener('scroll', listener) };
      listener();
      return;
    }
    // exit_intent: the pointer leaving through the top of the window, toward the tabs or the address bar. A touch
    // screen has no pointer to leave with, so there it never fires — which is the honest answer, not a guess.
    const listener = (event: MouseEvent) => {
      if (event.relatedTarget !== null || event.clientY > 0) return;
      document.removeEventListener('mouseout', listener);
      fire();
    };
    document.addEventListener('mouseout', listener);
    this.pendingDisplay = { deliveryId: message.delivery_id, cancel: () => document.removeEventListener('mouseout', listener) };
  }

  /**
   * `in_app_failed`: a message matched and was held back, with why — once per message, reason and day, so the
   * report counts messages rather than every event that asked. Kept only when storage is, like the ledger.
   */
  private reportFailure(message: InAppMessage, reason: InAppFailureReason): void {
    if (!message.campaign_id) return;
    const today = new Date().toDateString();
    let seen: Record<string, string> = {};
    try {
      seen = JSON.parse(safeGet(FAILED_KEY) ?? '{}') as Record<string, string>;
    } catch {
      seen = {};
    }
    const key = `${message.delivery_id}:${reason}`;
    if (seen[key] === today) return;
    const kept = Object.fromEntries(Object.entries(seen).filter(([, day]) => day === today));
    kept[key] = today;
    if (this.persist) safeSet(FAILED_KEY, JSON.stringify(kept));
    this.track('in_app_failed', {
      treebars_delivery_id: message.delivery_id,
      treebars_campaign_id: message.campaign_id,
      reason,
    });
  }

  /**
   * Shows a draft in-app message from the editor's "Test on device" on this page.
   *
   * The one-time `code` the editor shows is exchanged for a preview session tied to this browser's device id; the draft
   * is drawn at once and redrawn whenever it is saved in the editor. A preview is drawn and nothing else: no display is
   * counted, no cap is spent, no event is recorded, and whatever the message asks to write is refused. Also started by
   * `?treebars_preview_code=<code>` on the page's address, which the editor's link carries.
   *
   * Resolves to whether the preview started: false before `init`, when the code has expired or was already used, or
   * when the server could not be reached.
   */
  async previewInApp(code: string): Promise<boolean> {
    if (!this.config || !this.deviceId || !code.trim()) return false;
    try {
      const response = await fetch(`${this.backendUrl}${ENDPOINTS.previewPair}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', [HEADERS.writeKey]: this.config.writeKey },
        body: JSON.stringify({ code: code.trim(), device_id: this.deviceId }),
      });
      if (!response.ok) {
        console.warn('[treebars preview] that code has expired or was used; show a new one in the editor.');
        return false;
      }
      const answer = (await response.json()) as { session: string; revision: string; message: InAppMessage };
      this.stopPreview();
      this.inAppPreview = { session: answer.session, revision: answer.revision, timer: null };
      this.drawPreview(answer.message);
      this.inAppPreview.timer = setInterval(() => void this.refreshPreview(), PREVIEW_POLL_MS);
      return true;
    } catch {
      return false;
    }
  }

  /** The draft again, and a redraw only when it changed; a session that ended stops the loop. */
  private async refreshPreview(): Promise<void> {
    const session = this.inAppPreview;
    if (!session || !this.config) return;
    try {
      // The revision drawn, so an unchanged draft answers without its body: a poll every two seconds for an hour.
      const params = new URLSearchParams({ device_id: this.deviceId, revision: session.revision });
      const response = await fetch(`${this.backendUrl}${ENDPOINTS.preview}?${params.toString()}`, {
        headers: { [HEADERS.writeKey]: this.config.writeKey, [HEADERS.preview]: session.session },
      });
      if (response.status === 404) {
        console.info('[treebars preview] the preview has ended.');
        this.stopPreview();
        return;
      }
      if (!response.ok) return;
      const answer = (await response.json()) as { revision: string; message?: InAppMessage };
      if (answer.revision === session.revision || !answer.message) return;
      session.revision = answer.revision;
      console.info('[treebars preview] saved in the editor; redrawn.');
      this.drawPreview(answer.message);
    } catch {
      /* offline: the next tick asks again */
    }
  }

  private drawPreview(message: InAppMessage): void {
    this.previewClose?.();
    this.previewClose = null;
    this.freeScreen();
    this.showInApp({ ...message, preview: true });
  }

  private stopPreview(): void {
    if (this.inAppPreview?.timer) clearInterval(this.inAppPreview.timer);
    this.inAppPreview = null;
  }

  private showInApp(message: InAppMessage, sessionId: string | null = null): void {
    const content = message.content.in_app;
    // A large body that never arrived: a message with nothing to draw is not drawn empty.
    if (content?.html_ref && !content.html) {
      this.reportFailure(message, 'asset_download');
      return;
    }
    /*
     * Nor one naming a stored file that is missing (the sync's `assets.missing`): known at the sync, and a failed display
     * with its reason rather than a broken image — as on Android and iOS, which also fail one whose files could not be
     * fetched. Here the browser fetches the rest itself, from its own cache when it has them.
     */
    const markupBody = content?.body_mode === 'html' || content?.layout === 'html';
    if (markupBody && (message.assets?.missing?.length ?? 0) > 0) {
      this.reportFailure(message, 'asset_download');
      return;
    }
    // The drawn message's quiet close, for a press that leads somewhere (`spent`): set once it is drawn.
    let closeDrawn: (() => void) | null = null;
    // Which slot it takes and gives back: the screen a modal holds, or a place among the nudges.
    const nudge = isNudge(message);
    const free = () => this.freeFor(message);
    const display = new BridgeDisplay(message, this.bridgeSdk(message, () => closeDrawn?.()));
    let shown = false;
    // How long a markup body took to run and show, from here; and whether it is this page's first frame.
    const markup = markupBody;
    const started = Date.now();
    const cold = markup && !this.markupDrawn;
    if (markup) this.markupDrawn = true;
    /*
     * Counted when it is on screen, not when it is drawn. An HTML body is drawn hidden and shown when its bridge says it
     * is running; one a site's policy stopped is never shown, and must not count as a display or spend a cap.
     */
    const previewing = message.preview === true;
    const onShown = (drawn?: { pushedDown?: number }) => {
      if (shown) return;
      shown = true;
      // A preview is shown and nothing more: no display counted, no cap spent, no event.
      if (previewing) {
        console.info('[treebars preview] shown; nothing it does is recorded.');
        return;
      }
      this.nudgesInFlight.delete(message.delivery_id);
      this.inApp!.recordDisplay(message, sessionId);
      /*
       * "Any event is an opportunity; the first one after a sync wins" (see `triggerMatches`)
       * is only true if showing it also spends it. `recordDisplay` alone only marks a message
       * done once `max_displays` is reached, which an immediate-trigger message rarely sets —
       * a test send never does — so without this, every later event in the same session
       * would match `immediate` again and redraw the same message, once per event.
       */
      if (content?.trigger.kind === 'immediate') {
        this.inApp!.markDone(message.delivery_id);
      }
      this.track('in_app_displayed', markup ? { ...inAppReceipt(message), render_ms: Date.now() - started, cold } : inAppReceipt(message));
      /*
       * A banner that pushed the page down says by how much: a sticky header does not move with the page, and this is
       * the event a site listens for to move it.
       */
      this.announce(WEB_EVENTS.shown, drawn?.pushedDown ? { ...inAppReceipt(message), pushed_down: drawn.pushedDown } : inAppReceipt(message));
    };
    const view: InAppView = {
      message,
      // The page's own appearance: what `prefers-color-scheme` says as the message is drawn.
      tokens: this.inApp!.styleTokensFor(message, typeof window !== 'undefined' && typeof window.matchMedia === 'function' && window.matchMedia('(prefers-color-scheme: dark)').matches),
      onClick: (button) =>
        previewing ? console.info(`[treebars preview] “${button.label}” pressed; not recorded.`) : this.inAppButton(message, button),
      // Through the display, which records a dismissal once however many ways it is asked for.
      onDismiss: (reason) => display.dismiss(reason),
      onSubmit: (responses) => (previewing ? console.info('[treebars preview] form sent; not recorded.', responses) : this.inAppSubmitted(message, responses)),
      onShown,
      onFailed: (reason) => {
        free();
        // A site whose policy refuses both frames refuses them on every try: spent here, not retried on every event.
        if (reason === 'csp_blocked') this.inApp?.markDone(message.delivery_id);
        this.reportFailure(message, reason);
      },
      bridge: (method, args, close) => display.call(method, args, close),
      frame: {
        url: this.frameUrl,
        mode: this.frameMode(),
        remember: (mode) => this.rememberFrameMode(mode),
      },
    };
    const draw = this.renderer;
    // Claimed before drawing: a renderer's own `track` could otherwise consider the next message mid-draw.
    if (nudge) {
      this.nudges.set(message.delivery_id, () => closeDrawn?.());
      if (!previewing) this.nudgesInFlight.add(message.delivery_id);
    } else {
      this.presentingSince = Date.now();
      this.presentingPinned = draw === 'builtin' && (content?.body_mode === 'html' || content?.layout === 'html');
    }
    try {
      if (draw === 'builtin') closeDrawn = renderBuiltIn(view);
      else {
        draw!(view);
        onShown(undefined);
      }
      if (previewing) {
        this.previewClose = () => {
          closeDrawn?.();
          free();
        };
      }
    } catch (error) {
      free();
      this.log(`in-app render failed: ${String(error)}`);
      this.reportFailure(message, 'render_error');
    }
  }

  /** What one HTML display may ask of this SDK (`bridge-calls.ts`). */
  private bridgeSdk(message: InAppMessage, closeDrawn: () => void): ConstructorParameters<typeof BridgeDisplay>[1] {
    const live = this.liveBridgeSdk(message, closeDrawn);
    if (message.preview !== true) return live;
    // A preview's display writes nothing, whatever reaches it: the second line under the refusals in
    // `BridgeDisplay.call`, for the recording a safe method does of its own — a dismissal, a link's click.
    return {
      ...live,
      track: (name) => console.info(`[treebars preview] ${name} was not recorded.`),
      setTraits: () => ({ ok: false, reason: 'preview' }),
      requestPushPermission: async () => 'unsupported',
      announceClicked: () => undefined,
      // Taken down, and nothing marked: a preview is not in the queue, so there is nothing to spend.
      spent: () => {
        this.freeFor(message);
        closeDrawn();
      },
      dismissed: () => this.freeFor(message),
      flush: () => undefined,
    };
  }

  private liveBridgeSdk(message: InAppMessage, closeDrawn: () => void): ConstructorParameters<typeof BridgeDisplay>[1] {
    return {
      track: (name, properties) => this.track(name, properties as EventProperties),
      setTraits: (traits) => {
        this.setMessageTraits(traits as EventProperties);
        return { ok: true };
      },
      requestPushPermission: async () => {
        const answer = await this.push.requestPermission();
        return answer === 'subscribed' ? 'granted' : answer;
      },
      announceClicked: (data) => this.announce(WEB_EVENTS.clicked, data),
      open: (url, via) => {
        if (via === 'openRichLanding' || via === '_link_new') window.open(url, '_blank', 'noopener');
        else location.assign(url);
      },
      /*
       * A press that leads somewhere takes the message with it, as on Android and iOS. Most destinations unload the page
       * anyway; one in the same document — a hash, a single-page route — does not, and a spent message must not stay
       * drawn on a screen that is free for the next one.
       */
      spent: () => {
        this.freeFor(message);
        this.inApp?.markDone(message.delivery_id);
        closeDrawn();
      },
      dismissed: (reason) => {
        this.freeFor(message);
        this.inApp?.markDone(message.delivery_id);
        this.announce(reason === 'auto' ? WEB_EVENTS.autoDismissed : WEB_EVENTS.dismissed, inAppReceipt(message));
      },
      flush: () => void this.flush(),
      log: (line) => this.log(line),
      claimReward: (pool, deliveryId) => this.claimReward(pool, deliveryId),
    };
  }

  /**
   * The server's answer to a page's `claimReward`, asked with this device's own secret — and asked again after a 429, a
   * 503 or no answer, within a few seconds, which the server's one answer per person makes safe (`reward-claim.ts`).
   */
  private async claimReward(pool: string, deliveryId: string): Promise<Record<string, unknown>> {
    const config = this.config;
    if (!config || this.optedOut) return { ok: false, reason: 'not_available' };
    const ask = async (): Promise<RewardAttempt> => {
      let response: Response;
      try {
        response = await fetch(`${this.backendUrl}${ENDPOINTS.inAppReward}`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', ...this.contentHeaders(config.writeKey) },
          body: JSON.stringify({ device_id: this.deviceId, delivery_id: deliveryId, pool }),
        });
      } catch {
        return { status: null, retryAfter: null, answer: null };
      }
      // Readable across origins because the server names it in `Access-Control-Expose-Headers`.
      const retryAfter = response.headers.get('Retry-After');
      if (!response.ok) return { status: response.status, retryAfter, answer: null };
      // A 200 whose body is not an answer is `failed`, not `offline`: it was answered, and asking again would not help.
      const answer = (await response.json().catch(() => null)) as Record<string, unknown> | null;
      return { status: response.status, retryAfter, answer: answer && typeof answer === 'object' ? answer : null };
    };
    const last = await claimWithRetries(ask, {
      elapsed: () => (typeof performance !== 'undefined' ? performance.now() : Date.now()),
      now: () => Date.now(),
      sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
      random: Math.random,
    });
    return last.answer ?? rewardRefusal(last);
  }

  /** Which frame to draw an HTML body in first: the Treebars one once this session has found `srcdoc` stopped. */
  private frameMode(): FrameMode {
    if (this.frameModeSeen) return this.frameModeSeen;
    try {
      return sessionStorage.getItem(FRAME_MODE_KEY) === 'hosted' ? 'hosted' : 'srcdoc';
    } catch {
      return 'srcdoc';
    }
  }

  private rememberFrameMode(mode: FrameMode): void {
    this.frameModeSeen = mode;
    // Past this page only where the site allows storage at all (`disableStorage`).
    if (!this.storageAllowed) return;
    try {
      if (mode === 'hosted') sessionStorage.setItem(FRAME_MODE_KEY, mode);
      else sessionStorage.removeItem(FRAME_MODE_KEY);
    } catch {
      /* remembered for this page only */
    }
  }

  /**
   * Window events for the page: `window.addEventListener('TREEBARS_AUTOMATED_EVENTS', e => …)`, where `e.detail` is
   * `{ name, data }` — a message shown, pressed, dismissed or closed by itself. Named as common engagement SDKs name
   * theirs, with a Treebars prefix, so a migration keeps its listeners. Nothing is sent where there is no window.
   */
  private announce(name: string, data: Record<string, unknown>, channel: string = WEB_EVENTS.automated): void {
    if (typeof window === 'undefined' || typeof CustomEvent === 'undefined') return;
    try {
      window.dispatchEvent(new CustomEvent(channel, { detail: { name, data } }));
    } catch (error) {
      this.log(`event listener threw: ${String(error)}`);
    }
  }

  /** A self-handled message to the page's callback, once per trigger; nothing is spent until the page says it showed it. */
  private handSelfHandled(message: InAppMessage): void {
    try {
      this.selfHandledCallback?.(message);
    } catch (error) {
      console.warn('[treebars] getSelfHandledOSM callback threw', error);
    }
  }

  /** The self-handled messages this browser may show now: allowed by the caps, the pages and the contexts. */
  private eligibleSelfHandled(): InAppMessage[] {
    if (!this.inApp || !this.inAppEnabled) return [];
    return this.inApp.list().filter((message) => {
      const content = message.content.in_app;
      if (!content?.display?.self_handled || content.surface === 'inbox') return false;
      if (content.trigger.kind !== 'immediate' && content.trigger.kind !== 'session_start') return false;
      return this.displayBlockedBy(message, this.currentSessionId) === null;
    });
  }

  /** Self-handled messages, which the page draws itself and reports on. See `TreebarsOnsite`. */
  readonly onsite: TreebarsOnsite = {
    getSelfHandledOSM: (callback) => {
      this.selfHandledCallback = callback;
      const now = callback ? this.eligibleSelfHandled()[0] : undefined;
      if (now) this.handSelfHandled(now);
    },
    selfHandledShown: (message) => {
      if (!this.inApp) return;
      this.inApp.recordDisplay(message, this.currentSessionId);
      if (message.content.in_app?.trigger.kind === 'immediate') this.inApp.markDone(message.delivery_id);
      this.track('in_app_displayed', inAppReceipt(message));
      this.announce(WEB_EVENTS.shown, inAppReceipt(message));
    },
    selfHandledClicked: (message, button) => {
      this.track('in_app_clicked', button ? inAppClickProperties(message, button) : inAppReceipt(message));
      if (button && inAppClickEndsMessage(button)) this.inApp?.markDone(message.delivery_id);
      this.announce(WEB_EVENTS.clicked, { ...inAppReceipt(message), ...(button ? { action: button.action, values: button.data ?? (button.value ? { value: button.value } : {}) } : {}) });
      void this.flush();
    },
    selfHandledDismissed: (message) => {
      this.inApp?.markDone(message.delivery_id);
      this.track('in_app_dismissed', inAppReceipt(message));
      this.announce(WEB_EVENTS.dismissed, inAppReceipt(message));
    },
  };

  /** Whether an overlay is on screen and unanswered, within the hold — or for as long as it lasts, when pinned. */
  private screenHeld(): boolean {
    if (this.presentingSince === null) return false;
    if (this.presentingPinned || Date.now() - this.presentingSince < IN_APP_PRESENTATION_HOLD_MS) return true;
    this.presentingSince = null;
    return false;
  }

  /** The screen is free: an answer, a failure, a sign-out. */
  private freeScreen(): void {
    this.presentingSince = null;
    this.presentingPinned = false;
  }

  /** The slot this message took is free again: the screen for a modal, its place among the nudges for a nudge. */
  private freeFor(message: InAppMessage): void {
    if (isNudge(message)) {
      this.nudges.delete(message.delivery_id);
      this.nudgesInFlight.delete(message.delivery_id);
    } else this.freeScreen();
  }

  /** Every nudge taken down: they were the previous person's, or the SDK is stopping. */
  private closeNudges(): void {
    const drawn = [...this.nudges.values()];
    this.nudges.clear();
    this.nudgesInFlight.clear();
    for (const close of drawn) close();
  }

  /** A button pressed: always `in_app_clicked`, then what the button does beyond that. */
  private inAppButton(message: InAppMessage, button: InAppButton): void {
    // Reported before the page is handed the destination, so a click that navigates
    // away is still recorded.
    this.track('in_app_clicked', inAppClickProperties(message, button));
    // A call to action spends the message as a dismissal does, and frees the screen.
    if (inAppClickEndsMessage(button)) {
      this.freeFor(message);
      this.inApp!.markDone(message.delivery_id);
    }
    /*
     * The two-step push opt-in: this link asks for permission rather than going anywhere, so it is never handed to
     * `location.assign`. Asked here, inside the click, because a browser shows its permission prompt only to a gesture.
     */
    if (button.value === PUSH_PERMISSION_LINK) {
      void this.push.requestPermission();
      void this.flush();
      return;
    }
    const campaign = message.campaign_id ? { treebars_campaign_id: message.campaign_id } : {};
    if (button.action === 'track_event' && button.event_name) this.track(button.event_name, campaign);
    if (button.action === 'set_attribute' && button.key) this.setMessageTraits({ [button.key]: button.value ?? '' });
    /*
     * Copy and share, the device actions a push button also has, inside the click, where a browser allows the clipboard
     * and the share sheet. Neither leaves the page, so the SDK does both whoever drew the button; a page with no share sheet (most
     * desktops) is handed the text on its clipboard instead, which is what sharing it would have been for.
     */
    if ((button.action === 'copy' || button.action === 'share') && button.value && typeof navigator !== 'undefined') {
      const text = button.value;
      const copy = () => navigator.clipboard?.writeText(text).catch(() => undefined);
      if (button.action === 'share' && typeof navigator.share === 'function') void navigator.share({ text }).catch(() => undefined);
      else void copy();
    }
    // Every press, to the page's TREEBARS_AUTOMATED_EVENTS listener; a `custom` button's keys arrive only there.
    this.announce(WEB_EVENTS.clicked, {
      ...inAppClickProperties(message, button),
      action: button.action,
      values: clickValues(button),
    });
    if ((button.action === 'url' || button.action === 'deep_link') && button.value && this.renderer === 'builtin' && typeof location !== 'undefined') {
      // The built-in renderer is the one that has to go there itself; a page's own renderer decides for itself.
      void this.flush();
      location.assign(button.value);
      return;
    }
    // A call leaves the page as a link does: the built-in renderer dials, a page's own renderer decides.
    if (button.action === 'call' && button.value && this.renderer === 'builtin' && typeof location !== 'undefined') {
      void this.flush();
      location.assign(`tel:${button.value.replace(/[^\d+]/g, '')}`);
      return;
    }
    void this.flush();
  }

  /**
   * Traits a message set — a form's answer kept as a trait, a button's "set a trait", an HTML message's
   * `setUserAttribute` family and `data-tb-save` — on the person, signed in or not.
   *
   * Signed in, through `identify()` as always. With nobody signed in there is still a person — the anonymous one this
   * browser resolves to — so the traits go on it and travel with it at `identify()`, when that identity becomes the
   * account or is absorbed into one. That keeps an onboarding survey's answers from exactly the people an onboarding
   * survey is shown to. `/v1/identify` needs an account id, so they ride the event queue as `traits_set`: its retries,
   * its storage across a reload, and its device proof. Which checks apply (declared, reserved) is the caller's to
   * decide; this only decides where an allowed trait goes.
   */
  private setMessageTraits(traits: EventProperties): void {
    if (this.userId) {
      this.identify(this.userId, traits);
      return;
    }
    this.track(TRAITS_SET_EVENT, { trait_keys: Object.keys(traits).sort(), traits });
  }

  /**
   * A form's answers: `in_app_form_submitted` with the answers, and — for a field the form keeps as an address —
   * `email` or `phone` beside them, which the server attaches to the person as an opt-in.
   */
  private inAppSubmitted(message: InAppMessage, responses: Record<string, string | number>): void {
    const { addresses: kept, traits } = formKeeps(message, responses);
    if (Object.keys(traits).length > 0) this.setMessageTraits(traits);
    // Answered: done on this browser, and the screen is free — the built-in renderer closes without a dismissal.
    this.freeFor(message);
    this.inApp?.markDone(message.delivery_id);
    this.track('in_app_form_submitted', { ...inAppReceipt(message), responses, ...kept });
    void this.flush();
  }

  /**
   * Fetches this browser's in-app messages now, rather than at the next session start or return to the tab, and
   * refreshes the trigger list with them. Never throws: on failure the messages already held stay usable. Does nothing
   * when in-app is off, before `init`, or after `optOut()`.
   */
  async syncInAppMessages(): Promise<void> {
    if (!this.inAppEnabled || !this.config || !this.inApp || this.optedOut) return;
    const base = this.backendUrl;
    /*
     * The signed-in person's id rides in `contentHeaders`, as it does on the notification read,
     * so the server answers for that person: a device outlives a sign-out, and the queue is the
     * person's, not the browser's. A header, not a parameter — an account id in a URL is kept by
     * every log and proxy it passes.
     */
    const params = new URLSearchParams({ device_id: this.deviceId });
    const url = `${base}${ENDPOINTS.inApp}?${params.toString()}`;
    /*
     * The answer carries the trigger list, on every outcome including the refusals below, so the
     * trigger list is told a sync is out — an upload answered with a new version meanwhile then
     * waits for this rather than fetching the list a second time.
     */
    this.triggers?.beginSync();
    let triggerEvents: unknown = null;
    const epoch = this.identityEpoch;
    try {
      const response = await fetch(url, { headers: this.contentHeaders(this.config.writeKey) });
      if (!response.ok) return;
      const body = (await response.json()) as InAppSyncResponse;
      triggerEvents = body.trigger_events;
      // Asked for somebody who has since signed out, or been replaced: their queue is not this person's.
      if (epoch !== this.identityEpoch) return;
      if (body.signature_required) this.warnSignatureRequired();

      // The server has not registered this browser's secret yet: report it now, rather than
      // wait out the seven-day context TTL with no messages to show.
      if (body.claim_required) {
        this.reportDeviceContext(this.persist, true);
        void this.flush();
        return;
      }
      await this.fetchLargeBodies(body.messages ?? []);
      this.inApp.accept(body);
      // TREEBARS_LIFECYCLE: the first answer from the server is when the page's messages are known.
      if (!this.settingsAnnounced) {
        this.settingsAnnounced = true;
        this.announce(WEB_EVENTS.settingsFetched, {}, WEB_EVENTS.lifecycle);
      }
    } catch {
      // Offline, blocked or a bad gateway. The queue already held stays usable.
    } finally {
      this.triggers?.endSync(triggerEvents);
    }
  }

  /**
   * Bodies over 64 KiB, which the sync hands over as `html_ref`: each fetched once from
   * `/v1/in-app/body`, checked against its hash, and kept on the message — or taken from the copy this browser already
   * holds. One that never arrives is `asset_download` when it would have been drawn.
   */
  private async fetchLargeBodies(messages: InAppMessage[]): Promise<void> {
    const held = new Map((this.inApp?.list() ?? []).map((message) => [message.delivery_id, message]));
    await Promise.all(
      messages.map(async (message) => {
        const inApp = message.content.in_app;
        if (!inApp?.html_ref || inApp.html) return;
        const kept = held.get(message.delivery_id)?.content.in_app;
        if (kept?.html && kept.html_ref?.sha256 === inApp.html_ref.sha256) {
          inApp.html = kept.html;
          return;
        }
        try {
          const params = new URLSearchParams({ device_id: this.deviceId, delivery_id: message.delivery_id });
          const response = await fetch(`${this.backendUrl}${ENDPOINTS.inAppBody}?${params.toString()}`, { headers: this.contentHeaders(this.config!.writeKey) });
          if (!response.ok) return;
          const { html } = (await response.json()) as { html?: unknown };
          if (typeof html === 'string' && (await sha256Hex(html)) === inApp.html_ref.sha256) inApp.html = html;
        } catch {
          /* offline: the next sync asks again */
        }
      }),
    );
  }

  /** An inbox receipt names the campaign as an overlay's does, while the message is held. */
  private inboxReceipt(deliveryId: string): Record<string, string> {
    const message = this.inApp?.list().find((row) => row.delivery_id === deliveryId);
    return message ? inAppReceipt(message) : { treebars_delivery_id: deliveryId };
  }

  /**
   * The in-app inbox: messages authored as inbox rows, for a page that draws its own message centre. Data only — the
   * page draws the list and reports what the person did with `viewed`, `clicked` and `dismiss`.
   */
  get inbox() {
    return {
      /** The inbox messages this browser holds now. Synchronous: it reads what the last sync fetched. */
      list: (): InAppMessage[] => this.inApp?.inbox() ?? [],
      /** Removes a row and reports `in_app_dismissed`. */
      dismiss: (deliveryId: string): void => {
        const receipt = this.inboxReceipt(deliveryId);
        this.inApp?.markDone(deliveryId);
        // An inbox dismissal is the person's, not the browser's, so the server removes
        // it everywhere they are signed in.
        this.track('in_app_dismissed', receipt);
        void this.flush();
      },
      /** Fetches the queue again (`syncInAppMessages`); read `list()` once it resolves. */
      refresh: (): Promise<void> => this.syncInAppMessages(),
      /** A row came into view: `in_app_displayed`, the card's "viewed". Report it once per showing of the list. */
      viewed: (deliveryId: string): void => {
        this.track('in_app_displayed', this.inboxReceipt(deliveryId));
      },
      /** A row was tapped: `in_app_clicked`, with where it went. The page does the going. */
      clicked: (deliveryId: string, destination?: string): void => {
        this.track('in_app_clicked', { ...this.inboxReceipt(deliveryId), ...(destination ? { destination } : {}) });
        void this.flush();
      },
    };
  }

  /**
   * The notification centre.
   *
   * Raw rows and a cursor; the page draws the list, or calls `mountNotificationCenter` for a
   * ready-made one. Not the same thing as `inbox` — that is the queue of in-app messages
   * authored as rows, still actionable and still styled, while this is the history of
   * everything sent to this person, push included, keeping what expiry and dismissal take out
   * of that queue.
   *
   * `list()` is **async** where `inbox.list()` is synchronous, and the asymmetry is real
   * rather than an inconsistency: the inbox reads a cache this SDK already holds, and this
   * is a network read. A synchronous signature would have to lie about that.
   */
  get notifications() {
    return {
      /**
       * One page of the history: up to `limit` rows after `cursor`, optionally only from some `channels`. When the server
       * cannot answer, the first page comes from this browser's cache (`fromCache: true`), and a later page comes back
       * empty with the same `nextCursor`, to try again. Never throws.
       */
      list: async (options: {
        limit?: number;
        cursor?: string | null;
        channels?: NotificationChannel[];
      } = {}): Promise<NotificationPage> => {
        const page = await this.fetchNotificationPage(options);
        if (page) return page;

        // A cursored call has no cache to fall back to — deep pages are network-only — so
        // it hands the cursor back rather than throwing, and the caller retries.
        if (options.cursor) {
          return { notifications: [], unreadCount: 0, nextCursor: options.cursor, fromCache: true };
        }
        return (
          this.notificationStore?.cached() ?? {
            notifications: [],
            unreadCount: 0,
            nextCursor: null,
            fromCache: true,
          }
        );
      },

      /** How many notifications are unread, asked of the server with a one-row read. */
      unreadCount: async (): Promise<number> => (await this.notifications.list({ limit: 1 })).unreadCount,

      /** Marks one notification read, here at once and then on the server, and reports `notification_read`. */
      markRead: async (groupId: string): Promise<void> => {
        // Recorded locally first, so the row stops reading as unread while the write is
        // still in flight. `overlay` is what keeps the next refresh from undoing it.
        this.notificationStore?.noteRead(groupId);
        this.emitNotificationChange();
        await this.writeNotificationState({ read: [groupId] });
      },

      /**
       * Marks everything read.
       *
       * Sends the server's own `server_time` as a watermark rather than a list of ids: a
       * list cannot express somebody returning to nine hundred unread, and the server
       * clamps the instant to its own clock so a fast clock cannot pre-read the future.
       */
      markAllRead: async (): Promise<void> => {
        const through =
          (await this.fetchNotificationPage({ limit: 1 })) && this.lastNotificationServerTime;
        if (!through) return;
        this.notificationStore?.noteReadThrough(through);
        this.emitNotificationChange();
        await this.writeNotificationState({ read_through: through });
      },

      /**
       * A notification or card tapped in the centre: opened, and read with it — what the campaign report counts as
       * Opened for the send, since a centre row has no delivery id to report through.
       */
      markOpened: async (groupId: string): Promise<void> => {
        this.notificationStore?.noteRead(groupId);
        this.emitNotificationChange();
        await this.writeNotificationState({ opened: [groupId] });
      },

      /** Removes one notification from the centre, here at once and then on the server, and reports `notification_dismissed`. */
      dismiss: async (groupId: string): Promise<void> => {
        this.notificationStore?.noteDismissed(groupId);
        this.emitNotificationChange();
        await this.writeNotificationState({ dismissed: [groupId] });
      },

      /** Fetches the first page again, as `list()` does; `onChange` listeners are told when it arrives. */
      refresh: (): Promise<NotificationPage> => this.notifications.list(),

      /** Called whenever the centre changes. Returns its own unsubscribe. */
      onChange: (callback: (page: NotificationPage) => void): (() => void) => {
        this.notificationWatchers.add(callback);
        return () => {
          this.notificationWatchers.delete(callback);
        };
      },
    };
  }

  /** One page from the server, or null when it could not be had. Never throws. */
  private async fetchNotificationPage(options: {
    limit?: number;
    cursor?: string | null;
    channels?: NotificationChannel[];
  }): Promise<NotificationPage | null> {
    if (!this.config || !this.notificationStore || this.optedOut) return null;

    const params = new URLSearchParams({ device_id: this.deviceId });
    if (options.limit) params.set('limit', String(options.limit));
    if (options.cursor) params.set('cursor', options.cursor);
    if (options.channels?.length) params.set('channels', options.channels.join(','));

    let body: NotificationWireResponse;
    const epoch = this.identityEpoch;
    try {
      const response = await fetch(`${this.backendUrl}${ENDPOINTS.notifications}?${params.toString()}`, {
        headers: this.contentHeaders(this.config.writeKey),
      });
      if (!response.ok) {
        // Logged rather than swallowed, so a refusal — a CORS misconfiguration, say — shows
        // in the console instead of as an empty list.
        console.warn('[treebars] notifications refused', response.status);
        return null;
      }
      body = (await response.json()) as NotificationWireResponse;
    } catch (error) {
      console.warn('[treebars] notifications fetch failed', error);
      return null;
    }

    // The previous person's history, answered after they signed out: not cached, not shown, not returned.
    if (epoch !== this.identityEpoch) return null;
    if (body.signature_required) this.warnSignatureRequired();

    // The server has not registered this browser's secret yet, so there is nothing to read.
    // Re-report the context, forced past the hash gate, exactly as the in-app sync does.
    if (body.claim_required) {
      this.reportDeviceContext(this.persist, true);
      void this.flush();
      return null;
    }

    this.lastNotificationServerTime = body.server_time;

    const notifications = this.notificationStore.overlay(body.notifications);
    const page: NotificationPage = {
      notifications,
      // Counted against the server's own rows, never the overlaid ones — see overlayCount.
      unreadCount: this.notificationStore.overlayCount(body.unread_count, body.notifications),
      nextCursor: body.next_cursor,
      fromCache: false,
    };

    /*
     * Only the DEFAULT first page is cached.
     *
     * A cursored page is a scroll position rather than a screen somebody comes back to. And
     * a page with an explicit `limit` is a probe — `unreadCount()` and `markAllRead()` both
     * ask for one row. Caching a one-row answer over the real first page would run the unread
     * arithmetic against a single row, and the badge would disagree with the list.
     */
    if (!options.cursor && options.limit === undefined) {
      this.notificationStore.accept(this.userId ?? this.deviceId, page);
      this.emitNotificationChange(page);
    }
    return page;
  }

  /**
   * Sends the marks, then reports them for analytics.
   *
   * In that order. The POST is the latch — acknowledged, and made with this device's secret
   * and the signed-in identity; the events are what make "how many of our notifications
   * get read" answerable, and they ride the ordinary queue where a drop costs a data point
   * rather than somebody's unread badge.
   */
  private async writeNotificationState(payload: {
    read?: string[];
    dismissed?: string[];
    read_through?: string;
    opened?: string[];
  }): Promise<void> {
    if (!this.config || this.optedOut) return;

    try {
      const response = await fetch(`${this.backendUrl}/v1/notifications/state`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...this.contentHeaders(this.config.writeKey) },
        body: JSON.stringify({
          device_id: this.deviceId,
          ...(this.userId ? { user_id: this.userId } : {}),
          ...payload,
        }),
      });
      if (!response.ok) {
        console.warn('[treebars] notification state write refused', response.status);
        return;
      }
      const body = (await response.json()) as {
        unread_count: number;
        server_time: string;
        signature_required?: boolean;
      };
      // Refused, not written: a mark that did not land is not reported as one.
      if (body.signature_required) {
        this.warnSignatureRequired();
        return;
      }
      this.lastNotificationServerTime = body.server_time;
    } catch (error) {
      // Kept in the ledger, so the row still reads as marked here and the next successful
      // page reconciles.
      console.warn('[treebars] notification state write failed', error);
      return;
    }

    for (const groupId of [...(payload.read ?? []), ...(payload.opened ?? [])]) {
      this.track('notification_read', { notification_group_id: groupId });
    }
    for (const groupId of payload.dismissed ?? []) {
      this.track('notification_dismissed', { notification_group_id: groupId });
    }
    if (payload.read_through) {
      this.track('notification_read', { read_through: payload.read_through });
    }
  }

  private emitNotificationChange(page?: NotificationPage): void {
    if (this.notificationWatchers.size === 0) return;
    const next = page ?? this.notificationStore?.cached();
    if (!next) return;
    for (const watcher of this.notificationWatchers) {
      try {
        watcher(next);
      } catch (error) {
        // One page callback that throws must not stop the others being told.
        console.warn('[treebars] onChange listener threw', error);
      }
    }
  }

  /**
   * A ready-made notification centre, drawn into `target` from `notifications`: cards and notifications, pinned first,
   * category tabs, unread dots, dismiss and mark-all-read, and a tap that marks it opened and goes where it says.
   * Returns the function that takes it down. A site with its own design draws its own from `notifications` instead.
   */
  mountNotificationCenter(target: HTMLElement, options: NotificationCenterOptions = {}): () => void {
    return mountNotificationCenter(
      target,
      {
        list: (page) => this.notifications.list({ cursor: page.cursor ?? null }),
        markOpened: (groupId) => this.notifications.markOpened(groupId),
        markAllRead: () => this.notifications.markAllRead(),
        dismiss: (groupId) => this.notifications.dismiss(groupId),
        onChange: (callback) => this.notifications.onChange(callback),
      },
      options,
    );
  }

  /**
   * Sets how overlay in-app messages are drawn: the page's own function, `'builtin'` for this SDK's renderer, or null.
   * Until one is set, overlays are never shown; the inbox is unaffected. Nudges are drawn only by the built-in renderer.
   */
  setInAppRenderer(renderer: WebInAppRenderer | 'builtin' | null): void {
    this.renderer = renderer;
  }

  /*
   * The page's in-app context API, named as common engagement SDKs name it on Android, so a migration keeps its call
   * sites. Self-handled messages go through `onsite.getSelfHandledOSM`, and what happens to a message is heard through
   * the TREEBARS_AUTOMATED_EVENTS window event.
   */

  /**
   * Where somebody is, in the site's own words: a message naming contexts shows only while one of them is set.
   * Replaces the set; `resetInAppContext()` clears it.
   */
  setInAppContext(contexts: string[]): void {
    this.appContexts = new Set(contexts.filter((context) => context !== ''));
  }

  /** Clears the contexts, so a message naming any is not shown until they are set again. */
  resetInAppContext(): void {
    this.appContexts = new Set();
  }

  private enqueue(
    eventName: string,
    properties: EventProperties,
    sessionId: string,
    /** ISO timestamp. Set only for an event backdated into a session that already closed. */
    timestamp?: string,
  ): Record<string, unknown> {
    /*
     * The dimensions, read once and returned: the event is stamped with these, and an in-app
     * trigger's dimension row reads the SAME object, so a trigger and the stored row cannot disagree about
     * the device. A browser stamps no `os_version`, `device_model`, `app_version` or `app_build`.
     */
    const dimensions = {
      sdk_version: SDK_VERSION,
      sdk_name: SDK_NAME,
      screen_name: typeof document !== 'undefined' ? document.title : undefined,
      // Cached after the first call. Coarse by design; see ./device for what is and is
      // not read, and why.
      ...getWebDeviceDimensions(),
    };
    const event: QueuedEvent = {
      event_id:
        typeof crypto !== 'undefined' && 'randomUUID' in crypto
          ? crypto.randomUUID()
          : `evt_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`,
      session_id: sessionId,
      device_id: this.deviceId,
      user_id: this.userId,
      event_name: eventName,
      properties,
      timestamp: timestamp ?? new Date().toISOString(),
      env: this.config?.env ?? 'production',
      ...dimensions,
    };

    this.store?.add(event);
    this.log(`queued ${eventName}`);
    // After the add, so the flush a listed event asks for finds it on the queue.
    this.uploader?.eventLogged(eventName);
    return dimensions;
  }

  /**
   * The uploader's transport: one batch, exactly as stored, and the three things it needs back.
   *
   * `Retry-After` and the trigger version are readable here only because the server lists both in
   * `Access-Control-Expose-Headers`. Neither is a CORS-safelisted response header, so without that
   * a cross-origin page reads null for every answer — falling back to jitter for the one, and never
   * learning its trigger list is stale for the other.
   */
  private async sendBatch(batch: PendingBatch): Promise<UploadResponse> {
    const json = JSON.stringify(batch);
    /*
     * Not while the page is hidden. Compressing is asynchronous, and the page-hide path depends on
     * a flush getting its request out before the handler returns (see `Uploader.flush`) — a page
     * that is going away is better served by the plain bytes now than by smaller ones never.
     */
    const hidden = typeof document !== 'undefined' && document.visibilityState === 'hidden';
    const gzipped = hidden ? null : await gzip(json);
    if (gzipped) this.compressed = { batchId: batch.batch_id, bytes: gzipped };

    /*
     * An opt-out that arrived while this compressed. The batch is already dropped (`Uploader.discard`)
     * and the answer would settle nothing — but the request itself has not been made, so it is not:
     * without this, a batch sealed before the "no" would go out a moment after it.
     */
    if (this.optedOut) throw new Error('opted out');

    const size = gzipped ? gzipped.byteLength : new TextEncoder().encode(json).byteLength;
    const response = await fetch(`${this.backendUrl}${ENDPOINTS.events}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(gzipped ? { 'Content-Encoding': 'gzip' } : {}),
        [HEADERS.writeKey]: this.config!.writeKey,
        // What a push token or a WhatsApp number in this batch is registered against: this device.
        [HEADERS.deviceAuth]: this.fetchSecret,
      },
      body: gzipped ?? json,
      keepalive: size <= KEEPALIVE_MAX_BYTES,
    });
    return {
      status: response.status,
      retryAfter: response.headers.get('Retry-After'),
      triggersVersion: response.headers.get(HEADERS.triggersVersion),
    };
  }

  private post(path: string, body: unknown, headers: Record<string, string> = {}): Promise<Response> {
    return fetch(`${this.backendUrl}${path}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        [HEADERS.writeKey]: this.config!.writeKey,
        ...headers,
      },
      body: JSON.stringify(body),
      // Lets the request outlive the page for the duration of a normal navigation.
      keepalive: true,
    });
  }

  /**
   * Last-chance delivery when the page is going away.
   *
   * A `keepalive` fetch, which the browser completes after the document is discarded, sent exactly as a flush sends a
   * batch: the same URL, the write key and the device secret in headers, gzip named by `Content-Encoding`, and no
   * credentials. Not `sendBeacon`: a beacon cannot choose its credentials mode — it always sends them — while its
   * `application/json` body makes the browser preflight it. The ingest endpoint authenticates by write key, never by
   * cookie, and answers without `Access-Control-Allow-Credentials`, so the browser would refuse a beacon and its events
   * would wait for the next page load. Same URL and credentials mode as a flush also means the same preflight cache
   * entry, which the page has almost always filled already, so nothing has to be negotiated while the page is leaving.
   *
   * It sends the PENDING batch — the one a failed flush left, or one sealed and written here —
   * under its own id, and it removes nothing: "the browser queued it" is not delivery. The batch
   * stays until a flush gets a 2xx for it, and a copy this request already delivered is recognised
   * by its id, so a request that never arrives loses nothing and one that does is never counted
   * twice. The answer is not read even when one comes, because a page being unloaded may never see
   * it and the uploader's own bookkeeping must not depend on it. The cost is one resend — which the
   * server answers as a duplicate — whenever the page survives the hide or its visitor returns.
   *
   * The 64 KiB keepalive quota applies as it does to a flush: past it the request goes without
   * `keepalive`, which a tab switch still completes and an unload cancels. Nothing is lost either
   * way; the batch waits for the next flush or page load.
   */
  private beacon(): void {
    if (!this.uploader || !this.config || this.optedOut) return;

    const batch = this.uploader.nextBeaconBatch();
    if (!batch) return;

    // The gzip copy a flush already made of this very batch, when there is one — there is no time to compress now.
    const compressed = this.compressed?.batchId === batch.batch_id ? this.compressed.bytes : null;
    const body = compressed ?? JSON.stringify(batch);
    const size = compressed ? compressed.byteLength : new TextEncoder().encode(body as string).byteLength;
    try {
      fetch(`${this.backendUrl}${ENDPOINTS.events}`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...(compressed ? { 'Content-Encoding': 'gzip' } : {}),
          [HEADERS.writeKey]: this.config.writeKey,
          [HEADERS.deviceAuth]: this.fetchSecret,
        },
        body,
        credentials: 'omit',
        keepalive: size <= KEEPALIVE_MAX_BYTES,
      }).catch((error: unknown) => {
        this.log(`last upload before hide failed for ${batch.events.length} event(s); kept for the next flush: ${String(error)}`);
      });
    } catch (error) {
      // A browser that throws synchronously rather than rejecting. Never into the host page's pagehide handler.
      this.log(`last upload before hide refused: ${String(error)}`);
    }
  }

  private installLifecycleHooks(): void {
    // `visibilitychange` to hidden is the only reliable end-of-page signal on mobile
    // Safari, where `beforeunload` and `unload` often never fire.
    document.addEventListener('visibilitychange', () => {
      const hidden = document.visibilityState === 'hidden';
      const now = Date.now();

      if (this.config?.autoLifecycle !== false) {
        // Queued before the beacon below, so the transition leaves with the batch it
        // belongs to rather than waiting for a page load that may never come.
        this.track(hidden ? DEFAULT_EVENTS.APP_BACKGROUND : DEFAULT_EVENTS.APP_FOREGROUND, {
          [hidden ? 'foreground_ms' : 'background_ms']: now - this.visibilityChangedAt,
        });
      }

      this.visibilityChangedAt = now;
      if (hidden) this.beacon();
    });
    window.addEventListener('pagehide', () => this.beacon());
  }

  /**
   * Carry a click id from this page onto its Play Store buttons (`acquisition.ts`).
   *
   * Read once per page load rather than per click: `carriedClick` also WRITES what it found, and
   * doing that inside the click handler would put a storage write on the path of somebody's tap.
   * The closure keeps the answer, so a click is a regex and a string concat.
   */
  private installStoreLinkCarrier(): void {
    const click = carriedClick(window.location.href, this.persist);
    this.log(click ? `carrying click ${click.clickId} to store links` : 'no click id on this visit');
    // A tracker link opened this page — the website's half of what the app SDKs report as `link_opened`.
    const opened = new URL(window.location.href).searchParams.get(ACQUISITION.clickIdParam);
    if (opened && click?.clickId === opened) this.reportLinkOpened(opened);
    /*
     * A visit from an ad that pointed straight at this site, with no Treebars tracker link in between:
     * the address carries the ad network's own click id instead of a Treebars one. Recorded as a click, and the id
     * that comes back is carried exactly like one from a tracker link. Only when this address is from
     * an ad — an ordinary visit is not a click — and never over a click the address already carried.
     */
    /*
     * Not with storage off. That is a visitor who has not consented, and recording the visit sets the
     * `tbrs_bs` cookie and posts the signals iPhone install matching reads — the browser id, the time
     * zone, the screen — which is what the switch exists to withhold. The page still carries a click id
     * its own address has.
     */
    if (
      this.persist &&
      !new URL(window.location.href).searchParams.get(ACQUISITION.clickIdParam) &&
      hasAdClick(window.location.href)
    ) {
      this.startVisit(false);
    }
    /*
     * Watched even when this page carries none. A single-page site can navigate to a URL that has
     * one without a page load, and `carriedClick` reads the address again at tap time — so the
     * listener has to already be there. It costs one closure and no work until somebody taps a
     * Play link.
     */
    this.stopStoreLinks = watchStoreLinks(
      () => carriedClick(window.location.href, this.persist),
      /*
       * A tap on a store button with nothing carried is itself worth recording: this website sent
       * somebody to install the app, which is the one thing an ordinary visit can prove. The watcher
       * asks with `storeTap`, the visit is recorded under the project's `website` source, and the id
       * it answers with is carried exactly as an ad click's is — Play's referrer, or the pasteboard.
       * A page view asks nothing: it proves nobody sent anybody anywhere.
       */
      (storeTap) => this.pendingVisit ?? (storeTap ? this.startVisit(true) : null),
    );
  }

  /**
   * `link_opened`, once per click: this page was opened by a tracker link (its address carries a Treebars
   * click id) or by an ad that pointed at it (the click the server just recorded, with the source it named). The
   * same event the app SDKs send when a link opens the app, so a link's and a source's Overview count a
   * website visit as an arrival and walk what the visitor did next. A reload of the same address is the
   * same arrival, so each click id is reported once in this browser.
   */
  private reportLinkOpened(clickId: string, source?: string): void {
    // With storage off, once per page load: the list below is somewhere to remember, and there is none.
    if (!this.persist) {
      if (this.linkOpenedThisPage.has(clickId)) return;
      this.linkOpenedThisPage.add(clickId);
      this.track(ACQUISITION.linkOpenedEvent, { click_id: clickId, ...(source ? { acq_source: source } : {}) });
      return;
    }
    const key = 'treebars.link_opened.v1';
    let seen: string[] = [];
    try {
      seen = JSON.parse(window.localStorage.getItem(key) ?? '[]') as string[];
    } catch {
      // A private window, or storage somebody else's script filled with junk: report it, at worst twice.
    }
    if (Array.isArray(seen) && seen.includes(clickId)) return;
    try {
      window.localStorage.setItem(key, JSON.stringify([...(Array.isArray(seen) ? seen : []), clickId].slice(-20)));
    } catch {
      /* private window */
    }
    this.track(ACQUISITION.linkOpenedEvent, { click_id: clickId, ...(source ? { acq_source: source } : {}) });
  }

  /** A visit being recorded right now — the store-link watcher waits for it on a tap. */
  private pendingVisit: Promise<void> | null = null;

  /** Records this visit, once at a time, and hands the watcher something to wait on. */
  private startVisit(storeTap: boolean): Promise<void> | null {
    if (this.optedOut || !this.persist || !this.config) return null;
    if (this.pendingVisit) return this.pendingVisit;
    this.pendingVisit = this.recordVisit(storeTap).finally(() => {
      this.pendingVisit = null;
    });
    return this.pendingVisit;
  }

  /** The click ids `link_opened` has reported on this page, when there is no storage to remember them in. */
  private linkOpenedThisPage = new Set<string>();

  /**
   * `POST /v1/web-click`, remembered on success. Failure is a visit that simply is not carried.
   *
   * `storeTap` says this visit is leaving for a store right now, which is what makes a visit no ad sent
   * worth a click id at all — the server credits it to the project's own website rather than refusing it.
   */
  private async recordVisit(storeTap: boolean): Promise<void> {
    if (this.optedOut) return;
    try {
      const browserId = sharedBrowserId();
      const response = await fetch(`${this.backendUrl}${ENDPOINTS.webClick}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', [HEADERS.writeKey]: this.config!.writeKey },
        body: JSON.stringify({
          // Trimmed as a page view's address is, which keeps what is needed here: the ad network's click id and the
          // `utm_` labels.
          url: analyticsUrl(window.location.href),
          device_id: this.deviceId,
          // For matching an iPhone install to this visit when nothing exact reaches it (`acquisition.ts`).
          ...(browserId ? { browser_id: browserId } : {}),
          ...(storeTap ? { store_tap: true } : {}),
          ...deviceSignals(),
        }),
        keepalive: true,
      });
      if (!response.ok) return;
      const answer = (await response.json()) as { recorded?: boolean; click_id?: string; source?: string; handoff?: boolean };
      if (!answer.recorded || !answer.click_id) return;
      rememberClick({ clickId: answer.click_id, deepLinkPath: null, ...(answer.handoff ? { handoff: true } : {}) }, this.persist);
      this.log(`recorded this visit as click ${answer.click_id} (${answer.source ?? 'no source'})`);
      this.reportLinkOpened(answer.click_id, answer.source);
    } catch {
      // The store buttons carry nothing extra, which is exactly the page without this.
    }
  }

  private installPageViewTracking(): void {
    this.page();

    // Single-page apps navigate without a page load, so history is instrumented to
    // emit a page view on client-side route changes.
    const emit = () => setTimeout(() => this.page(), 0);
    const originalPush = history.pushState;
    const originalReplace = history.replaceState;

    history.pushState = function (this: History, ...args: Parameters<History['pushState']>) {
      const result = originalPush.apply(this, args);
      emit();
      return result;
    };
    history.replaceState = function (this: History, ...args: Parameters<History['replaceState']>) {
      const result = originalReplace.apply(this, args);
      emit();
      return result;
    };

    window.addEventListener('popstate', emit);
  }

  private log(message: string): void {
    if (this.config?.debug) console.log(`[treebars] ${message}`);
  }

  /**
   * What a content read or write carries: the key, the device's secret, and — when somebody is signed
   * in — their account id and its signature. One place, so no route can forget the signature and be
   * refused for a reason the page never hears about.
   *
   * The account id is a header rather than a URL parameter, because a URL is what every proxy, access
   * log and crash reporter keeps; and percent-encoded, because a header value is Latin-1 at best —
   * `fetch` throws on "用户7" rather than send it. The server decodes it.
   */
  private contentHeaders(writeKey: string): Record<string, string> {
    return {
      [HEADERS.writeKey]: writeKey,
      [HEADERS.deviceAuth]: this.fetchSecret,
      ...(this.userId ? { [HEADERS.userId]: encodeURIComponent(this.userId) } : {}),
      ...(this.userId && this.userSignature ? { [HEADERS.userSignature]: this.userSignature } : {}),
    };
  }

  /**
   * Said out loud, and not only under `debug`: a missing signature is a setup step the integration
   * skipped, and what it costs — every sign-in unrecorded and every signed-in person's messages
   * withheld, silently — is exactly the kind of absence nobody goes looking for.
   */
  private warnSignatureRequired(): void {
    if (this.warnedSignature) return;
    this.warnedSignature = true;
    console.warn(
      '[treebars] this environment requires a signed identity, so sign-ins are not recorded and in-app ' +
        'messages and notifications are withheld: pass the signature your backend computes to ' +
        'identify(userId, attributes, signature).',
    );
  }

  /** Stops timers and listeners. Primarily for tests and hot reloading. */
  shutdown(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    if (this.wakeTimer !== null) clearTimeout(this.wakeTimer);
    this.wakeTimer = null;
    this.stopStoreLinks?.();
    this.stopStoreLinks = null;
    this.pendingDisplay?.cancel();
    this.pendingDisplay = null;
    this.freeScreen();
    this.closeNudges();
    this.started = false;
  }
}

const treebars = new TreebarsWeb();
export default treebars;
export { TreebarsWeb };
