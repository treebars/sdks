import type { InAppButton, InAppContent, InAppMessage, InAppTokens } from './in-app';
import { inAppBodyMode, inAppShape } from './in-app';
import { hostMarkup, type FrameMode } from './bridge-host';
import { IN_APP_CONTAINER } from './generated/bridge';
import { PUSH_ASKABLE_STATUSES } from './generated/constants';

/*
 * On-site messaging: the rules that decide whether a matched message may be drawn on THIS page at THIS moment, and a
 * renderer the page can use instead of writing its own.
 *
 * The page rules read an address the same way the dashboard's preview does, so a message is drawn on the pages the
 * preview says it will be.
 */

export interface InAppUrlRule {
  op: 'equals' | 'not_equals' | 'contains' | 'not_contains' | 'starts_with' | 'ends_with' | 'regex' | 'not_regex' | 'path_equals' | 'has_query';
  value: string;
}

export type InAppSessionRule =
  | { kind: 'query_param'; key: string; value?: string }
  | { kind: 'visitor'; value: 'new' | 'returning' }
  | { kind: 'day'; days: number[] }
  | { kind: 'time'; from: string; to: string }
  | { kind: 'country'; countries: string[] }
  | { kind: 'device'; devices: ('mobile' | 'tablet' | 'desktop')[] };

export interface InAppDisplayRules {
  on?: 'load' | 'delay' | 'scroll' | 'exit_intent';
  delay_seconds?: number;
  scroll_percent?: number;
  url_rules?: InAppUrlRule[];
  url_match?: 'all' | 'any';
  contexts?: string[];
  session_rules?: InAppSessionRule[];
  priority?: number;
  auto_dismiss_seconds?: number;
  self_handled?: boolean;
  /** Shown only to people the page can still ask for push: see `pushAskableBlock`. */
  only_when_push_askable?: boolean;
}

/**
 * Why a message shown only to people who can still be asked for push is held back from this browser, or null.
 * `status` is the vocabulary every Treebars SDK shares — the browser's `Notification.permission` as
 * `WebPush.status()` names it — and which of its words can still be asked is `PUSH_ASKABLE_STATUSES`, one list shared
 * by all three SDKs. A browser asks once: after a refusal only its own settings bring the prompt back, and a site
 * with no service worker has nothing to ask with at all.
 */
export function pushAskableBlock(display: InAppDisplayRules | undefined, status: string): 'push_answered' | null {
  if (display?.only_when_push_askable !== true) return null;
  return (PUSH_ASKABLE_STATUSES as readonly string[]).includes(status) ? null : 'push_answered';
}

export interface InAppFormField {
  id: string;
  kind: 'text' | 'textarea' | 'email' | 'phone' | 'number' | 'date' | 'choice' | 'dropdown' | 'multi_choice' | 'rating' | 'nps';
  label: string;
  required?: boolean;
  options?: string[];
  /** What an empty box says before anything is typed or chosen. */
  placeholder?: string;
  save_as?: 'email' | 'phone';
  /** The answer kept as this trait, when the message declares it. */
  trait?: string;
}

export interface InAppForm {
  fields: InAppFormField[];
  submit_label?: string;
  thanks?: string;
}

export interface InAppSlide {
  image_url: string;
  /** What the image shows, for a screen reader. */
  image_alt?: string;
  title?: string;
  body?: string;
}

/** Why a matched message was not drawn — the reasons the campaign report counts (`in_app_failed`). */
export type InAppFailureReason =
  | 'max_per_day'
  | 'max_per_session'
  | 'trigger_cap'
  | 'min_gap'
  | 'max_displays'
  | 'context'
  | 'session_rule'
  | 'page_rule'
  | 'expired'
  | 'render_error'
  /** The page had nothing set to draw it: `setInAppRenderer(null)`, or a nudge on a page that draws its own messages. */
  | 'no_renderer'
  /** An HTML body whose frame the site's Content-Security-Policy refused, both the Treebars frame and the page's own. */
  | 'csp_blocked'
  /** A body over 64 KiB that could not be fetched, or whose hash did not match; or markup naming a stored file that is gone. */
  | 'asset_download'
  /** Shown only to people who can still be asked for push, and this person cannot. */
  | 'push_answered'
  /** A nudge that would have taken its edge's stack past its share of the window, and waits. */
  | 'no_room';

/**
 * What an `equals`, `not_equals`, `starts_with` or `ends_with` rule compares with: the page's address without its query
 * and fragment, unless the rule's own value names one. So "equals https://shop.example/pricing" still matches when a
 * campaign link adds `?utm_source=mail`, and "ends with /pricing" matches `/pricing#faq` — which is exactly the traffic
 * a message is for. A value with a `?` or a `#` in it is asking about them, and gets the whole address.
 *
 * `contains` and `not_contains` keep the whole address on purpose: "contains utm_campaign=spring" is how a rule asks
 * about one query value (`has_query` only asks whether a key is there), and stripping the query would quietly make it
 * match nothing. Regex rules read the whole address too; a pattern says what it wants.
 */
