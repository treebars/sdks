import { AD_CLICK_PARAMS } from './acquisition';
import { ACQUISITION } from './generated/constants';

/**
 * A page's address, as far as analytics needs it.
 *
 * The query and fragment of an address are where a site puts what it is handed: a password-reset
 * token, a magic-link code, an OAuth implicit grant (`#access_token=`), the email a form redirected
 * with. Sent whole with every page view, each would be stored for months after the link that minted
 * it had expired, and be one export or one shared board away from somebody it was never meant for.
 * The referrer carries the same risk one page later: after a reset page navigates to `/login`, the
 * login page's referrer is the reset URL, token and all.
 *
 * So what leaves the page is the origin and the path, the campaign labels and click ids an arrival is
 * credited by, and a hash router's route. A parameter somebody needs beyond those is named in
 * `pageUrlParams`, which is a decision that it is safe to keep for months. The path itself is sent as
 * it stands — it is the page — so a site that puts a secret in a path segment has to name its pages
 * with `page(name, { url })` and turn `autoPageViews` off.
 */

/** Kept on every address: what `/v1/web-click` and a report's campaign breakdown read. */
export const KEPT_URL_PARAMS: readonly string[] = [
  'utm_source',
  'utm_medium',
  'utm_campaign',
  'utm_term',
  'utm_content',
  'utm_id',
  ...AD_CLICK_PARAMS,
  ACQUISITION.clickIdParam,
];

/** The page's address with only the kept parameters, and no fragment but a hash router's route. */
export function analyticsUrl(href: string, extra: readonly string[] = []): string {
  let url: URL;
  try {
    url = new URL(href);
  } catch {
    return '';
  }
  const keep = new Set([...KEPT_URL_PARAMS, ...extra]);
  const kept = new URLSearchParams();
  url.searchParams.forEach((value, key) => {
    if (keep.has(key)) kept.append(key, value);
  });
  const query = kept.toString();
  return `${url.origin}${url.pathname}${query ? `?${query}` : ''}${hashRoute(url.hash)}`;
}

/**
 * The page before this one, as origin and path.
 *
 * Its query is somebody else's page's business — a search engine's terms, the previous page's
 * token — and a referrer is only ever grouped by where it came from.
 */
export function analyticsReferrer(referrer: string): string {
  if (!referrer) return '';
  try {
    const url = new URL(referrer);
    return `${url.origin}${url.pathname}`;
  } catch {
    return '';
  }
}

/**
 * `#/orders/42` or `#!/orders/42` is a page in a hash-routed app, so it stays — without its own query,
 * which carries what any query does. Every other fragment is an anchor or a token, and goes.
 */
function hashRoute(hash: string): string {
  return /^#!?\//.test(hash) ? hash.split('?')[0]! : '';
}
