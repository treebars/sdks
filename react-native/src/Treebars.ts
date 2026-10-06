import { forgetAdoption, readAdoption } from './adoption';
import { DEFAULT_BACKEND_URL } from './generated/constants';
import type { InAppButton, InAppMessage, InAppTokens } from './InApp';
import Native from './NativeTreebars';
import type {
  EventProperties,
  NotificationChannel,
  NotificationPage,
  TreebarsConfig,
  TreebarsEventName,
  TreebarsEvents,
  TreebarsUser,
  UploadLog,
} from './types';

/**
 * The Treebars React Native SDK.
 *
 * A thin bridge over the native Treebars SDKs — Kotlin on Android, Swift on iOS. The event
 * queue, sessions, storage, device information, lifecycle tracking and every in-app rule run
 * natively, so a React Native app behaves exactly as a native one does. This layer does four
 * things:
 *
 * - **Marshalling.** Arguments go down as JSON and results come back the same way; see
 *   `NativeTreebars.ts` for why strings rather than codegen structs.
 * - **The renderer protocol.** A TurboModule cannot hand a closure across, so the native
 *   side's `(onClick, onDismiss)` becomes a presentation with an id and two calls back.
 * - **A one-time storage hand-down** (`adoption.ts`), because the native SDKs cannot read
 *   AsyncStorage.
 * - **The public API** documented below.
 */

/**
 * How the host app draws a standard in-app message itself, if it wants to.
 *
 * **Optional.** With no renderer registered the native SDK draws standard messages itself.
 * Register one and it draws every standard message instead, and the native SDK draws none of
 * them. A message with a custom-HTML body is drawn by the native SDK either way, and a
 * self-handled message goes to `setEventListener('inAppCampaignSelfHandled', …)` while that
 * is listened to.
 *
 * A callback rather than a component, because this package has no React dependency and no
 * business owning the app's navigation, safe areas or animation. The SDK decides *which*
 * message and *when*; the app decides what it looks like — within the layout the message
 * asks for and the tokens the project set.
 *
 * - `message` and `tokens`: what to draw and the style to draw it with. Read the layout
 *   through `inAppShape()` and `inAppBodyMode()`, never from `layout` directly.
 * - `onClick(button)`: records the press and carries out the button's action. It does not
 *   end the presentation, so it is safe to call more than once.
 * - `onDismiss()`: ends the presentation and records `in_app_dismissed`; the message is not
 *   shown again on this device.
 *
 * Both callbacks are minted per presentation by this wrapper; only an id crosses the bridge.
 */
export type InAppRenderer = (view: {
  message: InAppMessage;
  tokens: InAppTokens | null;
  onClick: (button: InAppButton) => void | Promise<void>;
  onDismiss: () => void | Promise<void>;
}) => void;

/** What the native side emits when it has chosen a message and something can draw it. */
interface Presentation {
  presentationId: string;
  message: InAppMessage;
  tokens: InAppTokens | null;
}

const json = (value: unknown): string => JSON.stringify(value ?? {});

/** A native reply, or a reason. Never a plausible-looking default — see `NativeTreebars.ts`. */
function parse<T>(payload: string, what: string): T {
  try {
    return JSON.parse(payload) as T;
  } catch {
    throw new Error(`Treebars: the native side returned unreadable ${what}`);
  }
}

export class TreebarsSDK {
  private native = Native;

  /**
   * Resolves once `initialize` has crossed the bridge. Every method awaits it.
   *
   * This is what lets `init(); track()` work without awaiting `init()`. The wrapper has to read
   * AsyncStorage (`adoption.ts`) before it can call `initialize`, and those reads are
   * asynchronous. Rather than buffering events in JavaScript, every method awaits the same
   * in-flight promise, which keeps calls in order without storing anything here. `init()`'s
   * promise means "the native side is up".
   */
  private ready: Promise<void> | null = null;

  private renderer: InAppRenderer | null = null;

