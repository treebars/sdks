/**
 * Browser device dimensions.
 *
 * This module is where the web SDK's privacy posture is decided, so the rules are worth
 * stating outright. The device id in ./storage is a first-party random value and stays
 * that way; nothing here feeds it. What is collected is deliberately coarse: a browser
 * family and its *major* version, an OS name with no version, and a screen size rounded
 * into buckets. That is enough to answer "is Safari converting worse than Chrome" and
 * far too little to distinguish two visitors on the same platform.
 *
 * Specifically not collected: the raw `navigator.userAgent` string, exact screen or
 * window dimensions, installed fonts or plugins, canvas or WebGL signals, hardware
 * concurrency, and device memory. Those are high-entropy values that could tell one
 * browser from another, and none of them answer a product question the coarse values do not.
 *
 * `app_id` is the one value here that is not about the client at all: it is the page's
 * own origin, which the browser already sends as a header on the same request, so it adds
 * nothing a server did not have. Origin only — the path and query are a customer's data,
 * not a fact about the visitor.
 *
 * `navigator.userAgentData` is preferred where it exists because the browser hands over
 * exactly these low-entropy fields by design; the userAgent parse is a fallback for
 * Safari and Firefox, and it reads only the two tokens it needs.
 */

import { FNV_OFFSET_BASIS, FNV_PRIME } from './generated/constants';

export interface WebDeviceDimensions {
  platform_type: 'web';
  os_name?: string;
  device_manufacturer?: string;
  device_type?: string;
  locale?: string;
  timezone?: string;
  network_type?: string;
}

export interface WebDeviceContext extends WebDeviceDimensions {
  screen_width?: number;
  screen_height?: number;
  screen_scale?: number;
  /**
   * The page's origin, standing in for an application id.
   *
   * The three mobile SDKs report a bundle id or a package name — a value Apple or Google
   * issued for one registered app. A web page has no such thing, so this is the closest
   * honest answer to "which app is this", and it is a URL rather than an issued
   * identifier. **A breakdown by `app_id` across a project running both mixes two kinds
   * of value**; a row that looks like a malformed bundle id is a web row.
   *
   * It adds no entropy: the browser already sends this origin as a header on the same
   * request. Origin only — never the path or the query, which carry a customer's own
   * data and are not a fact about the client.
   */
  app_id?: string;
}

interface UserAgentData {
  brands?: { brand: string; version: string }[];
  mobile?: boolean;
  platform?: string;
}

function userAgentData(): UserAgentData | undefined {
  return (navigator as Navigator & { userAgentData?: UserAgentData }).userAgentData;
}

/**
 * The browser's family and major version, e.g. `Chrome 131`.
 *
 * Reported as `device_manufacturer` because that is the column a breakdown by vendor
 * already reads on mobile, and "who made the client" is the same question in both cases.
 * The major version only: a full version string is high-entropy and nothing asks it.
 */
function browserName(): string | undefined {
  if (typeof navigator === 'undefined') return undefined;

  const data = userAgentData();
  if (data?.brands?.length) {
    // Chromium ships deliberate junk entries ("Not_A Brand") to stop naive parsing, so
    // the real browser is whichever brand is not one of those.
    const brand = data.brands.find((b) => !/not.?a.?brand/i.test(b.brand)) ?? data.brands[0];
    if (brand) return `${brand.brand} ${brand.version.split('.')[0]}`;
  }

  const ua = navigator.userAgent;
  if (!ua) return undefined;

  // Ordered because every browser's UA claims to be several others. Edge before Chrome,
  // Chrome before Safari.
  const patterns: [string, RegExp][] = [
    ['Edge', /Edg(?:e|A|iOS)?\/(\d+)/],
    ['Opera', /OPR\/(\d+)/],
    ['Firefox', /Firefox\/(\d+)/],
    ['Chrome', /Chrome\/(\d+)/],
    ['Safari', /Version\/(\d+).*Safari/],
  ];

  for (const [name, pattern] of patterns) {
    const match = pattern.exec(ua);
    if (match) return `${name} ${match[1]}`;
  }
  return undefined;
}