function urlRuleSubject(url: URL, value: string): string {
  return /[?#]/.test(value) ? url.href : `${url.protocol}//${url.host}${url.pathname}`;
}

export function urlRuleMatches(rule: InAppUrlRule, href: string): boolean {
  let url: URL;
  try {
    url = new URL(href);
  } catch {
    return false;
  }
  const whole = url.href;
  const address = urlRuleSubject(url, rule.value);
  switch (rule.op) {
    case 'equals':
      return address === rule.value || address.replace(/\/$/, '') === rule.value.replace(/\/$/, '');
    case 'not_equals':
      return !urlRuleMatches({ op: 'equals', value: rule.value }, href);
    case 'contains':
      return whole.includes(rule.value);
    case 'not_contains':
      return !whole.includes(rule.value);
    case 'starts_with':
      return address.startsWith(rule.value);
    case 'ends_with':
      return address.endsWith(rule.value);
    case 'regex':
    case 'not_regex':
      try {
        return new RegExp(rule.value).test(whole) === (rule.op === 'regex');
      } catch {
        return false;
      }
    case 'path_equals':
      return url.pathname.replace(/\/$/, '') === rule.value.replace(/\/$/, '');
    case 'has_query':
      return url.searchParams.has(rule.value);
    default:
      return false;
  }
}

/** The page rules together: every one, or any one, as the message says. None is every page. */
export function pageRulesMatch(display: InAppDisplayRules | undefined, href: string): boolean {
  const rules = display?.url_rules ?? [];
  if (rules.length === 0) return true;
  return display?.url_match === 'any' ? rules.some((rule) => urlRuleMatches(rule, href)) : rules.every((rule) => urlRuleMatches(rule, href));
}

/** What the browser knows of this session, for the session rules. */
export interface SessionFacts {
  href: string;
  /** True while this is the browser's first session. */
  isNewVisitor: boolean;
  now: Date;
  /** From the last sync (`geo.country`); absent when Treebars could not place the request, which fails a country rule. */
  country?: string;
  device: 'mobile' | 'tablet' | 'desktop';
}

function minutesOf(value: string): number {
  const [hours, minutes] = value.split(':').map(Number);
  return (hours ?? 0) * 60 + (minutes ?? 0);
}

/** Every session rule must hold. A time window that wraps midnight (22:00 to 02:00) is read as one. */
export function sessionRulesMatch(rules: InAppSessionRule[] | undefined, facts: SessionFacts): boolean {
  for (const rule of rules ?? []) {
    switch (rule.kind) {
      case 'query_param': {
        let params: URLSearchParams;
        try {
          params = new URL(facts.href).searchParams;
        } catch {
          return false;
        }
        if (!params.has(rule.key)) return false;
        if (rule.value !== undefined && rule.value !== '' && params.get(rule.key) !== rule.value) return false;
        break;
      }
      case 'visitor':
        if ((rule.value === 'new') !== facts.isNewVisitor) return false;
        break;
      case 'day':
        if (!rule.days.includes(facts.now.getDay())) return false;
        break;
      case 'time': {
        const now = facts.now.getHours() * 60 + facts.now.getMinutes();
        const from = minutesOf(rule.from);
        const to = minutesOf(rule.to);
        const inside = from <= to ? now >= from && now < to : now >= from || now < to;
        if (!inside) return false;
        break;
      }
      case 'country':
        if (!facts.country || !rule.countries.includes(facts.country)) return false;
        break;
      case 'device':
        if (!rule.devices.includes(facts.device)) return false;
        break;
      default:
        // A rule this build does not know is not a rule it can say holds.
        return false;
    }
  }
  return true;
}

/** Whether the app's current contexts admit the message: none named on it is anywhere; else one of them is set. */
export function contextsMatch(wanted: string[] | undefined, current: ReadonlySet<string>): boolean {
  if (!wanted || wanted.length === 0) return true;
  return wanted.some((context) => current.has(context));
}

/** A coarse class from the viewport, which is what a page's layout answers to. */
export function deviceClass(): 'mobile' | 'tablet' | 'desktop' {
  if (typeof window === 'undefined') return 'desktop';
  const width = window.innerWidth;
  return width < 768 ? 'mobile' : width < 1024 ? 'tablet' : 'desktop';
}

/** Highest priority first; absent is 5. The list is already newest first, and a stable sort keeps that for ties. */
export function byPriority(messages: InAppMessage[]): InAppMessage[] {
  const priority = (message: InAppMessage) => (message.content.in_app as { display?: InAppDisplayRules } | undefined)?.display?.priority ?? 5;
  return [...messages].sort((a, b) => priority(b) - priority(a));
}

/*
 * The built-in renderer, which is what draws a message unless the page sets its own. Plain DOM with inline styles in
 * a shadow root, so nothing of the page leaks in and nothing of ours leaks out. A page with its own design system
 * hands `setInAppRenderer` a function instead, and `null` to have nothing drawn.
 */

export interface BuiltInView {
  message: InAppMessage;
  tokens: InAppTokens | null;
  onClick: (button: InAppButton) => void;
  /** `auto` when it closed itself after `auto_dismiss_seconds`, which the page hears as its own event. */
  onDismiss: (reason?: 'auto') => void;
  onSubmit: (responses: Record<string, string | number>) => void;
  /**
   * On screen. A standard body is as soon as it is drawn; an HTML body only when its bridge says it is running, so
   * a message a site's policy stopped is never counted as shown and never spends a cap.
   */
  onShown?: (drawn?: { pushedDown?: number }) => void;
  /** An HTML body that could not be shown after all. */
  onFailed?: (reason: InAppFailureReason) => void;
  /**
   * An HTML body's `treebars` bridge: each call, answered by the SDK. `close` takes the message down without reporting
   * anything — the caller reports what it means.
   */
  bridge?: (method: string, args: unknown[], close: () => void) => unknown;
  /** The Treebars frame for a strict-CSP site, which frame to draw first this session, and a way to remember it. */
  frame?: { url: string | null; mode: FrameMode; remember: (mode: FrameMode) => void };
}

const DEFAULT_TOKENS: InAppTokens = {
  accent: '#1c1c1a',
  on_accent: '#ffffff',
  surface: '#ffffff',
  on_surface: '#1c1c1a',
  on_surface_muted: '#6b6b66',
  backdrop: 'rgba(0,0,0,.45)',
  radius: 14,
  font_family: '-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif',
  button_shape: 'rounded',
};

function el<K extends keyof HTMLElementTagNameMap>(tag: K, css: string, text?: string): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  node.style.cssText = css;
  if (text !== undefined) node.textContent = text;
  return node;
}

