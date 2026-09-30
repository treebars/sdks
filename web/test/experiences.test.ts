import { describe, expect, it, vi } from 'vitest';

import {
  antiFlickerSnippet,
  applyChange,
  assignVariation,
  attributeUnsafe,
  changeKey,
  changeWritesInto,
  cleanMarkup,
  clickedChanges,
  decideExperiences,
  elementForbidden,
  fnv1a,
  redirectTarget,
  userAgentFacts,
  valueRuns,
  type Decision,
  type WebExperienceWire,
} from '../src/experiences';
import { editorParams } from '../src/visual-editor';

/* Web personalization on the page. */

const experience: WebExperienceWire = {
  id: '5b1b8a38-2f5c-4c1e-9a4e-6f4f7c1d2a10',
  kind: 'visual',
  url_rules: [{ op: 'contains', value: '/pricing' }],
  url_match: 'all',
  rules: [{ kind: 'browser', values: ['chrome'] }],
  variations: [
    { id: 'control', weight: 34, control: true, changes: [] },
    { id: 'b', weight: 33, changes: [{ op: 'text', selector: 'h1', value: 'B' }] },
    { id: 'c', weight: 33, changes: [{ op: 'hide', selector: '.promo' }] },
  ],
  goal_event: 'signup',
  priority: 5,
};

const chrome = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36';

describe('the page decides as the server does', () => {
  // The expected values are the server-side decide API's answers for the same inputs, so a visitor lands in the same
  // variation whichever of the two decides.
  it('hashes and assigns exactly as the server does', () => {
    expect(['x0', 'x1', 'x2', 'visitor-7'].map((value) => fnv1a(value))).toEqual([291704853, 274927234, 258149615, 1453174057]);
    expect(Array.from({ length: 12 }, (_, i) => assignVariation(experience.id, `visitor-${i}`, experience.variations))).toEqual([
      'c', 'c', 'b', 'b', 'control', 'c', 'c', 'b', 'b', 'control', 'b', 'c',
    ]);
  });

  it('shows the page’s experiences to the visitors its rules describe', () => {
    const visitor = { id: 'visitor-7', href: 'https://shop.example/pricing', isNewVisitor: false, identified: false, now: new Date(), userAgent: chrome };
    const decided = decideExperiences([experience], visitor);
    expect(decided).toHaveLength(1);
    expect(decided[0]!.variation_id).toBe('b');
    expect(decideExperiences([experience], { ...visitor, href: 'https://shop.example/' })).toEqual([]);
    expect(decideExperiences([experience], { ...visitor, userAgent: 'Mozilla/5.0 (X11; Linux x86_64; rv:120.0) Gecko/20100101 Firefox/120.0' })).toEqual([]);
  });
});

describe('split-URL tests and the editor', () => {
  it('carries the page’s query to the other address, without overwriting its own', () => {
    expect(redirectTarget('https://shop.example/b?v=2', 'https://shop.example/a?utm_source=mail&v=1')).toBe('https://shop.example/b?v=2&utm_source=mail');
  });

  it('reads an editing session only when both parameters are there and the origin is an origin', () => {
    expect(editorParams('https://shop.example/?treebars_editor=e1:b&treebars_origin=https://app.treebars.com')).toEqual({ experienceId: 'e1', variationId: 'b', origin: 'https://app.treebars.com' });
    expect(editorParams('https://shop.example/?treebars_editor=e1:b&treebars_origin=https://evil.example/path')).toBeNull();
    expect(editorParams('https://shop.example/?treebars_editor=e1:b')).toBeNull();
  });

  it('hides the page for at most the time it is given', () => {
    expect(antiFlickerSnippet(500)).toContain('500');
    expect(antiFlickerSnippet()).toContain('id="treebars-antiflicker"');
  });
});

/*
 * applyChange against a stand-in for the page: this suite has no DOM, and what is under test is which changes land and
 * in what order — not how the browser draws them.
 */
class FakeElement {
  attributes = new Map<string, string>();
  styles = new Map<string, string>();
  textContent = '';
  constructor(public localName: string) {}
  getAttribute(name: string) {
    return this.attributes.get(name) ?? null;
  }
  setAttribute(name: string, value: string) {
    this.attributes.set(name, value);
  }
  get style() {
    return { setProperty: (property: string, value: string) => this.styles.set(property, value) };
  }
  removed = false;
  remove() {
    this.removed = true;
  }
  /** Where it sits on the page; a change is refused anywhere inside a form. */
  parentElement: FakeElement | null = null;
  inside(parent: FakeElement): this {
    this.parentElement = parent;
    return this;
  }
  children: unknown[] = [];
  replaceChildren(...nodes: unknown[]) {
    this.children = nodes;
  }
}

