import { BRIDGE_HOST_METHODS, BRIDGE_SHIM, IN_APP_FRAME_CSP, IN_APP_FRAME_RULES, IN_APP_FRAME_SANDBOX } from './generated/bridge';

/*
 * The web's host for an HTML in-app message's `treebars` bridge.
 *
 * A message's markup runs in a frame sandboxed with `allow-scripts` and nothing else — no same origin, so it can reach
 * neither the customer's page nor its storage; no popups and no top navigation, so every link comes here. The shim the
 * generator wrote (`generated/bridge.ts`) goes in front of the markup with the frame's policy; this file carries its
 * calls to the SDK and the SDK's answers back, and decides nothing about what a call means — `index.ts` does.
 *
 * **Who may call.** A sandboxed frame posts with origin `"null"`, so an origin check proves nothing on its own. A
 * message is taken only when its source is this frame's window AND it carries this display's nonce, which exists
 * nowhere but in the document handed to the frame.
 *
 * **Strict-CSP sites.** A `srcdoc` frame inherits the policy of the page around it, so on a site whose `script-src`
 * refuses inline script, the shim never runs. The frame is kept hidden until the shim says `_ready`; one that finishes
 * loading without saying it was stopped, and the same document is drawn again inside a frame served from Treebars
 * (`frameUrl`), whose policy Treebars sets. If that is refused too, nothing was ever shown, and the caller reports
 * `csp_blocked` — a message whose buttons are dead is worse than one that is not there.
 */

export type FrameMode = 'srcdoc' | 'hosted';

export interface MarkupHostOptions {
  /** The message body as delivered: a fragment, or a document of its own. */
  html: string;
  direction?: 'ltr' | 'rtl';
  /** The frame's accessible name. */
  title: string;
  /** Where the frame goes. */
  parent: Node;
  /** The Treebars frame for a strict-CSP site, or null where there is none to fall back to. */
  frameUrl: string | null;
  /** Which frame to draw first: `hosted` when this session has already found `srcdoc` blocked. */
  mode: FrameMode;
  /** A call from the page's `treebars`, answered with whatever the returned value resolves to. */
  handle(method: string, args: unknown[]): unknown;
  /** The shim is running: the message may be shown. `mode` is the frame that worked. */
  onReady(mode: FrameMode): void;
  /** The content's height in CSS pixels, each time it changes. */
  onHeight(height: number): void;
  /** Neither frame ran the shim: the site's policy refused both. Nothing was shown. */
  onBlocked(): void;
  /** The page navigated its own frame away after it was shown: the message is gone. */
  onGone(): void;
  /** Which kind of device this browser is, for `data-tb-show`: the session rules' `deviceClass()`. */
  device?: 'mobile' | 'tablet' | 'desktop' | null;
  /**
   * Which way the window is held, for `data-tb-orientation`: by default the page's own, and followed as it turns.
   * A caller names one only to pin it — a test, or a preview drawn at a device's size.
   */
  orientation?: 'portrait' | 'landscape' | null;
  /** A key pressed inside the frame that the page should hear: Escape. */
  onKey?(key: string): void;
}

export interface MarkupHost {
  frame: HTMLIFrameElement;
  /** Focus into the message, onto its first control. */
  focus(): void;
  destroy(): void;
}

/** How long after a frame's `load` its shim may still say it is running. It runs before `load`; this is slack. */
const READY_AFTER_LOAD_MS = 400;
/** The Treebars frame loads a page first and then the message inside it, so it gets longer. */
const HOSTED_READY_MS = 3000;

const HOST_METHODS: ReadonlySet<string> = new Set(BRIDGE_HOST_METHODS);

/** Whether markup is a document of its own rather than a fragment. */
export function isMarkupDocument(html: string): boolean {
  return /^\s*(<!doctype\b|<html\b)/i.test(html);
}

function escapeAttribute(value: string): string {
  return value.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');
}

/** Safe-area insets in CSS pixels. The web has none of its own; the apps pass theirs. */
export interface BridgeInsets {
  top: number;
  right: number;
  bottom: number;
  left: number;
}

/**
 * The document the frame is handed. It matches Treebars' reference implementation byte for byte, for every host, as
 * the golden cases in `test/fixtures/bridge-documents.json` check.
 *
 * The policy and the shim come before anything of the message's. A fragment is framed as the preview and the apps
 * frame it (`IN_APP_FRAME_RULES`). A document is kept as a document, since HTML templates are often written as whole
 * pages: the policy and the shim go straight after its doctype, where the parser puts them in the head it has not yet
 * been shown, and the document's own `<html>` attributes still apply. `rtl` goes on `<html>` only when the author has
 * not said.
 */
