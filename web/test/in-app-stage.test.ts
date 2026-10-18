import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import type { InAppContent, InAppMessage } from '../src/in-app';
import { renderBuiltIn } from '../src/on-site';

/**
 * An HTML message on a page, as bridge 2 draws it: the SDK paints nothing — no backdrop, no surface, no corners, no
 * shadow — and the page is told the screen it is on, with the insets read by a probe in this document (a frame's own
 * `env()` is always 0). A stage is shown once the page says where its container is; a strip once its height is known.
 */

class FakeNode {
  attributes = new Map<string, string>();
  children: FakeNode[] = [];
  style: Record<string, string> = { cssText: '' };
  parentElement: FakeNode | null = null;
  textContent = '';
  posted: string[] = [];
  contentWindow: { postMessage: (text: string) => void } | null = null;
  constructor(public tagName: string) {
    if (tagName === 'iframe') this.contentWindow = { postMessage: (text: string) => this.posted.push(text) };
  }
  get parentNode() {
    return this.parentElement;
  }
  setAttribute(name: string, value: string) {
    this.attributes.set(name, value);
  }
  getAttribute(name: string) {
    return this.attributes.get(name) ?? null;
  }
  appendChild(child: FakeNode) {
    this.children.push(child);
    child.parentElement = this;
    return child;
  }
  insertBefore(child: FakeNode) {
    return this.appendChild(child);
  }
  get firstChild() {
    return this.children[0] ?? null;
  }
  attachShadow() {
    return this;
  }
  addEventListener() {}
  removeEventListener() {}
  focus() {}
  remove() {
    if (this.parentElement) this.parentElement.children = this.parentElement.children.filter((node) => node !== this);
    this.parentElement = null;
  }
  getBoundingClientRect() {
    const height = Number.parseFloat(this.style.height ?? '') || 0;
    return { left: 0, top: 0, right: 393, bottom: height, width: 393, height };
  }
  querySelector() {
    return null;
  }
  get inert() {
    return false;
  }
  set inert(_value: boolean) {}
  all(): FakeNode[] {
    return [this, ...this.children.flatMap((child) => child.all())];
  }
}

let body: FakeNode;
let listeners: Record<string, ((event: unknown) => void)[]>;
let size: { width: number; height: number };

