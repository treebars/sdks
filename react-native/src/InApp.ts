/**
 * The in-app types a host app reads, and the helpers only JavaScript can hold.
 *
 * The in-app store, trigger matching, frequency rules and transport all run in the native
 * SDKs. What stays here is what an app drawing its own message needs:
 *
 * - The types, because the host app draws the message and has to read it the same way the SDK
 *   does.
 * - `inAppShape` and `inAppBodyMode`, because "where does this go" and "who writes the body"
 *   are two questions — custom HTML is a body, not a shape — and an app answering them by hand
 *   gets it subtly wrong.
 * - `inAppHtmlDocument`, which wraps markup exactly as the dashboard's composer previews it,
 *   so the preview is not wrong about margins.
 * - `readInAppHtmlAction`, because `treebars://` is the only channel sandboxed markup has back
 *   into the SDK, and the WebView that issues those loads is a JavaScript-side object.
 */

/** The style a message is drawn with, as the project's theme resolves it. */
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
  // `type` and `source` ride through untouched: the native SDKs read them, and this bridge
  // carries a trigger rather than evaluating one.
  | { kind: 'event'; event_name: string; filters?: { key: string; op: string; value?: unknown; type?: string; source?: string }[] };

/**
 * A button, as the composer stores it. `click` is not a stored action: it is what a host sends
 * for a markup body's `treebars://click/<n>` — "record that this was pressed" on a message that
 * stays on screen — and the native SDKs neither follow it nor end the message for it. Every
 * other action but `dismiss` ends the message on this device, as a dismissal does.
 */
export interface InAppButton {
  label: string;
  action: 'dismiss' | 'deep_link' | 'url' | 'track_event' | 'set_attribute' | 'custom' | 'call' | 'copy' | 'share' | 'store_review' | 'click';
  /**
   * Where a `deep_link` or `url` goes; a `set_attribute`'s value; the number a `call` dials,
   * the text a `copy` or `share` hands on — which the native SDK does, not this bridge.
   */
  value?: string;
  /** A `track_event`'s event. */
  event_name?: string;
  /** A `set_attribute`'s trait. */
  key?: string;
  /**
   * A `custom` button's keys, handed to the app through the `inAppCampaignCustomAction` event;
   * on a `deep_link` or `url`, the key-values already appended to `value`.
   */
  data?: Record<string, string>;
  /**
   * Which element was pressed, counting from 1: a typed button's place, or a markup body's
   * `treebars://click/<n>`. Forwarded to the native SDK, which reports it as `button_index`.
   */
  index?: number;
}

/**
 * One field of an in-app form. `save_as` keeps an email or phone answer as the person's
 * address; `trait` keeps the answer as a trait the message declares, which the native SDK sets.
 * A number answers as a number, a date as `YYYY-MM-DD`, several choices as one string, the picks
 * joined by commas.
 */
export interface InAppFormField {
  id: string;
  kind: 'text' | 'textarea' | 'email' | 'phone' | 'number' | 'date' | 'choice' | 'dropdown' | 'multi_choice' | 'rating' | 'nps';
  label: string;
  required?: boolean;
  /** `choice` and `multi_choice`: 2–10 answers; `dropdown`: 2–30. */
  options?: string[];
  /** What an empty box says before anything is typed or chosen. */
  placeholder?: string;
  save_as?: 'email' | 'phone';
  trait?: string;
}

export interface InAppForm {
  fields: InAppFormField[];
  submit_label?: string;
  thanks?: string;
}

/** One card of a carousel. */
export interface InAppSlide {
  image_url: string;
  /** What the image shows, for a screen reader. */
  image_alt?: string;
  title?: string;
  body?: string;
}

/** When and how a message is drawn beyond its trigger. An app reads `auto_dismiss_seconds`; the rest is the native SDK's. */
export interface InAppDisplay {
  on?: 'load' | 'delay' | 'scroll' | 'exit_intent';
  delay_seconds?: number;
  contexts?: string[];
  priority?: number;
  auto_dismiss_seconds?: number;
  self_handled?: boolean;
}

export interface InAppContent {
  surface: 'overlay' | 'inbox';
  /**
   * Where the message sits. `'html'` is the legacy spelling of `fullscreen` +
   * `body_mode: 'html'` — read it through `inAppShape()`, never directly.
   */
  layout: 'modal' | 'banner' | 'fullscreen' | 'html';
  /** Who writes the body: the typed fields, or `html`. Absent means `standard`. */
  body_mode?: 'standard' | 'html';
  html?: string;
  position?: 'top' | 'bottom' | 'center';
  /** What the message's image shows, for a screen reader. */
  image_alt?: string;
  dismissible?: boolean;
  buttons?: InAppButton[];
  trigger: InAppTrigger;
  /**
   * Declared because the message carries it, and deliberately not acted on here. Treebars turns
   * it into the message's own `expires_at` when the message is sent, which every SDK already
   * checks. Computing a second expiry from this field on the device would disagree with the
   * first the moment the device's clock did.
   */
  expires_after_seconds?: number;
  max_displays?: number;
  /** Drawn however recently another message was: the channel's minimum gap does not apply. */
  ignore_min_gap?: boolean;
  /**
   * Which way the message's language reads, resolved by Treebars from the locale it rendered.
   * Carried across the bridge untouched, for the app's renderer to honour. Absent means no
   * direction was given: draw it as usual.
   */
  direction?: 'rtl' | 'ltr';
  /** For the renderer to draw: a form, a carousel, a countdown to an instant, and when the message closes itself. */
  display?: InAppDisplay;
  form?: InAppForm;
  slides?: InAppSlide[];
  countdown_to?: string;
}

