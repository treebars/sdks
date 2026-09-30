import { safeGet, safeRemove, safeSet } from './storage';
import { FNV_OFFSET_BASIS, FNV_PRIME } from './generated/constants';
import { sessionRulesMatch, urlRuleMatches, type InAppSessionRule, type InAppUrlRule } from './on-site';

/*
 * Web personalization on the page: which experiences this visitor sees here, which variation of each, and the page
 * changed to match.
 *
 * The deciding here gives the same answers as Treebars' server-side decide API. The hash in particular must be the
 * same in both, or a site that decides on its server and then loads this SDK would see a visitor switch variation
 * between the HTML and the first paint. `test/experiences.test.ts` pins it to the server's values.
 */

export type WebChange =
  | { op: 'text'; selector: string; value: string }
  | { op: 'html'; selector: string; value: string }
  | { op: 'hide'; selector: string }
  | { op: 'remove'; selector: string }
  | { op: 'style'; selector: string; property: string; value: string }
  | { op: 'attr'; selector: string; name: string; value: string }
  | { op: 'move'; selector: string; target: string; position: 'before' | 'after' }
  | { op: 'insert'; selector: string; position: 'before' | 'after' | 'prepend' | 'append'; html: string; widget?: string }
  | { op: 'track_click'; selector: string; name: string };

export interface WebVariation {
  id: string;
  name?: string;
  weight: number;
  control?: boolean;
  changes: WebChange[];
  redirect_url?: string;
}

export type WebTargetRule =
  | InAppSessionRule
  | { kind: 'os'; values: string[] }
  | { kind: 'browser'; values: string[] }
  | { kind: 'identified'; value: boolean };

export interface WebExperienceWire {
  id: string;
  kind: 'visual' | 'split_url';
  url_rules: InAppUrlRule[];
  url_match: 'all' | 'any';
  rules: WebTargetRule[];
  variations: WebVariation[];
  goal_event: string | null;
  priority: number;
}

export interface Decision {
  experience_id: string;
  variation_id: string;
  control: boolean;
  changes: WebChange[];
  redirect_url?: string;
}

export interface Visitor {
  id: string;
  href: string;
  isNewVisitor: boolean;
  identified: boolean;
  now: Date;
  country?: string;
  /** The device rule is answered from this too — see `userAgentFacts`. */
  userAgent: string;
  /** `navigator.maxTouchPoints`, which is how an iPad's Macintosh User-Agent is told from a Mac's (`userAgentFacts`). */
  maxTouchPoints?: number;
}

export function fnv1a(text: string): number {
  let hash = FNV_OFFSET_BASIS;
  for (let i = 0; i < text.length; i += 1) {
    hash ^= text.charCodeAt(i);
    hash = Math.imul(hash, FNV_PRIME) >>> 0;
  }
  return hash >>> 0;
}

export function assignVariation(experienceId: string, visitorId: string, variations: Pick<WebVariation, 'id' | 'weight'>[]): string | null {
  const bucket = fnv1a(`${experienceId}:${visitorId}`) % 100;
  let edge = 0;
  for (const variation of variations) {
    edge += variation.weight;
    if (bucket < edge) return variation.id;
  }
  return null;
}

/**
 * The operating system, browser and kind of device a User-Agent names — the same answer the server-side decide API
 * gives for the same User-Agent. The device is read from the User-Agent here too, not from the viewport the in-app
 * rules use, because the server-side decide API has no viewport: reading the viewport would let a narrow desktop
 * window or a phone in desktop mode match a device rule on one decider and not the other, and the two deciders
 * agreeing is the whole reason the hash is shared.
 *
 * One exception: iPadOS Safari sends a Macintosh User-Agent by default, so the string alone cannot tell an iPad from
 * a Mac and would match every iPad to a `desktop` rule and never a `tablet` one. A Mac has no touch screen, so a
 * Macintosh User-Agent with more than one touch point is an iPad — `ios` and `tablet`. `maxTouchPoints` is
 * `navigator.maxTouchPoints`; absent, the answer is the User-Agent's. The server-side decide API accepts the same
 * count as `touch_points` in its body; a site's server that does not pass it on treats an iPad as a Mac, and the two
 * deciders then disagree on the device and the operating system (never on the variation, which is the hash).
 */
