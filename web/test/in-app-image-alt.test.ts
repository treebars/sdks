import { afterEach, describe, expect, it, vi } from 'vitest';

import type { InAppContent, InAppMessage } from '../src/in-app';
import { renderBuiltIn } from '../src/on-site';

/**
 * What a screen reader is told: an image carries the author's description when there is one, so a promotion that is
 * only a picture does not read as nothing, and the dialog is named rather than announced as "dialog" alone.
 */

class FakeNode {
  attributes = new Map<string, string>();
  children: FakeNode[] = [];
  style = { cssText: '' };
  textContent = '';
  alt?: string;
  src?: string;
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
  const message: InAppMessage = {
    delivery_id: 'd1',
    campaign_id: 'c1',
    content: { title: 'Winter coats', body: 'Twenty percent off', image_url: 'https://cdn.example.com/coat.png', in_app: { surface: 'overlay', layout: 'modal', trigger: { kind: 'immediate' }, ...content } },
    created_at: '2026-09-28T12:00:00.000Z',
    expires_at: null,
  };
  renderBuiltIn({ message, tokens: null, onClick: () => {}, onDismiss: () => {}, onSubmit: () => {} });
  return body;
}

describe('what a screen reader is told', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('says what the image shows when the author did, and skips it as decoration when not', () => {
    expect(draw({ image_alt: 'A red winter coat' }).find((node) => node.tagName === 'img')!.alt).toBe('A red winter coat');
    expect(draw({}).find((node) => node.tagName === 'img')!.alt).toBe('');
  });

  it('names the dialog by the message’s title', () => {
    expect(draw({}).find((node) => node.getAttribute('role') === 'dialog')!.getAttribute('aria-label')).toBe('Winter coats');
  });
});