  /** The one live presentation, if any. Both native SDKs show one overlay at a time. */
  private pending: Presentation | null = null;

  private notificationWatchers = new Set<(page: NotificationPage) => void>();

  private uploadListener: ((log: UploadLog) => void) | null = null;

  /** The `onDeferredDeepLink` listener, if any. */
  private deepLinkListener: ((path: string) => void) | null = null;
  /** `setEventListener`'s listeners, by event. */
  private eventListeners = new Map<TreebarsEventName, Set<(payload: never) => void>>();

  private module() {
    if (!this.native) {
      /*
       * Loud on purpose. `TurboModuleRegistry.get` returns null rather than throwing, so a
       * missing module does not crash the app at import. But without the native module this
       * SDK can report nothing at all, and staying silent would leave an app shipping with no
       * data and no sign of why.
       */
      throw new Error(
        'Treebars: the native module is not linked, so nothing can be recorded. The package needs the New ' +
          'Architecture. Rebuild the app from clean: on Android, delete android/build, android/app/build and ' +
          'android/app/.cxx; on iOS, run `pod install` in ios/. Then build again.',
      );
    }
    return this.native;
  }

  /**
   * Starts the SDK. Call it once, as early as possible, before any other method.
   *
   * It need not be awaited: every other method waits for it, so `init(config); track('x')`
   * keeps its order. A second call returns the first call's promise and ignores its config.
   * Rejects when the config cannot be used — no write key, an unrecognised `env`, or a
   * `backendUrl` that is not https — and when the native module is not linked.
   */
  async init(config: TreebarsConfig): Promise<void> {
    if (this.ready) return this.ready;

    this.ready = (async () => {
      const native = this.module();
      this.uploadListener = config.onUpload ?? null;
      this.listen(native);

      /*
       * `backendUrl` is the current name, so it wins. Between the two deprecated ones
       * `backend_url` beats `ingestUrl`, because anybody still passing the snake_case name is
       * passing it deliberately — a codebase that sets both did so during a migration, and
       * silently preferring the other would move their traffic mid-upgrade.
       */
      const backendUrl =
        config.backendUrl ?? config.backend_url ?? config.ingestUrl ?? DEFAULT_BACKEND_URL;

      await native.initialize(
        json({
          write_key: config.write_key,
          backend_url: backendUrl,
          env: config.env,
          debug: config.debug,
          // Unset stays unset: a key that is `undefined` is left out of the JSON, and the native SDK then keeps its own pace.
          flush_interval_ms: config.flush_interval_ms,
          in_app_enabled: config.in_app_enabled,
          in_app_poll_interval_ms: config.in_app_poll_interval_ms,
          auto_track_lifecycle: config.auto_track_lifecycle,
          auto_track_sessions: config.auto_track_sessions,
          acquisition_consent: config.acquisition_consent,
          // iOS reads it; Android ignores it, because Play carries the click already.
          deferred_handoff: config.deferred_handoff,
          link_hosts: config.linkHosts,
          app_version: config.app_version,
          app_build: config.app_build,
          /*
           * The identity an earlier version of this package kept in AsyncStorage, which the
           * native SDKs cannot read themselves. Honoured only into an empty native key — see
           * `adoption.ts` for what each value protects and why a failed read hands down
           * nothing rather than something partial.
           */
          adopt: {
            ...(await readAdoption()),
            /*
             * Marks this install as React Native. `platform_type` reports the real OS, so
             * without this a React Native device would be indistinguishable from a native one
             * in every report.
             */
            sdkName: 'treebars-react-native',
          },
        }),
      );

      /*
       * The native SDK now holds the device id and secret in storage that device backups do not
       * include, so the AsyncStorage copy, which backups do include, is deleted. Not awaited:
       * nothing below reads it, and a key that will not delete is tried again next launch
       * (`forgetAdoption`).
       */
      void forgetAdoption();

      /*
       * Apply whatever renderer state was set BEFORE this ran, which is the normal order
       * rather than the exception. An app's renderer host is usually a child of the component
       * whose effect calls `init()`, and React runs a child's effects before its parent's — so
       * `setInAppRenderer` usually arrives while `this.ready` is still null, and only records
       * the renderer.
       */
      if (this.renderer) await native.setInAppRendererEnabled(true);
      /*
       * The two subscriptions, for the same reason: a provider's effect subscribes before its
       * parent's `init()` has run, so the subscription is sent here — and a push action or
       * deferred deep link the native SDK is holding reaches its listener.
       */
      if (this.eventListeners.size > 0) await native.setEventsSubscribed(json([...this.eventListeners.keys()]));
      if (this.deepLinkListener) await native.setDeferredDeepLinkSubscribed(true);
      /*
       * And the notification centre's watchers: a bell mounted in a child subscribes before this
       * runs, and the native side refuses the subscription until it has started. Sent here, the
       * bell is told of every change from the first one.
       */
      if (this.notificationWatchers.size > 0) await native.setNotificationsSubscribed(true);
    })();

    return this.ready;
  }