/** `02d 04:13:09`, or nothing once the moment has passed. */
export function countdownText(to: string, now = Date.now()): string {
  const left = Math.max(0, Date.parse(to) - now);
  if (!left) return '';
  const seconds = Math.floor(left / 1000);
  const days = Math.floor(seconds / 86_400);
  const pad = (value: number) => String(value).padStart(2, '0');
  const clock = `${pad(Math.floor((seconds % 86_400) / 3600))}:${pad(Math.floor((seconds % 3600) / 60))}:${pad(seconds % 60)}`;
  return days > 0 ? `${days}d ${clock}` : clock;
}

/**
 * Where a modal sits on the page: a popup grid — top, middle or bottom by start, center or end — and its own width,
 * clamped between the placement bounds and to the window less the gutters, so a 600-pixel
 * popup on a phone is the phone's width. `inset-inline-*` so a right-to-left page's start is its right. Absent, it is
 * the centred modal every host draws.
 */
function modalPlacement(placement: InAppContent['placement'] | undefined): string {
  const { modal, placement: bounds } = IN_APP_CONTAINER;
  const wanted = placement?.width ? Math.min(Math.max(placement.width, bounds.minWidth), bounds.maxWidth) : modal.maxWidth;
  const vertical = placement?.vertical ?? 'middle';
  const horizontal = placement?.horizontal ?? 'center';
  const y = vertical === 'top' ? `top:${modal.gutter}px` : vertical === 'bottom' ? `bottom:${modal.gutter}px` : 'top:50%';
  const x = horizontal === 'start' ? `inset-inline-start:${modal.gutter}px` : horizontal === 'end' ? `inset-inline-end:${modal.gutter}px` : 'left:50%';
  const shift = `translate(${horizontal === 'center' ? '-50%' : '0'},${vertical === 'middle' ? '-50%' : '0'})`;
  return `position:fixed;${y};${x};transform:${shift};width:min(calc(100% - ${modal.gutter * 2}px),${wanted}px);max-height:calc(100% - ${modal.gutter * 2}px)`;
}

/** What Tab can reach, in document order: a dialog's first stop is the first of these. */
const FOCUSABLE = 'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

/**
 * A modal's hold on the keyboard: the rest of the page `inert` while it is up, and focus put back
 * where it was when it goes. `inert` rather than a Tab listener, because it is the one trap that also holds across a
 * frame's edge — an HTML body's frame is an opaque origin the page cannot reach into — and because it takes the page out
 * of what a screen reader reads, which `aria-modal` alone only asks for. Only the elements this set are released; one
 * the site had made inert stays so. Returns the release.
 */
function holdFocus(host: HTMLElement): () => void {
  // Read by shape rather than `instanceof`: a page's own realm, or a test's DOM, need not share our HTMLElement.
  const before = (document.activeElement ?? null) as HTMLElement | null;
  const held: HTMLElement[] = [];
  for (const child of Array.from(document.body.children) as HTMLElement[]) {
    if (child === host || child.inert) continue;
    child.inert = true;
    held.push(child);
  }
  let released = false;
  return () => {
    if (released) return;
    released = true;
    for (const child of held) child.inert = false;
    if (before?.isConnected && typeof before.focus === 'function') before.focus({ preventScroll: true });
  };
}

/** The first control inside `root`, focused; nothing where it has none. */
function focusFirst(root: HTMLElement): void {
  const first = typeof root.querySelector === 'function' ? root.querySelector<HTMLElement>(FOCUSABLE) : null;
  if (typeof first?.focus === 'function') first.focus({ preventScroll: true });
}

