import { afterEach, describe, expect, it, vi } from 'vitest';

import { formKeeps, type InAppContent, type InAppMessage } from '../src/in-app';
import { isDay, renderBuiltIn, type InAppFormField } from '../src/on-site';

/**
 * A form's other kinds: a number, a date, a dropdown and several choices drawn by the built-in renderer and sent as the
 * apps send them, and an answer kept as a trait only when the message declares it.
 */

class FakeNode {
  attributes = new Map<string, string>();
  children: FakeNode[] = [];
  style = { cssText: '', background: '', color: '' };
  textContent = '';
  type = '';
  value = '';
  checked = false;
  noValidate = false;
  listeners: Record<string, ((event: unknown) => void)[]> = {};
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
  replaceChildren(...nodes: FakeNode[]) {
    this.children = nodes;
  }
  addEventListener(type: string, listener: (event: unknown) => void) {
    (this.listeners[type] ??= []).push(listener);
  }
  fire(type: string) {
    for (const listener of this.listeners[type] ?? []) listener({ preventDefault() {} });
  }
  remove() {}
  all(predicate: (node: FakeNode) => boolean, into: FakeNode[] = []): FakeNode[] {
    if (predicate(this)) into.push(this);
    for (const child of this.children) if (child instanceof FakeNode) child.all(predicate, into);
    return into;
  }
}
class FakeInput extends FakeNode {}
class FakeOption {
  constructor(
    public text: string,
    public value: string,
  ) {}
}

const fields: InAppFormField[] = [
  { id: 'age', kind: 'number', label: 'Age', placeholder: 'In years', trait: 'age' },
  { id: 'born', kind: 'date', label: 'Birthday' },
  { id: 'store', kind: 'dropdown', label: 'Store', options: ['Dubai', 'Cairo'], placeholder: 'Choose a store' },
  { id: 'likes', kind: 'multi_choice', label: 'Likes', options: ['Coats', 'Shoes', 'Bags'], trait: 'likes' },
];

function draw() {
  const body = new FakeNode('body');
  vi.stubGlobal('document', { createElement: (tag: string) => (tag === 'input' ? new FakeInput(tag) : new FakeNode(tag)), body, head: new FakeNode('head'), addEventListener() {}, removeEventListener() {} });
  vi.stubGlobal('HTMLInputElement', FakeInput);
  vi.stubGlobal('Option', FakeOption);
  const sent: Record<string, string | number>[] = [];
  const message: InAppMessage = {
    delivery_id: 'd1',
    campaign_id: 'c1',
    content: { title: 'Tell us', in_app: { surface: 'overlay', layout: 'modal', trigger: { kind: 'immediate' }, form: { fields } } as InAppContent },
    created_at: '2026-09-28T12:00:00.000Z',
    expires_at: null,
  };
  renderBuiltIn({ message, tokens: null, onClick: () => {}, onDismiss: () => {}, onSubmit: (responses) => sent.push(responses) });
  const form = body.all((node) => node.tagName === 'form')[0]!;
  return { body, form, sent };
}

describe('the built-in renderer’s form', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('draws a number and a date as the browser’s own inputs, with the placeholder', () => {
    const { body } = draw();
    const inputs = body.all((node) => node instanceof FakeInput && node.type !== 'checkbox');
    expect(inputs.map((input) => input.type)).toEqual(['number', 'date']);
    expect(inputs[0]!.getAttribute('placeholder')).toBe('In years');
  });

  it('says the dropdown’s placeholder on its empty first line, and draws several choices as boxes', () => {
    const { body } = draw();
    const select = body.all((node) => node.tagName === 'select')[0]!;
    expect((select.children[0] as unknown as FakeOption).text).toBe('Choose a store');
    expect(body.all((node) => node.type === 'checkbox').map((box) => box.value)).toEqual(['Coats', 'Shoes', 'Bags']);
  });

  it('sends a number as a number, the picks in the author’s order, and refuses a day that does not exist', () => {
    const { body, form, sent } = draw();
    const [age, born] = body.all((node) => node instanceof FakeInput && node.type !== 'checkbox');
    age!.value = ' 31 ';
    age!.fire('input');
    born!.value = '2026-02-30';
    born!.fire('input');
    const [coats, , bags] = body.all((node) => node.type === 'checkbox');
    bags!.checked = true;
    bags!.fire('change');
    coats!.checked = true;
    coats!.fire('change');
    form.fire('submit');
    expect(sent).toEqual([]);
    expect(body.all((node) => node.tagName === 'p').some((node) => node.textContent === '“Birthday” needs a date')).toBe(true);
    born!.value = '1995-06-01';
    born!.fire('input');
    form.fire('submit');
    expect(sent).toEqual([{ age: 31, born: '1995-06-01', likes: 'Coats,Bags' }]);
  });

  it('knows a day that exists', () => {
    expect(isDay('2024-02-29')).toBe(true);
    expect(isDay('2023-02-29')).toBe(false);
    expect(isDay('01/06/1995')).toBe(false);
  });
});

describe('what a sent form keeps', () => {
  const message = (declared: string[]): Pick<InAppMessage, 'content'> => ({
    content: {
      in_app: {
        surface: 'overlay',
        layout: 'modal',
        declared: { events: [], traits: declared },
        form: { fields: [...fields, { id: 'email', kind: 'email', label: 'Email', save_as: 'email' }, { id: 'id', kind: 'text', label: 'Id', trait: 'user_id' }] },
      } as InAppContent,
    },
  });

  it('keeps an address, and a trait only when the message declares it and the product does not keep it', () => {
    const responses = { age: 31, likes: 'Coats,Bags', email: 'a@b.co', id: 'someone-else' };
    expect(formKeeps(message(['age', 'likes', 'user_id']), responses)).toEqual({ addresses: { email: 'a@b.co' }, traits: { age: 31, likes: 'Coats,Bags' } });
    // A trait the message never declared is not set, whatever the field says.
    expect(formKeeps(message(['age']), responses).traits).toEqual({ age: 31 });
    // And an empty answer keeps nothing.
    expect(formKeeps(message(['age']), { age: '' }).traits).toEqual({});
  });
});
