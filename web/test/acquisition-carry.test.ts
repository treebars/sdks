import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import {
  carriedClick,
  carryOntoAnchor,
  isPlayLink,
  playReferrer,
  withReferrer,
  type CarriedClick,
  type StoreAnchor,
  handoffFor,
  hasAdClick,
  isAppStoreLink,
  watchStoreLinks,
} from '../src/acquisition';
import { STORAGE_KEYS } from '../src/generated/constants';

/**
 * Carrying a click id across a landing page and onto its store button.
 *
 * The hop this covers: ad → our tracking link → the customer's own marketing page → "Get it on
 * Google Play". The click id has to survive onto that button, or the install arrives with no proof
 * and the campaign is credited to nobody.
 *
 * Every failure here is SILENT — a wrong referrer is an organic install, not an error — so what is
 * pinned is each way the string can come out wrong rather than that the happy path runs.
 */

const CLICK: CarriedClick = { clickId: 'clk_abc12345', deepLinkPath: null };

function memoryStorage(): Storage {
  const map = new Map<string, string>();
  return {
    get length() {
      return map.size;
    },
    clear: () => map.clear(),
    getItem: (key: string) => map.get(key) ?? null,
    key: (i: number) => [...map.keys()][i] ?? null,
    removeItem: (key: string) => void map.delete(key),
    setItem: (key: string, value: string) => void map.set(key, value),
  } as Storage;
}

/** An anchor with the two methods the rule uses, and nothing else. */
function anchor(href: string): StoreAnchor & { href: string } {
  return {
    href,
    getAttribute(name: string) {
      return name === 'href' ? this.href : null;
    },
    setAttribute(name: string, value: string) {
      if (name === 'href') this.href = value;
    },
  };
}

let storage: Storage;

beforeEach(() => {
  storage = memoryStorage();
  vi.stubGlobal('window', {
    localStorage: storage,
    location: { href: 'https://northwind.example/spring', origin: 'https://northwind.example' },
  });
});

afterEach(() => vi.unstubAllGlobals());

describe('reading the click off the page', () => {
  it('takes the click id and the deep-link path the tracking link put there', () => {
    const found = carriedClick('https://northwind.example/spring?tbrs_click_id=clk_abc12345&tbrs_deep_link=/product/42');
    expect(found).toEqual({ clickId: 'clk_abc12345', deepLinkPath: '/product/42' });
  });

  it('remembers it, so a store button two pages later still carries it', () => {
    /*
     * The case that makes this more than one line. Somebody lands on the campaign page, reads it,
     * opens the features page, and taps the store button THERE — where the address has never had a
     * click id on it. Without this the whole feature only works on single-page landers.
     */
    carriedClick('https://northwind.example/spring?tbrs_click_id=clk_abc12345');
    expect(carriedClick('https://northwind.example/features')).toEqual({
      clickId: 'clk_abc12345',
      deepLinkPath: null,
    });
  });

  it('lets a fresh click id replace a remembered one', () => {
    carriedClick('https://northwind.example/spring?tbrs_click_id=clk_abc12345');
    const second = carriedClick('https://northwind.example/summer?tbrs_click_id=clk_zzz99999');
    expect(second?.clickId).toBe('clk_zzz99999');
    // And the new one is what a later page reads, not the first.
    expect(carriedClick('https://northwind.example/features')?.clickId).toBe('clk_zzz99999');
  });

  it('refuses a click id that is not one of ours', () => {
    /*
     * A query string is a place anybody can put anything. Accepting it would put a stranger's value
     * on the customer's store button, where it becomes the referrer an install is measured by.
     */
    expect(carriedClick('https://northwind.example/?tbrs_click_id=../../etc/passwd')).toBeNull();
    expect(carriedClick('https://northwind.example/?tbrs_click_id=short')).toBeNull();
    expect(carriedClick(`https://northwind.example/?tbrs_click_id=${'x'.repeat(200)}`)).toBeNull();
  });

  it('keeps the click and drops only the path when the path is not a path', () => {
    // The two are independently useful: a bad path costs somebody the screen they land on, where a
    // dropped click id costs the campaign its credit. One must not take the other with it.
    const found = carriedClick('https://northwind.example/?tbrs_click_id=clk_abc12345&tbrs_deep_link=https://evil.test/x');
    expect(found).toEqual({ clickId: 'clk_abc12345', deepLinkPath: null });
  });

  it('works when storage throws, which is a private window', () => {
    vi.stubGlobal('window', {
      get localStorage(): Storage {
        throw new Error('blocked');
      },
      location: { href: 'https://northwind.example/', origin: 'https://northwind.example' },
    });
    // The id is still read off the address, so a store button on THIS page is still carried. Only
    // the memory across pages is lost, which is the right thing to lose.
    expect(carriedClick('https://northwind.example/?tbrs_click_id=clk_abc12345')?.clickId).toBe('clk_abc12345');
    expect(carriedClick('https://northwind.example/features')).toBeNull();
  });

  it('stores under the generated key, so nothing here invents a second spelling', () => {
    carriedClick('https://northwind.example/?tbrs_click_id=clk_abc12345');
    expect(storage.getItem(STORAGE_KEYS.acquisitionClick)).toContain('clk_abc12345');
  });
});