/** Draws one message and returns a function that takes it down. Throws only when there is no document. */
export function renderBuiltIn(view: BuiltInView): () => void {
  const { message } = view;
  const tokens = { ...DEFAULT_TOKENS, ...(view.tokens ?? {}) };
  const content = message.content.in_app;
  if (inAppBodyMode(content) === 'html') return renderMarkup(view, tokens);
  const extras = content as (typeof content & { display?: InAppDisplayRules; form?: InAppForm; slides?: InAppSlide[]; countdown_to?: string; font_url?: string }) | undefined;
  // A nudge is HTML only; a typed one, should one arrive, is drawn as the bar it most resembles.
  const shape = inAppShape(content) === 'nudge' ? 'banner' : inAppShape(content);
  const radius = tokens.button_shape === 'pill' ? '999px' : tokens.button_shape === 'square' ? '0' : '8px';
  // Intervals and timeouts together: the two share one list of handles, so either clear function ends either.
  const timers: ReturnType<typeof setInterval>[] = [];

  const host = document.createElement('div');
  host.setAttribute('data-treebars-in-app', message.delivery_id);
  const root = host.attachShadow ? host.attachShadow({ mode: 'open' }) : host;
  if (extras?.font_url) {
    const link = document.createElement('link');
    link.rel = 'stylesheet';
    link.href = extras.font_url;
    // In the document, not the shadow root: a font face declared inside a shadow root is not loaded by every browser.
    document.head.appendChild(link);
  }

  let closed = false;
  let release = () => {};
  const close = () => {
    if (closed) return;
    closed = true;
    for (const timer of timers) clearInterval(timer);
    document.removeEventListener('keydown', onKey);
    host.remove();
    release();
  };
  const dismiss = (reason?: 'auto') => {
    close();
    view.onDismiss(reason);
  };
  // Escape closes what can be closed, as the markup renderer's does; a message that cannot be dismissed ignores it.
  const onKey = (event: KeyboardEvent) => {
    if (event.key === 'Escape' && content?.dismissible !== false) dismiss();
  };

  const backdrop = shape === 'banner' ? null : el('div', `position:fixed;inset:0;background:${tokens.backdrop};z-index:2147483646`);
  if (backdrop && content?.dismissible !== false) backdrop.addEventListener('click', () => dismiss());
  const position = content?.position ?? 'bottom';
  // A top banner that moves the page down is in the page's flow, the body's first child, rather than over it.
  const pushDown = shape === 'banner' && position === 'top' && content?.placement?.push_down === true;
  const boxCss =
    shape === 'banner'
      ? `${pushDown ? 'position:relative' : `position:fixed;left:0;right:0;${position === 'top' ? 'top:0' : 'bottom:0'}`};padding:14px 16px;display:flex;flex-wrap:wrap;gap:12px;align-items:center`
      : shape === 'fullscreen'
        ? 'position:fixed;inset:0;padding:32px 24px;overflow:auto;display:flex;flex-direction:column;justify-content:center;align-items:center'
        : `${modalPlacement(content?.placement)};overflow:auto;padding:24px;box-sizing:border-box;border-radius:${tokens.radius}px;box-shadow:0 12px 40px rgba(0,0,0,.25)`;
  const box = el('div', `${boxCss};z-index:2147483647;box-sizing:border-box;background:${tokens.surface};color:${tokens.on_surface};font:15px/1.5 ${tokens.font_family}`);
  box.setAttribute('role', 'dialog');
  box.setAttribute('aria-modal', shape === 'banner' ? 'false' : 'true');
  // A dialog with a name: a screen reader announces the title as it opens, rather than only "dialog".
  if (message.content.title) box.setAttribute('aria-label', message.content.title);
  /*
   * The message's own direction, when it has one. `dir` rather than `text-align`: it aligns the copy to its start, and
   * the button row's `flex-end` and the carousel follow it by themselves. The close control is placed by `right`, which
   * does not, so it moves to the other corner. Absent, nothing is set and the dialog inherits the page's direction. A
   * markup body is drawn in a frame, whose document inherits nothing from this one, so its direction goes on the markup
   * itself (`inAppHtmlWithDirection`) unless the author set their own.
   */
  const direction = content?.direction === 'rtl' || content?.direction === 'ltr' ? content.direction : undefined;
  if (direction) box.setAttribute('dir', direction);

  if (content?.dismissible !== false) {
    const x = el('button', `position:absolute;top:8px;${direction === 'rtl' ? 'left' : 'right'}:8px;border:0;background:none;font:20px/1 ${tokens.font_family};color:${tokens.on_surface_muted};cursor:pointer;padding:6px`, '×');
    x.type = 'button';
    x.setAttribute('aria-label', 'Close');
    x.addEventListener('click', () => dismiss());
    box.appendChild(x);
  }

  {
    const inner = el('div', shape === 'fullscreen' ? 'width:100%;max-width:560px' : shape === 'banner' ? 'flex:1;min-width:200px' : '');
    const slides = extras?.slides ?? [];
    if (slides.length > 0) inner.appendChild(carousel(slides, tokens, timers));
    else if (message.content.image_url && shape !== 'banner') {
      const image = el('img', `display:block;width:100%;border-radius:${Math.max(0, tokens.radius - 4)}px;margin:0 0 12px 0`);
      image.src = message.content.image_url;
      // What it shows, when the author said; otherwise decoration, which a screen reader skips.
      image.alt = content?.image_alt ?? '';
      inner.appendChild(image);
    }
    if (message.content.title) inner.appendChild(el('h2', 'margin:0 0 6px 0;font-size:18px;line-height:1.3', message.content.title));
    if (message.content.body) inner.appendChild(el('p', `margin:0 0 12px 0;color:${tokens.on_surface_muted}`, message.content.body));
    if (extras?.countdown_to) {
      const clock = el('div', 'font:600 22px/1.2 ui-monospace,SFMono-Regular,Menlo,monospace;margin:0 0 12px 0;letter-spacing:.02em');
      const tick = () => {
        clock.textContent = countdownText(extras.countdown_to!);
      };
      tick();
      timers.push(setInterval(tick, 1000));
      inner.appendChild(clock);
    }
    if (extras?.form?.fields?.length) {
      inner.appendChild(
        formView(extras.form, tokens, radius, (responses) => {
          view.onSubmit(responses);
          inner.replaceChildren(el('p', 'margin:12px 0', extras.form?.thanks || 'Thank you.'));
          timers.push(setTimeout(close, 2500));
        }),
      );
    }
    // A store review is an app's: a browser has no store to ask, so the button is not drawn at all
    // rather than drawn to do nothing.
    const buttons = (content?.buttons ?? []).filter((button) => button.action !== 'store_review');
    if (buttons.length > 0) {
      const row = el('div', 'display:flex;gap:8px;flex-wrap:wrap;justify-content:flex-end;margin-top:4px');
      buttons.forEach((button, index) => {
        const primary = index === buttons.length - 1;
        const node = el(
          'button',
          `font:inherit;padding:9px 16px;border-radius:${radius};cursor:pointer;${primary ? `border:0;background:${tokens.accent};color:${tokens.on_accent}` : `border:1px solid ${tokens.on_surface_muted};background:transparent;color:${tokens.on_surface}`}`,
          button.label,
        );
        node.type = 'button';
        node.addEventListener('click', () => {
          view.onClick(button);
          // A button that records something or hands the app keys leaves the message up only if it was a dismiss.
          close();
          if (button.action === 'dismiss') view.onDismiss();
        });
        row.appendChild(node);
      });
      inner.appendChild(row);
    }
    box.appendChild(inner);
  }

  if (backdrop) root.appendChild(backdrop);
  root.appendChild(box);
  if (pushDown) document.body.insertBefore(host, document.body.firstChild);
  else document.body.appendChild(host);
  document.addEventListener('keydown', onKey);
  // A modal takes the keyboard: the page behind is inert and focus starts on the message's first control. A banner
  // interrupts nothing and leaves focus where the person had it.
  if (shape !== 'banner') {
    release = holdFocus(host);
    focusFirst(box);
  }

  const auto = extras?.display?.auto_dismiss_seconds;
  if (auto) timers.push(setTimeout(() => dismiss('auto'), auto * 1000));
  view.onShown?.(pushDown && typeof box.getBoundingClientRect === 'function' ? { pushedDown: Math.round(box.getBoundingClientRect().height) } : undefined);
  return close;
}

