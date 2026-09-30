import { BRIDGE_EVENTS, BRIDGE_EVENT_KEYS, BRIDGE_LIMITS, BRIDGE_PREVIEW_WRITES, BRIDGE_RESERVED_TRAITS, BRIDGE_VERSION, type BridgeHostMethod } from './generated/bridge';
import { IN_APP_BUTTON_INDEX_KEY, RESERVED_EVENT_NAMES } from './generated/constants';
import { inAppReceipt, readInAppHtmlAction, type InAppMessage } from './in-app';

/*
 * What each `treebars` call means on the web: one display's worth of state — whether its dismissal was recorded, which
 * screen is showing, how many events it has sent — and a handler for every method the web hosts. The table is typed
 * against `BRIDGE_HOST_METHODS`, generated from the shared bridge definition, so a method added there does not compile
 * here until it has an answer.
 *
 * Every answer resolves; a refusal is `{ ok: false, reason }`, never a thrown error, because a template written for a
 * bridge whose methods return nothing never catches.
 */

/** What the SDK lends a display: the few things a bridge call needs of it, and nothing else. */
export interface BridgeSdk {
  track(name: string, properties: Record<string, unknown>): void;
  /**
   * Sets traits on the person: through `identify()` when somebody is signed in, and on the anonymous visitor otherwise,
   * who carries them into the account at sign-in. The page cannot tell the two apart, by design.
   */
  setTraits(traits: Record<string, unknown>): { ok: true } | { ok: false; reason: string };
  requestPushPermission(): Promise<'granted' | 'denied' | 'unsupported'>;
  /** The page's `TREEBARS_AUTOMATED_EVENTS` listener, told a message was pressed. */
  announceClicked(data: Record<string, unknown>): void;
  /**
   * Somewhere a press leads, and which call asked: `openDeepLink`, `openWebURL` and `_link` go in this tab,
   * `openRichLanding` and `_link_new` (a link with `target="_blank"`) in a new one.
   */
  open(url: string, via: BridgeOpenVia): void;
  /** The message is spent and the screen is free: a press that leads somewhere, as a dismissal does. */
  spent(): void;
  /** The message was dismissed: spent, the screen freed, the page told. Recording is the display's. */
  dismissed(reason?: 'auto'): void;
  flush(): void;
  log(message: string): void;
  /**
   * The server's answer to `claimReward(pool)` for this message: `{ won, prize?, code?, empty? }`, or a refusal —
   * `not_available` for a pool this message does not name or that is gone, `offline` when no answer came, and `failed`
   * for anything else — each only once a 429, a 503 or no answer has been retried (`reward-claim.ts`).
   */
  claimReward(pool: string, deliveryId: string): Promise<Record<string, unknown>>;
}

export type BridgeOpenVia = 'openDeepLink' | 'openWebURL' | 'openRichLanding' | '_link' | '_link_new';

type Result = unknown;
type Handler = (args: unknown[], close: () => void) => Result | Promise<Result>;

const OK = { ok: true } as const;
const refuse = (reason: string) => ({ ok: false, reason });

const PREVIEW_WRITES = new Set<string>(BRIDGE_PREVIEW_WRITES);

/** Schemes that run where they are opened, which the SDK never opens for a message — as `readInAppHtmlAction` refuses. */
const RUNS_IN_PLACE = /^(?:javascript|vbscript|data|blob|file|filesystem):/i;
const NAME = /^[A-Za-z_][\w.:-]{0,127}$/;
/** A stored value's key, and the limits on how many values a campaign keeps and how large each may be. */
const STORED_KEY = /^[A-Za-z_][A-Za-z0-9_.:-]{0,63}$/;
/** The shape of a reward pool's name. */
const POOL = /^[a-z0-9]([a-z0-9_]{0,58}[a-z0-9])?$/;
const STORED_MAX_KEYS = 32;
const STORED_MAX_BYTES = 1024;
const RESERVED_TRAITS = new Set(BRIDGE_RESERVED_TRAITS);
const RESERVED_EVENTS: ReadonlySet<string> = new Set(RESERVED_EVENT_NAMES as readonly string[]);

