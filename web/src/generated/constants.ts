// Generated from the values every Treebars SDK shares. Do not edit.
//
// Treebars' build regenerates this file and fails when it and its source disagree,
// so a hand-edit here is caught rather than shipped.

export const ENDPOINTS = {
  events: '/v1/events',
  identify: '/v1/identify',
  inApp: '/v1/in-app',
  inAppBody: '/v1/in-app/body',
  notifications: '/v1/notifications',
  notificationState: '/v1/notifications/state',
  handoff: '/v1/handoff',
  webClick: '/v1/web-click',
  previewPair: '/v1/preview/pair',
  preview: '/v1/preview',
  inAppReward: '/v1/in-app/reward',
  contextToken: '/v1/context-token',
} as const;

export const HEADERS = {
  writeKey: 'X-Treebars-Key',
  deviceAuth: 'X-Treebars-Device-Auth',
  preview: 'X-Treebars-Preview',
  triggersVersion: 'X-Treebars-Triggers-Version',
  linkResolve: 'X-Treebars-Resolve',
  userSignature: 'X-Treebars-User-Signature',
  userId: 'X-Treebars-User-Id',
} as const;

export const BATCH_SIZE = 50;
export const DRAIN_MAX_BATCHES = 10;
/** Seconds. A retry waits random(0, min(cap, base * 2^attempt)). */
export const BACKOFF_BASE_SECONDS = 2;
export const BACKOFF_CAP_SECONDS = 60;
export const RETRY_AFTER_STATUSES = [429, 503] as const;
/** Seconds. */
export const RETRY_AFTER_MAX_SECONDS = 3600;
export const AUTH_STATUSES = [401, 403] as const;
/** Seconds. */
export const AUTH_COOLDOWN_SECONDS = 3600;
export const QUEUE_CAP = 1000;
export const SESSION_TIMEOUT_MS = 1800000;
export const CONTEXT_REPORT_TTL_MS = 7 * 24 * 60 * 60 * 1000;
export const DEFAULT_FLUSH_INTERVAL_MS = 30000;
/** How soon after a listed event its flush goes out. Armed by the first, not moved by later ones. */
export const TRIGGER_FLUSH_DEBOUNCE_MS = 1000;
export const DEFAULT_IN_APP_POLL_INTERVAL_MS = 900000;
export const IN_APP_PRESENTATION_HOLD_MS = 30000;
/** A reward claim refused with a 429 or 503, or unanswered, is asked again this many times, all within the budget. */
export const REWARD_CLAIM_RETRIES = 2;
export const REWARD_CLAIM_BUDGET_MS = 8000;

export const FNV_OFFSET_BASIS = 0x811c9dc5;
export const FNV_PRIME = 0x01000193;

export const DELIVERY_ID_KEY = 'treebars_delivery_id';
export const CAMPAIGN_ID_KEY = 'treebars_campaign_id';
/** Which element of an in-app message was pressed, on in_app_clicked. */
export const IN_APP_BUTTON_INDEX_KEY = 'button_index';
export const IN_APP_BUTTON_LABEL_KEY = 'button_label';
/** The window events this SDK dispatches: `e.detail` is `{ name, data }`. */
export const WEB_EVENTS = {
  automated: 'TREEBARS_AUTOMATED_EVENTS',
  lifecycle: 'TREEBARS_LIFECYCLE',
  shown: 'TREEBARS_ONSITE_MESSAGE_SHOWN',
  clicked: 'TREEBARS_ONSITE_MESSAGE_CLICKED',
  dismissed: 'TREEBARS_ONSITE_MESSAGE_DISMISSED',
  autoDismissed: 'TREEBARS_ONSITE_MESSAGE_AUTO_DISMISS',
  initialised: 'SDK_INITIALIZATION_COMPLETED',
  settingsFetched: 'SETTINGS_FETCHED',
} as const;
/** The event names React Native's setEventListener takes. */
export const RN_EVENT_NAMES = ['pushClicked', 'inAppCampaignShown', 'inAppCampaignClicked', 'inAppCampaignDismissed', 'inAppCampaignCustomAction', 'inAppCampaignSelfHandled'] as const;
/** An in-app button with this deep link asks for push permission instead of opening anything. */
export const PUSH_PERMISSION_LINK = 'treebars://push-permission';
/** Which of a push's buttons was pressed, on notification_opened (web push carries it too). */
export const RICH_PUSH_BUTTON_ID_KEY = 'treebars_button_id';