/**
 * The stack a nudge joins: one fixed column per edge, in the light DOM so every nudge's own shadow root sits inside it,
 * and below a modal's backdrop — a modal may be drawn over nudges. The column lets every touch through; only a nudge
 * itself takes one, so the page under the stack stays usable.
 */
function nudgeStack(edge: 'top' | 'bottom', corner: 'start' | 'end' | null = null): HTMLElement {
  // One stack per edge, and per corner: a corner's nudges stack in that corner, as cards rather than a strip.
  const name = corner ? `${edge}-${corner}` : edge;
  const found = document.querySelector<HTMLElement>(`[data-treebars-nudges="${name}"]`);
  if (found) return found;
  const { modal, placement } = IN_APP_CONTAINER;
  const across = corner
    ? `inset-inline-${corner}:${modal.gutter}px;width:min(calc(100% - ${modal.gutter * 2}px),${placement.cornerWidth}px);gap:8px;${edge}:${modal.gutter}px`
    : `left:0;right:0;${edge}:0`;
  // Inside the safe area on a phone's browser: a nudge is a small card, not a bar that runs under the status bar.
  const stack = el('div', `position:fixed;${across};padding-${edge}:env(safe-area-inset-${edge},0px);z-index:2147483645;display:flex;flex-direction:${edge === 'top' ? 'column' : 'column-reverse'};pointer-events:none`);
  stack.setAttribute('data-treebars-nudges', name);
  document.body.appendChild(stack);
  return stack;
}

/** How much of the window an edge's nudges already take, beside the one being revealed. */
function stackHeight(stack: HTMLElement, besides: HTMLElement): number {
  let total = 0;
  for (const child of Array.from(stack.children)) if (child !== besides) total += child.getBoundingClientRect().height;
  return total;
}