describe('the referrer it builds', () => {
  it('carries our two parameters and nothing else', () => {
    // Deliberately only these two: the customer's UTM values are not read when a click id is
    // present, because the click RECORD already holds the source and the labels.
    const referrer = playReferrer({ clickId: 'clk_abc12345', deepLinkPath: '/product/42' });
    expect(new URLSearchParams(referrer).get('tbrs_click_id')).toBe('clk_abc12345');
    expect(new URLSearchParams(referrer).get('tbrs_deep_link')).toBe('/product/42');
    expect([...new URLSearchParams(referrer).keys()].sort()).toEqual(['tbrs_click_id', 'tbrs_deep_link']);
  });

  it('drops the path rather than the click id when it will not fit', () => {
    /*
     * Play truncates a referrer over its cap, and a truncated click id matches no click record — so
     * the install goes from measured to organic with nothing anywhere saying why. The path is worth
     * less than the click id, so the path is what goes.
     */
    const referrer = playReferrer({ clickId: 'clk_abc12345', deepLinkPath: `/${'a'.repeat(1200)}` });
    expect(referrer.length).toBeLessThanOrEqual(1000);
    expect(new URLSearchParams(referrer).get('tbrs_click_id')).toBe('clk_abc12345');
    expect(new URLSearchParams(referrer).has('tbrs_deep_link')).toBe(false);
  });
});

