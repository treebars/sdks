import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import type { InAppMessage } from '../src/in-app';

/**
 * Nudges on the web: a slot of their own beside the one a modal takes, at most three on screen, outside the channel's
 * caps — neither waiting on them nor spending them — and each freeing only its own place. The drawing itself (the
 * stack per edge, the room check) is the built-in renderer's, stood in for here.
 */

const drawn = vi.hoisted(() => ({ views: [] as Array<{ id: string; dismiss: () => void; shown: () => void }> }));

vi.mock('../src/on-site', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../src/on-site')>()),
  renderBuiltIn: (view: { message: InAppMessage; onDismiss: () => void; onShown?: () => void }) => {
    drawn.views.push({ id: view.message.delivery_id, dismiss: () => view.onDismiss(), shown: () => view.onShown?.() });
    view.onShown?.();
    return () => undefined;
  },
}));

const { TreebarsWeb } = await import('../src/index');

function memoryStorage(): Storage {
  const map = new Map<string, string>();
  return {
    get length() {
      return map.size;
    },
    clear: () => map.clear(),
    getItem: (key) => map.get(key) ?? null,
    key: (index) => [...map.keys()][index] ?? null,
    removeItem: (key) => void map.delete(key),
    setItem: (key, value) => void map.set(key, String(value)),
  };
}

const message = (id: string, layout: 'nudge' | 'modal', priority = 5): InAppMessage => ({
  delivery_id: id,
  campaign_id: `9f0c7a52-1111-4a55-8a55-00000000000${id.length}`,
  created_at: '2026-09-15T00:00:00.000Z',
  expires_at: null,
  content: {
    title: id,
    in_app: { surface: 'overlay', layout, body_mode: 'html', html: `<p>${id}</p>`, position: 'bottom', trigger: { kind: 'event', event_name: 'product_view' }, display: { priority } },
  } as never,
});

describe('nudges on a page', () => {
  let tracked: Array<{ name: string; properties: Record<string, unknown> }>;
  let sdk: InstanceType<typeof TreebarsWeb>;
  let queue: InAppMessage[];
  // A channel that allows one message a day with a long gap: a nudge must neither wait on it nor spend it.
  const policy = { max_per_day: 1, min_gap_seconds: 3600, messages_shown_today: 0, last_shown_at: null, max_per_session: 1, trigger_max_per_day: null };

  beforeEach(async () => {
    drawn.views = [];
    vi.useFakeTimers({ now: Date.parse('2026-09-15T12:00:00.000Z') });
    vi.stubGlobal('localStorage', memoryStorage());
    vi.stubGlobal('sessionStorage', memoryStorage());
    vi.stubGlobal('fetch', vi.fn(async (url: string) => (new URL(url).pathname === '/v1/in-app' ? Response.json({ messages: queue, policy, server_time: 'now' }) : new Response('{}', { status: 200 }))));
    vi.stubGlobal('CompressionStream', undefined);
    vi.stubGlobal('navigator', { userAgent: 'vitest', language: 'en-GB', sendBeacon: () => true });
    vi.stubGlobal('document', Object.assign(new EventTarget(), { visibilityState: 'visible', title: 'Product', referrer: '' }));
    vi.stubGlobal('window', Object.assign(new EventTarget(), { screen: { width: 1280, height: 800 }, devicePixelRatio: 1, location: { pathname: '/', href: 'https://shop.test/', origin: 'https://shop.test' } }));
    vi.stubGlobal('location', { href: 'https://shop.test/', assign: vi.fn() });
    tracked = [];
    sdk = new TreebarsWeb();
    sdk.init({ writeKey: 'pk_test_nudges', backendUrl: 'https://ingest.test', autoPageViews: false, autoLifecycle: false, flushIntervalMs: 60 * 60 * 1000 });
    const track = sdk.track.bind(sdk);
    vi.spyOn(sdk, 'track').mockImplementation((name, properties = {}) => {
      tracked.push({ name, properties });
      track(name, properties);
    });
    sdk.setInAppRenderer('builtin');
  });

  afterEach(() => {
    sdk.shutdown();
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it('draws beside a modal, three at most, outside the caps and without spending them', async () => {
    queue = [message('modal', 'modal', 1), message('n1', 'nudge'), message('n22', 'nudge'), message('n333', 'nudge'), message('n4444', 'nudge')];
    await sdk.syncInAppMessages();
    sdk.track('product_view');
    // Three nudges and the modal: the modal's slot and the nudges' are separate, and the fourth nudge waits.
    expect(drawn.views.map((view) => view.id).sort()).toEqual(['modal', 'n1', 'n22', 'n333']);
    // The modal spent the day's one allowance and the gap; the nudges spent neither, so the next event is still theirs.
    drawn.views.find((view) => view.id === 'n1')!.dismiss();
    sdk.track('product_view');
    expect(drawn.views.map((view) => view.id)).toContain('n4444');
    // …and a dismissed nudge is done, not drawn again.
    expect(drawn.views.filter((view) => view.id === 'n1')).toHaveLength(1);
  });

  it('frees only its own place: a nudge answered does not free the screen a modal holds', async () => {
    // Highest priority first: `modal` is drawn, `second` is the one that has to wait for the screen.
    queue = [message('modal', 'modal', 9), message('n1', 'nudge'), message('second', 'modal', 1)];
    await sdk.syncInAppMessages();
    sdk.track('product_view');
    drawn.views.find((view) => view.id === 'n1')!.dismiss();
    sdk.track('product_view');
    // The first modal is still on screen, so the second waits — whatever the nudge did.
    expect(drawn.views.map((view) => view.id)).toEqual(['n1', 'modal']);
  });
});
