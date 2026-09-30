import { ACQUISITION, MAX_REFERRER_LENGTH, STORAGE_KEYS } from './generated/constants';

/**
 * Carrying a click id across a landing page and onto the store button.
 *
 * **The hop this exists for.** Somebody taps an ad, the ad points at one of the project's Treebars
 * tracking links, and the link's destination is the customer's own marketing page rather than the
 * store. The tracking link puts `tbrs_click_id` on that page's address — and then the page's own
 * "Get it on Google Play" button is a plain store link, so without this the id is dropped at the
 * last hop, the install arrives with no proof, and the campaign is credited to nobody.
 *
 * On Android this is the whole difference between an exactly-measured paid install and an organic
 * one. On iPhone it is nothing, deliberately — nothing appended to an App Store URL reaches the
 * installed app, which is a fact about Apple's platform and not something a page can work around,
 * so `market://` and Play links are rewritten and App Store links are left exactly as the customer
 * wrote them.
 *
 * **It builds a minimal referrer rather than the full one a tracking link's redirect builds.** That
 * one carries the customer's own UTM parameters too, and none of them are read when a click id is
 * present: the recorded click already holds the source, the campaign labels and the link id, and
 * attribution reads those. So the string here is the two Treebars parameters and nothing else — a
 * small enough rule to be obviously the same rule, where a second copy of the full builder would be
 * a second thing to keep in step, in a path whose failure is silent.
 */

/** What the page arrived carrying, or null when this visit did not come through a tracking link. */
export interface CarriedClick {
  clickId: string;
  deepLinkPath: string | null;
  /**
   * Whether the project's iPhone app reads a handoff, so an App Store button copies the click before
   * leaving. Known only for a click this page recorded itself (`POST /v1/web-click` says); a click that
   * arrived on a tracker link already had its chance at the handoff on the way here.
   */
  handoff?: boolean;
}

/**
 * The click ids ad networks put on the address of a site their ad points at. A visit carrying one came
 * from an ad, which is the only visit worth recording as a click — see `recordAdClick` in `index.ts`.
 */
export const AD_CLICK_PARAMS = ['gclid', 'gbraid', 'wbraid', 'fbclid', 'ttclid'] as const;

/** Whether this address came from an ad: a network click id, or a `utm_source` that may name a source. */
export function hasAdClick(href: string): boolean {
  try {
    const params = new URL(href).searchParams;
    return AD_CLICK_PARAMS.some((param) => params.get(param)) || !!params.get('utm_source');
  } catch {
    return false;
  }
}

/**
 * The browser id this site shares with its link domain, for matching an iPhone install to this visit.
 *
 * `tbrs_bs` — the same name Treebars' tracking links set on the registrable domain they share with the
 * site. Whichever side sees the browser first mints it; the other reuses it, so a tap on one of the
 * project's links and a visit to its website in one Safari are one browser for matching instead of two.
 * Read and written only when a visit from an ad is recorded, lives six hours, and names nothing but this
 * browser.
 *
 * Set on the SHORTEST domain the browser accepts — `shop.acme.com` tries `acme.com` first — which is the
 * browser enforcing the public suffix list for us: `co.uk` is refused and `acme.co.uk` sticks. Null when
 * cookies are off, and the visit is then matched as a browser of its own.
 */
export const SHARED_BROWSER_COOKIE = 'tbrs_bs';
const SHARED_BROWSER_SECONDS = 6 * 60 * 60;

export function sharedBrowserId(): string | null {
  try {
    const held = document.cookie
      .split(';')
      .map((part) => part.trim())
      .find((part) => part.startsWith(`${SHARED_BROWSER_COOKIE}=`))
      ?.slice(SHARED_BROWSER_COOKIE.length + 1);
    const id = held && /^[a-z0-9]{22}$/.test(held) ? held : mintBrowserId();
    return writeSharedBrowserId(id) ? id : null;
  } catch {
    return null;
  }
}