  private listen(native: NonNullable<typeof Native>) {
    native.onInAppPresent((payload: string) => {
      const view = parse<Presentation>(payload, 'an in-app presentation');
      this.pending = view;
      this.draw(view);
    });

    native.onNotificationsChange((payload: string) => {
      const page = parse<NotificationPage>(payload, 'a notification page');
      // Copied before iterating: a watcher that unsubscribes itself inside its own callback
      // would otherwise mutate the set mid-loop.
      for (const watcher of [...this.notificationWatchers]) watcher(page);
    });

    native.onUploadLog((payload: string) => {
      this.uploadListener?.(parse<UploadLog>(payload, 'an upload log'));
    });

    // A path, not JSON: the one payload across this bridge that is already what it is.
    native.onDeferredDeepLink((path: string) => {
      this.deepLinkListener?.(path);
    });

    native.onTreebarsEvent((payload: string) => {
      const event = parse<{ name: TreebarsEventName; data: unknown }>(payload, 'an event');
      // Copied before calling: a listener that unsubscribes itself would otherwise change the set mid-loop.
      for (const listener of [...(this.eventListeners.get(event.name) ?? [])]) (listener as (data: unknown) => void)(event.data);
    });
  }

  private draw(view: Presentation) {
    const renderer = this.renderer;
    if (!renderer) return;

    renderer({
      message: view.message,
      tokens: view.tokens,
      /*
       * A click does NOT end the presentation; only `onDismiss` does. That is the subtle half
       * of the protocol. A markup body can report a click (`treebars://click/<n>`) and then a
       * dismiss on the same presentation, and if the click cleared the slot the dismiss would
       * arrive stale: no `in_app_dismissed`, the message never marked done, and the message
       * redrawn on the next matching event.
       */
      onClick: (button) => this.module().inAppClick(view.presentationId, json(button)),
      onDismiss: () => {
        if (this.pending?.presentationId === view.presentationId) this.pending = null;
        return this.module().inAppDismiss(view.presentationId);
      },
    });
  }

  /**
   * Signs a known person in on this device: every event from here on carries `profile.id`, and
   * the rest of `profile` updates their attributes. Records `user_identified`. Call `reset()`
   * when the person signs out.
   *
   * `options.signature` is the hex HMAC-SHA256 of `profile.id` under the environment's identity
   * secret, computed by your backend — never in the app, because the secret must not ship in it.
   * An environment that requires signed identities withholds a signed-in person's in-app
   * messages and notifications without it. The native SDK keeps and sends it, as it does on a
   * native integration.
   */
  async user(profile: TreebarsUser, options: { signature?: string } = {}): Promise<void> {
    await this.ready;
    const { id, ...attributes } = profile;
    await this.module().identify(id, json(attributes), options.signature ?? null);
  }

  /**
   * Records a screen view, and names the screen on every event that follows until the next
   * `screen()` call.
   */
  async screen(name: string, properties: EventProperties = {}): Promise<void> {
    await this.ready;
    await this.module().screen(name, json(properties));
  }