/**
 * An HTML body: the markup in a sandboxed frame with the `treebars` bridge, sized by the container spec
 * (`IN_APP_CONTAINER`), and nothing of the SDK's drawn over it — no close control, no padding. The markup carries its
 * own way out (the editor warns when it does not); Escape and a click on the dim still close a dismissible one, so a
 * template whose script broke cannot trap somebody on a site.
 *
 * Hidden until the bridge says it is running, and a fitted shape until its height is known: what appears is the message
 * at its size, never a blank box that fills in or jumps.
 */
function renderMarkup(view: BuiltInView, tokens: InAppTokens): () => void {
  const { message } = view;
  const content = message.content.in_app;
  const shape = inAppShape(content);
  const nudge = shape === 'nudge';
  const edge: 'top' | 'bottom' = content?.position === 'top' ? 'top' : 'bottom';
  // A nudge in a corner on a device wide enough for one; on a phone every nudge is a full-width strip.
  const corner: 'start' | 'end' | null = nudge && deviceClass() !== 'mobile' && (content?.placement?.horizontal === 'start' || content?.placement?.horizontal === 'end') ? content.placement.horizontal : null;
  const pushDown = shape === 'banner' && content?.position === 'top' && content?.placement?.push_down === true;
  const transparent = shape === 'fullscreen' && content?.transparent === true;
  const dismissible = content?.dismissible !== false;
  const direction = content?.direction === 'rtl' || content?.direction === 'ltr' ? content.direction : undefined;
  const timers: ReturnType<typeof setTimeout>[] = [];

  const host = document.createElement('div');
  host.setAttribute('data-treebars-in-app', message.delivery_id);
  const root = host.attachShadow ? host.attachShadow({ mode: 'open' }) : host;

  const backdrop = shape === 'banner' || nudge || transparent ? null : el('div', `position:fixed;inset:0;background:${tokens.backdrop};z-index:2147483646;visibility:hidden`);
  const { banner } = IN_APP_CONTAINER;
  const boxCss = nudge
    ? // In the stack's flow: as tall as the content up to its share of the window, and the one thing here that takes a touch.
      `position:relative;height:0;max-height:${IN_APP_CONTAINER.nudge.maxHeightShare * 100}vh;background:${tokens.surface};box-shadow:0 4px 24px rgba(0,0,0,.18);pointer-events:auto${corner ? `;border-radius:${tokens.radius}px` : ''}`
    : shape === 'fullscreen'
      ? `position:fixed;inset:0;background:${transparent ? 'transparent' : tokens.surface}`
      : shape === 'banner'
        ? `${pushDown ? 'position:relative;width:100%' : `position:fixed;left:0;right:0;${content?.position === 'top' ? 'top:0' : 'bottom:0'}`};height:0;max-height:${banner.maxHeightShare * 100}vh;background:${tokens.surface};box-shadow:0 4px 24px rgba(0,0,0,.18)`
        : `${modalPlacement(content?.placement)};height:0;border-radius:${tokens.radius}px;background:${tokens.surface};box-shadow:0 12px 40px rgba(0,0,0,.25)`;
  const box = el('div', `${boxCss};z-index:2147483647;overflow:hidden;visibility:hidden`);
  box.setAttribute('role', 'dialog');
  box.setAttribute('aria-modal', shape === 'banner' || nudge ? 'false' : 'true');
  if (message.content.title) box.setAttribute('aria-label', message.content.title);

  let closed = false;
  let shown = false;
  let working: FrameMode | null = null;
  let release = () => {};
  const close = () => {
    if (closed) return;
    closed = true;
    for (const timer of timers) clearTimeout(timer);
    document.removeEventListener('keydown', onKey);
    markup.destroy();
    const stack = host.parentElement;
    host.remove();
    // The last nudge at an edge takes its empty stack with it.
    if (nudge && stack && stack.children.length === 0) stack.remove();
    release();
  };
  const dismiss = (reason?: 'auto') => {
    if (closed) return;
    close();
    view.onDismiss(reason);
  };
  // Escape is for what interrupts: a nudge interrupts nothing, and closes by its own control. Pressed inside the frame it
  // never reaches this document, so the shim forwards it (`_key`) and it arrives here as the same key.
  const escape = (key: string) => {
    if (key === 'Escape' && shown && dismissible && !nudge) dismiss();
  };
  const onKey = (event: KeyboardEvent) => escape(event.key);
  if (backdrop && dismissible) backdrop.addEventListener('click', () => dismiss());

  const reveal = () => {
    if (shown || closed) return;
    /*
     * A nudge that would take its edge past its share of the window waits instead: taken down unspent, and asked again
     * at the next event — by when another may have closed. Three at a fifth each would be most of a phone.
     */
    if (nudge && stackHeight(nudgeStack(edge, corner), host) + box.getBoundingClientRect().height > IN_APP_CONTAINER.nudge.stackShare * window.innerHeight) {
      close();
      view.onFailed?.('no_room');
      return;
    }
    shown = true;
    box.style.visibility = 'visible';
    if (backdrop) backdrop.style.visibility = 'visible';
    // A modal takes the keyboard once it is on screen: the page behind inert, and focus into the message, where the
    // shim puts it on the first control. A banner and a nudge leave focus where it was.
    if (box.getAttribute('aria-modal') === 'true') {
      release = holdFocus(host);
      markup.focus();
    }
    if (working) view.frame?.remember(working);
    view.onShown?.(pushDown ? { pushedDown: Math.round(box.getBoundingClientRect().height) } : undefined);
    const auto = content?.display?.auto_dismiss_seconds;
    if (auto) timers.push(setTimeout(() => dismiss('auto'), auto * 1000));
  };

  const markup = hostMarkup({
    html: content?.html ?? '',
    direction,
    title: message.content.title || 'Message',
    parent: box,
    frameUrl: view.frame?.url ?? null,
    mode: view.frame?.mode ?? 'srcdoc',
    handle: (method, args) => (view.bridge ? view.bridge(method, args, close) : { ok: false, reason: 'unsupported' }),
    onReady: (mode) => {
      working = mode;
      if (shape === 'fullscreen') reveal();
      // A page that never reports its height is shown at the cap rather than never.
      else timers.push(setTimeout(() => {
        if (box.style.height === '0px') box.style.height = '100%';
        reveal();
      }, 1000));
    },
    onHeight: (height) => {
      if (shape === 'fullscreen') return;
      box.style.height = `${Math.ceil(height)}px`;
      if (working) reveal();
    },
    onBlocked: () => {
      close();
      console.warn(
        `[treebars] An HTML in-app message was not shown: this page's Content-Security-Policy refused its frame. ${view.frame?.url ? `Allow it with frame-src ${new URL(view.frame.url, location.href).origin}.` : ''}`.trim(),
      );
      view.onFailed?.('csp_blocked');
    },
    onGone: () => dismiss(),
    onKey: escape,
    device: deviceClass(),
  });

  if (backdrop) root.appendChild(backdrop);
  root.appendChild(box);
  // A nudge joins its edge's stack, the newest nearest the middle of the screen; everything else sits on the body.
  if (nudge) nudgeStack(edge, corner).appendChild(host);
  else if (pushDown) document.body.insertBefore(host, document.body.firstChild);
  else document.body.appendChild(host);
  document.addEventListener('keydown', onKey);
  return close;
}

