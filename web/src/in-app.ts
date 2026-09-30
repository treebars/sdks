import { safeGet, safeSet } from './storage';
import {
  DEVICE_FIELD_LENGTH,
  FILTER_OPERATOR_CODES,
  IN_APP_BUTTON_INDEX_KEY,
  IN_APP_BUTTON_LABEL_KEY,
  IN_APP_DIMENSIONS,
  LIST_MAX,
  NUMBER_GRAMMAR,
  STRING_VALUE_LENGTH,
} from './generated/constants';
import { BRIDGE_RESERVED_TRAITS } from './generated/bridge';
import type { InAppDisplayRules, InAppFailureReason, InAppForm, InAppSlide } from './on-site';

/*
 * In-app messages in the browser.
 *
 * The same three responsibilities as the iOS and Android SDKs — store, match, render — and
 * the same rules, deliberately: a message capped at three a day has to mean the same
 * thing on a phone and on a laptop. What differs is that everything here is synchronous,
 * because localStorage is.
 */

/*
 * One key per browser, not per write key: messages fetched under one key must never be drawn or reported under another,
 * and `claimStoredData` in `./storage` drops this store when the key changes, before it is built.
 */
const STORE_KEY = 'treebars.in_app.v1';
const LEDGER_KEY = 'treebars.in_app_ledger.v1';

export interface InAppTokens {
  accent: string;
  on_accent: string;
  surface: string;
  on_surface: string;
  on_surface_muted: string;
  backdrop: string;
  radius: number;
  font_family: string;
  button_shape: 'pill' | 'rounded' | 'square';
}

export type InAppTrigger =
  | { kind: 'immediate' }
  | { kind: 'session_start' }
  | { kind: 'screen_view'; screen_name: string }
  | { kind: 'event'; event_name: string; filters?: InAppFilter[] }
  /** The page a web push opened — any push, or one campaign's. */
  | { kind: 'push_click'; campaign_id?: string };

/**
 * One condition row on an event trigger, as a browser receives it. `type` says how the value compares — as text, a
 * number, a boolean or a version; `source: 'dimension'` reads the event's own dimension map, handed in by the context
 * `triggerMatches` takes, instead of its properties.
 */
export interface InAppFilter {
  key: string;
  op: string;
  value?: unknown;
  type?: string;
  source?: string;
}

/**
 * One button on a message, and what pressing it does: `dismiss` closes the message; `deep_link` and `url` go to
 * `value`; `track_event` records an event (`event_name`); `set_attribute` sets a trait on the signed-in person (`key`
 * and `value`); `custom` hands the page a bag of keys (`data`, in the TREEBARS_AUTOMATED_EVENTS window event); `call`,
 * `copy` and `share` act on the text in `value`; and `store_review` asks for an app store review, which the web cannot
 * do: the built-in renderer does not draw that button at all.
 */
export interface InAppButton {
  label: string;
  action: 'dismiss' | 'deep_link' | 'url' | 'track_event' | 'set_attribute' | 'custom' | 'call' | 'copy' | 'share' | 'store_review';
  value?: string;
  event_name?: string;
  key?: string;
  data?: Record<string, string>;
  /**
   * Which element this is, counting from 1: a typed button's position, or the `<n>` of a markup body's
   * `treebars://click/<n>`. Reported on `in_app_clicked` as `button_index`, so a message with two buttons reports which
   * one was pressed.
   */
  index?: number;
}

export interface InAppContent {
  surface: 'overlay' | 'inbox';
  /**
   * Where the message sits. `'html'` is the legacy spelling of `fullscreen` +
   * `body_mode: 'html'` — read it through `inAppShape()`, never directly.
   */
  layout: 'modal' | 'banner' | 'fullscreen' | 'nudge' | 'html';
  /** Who writes the body: the typed fields, or `html`. Absent means `standard`. */
  body_mode?: 'standard' | 'html';
  html?: string;
  /** The events and traits the markup's script declares it may record; the bridge refuses any other. */
  declared?: { events: string[]; traits: string[] };
  /** In place of `html` for a body over 64 KiB: fetched from `/v1/in-app/body` after the sync, and checked against its hash. */
  html_ref?: { sha256: string; bytes: number };
  /** `fullscreen` only: nothing drawn behind the markup, so markup that draws its own overlay shows the site through it. */
  transparent?: boolean;
  position?: 'top' | 'bottom' | 'center';
  /** What the message's image shows, for a screen reader. */
  image_alt?: string;
  /** Where on the page it sits, past the shapes every host draws. */
  placement?: { vertical?: 'top' | 'middle' | 'bottom'; horizontal?: 'start' | 'center' | 'end'; width?: number; push_down?: boolean };
  dismissible?: boolean;
  buttons?: InAppButton[];
  trigger: InAppTrigger;
  /**
   * Declared because the server sends it, and deliberately NOT acted on here.
   *
   * Treebars turns it into the message's own `expires_at` when the message is queued, and
   * every SDK checks that. Computing an expiry from this field as well would be a second,
   * independent answer to a question already answered — and the two would disagree the
   * moment a device's clock did.
   */
  expires_after_seconds?: number;
  max_displays?: number;
  /** Drawn however recently another message was: the channel's minimum gap does not apply. */
  ignore_min_gap?: boolean;
  /** Page rules, the on-site moment, contexts, session rules, priority, auto-dismiss, self-handled. */
  display?: InAppDisplayRules;
  form?: InAppForm;
  slides?: InAppSlide[];
  countdown_to?: string;
  font_url?: string;
  /** An inbox row drawn as a card. */
  card?: InAppCard;
  /**
   * Which way the message's language reads, resolved from the locale it was rendered in: Arabic copy drawn left-aligned
   * reads as broken even when every glyph is right. Absent, a renderer draws it in the page's own direction.
   */
  direction?: 'rtl' | 'ltr';
}