  /** Records an event, with `properties` sent as given. The name every Treebars SDK uses. */
  async track(eventName: string, properties: EventProperties = {}): Promise<void> {
    await this.ready;
    await this.module().track(eventName, json(properties));
  }

  /** @deprecated Renamed to `track`, so all four SDKs say the same word. */
  async log(eventName: string, properties: EventProperties = {}): Promise<void> {
    return this.track(eventName, properties);
  }

  /**
   * Fetches this device's pending in-app messages now, beyond the syncs the SDK already makes on
   * session start, on foreground and every `in_app_poll_interval_ms`.
   */
  async syncInAppMessages(): Promise<void> {
    await this.ready;
    await this.module().syncInAppMessages();
  }

  /**
   * The inbox: messages sent to the inbox surface, for an app that draws its own. Data only —
   * this SDK draws no inbox.
   */
  get inbox() {
    return {
      /** The messages in the inbox now. */
      list: async (): Promise<InAppMessage[]> => {
        await this.ready;
        return parse<InAppMessage[]>(await this.module().inboxList(), 'the inbox');
      },
      /** Removes a message from the inbox, for this person on every device they own. */
      dismiss: async (deliveryId: string): Promise<void> => {
        await this.ready;
        await this.module().inboxDismiss(deliveryId);
      },
      /** Reports that a card came into view (`in_app_displayed`). Once per card each time the list is shown. */
      viewed: async (deliveryId: string): Promise<void> => {
        await this.ready;
        await this.module().inboxViewed(deliveryId);
      },
      /** Reports that a card was tapped (`in_app_clicked`), with where it went. The app does the navigating. */
      clicked: async (deliveryId: string, destination?: string): Promise<void> => {
        await this.ready;
        await this.module().inboxClicked(deliveryId, destination ?? '');
      },
      /** Fetches pending messages now; the same as `syncInAppMessages()`. */
      refresh: (): Promise<void> => this.syncInAppMessages(),
    };
  }

  /**
   * The notification centre.
   *
   * Raw rows and a cursor. This SDK draws nothing and has no opinion about what a
   * notification looks like — that is the difference between this and the overlay surface,
   * and it is deliberate: a list belongs to the app's navigation, its safe areas and its
   * typography, none of which a dependency should be choosing.
   */
  get notifications() {
    return {
      /**
       * One page of the centre. Pass the page's `nextCursor` back as `cursor` for the next one;
       * `channels` limits the page to push or in-app rows.
       */
      list: async (
        options: { limit?: number; cursor?: string | null; channels?: NotificationChannel[] } = {},
      ): Promise<NotificationPage> => {
        await this.ready;
        return parse<NotificationPage>(
          await this.module().notificationsList(json(options)),
          'a notification page',
        );
      },

      /** The number of unread notifications: the first page's `unreadCount`, as both native SDKs derive it. */
      unreadCount: async (): Promise<number> => {
        const page = await this.notifications.list({ limit: 1 });
        return page.unreadCount;
      },

      /** Marks one notification read, on every device this person owns. Takes its `group_id`. */
      markRead: async (groupId: string): Promise<void> => {
        await this.ready;
        await this.module().notificationsMarkRead(groupId);
      },
      /** A notification or card tapped in the centre: opened, and read with it. */
      markOpened: async (groupId: string): Promise<void> => {
        await this.ready;
        await this.module().notificationsMarkOpened(groupId);
      },
      /** Marks everything in the centre read. */
      markAllRead: async (): Promise<void> => {
        await this.ready;
        await this.module().notificationsMarkAllRead();
      },
      /** Removes one notification from the centre, for this person on every device they own. */
      dismiss: async (groupId: string): Promise<void> => {
        await this.ready;
        await this.module().notificationsDismiss(groupId);
      },
      /** The first page, fetched again. */
      refresh: async (): Promise<NotificationPage> => this.notifications.list(),

      /**
       * Calls `callback` with the current page whenever the centre changes. Returns the
       * unsubscribe. Safe before `init()`, which sends the subscription once the native side
       * is up.
       *
       * Watchers are kept on this side and only the first subscribe and the last unsubscribe
       * cross the bridge, so an app with no bell pays nothing.
       */
      onChange: (callback: (page: NotificationPage) => void): (() => void) => {
        this.notificationWatchers.add(callback);
        if (this.notificationWatchers.size === 1) {
          void this.ready?.then(() => this.module().setNotificationsSubscribed(true));
        }
        return () => {
          this.notificationWatchers.delete(callback);
          if (this.notificationWatchers.size === 0) {
            void this.ready?.then(() => this.module().setNotificationsSubscribed(false));
          }
        };
      },
    };
  }