function page(elements: Record<string, FakeElement>): ParentNode {
  return { querySelectorAll: (selector: string) => (elements[selector] ? [elements[selector]] : []) } as unknown as ParentNode;
}

describe('applying changes', () => {
  it('applies a second change of the same kind to one element — a colour, then a size', () => {
    const h1 = new FakeElement('h1');
    const root = page({ 'header h1': h1 });
    applyChange({ op: 'style', selector: 'header h1', property: 'color', value: '#e5484d' }, root);
    applyChange({ op: 'style', selector: 'header h1', property: 'font-size', value: '40px' }, root);
    expect(h1.styles.get('color')).toBe('#e5484d');
    expect(h1.styles.get('font-size')).toBe('40px');
  });

  it('leaves the higher priority’s text on the page when two experiences change one element', () => {
    const h1 = new FakeElement('h1');
    const root = page({ h1 });
    const one = (id: string, priority: number, value: string): WebExperienceWire => ({
      id,
      kind: 'visual',
      url_rules: [{ op: 'contains', value: '/' }],
      url_match: 'all',
      rules: [],
      variations: [{ id: 'b', weight: 100, changes: [{ op: 'text', selector: 'h1', value }] }],
      goal_event: null,
      priority,
    });
    const visitor = { id: 'v', href: 'https://shop.example/', isNewVisitor: false, identified: false, now: new Date(), userAgent: chrome };
    const decided = decideExperiences([one('high', 8, 'High'), one('low', 3, 'Low')], visitor);
    for (const change of decided.flatMap((decision) => decision.changes)) applyChange(change, root);
    expect(h1.textContent).toBe('High');
  });

  it('applies the same change once, however often it is retried', () => {
    const h1 = new FakeElement('h1');
    const root = page({ h1 });
    const change = { op: 'text' as const, selector: 'h1', value: 'Once' };
    applyChange(change, root);
    h1.textContent = 'Drawn again by the app';
    applyChange(change, root);
    expect(h1.textContent).toBe('Drawn again by the app');
    expect(changeKey(change)).toBe(changeKey({ ...change }));
    expect(changeKey(change)).not.toBe(changeKey({ ...change, value: 'Twice' }));
  });

  it('never changes an element that runs or loads, however the change reached the page', () => {
    const script = new FakeElement('script');
    const base = new FakeElement('base');
    const set = new FakeElement('set');
    const root = page({ 'script#empty': script, base, 'svg set': set });
    applyChange({ op: 'text', selector: 'script#empty', value: 'x()' }, root);
    applyChange({ op: 'attr', selector: 'base', name: 'href', value: 'https://elsewhere.example/' }, root);
    applyChange({ op: 'attr', selector: 'svg set', name: 'to', value: 'x' }, root);
    expect(script.textContent).toBe('');
    expect(base.attributes.size).toBe(0);
    expect(set.attributes.size).toBe(0);
  });

  it('hides, restyles and removes an iframe, an embed and a noscript — the commonest reason to target one', () => {
    for (const name of ['iframe', 'embed', 'object', 'noscript', 'style', 'link']) {
      const hidden = new FakeElement(name);
      const styled = new FakeElement(name);
      const gone = new FakeElement(name);
      const root = page({ '#hide': hidden, '#style': styled, '#remove': gone });
      expect(applyChange({ op: 'hide', selector: '#hide' }, root)).toBe(true);
      applyChange({ op: 'style', selector: '#style', property: 'height', value: '0' }, root);
      applyChange({ op: 'remove', selector: '#remove' }, root);
      expect(hidden.styles.get('display'), name).toBe('none');
      expect(styled.styles.get('height'), name).toBe('0');
      expect(gone.removed, name).toBe(true);
    }
  });

  it('still writes nothing into an element that runs or loads: text, markup, attributes, an insert inside it', () => {
    const frame = new FakeElement('iframe');
    const script = new FakeElement('script');
    const root = page({ iframe: frame, script });
    applyChange({ op: 'text', selector: 'script', value: 'x()' }, root);
    applyChange({ op: 'html', selector: 'iframe', value: '<b>x</b>' }, root);
    applyChange({ op: 'attr', selector: 'iframe', name: 'src', value: 'https://elsewhere.example/' }, root);
    applyChange({ op: 'insert', selector: 'iframe', position: 'append', html: '<b>x</b>' }, root);
    expect(script.textContent).toBe('');
    expect(frame.children).toEqual([]);
    expect(frame.attributes.size).toBe(0);
    expect(changeWritesInto({ op: 'insert', selector: 'iframe', position: 'after', html: '<b>x</b>' })).toBe(false);
    expect(changeWritesInto({ op: 'insert', selector: 'iframe', position: 'prepend', html: '<b>x</b>' })).toBe(true);
    expect(changeWritesInto({ op: 'move', selector: 'iframe', target: 'footer', position: 'before' })).toBe(false);
  });

  it('refuses a tab-split javascript: address, srcdoc and formaction on an attribute change', () => {
    const link = new FakeElement('a');
    const root = page({ a: link });
    applyChange({ op: 'attr', selector: 'a', name: 'href', value: 'java\tscript:x' }, root);
    applyChange({ op: 'attr', selector: 'a', name: 'srcdoc', value: 'x' }, root);
    applyChange({ op: 'attr', selector: 'a', name: 'formaction', value: 'x' }, root);
    expect(link.attributes.has('href')).toBe(false);
    expect(link.attributes.has('srcdoc')).toBe(false);
    expect(link.attributes.has('formaction')).toBe(false);
    applyChange({ op: 'attr', selector: 'a', name: 'href', value: '/pricing' }, root);
    expect(link.getAttribute('href')).toBe('/pricing');
  });

  // Forms are not part of web experiences, and the page holds to that itself, whatever markup it is sent.
  it('strips a form from inserted markup, and every form attribute from what is left', () => {
    const removed: string[] = [];
    const node = (localName: string, attributes: { name: string; value: string }[] = []) => ({
      localName,
      attributes,
      remove: () => removed.push(localName),
      removeAttribute(name: string) {
        this.attributes = this.attributes.filter((attribute) => attribute.name !== name);
      },
    });
    const form = node('form', [{ name: 'action', value: 'https://elsewhere.example/' }]);
    const button = node('button', [
      { name: 'form', value: 'checkout' },
      { name: 'formaction', value: 'https://elsewhere.example/' },
      { name: 'formmethod', value: 'post' },
      { name: 'class', value: 'cta' },
    ]);
    const content = { querySelectorAll: () => [form, button] };
    vi.stubGlobal('document', { createElement: () => ({ innerHTML: '', content }) });
    try {
      expect(cleanMarkup('<form action="x"></form><button form="checkout">Pay</button>')).toBe(content);
    } finally {
      vi.unstubAllGlobals();
    }
    expect(removed).toEqual(['form']);
    expect(button.attributes).toEqual([{ name: 'class', value: 'cta' }]);
  });

  it('never repoints or fills a form already on the page, and never joins a control to one', () => {
    const form = new FakeElement('form');
    const button = new FakeElement('button');
    const root = page({ form, button });
    applyChange({ op: 'attr', selector: 'form', name: 'action', value: 'https://elsewhere.example/' }, root);
    applyChange({ op: 'insert', selector: 'form', position: 'append', html: '<b>x</b>' }, root);
    for (const name of ['form', 'formaction', 'formenctype', 'formmethod', 'formnovalidate', 'formtarget', 'action']) {
      applyChange({ op: 'attr', selector: 'button', name, value: 'x' }, root);
    }
    expect(form.attributes.size).toBe(0);
    // Not even the marker: a refused change is not applied, and a marker would read as applied next time.
    expect([...button.attributes.keys()]).toEqual([]);
    // Hidden like any other element: taking a form away is still a change an experience may make.
    expect(applyChange({ op: 'hide', selector: 'form' }, root)).toBe(true);
    expect(form.styles.get('display')).toBe('none');
    expect(elementForbidden('FORM')).toBe(true);
    expect(attributeUnsafe('data-format')).toBe(false);
    expect(attributeUnsafe('formatted')).toBe(false);
  });

  // The marker is per slot, so a value that was replaced can be applied again.
  it('ends on the last value when a change goes A → B → A — text, a colour, an attribute', () => {
    const h1 = new FakeElement('h1');
    const root = page({ h1 });
    for (const value of ['A', 'B', 'A']) applyChange({ op: 'text', selector: 'h1', value }, root);
    expect(h1.textContent).toBe('A');
    for (const value of ['red', 'blue', 'red']) applyChange({ op: 'style', selector: 'h1', property: 'color', value }, root);
    expect(h1.styles.get('color')).toBe('red');
    for (const value of ['/a', '/b', '/a']) applyChange({ op: 'attr', selector: 'h1', name: 'title', value }, root);
    expect(h1.getAttribute('title')).toBe('/a');
    // One entry per slot, however often it was rewritten.
    expect(h1.getAttribute('data-treebars-applied')!.split('|')).toHaveLength(3);
  });

  it('leaves the highest priority’s value when two experiences carry the same one', () => {
    const h1 = new FakeElement('h1');
    const root = page({ h1 });
    const one = (id: string, priority: number, value: string): WebExperienceWire => ({
      id,
      kind: 'visual',
      url_rules: [{ op: 'contains', value: '/' }],
      url_match: 'all',
      rules: [],
      variations: [{ id: 'b', weight: 100, changes: [{ op: 'text', selector: 'h1', value }] }],
      goal_event: null,
      priority,
    });
    const visitor = { id: 'v', href: 'https://shop.example/', isNewVisitor: false, identified: false, now: new Date(), userAgent: chrome };
    const decided = decideExperiences([one('high', 9, 'Sale'), one('low', 1, 'Sale'), one('middle', 5, 'New')], visitor);
    for (const change of decided.flatMap((decision) => decision.changes)) applyChange(change, root);
    expect(h1.textContent).toBe('Sale');
  });

  it('adds nothing to a page’s form from inside it, and still rewords, hides and restyles what is in it', () => {
    const form = new FakeElement('form');
    const fieldset = new FakeElement('fieldset').inside(form);
    const row = new FakeElement('div').inside(fieldset);
    const label = new FakeElement('label').inside(row);
    const field = new FakeElement('input').inside(row);
    const note = new FakeElement('textarea').inside(row);
    const outside = new FakeElement('aside');
    const inserted: string[] = [];
    for (const element of [row, label, field, outside]) {
      (element as unknown as { insertAdjacentElement: (where: string) => void }).insertAdjacentElement = (where) => void inserted.push(`${element.localName}:${where}`);
    }
    const root = {
      querySelectorAll: (selector: string) => ({ '#row': [row], '#label': [label], '#field': [field], '#note': [note], aside: [outside] })[selector] ?? [],
      querySelector: (selector: string) => ({ '#row': row, aside: outside })[selector] ?? null,
    } as unknown as ParentNode;
    vi.stubGlobal('document', { createElement: () => ({ innerHTML: '', content: { querySelectorAll: () => [] }, setAttribute() {}, appendChild() {} }) });
    try {
      applyChange({ op: 'insert', selector: '#row', position: 'append', html: '<input name="note">' }, root);
      applyChange({ op: 'insert', selector: '#row', position: 'after', html: '<button>Pay</button>' }, root);
      applyChange({ op: 'html', selector: '#row', value: '<input name="note">' }, root);
      // Copy is copy: a label's or a button's words are not what the form sends. A textarea's are.
      applyChange({ op: 'text', selector: '#label', value: 'Card number' }, root);
      applyChange({ op: 'text', selector: '#note', value: 'prefilled' }, root);
      applyChange({ op: 'attr', selector: '#field', name: 'name', value: 'elsewhere' }, root);
      // Moving the aside to beside the row puts it inside the form.
      applyChange({ op: 'move', selector: 'aside', target: '#row', position: 'after' }, root);
      // Outside any form, the same insert lands.
      applyChange({ op: 'insert', selector: 'aside', position: 'after', html: '<b>x</b>' }, root);
    } finally {
      vi.unstubAllGlobals();
    }
    expect(inserted).toEqual(['aside:afterend']);
    expect(label.textContent).toBe('Card number');
    expect(note.textContent).toBe('');
    expect(field.attributes.has('name')).toBe(false);
    expect((row as unknown as { children: unknown[] }).children).toEqual([]);
    applyChange({ op: 'hide', selector: '#field' }, root);
    applyChange({ op: 'style', selector: '#label', property: 'color', value: 'red' }, root);
    expect(field.styles.get('display')).toBe('none');
    expect(label.styles.get('color')).toBe('red');
  });

  it('reads an address as the server does', () => {
    const runs: [string, boolean][] = [
      ['java\tscript:x', true],
      ['\u0001 JaVa\nScRiPt:x', true],
      ['vbscript:x', true],
      ['https://shop.example/javascript:x', false],
      ['/pricing', false],
      [' javascript:x', true],
      ['data:text/plain,x', false],
    ];
    for (const [value, expected] of runs) expect(valueRuns(value), value).toBe(expected);
    expect(elementForbidden('animateTransform')).toBe(true);
    expect(elementForbidden('div')).toBe(false);
    expect(attributeUnsafe('onClick')).toBe(true);
    expect(attributeUnsafe('online')).toBe(true);
    expect(attributeUnsafe('href')).toBe(false);
  });
});