/**
 * An inbox row drawn as a card. `basic` is an icon beside the words, `illustration` a wide image above them;
 * `action` is what a tap does, `image_alt` is read aloud for the image, `pinned` keeps it first, `show_from` hides it
 * until then, `category` groups cards into a centre's tabs.
 */
export interface InAppCard {
  template: 'basic' | 'illustration';
  icon_url?: string;
  image_alt?: string;
  action?: { type: 'deep_link' | 'url'; value: string };
  pinned?: boolean;
  show_from?: string;
  category?: string;
  /** A button beside the tap: its words and where it goes. */
  cta?: { label: string; action: { type: 'deep_link' | 'url'; value: string } };
  /** Gone this many days after it was first seen — left out of the feed and the queue after that. */
  expires_after_seen_days?: number;
}

export type InAppBodyMode = NonNullable<InAppContent['body_mode']>;
export type InAppShape = 'modal' | 'banner' | 'fullscreen' | 'nudge';

/*
 * Two questions — where a message sits, and who writes its body — and the two readers that answer them.
 *
 * The legacy `layout: 'html'` answers both at once, so a renderer reading `layout` directly is
 * wrong for every message that sets `body_mode`, and it fails silently — custom markup is drawn
 * as a themed card with an empty body.
 */

/** Whether the body is the typed fields or markup, in either spelling. */
export function inAppBodyMode(
  content: Pick<InAppContent, 'layout' | 'body_mode'> | null | undefined,
): InAppBodyMode {
  if (!content) return 'standard';
  if (content.body_mode) return content.body_mode;
  return content.layout === 'html' ? 'html' : 'standard';
}

/**
 * Where the message sits, never the name of a body.
 *
 * Legacy `layout: 'html'` resolves to `fullscreen`: the old value carried no position, and a
 * sandboxed document with nowhere to be put is a document that takes the screen.
 */
export function inAppShape(content: Pick<InAppContent, 'layout'> | null | undefined): InAppShape {
  const layout = content?.layout;
  if (layout === 'modal' || layout === 'banner' || layout === 'fullscreen' || layout === 'nudge') return layout;
  if (layout === 'html') return 'fullscreen';
  return 'modal';
}

/**
 * A nudge: drawn in a slot of its own beside the one a modal takes, at most three on screen, and
 * outside the channel's caps — it neither waits on them nor spends them, so a nudge never holds back the modal the caps
 * were set for. Its own `max_displays`, expiry and dismissal still end it.
 */
export function isNudge(message: InAppMessage): boolean {
  return message.content.in_app?.layout === 'nudge';
}

/**
 * A markup body with the message's direction put on its document.
 *
 * The built-in renderer draws markup in a sandboxed `<iframe srcdoc>`, and a frame's document does not inherit `dir`
 * from the dialog around it — a `dir` on the dialog alone would align the close control and nothing the author wrote,
 * and an Arabic message in custom HTML would read left to right. So `rtl` goes on the markup's own `<html>`, inserted
 * after a leading doctype (before one, the frame would render in quirks mode).
 *
 * Only when the author has not said: a `dir` on their `<html>` or `<body>` is theirs. The order matters for `<html>`
 * in particular — the parser folds a second `<html>` tag's attributes into the first only where the first has none, so
 * ours going first would silently win. `ltr`, or no direction, is the markup exactly as sent.
 */
export function inAppHtmlWithDirection(html: string, direction: InAppContent['direction'] | undefined): string {
  if (direction !== 'rtl' || /<(html|body)\b[^>]*\sdir\s*=/i.test(html)) return html;
  const doctype = /^\s*<!doctype[^>]*>/i.exec(html)?.[0] ?? '';
  return `${doctype}<html dir="rtl">${html.slice(doctype.length)}`;
}

/*
 * What a navigation out of a custom-HTML body means.
 *
 * Sandboxed markup cannot call into the SDK — that is what sandboxing means — so the only
 * channel it has is the URL it tries to open, and `treebars://` is the vocabulary; the
 * dashboard's button block emits these hrefs. In a browser the sandbox is an
 * `<iframe sandbox="">`, so a page draws these by
 * listening for the frame's navigation attempt rather than by an interception callback —
 * the reading of the URL is the same either way, which is why it lives here.
 */
export type InAppHtmlAction =
  /** `treebars://dismiss` — close and report `in_app_dismissed`. */
  | { kind: 'dismiss' }
  /** `treebars://click/<n>` — report `in_app_clicked` for button n. The message stays up. */
  | { kind: 'click'; index: number }
  /** Anything else — report the click FIRST, then hand the URL to the host page. */
  | { kind: 'link'; url: string };

/**
 * Schemes that run or read where they are opened instead of going somewhere. A link in
 * message markup with one of these is never followed.
 */
const RUNS_IN_PLACE = new Set(['javascript', 'vbscript', 'data', 'blob', 'file', 'filesystem']);