/**
 * Expires `tbrs_bs` wherever `writeSharedBrowserId` could have set it — each registrable-domain
 * candidate, then host-only — for `wipeLocalData`. A browser id is this browser; a wipe that left it
 * would let the next visit be matched to the last one.
 */
export function forgetSharedBrowserId(): void {
  try {
    const labels = window.location.hostname.split('.');
    const expired = '; Max-Age=0; Path=/';
    for (let take = 2; take <= labels.length; take += 1) {
      document.cookie = `${SHARED_BROWSER_COOKIE}=; Domain=${labels.slice(-take).join('.')}${expired}`;
    }
    document.cookie = `${SHARED_BROWSER_COOKIE}=${expired}`;
  } catch {
    // No document, or cookies refused: nothing was set.
  }
}

function mintBrowserId(): string {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
  const bytes = crypto.getRandomValues(new Uint8Array(22));
  return Array.from(bytes, (byte) => alphabet[byte % alphabet.length]).join('');
}

function writeSharedBrowserId(id: string): boolean {
  const labels = window.location.hostname.split('.');
  const secure = window.location.protocol === 'https:' ? '; Secure' : '';
  const attributes = `; Max-Age=${SHARED_BROWSER_SECONDS}; Path=/; SameSite=Lax${secure}`;
  // The shortest domain the browser will take, then host-only for an address or `localhost`.
  for (let take = 2; take <= labels.length; take += 1) {
    const domain = labels.slice(-take).join('.');
    document.cookie = `${SHARED_BROWSER_COOKIE}=${id}; Domain=${domain}${attributes}`;
    if (document.cookie.includes(`${SHARED_BROWSER_COOKIE}=${id}`)) return true;
  }
  document.cookie = `${SHARED_BROWSER_COOKIE}=${id}${attributes}`;
  return document.cookie.includes(`${SHARED_BROWSER_COOKIE}=${id}`);
}

/**
 * What a page can report about the device that a link redirect cannot — no JavaScript runs on a
 * redirect: the time zone, and the screen in CSS pixels, which on a phone are the app's points.
 */
export function deviceSignals(): { timezone?: string; screen_width?: number; screen_height?: number } {
  const out: { timezone?: string; screen_width?: number; screen_height?: number } = {};
  try {
    const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    if (zone) out.timezone = zone;
  } catch {
    // No Intl zone: the time zone is left out, as unknown.
  }
  if (typeof screen !== 'undefined' && screen.width > 0 && screen.height > 0) {
    out.screen_width = screen.width;
    out.screen_height = screen.height;
  }
  return out;
}

/**
 * Remember a click this page recorded, so every later page of the visit carries it too.
 *
 * Not with storage off (`disableStorage`), which is a visitor who has not consented: the click is
 * then carried only by the page whose address has it.
 */
export function rememberClick(click: CarriedClick, persist = true): void {
  if (!persist || !CLICK_ID_SHAPE.test(click.clickId)) return;
  writeStorage(STORAGE_KEYS.acquisitionClick, JSON.stringify(click));
}

/**
 * Whether this is an App Store link — the one a referrer cannot survive, and the handoff is for.
 *
 * A TestFlight invitation counts: it is where an iPhone app is installed from before it is on the store,
 * and it loses the click exactly as the store does. An app in beta has no store address to put on a
 * button at all, so without it the handoff would never be copied for a tap on one.
 */
export function isAppStoreLink(href: string): boolean {
  try {
    const host = new URL(href, window.location.href).hostname;
    return host === 'apps.apple.com' || host === 'itunes.apple.com' || host === 'testflight.apple.com';
  } catch {
    return false;
  }
}

/**
 * The string an iPhone app reads back off the clipboard: this page's own address with the click id on
 * it — the shape the iOS SDK's `parseHandoff` accepts, an http(s) URL carrying `tbrs_click_id`.
 */