export function userAgentFacts(ua: string, maxTouchPoints?: number): { os: string; browser: string; device: 'mobile' | 'tablet' | 'desktop' } {
  const os = /iPhone|iPad|iPod/.test(ua) ? 'ios' : /Android/.test(ua) ? 'android' : /Windows/.test(ua) ? 'windows' : /Mac OS X|Macintosh/.test(ua) ? 'macos' : /Linux/.test(ua) ? 'linux' : 'other';
  const browser = /Edg\//.test(ua) ? 'edge' : /Firefox\/|FxiOS/.test(ua) ? 'firefox' : /Chrome\/|CriOS/.test(ua) ? 'chrome' : /Safari\//.test(ua) ? 'safari' : 'other';
  const device = /iPad|Tablet/.test(ua) || (/Android/.test(ua) && !/Mobile/.test(ua)) ? 'tablet' : /Mobi|iPhone|Android/.test(ua) ? 'mobile' : 'desktop';
  if (os === 'macos' && /Macintosh/.test(ua) && (maxTouchPoints ?? 0) > 1) return { os: 'ios', browser, device: 'tablet' };
  return { os, browser, device };
}

function targetRulesMatch(rules: WebTargetRule[], visitor: Visitor): boolean {
  const agent = userAgentFacts(visitor.userAgent, visitor.maxTouchPoints);
  const session: InAppSessionRule[] = [];
  for (const rule of rules) {
    if (rule.kind === 'os') {
      if (!rule.values.includes(agent.os)) return false;
    } else if (rule.kind === 'browser') {
      if (!rule.values.includes(agent.browser)) return false;
    } else if (rule.kind === 'identified') {
      if (rule.value !== visitor.identified) return false;
    } else session.push(rule);
  }
  return sessionRulesMatch(session, { href: visitor.href, isNewVisitor: visitor.isNewVisitor, now: visitor.now, country: visitor.country, device: agent.device });
}

function pageMatches(experience: Pick<WebExperienceWire, 'url_rules' | 'url_match'>, href: string): boolean {
  const rules = experience.url_rules ?? [];
  if (rules.length === 0) return false;
  return experience.url_match === 'any' ? rules.some((rule) => urlRuleMatches(rule, href)) : rules.every((rule) => urlRuleMatches(rule, href));
}

/** The experiences this visitor sees on this page, lowest priority first so the highest's changes land last. */
export function decideExperiences(experiences: WebExperienceWire[], visitor: Visitor): Decision[] {
  return [...experiences]
    .sort((a, b) => a.priority - b.priority)
    .flatMap((experience) => {
      if (!pageMatches(experience, visitor.href) || !targetRulesMatch(experience.rules ?? [], visitor)) return [];
      const id = assignVariation(experience.id, visitor.id, experience.variations);
      const variation = experience.variations.find((one) => one.id === id);
      if (!variation) return [];
      return [
        {
          experience_id: experience.id,
          variation_id: variation.id,
          control: variation.control === true,
          changes: variation.control ? [] : variation.changes,
          ...(experience.kind === 'split_url' && !variation.control && variation.redirect_url ? { redirect_url: variation.redirect_url } : {}),
        },
      ];
    });
}

/*
 * What "nothing runs" means on the page. The SDK enforces these rules itself on every change it applies — the visual
 * editor hands changes straight to `applyChange` — and only on the page are the markup's attributes decoded and its
 * elements known.
 *
 * A regex for the literal text `javascript:` is not enough, because the URL parser does not read text that way: it
 * drops tab, CR and LF from anywhere in an address and C0 controls and spaces from its ends, so a scheme with a tab
 * inside the word still navigates to script. `valueRuns` asks the parser's own question.
 */

/** Schemes that run what follows them when followed. */
const RUNNING_SCHEMES = new Set(['javascript:', 'vbscript:']);

