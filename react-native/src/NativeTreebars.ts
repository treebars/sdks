import { TurboModuleRegistry, type TurboModule } from 'react-native';
import type { EventEmitter } from 'react-native/Libraries/Types/CodegenTypes';

/**
 * The TurboModule spec: the whole bridge. Everything below it is a native Treebars SDK —
 * Kotlin on Android, Swift on iOS — and React Native holds no logic of its own.
 *
 * **Everything crosses as JSON strings, not codegen structs.** `InAppMessage`, `InAppContent`,
 * `InAppTokens` and `NotificationPage` are almost entirely optional fields, and the two
 * generators differ in how they handle optionals — a struct of a dozen maybes generates a
 * builder whose behaviour is not the same on both platforms. One parse per call is the cost,
 * and the parse is also what makes JS tolerant of a native build older or newer than it: an
 * unknown key is ignored rather than failing a codegen boundary.
 *
 * **Nothing here may swallow.** A `JSON.parse` failure on this side, or an
 * `NSJSONSerialization` failure on the other, rejects with `bad_payload`. It does not pass
 * `nil` onward and it does not fabricate a plausible return value: a bridge that answered an
 * empty inbox or a cheerful default on a parse error would make a marshalling failure
 * indistinguishable from a real answer.
 *
 * **What a resolved promise means.** A write — `track`, `registerPushToken`, `notificationsMarkRead`
 * and the rest — resolves once the native SDK has accepted the call, not once anything has been
 * uploaded. Nobody should read one as a delivery receipt.
 *
 * **`get`, not `getEnforcing`.** A missing native module does not crash the app at import.
 * `init()` rejects instead, with a message saying how to rebuild, because without the module
 * the SDK can report nothing at all.
 */
export interface Spec extends TurboModule {
  // ---------------------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------------------

  /**
   * `configJson` carries the write key, the backend URL, the flags and the adoption block.
   *
   * One JSON argument rather than a dozen parameters, because the config grows, and a codegen
   * signature would make every new option a breaking change for both native sides at once.
   */
  initialize(configJson: string): Promise<void>;
  reset(): Promise<void>;
  /**
   * The person's opt-out, kept by the native SDK across launches. No started gate on either side: it
   * keeps an opt-out made before `initialize`, as it keeps a consent grant.
   */
  optOut(): Promise<void>;
  optIn(): Promise<void>;
  isOptedOut(): Promise<boolean>;
  /**
   * A context token Treebars issued for this device and its session: a lower-case UUID, the same on both platforms.
   * The native SDK asks for it and counts it as session activity, as an event would; the bridge only carries the
   * answer. Null when there is none to give — before `initialize`, while opted out, or on any failure — and never a
   * rejection.
   */
  contextToken(): Promise<string | null>;
  /** Forgets this device in the native SDK: its id and secret, who was signed in, and everything unsent. */
  wipeLocalData(): Promise<void>;
  flush(): Promise<void>;
  /** The native SDK's consent switch for the install referrer and AdServices reads, forwarded as-is. */
  setAcquisitionConsent(granted: boolean): Promise<void>;
  /** A link opened the app; the native SDK parses it and decides whether there is anything to report. */
  handleLink(url: string): Promise<string | null>;

  // ---------------------------------------------------------------------------------------
  // Events
  // ---------------------------------------------------------------------------------------

  track(eventName: string, propertiesJson: string): Promise<void>;
  screen(name: string, propertiesJson: string): Promise<void>;
  /** `signature` is the app backend's, carried to the native SDK untouched; null when there is none. */
  identify(userId: string, attributesJson: string, signature: string | null): Promise<void>;

  /**
   * `provider` is `fcm` or `apns`. Anything else is refused rather than defaulted, because a
   * token filed under the wrong provider is accepted everywhere and fails only at the far end,
   * as a device that is never reached.
   */
  registerPushToken(token: string, provider: string): Promise<void>;

