import { safeGet, safeSet } from './storage';
import { DELIVERY_ID_KEY, CAMPAIGN_ID_KEY, RICH_PUSH_BUTTON_ID_KEY } from './generated/constants';

/*
 * Web push: subscribing this browser, asking first with a soft prompt, and reporting the notification a person clicked.
 *
 * **The service worker is the site's file.** A push is received by a worker registered on the site's own origin, so
 * the site hosts `treebars-sw.js` (shipped beside this SDK) at its root, or `importScripts` it from its own worker. It
 * draws the notification and, on a click, opens the page with the delivery named in the query — which is where this
 * module reads it back and reports `notification_opened`. A click on a page of another origin opens it and is not
 * counted: that page does not run this site's SDK to count it.
 *
 * **Soft prompt.** A browser shows its own permission prompt once; a "no" there is for good. So a site explains first,
 * in its own words — a banner, a small nudge in a corner, or an overlay — and asks the browser only after a yes. A
 * "later" hides the soft prompt for `reappearDays`.
 */

export interface WebPushOptions {
  /** The channel's VAPID public key, from the web push channel in the dashboard. */
  vapidPublicKey: string;
  /** Where the site serves `treebars-sw.js`. The root, by default, so it can receive for every page. */
  serviceWorkerPath?: string;
}

export interface PushPromptOptions extends WebPushOptions {
  /** A bar across the top, a card in the bottom corner, or a centred box over a dimmed page. `nudge` by default. */
  style?: 'banner' | 'nudge' | 'overlay';
  /** The prompt's message, in the site's own words. */
  text?: string;
  /** The label of the button that goes on to the browser's own prompt. `Allow` by default. */
  allow?: string;
  /** The label of the button that puts the prompt off for `reappearDays`. `Not now` by default. */
  deny?: string;
  /** Seconds after the call before the prompt shows. */
  delaySeconds?: number;
  /** Days a "not now" keeps the prompt away. 7 by default. */
  reappearDays?: number;
}

export type SubscribeResult = 'subscribed' | 'denied' | 'unsupported';
export type PromptResult = SubscribeResult | 'dismissed' | 'later';

interface Host {
  track: (event: string, properties: Record<string, unknown>) => void;
  flush: () => Promise<void> | void;
  persist: () => boolean;
}

const PROMPT_KEY = 'treebars.push.prompt.v1';
const PERMISSION_KEY = 'treebars.push.permission.v1';
/** The subscription endpoint this browser last registered, and the worker path it was registered through. */
const REGISTERED_KEY = 'treebars.push.registered.v1';
/** The query parameters the service worker adds to the page it opens, and this reads back. */
export const OPENED_PARAMS = { delivery: DELIVERY_ID_KEY, campaign: CAMPAIGN_ID_KEY, button: RICH_PUSH_BUTTON_ID_KEY } as const;

/** The permission as the other SDKs report it, so one report reads every platform. */
function permissionName(value: NotificationPermission | 'unsupported'): string {
  return value === 'granted' ? 'authorized' : value === 'denied' ? 'denied' : value === 'default' ? 'not_determined' : 'unsupported';
}