/**
 * An object from a bridge argument, which a template may pass as an object or as a JSON string: an object as it is, a
 * JSON string parsed, anything else nothing.
 */
function objectFrom(value: unknown): Record<string, unknown> {
  if (value && typeof value === 'object' && !Array.isArray(value)) return value as Record<string, unknown>;
  if (typeof value === 'string' && value.trim()) {
    try {
      const parsed = JSON.parse(value) as unknown;
      if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) return parsed as Record<string, unknown>;
    } catch {
      /* not JSON: nothing */
    }
  }
  return {};
}

/** A widget id as the template gave it: `0` stays `"0"`, nothing stays nothing. */
function widget(value: unknown): string | undefined {
  if (typeof value === 'number' && Number.isFinite(value)) return String(value);
  if (typeof value === 'string' && value.trim()) return value.trim().slice(0, 128);
  return undefined;
}

function url(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const target = value.trim();
  if (!target || RUNS_IN_PLACE.test(target.replace(/[\u0000- ]/g, ''))) return null;
  return target;
}

/** An ISO 8601 date, with or without a time — the same rule on every host (`test/fixtures/bridge-conformance.json`). */
const isoDate = (value: unknown): value is string =>
  typeof value === 'string' && /^\d{4}-\d{2}-\d{2}([T ][0-9:.]+(Z|[+-]\d{2}:?\d{2})?)?$/.test(value);
const coordinate = (value: unknown, limit: number): value is number => typeof value === 'number' && Number.isFinite(value) && Math.abs(value) <= limit;

async function copy(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    // The frame's click is the page's gesture too (activation reaches the frame's ancestors), but a clipboard refused
    // for focus still has the older route.
    const area = document.createElement('textarea');
    area.value = text;
    area.setAttribute('readonly', '');
    area.style.cssText = 'position:fixed;top:-1000px;opacity:0';
    document.body.appendChild(area);
    area.select();
    let done = false;
    try {
      done = document.execCommand('copy');
    } catch {
      done = false;
    }
    area.remove();
    return done;
  }
}

/** `copyText`'s message: a line at the foot of the window for two seconds. */
function toast(message: string): void {
  const node = document.createElement('div');
  node.setAttribute('role', 'status');
  node.textContent = message;
  node.style.cssText =
    'position:fixed;left:50%;bottom:24px;transform:translateX(-50%);z-index:2147483647;max-width:calc(100% - 32px);padding:10px 16px;border-radius:8px;background:rgba(17,24,39,.92);color:#fff;font:14px/1.4 -apple-system,BlinkMacSystemFont,sans-serif;box-shadow:0 6px 20px rgba(0,0,0,.25)';
  document.body.appendChild(node);
  setTimeout(() => node.remove(), 2000);
}

interface PendingClick {
  fields: Record<string, unknown>;
  then: Array<() => void>;
  leads: boolean;
}

/** One display of one HTML message: its bridge state and its answers. */
export class BridgeDisplay {
  private dismissRecorded = false;
  private screen: string | null = null;
  private events = 0;
  private lastEvent: Record<string, number> = {};
  private pending: PendingClick | null = null;
  /** What this message's campaign kept for the person, as synced, with this display's own writes laid over it. */
  private readonly stored: Record<string, string | number | boolean>;

  constructor(
    private readonly message: InAppMessage,
    private readonly sdk: BridgeSdk,
  ) {
    // The message's own copy, so a later display of it in this page reads what this one wrote.
    this.stored = message.stored ?? (message.stored = {});
  }

  private receipt(): Record<string, unknown> {
    return { ...inAppReceipt(this.message), ...(this.screen ? { [BRIDGE_EVENT_KEYS.screen]: this.screen } : {}) };
  }