/**
 * Whether opening a URL would run it, with the scheme read the way the browser's parser reads
 * it: control characters and spaces dropped first, so `java\tscript:` is `javascript:`.
 */
function runsInPlace(url: string): boolean {
  const scheme = /^([a-z][a-z0-9+.-]*):/i.exec(url.replace(/[\u0000- ]/g, ''));
  return scheme !== null && RUNS_IN_PLACE.has(scheme[1]!.toLowerCase());
}

/**
 * Reads one navigation attempt, or null when there is nothing to act on.
 *
 * A URL that would run rather than go anywhere — `javascript:`, `data:`, `file:` — is null,
 * never a `link`. The page opens a link, and a page that assigned `javascript:` to `location`
 * would run the markup's script as itself: out of the sandbox, with the visitor's session. So
 * the SDK refuses executable link schemes in message markup here, whatever the markup says.
 */
export function readInAppHtmlAction(url: string): InAppHtmlAction | null {
  const target = url.trim();
  if (!target) return null;
  if (target.startsWith('about:blank') || target === '#' || runsInPlace(target)) return null;

  if (target === 'treebars://dismiss') return { kind: 'dismiss' };

  const click = /^treebars:\/\/click\/(\d+)$/.exec(target);
  if (click) return { kind: 'click', index: Number(click[1]) };

  /*
   * Everything else is a link, and that deliberately includes the rest of `treebars://`.
   * Campaigns send people to deep links under that scheme, so claiming the whole of it here
   * would swallow the destinations. Only the two verbs above are the SDK's.
   */
  return { kind: 'link', url: target };
}

export interface InAppMessage {
  delivery_id: string;
  campaign_id: string | null;
  content: { title?: string; body?: string; image_url?: string; in_app?: InAppContent };
  created_at: string;
  expires_at: string | null;
  /** This message's own resolved tokens; absent when it has none, and the project default applies. */
  style?: InAppTokens;
  /** Its tokens in dark mode, when the message has a dark variant; absent otherwise. */
  style_dark?: InAppTokens;
  /**
   * A draft from the editor's "Test on device", never a queued message: drawn at once, recorded nowhere, and every
   * write its page asks for is refused (`BRIDGE_PREVIEW_WRITES`).
   */
  preview?: boolean;
  /**
   * What an HTML message kept for this person in its campaign (`setStoredValue`), handed over at sync with a message
   * whose markup reads it, so `getStoredValue` is local. Absent on every other message.
   */
  stored?: Record<string, string | number | boolean>;
  /**
   * A test send: drawn past every frequency cap — day, session, trigger kind and minimum gap — so a test is never held
   * back by a cap and mistaken for a broken message. Expiry and "done" still apply.
   */
  test?: boolean;
  /**
   * The files it loads, computed at sync and never authored: the project's stored files by hash, its font
   * stylesheets, the stored files it names that are gone (`missing`) and everything else (`external`). The iOS and
   * Android SDKs prefetch and inline the files; a browser draws them from its own cache, since each stored file's
   * address is served as immutable. What this SDK reads is `missing`: a markup body naming a stored file that is gone
   * is not drawn at all, rather than drawn with a hole in it, and is reported as failed.
   */
  assets?: { files?: { url: string; sha256: string; type: string; bytes: number }[]; stylesheets?: string[]; missing?: string[]; external?: string[] };
}

/**
 * What every in-app receipt carries: the delivery, and the campaign when there is one, so clicks and dismissals can be
 * reported by campaign. The iOS and Android SDKs build the same receipt.
 */
export function inAppReceipt(message: Pick<InAppMessage, 'delivery_id' | 'campaign_id'>): Record<string, string> {
  return {
    treebars_delivery_id: message.delivery_id,
    ...(message.campaign_id ? { treebars_campaign_id: message.campaign_id } : {}),
  };
}

/**
 * `in_app_clicked`'s properties: `destination` only for a button that sends somebody somewhere. A "set a trait"
 * button's value is the trait's value, not a place, so it is never reported as a destination.
 */
export function inAppClickProperties(
  message: Pick<InAppMessage, 'delivery_id' | 'campaign_id'> & { content?: InAppMessage['content'] },
  button: Pick<InAppButton, 'action' | 'value'> & Partial<Pick<InAppButton, 'label' | 'index'>>,
): Record<string, string | number> {
  const properties: Record<string, string | number> = inAppReceipt(message);
  if ((button.action === 'url' || button.action === 'deep_link') && button.value) properties.destination = button.value;
  // What was pressed: the element's number — the markup's `<n>`, or a typed button's place counting from 1 —
  // and a typed button's label when it has one.
  const position = message.content?.in_app?.buttons?.indexOf(button as InAppButton) ?? -1;
  const index = button.index ?? (position >= 0 ? position + 1 : undefined);
  if (index !== undefined) properties[IN_APP_BUTTON_INDEX_KEY] = index;
  if (button.label) properties[IN_APP_BUTTON_LABEL_KEY] = button.label;
  return properties;
}

const RESERVED_TRAITS: ReadonlySet<string> = new Set(BRIDGE_RESERVED_TRAITS);

/**
 * What a press hands the page's click listener: a `custom` button's keys, and for every other button its `value` — with
 * a link's key-values beside it, never in place of it, so a page routing on `values.value` still finds it when a link
 * carries extra keys such as UTM parameters. The iOS and Android SDKs follow the same rule.
 */