export function handoffFor(click: CarriedClick, href: string): string {
  const url = new URL(href);
  url.search = '';
  url.hash = '';
  url.searchParams.set(ACQUISITION.clickIdParam, click.clickId);
  if (click.deepLinkPath) url.searchParams.set(ACQUISITION.deepLinkParam, click.deepLinkPath);
  return url.toString();
}

/**
 * Store hosts whose links can carry a referrer through the install.
 *
 * Play and nothing else. `market://` is Play's own scheme and goes through an Android intent that
 * preserves the query, so it is the same answer by another spelling.
 */
const PLAY_HOSTS = ['play.google.com', 'market.android.com'];

/**
 * The shape of a Treebars click id, checked here so a hand-written or mangled value is refused.
 *
 * A page is a place anybody can put anything in a query string. Accepting whatever is there would
 * put a stranger's string on the customer's store button, where it becomes a referrer somebody
 * else's install is measured by — and the cost of being wrong is silent, so the check is cheap
 * insurance rather than defensiveness.
 */
const CLICK_ID_SHAPE = /^[A-Za-z0-9_-]{8,64}$/;

/** A deep-link path: rooted, with no scheme and no host. */
const DEEP_LINK_SHAPE = /^\/[A-Za-z0-9\-._~!$&'()*+,;=:@%/]*$/;

function readStorage(key: string): string | null {
  try {
    return window.localStorage.getItem(key);
  } catch {
    // A private window, blocked site data, or a browser that throws on access. A visit that cannot
    // remember the click still measures correctly when the store button is on the landing page
    // itself, which is the common shape — so this degrades rather than failing.
    return null;
  }
}

function writeStorage(key: string, value: string): void {
  try {
    window.localStorage.setItem(key, value);
  } catch {
    /* As above: remembering is an improvement, never a requirement. */
  }
}

/**
 * The click this visit carries: from the page's own address if it is there, else from storage.
 *
 * **Stored on sight, because the store button is usually on a different page.** Somebody lands on a
 * campaign page, reads it, opens the features page and taps the store button there — and the id was
 * only ever on the first URL. Reading the address every time and falling back to what was stored is
 * what makes the second page work.
 *
 * A fresh id on the address REPLACES a stored one. Two campaigns in one browser is an ordinary
 * thing; the one they are looking at now is the one that brought them to this button.
 *
 * With storage off (`persist` false) it is the address or nothing: no write, and no read of a click
 * an earlier, consented visit left behind.
 */
export function carriedClick(href: string, persist = true): CarriedClick | null {
  let fromUrl: CarriedClick | null = null;
  try {
    const params = new URL(href).searchParams;
    const clickId = params.get(ACQUISITION.clickIdParam);
    if (clickId && CLICK_ID_SHAPE.test(clickId)) {
      const path = params.get(ACQUISITION.deepLinkParam);
      fromUrl = { clickId, deepLinkPath: path && DEEP_LINK_SHAPE.test(path) ? path : null };
    }
  } catch {
    /* Not a URL this browser can parse. Fall through to what was stored. */
  }

  if (fromUrl) {
    if (persist) writeStorage(STORAGE_KEYS.acquisitionClick, JSON.stringify(fromUrl));
    return fromUrl;
  }
  if (!persist) return null;

  const stored = readStorage(STORAGE_KEYS.acquisitionClick);
  if (!stored) return null;
  try {
    const parsed = JSON.parse(stored) as CarriedClick;
    // Re-checked on the way out, not only on the way in: storage is per origin, and the customer's
    // own site shares it with every other script on the page.
    if (typeof parsed?.clickId !== 'string' || !CLICK_ID_SHAPE.test(parsed.clickId)) return null;
    const path = typeof parsed.deepLinkPath === 'string' ? parsed.deepLinkPath : null;
    return {
      clickId: parsed.clickId,
      deepLinkPath: path && DEEP_LINK_SHAPE.test(path) ? path : null,
      ...(parsed.handoff === true ? { handoff: true } : {}),
    };
  } catch {
    return null;
  }
}

/**
 * The referrer string Play hands to the app on first open.
 *
 * The deep-link path goes in first and the click id last, so that if the two together were ever over
 * the cap it is the path that is dropped — the same order of preference a tracking link's redirect
 * applies, and for the same reason: the path decides where somebody lands, the click id decides
 * whether the install is measured at all.
 */
export function playReferrer(click: CarriedClick): string {
  const params = new URLSearchParams();
  if (click.deepLinkPath) params.set(ACQUISITION.deepLinkParam, click.deepLinkPath);
  params.set(ACQUISITION.clickIdParam, click.clickId);
  if (params.toString().length > MAX_REFERRER_LENGTH) {
    params.delete(ACQUISITION.deepLinkParam);
  }
  return params.toString();
}

/** Whether this is a Play link, and therefore one a referrer survives. */
export function isPlayLink(href: string): boolean {
  if (href.startsWith('market://')) return true;
  try {
    const url = new URL(href, window.location.href);
    return PLAY_HOSTS.includes(url.hostname);
  } catch {
    return false;
  }
}

/**
 * The same link with the Treebars referrer on it, or unchanged when it is not a Play link.
 *
 * **A referrer the customer set themselves wins.** Some teams put their own `referrer=utm_source=…`
 * on a store button and read it in their own tooling; overwriting it would break something that was
 * working to fix something they had not asked to have fixed. A tracking link's own redirect makes the
 * opposite choice, where the referrer is Treebars' to build.
 */
export function withReferrer(href: string, click: CarriedClick): string {
  if (!isPlayLink(href)) return href;
  if (href.startsWith('market://')) {
    // `new URL` cannot parse a custom scheme consistently across browsers, so the query is handled
    // as text. Nothing here needs to understand the rest of the URL.
    if (/[?&]referrer=/.test(href)) return href;
    return `${href}${href.includes('?') ? '&' : '?'}referrer=${encodeURIComponent(playReferrer(click))}`;
  }
  try {
    const url = new URL(href, window.location.href);
    if (url.searchParams.has('referrer')) return href;
    url.searchParams.set('referrer', playReferrer(click));
    return url.toString();
  } catch {
    return href;
  }
}

/** The two methods this needs of an anchor, so the rule can be tested without a DOM. */
export interface StoreAnchor {
  getAttribute(name: string): string | null;
  setAttribute(name: string, value: string): void;
}

/**
 * Put the referrer on one anchor, if it is a Play link that has not got one. Returns what it did.
 *
 * Separated from the listener because this is the whole rule and the listener is plumbing. This
 * package's tests run without a DOM — the suites stub `window` and `document` by hand — so a rule
 * reachable only through a real `click` event would be a rule nothing checks.
 *
 * **`getAttribute`, never `.href`.** The property resolves what the author wrote into an absolute
 * URL, so `market://details?id=x` comes back as something else entirely and a relative link comes
 * back with the customer's own origin on it. The attribute is what they wrote and what has to stay
 * true after the rewrite.
 */
export function carryOntoAnchor(anchor: StoreAnchor, click: CarriedClick): boolean {
  const href = anchor.getAttribute('href') ?? '';
  if (!isPlayLink(href)) return false;
  const next = withReferrer(href, click);
  if (next === href) return false;
  anchor.setAttribute('href', next);
  return true;
}

/**
 * Watch the page for taps on store links and put the referrer on at the moment of the tap.
 *
 * **At click time rather than by rewriting the page on load**, which is the decision that makes this
 * work on a real marketing site. A rewrite pass sees the links that exist when it runs; a landing
 * page built with React, or one whose store button sits in a banner that appears on scroll, adds
 * them later — and a second rewrite pass on a timer is a guess about somebody else's rendering.
 * A listener on the document sees every tap whenever the link arrived.
 *
 * Capture phase, so the href is already correct if the page's own click handler reads it. Passive
 * in the sense that matters: nothing is prevented, nothing is navigated, and a link this does not
 * recognise is not touched.
 */
export function watchStoreLinks(
  getClick: () => CarriedClick | null,
  /**
   * The visit being recorded, or null — and, asked with `storeTap`, the caller may START recording one
   * for this tap.
   *
   * Two moments need it. A store tap in the second after an ad opened the page would otherwise leave
   * with nothing: the click id is on its way back from the server, and a tap does not wait for it. And a
   * tap on an ordinary visit — nobody sent this person, they read the site and decided — is the one
   * thing such a visit can prove, so it is worth a click id of its own. Both wait, briefly, for the
   * same answer.
   */
  pending: (storeTap: boolean) => Promise<unknown> | null = () => null,
): () => void {
  /** Carry the click onto this anchor, and copy the handoff on an App Store tap. True when it navigated itself. */
  const carry = (event: MouseEvent, anchor: Element, click: CarriedClick, navigate: boolean): void => {
    carryOntoAnchor(anchor, click);
    const href = anchor.getAttribute('href') ?? '';
    const target = anchor.getAttribute('target');
    const leave = () => {
      if (target && target !== '_self') window.open(href, target);
      else window.location.href = href;
    };
    /*
     * An App Store button, for a project whose iPhone app reads a handoff: copy the click before the
     * store opens, because nothing on an App Store address reaches the installed app. This is the
     * person's own tap, so the clipboard is allowed without the extra page a tracker link needs. The
     * store follows whether the copy worked or not — the install is what they came for.
     */
    if (event.type === 'click' && click.handoff && isAppStoreLink(href) && navigator.clipboard) {
      if (!navigate) event.preventDefault();
      try {
        navigator.clipboard.writeText(handoffFor(click, window.location.href)).then(leave, leave);
      } catch {
        leave();
      }
      return;
    }
    if (navigate) leave();
  };

  const onClick = (event: MouseEvent) => {
    const target = event.target;
    if (!(target instanceof Element)) return;
    const anchor = target.closest('a[href]');
    if (!anchor) return;

    const click = getClick();
    if (click) {
      carry(event, anchor, click, false);
      return;
    }

    /*
     * No click yet, but one is being recorded, and this is a store button: hold the tap until the
     * answer arrives (never more than 1.2 seconds), then carry it and go. The page's developer does
     * not have to know any of this happens — every Play and App Store link on the page is handled.
     */
    const href = anchor.getAttribute('href') ?? '';
    const store = isPlayLink(href) || isAppStoreLink(href);
    /*
     * Asked only for a store link, and only on a real click: `pending(true)` may send a request, and a
     * middle-click that opens a tab in the background is not somebody leaving for the store.
     */
    const waiting = pending(event.type === 'click' && store);
    if (event.type !== 'click' || !waiting || !store) return;
    event.preventDefault();
    const timeout = new Promise((resolve) => setTimeout(resolve, 1200));
    void Promise.race([waiting.catch(() => undefined), timeout]).then(() => {
      const late = getClick();
      if (late) carry(event, anchor, late, true);
      else if (anchor.getAttribute('target') && anchor.getAttribute('target') !== '_self') window.open(href, anchor.getAttribute('target')!);
      else window.location.href = href;
    });
  };

  document.addEventListener('click', onClick, true);
  /*
   * `auxclick` as well, for a middle-click or a tap that opens in a new tab. Not a nicety: somebody
   * comparing two apps opens both in tabs, and that install is exactly as real as any other.
   */
  document.addEventListener('auxclick', onClick, true);
  return () => {
    document.removeEventListener('click', onClick, true);
    document.removeEventListener('auxclick', onClick, true);
  };
}
