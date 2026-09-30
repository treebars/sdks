import { afterEach, describe, expect, it, vi } from 'vitest';

import { hostMarkup } from '../src/bridge-host';

/**
 * Which way the window is held: the frame's document is stamped with it, and a turn is told to the frame, whose shim
 * rewrites the rule — so a message drawn upright does not go on hiding its landscape half once the phone is held
 * sideways. What the shim then does with the message is tested with the shim, not here.
 */

class FakeFrame {
  attributes = new Map<string, string>();
  style = { cssText: '' };
  parentNode: unknown = null;
  posted: string[] = [];
  contentWindow = { postMessage: (text: string) => this.posted.push(text) };
  setAttribute(name: string, value: string) {
    this.attributes.set(name, value);
  }
  addEventListener() {}
  remove() {}
}

function held(portrait: boolean) {
  const listeners: (() => void)[] = [];
  const query = {
    get matches() {
      return portrait;
    },
    addEventListener: (_type: string, listener: () => void) => listeners.push(listener),
    removeEventListener: (_type: string, listener: () => void) => listeners.splice(listeners.indexOf(listener), 1),
  };
  const messages: ((event: { source: unknown; data: string }) => void)[] = [];
  vi.stubGlobal('window', {
    matchMedia: () => query,
    addEventListener: (type: string, listener: (event: { source: unknown; data: string }) => void) => type === 'message' && messages.push(listener),
    removeEventListener() {},
  });
  vi.stubGlobal('document', { createElement: () => new FakeFrame() });
  const parent = { appendChild: (frame: FakeFrame) => (created.push(frame), frame) };
  const created: FakeFrame[] = [];
  const host = hostMarkup({
    html: '<p data-tb-orientation="landscape">Wide</p>',
    title: 'Message',
    parent: parent as unknown as Node,
    frameUrl: null,
    mode: 'srcdoc',
    handle: () => ({ ok: true }),
    onReady() {},
    onHeight() {},
    onBlocked() {},
    onGone() {},
  });
  const frame = created[0]!;
  return {
    frame,
    host,
    listeners,
    turn(next: boolean) {
      portrait = next;
      for (const listener of [...listeners]) listener();
    },
    /** The shim says it is running, as the frame's page would. */
    ready() {
      const nonce = /"nonce":"([0-9a-f]+)"/.exec(frame.attributes.get('srcdoc') ?? '')![1];
      for (const listener of messages) listener({ source: frame.contentWindow, data: JSON.stringify({ tb: nonce, id: 1, method: '_ready', args: [] }) });
    },
  };
}

describe('the web host, as the window turns', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('stamps the way the window is held into the frame’s document', () => {
    const { frame } = held(true);
    expect(frame.attributes.get('srcdoc')).toContain('<style id="tb-orientation">[data-tb-orientation]:not([data-tb-orientation~="portrait"])');
  });

  const turns = (frame: FakeFrame) =>
    frame.posted.map((text) => JSON.parse(text) as { tb: string; orientation?: string }).filter((one) => one.orientation);

  it('tells the frame when the window turns, once per turn, with this display’s nonce', () => {
    const { frame, turn, ready } = held(true);
    ready();
    turn(false);
    turn(false);
    turn(true);
    const said = turns(frame);
    expect(said.map((one) => one.orientation)).toEqual(['landscape', 'portrait']);
    expect(frame.attributes.get('srcdoc')).toContain(`"nonce":"${said[0]!.tb}"`);
  });

  it('tells it a turn made while the frame was loading, once its shim is running', () => {
    const { frame, turn, ready } = held(true);
    turn(false);
    expect(turns(frame)).toEqual([]);
    ready();
    expect(turns(frame).map((one) => one.orientation)).toEqual(['landscape']);
  });

  it('stops listening once the message is taken down', () => {
    const { frame, host, listeners, turn, ready } = held(true);
    ready();
    host.destroy();
    expect(listeners).toHaveLength(0);
    turn(false);
    expect(turns(frame)).toEqual([]);
  });
});