/** Whether an attribute value, read as an address the way the browser reads one, would run script when followed. */
export function valueRuns(value: string): boolean {
  const address = value.replace(/[\t\n\r]/g, '').replace(/^[\u0000-\u0020]+/, '');
  const scheme = /^([a-z][a-z0-9+.-]*):/i.exec(address)?.[1];
  return scheme !== undefined && RUNNING_SCHEMES.has(`${scheme.toLowerCase()}:`);
}

/**
 * Attributes a change may never set, and inserted markup never keeps: every inline handler, `srcdoc`, and everything
 * that makes or re-points a form — a form's `action`, and `form=`, `formaction` and the other form-associated
 * attributes, which attach an inserted button to the page's own form by id and send what was typed into it elsewhere.
 * Forms are not part of web experiences at all.
 */
export function attributeUnsafe(name: string): boolean {
  return /^(on|srcdoc$|action$|form$|formaction$|formenctype$|formmethod$|formnovalidate$|formtarget$)/i.test(name);
}

/**
 * Elements that run, load, or re-point the page: stripped from inserted markup, and never given content or attributes
 * by a change (`changeWritesInto`).
 *
 * A target, too, because an element already on the page can be made to run. An empty `<script>` is not "started"
 * until it has content, so a `text` change on one executes that text; `<base>` re-points every relative address on the
 * page, scripts included; the SVG animation elements can set an `href` to an address no attribute check ever sees.
 * Compared on `localName` in lower case: SVG's names are camel-cased, and a selector would match them case-sensitively.
 *
 * `form` is here because forms are not part of web experiences: an inserted one is stripped with everything in
 * it, and a page's own form is never written into — no `action` repointed, no markup inserted at its start or end, and
 * nothing written anywhere inside it either (`writesInsideForbidden`) — while it can still be hidden, restyled, moved or
 * removed like any other element.
 */
const FORBIDDEN_ELEMENTS = new Set(['script', 'iframe', 'frame', 'frameset', 'object', 'embed', 'applet', 'base', 'meta', 'link', 'style', 'animate', 'set', 'animatetransform', 'animatemotion', 'noscript', 'form']);

export function elementForbidden(localName: string): boolean {
  return FORBIDDEN_ELEMENTS.has(localName.toLowerCase());
}

/** Markup as the page will hold it: running elements, inline handlers and running addresses taken out. */
export function cleanMarkup(html: string): DocumentFragment {
  const template = document.createElement('template');
  template.innerHTML = html;
  for (const node of [...template.content.querySelectorAll('*')]) {
    if (elementForbidden(node.localName)) {
      node.remove();
      continue;
    }
    for (const attribute of [...node.attributes]) {
      if (attributeUnsafe(attribute.name) || valueRuns(attribute.value)) node.removeAttribute(attribute.name);
    }
  }
  return template.content;
}

/**
 * Whether a change puts something INTO its element — content, markup or an attribute — which is the only way a change
 * can make an element that runs or loads do so. Only these are refused on an `elementForbidden` target.
 *
 * The other ops stay allowed there, because they are the commonest reason to target an iframe: hiding a chat widget
 * or a video embed, removing a promo frame, putting a banner beside one. Hide, remove and style set nothing the
 * element reads; a move re-inserts the element the page already had, and a script that has run does not run again;
 * an insert before or after one adds a sibling built by `cleanMarkup`.
 */
export function changeWritesInto(change: WebChange): boolean {
  switch (change.op) {
    case 'text':
    case 'html':
    case 'attr':
      return true;
    case 'insert':
      return change.position === 'prepend' || change.position === 'append';
    default:
      return false;
  }
}

const APPLIED = 'data-treebars-applied';

