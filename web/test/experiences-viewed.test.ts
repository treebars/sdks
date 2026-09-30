import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { applyChanges, type WebChange, type WebExperienceWire } from '../src/experiences';
import { TreebarsWeb } from '../src/index';

/**
 * A variation is counted as seen when the page shows it, not when it is decided. A change can target an element the
 * page refuses to write into, such as one inside a form; the page then stays as the control has it, and counting the
 * variation there would credit it with a visitor who never saw it, and with their conversion.
 *
 * And the device rule is answered on the page with the touch-point count: an iPad's Macintosh User-Agent alone reads
 * as a Mac.
 */

function webStorage() {
  const map = new Map<string, string>();
  return {
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

/** Just enough of an element for `changeOutcome`: this suite has no DOM. */
class FakeElement {
  attributes = new Map<string, string>();
  textContent = '';
  /** What a text change's undo reads (`changeOutcome`); this suite's elements hold only text. */
  childNodes: unknown[] = [];
  parentElement: FakeElement | null = null;
  constructor(public localName: string) {}
  getAttribute(name: string) {
    return this.attributes.get(name) ?? null;
  }
  setAttribute(name: string, value: string) {
    this.attributes.set(name, value);
  }
  inside(parent: FakeElement): this {
    this.parentElement = parent;
    return this;
  }
}

/** A MutationObserver the test fires by hand: the page "drawing" is `redraw()`. */
class FakeObserver {
  static live: FakeObserver[] = [];
  connected = false;
  constructor(private readonly callback: () => void) {}
  observe() {
    this.connected = true;
    FakeObserver.live.push(this);
  }
  disconnect() {
    this.connected = false;
  }
  static redraw() {
    for (const observer of FakeObserver.live) if (observer.connected) observer.callback();
  }
}

const EXPERIENCE_ID = '6a0c1f4e-2b7d-4c9a-8e31-5f2d7b9c4a10';

function experience(variation: { id: string; control?: boolean; changes: WebChange[] }, rules: WebExperienceWire['rules'] = []): WebExperienceWire {
  return {
    id: EXPERIENCE_ID,
    kind: 'visual',
    url_rules: [{ op: 'contains', value: '/checkout' }],
    url_match: 'all',
    rules,
    variations: [{ weight: 100, ...variation }],
    goal_event: 'purchase',
    priority: 1,
  };
}

const IPAD = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15';

describe('experience_viewed on the page', () => {
  let local: ReturnType<typeof webStorage>;
  let elements: Record<string, FakeElement[]>;
  let sdk: TreebarsWeb | null;

  function stubPage(options: { userAgent?: string; maxTouchPoints?: number } = {}) {
    vi.stubGlobal('navigator', { userAgent: options.userAgent ?? 'vitest', language: 'en-GB', sendBeacon: () => true, maxTouchPoints: options.maxTouchPoints ?? 0 });
  }

  beforeEach(() => {
    local = webStorage();
    sdk = null;
    FakeObserver.live = [];
    const form = new FakeElement('form');
    elements = {
      h1: [new FakeElement('h1')],
      '#card': [new FakeElement('input').inside(form)],
      '#cta': [new FakeElement('button')],
    };
    vi.stubGlobal('localStorage', local);
    vi.stubGlobal('sessionStorage', webStorage());
    stubPage();
    vi.stubGlobal('MutationObserver', FakeObserver);
    vi.stubGlobal(
      'document',
      Object.assign(new EventTarget(), {
        visibilityState: 'visible',
        title: 'Checkout',
        referrer: '',
        cookie: '',
        readyState: 'complete',
        documentElement: {},
        getElementById: () => null,
        querySelectorAll: (selector: string) => elements[selector] ?? [],
        querySelector: (selector: string) => elements[selector]?.[0] ?? null,
      }),
    );
    const location = { href: 'https://shop.test/checkout', pathname: '/checkout', search: '', origin: 'https://shop.test', hostname: 'shop.test', protocol: 'https:', replace: vi.fn() };
    vi.stubGlobal('location', location);
    vi.stubGlobal('window', Object.assign(new EventTarget(), { screen: { width: 1024, height: 1366 }, devicePixelRatio: 2, location }));
  });

  afterEach(() => {
    sdk?.shutdown();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
    vi.useRealTimers();
  });

  async function open(wire: WebExperienceWire) {
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string) =>
        new URL(url).pathname === '/v1/experiences'
          ? Response.json({ experiences: [wire] })
          : Response.json({ accepted: 1, messages: [], notifications: [], unread_count: 0, server_time: 'now' }),
      ),
    );
    sdk = new TreebarsWeb();
    const track = vi.spyOn(sdk, 'track');
    sdk.init({ writeKey: 'pk_live_viewed', backendUrl: 'https://ingest.test', autoPageViews: false, experiences: true, flushIntervalMs: 60 * 60 * 1000 });
    await vi.waitFor(() => expect((sdk as unknown as { experienceList: unknown }).experienceList).toEqual([wire]), { timeout: 3000, interval: 10 });
    const viewed = () => track.mock.calls.filter(([name]) => name === 'experience_viewed');
    const exposures = () => JSON.parse(local.getItem('treebars.experiences.v1') ?? '{}') as Record<string, unknown>;
    return { viewed, exposures };
  }

  it('records no view for a variation whose only change is inside a form', async () => {
    const { viewed, exposures } = await open(experience({ id: 'b', changes: [{ op: 'attr', selector: '#card', name: 'placeholder', value: 'Card' }] }));
    expect(elements['#card']![0]!.attributes.size).toBe(0);
    expect(viewed()).toEqual([]);
    expect(exposures()).toEqual({});
  });

  it('records no view when the rest of the variation only counts clicks', async () => {
    const { viewed, exposures } = await open(
      experience({ id: 'b', changes: [{ op: 'attr', selector: '#card', name: 'placeholder', value: 'Card' }, { op: 'track_click', selector: '#cta', name: 'Pay' }] }),
    );
    expect(viewed()).toEqual([]);
    expect(exposures()).toEqual({});
  });

  it('records one view when at least one change lands', async () => {
    const { viewed, exposures } = await open(
      experience({ id: 'b', changes: [{ op: 'attr', selector: '#card', name: 'placeholder', value: 'Card' }, { op: 'text', selector: 'h1', value: 'Pay in one step' }] }),
    );
    expect(elements.h1![0]!.textContent).toBe('Pay in one step');
    expect(viewed()).toEqual([['experience_viewed', { experience_id: EXPERIENCE_ID, variation_id: 'b' }]]);
    expect(exposures()).toEqual({ [EXPERIENCE_ID]: { variation_id: 'b', goal_event: 'purchase' } });
  });

  it('records the control, which has nothing to change', async () => {
    const { viewed, exposures } = await open(experience({ id: 'a', control: true, changes: [] }));
    expect(viewed()).toEqual([['experience_viewed', { experience_id: EXPERIENCE_ID, variation_id: 'a' }]]);
    expect(Object.keys(exposures())).toEqual([EXPERIENCE_ID]);
  });

  it('records the view when a late change lands as the page draws, once', async () => {
    const late = elements.h1!;
    elements.h1 = [];
    const { viewed, exposures } = await open(experience({ id: 'b', changes: [{ op: 'text', selector: 'h1', value: 'Later' }] }));
    expect(viewed()).toEqual([]);
    elements.h1 = late;
    FakeObserver.redraw();
    FakeObserver.redraw();
    expect(late[0]!.textContent).toBe('Later');
    expect(viewed()).toEqual([['experience_viewed', { experience_id: EXPERIENCE_ID, variation_id: 'b' }]]);
    expect(Object.keys(exposures())).toEqual([EXPERIENCE_ID]);
    // Asked again on the same page — who is reading changed — the change is already there and is not a second view.
    sdk!.identify('user_7');
    expect(viewed()).toHaveLength(1);
  });

  it('decides an iPad’s Macintosh User-Agent as a tablet from the page’s touch points', async () => {
    stubPage({ userAgent: IPAD, maxTouchPoints: 5 });
    const tabletOnly = experience({ id: 'b', changes: [] }, [{ kind: 'device', devices: ['tablet'] }]);
    const { viewed } = await open(tabletOnly);
    expect(viewed()).toEqual([['experience_viewed', { experience_id: EXPERIENCE_ID, variation_id: 'b' }]]);
  });

  it('reads the same User-Agent with no touch points as a Mac', async () => {
    stubPage({ userAgent: IPAD, maxTouchPoints: 0 });
    const { viewed } = await open(experience({ id: 'b', changes: [] }, [{ kind: 'device', devices: ['tablet'] }]));
    expect(viewed()).toEqual([]);
  });
});

describe('applyChanges', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  it('reports a change that lands inside the window, and never one that arrives after it closes', () => {
    vi.useFakeTimers();
    FakeObserver.live = [];
    const h1 = new FakeElement('h1');
    const present: Record<string, FakeElement[]> = {};
    vi.stubGlobal('MutationObserver', FakeObserver);
    vi.stubGlobal('document', { documentElement: {}, querySelectorAll: (selector: string) => present[selector] ?? [] });
    const applied: number[] = [];
    applyChanges(
      [{ op: 'track_click', selector: '#cta', name: 'Pay' }, { op: 'text', selector: 'h1', value: 'Too late' }, { op: 'text', selector: 'h2', value: 'In time' }],
      5000,
      (index) => applied.push(index),
    );
    expect(applied).toEqual([]);
    vi.advanceTimersByTime(1000);
    present.h2 = [new FakeElement('h2')];
    FakeObserver.redraw();
    expect(applied).toEqual([2]);
    vi.advanceTimersByTime(4000);
    present.h1 = [h1];
    FakeObserver.redraw();
    expect(applied).toEqual([2]);
    expect(h1.textContent).toBe('');
  });
});