  /**
   * Where the link that brought somebody here wanted them to land, after the install.
   *
   * Deferred deep linking. A tap on a Treebars tracker link with a deep-link path sends the
   * person to the store; the path is carried through the install and handed to `listener` on
   * the first launch after it, as a path like `/sale/summer` to route exactly as any other link
   * is routed. On Android the Play Install Referrer carries it. On iPhone the App Store carries
   * nothing, so the path arrives only when `deferred_handoff` is on — in the config and in the
   * project's Acquisition settings. Both platforms need acquisition consent
   * (`acquisition_consent` or `setAcquisitionConsent`).
   *
   * **Called at most once per install**, and only while the install is younger than a day —
   * both decided in the native SDK. Without the first, every launch would reopen a sale somebody
   * bought from weeks ago; without the second, adding this listener in a later app version
   * would send the whole installed base into that sale on release day.
   *
   * Order does not matter. Subscribing before the path arrives is normal and so is subscribing
   * after: the native SDK holds the path until a listener takes it, and taking it is what spends
   * it. Safe before `init()`. Returns the unsubscribe.
   */
  onDeferredDeepLink(listener: (path: string) => void): () => void {
    this.deepLinkListener = listener;
    void this.ready?.then(() => this.module().setDeferredDeepLinkSubscribed(true));
    return () => {
      // Only if it is still ours: a fast refresh can register the next listener before this
      // teardown runs, and clearing unconditionally would drop the live one.
      if (this.deepLinkListener !== listener) return;
      this.deepLinkListener = null;
      void this.ready?.then(() => this.module().setDeferredDeepLinkSubscribed(false));
    };
  }

  /**
   * Listens to one of the SDK's events. The names match those common engagement SDKs use, so a
   * migration keeps its call sites. Returns the unsubscribe; safe before `init()`.
   *
   * - `pushClicked`: a push's "Open a screen" action, or its keys. A tap that opened the app
   *   from closed is held by the native SDK until this is listened to.
   * - `inAppCampaignShown`, `inAppCampaignClicked`, `inAppCampaignDismissed`: a message was
   *   shown, pressed, or closed.
   * - `inAppCampaignCustomAction`: a button set to "Hand the app keys" was pressed.
   * - `inAppCampaignSelfHandled`: **changes behaviour.** While it is listened to, a message
   *   marked self-handled comes here instead of being drawn, and the app reports what happens
   *   to it with `selfHandledShown`, `selfHandledClicked` and `selfHandledDismissed`.
   */
  setEventListener<Name extends TreebarsEventName>(name: Name, listener: (payload: TreebarsEvents[Name]) => void): () => void {
    const set = this.eventListeners.get(name) ?? new Set();
    set.add(listener as (payload: never) => void);
    this.eventListeners.set(name, set);
    this.syncEventSubscriptions();
    return () => {
      const current = this.eventListeners.get(name);
      if (!current?.delete(listener as (payload: never) => void)) return;
      if (current.size === 0) this.eventListeners.delete(name);
      this.syncEventSubscriptions();
    };
  }