beforeEach(() => {
  vi.useFakeTimers();
  body = new FakeNode('body');
  listeners = {};
  size = { width: 393, height: 852 };
  vi.stubGlobal('document', {
    createElement: (tag: string) => new FakeNode(tag),
    body,
    head: new FakeNode('head'),
    activeElement: null,
    addEventListener() {},
    removeEventListener() {},
    querySelector: () => null,
  });
  vi.stubGlobal('window', {
    get innerWidth() {
      return size.width;
    },
    get innerHeight() {
      return size.height;
    },
    matchMedia: (query: string) => ({ matches: query.includes('portrait') ? size.height >= size.width : false, addEventListener() {}, removeEventListener() {} }),
    addEventListener: (type: string, listener: (event: unknown) => void) => (listeners[type] ??= []).push(listener),
    removeEventListener: (type: string, listener: (event: unknown) => void) => (listeners[type] = (listeners[type] ?? []).filter((one) => one !== listener)),
  });
  vi.stubGlobal('navigator', { userAgent: 'vitest' });
  // A phone browser's notch and home bar, as the probe's padding reads them.
  vi.stubGlobal('getComputedStyle', () => ({ paddingTop: '47px', paddingRight: '0px', paddingBottom: '34px', paddingLeft: '0px' }));
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

function draw(content: Partial<InAppContent>) {
  const message: InAppMessage = {
    delivery_id: 'd1',
    campaign_id: 'c1',
    content: { title: 'Spring sale', in_app: { surface: 'overlay', layout: 'modal', body_mode: 'html', html: '<div data-tb-stage>x</div>', trigger: { kind: 'immediate' }, ...content } },
    created_at: '2026-10-17T12:00:00.000Z',
    expires_at: null,
  };
  const shown: unknown[] = [];
  const close = renderBuiltIn({ message, tokens: null, onClick: () => {}, onDismiss: () => {}, onSubmit: () => {}, onShown: (drawn) => shown.push(drawn ?? null) });
  const nodes = () => body.all();
  const frame = () => nodes().find((node) => node.tagName === 'iframe')!;
  const box = () => nodes().find((node) => node.getAttribute('role') === 'dialog')!;
  const nonce = () => /"nonce":"([0-9a-f]+)"/.exec(frame().getAttribute('srcdoc') ?? '')![1]!;
  let id = 0;
  const say = (method: string, ...args: unknown[]) => {
    for (const listener of listeners.message ?? []) listener({ source: frame().contentWindow, data: JSON.stringify({ tb: nonce(), id: (id += 1), method, args }) });
  };
  const envs = () => frame().posted.map((text) => JSON.parse(text) as { env?: Record<string, unknown> }).filter((one) => one.env).map((one) => one.env!);
  return { close, shown, nodes, frame, box, say, envs };
}

describe('a stage message on a page', () => {
  it('is a transparent box over the window, with no backdrop and nothing painted of the SDK’s', () => {
    const { nodes, box } = draw({ presentation: { bridge: 2, mode: 'stage' } });
    expect(box().style.cssText).toContain('position:fixed;inset:0');
    expect(box().getAttribute('aria-modal')).toBe('true');
    for (const node of nodes()) {
      const css = node.style.cssText;
      for (const paint of ['box-shadow', 'border-radius', 'rgba(']) expect(css, node.tagName).not.toContain(paint);
      const backgrounds = css.match(/background:[^;]*/g) ?? [];
      for (const background of backgrounds) expect(background, node.tagName).toMatch(/background:transparent/);
    }
    // The frame says `color-scheme: normal`, or a dark page paints an opaque backdrop behind it.
    const frame = nodes().find((node) => node.tagName === 'iframe')!;
    expect(frame.style.cssText).toContain('color-scheme:normal');
  });

  it('hands the page the insets a probe reads in this document, from the first byte', () => {
    const { frame, nodes } = draw({ presentation: { bridge: 2, mode: 'stage' } });
    const probe = nodes().find((node) => node.style.cssText.includes('env(safe-area-inset-top'))!;
    expect(probe.style.cssText).toContain('visibility:hidden');
    const srcdoc = frame().getAttribute('srcdoc')!;
    expect(srcdoc).toContain('--tb-safe-top:47px;--tb-safe-right:0px;--tb-safe-bottom:34px');
    expect(srcdoc).toContain('<html data-tb-host="web" data-tb-device="phone" data-tb-orientation="portrait" data-tb-theme="light">');
  });

  it('is shown when the page says where its container is, with `shown` in its environment', () => {
    const { box, say, envs, shown } = draw({ presentation: { bridge: 2, mode: 'stage' } });
    say('_ready');
    expect(box().style.cssText).toContain('visibility:hidden');
    expect(shown).toEqual([]);
    say('_layout', { container: { x: 16, y: 300, w: 361, h: 252 } });
    expect(box().style.visibility).toBe('visible');
    expect(shown).toHaveLength(1);
    expect(envs().at(-1)).toMatchObject({ shown: true, safe: { top: 47, bottom: 34 } });
  });

  it('is shown a second after it runs if the page never says where its container is', () => {
    const { box, say, shown } = draw({ presentation: { bridge: 2, mode: 'stage' } });
    say('_ready');
    vi.advanceTimersByTime(999);
    expect(shown).toEqual([]);
    vi.advanceTimersByTime(1);
    expect(box().style.visibility).toBe('visible');
    expect(shown).toHaveLength(1);
  });

  it('tells the page the window turned, once', () => {
    const { say, envs } = draw({ presentation: { bridge: 2, mode: 'stage' } });
    say('_ready');
    say('_layout', { container: { x: 0, y: 0, w: 10, h: 10 } });
    const before = envs().length;
    size = { width: 852, height: 393 };
    for (const listener of listeners.resize ?? []) listener({});
    for (const listener of listeners.resize ?? []) listener({});
    expect(envs().slice(before)).toEqual([expect.objectContaining({ orientation: 'landscape' })]);
  });

  it('on a touch device is the visual viewport, so a keyboard shrinks the stage rather than covering it', () => {
    const viewportListeners: (() => void)[] = [];
    const viewport = { offsetTop: 0, offsetLeft: 0, width: 393, height: 852, addEventListener: (_type: string, listener: () => void) => viewportListeners.push(listener), removeEventListener() {} };
    const plain = window as unknown as Record<string, unknown>;
    plain.visualViewport = viewport;
    const media = plain.matchMedia as (query: string) => { matches: boolean };
    plain.matchMedia = (query: string) => (query === '(pointer: coarse)' ? { ...media(query), matches: true } : media(query));
    const { box, say, envs } = draw({ presentation: { bridge: 2, mode: 'stage' } });
    expect(box().style.height).toBe('852px');
    say('_ready');
    say('_layout', { container: { x: 0, y: 0, w: 10, h: 10 } });
    // The keyboard comes up: the visual viewport is shorter, and so is the stage.
    viewport.height = 516;
    viewportListeners.forEach((listener) => listener());
    expect(box().style.height).toBe('516px');
    expect(box().style.top).toBe('0px');
    expect(envs().at(-1)).toMatchObject({ keyboard: { height: 0 }, safe: { bottom: 34 } });
  });

  it('reads a message from before presentations by its layout', () => {
    const { box } = draw({ layout: 'sheet' });
    expect(box().style.cssText).toContain('position:fixed;inset:0');
  });
});

describe('a strip on a page', () => {
  it('is a transparent box at its edge, as tall as the page says, with nothing painted of the SDK’s', () => {
    const { box, say, envs, nodes } = draw({ layout: 'banner', presentation: { bridge: 2, mode: 'strip', edge: 'top', floating: false } });
    expect(box().style.cssText).toContain('position:fixed;left:0;right:0;top:0');
    expect(box().getAttribute('aria-modal')).toBe('false');
    for (const node of nodes()) for (const paint of ['box-shadow', 'border-radius']) expect(node.style.cssText).not.toContain(paint);
    say('_ready');
    say('resize', 96);
    expect(box().style.height).toBe('96px');
    expect(box().style.visibility).toBe('visible');
    // A top banner lies under the notch, and over nothing at the bottom.
    expect(envs().at(-1)).toMatchObject({ shown: true, safe: { top: 47, bottom: 0 } });
  });
});
