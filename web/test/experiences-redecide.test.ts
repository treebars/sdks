import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import type { WebExperienceWire } from '../src/experiences';
import { TreebarsWeb } from '../src/index';

/**
 * Signing in mid-page decides the page again (`identify`, `reset`), and a split-URL test does not move the visitor when
 * it does. So a variation that now matches is one the visitor never sees, and it is not counted: tracking
 * `experience_viewed` or storing the exposure with its goal would credit a conversion made on the control page to
 * variation B.
 */

function webStorage() {
  const map = new Map<string, string>();
  return {
    map,
    get length() {
      return map.size;
    },
    key: (index: number) => [...map.keys()][index] ?? null,
    getItem: (key: string) => map.get(key) ?? null,
    setItem: (key: string, value: string) => void map.set(key, value),
    removeItem: (key: string) => void map.delete(key),
    clear: () => map.clear(),
  };
}

const splitTest = (control: boolean): WebExperienceWire => ({
  id: '0f5a3c2e-7b1d-4e8a-9c6f-2d4b8e1a7c30',
  kind: 'split_url',
  url_rules: [{ op: 'contains', value: '/pricing' }],
  url_match: 'all',
  rules: [{ kind: 'identified', value: true }],
  variations: [control ? { id: 'a', weight: 100, control: true, changes: [] } : { id: 'b', weight: 100, changes: [], redirect_url: '/pricing-b' }],
  goal_event: 'signup',
  priority: 5,
});

describe('a re-decision after signing in', () => {
  let local: ReturnType<typeof webStorage>;
  let replace: ReturnType<typeof vi.fn>;
  let sdk: TreebarsWeb | null;

  beforeEach(() => {
    local = webStorage();
    replace = vi.fn();
    sdk = null;
    vi.stubGlobal('localStorage', local);
    vi.stubGlobal('sessionStorage', webStorage());
    vi.stubGlobal('navigator', { userAgent: 'vitest', language: 'en-GB', sendBeacon: () => true });
    vi.stubGlobal('document', Object.assign(new EventTarget(), { visibilityState: 'visible', title: 'Pricing', referrer: '', cookie: '', readyState: 'complete', getElementById: () => null }));
    const location = { href: 'https://shop.test/pricing', pathname: '/pricing', search: '', origin: 'https://shop.test', hostname: 'shop.test', protocol: 'https:', replace };
    vi.stubGlobal('location', location);
    vi.stubGlobal('window', Object.assign(new EventTarget(), { screen: { width: 1280, height: 800 }, devicePixelRatio: 1, location }));
  });

  afterEach(() => {
    sdk?.shutdown();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  async function signInOn(experience: WebExperienceWire) {
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string) =>
        new URL(url).pathname === '/v1/experiences'
          ? Response.json({ experiences: [experience] })
          : Response.json({ accepted: 1, messages: [], notifications: [], unread_count: 0, server_time: 'now' }),
      ),
    );
    sdk = new TreebarsWeb();
    const track = vi.spyOn(sdk, 'track');
    sdk.init({ writeKey: 'pk_live_split', backendUrl: 'https://ingest.test', autoPageViews: false, experiences: true, flushIntervalMs: 60 * 60 * 1000 });
    // The experiences have to be on hand before signing in, or the re-decision has nothing to decide and passes vacuously.
    await vi.waitFor(() => expect((sdk as unknown as { experienceList: unknown }).experienceList).toEqual([experience]), { timeout: 3000, interval: 10 });
    // Signed out, the rule does not match: nothing is decided yet.
    expect(track.mock.calls.filter(([name]) => name === 'experience_viewed')).toEqual([]);
    sdk.identify('user_42');
    const viewed = track.mock.calls.filter(([name]) => name === 'experience_viewed');
    return { viewed, exposures: JSON.parse(local.getItem('treebars.experiences.v1') ?? '{}') as Record<string, unknown> };
  }

  it('neither moves the visitor to a split-URL variation nor counts it', async () => {
    const { viewed, exposures } = await signInOn(splitTest(false));
    expect(replace).not.toHaveBeenCalled();
    expect(viewed).toEqual([]);
    expect(exposures).toEqual({});
  });

  it('still counts the control arm, whose page is the one the visitor is on', async () => {
    const { viewed, exposures } = await signInOn(splitTest(true));
    expect(replace).not.toHaveBeenCalled();
    expect(viewed).toEqual([['experience_viewed', { experience_id: splitTest(true).id, variation_id: 'a' }]]);
    expect(Object.keys(exposures)).toEqual([splitTest(true).id]);
  });
});
