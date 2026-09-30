import { applyChange, writesInsideForbidden, type WebChange } from './experiences';

/*
 * The visual editor, drawn on the customer's own site.
 *
 * The dashboard cannot put somebody else's site in a frame and reach into it — the site's own headers forbid the one and
 * the browser the other — so the editor runs where the page is: the dashboard opens the site with
 * `?treebars_editor=<experience>:<variation>&treebars_origin=<dashboard origin>`, this SDK sees the parameter and draws a
 * toolbar instead of applying experiences, and the two talk by `postMessage`. Messages are accepted only from the
 * window that opened this one and only from the origin it named; changes are posted only to that origin.
 *
 * The named origin is only believed once Treebars has vouched for it (`startEditorIfTrusted` in `index.ts`): whoever
 * opens the tab writes the address, so without that check any page could name itself and draw on the customer's site.
 * And only on a site with `experiences: true` — a site that runs no experiences has no editor to open.
 *
 * What it offers: pick an element by pointing, then edit its text, hide or remove it, move it above or below its
 * neighbour, set its colour, background or size, count its clicks, or insert a widget after it. Every change is applied
 * here as it is made, through the same `applyChange` a visitor's page uses, so what the editor shows is what ships.
 */

export interface EditorParams {
  experienceId: string;
  variationId: string;
  origin: string;
}

/** Reads the editor parameters, or null when this page load is not an editing session. */
export function editorParams(href: string): EditorParams | null {
  try {
    const url = new URL(href);
    const target = url.searchParams.get('treebars_editor');
    const origin = url.searchParams.get('treebars_origin');
    if (!target || !origin) return null;
    const [experienceId, variationId] = target.split(':');
    if (!experienceId || !variationId || !/^https?:\/\/[^/]+$/.test(origin)) return null;
    return { experienceId, variationId, origin };
  } catch {
    return null;
  }
}

/** A selector for one element: its id when that is unique, else a path of tags and positions from the nearest id. */
export function selectorFor(element: Element): string {
  const escape = (value: string) => (typeof CSS !== 'undefined' && CSS.escape ? CSS.escape(value) : value.replace(/[^A-Za-z0-9_-]/g, '\\$&'));
  const parts: string[] = [];
  let node: Element | null = element;
  while (node && node.nodeType === 1 && node !== document.documentElement) {
    if (node.id && document.querySelectorAll(`#${escape(node.id)}`).length === 1) {
      parts.unshift(`#${escape(node.id)}`);
      return parts.join(' > ');
    }
    const tag = node.tagName.toLowerCase();
    const parent: Element | null = node.parentElement;
    if (!parent) {
      parts.unshift(tag);
      break;
    }
    const same = [...parent.children].filter((child) => child.tagName === node!.tagName);
    parts.unshift(same.length > 1 ? `${tag}:nth-of-type(${same.indexOf(node) + 1})` : tag);
    node = parent;
  }
  return parts.join(' > ');
}

interface Widget {
  key: string;
  name: string;
  html: string;
}

const PANEL =
  'position:fixed;right:16px;bottom:16px;z-index:2147483647;width:300px;max-height:70vh;overflow:auto;padding:12px;border-radius:12px;background:#1c1c1a;color:#fff;font:13px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;box-shadow:0 12px 40px rgba(0,0,0,.35)';
const BUTTON = 'font:inherit;padding:5px 9px;margin:2px;border-radius:6px;border:1px solid rgba(255,255,255,.25);background:transparent;color:#fff;cursor:pointer';