export function bridgeDocument(
  html: string,
  options: {
    host: 'web' | 'android' | 'ios';
    nonce: string;
    direction?: 'ltr' | 'rtl' | null;
    insets?: BridgeInsets | null;
    device?: 'mobile' | 'tablet' | 'desktop' | null;
    orientation?: 'portrait' | 'landscape' | null;
  },
): string {
  const policy = `<meta http-equiv="Content-Security-Policy" content="${escapeAttribute(IN_APP_FRAME_CSP)}">`;
  const shim = `<script>${BRIDGE_SHIM}({"host":"${options.host}","nonce":"${options.nonce}"})</script>`;
  const insets = options.insets;
  const safe = insets
    ? `<style>:root{--tb-safe-top:${insets.top}px;--tb-safe-right:${insets.right}px;--tb-safe-bottom:${insets.bottom}px;--tb-safe-left:${insets.left}px}</style>`
    : '';
  // The device class hides every `data-tb-show` element not listed for it.
  const device = options.device === 'mobile' || options.device === 'tablet' || options.device === 'desktop' ? options.device : null;
  const shown = device ? `<style>[data-tb-show]:not([data-tb-show~="${device}"]){display:none!important}</style>` : '';
  // The way the device is held, in a rule of its own that the shim rewrites when it turns.
  const orientation = options.orientation === 'portrait' || options.orientation === 'landscape' ? options.orientation : null;
  const held = orientation ? `<style id="tb-orientation">[data-tb-orientation]:not([data-tb-orientation~="${orientation}"]){display:none!important}</style>` : '';
  const dir = options.direction === 'rtl' && !/<(html|body)\b[^>]*\sdir\s*=/i.test(html) ? '<html dir="rtl">' : '';
  if (isMarkupDocument(html)) {
    const found = /^\s*<!doctype[^>]*>/i.exec(html)?.[0];
    return `${found ?? '<!doctype html>'}${dir}${policy}${safe}${shown}${held}${shim}${html.slice(found?.length ?? 0)}`;
  }
  return `<!doctype html>${dir}<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">${policy}<style>${IN_APP_FRAME_RULES}</style>${safe}${shown}${held}${shim}${html}`;
}

/** A nonce for one display: unguessable, and in nothing but the document the frame is handed. */
export function displayNonce(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
}

interface Call {
  tb?: unknown;
  id?: unknown;
  method?: unknown;
  args?: unknown;
}

/**
 * How this window is held: landscape when it is wider than it is tall, as `(orientation: landscape)` says. Null
 * where there is no `matchMedia` to ask, which stamps nothing and so hides nothing.
 */
export function pageOrientation(): 'portrait' | 'landscape' | null {
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return null;
  return window.matchMedia('(orientation: portrait)').matches ? 'portrait' : 'landscape';
}

