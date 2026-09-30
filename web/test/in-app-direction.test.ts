import { afterEach, describe, expect, it, vi } from 'vitest';

import { inAppHtmlWithDirection, type InAppContent, type InAppMessage } from '../src/in-app';
import { renderBuiltIn } from '../src/on-site';

/**
 * The built-in renderer and a message's direction. Arabic copy drawn left-aligned reads as broken even when every glyph
 * is right; the server says which way the message's language reads, and the renderer follows it — and sets nothing at
 * all when the server says nothing.
 */

/** The little of the DOM the renderer touches, kept as a tree so the dialog can be found again. */
class FakeNode {
  attributes = new Map<string, string>();
  children: FakeNode[] = [];
  style = { cssText: '', padding: '' };
  textContent = '';
  type = '';
  constructor(public tagName: string) {}
  setAttribute(name: string, value: string) {
    this.attributes.set(name, value);
  }
  getAttribute(name: string) {
    return this.attributes.get(name) ?? null;
  }
  appendChild(child: FakeNode) {
    this.children.push(child);
    return child;
  }
  addEventListener() {}
  remove() {}
  find(predicate: (node: FakeNode) => boolean): FakeNode | undefined {
    if (predicate(this)) return this;
    for (const child of this.children) {
      const found = child.find(predicate);
      if (found) return found;
    }
    return undefined;
  }
}

function draw(content: Partial<InAppContent>): FakeNode {
  const body = new FakeNode('body');
  vi.stubGlobal('document', { createElement: (tag: string) => new FakeNode(tag), body, head: new FakeNode('head'), addEventListener() {}, removeEventListener() {} });
  // An HTML body is hosted with the bridge, which listens on the window for its frame's calls.
  vi.stubGlobal('window', { addEventListener() {}, removeEventListener() {} });
  const message: InAppMessage = {
    delivery_id: 'd1',
    campaign_id: 'c1',
    content: { title: 'Special offer', body: 'Twenty percent off, today only', in_app: { surface: 'overlay', layout: 'modal', trigger: { kind: 'immediate' }, ...content } },
    created_at: '2026-09-25T12:00:00.000Z',
    expires_at: null,
  };
  renderBuiltIn({ message, tokens: null, onClick: () => {}, onDismiss: () => {}, onSubmit: () => {} });
  return body;
}

const dialogOf = (page: FakeNode) => page.find((node) => node.getAttribute('role') === 'dialog')!;
const closeOf = (page: FakeNode) => page.find((node) => node.getAttribute('aria-label') === 'Close')!;

describe('a message’s direction', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('draws a right-to-left message right to left, with the close control in the other corner', () => {
    const page = draw({ direction: 'rtl' });
    expect(dialogOf(page).getAttribute('dir')).toBe('rtl');
    expect(closeOf(page).style.cssText).toContain('left:8px');
    expect(closeOf(page).style.cssText).not.toContain('right:8px');
  });

  it('draws one with no direction exactly as before: nothing set, the page’s own direction inherited', () => {
    const page = draw({});
    expect(dialogOf(page).getAttribute('dir')).toBeNull();
    expect(closeOf(page).style.cssText).toContain('right:8px');
  });

  it('sets a left-to-right one explicitly, so a right-to-left page does not flip an English message', () => {
    const page = draw({ direction: 'ltr' });
    expect(dialogOf(page).getAttribute('dir')).toBe('ltr');
    expect(closeOf(page).style.cssText).toContain('right:8px');
  });

  it('ignores a value it does not know rather than writing it into the page', () => {
    const page = draw({ direction: 'sideways' as never });
    expect(dialogOf(page).getAttribute('dir')).toBeNull();
  });
});

describe('a markup body’s direction', () => {
  afterEach(() => vi.unstubAllGlobals());

  const srcdocOf = (page: FakeNode) => page.find((node) => node.tagName === 'iframe')!.getAttribute('srcdoc')!;
  /** What follows the SDK's own head — the policy, the base styles and the bridge shim. */
  const bodyOf = (srcdoc: string) => srcdoc.slice(srcdoc.indexOf('</script>') + '</script>'.length);

  it('puts right-to-left on the framed document, which inherits nothing from the dialog', () => {
    const srcdoc = srcdocOf(draw({ body_mode: 'html', html: '<p>Special offer</p>', direction: 'rtl' }));
    expect(srcdoc.startsWith('<!doctype html><html dir="rtl"><meta charset="utf-8">')).toBe(true);
    expect(bodyOf(srcdoc)).toBe('<p>Special offer</p>');
  });

  it('keeps a leading doctype first, so the frame is not put into quirks mode', () => {
    expect(inAppHtmlWithDirection('<!DOCTYPE html><html lang="ar"><body><p>x</p></body></html>', 'rtl')).toBe('<!DOCTYPE html><html dir="rtl"><html lang="ar"><body><p>x</p></body></html>');
    // A document is kept as a document: its doctype first, then the direction, the policy and the shim, then it.
    const srcdoc = srcdocOf(draw({ body_mode: 'html', html: '<!DOCTYPE html><html lang="ar"><body><p>x</p></body></html>', direction: 'rtl' }));
    expect(srcdoc.startsWith('<!DOCTYPE html><html dir="rtl"><meta http-equiv="Content-Security-Policy"')).toBe(true);
    expect(bodyOf(srcdoc)).toBe('<html lang="ar"><body><p>x</p></body></html>');
  });

  it('leaves markup that sets its own direction alone', () => {
    for (const html of ['<html dir="ltr"><p>x</p></html>', '<body class="m" DIR=rtl><p>x</p></body>']) {
      const srcdoc = srcdocOf(draw({ body_mode: 'html', html, direction: 'rtl' }));
      expect(srcdoc).not.toContain('<html dir="rtl">');
      expect(srcdoc.endsWith(html)).toBe(true);
    }
  });

  it('sends the markup exactly as written with no direction, or a left-to-right one', () => {
    for (const direction of [undefined, 'ltr'] as const) {
      const srcdoc = srcdocOf(draw({ body_mode: 'html', html: '<p>x</p>', ...(direction ? { direction } : {}) }));
      expect(srcdoc).not.toContain('dir=');
      expect(bodyOf(srcdoc)).toBe('<p>x</p>');
    }
  });

  it('frames it with scripts and nothing else, the policy before the shim and the shim before the markup', () => {
    const page = draw({ body_mode: 'html', html: '<p>x</p>' });
    const frame = page.find((node) => node.tagName === 'iframe')!;
    expect(frame.getAttribute('sandbox')).toBe('allow-scripts');
    const srcdoc = frame.getAttribute('srcdoc')!;
    const policy = srcdoc.indexOf('Content-Security-Policy');
    const shim = srcdoc.indexOf('<script>(function(');
    expect(policy).toBeGreaterThan(0);
    expect(shim).toBeGreaterThan(policy);
    expect(srcdoc.indexOf('<p>x</p>')).toBeGreaterThan(shim);
    expect(srcdoc).toMatch(/"host":"web","nonce":"[0-9a-f]{32}"/);
  });
});
