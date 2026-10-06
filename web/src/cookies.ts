/**
 * First-party cookies that a site's subdomains share.
 *
 * `localStorage` belongs to one origin, so `example.com` and `app.example.com` each have their own. A cookie set on
 * the domain the two have in common is the one place a page can keep something every subdomain reads. Each value this
 * SDK keeps there goes through this file, so they all agree about which domain that is, and about how one is removed.
 *
 * Every function here answers rather than throws: a page with no document, a sandboxed frame, or a browser with
 * cookies turned off simply has no shared cookie.
 */

/**
 * Every value held under `name`. A list, because one name can be set at more than one domain, and a page is shown
 * each of them with nothing saying which is which.
 */
export function readCookieValues(name: string): string[] {
  try {
    const prefix = `${name}=`;
    return document.cookie
      .split(';')
      .map((part) => part.trim())
      .filter((part) => part.startsWith(prefix))
      .map((part) => part.slice(prefix.length));
  } catch {
    return [];
  }
}

const secureAttribute = (): string => (window.location.protocol === 'https:' ? '; Secure' : '');

/**
 * The widest domain this page may set a cookie on, or null when that is only its own host.
 *
 * Found by asking the browser rather than by reading the hostname. Candidates are tried from the shortest — the last
 * two labels, then three — and the first one the browser keeps a cookie on is the answer. A browser refuses a public
 * suffix, so `shop.example.co.uk` is refused `co.uk` and keeps `example.co.uk`, and a site on a suffix many unrelated
 * sites share, such as a hosting provider's, keeps nothing wider than itself. `localhost` has no wider domain at all.
 *
 * Asked with a cookie of its own, set for a moment and removed, under a name no other call uses. Writing the real
 * cookie and then looking for its value cannot tell a refusal from an acceptance once that value is already held from
 * an earlier visit — and the write meant to renew it would then stop at a domain that had refused it.
 */
function sharedCookieDomain(): string | null {
  const labels = window.location.hostname.split('.');
  const probe = `tbrs_probe_${crypto.getRandomValues(new Uint32Array(1))[0]!.toString(36)}`;
  const secure = secureAttribute();
  for (let take = 2; take <= labels.length; take += 1) {
    const domain = labels.slice(-take).join('.');
    document.cookie = `${probe}=1; Domain=${domain}; Max-Age=60; Path=/; SameSite=Lax${secure}`;
    const kept = readCookieValues(probe).includes('1');
    document.cookie = `${probe}=; Domain=${domain}; Max-Age=0; Path=/`;
    if (kept) return domain;
  }
  return null;
}

/**
 * Sets `name` to `value` for `maxAgeSeconds` on the widest domain the browser accepts, or on this host alone when
 * there is none wider. Writing it again renews its lifetime. Returns whether the browser kept it.
 *
 * `SameSite=Lax` and `Path=/` always, and `Secure` on an https page. The value is written as given, so a caller passes
 * only characters a cookie can hold.
 */
export function writeSharedCookie(name: string, value: string, maxAgeSeconds: number): boolean {
  try {
    const domain = sharedCookieDomain();
    const scope = domain ? `; Domain=${domain}` : '';
    document.cookie = `${name}=${value}${scope}; Max-Age=${maxAgeSeconds}; Path=/; SameSite=Lax${secureAttribute()}`;
    return readCookieValues(name).includes(value);
  } catch {
    return false;
  }
}

/**
 * Expires `name` everywhere `writeSharedCookie` could have set it: on each candidate domain, then on this host alone.
 * Every candidate rather than only today's answer, so a cookie an earlier visit set somewhere else goes too.
 */
export function expireSharedCookie(name: string): void {
  try {
    const labels = window.location.hostname.split('.');
    const expired = '; Max-Age=0; Path=/';
    for (let take = 2; take <= labels.length; take += 1) {
      document.cookie = `${name}=; Domain=${labels.slice(-take).join('.')}${expired}`;
    }
    document.cookie = `${name}=${expired}`;
  } catch {
    // No document, or cookies refused: nothing was set.
  }
}
