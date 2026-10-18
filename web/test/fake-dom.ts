import { vi } from 'vitest';

/**
 * A style a renderer writes as one `cssText` and later changes one property at a time: setting `cssText` spreads its
 * declarations onto camel-cased properties, so a test reads `style.visibility` either way.
 */
const LENGTHS = new Set(['height', 'width', 'top', 'left', 'right', 'bottom', 'maxHeight', 'maxWidth']);

export class FakeStyle {
  [property: string]: unknown;
  private text = '';
  get cssText(): string {
    return this.text;
  }
  set cssText(value: string) {
    this.text = value;
    for (const declaration of value.split(';')) {
      const at = declaration.indexOf(':');
      if (at < 0) continue;
      const name = declaration.slice(0, at).trim().replace(/-([a-z])/g, (_, letter: string) => letter.toUpperCase());
      const raw = declaration.slice(at + 1).trim();
      // As a browser reads it back: a bare zero length is "0px".
      if (name) this[name] = raw === '0' && LENGTHS.has(name) ? '0px' : raw;
    }
  }
}

/**
 * The little of the DOM the SDK's drawing code touches, kept as a tree so a test can find a node by what a person would
 * see — its words, its label, its role — and press it. Enough for the renderers and the notification centre; not a
 * browser. `install()` puts a `document` over it and returns the body.
 */
export class FakeNode {
  attributes = new Map<string, string>();
  children: FakeNode[] = [];
  listeners = new Map<string, Array<(event: Record<string, unknown>) => void>>();
  style: FakeStyle = new FakeStyle();
  parent: FakeNode | null = null;
  type = '';
  title = '';
  src = '';
  alt = '';
  value = '';
  disabled = false;
  focused = false;
  private ownText = '';
  constructor(public tagName: string) {}

  get textContent(): string {
    return this.ownText + this.children.map((child) => child.textContent).join('');
  }
  set textContent(text: string) {
    this.ownText = text;
    this.children = [];
  }
  setAttribute(name: string, value: string) {
    this.attributes.set(name, value);
  }
  getAttribute(name: string) {
    return this.attributes.get(name) ?? null;
  }
  appendChild(child: FakeNode) {
    child.remove();
    child.parent = this;
    this.children.push(child);
    return child;
  }
  append(...children: FakeNode[]) {
    for (const child of children) this.appendChild(child);
  }
  insertBefore(child: FakeNode, before: FakeNode | null) {
    child.remove();
    child.parent = this;
    const at = before ? this.children.indexOf(before) : -1;
    if (at < 0) this.children.push(child);
    else this.children.splice(at, 0, child);
    return child;
  }
  replaceChild(next: FakeNode, old: FakeNode) {
    const at = this.children.indexOf(old);
    if (at < 0) return old;
    next.remove();
    next.parent = this;
    old.parent = null;
    this.children[at] = next;
    return old;
  }
  get parentNode(): FakeNode | null {
    return this.parent;
  }
  replaceChildren(...children: FakeNode[]) {
    for (const child of this.children) child.parent = null;
    this.children = [];
    this.append(...children);
  }
  get firstChild(): FakeNode | null {
    return this.children[0] ?? null;
  }
  get parentElement(): FakeNode | null {
    return this.parent;
  }
  remove() {
    if (!this.parent) return;
    this.parent.children = this.parent.children.filter((child) => child !== this);
    this.parent = null;
  }
  attachShadow() {
    return this;
  }
  addEventListener(type: string, listener: (event: Record<string, unknown>) => void) {
    this.listeners.set(type, [...(this.listeners.get(type) ?? []), listener]);
  }
  removeEventListener(type: string, listener: (event: Record<string, unknown>) => void) {
    this.listeners.set(type, (this.listeners.get(type) ?? []).filter((one) => one !== listener));
  }
  /** Fires `type` on this node only, as a press or a key would arrive; returns the event so a test can read it. */
  fire(type: string, event: Record<string, unknown> = {}) {
    const full = { preventDefault() {}, stopPropagation() {}, target: this, ...event };
    for (const listener of this.listeners.get(type) ?? []) listener(full);
    return full;
  }
  click() {
    this.fire('click');
  }
  focus() {
    this.focused = true;
  }
  getBoundingClientRect() {
    return { left: 0, top: 0, width: 0, height: 0, right: 0, bottom: 0 };
  }
  querySelector() {
    return null;
  }
  querySelectorAll() {
    return [];
  }
  /** Every node under this one, this one first. */
  all(): FakeNode[] {
    return [this, ...this.children.flatMap((child) => child.all())];
  }
  find(predicate: (node: FakeNode) => boolean): FakeNode | undefined {
    return this.all().find(predicate);
  }
  /** The control a person would press by its words or its label, exactly. */
  byName(name: string): FakeNode | undefined {
    return this.find((node) => node.getAttribute('aria-label') === name || (node.tagName === 'button' && node.textContent === name));
  }
}

/** A document over a fresh tree. Returns the body and the document's own node, which holds its listeners. */
export function install(): { body: FakeNode; doc: FakeNode; head: FakeNode } {
  const body = new FakeNode('body');
  const head = new FakeNode('head');
  const doc = new FakeNode('document');
  vi.stubGlobal('document', {
    createElement: (tag: string) => new FakeNode(tag),
    body,
    head,
    activeElement: null,
    // An attribute selector, `[name="value"]`, the only kind the SDK asks the document for.
    querySelector: (selector: string) => {
      const match = /^\[([\w-]+)="([^"]*)"\]$/.exec(selector);
      return match ? (body.find((node) => node.getAttribute(match[1]!) === match[2]) ?? null) : null;
    },
    addEventListener: doc.addEventListener.bind(doc),
    removeEventListener: doc.removeEventListener.bind(doc),
  });
  return { body, doc, head };
}