/**
 * What marks a change as done on an element: the SLOT it writes, and the value it wrote there, hashed.
 *
 * Neither the op and selector alone nor the whole change would do. Keyed by op and selector, a second change of the
 * same kind to one element — a colour then a size, two widgets after one heading, two moves — would be taken for the
 * first and skipped, and across experiences the LOWER priority's change would land and the higher one's be skipped,
 * the reverse of the order `decideExperiences` sorts them into. Keyed by the whole change, a change identical to one
 * EARLIER in the list would be skipped, so text A → B → A would end on B, and two experiences carrying the same value
 * (low "Sale", middle "New", high "Sale") would end on the middle one.
 *
 * So the marker is per slot — what one element can hold only one of at a time. `text` and `html` share one, since each
 * replaces the element's content; each style property is its own, as is each attribute; a move is one (an element is
 * in one place). The value written is kept beside the slot, and a change is skipped only when its slot already holds
 * exactly its value — which is the whole point of the marker: a change retried as the page redraws, or re-run on a
 * single-page app's next page, is not applied twice. A later change to the same slot with a different value always
 * lands, even when that value was already applied and replaced.
 *
 * Hide and remove have one value each. An insert is the exception: nothing is replaced, so every distinct insert is its
 * own slot, and the same insert twice is still one widget, not two.
 */
export function changeKey(change: WebChange): string {
  return `${changeSlot(change)}=${fnv1a(JSON.stringify(change)).toString(36)}`;
}

function changeSlot(change: WebChange): string {
  switch (change.op) {
    case 'text':
    case 'html':
      return 'content';
    case 'style':
      return `style:${change.property.toLowerCase()}`;
    case 'attr':
      return `attr:${change.name.toLowerCase()}`;
    case 'insert':
      return `insert:${fnv1a(JSON.stringify(change)).toString(36)}`;
    default:
      return change.op;
  }
}

/**
 * Whether a change would put something inside an element that runs or loads — the element itself for a change that
 * writes into it (`changeWritesInto`), or any element ABOVE where it writes.
 *
 * Checking the target alone is not enough to keep a page's own form from being written into: an `html` or `insert` on
 * a `div` or a `fieldset` inside `form#checkout` adds an `<input name=…>` or a `<button>`, which then belongs to that
 * form and is submitted with it — no `form=` attribute needed. The same holds for an `attr` on a field inside it: a
 * `name` or a `value` is what is submitted. So, inside one:
 *
 * - `html`, `attr` and an insert at the start or end write into the element, so the element and everything above it
 *   are asked;
 * - an insert before or after writes into the element's PARENT, so only what is above the element is asked — the
 *   element itself being an iframe is still fine, as `changeWritesInto` says;
 * - a move puts the element beside its destination, so what is above the destination is asked;
 * - `text` is refused inside a form only on what a form submits as text — a `textarea`'s value, an `option`'s, a
 *   `select`'s options. Everywhere else in a form it is copy: rewording "Add to cart", which on most shops sits inside
 *   `<form action="/cart/add">`, is the commonest test there is, and refusing it would skip that change on most shops.
 *   Text cannot add a control.
 *
 * Hide, style and remove still work on everything, a form's own fields included: taking something away or restyling
 * it collects nothing.
 */
export function writesInsideForbidden(change: WebChange, element: Element, root: ParentNode = document): boolean {
  switch (change.op) {
    case 'text':
      return elementForbidden(element.localName) || ancestorForbidden(element, !FORM_TEXT_VALUES.has(element.localName.toLowerCase()));
    case 'html':
    case 'attr':
    case 'insert':
      return (changeWritesInto(change) && elementForbidden(element.localName)) || ancestorForbidden(element);
    case 'move': {
      let destination: Element | null = null;
      try {
        destination = root.querySelector(change.target);
      } catch {
        return false;
      }
      return destination !== null && ancestorForbidden(destination);
    }
    default:
      return false;
  }
}

/** The elements whose text a form submits (`writesInsideForbidden`). */
const FORM_TEXT_VALUES = new Set(['textarea', 'option', 'select']);

/**
 * Whether anything above an element is one `elementForbidden` names — a `form` aside, when `exceptForms` says so.
 * Walked by hand rather than with `closest`: SVG's names are camel-cased, and a selector matches them case-sensitively.
 */
function ancestorForbidden(element: Element, exceptForms = false): boolean {
  for (let node = element.parentElement; node; node = node.parentElement) {
    if (exceptForms && node.localName.toLowerCase() === 'form') continue;
    if (elementForbidden(node.localName)) return true;
  }
  return false;
}