function carousel(slides: InAppSlide[], tokens: InAppTokens, timers: ReturnType<typeof setInterval>[]): HTMLElement {
  const wrap = el('div', 'position:relative;margin:0 0 12px 0');
  const image = el('img', `display:block;width:100%;border-radius:${Math.max(0, tokens.radius - 4)}px`);
  image.alt = '';
  const caption = el('div', 'margin-top:8px');
  const dots = el('div', 'display:flex;gap:6px;justify-content:center;margin-top:8px');
  let at = 0;
  const show = (index: number) => {
    at = (index + slides.length) % slides.length;
    const slide = slides[at]!;
    image.src = slide.image_url;
    image.alt = slide.image_alt ?? '';
    caption.replaceChildren();
    if (slide.title) caption.appendChild(el('strong', 'display:block', slide.title));
    if (slide.body) caption.appendChild(el('span', `color:${tokens.on_surface_muted}`, slide.body));
    dots.querySelectorAll('span').forEach((dot, i) => {
      (dot as HTMLElement).style.opacity = i === at ? '1' : '.3';
    });
  };
  for (let i = 0; i < slides.length; i += 1) dots.appendChild(el('span', `width:7px;height:7px;border-radius:50%;background:${tokens.on_surface}`));
  const arrow = (label: string, side: 'left' | 'right', step: number) => {
    const node = el('button', `position:absolute;top:40%;${side}:6px;border:0;border-radius:50%;width:30px;height:30px;background:rgba(0,0,0,.45);color:#fff;cursor:pointer;font:16px/1 sans-serif`, label);
    node.type = 'button';
    node.setAttribute('aria-label', step > 0 ? 'Next' : 'Previous');
    node.addEventListener('click', () => show(at + step));
    return node;
  };
  wrap.append(image, arrow('‹', 'left', -1), arrow('›', 'right', 1), caption, dots);
  show(0);
  // Moves on by itself every five seconds, as a carousel does; a click on an arrow is still one step.
  timers.push(setInterval(() => show(at + 1), 5000));
  return wrap;
}

/** The input each typed kind draws: the browser's own keyboard, picker and checks come with the type. */
const INPUT_TYPES: Partial<Record<InAppFormField['kind'], string>> = { email: 'email', phone: 'tel', number: 'number', date: 'date' };

/** A calendar day as a date input writes it, and one that exists: `2026-02-30` is not a day. */
export function isDay(value: string): boolean {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!match) return false;
  const at = new Date(Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3])));
  return at.getUTCFullYear() === Number(match[1]) && at.getUTCMonth() === Number(match[2]) - 1 && at.getUTCDate() === Number(match[3]);
}

