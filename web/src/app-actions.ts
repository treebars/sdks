import { APP_ACTIONS, CAMPAIGN_ID_KEY, DELIVERY_ID_KEY } from './generated/constants';

/*
 * App actions: a named action and a small JSON payload, fired from a tap in a message, which the page subscribes to by
 * name with `onAction`.
 *
 * Every Treebars SDK runs this same dispatcher, held to the shared cases in `test/fixtures/app-action-scenarios.json`:
 * - an action goes to every handler subscribed to its name and to every catch-all, in the order they subscribed;
 * - one that nothing has subscribed to yet is held for a few seconds, at most a handful at a time, and handed to the
 *   first handler that subscribes for it — a message drawn before the code that handles its action has run still works;
 * - once its fate is known it is recorded as `app_action` with `handled` true or false, the name and where it came from,
 *   and never the payload, which can carry a person's own ids. A preview's actions are handed over and never recorded.
 */

/** Where an action came from: a tap in an in-app message, a push, or an inbox card. */
export interface AppActionSource {
  kind: 'in_app' | 'push' | 'card';
  campaign_id?: string | null;
  message_id?: string | null;
}

/** What a handler receives. */
export interface AppAction {
  /** The action's name, as the message names it: `add_to_cart`, `cart.open`, or the built-in `navigate`. */
  name: string;
  /** Its payload, a JSON object; `{ screen, props }` for `navigate`. */
  payload: Record<string, unknown>;
  source: AppActionSource;
}

export type AppActionHandler = (action: AppAction) => void;

/** Lower-case letters, digits, dots and underscores, starting with a letter: what an action may be called. */
export const APP_ACTION_NAME = new RegExp(APP_ACTIONS.namePattern);

/** The payload's size as JSON, in UTF-8 bytes, the way every SDK measures it. */
export function payloadBytes(payload: Record<string, unknown>): number {
  return new TextEncoder().encode(JSON.stringify(payload)).length;
}

interface Subscription {
  name: string | null;
  handler: AppActionHandler;
}

interface Held {
  action: AppAction;
  record: boolean;
  timer: unknown;
}

export interface AppActionsOptions {
  /** Records an event: the SDK's `track`. */
  track(name: string, properties: Record<string, unknown>): void;
  /** Runs `work` after `ms`; returns something `cancel` takes. The window's timers by default. */
  later?(ms: number, work: () => void): unknown;
  cancel?(timer: unknown): void;
  log?(message: string): void;
}

export class AppActions {
  private readonly subscriptions: Subscription[] = [];
  private readonly held: Held[] = [];
  private readonly later: (ms: number, work: () => void) => unknown;
  private readonly cancelTimer: (timer: unknown) => void;

  constructor(private readonly options: AppActionsOptions) {
    this.later = options.later ?? ((ms, work) => setTimeout(work, ms));
    this.cancelTimer = options.cancel ?? ((timer) => clearTimeout(timer as ReturnType<typeof setTimeout>));
  }

  /**
   * Subscribes `handler` to one action by name, or to every action when `name` is null, and hands it whatever is held
   * for it. Returns the way to stop.
   */
  on(name: string | null, handler: AppActionHandler): () => void {
    const subscription: Subscription = { name, handler };
    this.subscriptions.push(subscription);
    for (const entry of this.held.filter((held) => name === null || held.action.name === name)) {
      this.held.splice(this.held.indexOf(entry), 1);
      this.cancelTimer(entry.timer);
      this.deliver(entry.action, [subscription], entry.record);
    }
    return () => {
      const index = this.subscriptions.indexOf(subscription);
      if (index >= 0) this.subscriptions.splice(index, 1);
    };
  }

  /** Hands an action to the handlers subscribed to it, or holds it until one subscribes. */
  fire(action: AppAction, record = true): void {
    const handlers = this.subscriptions.filter((subscription) => subscription.name === null || subscription.name === action.name);
    if (handlers.length > 0) {
      this.deliver(action, handlers, record);
      return;
    }
    const entry: Held = { action, record, timer: null };
    entry.timer = this.later(APP_ACTIONS.holdMs, () => this.letGo(entry));
    this.held.push(entry);
    // More held than the hold keeps lets the oldest go: a burst of taps nothing listens to is not a queue to replay.
    while (this.held.length > APP_ACTIONS.holdMax) {
      const oldest = this.held[0]!;
      this.cancelTimer(oldest.timer);
      this.letGo(oldest);
    }
  }

  /** Lets go of everything held, unrecorded: the SDK is stopping, or the person who tapped has signed out. */
  clear(): void {
    for (const entry of this.held.splice(0)) this.cancelTimer(entry.timer);
  }

  private deliver(action: AppAction, handlers: Subscription[], record: boolean): void {
    for (const { handler } of [...handlers]) {
      try {
        handler(action);
      } catch (error) {
        // A handler that throws still received the action; the next one still runs.
        this.options.log?.(`onAction handler for "${action.name}" threw: ${String(error)}`);
      }
    }
    if (record) this.record(action, true);
  }

  private letGo(entry: Held): void {
    const index = this.held.indexOf(entry);
    if (index < 0) return;
    this.held.splice(index, 1);
    if (entry.record) this.record(entry.action, false);
  }

  private record(action: AppAction, handled: boolean): void {
    this.options.track(APP_ACTIONS.event, {
      [APP_ACTIONS.nameKey]: action.name,
      [APP_ACTIONS.handledKey]: handled,
      [APP_ACTIONS.sourceKey]: action.source.kind,
      ...(action.source.campaign_id ? { [CAMPAIGN_ID_KEY]: action.source.campaign_id } : {}),
      ...(action.source.message_id ? { [DELIVERY_ID_KEY]: action.source.message_id } : {}),
    });
  }
}
