/**
 * A small DOM for the experience tests, which run with none: elements in a real tree, and a selector engine that
 * resolves POSITIONS on every query — `section:nth-of-type(2)`, `:first-of-type`, `>` and descendant combinators, `#id`,
 * `.class` and `[attribute]`. A map from selector to a fixed element cannot show what these tests pin, which is all
 * about a positional selector finding a different element once the page has changed.
 */

export class FakeComment {
  parent: FakeElement | null = null;
  get isConnected(): boolean {
    return this.parent?.isConnected ?? false;
  }
  replaceWith(node: FakeNode): void {
    this.parent?.swap(this, node);
  }
  remove(): void {
    this.parent?.drop(this);
  }
}

/** Text, as its own node: a text change's undo puts the old nodes back, so they have to exist. */
export class FakeText extends FakeComment {
  constructor(public data: string) {
    super();
  }
}

export type FakeNode = FakeElement | FakeComment;

class FakeStyle {
  values = new Map<string, { value: string; priority: string }>();
  setProperty(name: string, value: string, priority = ''): void {
    this.values.set(name, { value, priority });
  }
  getPropertyValue(name: string): string {
    return this.values.get(name)?.value ?? '';
  }
  getPropertyPriority(name: string): string {
    return this.values.get(name)?.priority ?? '';
  }
  removeProperty(name: string): void {
    this.values.delete(name);
  }
}

export class FakeElement {
  readonly nodeType = 1;
  readonly namespaceURI = 'http://www.w3.org/1999/xhtml';
  parent: FakeElement | null = null;
  nodes: FakeNode[] = [];
  attributes = new Map<string, string>();
  style = new FakeStyle();
  isRoot = false;

  constructor(
    public localName: string,
    attributes: Record<string, string> = {},
    children: FakeElement[] = [],
  ) {
    for (const [name, value] of Object.entries(attributes)) this.attributes.set(name, value);
    for (const child of children) this.append(child);
  }

  get tagName(): string {
    return this.localName.toUpperCase();
  }
  get id(): string {
    return this.attributes.get('id') ?? '';
  }
  get parentElement(): FakeElement | null {
    return this.parent;
  }
  get children(): FakeElement[] {
    return this.nodes.filter((node): node is FakeElement => node instanceof FakeElement);
  }
  get childNodes(): FakeNode[] {
    return [...this.nodes];
  }
  get isConnected(): boolean {
    return this.isRoot || (this.parent?.isConnected ?? false);
  }
  get textContent(): string {
    return this.nodes.map((node) => (node instanceof FakeElement ? node.textContent : node instanceof FakeText ? node.data : '')).join('');
  }
  set textContent(value: string) {
    for (const node of this.nodes) node.parent = null;
    this.nodes = [];
    if (value) this.append(new FakeText(value));
  }
  getAttribute(name: string): string | null {
    return this.attributes.get(name) ?? null;
  }
  setAttribute(name: string, value: string): void {
    this.attributes.set(name, value);
  }
  removeAttribute(name: string): void {
    this.attributes.delete(name);
  }
  append(...nodes: FakeNode[]): void {
    for (const node of nodes) {
      node.parent?.drop(node);
      node.parent = this;
      this.nodes.push(node);
    }
  }
  appendChild(node: FakeNode | FakeElement): void {
    // A fragment (a template's content) hands over its children.
    if (node instanceof FakeElement && node.localName === '#fragment') this.append(...node.nodes);
    else this.append(node);
  }
  replaceChildren(...nodes: FakeNode[]): void {
    this.textContent = '';
    for (const node of nodes) this.appendChild(node);
  }
  drop(node: FakeNode): void {
    this.nodes = this.nodes.filter((one) => one !== node);
    node.parent = null;
  }
  swap(old: FakeNode, replacement: FakeNode): void {
    replacement.parent?.drop(replacement);
    const index = this.nodes.indexOf(old);
    this.nodes[index] = replacement;
    old.parent = null;
    replacement.parent = this;
  }
  private insertAt(node: FakeNode, index: number): void {
    node.parent?.drop(node);
    node.parent = this;
    this.nodes.splice(index, 0, node);
  }
  remove(): void {
    this.parent?.drop(this);
  }
  replaceWith(node: FakeNode): void {
    this.parent?.swap(this, node);
  }
  before(node: FakeNode): void {
    this.parent?.insertAt(node, this.parent.nodes.indexOf(this));
  }
  insertAdjacentElement(where: string, element: FakeElement): FakeElement {
    if (where === 'beforebegin') this.before(element);
    else if (where === 'afterend') {
      const parent = this.parent!;
      element.parent?.drop(element);
      parent.insertAt(element, parent.nodes.indexOf(this) + 1);
    } else if (where === 'afterbegin') this.insertAt(element, 0);
    else this.append(element);
    return element;
  }
  /** Every element below this one, in document order. */
  descendants(): FakeElement[] {
    return this.children.flatMap((child) => [child, ...child.descendants()]);
  }
  querySelectorAll(selector: string): FakeElement[] {
    return this.descendants().filter((element) => matches(element, selector));
  }
  querySelector(selector: string): FakeElement | null {
    return this.querySelectorAll(selector)[0] ?? null;
  }
  closest(selector: string): FakeElement | null {
    for (let node: FakeElement | null = this; node; node = node.parent) if (matches(node, selector)) return node;
    return null;
  }
}