  /**
   * The raw push payload, as JSON.
   *
   * Passed through unchanged rather than pre-extracted: Swift takes `[AnyHashable: Any]` and
   * Kotlin `Map<String, String>`, both reading the Treebars keys (`DELIVERY_ID_KEY`,
   * `CAMPAIGN_ID_KEY`) at the root, so the wrapper has no business deciding which keys matter.
   */
  trackNotificationOpened(payloadJson: string): Promise<void>;
  /**
   * Asks for push permission: the native SDK's own prompt, `provisional` being Apple's quiet trial. Resolves whether
   * pushes may be shown at the moment it answers — on iOS once the person has answered the prompt, on Android before
   * they have; the person's answer is recorded by the native SDK as an event.
   */
  requestPushPermission(provisional: boolean): Promise<boolean>;
  /** A push swiped away, for an app whose notification library sees it: `push_dismissed`. */
  trackNotificationDismissed(payloadJson: string): Promise<void>;
  /**
   * A push's data, handed over from the app's messaging library, drawn by the native SDK when it is one the SDK draws.
   * Resolves whether it was. Android draws; iOS always resolves false — its rich parts are the Notification Service
   * Extension's (`TreebarsNotificationService.enrich`), which runs outside the app. No `initialize` needed: it runs
   * from a headless background task.
   */
  handleRemotePush(payloadJson: string): Promise<boolean>;
  /**
   * Which of `setEventListener`'s events JavaScript listens to, as a JSON list of names:
   * `pushClicked`, `inAppCampaignShown`, `inAppCampaignClicked`, `inAppCampaignDismissed`, `inAppCampaignCustomAction`,
   * `inAppCampaignSelfHandled`. Installs the native listeners for those and hands the rest back; a push action that
   * arrived before anybody listened is held by the native SDK and delivered here. Self-handled is its own subscription
   * because listening changes behaviour: a self-handled message goes to JavaScript instead of the renderer.
   */
  setEventsSubscribed(namesJson: string): Promise<void>;

  // ---------------------------------------------------------------------------------------
  // Queue telemetry, for an app's own debug screen
  // ---------------------------------------------------------------------------------------

  pendingCount(): Promise<number>;

  /**
   * Synchronous, and the only synchronous method here.
   *
   * A debug screen may read it once a second to draw a countdown; a promise per tick would be
   * a round trip per tick for a number the native side already holds. `-1` rather than null
   * because codegen has no nullable number — the wrapper maps it back.
   */
  msUntilNextFlush(): number;

  // ---------------------------------------------------------------------------------------
  // In-app
  // ---------------------------------------------------------------------------------------

  syncInAppMessages(): Promise<void>;
  inboxList(): Promise<string>;
  inboxDismiss(deliveryId: string): Promise<void>;
  /** A card came into view — `in_app_displayed`. */
  inboxViewed(deliveryId: string): Promise<void>;
  /** A card was tapped — `in_app_clicked`; an empty destination is none. */
  inboxClicked(deliveryId: string, destination: string): Promise<void>;

  /**
   * Whether JavaScript draws standard messages, or the native SDK does.
   *
   * Enabled, the native SDK hands each standard presentation to JavaScript. Disabled — and
   * before an app registers a renderer — the native SDK draws it itself. So a trigger answered
   * at cold start, before any JavaScript effect has run (`initialize` records `app_open` first,
   * and an `EventEmitter` has no replay), is drawn natively rather than waiting.
   */
  setInAppRendererEnabled(enabled: boolean): Promise<void>;

  /**
   * Report a press on a presentation. **Does not end it.**
   *
   * A renderer that reports a click, such as a markup body's `treebars://click/<n>`, keeps its
   * overlay up, because closing it there would make click a third spelling of dismiss. A markup
   * body may fire click and then dismiss on the same presentation, so this must be safe to call
   * repeatedly and must leave the slot live.
   */
  inAppClick(presentationId: string, buttonJson: string): Promise<void>;