/**
 * One change on the page. Returns whether its element was there — a change to an element a script has not drawn yet is
 * tried again as the page changes (see `applyChanges`). Each change is applied to an element once per value
 * (`changeKey`), and never writes into, or anywhere inside, an element that runs or loads (`writesInsideForbidden`).
 */
export function applyChange(change: WebChange, root: ParentNode = document): boolean {
  return changeOutcome(change, root) !== 'absent';
}

/**
 * What one change did on the page: `applied` when at least one element now holds it, `skipped` when its element is
 * there and nothing was written (every match inside a form, an unsafe attribute, a selector the browser cannot parse,
 * a `track_click`, which changes nothing), `absent` when there is nothing to change yet.
 *
 * `applied` includes an element that already held exactly this value (`changeKey`): the change is on the page either
 * way, and a single-page app's next page, or a re-decision, is a new view of it rather than nothing. This is what decides
 * whether a visitor saw a variation (`applyChanges`'s `onApplied`), so a change skipped inside a form never counts the
 * visitor as viewing a page that did not change.
 *
 * **Applying a change again must leave the page as applying it once did.** Three ops need care for that, because the
 * marker that says "done" lives on the element and the visual editor's selectors are positions
 * (`main > section:nth-of-type(1)`). Every page_view re-decides — and a router calls `history.replaceState` constantly —
 * so each of these runs again and again:
 *
 * - a **remove** that took the marked element away would leave the selector matching the next section, unmarked, and
 *   each re-decision would remove one more. So the element is replaced by a hidden, empty STAND-IN of the same tag, id
 *   and class that carries the marker, so every position after it is where it was and the selector finds the stand-in;
 * - a **move** would re-resolve to whichever element now sat at the old position and move that too, flipping two
 *   elements back and forth. So a move is done when any element on the page carries it;
 * - an **insert** before its element shifts every later `div:nth-of-type`, so the selector would find the new holder
 *   and insert another. So the holder carries the insert's marker too.
 *
 * A custom element (a name with a hyphen) gets no stand-in: creating one runs the site's own constructor, which could
 * do anything, and positional removal of one is the rare case. It is removed outright.
 *
 * `undo`, when given, is handed one function per element written, which puts back what was there — but only if the
 * element still holds what this wrote. A single-page app re-renders what it owns, and restoring the old text over a
 * framework's new text would be worse than leaving ours (`index.ts`, where a page the experience no longer matches
 * takes its changes back).
 */