describe('which links get touched', () => {
  it('recognises Play, in both of its spellings', () => {
    expect(isPlayLink('https://play.google.com/store/apps/details?id=com.northwind')).toBe(true);
    expect(isPlayLink('market://details?id=com.northwind')).toBe(true);
  });

  it('leaves the App Store exactly as written', () => {
    /*
     * Not an oversight and not a to-do. Nothing appended to an App Store URL reaches the installed
     * app — that is the shape of Apple's platform — so a referrer here would be a parameter that
     * does nothing, on somebody else's link, forever.
     */
    const link = anchor('https://apps.apple.com/app/id123456789');
    expect(carryOntoAnchor(link, CLICK)).toBe(false);
    expect(link.href).toBe('https://apps.apple.com/app/id123456789');
  });

  it('leaves an ordinary link alone', () => {
    const link = anchor('/pricing');
    expect(carryOntoAnchor(link, CLICK)).toBe(false);
    expect(link.href).toBe('/pricing');
  });

  it('puts the referrer on a Play link', () => {
    const link = anchor('https://play.google.com/store/apps/details?id=com.northwind');
    expect(carryOntoAnchor(link, CLICK)).toBe(true);
    expect(new URL(link.href).searchParams.get('referrer')).toBe('tbrs_click_id=clk_abc12345');
    // The app id survives: a rewrite that lost it would send everybody to a broken store page.
    expect(new URL(link.href).searchParams.get('id')).toBe('com.northwind');
  });

  it('puts it on a market:// link too, which `new URL` cannot be trusted with', () => {
    const link = anchor('market://details?id=com.northwind');
    expect(carryOntoAnchor(link, CLICK)).toBe(true);
    expect(link.href).toBe('market://details?id=com.northwind&referrer=tbrs_click_id%3Dclk_abc12345');
  });

  it('does not overwrite a referrer the customer put there themselves', () => {
    /*
     * Some teams set their own and read it in their own tooling. Overwriting it would break
     * something that was working, to fix something they never asked us to fix.
     */
    const link = anchor('https://play.google.com/store/apps/details?id=com.northwind&referrer=utm_source%3Dnewsletter');
    expect(carryOntoAnchor(link, CLICK)).toBe(false);
    expect(link.href).toContain('utm_source%3Dnewsletter');
  });

  it('is idempotent, because a tap can be repeated', () => {
    // The listener runs on every click, and somebody who taps twice must not get a referrer with
    // two click ids in it.
    const link = anchor('https://play.google.com/store/apps/details?id=com.northwind');
    carryOntoAnchor(link, CLICK);
    const once = link.href;
    expect(carryOntoAnchor(link, CLICK)).toBe(false);
    expect(link.href).toBe(once);
  });

  it('reads the attribute rather than the resolved property', () => {
    // A relative Play link is unusual but legal, and `.href` would have resolved it against the
    // customer's own origin — making it not a Play link at all, silently.
    const link = anchor('//play.google.com/store/apps/details?id=com.northwind');
    expect(carryOntoAnchor(link, CLICK)).toBe(true);
    expect(link.href).toContain('referrer=tbrs_click_id');
  });
});

describe('what `withReferrer` refuses', () => {
  it('returns the href unchanged when it cannot be parsed', () => {
    expect(withReferrer('https://', CLICK)).toBe('https://');
  });
});


describe('a visit from an ad that pointed at the site itself', () => {
  it('counts only an address an ad put a click id or a utm_source on', () => {
    // An ordinary visit is not a click; recording one would credit organic traffic to a campaign.
    expect(hasAdClick('https://shop.example/sale?fbclid=IwAR123')).toBe(true);
    expect(hasAdClick('https://shop.example/sale?gclid=Cj0K')).toBe(true);
    expect(hasAdClick('https://shop.example/sale?utm_source=newsletter')).toBe(true);
    expect(hasAdClick('https://shop.example/sale')).toBe(false);
  });

  it('hands an iPhone app this page with our click id and nothing of the ad’s', () => {
    // The shape the iOS SDK's `parseHandoff` accepts: an http(s) URL carrying `tbrs_click_id`. The
    // network's own id and the utm tags stay off it — the app needs ours, and the clipboard is shared.
    const handoff = handoffFor(
      { clickId: 'ab12cd34ef56gh78ij90kl', deepLinkPath: null },
      'https://shop.example/sale?fbclid=IwAR123&utm_source=meta#top',
    );
    expect(handoff).toBe('https://shop.example/sale?tbrs_click_id=ab12cd34ef56gh78ij90kl');
  });

  it('knows an App Store button from a Play one', () => {
    expect(isAppStoreLink('https://apps.apple.com/app/id310633997')).toBe(true);
    expect(isAppStoreLink('https://testflight.apple.com/join/1Nfa8aMc')).toBe(true);
    expect(isAppStoreLink('https://play.google.com/store/apps/details?id=com.example')).toBe(false);
  });
});