  /**
   * A dismissal from anywhere — the page's call, Escape, the dim, the timer — recorded once per display. `trackDismiss`
   * records without closing and `dismissMessage` closes without recording again, so a template that calls both counts
   * one.
   */
  dismiss(reason?: 'auto', element?: string): void {
    this.recordDismiss(element);
    this.sdk.dismissed(reason);
  }

  private recordDismiss(element?: string): void {
    if (this.dismissRecorded) return;
    this.dismissRecorded = true;
    this.sdk.track('in_app_dismissed', { ...this.receipt(), ...(element ? { [BRIDGE_EVENT_KEYS.element]: element } : {}) });
  }

  /**
   * A press, recorded once however many calls said so. A template's handler that calls `trackClick(1)` and
   * `openWebURL(url)` together is one press, so everything asked in the same turn is folded into one `in_app_clicked`
   * with the element and the destination both; the page's messages from one handler all arrive before this turn's
   * timer. What the press leads to runs after it is recorded and flushed.
   */
  private click(fields: Record<string, unknown>, then?: () => void, leads = false): void {
    if (!this.pending) {
      // The screen it was pressed on, taken now: the press may be what moves the flow on before this turn ends.
      this.pending = { fields: this.screen ? { [BRIDGE_EVENT_KEYS.screen]: this.screen } : {}, then: [], leads: false };
      setTimeout(() => this.flushClick(), 0);
    }
    Object.assign(this.pending.fields, fields);
    if (then) this.pending.then.push(then);
    if (leads) this.pending.leads = true;
  }

  private flushClick(): void {
    const pending = this.pending;
    this.pending = null;
    if (!pending) return;
    this.sdk.track('in_app_clicked', { ...inAppReceipt(this.message), ...pending.fields });
    this.sdk.announceClicked({ ...inAppReceipt(this.message), ...pending.fields });
    if (pending.leads) this.sdk.spent();
    if (pending.then.length > 0) this.sdk.flush();
    for (const action of pending.then) action();
  }

  private event(args: unknown[]): Result {
    const name = args[0];
    if (typeof name !== 'string' || !NAME.test(name) || /^(?:undefined|null)$/.test(name)) return refuse('invalid_name');
    if (name.startsWith('in_app_') || RESERVED_EVENTS.has(name)) return refuse('reserved');
    if (!this.message.content.in_app?.declared?.events.includes(name)) {
      this.sdk.log(`in-app event "${name}" is not declared in the message, so it was not recorded`);
      return refuse('undeclared');
    }
    const now = Date.now();
    if (now - (this.lastEvent[name] ?? -Infinity) < BRIDGE_LIMITS.repeatWindowMs) return refuse('repeat');
    if (this.events >= BRIDGE_LIMITS.eventsPerDisplay) return refuse('limit');
    this.events += 1;
    this.lastEvent[name] = now;
    // Location and date attributes are properties like any other; the campaign is always attached (the sixth
    // argument is accepted and ignored), and `isNonInteractive` means nothing to a message on screen.
    this.sdk.track(name, { ...objectFrom(args[3]), ...objectFrom(args[2]), ...objectFrom(args[1]), ...this.receipt() });
    return OK;
  }

  private trait(name: string, value: unknown): Result {
    if (value === undefined || value === null || (typeof value === 'object' && !isLocation(value))) return refuse('invalid_value');
    return this.sdk.setTraits({ [name]: value });
  }

  private declaredTrait(name: unknown, value: unknown): Result {
    if (typeof name !== 'string' || !NAME.test(name)) return refuse('invalid_name');
    if (RESERVED_TRAITS.has(name)) return refuse('reserved');
    if (!this.message.content.in_app?.declared?.traits.includes(name)) return refuse('undeclared');
    return this.trait(name, value);
  }

  private optIn(kind: 'email' | 'phone', value: unknown): Result {
    const address = typeof value === 'string' ? value.trim() : '';
    const valid = kind === 'email' ? /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(address) : /^\+?[\d\s().-]{6,20}$/.test(address);
    if (!valid) return refuse('invalid_value');
    this.sdk.track(BRIDGE_EVENTS.optedIn, { ...this.receipt(), [kind]: address });
    return OK;
  }