function applicationServerKey(key: string): Uint8Array {
  const padded = key.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (key.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export class WebPush {
  /** The options the site last subscribed with, so the in-app opt-in button can subscribe the same way. */
  private options: WebPushOptions | null = null;

  constructor(private readonly host: Host) {}

  /** Whether this browser can receive a push at all: a worker, a push manager and notifications. */
  supported(): boolean {
    return (
      typeof window !== 'undefined' &&
      typeof navigator !== 'undefined' &&
      'serviceWorker' in navigator &&
      'PushManager' in window &&
      typeof Notification !== 'undefined'
    );
  }

  permission(): NotificationPermission | 'unsupported' {
    return this.supported() ? Notification.permission : 'unsupported';
  }

  /** The permission in the words every Treebars SDK shares, read now: a person can change it in the browser at any time. */
  status(): string {
    return permissionName(this.permission());
  }

  /** Reports a permission that changed since this browser last said, as the other SDKs do. */
  notePermission(): void {
    const now = permissionName(this.permission());
    const before = this.host.persist() ? safeGet(PERMISSION_KEY) : null;
    if (before === now) return;
    if (this.host.persist()) safeSet(PERMISSION_KEY, now);
    if (before !== null) this.host.track('notification_permission_changed', { from: before, to: now });
  }

  /**
   * Asks the browser (its own prompt, if it has not been answered), registers the worker and subscribes, and registers
   * the subscription with Treebars. Call it from a click: browsers refuse a permission prompt nobody asked for.
   */
  async subscribe(options: WebPushOptions): Promise<SubscribeResult> {
    this.options = options;
    if (!this.supported()) return 'unsupported';
    let permission = Notification.permission;
    if (permission === 'default') permission = await Notification.requestPermission();
    this.notePermission();
    if (permission !== 'granted') return 'denied';

    const registration = await navigator.serviceWorker.register(options.serviceWorkerPath ?? '/treebars-sw.js');
    await navigator.serviceWorker.ready;
    const subscription =
      (await registration.pushManager.getSubscription()) ??
      (await registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: applicationServerKey(options.vapidPublicKey) as BufferSource,
      }));
    this.register(subscription, options.serviceWorkerPath);
    await this.host.flush();
    return 'subscribed';
  }

  private register(subscription: PushSubscription, serviceWorkerPath: string | undefined): void {
    this.host.track('push_token_registered', { token: JSON.stringify(subscription.toJSON()), provider: 'webpush' });
    if (this.host.persist()) safeSet(REGISTERED_KEY, JSON.stringify({ endpoint: subscription.endpoint, path: serviceWorkerPath ?? '/treebars-sw.js' }));
  }

  /**
   * The in-app opt-in button (a message's `treebars://push-permission` link). Subscribes as the site last did when
   * it has called `subscribe` or `prompt` on this page; otherwise asks the browser for permission only, and the
   * site's own `subscribe` registers the browser later. Never navigates. Must run inside the click: the browser shows
   * its prompt only to a gesture, so the permission request is made before anything is awaited.
   */
  async requestPermission(): Promise<SubscribeResult> {
    if (!this.supported()) return 'unsupported';
    if (this.options) return this.subscribe(this.options);
    const permission = Notification.permission === 'default' ? await Notification.requestPermission() : Notification.permission;
    this.notePermission();
    return permission === 'granted' ? 'subscribed' : 'denied';
  }

  /**
   * On every page load: the permission as it is now, and the subscription as it is now.
   *
   * A person can revoke the permission in the browser's settings at any time, so it is read and reported on every load,
   * not only inside `subscribe`. And a browser can replace its subscription without the site calling `subscribe` — an
   * expired endpoint, a worker unregistered and registered again, or `pushsubscriptionchange` in `treebars-sw.js`
   * subscribing afresh — so the current one is compared with the one last registered, and registered again only when it
   * changed; that keeps pushes reaching this browser. It never subscribes on its own: without a site's `subscribe` there
   * is no key to subscribe with, and a load is not a gesture.
   */
  async refresh(): Promise<void> {
    if (!this.supported() || !this.host.persist()) return;
    this.notePermission();
    this.watchPermission();
    let registered: { endpoint?: string; path?: string } | null = null;
    try {
      registered = JSON.parse(safeGet(REGISTERED_KEY) ?? 'null') as { endpoint?: string; path?: string } | null;
    } catch {
      registered = null;
    }
    // A record with a path and no endpoint is one `deviceChanged` left: subscribed, and owed a registration.
    if (!(registered?.endpoint || registered?.path) || Notification.permission !== 'granted') return;
    try {
      const registration = await navigator.serviceWorker.getRegistration(registered.path ?? '/treebars-sw.js');
      const subscription = await registration?.pushManager.getSubscription();
      if (!subscription || subscription.endpoint === registered.endpoint) return;
      this.register(subscription, registered.path);
      await this.host.flush();
    } catch {
      // A browser that will not say is left as it was; the next load asks again.
    }
  }

  /**
   * This browser reports as another device from here on (`shareAcrossSubdomains`). Its push subscription was
   * registered for the previous one, so the record of that is kept without its endpoint — which no subscription
   * matches — and the next `refresh` registers the subscription again, for this device. A browser the site never
   * subscribed has no record, and nothing changes for it.
   */
  deviceChanged(): void {
    try {
      const registered = JSON.parse(safeGet(REGISTERED_KEY) ?? 'null') as { endpoint?: string; path?: string } | null;
      if (!registered?.endpoint) return;
      safeSet(REGISTERED_KEY, JSON.stringify({ path: registered.path ?? '/treebars-sw.js' }));
    } catch {
      // A record that cannot be read is no record.
    }
  }

  /** Reports a permission changed while the page is open, where the browser says (not every browser does). */
  private watchPermission(): void {
    try {
      void navigator.permissions
        ?.query({ name: 'notifications' as PermissionName })
        .then((status) => {
          status.onchange = () => this.notePermission();
        })
        .catch(() => undefined);
    } catch {
      // Safari's permissions API answers some names and throws for others.
    }
  }

  /**
   * The soft prompt: the site's words first, the browser's prompt only after a yes. Resolves how it ended — or at once
   * with `subscribed`/`denied` when the browser has already answered, `later` while a "not now" is still standing.
   */
  async prompt(options: PushPromptOptions): Promise<PromptResult> {
    this.options = { vapidPublicKey: options.vapidPublicKey, serviceWorkerPath: options.serviceWorkerPath };
    if (!this.supported()) return 'unsupported';
    if (Notification.permission === 'granted') return this.subscribe(options);
    if (Notification.permission === 'denied') return 'denied';
    const until = Number(safeGet(PROMPT_KEY) ?? 0);
    if (until > Date.now()) return 'later';
    if (options.delaySeconds) await new Promise((resolve) => setTimeout(resolve, options.delaySeconds! * 1000));

    const answer = await showPrompt(options);
    if (answer === 'allow') return this.subscribe(options);
    safeSet(PROMPT_KEY, String(Date.now() + (options.reappearDays ?? 7) * 86_400_000));
    return 'dismissed';
  }

  /**
   * The page a notification opened (the worker put the delivery in the query): reported as `notification_opened` —
   * with the button, when it was one — and taken back out of the address bar, so a reload or a shared link does not
   * count it again.
   */
  trackOpened(): void {
    if (typeof location === 'undefined' || typeof history === 'undefined') return;
    const url = new URL(location.href);
    const delivery = url.searchParams.get(OPENED_PARAMS.delivery);
    if (!delivery) return;
    const properties: Record<string, unknown> = { [DELIVERY_ID_KEY]: delivery };
    const campaign = url.searchParams.get(OPENED_PARAMS.campaign);
    if (campaign) properties[CAMPAIGN_ID_KEY] = campaign;
    const button = url.searchParams.get(OPENED_PARAMS.button);
    if (button) properties[RICH_PUSH_BUTTON_ID_KEY] = button;
    this.host.track('notification_opened', properties);
    for (const key of Object.values(OPENED_PARAMS)) url.searchParams.delete(key);
    history.replaceState(history.state, '', url.toString());
  }
}

