import { afterEach, describe, expect, it, vi } from 'vitest';

import type { InAppContent, InAppMessage } from '../src/in-app';
import { renderBuiltIn } from '../src/on-site';

/**
 * A web popup the person can fold away. Folded, the message is hidden and a tab with its name (or a round button) sits
 * at its edge; a press opens it again. Neither is a dismissal, a message drawn folded is still counted as shown, and
 * folding is offered only where it can be drawn: a modal with no dark layer, pinned to a corner.
 */

type Listener = (event: { key?: string }) => void;

class FakeNode {
  attributes = new Map<string, string>();
  children: FakeNode[] = [];
  listeners = new Map<string, Listener[]>();
  style: Record<string, string> = { cssText: '' };
  textContent = '';
  type = '';
  title = '';
  focused = false;
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
  addEventListener(type: string, listener: Listener) {
    this.listeners.set(type, [...(this.listeners.get(type) ?? []), listener]);
  }
  fire(type: string, event: { key?: string } = {}) {
    for (const listener of this.listeners.get(type) ?? []) listener(event);
  }
  focus() {
    this.focused = true;
  }
  remove() {}
  querySelector() {
    return null;
  }
  find(predicate: (node: FakeNode) => boolean): FakeNode | undefined {
    if (predicate(this)) return this;
    for (const child of this.children) {
      const found = child.find(predicate);
      if (found) return found;
    }
    return undefined;
  }
}

const CORNER = { vertical: 'bottom', horizontal: 'end', no_backdrop: true, minimisable: true } as const;

function draw(placement: InAppContent['placement']) {
  const body = new FakeNode('body');
  const doc = new FakeNode('document');
  vi.stubGlobal('document', { createElement: (tag: string) => new FakeNode(tag), body, head: new FakeNode('head'), addEventListener: doc.addEventListener.bind(doc), removeEventListener() {} });
  vi.stubGlobal('window', { addEventListener() {}, removeEventListener() {} });
  const message: InAppMessage = {
    delivery_id: 'd1',
    campaign_id: 'c1',
    content: { title: 'Autumn sale', body: 'Thirty percent off', in_app: { surface: 'overlay', layout: 'modal', trigger: { kind: 'immediate' }, placement } },
    created_at: '2026-10-11T12:00:00.000Z',
    expires_at: null,
  };
  const minimised: boolean[] = [];
  const dismissed: unknown[] = [];
  let shown = 0;
  renderBuiltIn({ message, tokens: null, onClick: () => {}, onDismiss: (reason) => dismissed.push(reason ?? 'closed'), onSubmit: () => {}, onShown: () => shown++, onMinimise: (value) => minimised.push(value) });
  const dialog = body.find((node) => node.getAttribute('role') === 'dialog')!;
  const handle = body.find((node) => node.getAttribute('aria-label') === 'Minimise');
  const tab = body.find((node) => (node.getAttribute('aria-label') ?? '').startsWith('Open: '));
  return { dialog, handle, tab, minimised, dismissed, shown: () => shown, press: (key: string) => doc.fire('keydown', { key }) };
}

describe('a web popup that can be minimised', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('folds into a tab with its name and opens again, neither a dismissal', () => {
    const page = draw({ ...CORNER });
    expect(page.handle).toBeDefined();
    expect(page.tab!.style.cssText).toContain('display:none');
    page.handle!.fire('click');
    expect(page.dialog.style.visibility).toBe('hidden');
    expect(page.tab!.style.display).toBe('inline-flex');
    expect(page.tab!.textContent).toBe('Autumn sale ⌃');
    expect(page.tab!.focused).toBe(true);
    // Escape does nothing to a folded message: there is nothing on screen for it to close.
    page.press('Escape');
    expect(page.dismissed).toEqual([]);
    page.tab!.fire('click');
    expect(page.dialog.style.visibility).toBe('visible');
    expect(page.tab!.style.display).toBe('none');
    expect(page.minimised).toEqual([true, false]);
    expect(page.dismissed).toEqual([]);
    page.press('Escape');
    expect(page.dismissed).toEqual(['closed']);
  });

  it('says what its author wrote, as text, and a round button shows its first character', () => {
    const tab = draw({ ...CORNER, minimised_label: '<b>Sale</b>' }).tab!;
    expect(tab.textContent).toBe('<b>Sale</b> ⌃');
    const round = draw({ ...CORNER, vertical: 'top', minimised_look: 'round', minimised_label: '🍂 Sale' }).tab!;
    expect(round.textContent).toBe('🍂');
    expect(round.style.cssText).toContain('border-radius:50%');
    expect(round.style.cssText).toContain('top:16px');
  });

  it('drawn folded, is counted as shown and records no minimise', () => {
    const page = draw({ ...CORNER, start_minimised: true });
    expect(page.dialog.style.visibility).toBe('hidden');
    expect(page.tab!.style.display).toBe('inline-flex');
    expect(page.shown()).toBe(1);
    expect(page.minimised).toEqual([]);
  });

  it('is not offered with a dark layer behind it, or away from a corner', () => {
    expect(draw({ ...CORNER, no_backdrop: undefined }).handle).toBeUndefined();
    expect(draw({ ...CORNER, vertical: 'middle' }).handle).toBeUndefined();
    expect(draw({ ...CORNER, horizontal: 'center' }).handle).toBeUndefined();
  });
});