  /** Tells the native side which events anybody listens to. Before `init()` it waits; `init()` sends the set. */
  private syncEventSubscriptions() {
    void this.ready?.then(() => this.module().setEventsSubscribed(json([...this.eventListeners.keys()])));
  }

  /**
   * Registers a renderer (see `InAppRenderer`), or clears it with null. Returns a function that
   * clears it again, only while this renderer is still the registered one — call it from the
   * host component's cleanup. Safe before `init()`.
   *
   * Registering re-draws a presentation that is still outstanding rather than discarding it: a
   * fast refresh rebuilds the JavaScript side while the native module stays alive, and the
   * message's `in_app_displayed` has already been recorded. Clearing hands drawing back to the
   * native SDK, which then draws standard messages itself.
   */
  setInAppRenderer(renderer: InAppRenderer | null): () => void {
    this.renderer = renderer;
    /*
     * Only forwarded once there is a native side to forward to. Before `init()` this is
     * recorded and nothing else — `init()` applies it — because a child's effect calling this
     * ahead of its parent's `init()` is the ordinary case, not a misuse.
     */
    void this.ready?.then(() => this.module().setInAppRendererEnabled(renderer !== null));
    if (renderer && this.pending) this.draw(this.pending);
    /*
     * The clear a host's cleanup should call, guarded like `setEventListener`'s: it clears only
     * while this renderer is still the registered one. An Activity rebuilt under a live React
     * context mounts the new host before the old one unmounts, and an unconditional
     * `setInAppRenderer(null)` from the old cleanup would take the new host's renderer with it.
     */
    return () => {
      if (renderer === null || this.renderer !== renderer) return;
      this.setInAppRenderer(null);
    };
  }

  /**
   * Registers this device's push token. `provider` names the service that issued it: `'fcm'`
   * for a Firebase Cloud Messaging token, `'apns'` for an APNs device token passed as its hex
   * string.
   *
   * The hex is turned into bytes inside the iOS SDK, which shares that step with its native
   * `Data` entry point, so the two cannot disagree about the token. Converting it here — with
   * `string.data(using: .utf8)`, say — would yield a token twice the correct length that no
   * push ever reaches.
   */
  async registerPushToken(token: string, provider: 'fcm' | 'apns'): Promise<void> {
    await this.ready;
    await this.module().registerPushToken(token, provider);
  }

  /**
   * Reports that a push was tapped (`notification_opened`). Pass the push's data as the
   * notification library hands it over; the SDK reads the Treebars keys it carries
   * (`DELIVERY_ID_KEY`, `CAMPAIGN_ID_KEY`). A null payload is not an error and does nothing.
   */
  async trackNotificationOpened(
    payload: Record<string, unknown> | null | undefined,
  ): Promise<void> {
    if (!payload) return;
    await this.ready;
    await this.module().trackNotificationOpened(json(payload));
  }

  /**
   * Reports that a push was swiped away (`push_dismissed`), for an app whose notification
   * library reports it. A null payload is not an error and does nothing.
   */
  async trackNotificationDismissed(payload: Record<string, unknown> | null | undefined): Promise<void> {
    if (!payload) return;
    await this.ready;
    await this.module().trackNotificationDismissed(json(payload));
  }

  /**
   * Hands a push's data from the app's messaging library — React Native Firebase's
   * `setBackgroundMessageHandler` and `onMessage` — to the Android SDK, which draws it when the
   * channel is set to have the SDK draw rich pushes. Resolves whether it drew it; any other push
   * is left to the library. Needs no `init()`: a background handler runs headless. On iOS it
   * always resolves false, since the Notification Service Extension draws a rich push there.
   */
  async handleRemotePush(data: Record<string, unknown> | null | undefined): Promise<boolean> {
    if (!data) return false;
    return this.module().handleRemotePush(json(data));
  }