export function clickValues(button: Pick<InAppButton, 'action' | 'value' | 'data'>): Record<string, string> {
  if (button.action === 'custom') return button.data ?? (button.value ? { value: button.value } : {});
  return { ...(button.data ?? {}), ...(button.value ? { value: button.value } : {}) };
}

/**
 * What a sent form keeps beyond its answers: an email or phone field marked `save_as`, as an address Treebars attaches
 * to the person as an opt-in; and an answer kept as a trait — only a trait the message declares, and never one Treebars
 * keeps itself (`BRIDGE_RESERVED_TRAITS`). The same rule as a markup form's `data-tb-save`, and as the iOS and Android
 * SDKs'.
 */
export function formKeeps(
  message: Pick<InAppMessage, 'content'>,
  responses: Record<string, string | number>,
): { addresses: Record<string, string>; traits: Record<string, string | number> } {
  const inApp = message.content.in_app;
  const declared = new Set(inApp?.declared?.traits ?? []);
  const addresses: Record<string, string> = {};
  const traits: Record<string, string | number> = {};
  for (const field of inApp?.form?.fields ?? []) {
    const value = responses[field.id];
    if (value === undefined || value === '') continue;
    if (field.save_as && typeof value === 'string') addresses[field.save_as] = value;
    if (field.trait && declared.has(field.trait) && !RESERVED_TRAITS.has(field.trait)) traits[field.trait] = value;
  }
  return { addresses, traits };
}

/**
 * Whether a press ends the message on this browser, as a dismissal does: a link, a page, an event, a trait or the
 * app's keys — and the device actions, a call, a copy, a share, a store review, which every renderer closes the message
 * on as it does any call to action. Ending it means the next matching event does not draw it again. `dismiss` is not
 * one — its own dismissal follows — nor is anything this SDK does not know.
 */
export function inAppClickEndsMessage(button: Pick<InAppButton, 'action'>): boolean {
  return ['url', 'deep_link', 'track_event', 'set_attribute', 'custom', 'call', 'copy', 'share', 'store_review'].includes(button.action);
}

/** The trigger kinds a day cap can be set for. `immediate` is a send-now, and has none. */
export type CappedTriggerKind = 'session_start' | 'screen_view' | 'event';

export interface InAppPolicy {
  max_per_day: number | null;
  min_gap_seconds: number | null;
  /**
   * Caps this device counts itself: draws in one session, and distinct messages a day per trigger kind — in this
   * browser's own day. Absent means no cap.
   */
  max_per_session?: number | null;
  trigger_max_per_day?: Partial<Record<CappedTriggerKind, number | null>>;
  /** Nudges' own, counted on this browser outside every cap above: a session's, and a gap. */
  nudge_max_per_session?: number | null;
  nudge_min_gap_seconds?: number | null;
  messages_shown_today: number;
  last_shown_at: string | null;
}

export interface InAppSyncResponse {
  messages: InAppMessage[];
  policy: InAppPolicy | null;
  style?: InAppTokens;
  claim_required?: boolean;
  /** Set when a live environment wanted a valid `signature` (see `identify`) for the signed-in account id, and the read had none. */
  signature_required?: boolean;
  /** The country Treebars placed this request in, for a country session rule. */
  geo?: { country?: string };
  /** The environment's trigger list; `readTriggerList` in `./triggers` is what reads it. */
  trigger_events?: unknown;
  server_time: string;
}

interface Ledger {
  shown: Record<string, number>;
  done: Record<string, true>;
  last_shown_at: number | null;
  since_sync: number;
  /** Draws in the current session, keyed by its id so a new session starts at zero by itself. */
  session?: { id: string; shown: number };
  /** Distinct messages first drawn today, per trigger kind, in this browser's local day. */
  by_trigger?: { day: string; counts: Partial<Record<CappedTriggerKind, number>> };
  /** Nudges' own: drawn in the current session, and when the last one was — apart from the modals' above. */
  nudge_session?: { id: string; shown: number };
  nudge_last_shown_at?: number | null;
  /**
   * The last sync's caps, kept with the counts they are read against, so a page load that draws from the stored queue
   * before its own sync comes back is still capped — a session's cap, a trigger's share of the day, the daily cap and
   * nudges' caps alike. Here and not under a key of its own, so a sign-out, a write-key change and a store that keeps
   * nothing all cover it already.
   */
  policy?: InAppPolicy | null;
}

/*
 * A new ledger each time. A spread copies only the top level, so one shared constant spread into place would share the
 * same `shown` and `done` objects across every store and every `reset()` — and display counts would outlive a sign-out.
 */
const emptyLedger = (): Ledger => ({ shown: {}, done: {}, last_shown_at: null, since_sync: 0 });

