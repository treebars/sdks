import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import type { InAppContent, InAppMessage } from '../src/in-app';
import { renderBuiltIn } from '../src/on-site';
import { FakeNode, install } from './fake-dom';

/**
 * The built-in renderer's typed body: what an old message with fields rather than markup draws, and what a press in
 * it does. A carousel steps and moves on by itself, a countdown ticks, the buttons record and close, a store review is
 * not offered in a browser, and a form checks its answers before it sends them and thanks the person.
 */

let body: FakeNode;
let doc: FakeNode;

beforeEach(() => {
  vi.useFakeTimers({ now: Date.parse('2026-10-11T12:00:00.000Z') });
  ({ body, doc } = install());
  // What the form's controls are made of in a browser.
  vi.stubGlobal('Option', class extends FakeNode {
    constructor(text: string, value: string) {
      super('option');
      this.textContent = text;
      this.value = value;
    }
  });
  vi.stubGlobal('HTMLInputElement', FakeNode);
  vi.stubGlobal('window', { addEventListener() {}, removeEventListener() {} });
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

function draw(inApp: Partial<InAppContent> & Record<string, unknown>, words: { title?: string; body?: string; image_url?: string } = { title: 'Autumn sale', body: 'Thirty percent off' }) {
  const message: InAppMessage = {
    delivery_id: 'd1',
    campaign_id: 'c1',
    content: { ...words, in_app: { surface: 'overlay', layout: 'modal', trigger: { kind: 'immediate' }, ...inApp } as InAppContent },
    created_at: '2026-10-11T12:00:00.000Z',
    expires_at: null,
  };
  const seen: string[] = [];
  renderBuiltIn({
    message,
    tokens: null,
    onClick: (button) => seen.push(`click ${button.label}`),
    onDismiss: (reason) => seen.push(`dismiss${reason ? ` ${reason}` : ''}`),
    onSubmit: (responses) => seen.push(`submit ${JSON.stringify(responses)}`),
    onShown: () => seen.push('shown'),
  });
  return { seen, dialog: () => body.find((node) => node.getAttribute('role') === 'dialog'), drawn: () => body.children.length > 0 };
}

describe('the typed body', () => {
  it('draws its picture with what it shows, its words, and is counted as shown once drawn', () => {
    const { seen, dialog } = draw({ image_alt: 'A coat on a hook' }, { title: 'Autumn sale', body: 'Thirty percent off', image_url: 'https://cdn.test/coat.png' });
    const image = dialog()!.find((node) => node.tagName === 'img')!;
    expect(image.src).toBe('https://cdn.test/coat.png');
    expect(image.alt).toBe('A coat on a hook');
    expect(dialog()!.getAttribute('aria-label')).toBe('Autumn sale');
    expect(dialog()!.textContent).toContain('Thirty percent off');
    expect(seen).toEqual(['shown']);
  });

  it('a press records and closes; a dismiss button is a dismissal too; a store review is not offered in a browser', () => {
    const { seen, drawn } = draw({
      buttons: [
        { label: 'Rate us', action: 'store_review' },
        { label: 'Later', action: 'dismiss' },
        { label: 'Shop now', action: 'deep_link', value: '/sale' },
      ],
    } as never);
    expect(body.byName('Rate us')).toBeUndefined();
    body.byName('Shop now')!.click();
    expect(seen).toEqual(['shown', 'click Shop now']);
    expect(drawn()).toBe(false);

    const second = draw({ buttons: [{ label: 'Later', action: 'dismiss' }] } as never);
    body.byName('Later')!.click();
    expect(second.seen).toEqual(['shown', 'click Later', 'dismiss']);
  });

  it('Escape and the close control dismiss it; a message that cannot be dismissed has neither', () => {
    const first = draw({});
    doc.fire('keydown', { key: 'Escape' });
    expect(first.seen).toEqual(['shown', 'dismiss']);

    const second = draw({});
    body.byName('Close')!.click();
    expect(second.seen).toEqual(['shown', 'dismiss']);

    const third = draw({ dismissible: false, buttons: [{ label: 'OK', action: 'dismiss' }] } as never);
    expect(body.byName('Close')).toBeUndefined();
    doc.fire('keydown', { key: 'Escape' });
    expect(third.seen).toEqual(['shown']);
  });

  it('closes itself after the seconds asked, saying so', () => {
    const { seen } = draw({ display: { auto_dismiss_seconds: 8 } });
    vi.advanceTimersByTime(7_999);
    expect(seen).toEqual(['shown']);
    vi.advanceTimersByTime(1);
    expect(seen).toEqual(['shown', 'dismiss auto']);
  });

  it('a countdown ticks every second to its moment', () => {
    const { dialog } = draw({ countdown_to: '2026-10-13T13:02:03.000Z' });
    const clock = () => dialog()!.find((node) => node.tagName === 'div' && /^\d+d |^\d{2}:/.test(node.textContent) && node.children.length === 0)!;
    expect(clock().textContent).toBe('2d 01:02:03');
    vi.advanceTimersByTime(1_000);
    expect(clock().textContent).toBe('2d 01:02:02');
  });

  it('a carousel steps both ways, wraps, and moves on by itself', () => {
    const { dialog } = draw({
      slides: [
        { image_url: 'https://cdn.test/1.png', title: 'One', image_alt: 'First' },
        { image_url: 'https://cdn.test/2.png', title: 'Two' },
        { image_url: 'https://cdn.test/3.png', title: 'Three' },
      ],
    } as never);
    const image = () => dialog()!.find((node) => node.tagName === 'img')!;
    expect(image().src).toBe('https://cdn.test/1.png');
    expect(image().alt).toBe('First');
    body.byName('Previous')!.click();
    expect(image().src).toBe('https://cdn.test/3.png');
    body.byName('Next')!.click();
    body.byName('Next')!.click();
    expect(image().src).toBe('https://cdn.test/2.png');
    expect(dialog()!.textContent).toContain('Two');
    vi.advanceTimersByTime(5_000);
    expect(image().src).toBe('https://cdn.test/3.png');
  });

  it('a top banner is a bar across the page, and takes no hold of the keyboard', () => {
    const { dialog } = draw({ layout: 'banner', position: 'top' });
    expect(dialog()!.style.cssText).toContain('top:0');
    expect(dialog()!.getAttribute('aria-modal')).toBe('false');
  });
});

describe('a form', () => {
  const fields = [
    { id: 'name', kind: 'text', label: 'Your name', required: true },
    { id: 'email', kind: 'email', label: 'Email' },
    { id: 'age', kind: 'number', label: 'Age' },
    { id: 'born', kind: 'date', label: 'Birthday' },
    { id: 'size', kind: 'choice', label: 'Size', options: ['S', 'M', 'L'], placeholder: 'Pick one' },
    { id: 'likes', kind: 'multi_choice', label: 'Likes', options: ['Coats', 'Boots', 'Hats'] },
    { id: 'stars', kind: 'rating', label: 'Stars' },
    { id: 'nps', kind: 'nps', label: 'Recommend' },
  ];
  const control = (label: string, tag: string) => body.find((node) => node.tagName === 'label' && node.textContent.startsWith(label))!.find((node) => node.tagName === tag)!;
  const type = (label: string, value: string) => {
    const input = control(label, 'input');
    input.value = value;
    input.fire('input');
  };
  const send = () => body.find((node) => node.tagName === 'form')!.fire('submit');
  const problem = () => body.find((node) => node.tagName === 'p' && node.style.cssText.includes('#b42318'))!.textContent;

  it('says what is missing or wrong before it sends, one thing at a time', () => {
    const { seen } = draw({ form: { fields } } as never);
    send();
    expect(problem()).toBe('“Your name” needs an answer');
    type('Your name', 'Mona');
    type('Email', 'not-an-address');
    send();
    expect(problem()).toBe('That email address does not look right');
    type('Email', 'mona@shop.test');
    type('Age', 'thirty');
    send();
    expect(problem()).toBe('“Age” needs a number');
    type('Age', '30');
    type('Birthday', '2026-02-30');
    send();
    expect(problem()).toBe('“Birthday” needs a date');
    expect(seen).toEqual(['shown']);
  });

  it('sends every kind of answer in its own shape, thanks the person, and goes', () => {
    const { seen, drawn } = draw({ form: { fields, thanks: 'Thanks, Mona', submit_label: 'Join' } } as never);
    expect(body.byName('Join')).toBeDefined();
    type('Your name', ' Mona ');
    type('Age', '30');
    type('Birthday', '1996-05-04');
    const select = control('Size', 'select');
    expect(select.children.map((option) => option.textContent)).toEqual(['Pick one', 'S', 'M', 'L']);
    select.value = 'M';
    select.fire('change');
    for (const option of ['Hats', 'Coats']) {
      const box = body.find((node) => node.tagName === 'label' && node.textContent === option)!.find((node) => node.tagName === 'input')!;
      Object.assign(box, { checked: true });
      box.fire('change');
    }
    // Four stars, and a nine out of ten.
    body.find((node) => node.tagName === 'label' && node.textContent.startsWith('Stars'))!.byName('4')!.click();
    body.find((node) => node.tagName === 'label' && node.textContent.startsWith('Recommend'))!.byName('9')!.click();
    send();
    expect(seen).toEqual(['shown', `submit ${JSON.stringify({ name: 'Mona', age: 30, born: '1996-05-04', size: 'M', likes: 'Coats,Hats', stars: 4, nps: 9 })}`]);
    expect(body.textContent).toContain('Thanks, Mona');
    vi.advanceTimersByTime(2_500);
    expect(drawn()).toBe(false);
  });
});

describe('a markup body', () => {
  /** The bridge's calls arrive on the window; the frame's own window is what a call must come from. */
  let listeners: Array<(event: { source: unknown; data: unknown }) => void>;
  beforeEach(() => {
    listeners = [];
    const create = (document as unknown as { createElement: (tag: string) => FakeNode }).createElement;
    (document as unknown as { createElement: (tag: string) => FakeNode }).createElement = (tag: string) => {
      const node = create(tag);
      if (tag === 'iframe') Object.assign(node, { contentWindow: { postMessage() {} } });
      return node;
    };
    vi.stubGlobal('window', {
      innerHeight: 800,
      addEventListener: (type: string, listener: (event: { source: unknown; data: unknown }) => void) => type === 'message' && listeners.push(listener),
      removeEventListener: () => {},
    });
  });

  const frame = () => body.find((node) => node.tagName === 'iframe')!;
  const say = (method: string, args: unknown[] = []) => {
    const nonce = /"nonce":"([0-9a-f]+)"/.exec(frame().getAttribute('srcdoc') ?? '')![1];
    for (const listener of listeners) listener({ source: (frame() as unknown as { contentWindow: unknown }).contentWindow, data: JSON.stringify({ tb: nonce, id: 1, method, args }) });
  };

  // A modal is a stage (bridge 2): a frame over the whole window, revealed once the page says where its container is.
  it('stays hidden until it runs and lays its container out, and is counted only then', () => {
    const { seen, dialog } = draw({ body_mode: 'html', html: '<p>Hi</p>' });
    expect(dialog()!.style.visibility).toBe('hidden');
    expect(seen).toEqual([]);
    say('_ready');
    say('_layout', [{ container: { x: 40, y: 280, w: 320, h: 240 } }]);
    expect(dialog()!.style.visibility).toBe('visible');
    expect(seen).toEqual(['shown']);
    // Escape pressed inside the frame never reaches the page; the shim passes it on.
    say('_key', ['Escape']);
    expect(seen).toEqual(['shown', 'dismiss']);
  });

  it('one that never lays itself out is shown after a second rather than never', () => {
    const { seen, dialog } = draw({ body_mode: 'html', html: '<p>Hi</p>' });
    say('_ready');
    expect(seen).toEqual([]);
    vi.advanceTimersByTime(1_000);
    expect(dialog()!.style.visibility).toBe('visible');
    expect(seen).toEqual(['shown']);
  });

  /*
   * A modal with nothing behind it (stage's web placement, carried by the document's presentation): the page under it
   * stays usable, so its frame is clipped to the container the page laid out, and in a corner it folds into a tab.
   */
  const floating = (minimise?: Record<string, unknown>) => {
    const drawn = draw({ body_mode: 'html', html: '<p>Hi</p>', presentation: { bridge: 2, mode: 'stage', dismissible: true, web: { float: true, ...(minimise ? { minimise } : {}) } } });
    Object.assign(drawn.dialog()!, { getBoundingClientRect: () => ({ left: 0, top: 0, width: 1200, height: 800, right: 1200, bottom: 800 }) });
    return drawn;
  };

  it('a floating modal leaves the page usable: not modal, and its frame clipped to its container', () => {
    const { seen, dialog } = floating();
    expect(dialog()!.getAttribute('aria-modal')).toBe('false');
    say('_ready');
    say('_layout', [{ container: { x: 840, y: 500, w: 340, h: 280 } }]);
    expect(seen).toEqual(['shown']);
    expect(dialog()!.style.clipPath).toBe('inset(476px 0px 0px 816px)');
    expect(body.find((node) => node.getAttribute('aria-label') === 'Minimise')).toBeUndefined();
  });

  it('minimised, it folds into a tab with its name and opens again; drawn folded, it is still counted', () => {
    const { seen, dialog } = floating({ label: 'Sale' });
    say('_ready');
    say('_layout', [{ container: { x: 840, y: 500, w: 340, h: 280 } }]);
    const handle = body.find((node) => node.getAttribute('aria-label') === 'Minimise')!;
    const tab = body.find((node) => (node.getAttribute('aria-label') ?? '').startsWith('Open: '))!;
    // The container is in the bottom right, so the tab sits on the bottom edge at the right.
    expect(tab.style.cssText).toContain('bottom:0');
    expect(tab.style.cssText).toContain('right:16px');
    handle.fire('click');
    expect(dialog()!.style.visibility).toBe('hidden');
    expect(tab.textContent).toBe('Sale ⌃');
    say('_key', ['Escape']);
    expect(seen).toEqual(['shown']);
    tab.fire('click');
    expect(dialog()!.style.visibility).toBe('visible');

    body.children.length = 0;
    const later = floating({ start: true });
    say('_ready');
    say('_layout', [{ container: { x: 20, y: 20, w: 340, h: 280 } }]);
    expect(later.dialog()!.style.visibility).toBe('hidden');
    expect(later.seen).toEqual(['shown']);
  });

  it('a nudge joins a stack at its edge, interrupts nothing, and the stack goes with the last one', () => {
    const { seen, dialog } = draw({ layout: 'nudge', body_mode: 'html', html: '<p>Hi</p>', position: 'top' });
    const stack = body.find((node) => node.getAttribute('data-treebars-nudges') === 'top')!;
    expect(stack.style.cssText).toContain('pointer-events:none');
    expect(dialog()!.getAttribute('aria-modal')).toBe('false');
    say('_ready');
    say('resize', [90]);
    expect(seen).toEqual(['shown']);
    // Escape is for what interrupts; a nudge closes by its own control.
    say('_key', ['Escape']);
    expect(seen).toEqual(['shown']);
    say('dismissMessage');
  });
});
