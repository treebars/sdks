import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { changeOutcome, type WebChange } from '../src/experiences';
import { FakeElement, fakeDocument } from './fake-dom';

/*
 * The visual editor names an element by its position (`body > main > section:nth-of-type(1) > h1`) whenever it has no
 * id of its own, which on most sites is every element. So a remove, a move or an insert applied again on every
 * re-decision must land on the SAME element each time, even though, once it has been applied, the position names the
 * next one along.
 */

function sections(count: number): FakeElement[] {
  return Array.from({ length: count }, (_, index) => new FakeElement('section', { class: 'band' }, [new FakeElement('h2', { 'data-name': `s${index + 1}` })]));
}

const names = (parent: FakeElement) => parent.children.filter((child) => child.getAttribute('data-treebars-removed') === null).map((child) => child.children[0]?.getAttribute('data-name') ?? child.localName);

describe('a positional change applied again', () => {
  let main: FakeElement;

  beforeEach(() => {
    main = new FakeElement('main', {}, sections(4));
    vi.stubGlobal('document', fakeDocument(new FakeElement('body', {}, [main])));
  });
  afterEach(() => vi.unstubAllGlobals());

  it('removes one section, however many times the page is decided', () => {
    const change: WebChange = { op: 'remove', selector: 'main > section:first-of-type' };
    for (let i = 0; i < 4; i += 1) expect(changeOutcome(change, document)).toBe('applied');
    expect(names(main)).toEqual(['s2', 's3', 's4']);
  });

  it('moves one section once, rather than flipping two back and forth', () => {
    const change: WebChange = { op: 'move', selector: 'main > section:nth-of-type(1)', target: 'main > section:nth-of-type(3)', position: 'after' };
    for (let i = 0; i < 3; i += 1) changeOutcome(change, document);
    expect(names(main)).toEqual(['s2', 's3', 's1', 's4']);
  });

  it('inserts one widget before a positional element, not one per re-decision', () => {
    // The holder is a div, so before a div it takes that div's position — and the same selector would find the holder
    // next time.
    const divs = new FakeElement('div', {}, [new FakeElement('div', { id: 'one' }), new FakeElement('div', { id: 'two' })]);
    main.append(divs);
    const change: WebChange = { op: 'insert', selector: 'main > div > div:nth-of-type(1)', position: 'before', html: '<p>Hi</p>' };
    for (let i = 0; i < 3; i += 1) changeOutcome(change, document);
    expect(divs.children.map((child) => child.id || 'widget')).toEqual(['widget', 'one', 'two']);
  });

  it('can be taken back, and a stand-in leaves no trace when it is', () => {
    const restores: (() => void)[] = [];
    changeOutcome({ op: 'remove', selector: 'main > section:nth-of-type(2)' }, document, (restore) => restores.push(restore));
    changeOutcome({ op: 'move', selector: 'main > section:nth-of-type(1)', target: 'main > section:nth-of-type(4)', position: 'after' }, document, (restore) => restores.push(restore));
    expect(names(main)).toEqual(['s3', 's4', 's1']);
    for (const restore of restores.reverse()) restore();
    expect(names(main)).toEqual(['s1', 's2', 's3', 's4']);
    expect(main.children).toHaveLength(4);
  });

  it('hides a stand-in through the style object, which a strict style-src does not block', () => {
    changeOutcome({ op: 'remove', selector: 'main > section:nth-of-type(1)' }, document);
    const standIn = main.children[0]!;
    expect(standIn.getAttribute('data-treebars-removed')).toBe('');
    expect(standIn.getAttribute('style')).toBeNull();
    expect([standIn.style.getPropertyValue('display'), standIn.style.getPropertyPriority('display')]).toEqual(['none', 'important']);
  });

  it('leaves no live control behind a removed button or option inside a form', () => {
    const select = new FakeElement('select', { name: 'size' }, [new FakeElement('option', { value: 'm' }), new FakeElement('option', { value: 'l' })]);
    const form = new FakeElement('form', {}, [select, new FakeElement('button', {}), new FakeElement('button', { type: 'submit', id: 'buy' })]);
    main.append(form);
    changeOutcome({ op: 'remove', selector: 'main > form > select > option:nth-of-type(1)' }, document);
    changeOutcome({ op: 'remove', selector: 'main > form > button:nth-of-type(1)' }, document);
    const [option] = select.children;
    const [button] = form.children.filter((child) => child.localName === 'button');
    expect(option!.getAttribute('data-treebars-removed')).toBe('');
    expect(option!.getAttribute('disabled')).toBe('');
    expect(option!.getAttribute('value')).toBeNull();
    expect([button!.getAttribute('type'), button!.getAttribute('disabled')]).toEqual(['button', '']);
  });
});