/** This browser's local calendar day, which is what "a day" means for a count the device keeps. */
function localDay(at: number): string {
  const d = new Date(at);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function cappedKind(message: InAppMessage): CappedTriggerKind | null {
  const kind = message.content.in_app?.trigger?.kind;
  return kind === 'session_start' || kind === 'screen_view' || kind === 'event' ? kind : null;
}

export class InAppStore {
  private messages: InAppMessage[] = [];
  private ledger: Ledger = emptyLedger();
  private tokens: InAppTokens | null = null;
  /** The country of the last sync, for a country session rule; kept only in memory. */
  country: string | undefined;

  constructor(private persist: boolean) {
    /*
     * Read only where it would also be written: a page with storage off, or a person who opted out, starts empty rather
     * than reading what an earlier visit left under this key. What this store holds under a DIFFERENT write key is
     * dropped before it is built (`claimStoredData`).
     */
    if (!persist) return;
    try {
      const queue = safeGet(STORE_KEY);
      if (queue) this.messages = JSON.parse(queue) as InAppMessage[];
      const ledger = safeGet(LEDGER_KEY);
      if (ledger) this.ledger = { ...emptyLedger(), ...(JSON.parse(ledger) as Ledger) };
      // A stored ledger without a policy has none: nothing is capped until a sync brings one.
      if (typeof this.ledger.policy !== 'object') this.ledger.policy = null;
    } catch {
      // A corrupt store is an empty store. Analytics must never break the host page.
    }
  }

  accept(response: InAppSyncResponse): void {
    this.messages = response.messages;
    if (response.policy) {
      this.ledger.policy = response.policy;
      // The server's count already includes anything shown before this moment.
      this.ledger.since_sync = 0;
    }
    if (response.style) this.tokens = response.style;
    if (response.geo?.country) this.country = response.geo.country;

    const live = new Set(this.messages.map((message) => message.delivery_id));
    for (const id of Object.keys(this.ledger.shown)) if (!live.has(id)) delete this.ledger.shown[id];
    for (const id of Object.keys(this.ledger.done)) if (!live.has(id)) delete this.ledger.done[id];
    this.save();
  }

  list(): InAppMessage[] {
    return this.messages;
  }

  /**
   * The inbox rows, pinned cards first and newest first within each — a card whose `show_from` has not come yet left
   * out, as the notification feed leaves it out.
   */
  inbox(now: number = Date.now()): InAppMessage[] {
    const rows = this.messages.filter((message) => {
      if (message.content.in_app?.surface !== 'inbox') return false;
      const from = message.content.in_app.card?.show_from;
      return !from || Date.parse(from) <= now;
    });
    return rows.filter((row) => row.content.in_app?.card?.pinned).concat(rows.filter((row) => !row.content.in_app?.card?.pinned));
  }

  /**
   * A message's own tokens when it has them, else the project default from the sync — its dark ones on a page read in
   * dark mode, when it has a dark variant. Asked as it is drawn, so the colours are right on the
   * first paint rather than corrected after it.
   */
  styleTokensFor(message: InAppMessage, dark = false): InAppTokens | null {
    if (dark && message.style_dark) return message.style_dark;
    return message.style ?? this.tokens;
  }

  recordDisplay(message: InAppMessage, sessionId: string | null = null, now: number = Date.now()): void {
    const id = message.delivery_id;
    // A nudge spends only its own ledger (`isNudge`): the day, session, trigger and gap ledgers are the modals'.
    if (isNudge(message)) {
      if (sessionId) {
        const session = this.ledger.nudge_session?.id === sessionId ? this.ledger.nudge_session : { id: sessionId, shown: 0 };
        this.ledger.nudge_session = { id: sessionId, shown: session.shown + 1 };
      }
      this.ledger.nudge_last_shown_at = now;
      const shown = (this.ledger.shown[id] ?? 0) + 1;
      this.ledger.shown[id] = shown;
      const max = message.content.in_app?.max_displays;
      if (typeof max === 'number' && max > 0 && shown >= max) this.ledger.done[id] = true;
      this.save();
      return;
    }
    const firstTime = (this.ledger.shown[id] ?? 0) === 0;
    if (sessionId) {
      const session = this.ledger.session?.id === sessionId ? this.ledger.session : { id: sessionId, shown: 0 };
      this.ledger.session = { id: sessionId, shown: session.shown + 1 };
    }
    const kind = cappedKind(message);
    if (kind && firstTime) {
      const day = localDay(now);
      const counts = this.ledger.by_trigger?.day === day ? this.ledger.by_trigger.counts : {};
      this.ledger.by_trigger = { day, counts: { ...counts, [kind]: (counts[kind] ?? 0) + 1 } };
    }
    const shown = (this.ledger.shown[id] ?? 0) + 1;
    this.ledger.shown[id] = shown;
    this.ledger.last_shown_at = Date.now();
    this.ledger.since_sync += 1;
    const max = message.content.in_app?.max_displays;
    if (typeof max === 'number' && max > 0 && shown >= max) this.ledger.done[id] = true;
    this.save();
  }

  markDone(deliveryId: string): void {
    this.ledger.done[deliveryId] = true;
    this.save();
  }

  reset(): void {
    this.messages = [];
    this.ledger = emptyLedger();
    this.save();
  }

  /** Whether this browser may draw this message now. Same rules as every other SDK. */
  allows(message: InAppMessage, sessionId: string | null = null, now: number = Date.now()): boolean {
    return this.blockedBy(message, sessionId, now) === null;
  }

  /**
   * Why this browser may not draw this message now, or null when it may — the reason an `in_app_failed` names.
   * `done` is not a failure: a message already shown as often as it may be, or dismissed, is finished, not held back.
   */
  blockedBy(message: InAppMessage, sessionId: string | null = null, now: number = Date.now(), nudgesInFlight = 0): InAppFailureReason | 'done' | null {
    const id = message.delivery_id;
    if (this.ledger.done[id]) return 'done';
    if (message.expires_at && Date.parse(message.expires_at) <= Date.now()) return 'expired';

    const policy = this.ledger.policy;
    if (!policy) return null;
    // A test send is drawn past every cap below.
    if (message.test === true) return null;
    /*
     * A nudge is outside them (`isNudge`), under two caps of its own. `nudgesInFlight` are drawn and not yet on screen —
     * a nudge is counted only once it is shown — so they count here as shown now: three nudges one event draws are three
     * before any of them reports, which the ledger alone would not know.
     */
    if (isNudge(message)) {
      const cap = policy.nudge_max_per_session;
      const shownHere = sessionId && this.ledger.nudge_session?.id === sessionId ? this.ledger.nudge_session.shown : 0;
      if (cap && shownHere + nudgesInFlight >= cap) return 'max_per_session';
      const gap = policy.nudge_min_gap_seconds;
      const last = this.ledger.nudge_last_shown_at;
      if (gap && (nudgesInFlight > 0 || (last && now - last < gap * 1000))) return 'min_gap';
      return null;
    }

    // The cap counts distinct messages, matching the server, so seeing one again does
    // not spend another unit of the allowance.
    const alreadySeen = (this.ledger.shown[id] ?? 0) > 0;
    if (policy.max_per_day !== null && !alreadySeen) {
      if (policy.messages_shown_today + this.ledger.since_sync >= policy.max_per_day) return 'max_per_day';
    }

    // Per session: every draw counts, a repeat of the same message included — each one interrupted somebody.
    if (policy.max_per_session && sessionId) {
      const drawn = this.ledger.session?.id === sessionId ? this.ledger.session.shown : 0;
      if (drawn >= policy.max_per_session) return 'max_per_session';
    }

    // Per trigger kind a day: distinct messages, like the day cap, so a repeat spends nothing more.
    const kind = cappedKind(message);
    const kindCap = kind ? policy.trigger_max_per_day?.[kind] : null;
    if (kind && kindCap && !alreadySeen) {
      const counts = this.ledger.by_trigger?.day === localDay(now) ? this.ledger.by_trigger.counts : {};
      if ((counts[kind] ?? 0) >= kindCap) return 'trigger_cap';
    }

    if (policy.min_gap_seconds !== null && message.content.in_app?.ignore_min_gap !== true) {
      const serverLast = policy.last_shown_at ? Date.parse(policy.last_shown_at) : 0;
      const last = Math.max(serverLast, this.ledger.last_shown_at ?? 0);
      if (last && now - last < policy.min_gap_seconds * 1000) return 'min_gap';
    }

    return null;
  }

  private save(): void {
    if (!this.persist) return;
    safeSet(STORE_KEY, JSON.stringify(this.messages));
    safeSet(LEDGER_KEY, JSON.stringify(this.ledger));
  }
}

/**
 * What else a trigger may read of the moment. `screen` is the live screen the draw loop passes,
 * which a `screen_view` trigger reads ahead of `properties.screen_name`. `dimensions` is the dimension map the
 * SDK stamped on THIS event — the same object, never a second read of the device — which a dimension row reads;
 * without it a dimension row is false.
 */
export interface InAppContext {
  screen?: string | null;
  dimensions?: Record<string, unknown> | null;
}

/**
 * Whether a message's trigger matches what just happened.
 *
 * The same rule as the iOS and Android SDKs', deliberately: a message triggered one way on a phone and
 * another in a browser would be a difference nobody could see without comparing two screens. All three
 * take the same context and answer the same cases.
 */
export function triggerMatches(
  trigger: InAppTrigger,
  eventName: string,
  properties: Record<string, unknown>,
  context: InAppContext = {},
): boolean {
  const screenName = context.screen;
  switch (trigger.kind) {
    case 'immediate':
      return true;
    case 'session_start':
      return eventName === 'session_start' || eventName === 'app_open';
    case 'screen_view':
      // page_view is the web's screen_view; Treebars treats them alike.
      return (
        (eventName === 'page_view' || eventName === 'screen_view') &&
        (screenName ?? properties.screen_name ?? properties.name) === trigger.screen_name
      );
    case 'event':
      return eventName === trigger.event_name && matchesFilters(properties, trigger.filters, context.dimensions);
    case 'push_click':
      // The page a web push opened reports `notification_opened` with the campaign that sent it.
      return eventName === 'notification_opened' && (!trigger.campaign_id || properties.treebars_campaign_id === trigger.campaign_id);
    default:
      return false;
  }
}

/**
 * Whether a filter has been authored far enough to mean anything.
 *
 * The dashboard's filter builder saves `{ key: '', op: 'eq', value: '' }` the moment "Add filter"
 * is clicked. Read literally that row asks for a property named `''`, which nothing has, so the
 * whole trigger would match nobody — a working campaign would stop reaching every device because
 * of a row nobody finished. An incomplete row is dropped instead, and the rows beside it decide.
 */
function isCompleteFilter(filter: InAppFilter): boolean {
  if (filter.key.trim() === '') return false;
  // `exists` is complete on its key alone; every other operator needs something to compare against —
  // `not_exists` included, which carries a marker so an older SDK sees a complete row it refuses.
  if (filter.op === 'exists') return true;
  return filter.value !== undefined && filter.value !== null && String(filter.value) !== '';
}

/** An object with a string key: the shape every reader assumes. */
function isWellFormed(filter: unknown): filter is InAppFilter {
  return (
    typeof filter === 'object' &&
    filter !== null &&
    !Array.isArray(filter) &&
    typeof (filter as { key?: unknown }).key === 'string'
  );
}

/**
 * The trigger's filters against one event, read in DEVICE mode — the same reading every Treebars SDK gives
 * them, so a trigger reaches the same people on every platform.
 *
 * A malformed element fails the WHOLE trigger, not just its row. Dropped, `[{plan eq pro}, "x"]` against
 * `{plan: 'pro'}` would still draw — a message shown to somebody no rule ever described.
 */
function matchesFilters(
  properties: Record<string, unknown>,
  filters?: unknown,
  dimensions?: Record<string, unknown> | null,
): boolean {
  if (filters === undefined || filters === null) return true;
  if (!Array.isArray(filters) || !filters.every(isWellFormed)) return false;
  if (filters.length === 0) return true;
  // Incomplete rows are dropped before the conjunction, not failed inside it — an unfinished row
  // beside a real one must leave the real one deciding.
  return filters.filter(isCompleteFilter).every((filter) => matchesFilter(properties, filter, dimensions));
}

const KNOWN: ReadonlySet<string> = new Set(FILTER_OPERATOR_CODES);
/** The codes that match a value that is not set. */
const NEGATED: ReadonlySet<string> = new Set(['neq', 'not_contains', 'not_in', 'not_exists']);
const TEXT_CODES: ReadonlySet<string> = new Set(['contains', 'not_contains', 'starts_with', 'ends_with']);
const TYPES: ReadonlySet<string> = new Set(['string', 'number', 'boolean', 'version']);
const DIMENSIONS: ReadonlySet<string> = new Set(IN_APP_DIMENSIONS);
const GRAMMAR = new RegExp(NUMBER_GRAMMAR);

function matchesFilter(
  properties: Record<string, unknown>,
  filter: InAppFilter,
  dimensions: Record<string, unknown> | null | undefined,
): boolean {
  // A side or a type this SDK does not read, and a code it does not know, fail closed: showing a message to
  // people who do not qualify is worse than showing it to nobody.
  if (filter.source !== undefined && filter.source !== 'property' && filter.source !== 'dimension') return false;
  if (filter.type !== undefined && !TYPES.has(filter.type)) return false;
  if (!KNOWN.has(filter.op)) return false;

  /*
   * A dimension row reads the event's own map, never a property of the same name — and is false, not
   * "not set", without one, or for a name an in-app trigger may not read: geo, which a device cannot know,
   * and anything outside `IN_APP_DIMENSIONS`. Read as not set it would pass `neq`. A dimension holds text,
   * so the row compares as text unless it is a version row.
   */
  if (filter.source === 'dimension') {
    if (!dimensions || !DIMENSIONS.has(filter.key)) return false;
    const stamped = Object.prototype.hasOwnProperty.call(dimensions, filter.key) ? dimensions[filter.key] : undefined;
    const row = filter.type === 'version' ? filter : { ...filter, type: 'string' };
    return compareValue(storedDimension(filter.key, stamped), row);
  }

  // By its literal, own key: `toString` finds nothing.
  const actual = Object.prototype.hasOwnProperty.call(properties, filter.key) ? properties[filter.key] : undefined;
  return compareValue(actual, filter);
}

/**
 * A dimension as Treebars will store it, from the value this SDK stamped. A device field is trimmed and cut
 * at the generated `DEVICE_FIELD_LENGTH`; a screen name is not trimmed and is cut at `STRING_VALUE_LENGTH`;
 * anything empty or not a string is missing. Both cuts count UTF-16 code units, as `slice` does.
 */
function storedDimension(name: string, value: unknown): string | undefined {
  if (typeof value !== 'string') return undefined;
  if (name === 'screen_name') return value.length === 0 ? undefined : value.slice(0, STRING_VALUE_LENGTH);
  const trimmed = value.trim();
  return trimmed.length === 0 ? undefined : trimmed.slice(0, DEVICE_FIELD_LENGTH);
}

/** One row's comparison in device mode, over a value already found by whichever side the row names. */
function compareValue(actual: unknown, filter: InAppFilter): boolean {
  // Not set is missing, null or `""`: "is set" is false for it; every negated code matches it.
  const unset = actual === undefined || actual === null || actual === '';
  const op = filter.op;
  if (op === 'exists') return !unset;
  if (op === 'not_exists') return unset;
  // A row that cannot say anything matches nobody, before the not-set reading.
  if (saysNothing(filter)) return false;
  if (unset) return NEGATED.has(op);
  // A property that is not a scalar — an array, an object — fails closed, the negated codes included.
  if (typeof actual !== 'string' && typeof actual !== 'number' && typeof actual !== 'boolean') return false;

  if (op === 'in' || op === 'not_in') {
    const items = decodeList(filter.value)!;
    const as = filter.type ?? (typeof items[0] === 'number' ? 'number' : 'string');
    if (as === 'version') {
      // Every item parses — `saysNothing` refused the row otherwise; a present value that does not is false.
      const left = parseVersion(actual);
      if (!left) return false;
      const hit = items.some((item) => compareVersion(left, parseVersion(item)!) === 0);
      return op === 'in' ? hit : !hit;
    }
    if (as === 'number') {
      const left = asNumber(actual, filter.type === 'number');
      if (left === null) return false;
      const hit = (items as number[]).includes(left);
      return op === 'in' ? hit : !hit;
    }
    const hit = items.some((item) => String(actual) === String(item));
    return op === 'in' ? hit : !hit;
  }

  const as = filter.type ?? (typeof filter.value === 'number' ? 'number' : typeof filter.value === 'boolean' ? 'boolean' : 'string');
  if (as === 'version') {
    // Part by part: 2.10 is after 2.9.1, and 2.3 = 2.3.0. A present value that does not
    // parse — a JSON number, 2.4.0-beta — is false under every code here, `neq` included; a text code has no
    // version reading.
    const left = parseVersion(actual);
    if (!left) return false;
    const order = compareVersion(left, parseVersion(filter.value)!);
    switch (op) {
      case 'eq': return order === 0;
      case 'neq': return order !== 0;
      case 'gt': return order > 0;
      case 'gte': return order >= 0;
      case 'lt': return order < 0;
      case 'lte': return order <= 0;
      default: return false;
    }
  }
  if (as === 'number') {
    // With no `type` only a JS number; under `type: 'number'`, text in `NUMBER_GRAMMAR` too.
    const left = asNumber(actual, filter.type === 'number');
    const right = filter.value as number;
    if (left === null) return false;
    switch (op) {
      case 'eq': return left === right;
      case 'neq': return left !== right;
      case 'gt': return left > right;
      case 'gte': return left >= right;
      case 'lt': return left < right;
      case 'lte': return left <= right;
      default: return false;
    }
  }

  // `string` and `boolean` compare text — `"150"` is `150` here, and `true` is `"true"`.
  const left = String(actual);
  const right = String(filter.value ?? '');
  const orders = filter.type !== 'boolean';
  switch (op) {
    case 'eq': return left === right;
    case 'neq': return left !== right;
    case 'contains': return left.includes(right);
    case 'not_contains': return !left.includes(right);
    case 'starts_with': return left.startsWith(right);
    case 'ends_with': return left.endsWith(right);
    case 'gt': return orders && left > right;
    case 'gte': return orders && left >= right;
    case 'lt': return orders && left < right;
    case 'lte': return orders && left <= right;
    default: return false;
  }
}

/**
 * Whether a row cannot say anything: a value that is not a scalar, a list that does not decode, a number row holding text or
 * under a text code, and a version row whose value or any item does not parse. It runs before the not-set
 * reading, so "app version is not 2.4.0-beta" never matches every device that sends no app version — which on
 * this SDK is every device, because a browser has none.
 */
function saysNothing(filter: InAppFilter): boolean {
  // A value that is not a scalar has no comparison; a list is always a JSON string.
  if (typeof filter.value === 'object' && filter.value !== null) return true;
  if (filter.op === 'in' || filter.op === 'not_in') {
    const items = decodeList(filter.value);
    if (!items) return true;
    const as = filter.type ?? (typeof items[0] === 'number' ? 'number' : 'string');
    if (as === 'number') return typeof items[0] !== 'number';
    if (as === 'version') return items.some((item) => parseVersion(item) === null);
    return false;
  }
  const as = filter.type ?? (typeof filter.value === 'number' ? 'number' : typeof filter.value === 'boolean' ? 'boolean' : 'string');
  if (as === 'number') return typeof filter.value !== 'number' || TEXT_CODES.has(filter.op);
  if (as === 'version') return parseVersion(filter.value) === null;
  return false;
}

/**
 * A version's parts: a string of one to four dot-separated
 * parts of one to ten ASCII digits, with an optional leading `v`. Only a string parses — the JSON number 2.3 is
 * not a version — and `$` without the `m` flag anchors at the very end, so `"2.3\n"` does not either. Ten digits
 * stay exact in a JavaScript number.
 */
const VERSION = /^[vV]?[0-9]{1,10}(\.[0-9]{1,10}){0,3}$/;

function parseVersion(value: unknown): number[] | null {
  if (typeof value !== 'string' || !VERSION.test(value)) return null;
  const body = value[0] === 'v' || value[0] === 'V' ? value.slice(1) : value;
  return body.split('.').map(Number);
}

/** Part by part, both sides padded with zeros to four parts, so 2.3 = 2.3.0 = 2.3.0.0. */
function compareVersion(a: readonly number[], b: readonly number[]): number {
  for (let i = 0; i < 4; i += 1) {
    const left = a[i] ?? 0;
    const right = b[i] ?? 0;
    if (left !== right) return left < right ? -1 : 1;
  }
  return 0;
}

/** A stored list — a JSON array as a string, of non-empty strings or finite numbers, at most `LIST_MAX`. */
function decodeList(value: unknown): (string | number)[] | null {
  if (typeof value !== 'string') return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(value);
  } catch {
    return null;
  }
  if (!Array.isArray(parsed) || parsed.length === 0 || parsed.length > LIST_MAX) return null;
  if (parsed.every((item) => typeof item === 'string' && item.length > 0)) return parsed as string[];
  if (parsed.every((item) => typeof item === 'number' && Number.isFinite(item))) return parsed as number[];
  return null;
}

function asNumber(actual: unknown, readText: boolean): number | null {
  if (typeof actual === 'number') return Number.isNaN(actual) ? null : actual;
  if (readText && typeof actual === 'string' && GRAMMAR.test(actual)) return Number(actual);
  return null;
}