const STYLES: Record<NonNullable<PushPromptOptions['style']>, string> = {
  banner: 'position:fixed;top:0;left:0;right:0;padding:12px 16px;display:flex;flex-wrap:wrap;gap:12px;align-items:center;justify-content:center',
  nudge: 'position:fixed;bottom:16px;right:16px;max-width:320px;padding:16px;border-radius:12px;box-shadow:0 8px 24px rgba(0,0,0,.18)',
  overlay: 'position:fixed;top:50%;left:50%;transform:translate(-50%,-50%);max-width:360px;width:calc(100% - 32px);padding:24px;border-radius:14px;box-shadow:0 12px 40px rgba(0,0,0,.25)',
};

/** Draws the soft prompt and resolves what the person chose. Plain DOM with inline styles: nothing leaks onto the site. */
function showPrompt(options: PushPromptOptions): Promise<'allow' | 'deny'> {
  return new Promise((resolve) => {
    const style = options.style ?? 'nudge';
    const backdrop = style === 'overlay' ? document.createElement('div') : null;
    if (backdrop) {
      backdrop.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.45);z-index:2147483646';
      document.body.appendChild(backdrop);
    }
    const box = document.createElement('div');
    box.setAttribute('role', 'dialog');
    box.setAttribute('aria-live', 'polite');
    box.style.cssText = `${STYLES[style]};z-index:2147483647;background:#fff;color:#1c1c1a;font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif`;
    const text = document.createElement('p');
    text.style.cssText = 'margin:0 0 12px 0';
    text.textContent = options.text ?? 'Get a notification when there is something new for you.';
    const buttons = document.createElement('div');
    buttons.style.cssText = 'display:flex;gap:8px;justify-content:flex-end';
    const deny = document.createElement('button');
    deny.type = 'button';
    deny.textContent = options.deny ?? 'Not now';
    deny.style.cssText = 'font:inherit;padding:8px 14px;border-radius:8px;border:1px solid #d6d6d1;background:#fff;color:#1c1c1a;cursor:pointer';
    const allow = document.createElement('button');
    allow.type = 'button';
    allow.textContent = options.allow ?? 'Allow';
    allow.style.cssText = 'font:inherit;padding:8px 14px;border-radius:8px;border:0;background:#1c1c1a;color:#fff;cursor:pointer';
    buttons.append(deny, allow);
    box.append(text, buttons);
    document.body.appendChild(box);
    const close = (answer: 'allow' | 'deny') => {
      box.remove();
      backdrop?.remove();
      resolve(answer);
    };
    allow.addEventListener('click', () => close('allow'));
    deny.addEventListener('click', () => close('deny'));
  });
}