function osName(): string | undefined {
  if (typeof navigator === 'undefined') return undefined;

  const platform = userAgentData()?.platform;
  if (platform) return platform;

  const ua = navigator.userAgent ?? '';
  if (/iPhone|iPad|iPod/.test(ua)) return 'iOS';
  if (/Android/.test(ua)) return 'Android';
  if (/Mac OS X/.test(ua)) return 'macOS';
  if (/Windows/.test(ua)) return 'Windows';
  if (/Linux/.test(ua)) return 'Linux';
  return undefined;
}

function deviceType(): string | undefined {
  if (typeof navigator === 'undefined') return undefined;

  const data = userAgentData();
  if (typeof data?.mobile === 'boolean') return data.mobile ? 'phone' : 'desktop';

  const ua = navigator.userAgent ?? '';
  if (/iPad|Tablet/.test(ua)) return 'tablet';
  if (/Mobi|Android/.test(ua)) return 'phone';
  return 'desktop';
}

function networkType(): string | undefined {
  const connection = (navigator as Navigator & { connection?: { effectiveType?: string } }).connection;
  return connection?.effectiveType;
}

/**
 * Screen size rounded down to the nearest 100px.
 *
 * Exact screen dimensions are high-entropy — they help tell one browser from another —
 * and no product question needs them: "how many users are on a small screen" survives
 * the rounding intact.
 */
function bucket(value: number): number {
  return Math.max(0, Math.floor(value / 100) * 100);
}

let cached: WebDeviceDimensions | null = null;

export function getWebDeviceDimensions(): WebDeviceDimensions {
  if (cached) return cached;

  cached = {
    platform_type: 'web',
    os_name: osName(),
    device_manufacturer: browserName(),
    device_type: deviceType(),
    locale: typeof navigator !== 'undefined' ? navigator.language : undefined,
    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    network_type: typeof navigator !== 'undefined' ? networkType() : undefined,
  };

  return cached;
}

export function getWebDeviceContext(): WebDeviceContext {
  const screen = typeof window !== 'undefined' ? window.screen : undefined;

  return {
    ...getWebDeviceDimensions(),
    screen_width: screen ? bucket(screen.width) : undefined,
    screen_height: screen ? bucket(screen.height) : undefined,
    screen_scale: typeof window !== 'undefined' ? window.devicePixelRatio : undefined,
    app_id: typeof location !== 'undefined' ? location.origin : undefined,
  };
}

/**
 * A stable 32-bit FNV-1a over the sorted context. Deliberately identical to the
 * implementation in the other Treebars SDKs so a device's hash means the same thing
 * everywhere.
 */
export function hashDeviceContext(context: WebDeviceContext): string {
  const canonical = Object.keys(context)
    .sort()
    .map((key) => `${key}=${String((context as unknown as Record<string, unknown>)[key] ?? '')}`)
    .join(' ');

  let hash = FNV_OFFSET_BASIS;
  for (let i = 0; i < canonical.length; i += 1) {
    hash ^= canonical.charCodeAt(i);
    hash = Math.imul(hash, FNV_PRIME) >>> 0;
  }
  return hash.toString(16).padStart(8, '0');
}

/**
 * What the SDK already knows about a visitor before the page has said anything.
 *
 * So a profile does not arrive carrying nothing but an id: locale and timezone are already
 * in the dimensions, and they are two of the keys the dashboard's profile view shows.
 *
 * Merged *under* whatever the page passed, never over it: a site that states its own
 * `locale` is making a claim about the person's preference, which outranks the browser's.
 * Everything here is from the same coarse set described at the top of this file.
 */
export function defaultUserAttributes(firstSeenAt?: string): Record<string, string> {
  const dimensions = getWebDeviceDimensions();

  const attributes: Record<string, string> = { platform: dimensions.platform_type };
  if (dimensions.locale) attributes.locale = dimensions.locale;
  if (dimensions.timezone) attributes.timezone = dimensions.timezone;
  if (firstSeenAt) attributes.first_seen_at = firstSeenAt;

  return attributes;
}