/*
 * The two parameter names a landing page has to read and re-emit.
 *
 * Treebars' tracking links write them, so a page that renames or drops either one loses the click
 * an install should be credited to, and nothing reports it. Swift has the same two.
 */
export const ACQUISITION = {
  clickIdParam: 'tbrs_click_id',
  deepLinkParam: 'tbrs_deep_link',
  /** The evidence event a link opening an already-installed app sends. */
  linkOpenedEvent: 'link_opened',
} as const;

/** Play's cap on the referrer it hands back, so a page cannot build one the store will truncate. */
export const MAX_REFERRER_LENGTH = 1000;

export const SDK_VERSION = '0.3.0';
export const SDK_NAME = 'treebars-web';
export const DEVICE_ID_PREFIX = 'dev_';

/** Only the two SDKs that have one. Android and iOS require an explicit host.  */
export const DEFAULT_BACKEND_URL = 'https://ingest.treebars.com';

export const RESERVED_EVENT_NAMES = [
  'session_start',
  'session_end',
  'app_open',
  'app_background',
  'app_foreground',
  'screen_view',
  'page_view',
  'notification_received',
  'notification_opened',
  'push_dismissed',
  'user_identified',
  'user_signed_out',
  'traits_set',
  'device_context',
  'app_uninstall',
  'flow_exited',
  'flow_entered',
  'in_app_displayed',
  'in_app_clicked',
  'in_app_dismissed',
  'in_app_form_submitted',
  'in_app_failed',
  'sms_received',
  'whatsapp_received',
  'notification_read',
  'notification_dismissed',
  'notification_permission_changed',
  'whatsapp_opt_in',
  'install_referrer',
  'apple_ads_attribution',
  'install_attributed',
  'link_opened',
  'reengagement_attributed',
] as const;

/** The condition operator codes, and only the codes: what each one means is the evaluator's. */
export const FILTER_OPERATOR_CODES = [
  'eq',
  'neq',
  'contains',
  'not_contains',
  'starts_with',
  'ends_with',
  'in',
  'not_in',
  'gt',
  'gte',
  'lt',
  'lte',
  'exists',
  'not_exists',
] as const;

/** The one number grammar every engine reads typed-number text with; match the WHOLE input. */
export const NUMBER_GRAMMAR = '^[+-]?([0-9]+\\.?[0-9]*|\\.[0-9]+)([eE][+-]?[0-9]+)?$';
/** The most items a stored condition list holds. */
export const LIST_MAX = 50;
/** Ingest's caps, in UTF-16 code units: a trimmed device field, and a screen name. */
export const DEVICE_FIELD_LENGTH = 128;
export const STRING_VALUE_LENGTH = 1024;

/** The dimension names an in-app trigger may read: an allowlist of keys, and nothing about what a row answers. */
export const IN_APP_DIMENSIONS = [
  'platform_type',
  'os_name',
  'os_version',
  'device_manufacturer',
  'device_model',
  'device_type',
  'app_version',
  'app_build',
  'sdk_name',
  'sdk_version',
  'locale',
  'timezone',
  'network_type',
  'screen_name',
] as const;

/** The push-permission states the app can still ask from: a message shown only then is held back from every other. */
export const PUSH_ASKABLE_STATUSES = ['not_determined', 'provisional', 'denied_askable'] as const;

// Storage keys are per platform and are NOT shared values. Agreement across platforms is the
// failure mode: a changed key does not migrate anything, it points this SDK at an empty address
// and every install in the field silently becomes a new anonymous device.
export const STORAGE_KEYS = {
  queue: 'treebars.queue.v1',
  uploader: 'treebars.uploader.v1',
  triggers: 'treebars.triggers.v1',
  device: 'treebars.device.v1',
  deviceContext: 'treebars.device_context.v1',
  fetchSecret: 'treebars.fetch_secret.v1',
  firstSeen: 'treebars.first_seen.v1',
  identifiedUser: 'treebars.identified_user.v1',
  signedInUser: 'treebars.signed_in_user.v1',
  signedInUserSignature: 'treebars.signed_in_user_signature.v1',
  session: 'treebars.session.v1',
  inApp: 'treebars.in_app.v1',
  inAppLedger: 'treebars.in_app_ledger.v1',
  notifications: 'treebars.notifications.v1',
  notificationLedger: 'treebars.notification_ledger.v1',
  acquisitionClick: 'treebars.acquisition_click.v1',
} as const;