  private readonly handlers: Record<BridgeHostMethod, Handler> = {
    // Said by the shim, and answered by the frame host before it reaches here.
    _ready: () => OK,
    resize: () => OK,
    _key: () => OK,

    dismissMessage: (_args, close) => {
      close();
      this.dismiss();
      return OK;
    },
    trackDismiss: (args) => {
      this.recordDismiss(widget(args[0]));
      return OK;
    },
    trackClick: (args) => {
      const element = widget(args[0]);
      const index = element && /^[1-9]\d*$/.test(element) ? Number(element) : undefined;
      this.click({ ...(element ? { [BRIDGE_EVENT_KEYS.element]: element } : {}), ...(index ? { [IN_APP_BUTTON_INDEX_KEY]: index } : {}) });
      return OK;
    },
    trackRating: (args) => {
      const rating = Number(args[0]);
      if (!Number.isFinite(rating)) return refuse('invalid_value');
      this.sdk.track(BRIDGE_EVENTS.rated, { ...this.receipt(), rating });
      return OK;
    },
    trackEvent: (args) => this.event(args),

    identifyUser: () => refuse('identity_from_message'),
    setUniqueId: () => refuse('identity_from_message'),
    setAlias: () => refuse('identity_from_message'),

    setEmailId: (args) => this.optIn('email', args[0]),
    setMobileNumber: (args) => this.optIn('phone', args[0]),
    setUserName: (args) => this.trait('name', typeof args[0] === 'string' ? args[0] : undefined),
    setFirstName: (args) => this.trait('first_name', typeof args[0] === 'string' ? args[0] : undefined),
    setLastName: (args) => this.trait('last_name', typeof args[0] === 'string' ? args[0] : undefined),
    setGender: (args) => (['male', 'female', 'other'].includes(String(args[0])) ? this.trait('gender', args[0]) : refuse('invalid_value')),
    setBirthDate: (args) => (isoDate(args[0]) ? this.trait('birth_date', args[0]) : refuse('invalid_value')),
    setUserLocation: (args) =>
      coordinate(args[0], 90) && coordinate(args[1], 180) ? this.trait('location', { latitude: args[0], longitude: args[1] }) : refuse('invalid_value'),
    setUserAttribute: (args) =>
      typeof args[1] === 'string' || typeof args[1] === 'number' || typeof args[1] === 'boolean' ? this.declaredTrait(args[0], args[1]) : refuse('invalid_value'),
    setUserAttributeDate: (args) => (isoDate(args[1]) ? this.declaredTrait(args[0], args[1]) : refuse('invalid_value')),
    setUserAttributeLocation: (args) =>
      coordinate(args[1], 90) && coordinate(args[2], 180) ? this.declaredTrait(args[0], { latitude: args[1], longitude: args[2] }) : refuse('invalid_value'),

    navigateToScreen: (args) => {
      if (typeof args[0] !== 'string' || !args[0].trim()) return refuse('invalid_value');
      // The web has no app screens: the page's own router hears it, with the key-values, on TREEBARS_AUTOMATED_EVENTS.
      this.click({ [BRIDGE_EVENT_KEYS.destination]: args[0], action: 'navigate', values: objectFrom(args[1]) });
      return OK;
    },
    openDeepLink: (args) => {
      const target = url(args[0]);
      if (!target) return refuse('invalid_url');
      this.click({ [BRIDGE_EVENT_KEYS.destination]: target }, () => this.sdk.open(target, 'openDeepLink'), true);
      return OK;
    },
    openRichLanding: (args) => {
      const target = url(args[0]);
      if (!target) return refuse('invalid_url');
      this.click({ [BRIDGE_EVENT_KEYS.destination]: target }, () => this.sdk.open(target, 'openRichLanding'));
      return OK;
    },
    openWebURL: (args) => {
      const target = url(args[0]);
      if (!target) return refuse('invalid_url');
      this.click({ [BRIDGE_EVENT_KEYS.destination]: target }, () => this.sdk.open(target, 'openWebURL'), true);
      return OK;
    },

    copyText: async (args) => {
      const done = await copy(String(args[0] ?? ''));
      if (done && typeof args[1] === 'string' && args[1].trim()) toast(args[1].trim());
      return done ? OK : refuse('not_allowed');
    },
    call: (args) => {
      if (typeof args[0] !== 'string' || !args[0].trim()) return refuse('invalid_value');
      location.href = `tel:${encodeURIComponent(args[0].trim())}`;
      return OK;
    },
    sms: (args) => {
      if (typeof args[0] !== 'string' || !args[0].trim()) return refuse('invalid_value');
      const body = typeof args[1] === 'string' && args[1] ? `?body=${encodeURIComponent(args[1])}` : '';
      location.href = `sms:${encodeURIComponent(args[0].trim())}${body}`;
      return OK;
    },
    share: async (args) => {
      if (typeof navigator.share !== 'function') return refuse('unsupported');
      try {
        await navigator.share({ text: String(args[0] ?? '') });
        return OK;
      } catch {
        return refuse('cancelled');
      }
    },
    customAction: (args) => {
      this.click({ action: 'custom', values: objectFrom(args[0]) });
      return OK;
    },
    requestNotificationPermission: () => this.sdk.requestPushPermission(),
    showPushOptIn: () => this.sdk.requestPushPermission(),
    handleNotificationPopUp: () => this.sdk.requestPushPermission(),

    getContext: () => {
      const content = this.message.content.in_app;
      const dark = typeof matchMedia === 'function' && matchMedia('(prefers-color-scheme: dark)').matches;
      return {
        locale: navigator.language || 'en',
        direction: content?.direction ?? (document.documentElement.dir === 'rtl' ? 'rtl' : 'ltr'),
        theme: dark ? 'dark' : 'light',
        platform: 'web',
        insets: { top: 0, right: 0, bottom: 0, left: 0 },
        screen: this.screen,
        deliveryId: this.message.delivery_id,
        campaignId: this.message.campaign_id,
        bridgeVersion: BRIDGE_VERSION,
        preview: this.message.preview === true,
      };
    },
    claimReward: async (args) => {
      const pool = args[0];
      if (typeof pool !== 'string' || !POOL.test(pool)) return refuse('invalid_name');
      const answer = await this.sdk.claimReward(pool, this.message.delivery_id);
      // Recorded as the page is told, so the report and the person agree; a refusal is not a play.
      if (typeof answer.won === 'boolean') {
        this.sdk.track(BRIDGE_EVENTS.rewardClaimed, { ...this.receipt(), pool, won: answer.won, ...(typeof answer.prize === 'string' ? { prize: answer.prize } : {}) });
      }
      return answer;
    },
    getStoredValue: (args) => (typeof args[0] === 'string' && Object.prototype.hasOwnProperty.call(this.stored, args[0]) ? this.stored[args[0]] : null),
    setStoredValue: (args) => {
      const [key, value] = args;
      if (typeof key !== 'string' || !STORED_KEY.test(key)) return refuse('invalid_name');
      const valid = value === null || typeof value === 'string' || typeof value === 'boolean' || (typeof value === 'number' && Number.isFinite(value));
      if (!valid || JSON.stringify(value).length > STORED_MAX_BYTES) return refuse('invalid_value');
      if (value !== null && !(key in this.stored) && Object.keys(this.stored).length >= STORED_MAX_KEYS) return refuse('limit');
      if (value === null) delete this.stored[key];
      else this.stored[key] = value as string | number | boolean;
      // Kept on the server per campaign; a test send or a journey step has none, so it lasts this display only.
      if (!this.message.campaign_id) return refuse('no_campaign');
      this.sdk.track(BRIDGE_EVENTS.valueStored, { ...inAppReceipt(this.message), key, value });
      return OK;
    },

    _screen: (args) => {
      if (typeof args[0] !== 'string') return refuse('invalid_value');
      this.screen = args[0].slice(0, 128);
      this.sdk.track(BRIDGE_EVENTS.screenViewed, {
        ...this.receipt(),
        index: Number(args[1]) || 0,
        ...(typeof args[2] === 'string' ? { from: args[2] } : {}),
        how: typeof args[3] === 'string' ? args[3] : 'jump',
      });
      return OK;
    },
    _complete: (args) => {
      this.sdk.track(BRIDGE_EVENTS.completed, { ...this.receipt(), screens_seen: Number(args[0]) || 0 });
      return OK;
    },
    // A quiz reached its result: its score, recorded by the host as every other `in_app_*` is.
    _quiz: (args) => {
      this.sdk.track(BRIDGE_EVENTS.quizCompleted, { ...this.receipt(), quiz: typeof args[0] === 'string' ? args[0].slice(0, 64) : 'quiz', score: Number(args[1]) || 0, total: Number(args[2]) || 0 });
      return OK;
    },
    _submit: (args) => {
      // Answers as a typed form sends them — text or a number — so a group of ticked boxes is kept, not dropped.
      const answers = Object.fromEntries(
        Object.entries(objectFrom(args[0])).map(([key, value]) => [key, Array.isArray(value) ? value.join(',') : typeof value === 'boolean' ? String(value) : value]),
      );
      const save = objectFrom(args[1]);
      const kept: Record<string, string> = {};
      for (const kind of ['email', 'phone'] as const) if (typeof save[kind] === 'string' && save[kind]) kept[kind] = save[kind] as string;
      // `in_app_form_submitted` as the typed form sends it: the answers, and the addresses the server keeps as opt-ins.
      this.sdk.track('in_app_form_submitted', { ...this.receipt(), responses: answers, ...kept });
      const traits = Object.fromEntries(
        Object.entries(save).filter(([name]) => name !== 'email' && name !== 'phone' && this.message.content.in_app?.declared?.traits.includes(name) && !RESERVED_TRAITS.has(name)),
      );
      if (Object.keys(traits).length > 0) this.sdk.setTraits(traits);
      this.sdk.flush();
      return OK;
    },
    _link: (args, close) => {
      const action = typeof args[0] === 'string' ? readInAppHtmlAction(args[0]) : null;
      if (!action) return refuse('invalid_url');
      if (action.kind === 'dismiss') {
        close();
        this.dismiss();
      } else if (action.kind === 'click') {
        this.click({ [BRIDGE_EVENT_KEYS.element]: String(action.index), [IN_APP_BUTTON_INDEX_KEY]: action.index });
      } else {
        const target = action.url;
        const newWindow = args[1] === true;
        this.click({ [BRIDGE_EVENT_KEYS.destination]: target }, () => this.sdk.open(target, newWindow ? '_link_new' : '_link'), !newWindow);
      }
      return OK;
    },
    _alert: (args) => {
      window.alert(String(args[0] ?? ''));
      return OK;
    },
  };

  /**
   * One call from the page. A preview refuses every method that writes, before any handler runs,
   * and says which in the console — the author is the one testing, and a write they expected should not vanish silently.
   */
  call(method: string, args: unknown[], close: () => void): Result | Promise<Result> {
    if (this.message.preview === true && PREVIEW_WRITES.has(method)) {
      console.info(`[treebars preview] ${method} was not recorded: a preview writes nothing.`);
      return refuse('preview');
    }
    const handler = (this.handlers as Record<string, Handler | undefined>)[method];
    return handler ? handler(args, close) : refuse('unsupported');
  }
}

function isLocation(value: object): boolean {
  const record = value as Record<string, unknown>;
  return typeof record.latitude === 'number' && typeof record.longitude === 'number';
}