  /**
   * Asks for permission to show pushes — on iOS optionally as Apple's provisional, quiet trial;
   * on Android 13 and later the runtime prompt, on the screen in front. Call it after explaining
   * why, not at launch.
   *
   * Resolves whether pushes may be shown at the moment it answers, and the two platforms answer
   * at different moments. iOS answers once the person has, so the value is their answer. Android
   * answers at once, before the person has responded to the prompt: `true` there means pushes
   * were already allowed and nothing was asked, and `false` says only that they are not allowed
   * yet, never that the person refused. On both, the SDK records the person's answer as an event.
   */
  async requestPushPermission(options: { provisional?: boolean } = {}): Promise<boolean> {
    await this.ready;
    return this.module().requestPushPermission(options.provisional === true);
  }

  /**
   * Where somebody is in the app, in its own words: a message naming contexts shows only while
   * one of them is set. Replaces the current set; `resetCurrentContext()` clears it. Named as
   * common engagement SDKs name it.
   */
  async setCurrentContext(contexts: string[]): Promise<void> {
    await this.ready;
    await this.module().setInAppContext(json(contexts));
  }

  /** Clears the contexts. Named as common engagement SDKs name it. */
  async resetCurrentContext(): Promise<void> {
    await this.ready;
    await this.module().resetInAppContext();
  }

  /** Evaluate the messages for this screen now. Named as common engagement SDKs name it. */
  async showInApp(): Promise<void> {
    await this.ready;
    await this.module().showInApp();
  }

  /**
   * Nudges may appear on this screen, until it changes, at the edge `position` names. Named as
   * common engagement SDKs name it, with its positions as words. On Android `position` is
   * ignored and a nudge may appear at either edge.
   */
  async showNudge(position: 'top' | 'bottom' | 'any' = 'any'): Promise<void> {
    await this.ready;
    await this.module().showNudge(position);
  }

  /** The self-handled message eligible now, or null. Named as common engagement SDKs name it. */
  async getSelfHandledInApp(): Promise<InAppMessage | null> {
    return (await this.getSelfHandledInApps())[0] ?? null;
  }

  /** Every self-handled message eligible now. Named as common engagement SDKs name it. */
  async getSelfHandledInApps(): Promise<InAppMessage[]> {
    await this.ready;
    return parse<InAppMessage[]>(await this.module().getSelfHandledInApps(), 'self-handled messages');
  }

  /**
   * Call when the app has shown a self-handled message: it is counted as displayed, as any
   * display is. Named as common engagement SDKs name it.
   */
  async selfHandledShown(message: Pick<InAppMessage, 'delivery_id'>): Promise<void> {
    await this.ready;
    await this.module().selfHandledShown(message.delivery_id);
  }

  /**
   * Call when a self-handled message was pressed; `button` names what, when there is one. A
   * call to action ends the message. Named as common engagement SDKs name it.
   */
  async selfHandledClicked(message: Pick<InAppMessage, 'delivery_id'>, button?: InAppButton): Promise<void> {
    await this.ready;
    await this.module().selfHandledClicked(message.delivery_id, button ? json(button) : '');
  }

  /** Call when a self-handled message went away. Named as common engagement SDKs name it. */
  async selfHandledDismissed(message: Pick<InAppMessage, 'delivery_id'>): Promise<void> {
    await this.ready;
    await this.module().selfHandledDismissed(message.delivery_id);
  }

  /**
   * A form's answers, keyed by field id, from the component that drew it: recorded as
   * `in_app_form_submitted`, and an email or phone field the form keeps becomes the person's
   * address.
   */
  async submitInAppForm(deliveryId: string, responses: Record<string, string | number>): Promise<void> {
    await this.ready;
    await this.module().submitInAppForm(deliveryId, json(responses));
  }

  /** Uploads everything queued now, rather than waiting for the next automatic flush. */
  async flush(): Promise<void> {
    await this.ready;
    await this.module().flush();
  }

  /**
   * Grants or withdraws consent to report how this install arrived. See `acquisition_consent`
   * on the config, which is where an app that already knows the answer should give it. Safe
   * before `init()`: the native SDK keeps an answer given early.
   *
   * The reading, the retries and the event all run in the native SDK; this forwards the answer.
   */
  async setAcquisitionConsent(granted: boolean): Promise<void> {
    await this.ready;
    await this.module().setAcquisitionConsent(granted);
  }

