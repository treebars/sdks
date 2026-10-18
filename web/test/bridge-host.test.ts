import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { hostMarkup, type MarkupHostOptions } from '../src/bridge-host';
import { FakeNode, install } from './fake-dom';

/**
 * The frame an HTML message runs in, and the bridge between its `treebars` and the SDK. The frame is sandboxed, so an
 * origin proves nothing: a call is taken only from this frame's window and with this display's nonce. A frame whose
 * script a site's policy refused is drawn again from Treebars, and one refused there too is reported, never shown.
 */

const sent = (frame: FakeNode) => (frame as unknown as { posted: unknown[] }).posted.map((data) => JSON.parse(String(data)) as Record<string, unknown>);

let parent: FakeNode;
let messageListeners: Array<(event: { source: unknown; data: unknown }) => void>;

beforeEach(() => {
  vi.useFakeTimers();
  install();
  parent = new FakeNode('div');
  messageListeners = [];
  // An iframe has a window of its own that the host posts to; each frame here gets one that records what it was sent.
  const create = (document as unknown as { createElement: (tag: string) => FakeNode }).createElement;
  (document as unknown as { createElement: (tag: string) => FakeNode }).createElement = (tag: string) => {
    const node = create(tag);
    if (tag === 'iframe') {
      const posted: unknown[] = [];
      Object.assign(node, { posted, contentWindow: { postMessage: (data: unknown) => posted.push(data) } });
    }
    return node;
  };
  vi.stubGlobal('window', {
    addEventListener: (type: string, listener: (event: { source: unknown; data: unknown }) => void) => type === 'message' && messageListeners.push(listener),
    removeEventListener: (type: string, listener: (event: { source: unknown; data: unknown }) => void) => {
      if (type === 'message') messageListeners = messageListeners.filter((one) => one !== listener);
    },
  });
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

function host(over: Partial<MarkupHostOptions> = {}) {
  const seen: string[] = [];
  const options: MarkupHostOptions = {
    html: '<p>Hello</p>',
    title: 'Autumn sale',
    parent: parent as never,
    frameUrl: null,
    mode: 'srcdoc',
    handle: (method, args) => (seen.push(`handle ${method} ${JSON.stringify(args)}`), { ok: true, method }),
    onReady: (mode) => seen.push(`ready ${mode}`),
    onHeight: (height) => seen.push(`height ${height}`),
    onBlocked: () => seen.push('blocked'),
    onGone: () => seen.push('gone'),
    onKey: (key) => seen.push(`key ${key}`),
    orientation: null,
    ...over,
  };
  const markup = hostMarkup(options);
  const frame = () => markup.frame as unknown as FakeNode;
  const nonce = () => /"nonce":"([0-9a-f]+)"/.exec(frame().getAttribute('srcdoc') ?? '')?.[1] ?? 'unknown';
  /** A call from the page inside the frame, as its shim posts it. */
  const call = (method: string, args: unknown[] = [], id = 1, from: unknown = frame().contentWindow, tb = nonce()) => {
    for (const listener of messageListeners) listener({ source: from, data: JSON.stringify({ tb, id, method, args }) });
  };
  return { markup, frame, nonce, call, seen };
}

const settle = async () => {
  for (let turn = 0; turn < 10; turn += 1) await Promise.resolve();
};

describe('the frame', () => {
  it('is sandboxed, named, and handed the message with this display’s nonce', () => {
    const { frame, nonce } = host();
    expect(parent.children).toEqual([frame()]);
    expect(frame().getAttribute('sandbox')).toBe('allow-scripts');
    expect(frame().getAttribute('title')).toBe('Autumn sale');
    expect(frame().getAttribute('srcdoc')).toContain('<p>Hello</p>');
    expect(nonce()).toMatch(/^[0-9a-f]{32}$/);
  });

  it('takes a call only from its own window, with its own nonce', async () => {
    const { call, seen, frame } = host();
    call('_ready', [], 1, { someone: 'else' });
    call('_ready', [], 1, frame().contentWindow, 'f'.repeat(32));
    expect(seen).toEqual([]);
    call('_ready');
    call('_ready', [], 2);
    expect(seen).toEqual(['ready srcdoc']);
    expect(sent(frame()).map((reply) => reply.reply)).toEqual([1, 2]);
  });

  it('passes on the content’s height and the keys the page should hear, and refuses a height that is not one', () => {
    const { call, seen } = host();
    call('resize', [312.5]);
    call('resize', [-4]);
    call('resize', ['tall']);
    call('_key', ['Escape']);
    expect(seen).toEqual(['height 312.5', 'key Escape']);
  });

  it('hands a host method to the SDK and answers with what it said; an unknown one and a failure still answer', async () => {
    const { call, seen, frame, markup } = host({
      handle: (method) => {
        if (method === 'trackRating') throw new Error('no');
        return { ok: true, method };
      },
    });
    call('trackClick', [1], 7);
    call('trackRating', [5], 8);
    call('requestStoreReview', [], 9);
    call('noSuchMethod', [], 10);
    await settle();
    const replies = Object.fromEntries(sent(frame()).map((reply) => [reply.reply, reply.result]));
    expect(replies[7]).toEqual({ ok: true, method: 'trackClick' });
    expect(replies[8]).toEqual({ ok: false, reason: 'error' });
    expect(replies[10]).toEqual({ ok: false, reason: 'unsupported' });
    expect(seen).toEqual([]);
    markup.destroy();
  });
});

describe('a site whose policy stops the message', () => {
  it('draws it again from Treebars when the shim does not run, and hands that frame the message', () => {
    const { frame, seen, call } = host({ frameUrl: 'https://frame.treebars.test/in-app' });
    const first = frame();
    first.fire('load');
    vi.advanceTimersByTime(400);
    expect(frame()).not.toBe(first);
    expect(frame().src).toBe('https://frame.treebars.test/in-app');
    expect(parent.children).toEqual([frame()]);
    frame().fire('load');
    const init = sent(frame())[0]!;
    expect(String(init.init)).toContain('<p>Hello</p>');
    call('_ready', [], 1, frame().contentWindow, String(init.tb));
    expect(seen).toEqual(['ready hosted']);
  });

  it('reports it blocked when there is no Treebars frame, or that one says nothing either', () => {
    const plain = host();
    plain.frame().fire('load');
    vi.advanceTimersByTime(400);
    expect(plain.seen).toEqual(['blocked']);

    const hosted = host({ frameUrl: 'https://frame.treebars.test/in-app', mode: 'hosted' });
    expect(hosted.frame().src).toBe('https://frame.treebars.test/in-app');
    vi.advanceTimersByTime(3000);
    expect(hosted.seen).toEqual(['blocked']);
  });

  it('a frame that ran is never reported blocked; one the page navigates away after is gone', () => {
    const { frame, call, seen } = host();
    frame().fire('load');
    call('_ready');
    vi.advanceTimersByTime(1000);
    frame().fire('load');
    expect(seen).toEqual(['ready srcdoc', 'gone']);
  });
});

describe('focus and taking it down', () => {
  it('asks the shim to take focus, and once taken down hears nothing more', () => {
    const { markup, frame, call, seen } = host();
    call('_ready');
    const shown = frame();
    markup.focus();
    expect(shown.focused).toBe(true);
    expect(sent(shown).some((message) => message.focus === true)).toBe(true);
    markup.destroy();
    expect(parent.children).toEqual([]);
    expect(messageListeners).toEqual([]);
    call('resize', [100], 3, shown.contentWindow);
    expect(seen).toEqual(['ready srcdoc']);
  });
});