  /** Ends the presentation, marks the message done and reports `in_app_dismissed`. */
  inAppDismiss(presentationId: string): Promise<void>;

  /** The app's contexts, a JSON list of names; a message naming contexts shows only while one is set. */
  setInAppContext(contextsJson: string): Promise<void>;

  /** Clears the app's contexts. */
  resetInAppContext(): Promise<void>;

  /** Evaluate the messages for this screen now: the native SDK's `showInApp`. */
  showInApp(): Promise<void>;
  /** Nudges may appear on this screen: `top`, `bottom` or `any`. The native SDK's `showNudge`. */
  showNudge(position: string): Promise<void>;

  /** Every self-handled message eligible now, as a JSON list of messages. */
  getSelfHandledInApps(): Promise<string>;

  /** The app drew the self-handled message with this delivery id. */
  selfHandledShown(deliveryId: string): Promise<void>;

  /** A self-handled message was pressed; `buttonJson` names the button, or is empty. */
  selfHandledClicked(deliveryId: string, buttonJson: string): Promise<void>;

  /** A self-handled message went away. */
  selfHandledDismissed(deliveryId: string): Promise<void>;

  /** A form's answers, a JSON object by field id, for the message with this delivery id. */
  submitInAppForm(deliveryId: string, responsesJson: string): Promise<void>;

  // ---------------------------------------------------------------------------------------
  // The notification centre
  // ---------------------------------------------------------------------------------------

  notificationsList(optionsJson: string): Promise<string>;
  notificationsMarkRead(groupId: string): Promise<void>;
  /** A notification or card tapped in the centre — opened, and read with it. */
  notificationsMarkOpened(groupId: string): Promise<void>;
  notificationsMarkAllRead(): Promise<void>;
  notificationsDismiss(groupId: string): Promise<void>;

  /**
   * Whether anything is watching the inbox.
   *
   * JS keeps its own watcher `Set` and calls this only on 0→1 and 1→0, so an app with no bell
   * pays nothing.
   */
  setNotificationsSubscribed(subscribed: boolean): Promise<void>;

  /**
   * Whether anything is watching for the link that brought somebody here.
   *
   * The same rule as the bell, for the same reason, and here it is the whole feature rather than a
   * saving: the native SDK hands the path over ONCE and then forgets it, so taking it with nobody
   * listening would spend the one delivery on nothing. The path can arrive before the app's effects
   * have run or after them — either order is normal, and the native SDK's own store is what makes
   * both work.
   */
  setDeferredDeepLinkSubscribed(subscribed: boolean): Promise<void>;

  // ---------------------------------------------------------------------------------------
  // Events out
  //
  // All three follow one rule: native does not spend state for an absent listener, and the
  // outstanding value is re-emitted on re-subscribe. `EventEmitter` has no replay, and
  // `initialize` fires the device report, `app_open` and a sync before the app's effects
  // have run — so a rule written for one emitter and not the others just moves the lost event.
  // ---------------------------------------------------------------------------------------

  /** `{ presentationId, message, tokens }`, already JSON-decoded by codegen into a string. */
  readonly onInAppPresent: EventEmitter<string>;
  readonly onNotificationsChange: EventEmitter<string>;
  readonly onUploadLog: EventEmitter<string>;

  /**
   * The path a tracker link carried through the install, once per install. Android reads it from
   * the Play Install Referrer; iOS from the handoff a Treebars link carries across the App Store,
   * when `deferred_handoff` is on.
   */
  readonly onDeferredDeepLink: EventEmitter<string>;

  /** One of `setEventListener`'s events, as `{ name, data }` JSON; see `TreebarsEvents` in `types.ts`. */
  readonly onTreebarsEvent: EventEmitter<string>;
}

export default TurboModuleRegistry.get<Spec>('TreebarsNative');
