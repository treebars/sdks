import { afterEach, describe, expect, it, vi } from 'vitest';

import { inAppClickEndsMessage, type InAppButton, type InAppContent, type InAppMessage } from '../src/in-app';
import { renderBuiltIn } from '../src/on-site';

/**
 * Push's actions on an in-app button: a call, a copy, a share and a store review are calls to action that spend the
 * message, and a browser, which has no store to ask, does not draw a store review at all.
 */

class FakeNode {
  attributes = new Map<string, string>();
  children: FakeNode[] = [];
  style = { cssText: '' };
  textContent = '';
  type = '';
  listeners: Record<string, (() => void)[]> = {};
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
  append(...nodes: FakeNode[]) {
    this.children.push(...nodes);
  }
  addEventListener(type: string, listener: () => void) {
    (this.listeners[type] ??= []).push(listener);
  }
  remove() {}
  all(predicate: (node: FakeNode) => boolean, into: FakeNode[] = []): FakeNode[] {
    if (predicate(this)) into.push(this);
    for (const child of this.children) child.all(predicate, into);
    return into;
  }
}

describe('push’s actions on an in-app button', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('spend the message as every call to action does', () => {
    for (const action of ['call', 'copy', 'share', 'store_review'] as const) expect(inAppClickEndsMessage({ action })).toBe(true);
    expect(inAppClickEndsMessage({ action: 'dismiss' })).toBe(false);
  });

  it('are drawn by the built-in renderer, all but the store review, which a browser cannot ask for', () => {
    const body = new FakeNode('body');
    vi.stubGlobal('document', { createElement: (tag: string) => new FakeNode(tag), body, head: new FakeNode('head'), addEventListener() {}, removeEventListener() {} });
    const buttons: InAppButton[] = [
      { label: 'Rate us', action: 'store_review' },
      { label: 'Copy the code', action: 'copy', value: 'SPRING25' },
    ];
    const pressed: InAppButton[] = [];
    const message: InAppMessage = {
      delivery_id: 'd1',
      campaign_id: 'c1',
      content: { title: 'Spring', in_app: { surface: 'overlay', layout: 'modal', trigger: { kind: 'immediate' }, buttons } as InAppContent },
      created_at: '2026-09-28T12:00:00.000Z',
      expires_at: null,
    };
    renderBuiltIn({ message, tokens: null, onClick: (button) => pressed.push(button), onDismiss: () => {}, onSubmit: () => {} });
    const drawn = body.all((node) => node.tagName === 'button' && node.textContent !== '×');
    expect(drawn.map((node) => node.textContent)).toEqual(['Copy the code']);
    drawn[0]!.listeners.click![0]!();
    expect(pressed).toEqual([buttons[1]]);
  });
});
