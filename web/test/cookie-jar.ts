/**
 * A browser's cookie jar, for tests: enough of one to tell a site's subdomains from another site.
 *
 * The fakes the other suites use keep a list of strings, which is all they need — they ask whether a cookie was
 * written. A cookie shared across subdomains is a claim about DOMAINS, so this one models them: a cookie belongs to a
 * domain, a page is shown the cookies of its own host and of each parent domain one was set on, and a page may set one
 * on its own host or on a parent of it, never on a public suffix and never on somebody else's domain.
 *
 * One jar is one browser. Two hostnames under one parent share what was set on the parent; two unrelated ones share
 * nothing, because neither can name a domain the other is under.
 */

export interface StoredCookie {
  name: string;
  value: string;
  /** The host for a host-only cookie; the `Domain` attribute otherwise. */
  domain: string;
  /** True when no `Domain` was given, or the one given was only the page's own host on a public suffix or an address. */
  hostOnly: boolean;
  path: string;
  secure: boolean;
  sameSite: string | null;
  /** Epoch milliseconds, by the test's clock. */
  expiresAt: number;
}

const isAddress = (host: string): boolean => /^\d{1,3}(\.\d{1,3}){3}$/.test(host);

export class CookieJar {
  private stored: StoredCookie[] = [];
  /** Every string a page assigned to `document.cookie`, in order, refused ones included. */
  readonly writes: Array<{ host: string; text: string }> = [];

  /** The suffixes this browser refuses a cookie on. A real browser has the whole public suffix list. */
  constructor(private readonly publicSuffixes: readonly string[] = ['com', 'test', 'uk', 'co.uk', 'io', 'github.io']) {}

  /** What assigning `text` to `document.cookie` does on the page at `href`. */
  set(href: string, text: string): void {
    const url = new URL(href);
    const host = url.hostname;
    this.writes.push({ host, text });

    const [pair = '', ...rest] = text.split(';').map((part) => part.trim());
    const equals = pair.indexOf('=');
    if (equals < 1) return;
    const name = pair.slice(0, equals);
    const value = pair.slice(equals + 1);
    const attributes = new Map<string, string>();
    for (const attribute of rest) {
      const at = attribute.indexOf('=');
      attributes.set((at === -1 ? attribute : attribute.slice(0, at)).toLowerCase(), at === -1 ? '' : attribute.slice(at + 1));
    }

    let domain = host;
    let hostOnly = true;
    const asked = attributes.get('domain')?.replace(/^\./, '').toLowerCase();
    if (asked) {
      if (isAddress(host) || this.publicSuffixes.includes(asked)) {
        // A public suffix, or any domain at all on an address: refused, unless it is exactly the page's own host,
        // which a browser keeps for that host alone.
        if (asked !== host) return;
      } else if (host !== asked && !host.endsWith(`.${asked}`)) {
        // Not a domain this page is under.
        return;
      } else {
        domain = asked;
        hostOnly = false;
      }
    }
    // A plain-http page cannot set a `Secure` cookie.
    const secure = attributes.has('secure');
    if (secure && url.protocol !== 'https:') return;

    const path = attributes.get('path') || '/';
    this.stored = this.stored.filter((cookie) => !(cookie.name === name && cookie.domain === domain && cookie.hostOnly === hostOnly && cookie.path === path));
    const maxAge = attributes.has('max-age') ? Number(attributes.get('max-age')) : null;
    if (maxAge !== null && !(maxAge > 0)) return;
    this.stored.push({
      name,
      value,
      domain,
      hostOnly,
      path,
      secure,
      sameSite: attributes.get('samesite') ?? null,
      expiresAt: maxAge === null ? Number.POSITIVE_INFINITY : Date.now() + maxAge * 1000,
    });
  }

  /** The cookies the page at `href` is shown, oldest first. */
  visible(href: string): StoredCookie[] {
    const url = new URL(href);
    const host = url.hostname;
    this.stored = this.stored.filter((cookie) => cookie.expiresAt > Date.now());
    return this.stored.filter(
      (cookie) =>
        (cookie.hostOnly ? host === cookie.domain : host === cookie.domain || host.endsWith(`.${cookie.domain}`)) &&
        (!cookie.secure || url.protocol === 'https:'),
    );
  }

  /** What reading `document.cookie` answers on the page at `href`. */
  get(href: string): string {
    return this.visible(href)
      .map((cookie) => `${cookie.name}=${cookie.value}`)
      .join('; ');
  }

  /** Every unexpired cookie of this name, wherever it is set. */
  named(name: string): StoredCookie[] {
    this.stored = this.stored.filter((cookie) => cookie.expiresAt > Date.now());
    return this.stored.filter((cookie) => cookie.name === name);
  }

  /** Every unexpired cookie in the jar. */
  all(): StoredCookie[] {
    this.stored = this.stored.filter((cookie) => cookie.expiresAt > Date.now());
    return [...this.stored];
  }

  /** Defines `cookie` on a stand-in `document` for the page at `href`. */
  attach<T extends object>(document: T, href: string): T {
    Object.defineProperty(document, 'cookie', {
      configurable: true,
      get: () => this.get(href),
      set: (text: string) => this.set(href, text),
    });
    return document;
  }
}