export function changeOutcome(change: WebChange, root: ParentNode = document, undo?: (restore: () => void) => void): 'applied' | 'skipped' | 'absent' {
  if (change.op === 'track_click') return 'skipped';
  let elements: Element[];
  try {
    elements = [...root.querySelectorAll(change.selector)];
  } catch {
    // A selector the browser cannot parse is one change lost, not a page broken.
    return 'skipped';
  }
  if (elements.length === 0) return 'absent';
  const key = changeKey(change);
  const slot = `${changeSlot(change)}=`;
  if (change.op === 'move' && carriesKey(root, key)) return 'applied';
  let applied = false;
  for (const element of elements) {
    if (writesInsideForbidden(change, element, root)) continue;
    const done = markersOf(element);
    if (done.includes(key)) {
      applied = true;
      continue;
    }
    switch (change.op) {
      case 'text':
      case 'html': {
        const before = undo ? [...element.childNodes] : [];
        if (change.op === 'text') element.textContent = change.value;
        else element.replaceChildren(cleanMarkup(change.value));
        if (undo) {
          const written = [...element.childNodes];
          undo(() => {
            const now = [...element.childNodes];
            if (now.length !== written.length || now.some((node, index) => node !== written[index])) return;
            element.replaceChildren(...before);
            unmark(element, key);
          });
        }
        break;
      }
      case 'hide':
      case 'style': {
        const style = (element as HTMLElement).style;
        const property = change.op === 'hide' ? 'display' : change.property;
        const previous = undo ? { value: style.getPropertyValue(property), priority: style.getPropertyPriority(property) } : null;
        style.setProperty(property, change.op === 'hide' ? 'none' : change.value, 'important');
        if (undo && previous) {
          const written = style.getPropertyValue(property);
          undo(() => {
            if (style.getPropertyValue(property) !== written) return;
            if (previous.value) style.setProperty(property, previous.value, previous.priority);
            else style.removeProperty(property);
            unmark(element, key);
          });
        }
        break;
      }
      case 'remove': {
        const standIn = standInFor(element, key);
        if (standIn) element.replaceWith(standIn);
        else element.remove();
        undo?.(() => {
          if (standIn?.isConnected) standIn.replaceWith(element);
        });
        applied = true;
        continue;
      }
      case 'attr': {
        // Refused, and not marked done either: a marker would read as applied the next time the page is decided.
        if (attributeUnsafe(change.name) || valueRuns(change.value)) continue;
        const previous = element.getAttribute(change.name);
        element.setAttribute(change.name, change.value);
        undo?.(() => {
          if (element.getAttribute(change.name) !== change.value) return;
          if (previous === null) element.removeAttribute(change.name);
          else element.setAttribute(change.name, previous);
          unmark(element, key);
        });
        break;
      }
      case 'move': {
        const target = root.querySelector(change.target);
        if (!target) return applied ? 'applied' : 'absent';
        // Where it was, so a page that no longer wants it moved can put it back. A comment: invisible, and no position.
        const home = undo && typeof document.createComment === 'function' ? document.createComment('') : null;
        if (home) element.before(home);
        target.insertAdjacentElement(change.position === 'before' ? 'beforebegin' : 'afterend', element);
        undo?.(() => {
          if (!home?.isConnected) return;
          home.replaceWith(element);
          unmark(element, key);
        });
        break;
      }
      case 'insert': {
        const where = { before: 'beforebegin', after: 'afterend', prepend: 'afterbegin', append: 'beforeend' }[change.position] as InsertPosition;
        const holder = document.createElement('div');
        holder.setAttribute('data-treebars-widget', change.widget ?? 'custom');
        holder.setAttribute(APPLIED, key);
        holder.appendChild(cleanMarkup(change.html));
        element.insertAdjacentElement(where, holder);
        undo?.(() => {
          holder.remove();
          unmark(element, key);
        });
        break;
      }
    }
    // The slot's previous value goes: it no longer describes the element, and keeping it would make A → B → A end on B.
    element.setAttribute(APPLIED, [...done.filter((entry) => !entry.startsWith(slot)), key].join('|'));
    applied = true;
  }
  return applied ? 'applied' : 'skipped';
}

function markersOf(element: Element): string[] {
  return (element.getAttribute(APPLIED) ?? '').split('|').filter(Boolean);
}

function unmark(element: Element, key: string): void {
  const rest = markersOf(element).filter((entry) => entry !== key);
  if (rest.length > 0) element.setAttribute(APPLIED, rest.join('|'));
  else element.removeAttribute(APPLIED);
}

/** Whether any element under `root` carries this change's marker. */
function carriesKey(root: ParentNode, key: string): boolean {
  try {
    return [...root.querySelectorAll(`[${APPLIED}]`)].some((element) => markersOf(element).includes(key));
  } catch {
    return false;
  }
}

/**
 * What a removed element leaves behind: an empty, hidden element of its own tag, id and class, carrying the removal's
 * marker, so the element's position — which is what the editor's selectors name — still holds something marked done.
 * Null for a custom element (see `changeOutcome`).
 *
 * Hidden through the style OBJECT, not a `style` attribute: a strict `style-src` refuses the attribute, and then only
 * `hidden` is left, which any site rule on the copied class beats — an empty coloured band where a section was.
 *
 * A stand-in of a form control is inert (`INERT_CONTROLS`). Remove works inside a form, and a copy of the removed tag
 * is a new control in it: an `<option>` with no value could become a named select's default and submit `''`, and a
 * `<button>` defaults to submit and could become the button Enter presses. Disabled, a control is skipped for the
 * default and never submitted; a button made `type=button` is no submitter at all.
 */