export type InAppBodyMode = NonNullable<InAppContent['body_mode']>;
export type InAppShape = 'modal' | 'banner' | 'fullscreen';

/*
 * Two questions — where the message sits, and who writes its body — and the two readers that
 * answer them.
 *
 * A renderer that reads `layout` directly is wrong for every message with a `body_mode`, and it
 * fails silently: custom markup is drawn as a themed card with an empty body, which looks like
 * the message rather than like a bug.
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
  if (layout === 'modal' || layout === 'banner' || layout === 'fullscreen') return layout;
  if (layout === 'html') return 'fullscreen';
  return 'modal';
}

/**
 * Enough of a document for a fragment to lay out like a message rather than like 1998.
 *
 * Wraps the markup exactly as the dashboard's composer does for its preview, so a device lays
 * it out as the preview did: the margins, the base font and how an image is sized.
 *
 * It injects **none** of the nine `InAppTokens`. Custom markup is drawn in a sandbox and
 * cannot read them; the container around it is the SDK's, and says only where it goes, not
 * what colour it is.
 *
 * **It sanitises nothing.** The markup is wrapped as it arrives, scripts and event handlers
 * included, so the sandbox it is drawn in is what keeps it from the app: a WebView with
 * JavaScript off, or an `<iframe sandbox="">` in a browser. Hand the result to anything that
 * runs scripts and a campaign's markup runs as the app.
 */
export function inAppHtmlDocument(body: string, direction?: InAppContent['direction']): string {
  return `<!doctype html>${htmlDirection(body, direction)}<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>
    html,body{margin:0;padding:0;background:transparent}
    body{font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;color:#111827}
    img{max-width:100%;display:block}
    a{color:inherit}
  </style>${body}`;
}

/**
 * `<html dir="rtl">` when the message reads right to left and the markup has not said; nothing
 * otherwise, so a message with no direction, or `ltr`, is wrapped byte for byte as the
 * composer's preview wraps it.
 *
 * A WebView's document is its own: the `writingDirection` the typed layouts use reaches
 * nothing inside it, so the document has to say it. It goes on `<html>`, straight after the
 * doctype. A `dir` on the author's own `<html>` or `<body>` is theirs and wins — and for
 * `<html>` that needs this check, because the parser folds a second `<html>` tag's attributes
 * into the first only where the first has none, so ours would silently beat theirs.
 */
function htmlDirection(body: string, direction: InAppContent['direction'] | undefined): string {
  return direction === 'rtl' && !/<(html|body)\b[^>]*\sdir\s*=/i.test(body) ? '<html dir="rtl">' : '';
}

/*
 * What a navigation out of a custom-HTML body means.
 *
 * Sandboxed markup cannot call into the SDK — that is what sandboxing means — so the only
 * channel it has is the URL it tries to open, and `treebars://` is the vocabulary. The
 * dashboard's button block emits these hrefs, so a renderer implementing anything else
 * disagrees with what the composer already wrote.
 *
 * Parsed here rather than in each renderer, so every platform reads the scheme the same way.
 */
export type InAppHtmlAction =
  /** `treebars://dismiss` — close and report `in_app_dismissed`. */
  | { kind: 'dismiss' }
  /** `treebars://click/<n>` — report `in_app_clicked` for button n. The message stays up. */
  | { kind: 'click'; index: number }
  /** Anything else — report the click FIRST, then hand the URL to the host app. */
  | { kind: 'link'; url: string };

/** Schemes that run or read where they are opened instead of going somewhere. */
const RUNS_IN_PLACE = new Set(['javascript', 'vbscript', 'data', 'blob', 'file', 'filesystem']);

/**
 * Whether opening a URL would run it. The scheme is read the way a browser reads one, with
 * control characters and spaces dropped first — the parser strips them at the ends and drops a
 * tab or a newline anywhere, so `java\tscript:` is `javascript:` — and not through `URL`,
 * because React Native's is a handful of regular expressions that does none of that.
 */
function runsInPlace(url: string): boolean {
  const scheme = /^([a-z][a-z0-9+.-]*):/i.exec(url.replace(/[\u0000- ]/g, ''));
  return scheme !== null && RUNS_IN_PLACE.has(scheme[1]!.toLowerCase());
}

/**
 * Reads one navigation attempt, or null when there is nothing to act on.
 *
 * Null covers the loads a WebView makes on its own — `about:blank`, the `data:` document we
 * hand it — which are not somebody pressing anything. Treating those as a click would report
 * an interaction for every message merely shown.
 *
 * And a URL that would run rather than go anywhere — `javascript:`, `data:`, `file:` — is
 * null too, never a `link`. The host opens a link, and a host that opened `javascript:` would
 * run the markup's script as itself: out of the sandbox, with the app's session. So this
 * refuses one whatever the markup says.
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
   * Only the two verbs above are the SDK's; a campaign's destinations belong to whoever
   * wrote them and are handed straight to the host app, scheme and all — an app's scheme is
   * not the SDK's to interpret.
   */
  return { kind: 'link', url: target };
}

export interface InAppMessage {
  delivery_id: string;
  campaign_id: string | null;
  content: { title?: string; body?: string; image_url?: string; in_app?: InAppContent };
  created_at: string;
  expires_at: string | null;
  /**
   * This message's own style, resolved by Treebars. When it is absent, the `tokens` a renderer
   * is handed already fall back to the project's default.
   */
  style?: InAppTokens;
}