  /**
   * Report that a link opened this app, so a tracker link that brings somebody back is credited.
   *
   * Pass every URL the app is opened with. Resolves with the link's deep-link path when a
   * Universal Link or App Link on one of the config's `linkHosts` opened the app — the operating
   * system hands over only the link's address, so the native SDK asks the link host what it
   * means — and with null for every other URL, which the app routes as it always did. It never
   * routes anything itself, and a host not on that list is never asked.
   *
   * The parsing, the lookup and the event all run in the native SDK on both platforms; this
   * passes the URL across.
   */
  async handleLink(url: string): Promise<string | null> {
    await this.ready;
    return (await this.module().handleLink(url)) ?? null;
  }

  /**
   * Milliseconds until the next automatic flush, or null when none is scheduled: an event
   * schedules one, so it is null while nothing has been recorded since the last upload, and
   * before `init()`. Zero means a flush is due now, which is not the same as none scheduled.
   *
   * Synchronous, so a debug screen can read it once a second to draw a countdown without a
   * round trip per tick. The bridge carries "nothing scheduled" as `-1`, since codegen has no
   * nullable number.
   */
  msUntilNextFlush(): number | null {
    if (!this.native || !this.ready) return null;
    const value = this.native.msUntilNextFlush();
    return value < 0 ? null : value;
  }

  /** How many events are waiting to be uploaded. 0 before `init()`. */
  async pendingCount(): Promise<number> {
    if (!this.ready) return 0;
    await this.ready;
    return this.module().pendingCount();
  }

  /**
   * Signs the person out on this device. Events already queued are still sent: they were
   * recorded while that person was signed in.
   */
  async reset(): Promise<void> {
    await this.ready;
    await this.module().reset();
  }

  /**
   * Stops the SDK recording or sending anything from this device until `optIn()`, and on every later
   * launch — the native SDK keeps the answer. What was waiting to be sent is dropped. Safe before `init()`,
   * which is where a consent prompt that answers first calls it. Nothing already sent is touched:
   * that is the API's `/privacy/delete`, from the app's backend.
   */
  async optOut(): Promise<void> {
    await this.module().optOut();
  }

  /** Undoes `optOut()`: recording resumes with the next event. */
  async optIn(): Promise<void> {
    await this.module().optIn();
  }

  /** Whether `optOut()` is in effect on this device. Safe before `init()`. */
  async isOptedOut(): Promise<boolean> {
    return this.module().isOptedOut();
  }

  /**
   * A token for whatever will report the purchase about to happen, so its event is filed under
   * this device, this person and this session: `context.treebars` for the app's backend,
   * `appAccountToken` on iOS, `obfuscatedAccountIdAndroid` on Android, or Stripe's or
   * RevenueCat's metadata. Treebars issues it for this device, so it is proof the device asked
   * rather than a string anybody could write — and it works for a guest.
   *
   * Once per purchase, just before it: asking counts as activity in the session, as an event
   * would. Null before `init()`, while opted out, or when the server could not be reached — go
   * ahead with the purchase without it.
   */
  async contextToken(): Promise<string | null> {
    // After `init()` has crossed, where one is in flight: asked before, the native SDK has no device to name and says null.
    await this.ready;
    return (await this.module().contextToken()) ?? null;
  }

  /**
   * Forgets this device, here: its id and secret, who is signed in and who had been, the queue and
   * everything waiting to be sent, the session, the in-app ledger and the notification history — and
   * sends nothing on the way. From the next event it is a device the server has never seen. The
   * opt-out stays; a person who wants to be forgotten and not recorded again is opted out as well.
   */
  async wipeLocalData(): Promise<void> {
    await this.ready;
    await this.module().wipeLocalData();
  }
}

const treebars = new TreebarsSDK();
export default treebars;