function standInFor(element: Element, key: string): Element | null {
  const name = element.localName;
  if (!name || name.includes('-') || typeof document === 'undefined' || typeof document.createElementNS !== 'function') return null;
  const standIn = document.createElementNS(element.namespaceURI ?? 'http://www.w3.org/1999/xhtml', name);
  for (const attribute of ['id', 'class']) {
    const value = element.getAttribute(attribute);
    if (value !== null) standIn.setAttribute(attribute, value);
  }
  standIn.setAttribute('hidden', '');
  standIn.setAttribute('aria-hidden', 'true');
  standIn.setAttribute('data-treebars-removed', '');
  for (const [attribute, value] of INERT_CONTROLS[name.toLowerCase()] ?? []) standIn.setAttribute(attribute, value);
  (standIn as HTMLElement).style?.setProperty('display', 'none', 'important');
  standIn.setAttribute(APPLIED, key);
  return standIn;
}

const DISABLED: [string, string] = ['disabled', ''];
const INERT_CONTROLS: Record<string, [string, string][]> = {
  button: [['type', 'button'], DISABLED],
  input: [['type', 'hidden'], DISABLED],
  select: [DISABLED],
  option: [DISABLED],
  optgroup: [DISABLED],
  textarea: [DISABLED],
  fieldset: [DISABLED],
};

/**
 * What one click reports: at most one experience_clicked per experience, named by the first of its counted changes the
 * click landed in. `matches` asks whether the clicked element is inside a selector — `closest`, on the page.
 */
export function clickedChanges(shown: Decision[], matches: (selector: string) => boolean): { experience_id: string; variation_id: string; name: string }[] {
  const clicks: { experience_id: string; variation_id: string; name: string }[] = [];
  for (const decision of shown) {
    const change = decision.changes.find((one): one is Extract<WebChange, { op: 'track_click' }> => one.op === 'track_click' && matches(one.selector));
    if (change) clicks.push({ experience_id: decision.experience_id, variation_id: decision.variation_id, name: change.name });
  }
  return clicks;
}

/**
 * Every change of the visitor's variations. What is not on the page yet is tried again as the page changes, for a few
 * seconds — a single-page app draws after this runs — and then given up on, so an observer is not left running.
 *
 * `onApplied(index)` is called once for each change, by its index in `changes`, the first time it lands
 * (`changeOutcome`) — at once, or later from the observer. A change that is skipped, or never appears within the
 * window, never calls it. It is how the SDK knows a variation was really seen.
 *
 * `onWritten(index, restore)` is handed what takes each write back (`changeOutcome`'s `undo`).
 */
export function applyChanges(
  changes: WebChange[],
  waitMs = 5000,
  onApplied?: (index: number) => void,
  onWritten?: (index: number, restore: () => void) => void,
): () => void {
  const attempt = (index: number): boolean => {
    const outcome = changeOutcome(changes[index]!, document, onWritten ? (restore) => onWritten(index, restore) : undefined);
    if (outcome === 'applied') onApplied?.(index);
    return outcome !== 'absent';
  };
  let pending = changes.map((_, index) => index).filter((index) => !attempt(index));
  if (pending.length === 0 || typeof MutationObserver === 'undefined') return () => {};
  const observer = new MutationObserver(() => {
    pending = pending.filter((index) => !attempt(index));
    if (pending.length === 0) observer.disconnect();
  });
  observer.observe(document.documentElement, { childList: true, subtree: true });
  const timer = setTimeout(() => observer.disconnect(), waitMs);
  return () => {
    clearTimeout(timer);
    observer.disconnect();
  };
}

/** The anti-flicker style's id: the snippet in the page's head adds it, and the SDK removes it once changes are on. */
export const ANTI_FLICKER_ID = 'treebars-antiflicker';

/**
 * Pasted into the page's `<head>` above the SDK: hides the page until experiences are applied, or for at most `ms`, so a
 * visitor never sees the old headline turn into the new one. Without it the change is visible for a frame or two.
 */
export function antiFlickerSnippet(ms = 800): string {
  return `<style id="${ANTI_FLICKER_ID}">body{opacity:0 !important}</style><script>setTimeout(function(){var s=document.getElementById('${ANTI_FLICKER_ID}');if(s)s.remove()},${ms})</script>`;
}