function compoundMatches(element: FakeElement, compound: string): boolean {
  if (compound === '*') return true;
  const parts = /^([a-z][a-z0-9-]*)?(#[\w-]+)?((?:\.[\w-]+)*)(\[[\w-]+\])?(?::nth-of-type\((\d+)\)|:(first-of-type))?$/i.exec(compound);
  if (!parts) throw new Error(`fake-dom cannot read ${compound}`);
  const [, tag, id, classes, attribute, nth, first] = parts;
  if (tag && element.localName !== tag.toLowerCase()) return false;
  if (id && element.id !== id.slice(1)) return false;
  const own = (element.getAttribute('class') ?? '').split(/\s+/);
  if (classes && !classes.split('.').filter(Boolean).every((name) => own.includes(name))) return false;
  if (attribute && element.getAttribute(attribute.slice(1, -1)) === null) return false;
  if (nth || first) {
    const same = element.parent ? element.parent.children.filter((child) => child.localName === element.localName) : [element];
    if (same.indexOf(element) + 1 !== (first ? 1 : Number(nth))) return false;
  }
  return true;
}

/** Right to left, as a browser reads a selector: `a > b` and `a b`. */
function matches(element: FakeElement, selector: string): boolean {
  const tokens = selector.trim().replace(/\s*>\s*/g, ' > ').split(/\s+/);
  const walk = (node: FakeElement | null, index: number): boolean => {
    if (!node || !compoundMatches(node, tokens[index]!)) return false;
    if (index === 0) return true;
    if (tokens[index - 1] === '>') return walk(node.parent, index - 2);
    for (let up = node.parent; up; up = up.parent) if (walk(up, index - 1)) return true;
    return false;
  };
  return walk(element, tokens.length - 1);
}

/** A document over a tree: what `changeOutcome`, `cleanMarkup` and `selectorFor` reach for on `document`. */
export function fakeDocument(body: FakeElement) {
  const html = new FakeElement('html', {}, [body]);
  html.isRoot = true;
  return {
    documentElement: html,
    body,
    querySelectorAll: (selector: string) => html.querySelectorAll(selector),
    querySelector: (selector: string) => html.querySelector(selector),
    createElement: (name: string) => {
      const element = new FakeElement(name);
      if (name === 'template') Object.assign(element, { innerHTML: '', content: new FakeElement('#fragment') });
      return element;
    },
    createElementNS: (_namespace: string, name: string) => new FakeElement(name),
    createComment: () => new FakeComment(),
  };
}