export function startVisualEditor(params: EditorParams): void {
  const changes: WebChange[] = [];
  let widgets: Widget[] = [];
  let picking = true;
  let selected: Element | null = null;

  const opener = window.opener as Window | null;
  const send = (message: Record<string, unknown>) => opener?.postMessage({ source: 'treebars-editor', ...message }, params.origin);

  const panel = document.createElement('div');
  panel.style.cssText = PANEL;
  panel.setAttribute('data-treebars-editor', '');
  const outline = document.createElement('div');
  outline.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483646;border:2px solid #3e63dd;border-radius:3px;display:none';
  document.body.append(outline, panel);

  const inEditor = (target: EventTarget | null) => target instanceof Node && panel.contains(target);
  const place = (element: Element | null) => {
    if (!element) {
      outline.style.display = 'none';
      return;
    }
    const box = element.getBoundingClientRect();
    Object.assign(outline.style, { display: 'block', left: `${box.left - 2}px`, top: `${box.top - 2}px`, width: `${box.width + 4}px`, height: `${box.height + 4}px` });
  };

  let refused: string | null = null;
  const add = (change: WebChange) => {
    /*
     * Only a change the page will make. Inside a form (or anything else that runs or loads) the page skips markup,
     * attributes, inserts and a move in (`writesInsideForbidden`), so the editor refuses such a change as it is made,
     * where the page can be seen, rather than saving one that would never appear.
     */
    const target = document.querySelector(change.selector);
    if (target && writesInsideForbidden(change, target)) {
      refused = 'That change cannot be made here: web experiences do not write inside a form.';
      draw();
      return;
    }
    refused = null;
    changes.push(change);
    applyChange(change);
    send({ type: 'changes', changes });
    draw();
  };

  const draw = () => {
    panel.replaceChildren();
    const title = document.createElement('div');
    title.style.cssText = 'font-weight:600;margin-bottom:6px';
    title.textContent = `Editing variation ${params.variationId}`;
    panel.appendChild(title);

    if (!selected) {
      const hint = document.createElement('p');
      hint.style.margin = '4px 0 8px';
      hint.textContent = picking ? 'Point at something on the page and click it.' : 'Picking is paused.';
      panel.appendChild(hint);
    } else {
      const selector = selectorFor(selected);
      const code = document.createElement('code');
      code.style.cssText = 'display:block;margin:4px 0 8px;word-break:break-all;opacity:.8';
      code.textContent = selector;
      panel.appendChild(code);
      const action = (label: string, run: () => void) => {
        const button = document.createElement('button');
        button.type = 'button';
        button.style.cssText = BUTTON;
        button.textContent = label;
        button.addEventListener('click', run);
        panel.appendChild(button);
      };
      action('Edit text', () => {
        const value = window.prompt('The new text', selected?.textContent?.trim() ?? '');
        if (value !== null) add({ op: 'text', selector, value });
      });
      action('Hide', () => add({ op: 'hide', selector }));
      action('Remove', () => add({ op: 'remove', selector }));
      const previous = selected.previousElementSibling;
      const next = selected.nextElementSibling;
      if (previous) action('Move up', () => add({ op: 'move', selector, target: selectorFor(previous), position: 'before' }));
      if (next) action('Move down', () => add({ op: 'move', selector, target: selectorFor(next), position: 'after' }));
      action('Colour', () => {
        const value = window.prompt('Text colour, as CSS', '#1c1c1a');
        if (value) add({ op: 'style', selector, property: 'color', value });
      });
      action('Background', () => {
        const value = window.prompt('Background, as CSS', '#fff5d6');
        if (value) add({ op: 'style', selector, property: 'background', value });
      });
      action('Size', () => {
        const value = window.prompt('Font size, as CSS', '18px');
        if (value) add({ op: 'style', selector, property: 'font-size', value });
      });
      action('Count clicks', () => {
        const name = window.prompt('A name for these clicks in the report', 'cta');
        if (name) add({ op: 'track_click', selector, name });
      });
      for (const widget of widgets) action(`+ ${widget.name}`, () => add({ op: 'insert', selector, position: 'after', html: widget.html, widget: widget.key }));
    }

    if (refused) {
      const note = document.createElement('p');
      note.style.cssText = 'margin:8px 0 0;color:#b3261e';
      note.textContent = refused;
      panel.appendChild(note);
    }

    const footer = document.createElement('div');
    footer.style.cssText = 'margin-top:10px;display:flex;flex-wrap:wrap;align-items:center;gap:4px';
    const count = document.createElement('span');
    count.style.cssText = 'flex:1;opacity:.8';
    count.textContent = `${changes.length} change${changes.length === 1 ? '' : 's'}`;
    const toggle = document.createElement('button');
    toggle.type = 'button';
    toggle.style.cssText = BUTTON;
    toggle.textContent = picking ? 'Pause picking' : 'Pick again';
    toggle.addEventListener('click', () => {
      picking = !picking;
      selected = null;
      place(null);
      draw();
    });
    const undo = document.createElement('button');
    undo.type = 'button';
    undo.style.cssText = BUTTON;
    undo.textContent = 'Undo';
    undo.disabled = changes.length === 0;
    // The page cannot un-apply a change, so undo reloads it: the dashboard keeps the list one shorter and hands it back.
    undo.addEventListener('click', () => {
      changes.pop();
      send({ type: 'changes', changes });
      location.reload();
    });
    footer.append(count, toggle, undo);
    panel.appendChild(footer);
  };

  document.addEventListener(
    'mouseover',
    (event) => {
      if (!picking || inEditor(event.target) || !(event.target instanceof Element)) return;
      place(event.target);
    },
    true,
  );
  document.addEventListener(
    'click',
    (event) => {
      if (!picking || inEditor(event.target) || !(event.target instanceof Element)) return;
      // A click while picking chooses the element; it does not follow the link or submit the form under it.
      event.preventDefault();
      event.stopPropagation();
      selected = event.target;
      place(selected);
      draw();
    },
    true,
  );

  window.addEventListener('message', (event) => {
    if (event.origin !== params.origin || event.source !== opener) return;
    const data = event.data as { source?: string; type?: string; changes?: WebChange[]; widgets?: Widget[] } | null;
    if (data?.source !== 'treebars-dashboard' || data.type !== 'load') return;
    widgets = Array.isArray(data.widgets) ? data.widgets : [];
    changes.splice(0, changes.length, ...(Array.isArray(data.changes) ? data.changes : []));
    for (const change of changes) applyChange(change);
    draw();
  });

  draw();
  send({ type: 'ready', experience_id: params.experienceId, variation_id: params.variationId });
}