export function revealPage(): void {
  if (typeof document === 'undefined') return;
  document.getElementById(ANTI_FLICKER_ID)?.remove();
}

/** The variations this visitor has been shown, kept so a goal reached later is credited to them. */
const EXPOSURES_KEY = 'treebars.experiences.v1';

/**
 * One experience this browser was shown: the variation, the goal, and whether the goal has been credited. `converted`
 * is what makes experience_converted once per experience per browser — so every rewrite of an exposure keeps it, or
 * every later goal after a reload would send another conversion.
 */
export interface Exposure {
  variation_id: string;
  goal_event: string | null;
  converted?: boolean;
}

export function readExposures(persist: boolean): Record<string, Exposure> {
  if (!persist) return {};
  try {
    return JSON.parse(safeGet(EXPOSURES_KEY) ?? '{}') as Record<string, Exposure>;
  } catch {
    return {};
  }
}

export function writeExposures(persist: boolean, exposures: Record<string, Exposure>): void {
  if (persist) safeSet(EXPOSURES_KEY, JSON.stringify(exposures));
}

/** Forgets every exposure: they were the previous person's (`reset()`). */
export function clearExposures(): void {
  safeRemove(EXPOSURES_KEY);
}

/**
 * The exposures of experiences that are still running, from the environment's list as just fetched. An experience that
 * is paused, archived or deleted is not in the list, and its goal must stop being credited: a stopped test's report is
 * frozen, and a browser that remembered it for ever would keep converting it.
 */
export function liveExposures(exposures: Record<string, Exposure>, running: { id: string }[]): Record<string, Exposure> {
  const ids = new Set(running.map((experience) => experience.id));
  return Object.fromEntries(Object.entries(exposures).filter(([id]) => ids.has(id)));
}

/**
 * The split-URL hop this tab last made. "The target is not this address" is not enough of a loop guard on its own: a
 * host that serves the target under another address — a trailing slash or `.html` stripped, http to https, apex to
 * www — and whose page rules also match it would answer the redirect with the same page, for ever. So a hop is written
 * down before it is made, and read on the next page: arriving on a page that would send the visitor on for the SAME
 * experience within a few seconds of being sent is the loop, and the visitor stays.
 *
 * Per tab (`sessionStorage`), and consumed by the next page whatever it decides, so going back to the control page later
 * is decided afresh. A hop that cannot be written down is not made: without storage there is no way to tell the loop
 * from a first visit, and — with no stored device id either — the visitor's variation is not even the same one page
 * to the next.
 */
const SPLIT_HOP_KEY = 'treebars.split_hop.v1';
const SPLIT_HOP_MS = 30_000;

export function takeSplitHop(now = Date.now()): string | null {
  try {
    const raw = globalThis.sessionStorage?.getItem(SPLIT_HOP_KEY) ?? null;
    globalThis.sessionStorage?.removeItem(SPLIT_HOP_KEY);
    if (!raw) return null;
    const hop = JSON.parse(raw) as { experience_id?: unknown; at?: unknown };
    return typeof hop.experience_id === 'string' && typeof hop.at === 'number' && now - hop.at >= 0 && now - hop.at < SPLIT_HOP_MS ? hop.experience_id : null;
  } catch {
    return null;
  }
}

export function recordSplitHop(experienceId: string, now = Date.now()): boolean {
  try {
    if (!globalThis.sessionStorage) return false;
    globalThis.sessionStorage.setItem(SPLIT_HOP_KEY, JSON.stringify({ experience_id: experienceId, at: now }));
    return true;
  } catch {
    return false;
  }
}

/** A split-URL address with the page's own query carried across, so campaign parameters survive the hop. */
export function redirectTarget(to: string, from: string): string {
  try {
    const target = new URL(to, from);
    const source = new URL(from);
    source.searchParams.forEach((value, key) => {
      if (!target.searchParams.has(key)) target.searchParams.set(key, value);
    });
    return target.toString();
  } catch {
    return to;
  }
}