/** Draws the markup in a sandboxed frame and carries its bridge. Returns the frame and a way to take it all down. */
export function hostMarkup(options: MarkupHostOptions): MarkupHost {
  const nonce = displayNonce();
  const pinned = options.orientation !== undefined;
  let held = pinned ? (options.orientation ?? null) : pageOrientation();
  const document_ = bridgeDocument(options.html, { host: 'web', nonce, direction: options.direction, device: options.device ?? null, orientation: held });
  let frame = createFrame();
  let mode: FrameMode = options.mode === 'hosted' && options.frameUrl ? 'hosted' : 'srcdoc';
  let ready = false;
  let loads = 0;
  let destroyed = false;
  const timers: ReturnType<typeof setTimeout>[] = [];

  function createFrame(): HTMLIFrameElement {
    const created = document.createElement('iframe');
    created.setAttribute('sandbox', IN_APP_FRAME_SANDBOX);
    created.setAttribute('title', options.title);
    created.style.cssText = 'border:0;display:block;width:100%;height:100%;background:transparent;color-scheme:normal';
    return created;
  }

  function reply(id: number, result: unknown): void {
    try {
      // nosemgrep: treebars-postmessage-any-origin — the sandboxed frame's origin is opaque, so no target origin can name it; a frame that navigates away is taken down on its next load (`onGone`), and a reply holds nothing the message could not already read.
      frame.contentWindow?.postMessage(JSON.stringify({ tb: nonce, reply: id, result: result === undefined ? null : result }), '*');
    } catch {
      /* a frame that has gone takes its answer with it */
    }
  }

  function onMessage(event: MessageEvent): void {
    if (destroyed || event.source !== frame.contentWindow) return;
    let call: Call;
    try {
      call = (typeof event.data === 'string' ? JSON.parse(event.data) : event.data) as Call;
    } catch {
      return;
    }
    if (!call || call.tb !== nonce || typeof call.method !== 'string' || typeof call.id !== 'number') return;
    const id = call.id;
    const args = Array.isArray(call.args) ? call.args : [];
    if (call.method === '_ready') {
      if (!ready) {
        ready = true;
        for (const timer of timers.splice(0)) clearTimeout(timer);
        // A turn while the frame was loading reached no shim: said now, if the window is held the other way.
        if (!pinned) turned();
        options.onReady(mode);
      }
      reply(id, { ok: true });
      return;
    }
    // A key pressed inside the frame, which never reaches the page's own listeners: Escape, for the renderer.
    if (call.method === '_key') {
      if (typeof args[0] === 'string') options.onKey?.(args[0]);
      reply(id, { ok: true });
      return;
    }
    if (call.method === 'resize') {
      const height = Number(args[0]);
      if (Number.isFinite(height) && height >= 0) options.onHeight(height);
      reply(id, { ok: true });
      return;
    }
    // A method the table gives no host of this one (`requestStoreReview` on the web) still answers, never hangs.
    if (!HOST_METHODS.has(call.method)) {
      reply(id, { ok: false, reason: 'unsupported' });
      return;
    }
    Promise.resolve()
      .then(() => options.handle(call.method as string, args))
      .then(
        (result) => reply(id, result),
        () => reply(id, { ok: false, reason: 'error' }),
      );
  }

  function blocked(): void {
    if (ready || destroyed) return;
    if (mode === 'srcdoc' && options.frameUrl) {
      start('hosted');
      return;
    }
    options.onBlocked();
  }

  function onLoad(): void {
    loads += 1;
    // The page moved its own frame somewhere else after it was shown: whatever is in it now is not the message.
    if (ready && loads > 1) {
      options.onGone();
      return;
    }
    if (mode === 'hosted') {
      try {
        // nosemgrep: treebars-postmessage-any-origin — the Treebars frame is sandboxed, so its origin is opaque; posted once, on its first load, and the document is the message the site was about to draw anyway.
        frame.contentWindow?.postMessage(JSON.stringify({ tb: nonce, init: document_ }), '*');
      } catch {
        /* the frame refused to load; its timer reports it */
      }
      return;
    }
    if (!ready) timers.push(setTimeout(blocked, READY_AFTER_LOAD_MS));
  }

  function start(next: FrameMode): void {
    for (const timer of timers.splice(0)) clearTimeout(timer);
    const old = frame;
    frame = createFrame();
    mode = next;
    loads = 0;
    frame.addEventListener('load', onLoad);
    if (next === 'hosted') {
      frame.src = options.frameUrl!;
      // A frame the site's `frame-src` refuses may never say anything at all.
      timers.push(setTimeout(blocked, HOSTED_READY_MS));
    } else {
      frame.setAttribute('srcdoc', document_);
    }
    if (old.parentNode) old.parentNode.replaceChild(frame, old);
    else options.parent.appendChild(frame);
  }

  /*
   * The window turned: the frame is told, and its shim rewrites the rule it was drawn with, so a message drawn
   * upright does not go on hiding its landscape half once the phone is held sideways. Through the Treebars frame too,
   * which passes on anything carrying the nonce.
   */
  const turned = () => {
    const now = pageOrientation();
    // Before the shim says it is running there is nothing in the frame to tell: `_ready` asks again.
    if (destroyed || !ready || !now || now === held) return;
    held = now;
    try {
      // nosemgrep: treebars-postmessage-any-origin — the frame's origin is opaque, and this says nothing but which way the window is held.
      frame.contentWindow?.postMessage(JSON.stringify({ tb: nonce, orientation: now }), '*');
    } catch {
      /* a frame that has gone has nothing to turn */
    }
  };
  const query = !pinned && typeof window.matchMedia === 'function' ? window.matchMedia('(orientation: portrait)') : null;
  query?.addEventListener?.('change', turned);

  window.addEventListener('message', onMessage);
  start(mode);

  return {
    get frame() {
      return frame;
    },
    /**
     * Focus into the message: the frame first, which the page may do, then the shim puts it on the first control —
     * the page cannot, the frame being an opaque origin. Through the Treebars frame too, which passes it on.
     */
    focus() {
      if (destroyed) return;
      frame.focus({ preventScroll: true });
      try {
        // nosemgrep: treebars-postmessage-any-origin — the frame's origin is opaque, and this says nothing but "take focus".
        frame.contentWindow?.postMessage(JSON.stringify({ tb: nonce, focus: true }), '*');
      } catch {
        /* a frame that has gone takes no focus */
      }
    },
    destroy() {
      destroyed = true;
      for (const timer of timers.splice(0)) clearTimeout(timer);
      query?.removeEventListener?.('change', turned);
      window.removeEventListener('message', onMessage);
      frame.remove();
    },
  };
}