/*
 * The tap that lands before the click id does. An ad opens the page, the SDK starts recording the visit,
 * and the eager visitor taps the store badge inside that second — so the tap is held until the click id
 * arrives, or briefly at most. No DOM here, so the document is the three things `watchStoreLinks`
 * touches: a listener, `Element`, and where the page goes.
 */
describe('a store tap while the visit is still being recorded', () => {
  class FakeElement {
    constructor(public href: string) {}
    closest() {
      return this;
    }
    getAttribute(name: string) {
      return name === 'href' ? this.href : null;
    }
    setAttribute(name: string, value: string) {
      if (name === 'href') this.href = value;
    }
  }
  let listener: ((event: unknown) => void) | null;
  let went: string | null;

  beforeEach(() => {
    listener = null;
    went = null;
    vi.useFakeTimers();
    vi.stubGlobal('Element', FakeElement);
    vi.stubGlobal('document', {
      addEventListener: (type: string, fn: (event: unknown) => void) => {
        if (type === 'click') listener = fn;
      },
      removeEventListener: () => undefined,
    });
    // Leaving the page is an assignment to `location.href`, so that is where the test watches.
    const location = {};
    Object.defineProperty(location, 'href', {
      get: () => 'https://shop.example/sale?gclid=Cj0K',
      set: (value: string) => {
        went = value;
      },
    });
    vi.stubGlobal('window', { location, open: () => null });
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  const tap = (href: string) => {
    const event = { type: 'click', target: new FakeElement(href), prevented: false, preventDefault() { this.prevented = true; } };
    listener!(event);
    return event;
  };

  it('holds the tap and leaves with the click id once it arrives', async () => {
    let click: CarriedClick | null = null;
    let answer!: () => void;
    const recording = new Promise<void>((resolve) => (answer = resolve));
    watchStoreLinks(() => click, () => recording);

    const event = tap('https://play.google.com/store/apps/details?id=com.example');
    expect(event.prevented).toBe(true);
    expect(went).toBeNull();

    click = CLICK;
    answer();
    await vi.advanceTimersByTimeAsync(0);
    expect(went).toContain('referrer=');
    expect(decodeURIComponent(went!)).toContain('clk_abc12345');
  });

  it('gives up after 1.2 seconds and goes anyway — the install is what they came for', async () => {
    watchStoreLinks(() => null, () => new Promise(() => undefined));
    tap('https://play.google.com/store/apps/details?id=com.example');
    await vi.advanceTimersByTimeAsync(1199);
    expect(went).toBeNull();
    await vi.advanceTimersByTimeAsync(1);
    expect(went).toBe('https://play.google.com/store/apps/details?id=com.example');
  });

  it('never holds a link that is not a store', () => {
    watchStoreLinks(() => null, () => new Promise(() => undefined));
    expect(tap('https://shop.example/pricing').prevented).toBe(false);
  });

  /*
   * An ordinary visit — nobody sent this person, they read the site and decided — proves one thing when
   * they tap "Get the app", and nothing before it. So the tap is what asks for a click id, and only a
   * store link asks: a page view that recorded a click would be claiming the website sent somebody
   * somewhere it did not.
   */
  it('asks for a click id when a store tap has nothing to carry, and carries what comes back', async () => {
    let click: CarriedClick | null = null;
    const asked: boolean[] = [];
    let answer!: () => void;
    const recording = new Promise<void>((resolve) => (answer = resolve));
    watchStoreLinks(
      () => click,
      (storeTap) => {
        asked.push(storeTap);
        return storeTap ? recording : null;
      },
    );

    expect(tap('https://shop.example/pricing').prevented).toBe(false);
    expect(asked).toEqual([false]);

    const event = tap('https://play.google.com/store/apps/details?id=com.example');
    expect(asked).toEqual([false, true]);
    expect(event.prevented).toBe(true);

    click = CLICK;
    answer();
    await vi.advanceTimersByTimeAsync(0);
    expect(decodeURIComponent(went!)).toContain('clk_abc12345');
  });
});