function formView(form: InAppForm, tokens: InAppTokens, radius: string, submit: (responses: Record<string, string | number>) => void): HTMLElement {
  const node = el('form', 'display:flex;flex-direction:column;gap:12px;margin:0 0 12px 0');
  node.noValidate = true;
  const values: Record<string, string | number> = {};
  const inputCss = `font:inherit;padding:8px 10px;border-radius:8px;border:1px solid ${tokens.on_surface_muted};background:transparent;color:${tokens.on_surface};width:100%;box-sizing:border-box`;
  for (const field of form.fields) {
    const label = el('label', 'display:flex;flex-direction:column;gap:6px;font-weight:500', `${field.label}${field.required ? ' *' : ''}`);
    if (field.kind === 'rating' || field.kind === 'nps') {
      const scale = field.kind === 'nps' ? Array.from({ length: 11 }, (_, i) => i) : [1, 2, 3, 4, 5];
      const row = el('div', 'display:flex;gap:4px;flex-wrap:wrap');
      const cells: HTMLButtonElement[] = [];
      for (const score of scale) {
        const cell = el('button', `font:inherit;min-width:32px;padding:6px;border-radius:${radius};border:1px solid ${tokens.on_surface_muted};background:transparent;color:${tokens.on_surface};cursor:pointer`, field.kind === 'rating' ? '★' : String(score));
        cell.type = 'button';
        cell.setAttribute('aria-label', String(score));
        cell.addEventListener('click', () => {
          values[field.id] = score;
          cells.forEach((other, i) => {
            const on = field.kind === 'rating' ? scale[i]! <= score : scale[i] === score;
            other.style.background = on ? tokens.accent : 'transparent';
            other.style.color = on ? tokens.on_accent : tokens.on_surface;
          });
        });
        cells.push(cell);
        row.appendChild(cell);
      }
      label.appendChild(row);
    } else if (field.kind === 'choice' || field.kind === 'dropdown') {
      // One of a list is a select on the web; a dropdown is the same control with a longer list, and
      // its empty first line says the placeholder where there is one.
      const select = el('select', inputCss);
      select.appendChild(new Option(field.placeholder ?? '', ''));
      for (const option of field.options ?? []) select.appendChild(new Option(option, option));
      select.addEventListener('change', () => {
        values[field.id] = select.value;
      });
      label.appendChild(select);
    } else if (field.kind === 'multi_choice') {
      // Several choices travel as one answer, the picks joined by commas — as a markup form's ticked boxes do.
      const group = el('div', 'display:flex;flex-direction:column;gap:4px;font-weight:400');
      const picked = new Set<string>();
      for (const option of field.options ?? []) {
        const row = el('label', 'display:flex;gap:8px;align-items:center');
        const box = el('input', `accent-color:${tokens.accent}`);
        box.type = 'checkbox';
        box.value = option;
        box.addEventListener('change', () => {
          if (box.checked) picked.add(option);
          else picked.delete(option);
          // In the author's order, whatever order they were ticked in.
          values[field.id] = (field.options ?? []).filter((one) => picked.has(one)).join(',');
        });
        row.append(box, el('span', '', option));
        group.appendChild(row);
      }
      label.appendChild(group);
    } else {
      const input = field.kind === 'textarea' ? el('textarea', `${inputCss};min-height:72px`) : el('input', inputCss);
      if (input instanceof HTMLInputElement) input.type = INPUT_TYPES[field.kind] ?? 'text';
      if (field.placeholder) input.setAttribute('placeholder', field.placeholder);
      input.addEventListener('input', () => {
        const text = input.value.trim();
        // A number is sent as a number, so the export and a trait keep it as one; a date as the input writes it, YYYY-MM-DD.
        values[field.id] = field.kind === 'number' && text !== '' && Number.isFinite(Number(text)) ? Number(text) : text;
      });
      label.appendChild(input);
    }
    node.appendChild(label);
  }
  const problem = el('p', 'margin:0;color:#b42318;font-size:13px');
  const send = el('button', `font:inherit;padding:9px 16px;border-radius:${radius};border:0;background:${tokens.accent};color:${tokens.on_accent};cursor:pointer;align-self:flex-end`, form.submit_label || 'Send');
  send.type = 'submit';
  node.append(problem, send);
  node.addEventListener('submit', (event) => {
    event.preventDefault();
    const missing = form.fields.find((field) => field.required && (values[field.id] === undefined || values[field.id] === ''));
    if (missing) {
      problem.textContent = `“${missing.label}” needs an answer`;
      return;
    }
    const email = form.fields.find((field) => field.kind === 'email' && values[field.id]);
    if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(String(values[email.id]))) {
      problem.textContent = 'That email address does not look right';
      return;
    }
    const number = form.fields.find((field) => field.kind === 'number' && typeof values[field.id] === 'string' && values[field.id] !== '');
    if (number) {
      problem.textContent = `“${number.label}” needs a number`;
      return;
    }
    const date = form.fields.find((field) => field.kind === 'date' && values[field.id] && !isDay(String(values[field.id])));
    if (date) {
      problem.textContent = `“${date.label}” needs a date`;
      return;
    }
    submit({ ...values });
  });
  return node;
}