describe('counting clicks', () => {
  const shown: Decision[] = [
    { experience_id: 'e1', variation_id: 'b', control: false, changes: [{ op: 'track_click', selector: 'a', name: 'any link' }, { op: 'track_click', selector: 'a.cta', name: 'cta' }] },
    { experience_id: 'e2', variation_id: 'c', control: false, changes: [{ op: 'track_click', selector: 'a.cta', name: 'cta' }] },
    { experience_id: 'e3', variation_id: 'b', control: false, changes: [{ op: 'track_click', selector: 'footer', name: 'footer' }] },
  ];

  it('reports one click once per experience that counts it', () => {
    const clicks = clickedChanges(shown, (selector) => selector === 'a' || selector === 'a.cta');
    expect(clicks).toEqual([
      { experience_id: 'e1', variation_id: 'b', name: 'any link' },
      { experience_id: 'e2', variation_id: 'c', name: 'cta' },
    ]);
  });
});

describe('the device a rule asks about', () => {
  it('is read from the User-Agent exactly as the server-side decide reads it', () => {
    const agents: [string, ReturnType<typeof userAgentFacts>][] = [
      [chrome, { os: 'macos', browser: 'chrome', device: 'desktop' }],
      ['Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1', { os: 'ios', browser: 'safari', device: 'mobile' }],
      ['Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/604.1', { os: 'ios', browser: 'safari', device: 'tablet' }],
      ['Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36', { os: 'android', browser: 'chrome', device: 'mobile' }],
      ['Mozilla/5.0 (Linux; Android 14; SM-X710) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36', { os: 'android', browser: 'chrome', device: 'tablet' }],
      ['Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:120.0) Gecko/20100101 Firefox/120.0', { os: 'windows', browser: 'firefox', device: 'desktop' }],
    ];
    for (const [ua, facts] of agents) expect(userAgentFacts(ua), ua).toEqual(facts);
  });

  it('reads an iPad’s Macintosh User-Agent as a tablet only where the page can count touch points', () => {
    const ipadSafari = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15';
    expect(userAgentFacts(ipadSafari, 5)).toEqual({ os: 'ios', browser: 'safari', device: 'tablet' });
    // A Mac, and the server, which has no touch points to read: the User-Agent's answer, still the server's exactly.
    expect(userAgentFacts(ipadSafari, 0)).toEqual({ os: 'macos', browser: 'safari', device: 'desktop' });
    expect(userAgentFacts(ipadSafari)).toEqual({ os: 'macos', browser: 'safari', device: 'desktop' });
    // A touch-screen Windows laptop is not an iPad.
    expect(userAgentFacts('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36', 10).device).toBe('desktop');
    const tabletOnly: WebExperienceWire = { ...experience, rules: [{ kind: 'device', devices: ['tablet'] }], variations: [{ id: 'b', weight: 100, changes: [] }] };
    const visitor = { id: 'v', href: 'https://shop.example/pricing', isNewVisitor: false, identified: false, now: new Date(), userAgent: ipadSafari };
    expect(decideExperiences([tabletOnly], { ...visitor, maxTouchPoints: 5 })).toHaveLength(1);
    expect(decideExperiences([tabletOnly], visitor)).toEqual([]);
  });

  it('decides a device rule on the page as the server does, whatever the window’s width', () => {
    const phone = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
    const mobileOnly: WebExperienceWire = { ...experience, rules: [{ kind: 'device', devices: ['mobile'] }], variations: [{ id: 'b', weight: 100, changes: [] }] };
    const visitor = { id: 'v', href: 'https://shop.example/pricing', isNewVisitor: false, identified: false, now: new Date(), userAgent: phone };
    expect(decideExperiences([mobileOnly], visitor)).toHaveLength(1);
    expect(decideExperiences([mobileOnly], { ...visitor, userAgent: chrome })).toEqual([]);
  });
});
