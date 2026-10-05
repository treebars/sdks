#import "TreebarsNative.h"

/*
 * The Swift core's Objective-C face. `TreebarsSDK` is the core pod's name and its Swift module,
 * which is why the pod on disk and the header named here are spelled differently — that
 * podspec's own comment explains the collision that split them.
 *
 * **`@import TreebarsSDK` is what a Swift pod is normally reached by, and it does not compile
 * here.** `@import` in Objective-C++ needs `-fcxx-modules`, which is off, so the error is
 * `use of '@import' when C++ modules are disabled` on this line — before anything about the
 * dependency has been considered. Turning it on moves the failure rather than removing it:
 * with `-fcxx-modules` every React Native header in this file's include graph becomes a C++
 * module, and the build then stops on `declaration of 'RCTPromiseRejectBlock' must be imported
 * from module 'ReactCodegen.rnasyncstorage.rnasyncstorage' before it is required` — a message
 * naming another library's codegen and nothing this package owns.
 *
 * A textual include has no such reach, and needs one thing to work: the header is generated
 * during the CORE's build, into a directory no consumer searches. `TreebarsReactNative.podspec` adds
 * that directory, and without it this line fails as `file not found` after a `pod install`
 * that succeeded — which reads as a broken podspec rather than a missing search path.
 */
#import "TreebarsSDK-Swift.h"

/**
 * The iOS half of the bridge. Everything below it is the Swift core; nothing above it is.
 *
 * Read `src/NativeTreebars.ts` for the contract this answers — every method here exists
 * because that spec declares it, and the reasoning for the JSON-string boundary, the
 * presentation protocol and the emitters lives there rather than being restated.
 *
 * What this file adds on top of the spec is the part only Objective-C has to solve:
 *
 * - **Nothing raises.** A promise-returning TurboModule method on this platform is dispatched
 *   onto a shared module queue, and an ObjC exception raised inside one is rethrown there with
 *   nothing above it — `convertNSExceptionToJSError` covers SYNCHRONOUS methods only, so an
 *   async body that throws terminates the app rather than rejecting a promise. Every body
 *   below therefore runs inside `TreebarsAnswer`, which turns a raise into a rejection.
 * - **The presentation slot.** `Treebars.setInAppRenderer` hands over two closures, and a
 *   TurboModule cannot give a closure to JavaScript. So an id is minted with them, the pair is
 *   boxed in `TreebarsPresentation`, and one slot holds the pair the id names. One slot and not
 *   a map because both cores show one overlay at a time — a second presentation supersedes the
 *   first, and an id that is no longer in the slot resolves and does nothing.
 * - **`inAppClick` leaves the slot live.** A markup body fires a `treebars://click/<n>` and
 *   then `treebars://dismiss` on the same presentation. Under a clear-on-click rule the
 *   dismiss arrives stale and is dropped, which loses `in_app_dismissed` and the `markDone`
 *   with it — so the message is drawn again on the next matching event, to somebody who
 *   already closed it.
 * - **Re-subscribing re-emits.** `EventEmitter` has no replay and `initialize` reports a
 *   device context, an `app_open` and a sync before any of the app's effects have run, so a
 *   listener arriving second would see nothing. `setInAppRendererEnabled:YES` re-emits the
 *   outstanding presentation instead of clearing it, and `setNotificationsSubscribed:YES`
 *   re-emits the last page. Neither spends anything: what gates SPENDING is whether the core
 *   holds a renderer at all, which is the other half of the same switch.
 *
 * There is one bridge file and no old-architecture twin: this package is a TurboModule, for
 * React Native's New Architecture only.
 */

/// Rejection codes, which are a contract with `Treebars.ts` rather than internal names.
///
/// The third, `bad_config`, is only ever raised inside the Swift façade — nothing on this side
/// of the boundary reads a configuration.
static NSString *const kTreebarsNotInitialized = @"not_initialized";
static NSString *const kTreebarsBadPayload = @"bad_payload";

/**
 * Every promise body runs inside this.
 *
 * An `NSException` here is not a JavaScript error unless something makes it one: the async
 * dispatch has no `@try` above it, so a raise unwinds off the module queue and takes the
 * process with it. The exception's own name becomes the code rather than being flattened into
 * one of the spec's three — `bad_payload` is a claim about the argument, and a raise is not
 * that claim.
 */
static void TreebarsAnswer(RCTPromiseRejectBlock reject, void (^body)(void))
{
  @try {
    body();
  } @catch (NSException *raised) {
    reject(
        raised.name.length > 0 ? raised.name : @"native_exception",
        raised.reason.length > 0 ? raised.reason : @"Treebars: the native side raised",
        nil);
  }
}

/// Turns a façade failure into a rejection, and answers whether it did.
static BOOL TreebarsRejected(TreebarsBridgeFailure *_Nullable failure, RCTPromiseRejectBlock reject)
{
  if (failure == nil) {
    return NO;
  }
  reject(failure.code, failure.message, nil);
  return YES;
}

/**
 * Refuses anything that would otherwise answer with a fabricated value.
 *
 * The core tolerates being called before `initialize` — by doing nothing, quietly — so an
 * inbox would come back empty and a notification page would come back as a cache miss, both
 * indistinguishable from a real answer, which is exactly what this bridge refuses to give.
 * It costs the wrapper nothing: every method there awaits the same in-flight `init()`.
 */
static BOOL TreebarsRejectedUnstarted(RCTPromiseRejectBlock reject)
{
  if ([TreebarsBridge isStarted]) {
    return NO;
  }
  reject(
      kTreebarsNotInitialized,
      @"Treebars: initialize has not been called, or it failed",
      nil);
  return YES;
}

@implementation TreebarsNative {
  /**
   * The one live presentation, and the three fields are one value.
   *
   * Written from the main thread — the core invokes a renderer on the main actor — and read
   * from the module's own serial queue, so the trio is guarded rather than assumed. The JSON
   * is held beside the box because re-subscribing has to re-emit exactly what was emitted the
   * first time; rebuilding it would mint a second id for the same overlay.
   */
  NSString *_presentationId;
  NSString *_presentationJson;
  TreebarsPresentation *_presentation;

  /**
   * The notification centre's last page, and whether anybody is listening for the next one.
   *
   * The core is watched from `initialize` onwards whatever JavaScript is doing, because a page
   * costs nothing to hold and a bell that re-subscribes after a screen remount would otherwise
   * read as empty until the next write. Only the EMIT is gated.
   */
  NSString *_notificationsLatest;
  BOOL _notificationsSubscribed;

  /**
   * Whether this module has installed the core's renderer before. A second install is the same host coming back — the
   * JavaScript host unmounted and mounted while this module lived on — and it hands its outstanding presentation
   * back, so the core must not free the screen for another message. A module built by a reload starts at NO.
   */
  BOOL _rendererInstalled;

  NSLock *_lock;
}

RCT_EXPORT_MODULE()

+ (BOOL)requiresMainQueueSetup
{
  return NO;
}

- (instancetype)init
{
  if (self = [super init]) {
    _lock = [NSLock new];
  }
  return self;
}

/**
 * Drops every route back into a runtime that is going away.
 *
 * The upload listener, the notification watcher and the in-app renderer are held by a Swift
 * singleton that outlives every reload — so without this, a torn-down module goes on being
 * handed values it can only forward into a dead JavaScript runtime. The blocks capture `self`
 * weakly for the same reason from the other direction: a strong capture would be a cycle
 * through the singleton and this module would never be deallocated at all.
 */
- (void)invalidate
{
  [TreebarsBridge detach];

  [_lock lock];
  _presentationId = nil;
  _presentationJson = nil;
  _presentation = nil;
  _notificationsLatest = nil;
  _notificationsSubscribed = NO;
  [_lock unlock];
}

/**
 * Whether an emit would reach anything.
 *
 * `_eventEmitterCallback` is a `std::function` installed when the JSI object is constructed,
 * which happens before JavaScript can call any method here — so no JS-driven path can find it
 * empty. A native listener firing after teardown can, and calling an empty `std::function`
 * throws where nothing is catching. `invalidate` above is the real fix; this is the guard that
 * makes its absence survivable rather than fatal.
 */
- (BOOL)canEmit
{
  return (bool)_eventEmitterCallback;
}

// -----------------------------------------------------------------------------------------
// Lifecycle
// -----------------------------------------------------------------------------------------

- (void)initialize:(NSString *)configJson
           resolve:(RCTPromiseResolveBlock)resolve
            reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    __weak __typeof(self) weakSelf = self;

    /*
     * Both listeners are installed by the same call, and the upload one is why.
     * `setUploadListener` writes through an uploader that does not exist until `initialize`
     * has built it, so installing it first would install it into nothing — a listener that is
     * demonstrably set and reports no upload ever.
     */
    TreebarsBridgeFailure *failure = [TreebarsBridge
        startWithConfigJson:configJson
                 uploadSink:^(NSString *json) {
                   __typeof(self) strongSelf = weakSelf;
                   if ([strongSelf canEmit]) {
                     [strongSelf emitOnUploadLog:json];
                   }
                 }
          notificationsSink:^(NSString *json) {
            [weakSelf holdNotificationPage:json];
          }];

    if (TreebarsRejected(failure, reject)) {
      return;
    }
    resolve(nil);
  });
}

- (void)reset:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    [TreebarsBridge reset];
    resolve(nil);
  });
}

- (void)flush:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    [TreebarsBridge flush];
    resolve(nil);
  });
}

// No started gate: the core keeps an opt-out made before `initialize`, as it keeps a consent grant.
- (void)optOut:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    [TreebarsBridge optOut];
    resolve(nil);
  });
}

- (void)optIn:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    [TreebarsBridge optIn];
    resolve(nil);
  });
}

- (void)isOptedOut:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    resolve(@([TreebarsBridge isOptedOut]));
  });
}

// No started gate, and it resolves null rather than rejecting: the core answers nil before
// `initialize`, and an app awaits this on its way to a purchase, which must go ahead without a
// token rather than fail for want of one. The completion runs off a Swift `Task`, so it carries
// its own guard, as `pendingCount`'s does.
- (void)contextToken:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    [TreebarsBridge contextToken:^(NSString *_Nullable token) {
      TreebarsAnswer(reject, ^{
        resolve(token ?: (id)[NSNull null]);
      });
    }];
  });
}

- (void)wipeLocalData:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    [TreebarsBridge wipeLocalData];
    resolve(nil);
  });
}

// No started gate: the core holds a grant made before `initialize`, so the bridge must not be
// stricter than the thing it bridges.
- (void)setAcquisitionConsent:(BOOL)granted
                      resolve:(RCTPromiseResolveBlock)resolve
                       reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    [TreebarsBridge setAcquisitionConsent:granted];
    resolve(nil);
  });
}

// A link opened the app. The Swift core parses it, asks a link host what a Universal Link means,
// measures the idle gap and decides what to report; the promise settles with the link's deep-link
// path, or nil for a URL the app routes itself. Nothing is parsed on this side, for the reason every
// method here gives.
- (void)handleLink:(NSString *)url
           resolve:(RCTPromiseResolveBlock)resolve
            reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    [TreebarsBridge handleLink:url completion:^(NSString *_Nullable path) {
      resolve(path);
    }];
  });
}

// -----------------------------------------------------------------------------------------
// Events
// -----------------------------------------------------------------------------------------

- (void)track:(NSString *)eventName
    propertiesJson:(NSString *)propertiesJson
           resolve:(RCTPromiseResolveBlock)resolve
            reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    if (TreebarsRejected([TreebarsBridge track:eventName propertiesJson:propertiesJson], reject)) {
      return;
    }
    resolve(nil);
  });
}

- (void)screen:(NSString *)name
    propertiesJson:(NSString *)propertiesJson
           resolve:(RCTPromiseResolveBlock)resolve
            reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    if (TreebarsRejected([TreebarsBridge screen:name propertiesJson:propertiesJson], reject)) {
      return;
    }
    resolve(nil);
  });
}

- (void)identify:(NSString *)userId
    attributesJson:(NSString *)attributesJson
         signature:(NSString *_Nullable)signature
           resolve:(RCTPromiseResolveBlock)resolve
            reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    if (TreebarsRejected([TreebarsBridge identify:userId attributesJson:attributesJson signature:signature], reject)) {
      return;
    }
    resolve(nil);
  });
}

- (void)registerPushToken:(NSString *)token
                 provider:(NSString *)provider
                  resolve:(RCTPromiseResolveBlock)resolve
                   reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    if (TreebarsRejected([TreebarsBridge registerPushToken:token provider:provider], reject)) {
      return;
    }
    resolve(nil);
  });
}

- (void)trackNotificationOpened:(NSString *)payloadJson
                        resolve:(RCTPromiseResolveBlock)resolve
                         reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    if (TreebarsRejected([TreebarsBridge trackNotificationOpened:payloadJson], reject)) {
      return;
    }
    resolve(nil);
  });
}

- (void)trackNotificationDismissed:(NSString *)payloadJson
                           resolve:(RCTPromiseResolveBlock)resolve
                            reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    if (TreebarsRejected([TreebarsBridge trackNotificationDismissed:payloadJson], reject)) {
      return;
    }
    resolve(nil);
  });
}

/**
 * Always false on iOS, and not for want of an implementation: a push's rich parts are attached by the app's
 * Notification Service Extension (`TreebarsNotificationService.enrich`), which runs in its own process before the
 * alert is shown. There is nothing for the app to draw. Android draws here.
 */
- (void)handleRemotePush:(NSString *)payloadJson
                 resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject
{
  resolve(@NO);
}

/**
 * `setEventListener`'s events, forwarded from the core by the bridge facade and nothing more.
 * No started gate, like the deferred deep link's: subscribing before `initialize` is the ordinary React ordering.
 */
- (void)setEventsSubscribed:(NSString *)namesJson
                    resolve:(RCTPromiseResolveBlock)resolve
                     reject:(RCTPromiseRejectBlock)reject
{
  __weak __typeof(self) weakSelf = self;
  TreebarsBridgeFailure *failure = [TreebarsBridge setEventsSubscribed:namesJson sink:^(NSString *event) {
    __typeof(self) strongSelf = weakSelf;
    if ([strongSelf canEmit]) {
      [strongSelf emitOnTreebarsEvent:event];
    }
  }];
  if (TreebarsRejected(failure, reject)) {
    return;
  }
  resolve(nil);
}

- (void)requestPushPermission:(BOOL)provisional
                      resolve:(RCTPromiseResolveBlock)resolve
                       reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    [TreebarsBridge requestPushPermission:provisional completion:^(BOOL granted) {
      resolve(@(granted));
    }];
  });
}

// -----------------------------------------------------------------------------------------
// Queue telemetry, for an app's own debug screen
// -----------------------------------------------------------------------------------------

- (void)pendingCount:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    // The completion runs off a Swift `Task` rather than on this queue, so it carries its own
    // guard: a raise inside it has no `@try` above it either.
    [TreebarsBridge pendingCountWithCompletion:^(NSInteger pending) {
      TreebarsAnswer(reject, ^{
        resolve(@(pending));
      });
    }];
  });
}

/// The only synchronous method here, and `-1` is how it says "nothing is scheduled".
- (NSNumber *)msUntilNextFlush
{
  return @([TreebarsBridge msUntilNextFlush]);
}

// -----------------------------------------------------------------------------------------
// In-app
// -----------------------------------------------------------------------------------------

- (void)syncInAppMessages:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    [TreebarsBridge syncInAppMessages];
    resolve(nil);
  });
}

- (void)inboxList:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    NSString *inbox = [TreebarsBridge inboxList];
    if (inbox == nil) {
      // An inbox that will not encode is not an empty inbox, and answering `[]` would make a
      // marshalling bug read as a person with no messages.
      reject(kTreebarsBadPayload, @"inbox.list: the inbox could not be encoded", nil);
      return;
    }
    resolve(inbox);
  });
}

- (void)inboxDismiss:(NSString *)deliveryId
             resolve:(RCTPromiseResolveBlock)resolve
              reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    [TreebarsBridge inboxDismiss:deliveryId];
    resolve(nil);
  });
}

- (void)inboxViewed:(NSString *)deliveryId
            resolve:(RCTPromiseResolveBlock)resolve
             reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    [TreebarsBridge inboxViewed:deliveryId];
    resolve(nil);
  });
}

- (void)inboxClicked:(NSString *)deliveryId
         destination:(NSString *)destination
             resolve:(RCTPromiseResolveBlock)resolve
              reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    [TreebarsBridge inboxClicked:deliveryId destination:destination];
    resolve(nil);
  });
}

- (void)notificationsMarkOpened:(NSString *)groupId
                        resolve:(RCTPromiseResolveBlock)resolve
                         reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    [TreebarsBridge notificationsMarkOpened:groupId];
    resolve(nil);
  });
}

- (void)setInAppRendererEnabled:(BOOL)enabled
                        resolve:(RCTPromiseResolveBlock)resolve
                         reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }

    if (!enabled) {
      /*
       * The renderer goes and the slot deliberately stays. Clearing the core's renderer hands
       * drawing back to the core, which then draws a standard message natively. Clearing the
       * SLOT would throw away an overlay that is still on screen as far as anybody watching is
       * concerned, and whose display has already been spent.
       */
      [TreebarsBridge setInAppRendererWithSink:nil reattaching:NO];
      resolve(nil);
      return;
    }

    __weak __typeof(self) weakSelf = self;
    [TreebarsBridge setInAppRendererWithSink:^(NSString *presentationId,
                                               NSString *presentationJson,
                                               TreebarsPresentation *presentation) {
      [weakSelf holdPresentation:presentationId json:presentationJson box:presentation];
    }
                                 reattaching:_rendererInstalled];
    _rendererInstalled = YES;

    /*
     * And the outstanding one goes out again, which is the whole reason this is a switch
     * rather than a one-way registration. Metro rebuilds the JavaScript listener set while
     * this module stays alive; `in_app_displayed` has already been spent, so handing the
     * presentation back to the reconnecting listener is the only action that is not a loss.
     */
    NSString *outstanding = [self outstandingPresentation];
    if (outstanding != nil && [self canEmit]) {
      [self emitOnInAppPresent:outstanding];
    }
    resolve(nil);
  });
}

- (void)inAppClick:(NSString *)presentationId
        buttonJson:(NSString *)buttonJson
           resolve:(RCTPromiseResolveBlock)resolve
            reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }

    TreebarsPresentation *presentation = [self presentationFor:presentationId];
    if (presentation == nil) {
      // Stale, which is ordinary rather than exceptional: a superseded overlay whose host has
      // not yet been told. Nothing to report and nothing to fail.
      resolve(nil);
      return;
    }

    // The slot is untouched on purpose — see the note at the top of this file.
    if (TreebarsRejected([presentation clickWithButtonJson:buttonJson], reject)) {
      return;
    }
    resolve(nil);
  });
}

- (void)inAppDismiss:(NSString *)presentationId
             resolve:(RCTPromiseResolveBlock)resolve
              reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }

    // Taken out of the slot first, then dismissed: `dismiss` marks the message done and
    // reports `in_app_dismissed`, and a second dismissal of the same id must find nothing.
    [[self takePresentation:presentationId] dismiss];
    resolve(nil);
  });
}

- (void)setInAppContext:(NSString *)contextsJson
                resolve:(RCTPromiseResolveBlock)resolve
                 reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    if (TreebarsRejected([TreebarsBridge setInAppContext:contextsJson], reject)) {
      return;
    }
    resolve(nil);
  });
}

- (void)resetInAppContext:(RCTPromiseResolveBlock)resolve
                   reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    [TreebarsBridge resetInAppContext];
    resolve(nil);
  });
}

- (void)showInApp:(RCTPromiseResolveBlock)resolve
           reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    [TreebarsBridge showInApp];
    resolve(nil);
  });
}

- (void)showNudge:(NSString *)position
          resolve:(RCTPromiseResolveBlock)resolve
           reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    [TreebarsBridge showNudge:position];
    resolve(nil);
  });
}

- (void)getSelfHandledInApps:(RCTPromiseResolveBlock)resolve
                      reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    [TreebarsBridge getSelfHandledInApps:^(NSString *messages) {
      resolve(messages);
    }];
  });
}

- (void)selfHandledShown:(NSString *)deliveryId
                 resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    if (TreebarsRejected([TreebarsBridge selfHandledShown:deliveryId], reject)) {
      return;
    }
    resolve(nil);
  });
}

- (void)selfHandledClicked:(NSString *)deliveryId
                buttonJson:(NSString *)buttonJson
                   resolve:(RCTPromiseResolveBlock)resolve
                    reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    if (TreebarsRejected([TreebarsBridge selfHandledClicked:deliveryId buttonJson:buttonJson], reject)) {
      return;
    }
    resolve(nil);
  });
}

- (void)selfHandledDismissed:(NSString *)deliveryId
                     resolve:(RCTPromiseResolveBlock)resolve
                      reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    if (TreebarsRejected([TreebarsBridge selfHandledDismissed:deliveryId], reject)) {
      return;
    }
    resolve(nil);
  });
}

- (void)submitInAppForm:(NSString *)deliveryId
          responsesJson:(NSString *)responsesJson
                resolve:(RCTPromiseResolveBlock)resolve
                 reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    if (TreebarsRejected([TreebarsBridge submitInAppForm:deliveryId responsesJson:responsesJson], reject)) {
      return;
    }
    resolve(nil);
  });
}

// -----------------------------------------------------------------------------------------
// The notification centre
// -----------------------------------------------------------------------------------------

- (void)notificationsList:(NSString *)optionsJson
                  resolve:(RCTPromiseResolveBlock)resolve
                   reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    [TreebarsBridge notificationsList:optionsJson
                           completion:^(NSString *page, TreebarsBridgeFailure *failure) {
                             TreebarsAnswer(reject, ^{
                               if (TreebarsRejected(failure, reject)) {
                                 return;
                               }
                               resolve(page);
                             });
                           }];
  });
}

- (void)notificationsMarkRead:(NSString *)groupId
                      resolve:(RCTPromiseResolveBlock)resolve
                       reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    [TreebarsBridge notificationsMarkRead:groupId];
    resolve(nil);
  });
}

- (void)notificationsMarkAllRead:(RCTPromiseResolveBlock)resolve
                          reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    [TreebarsBridge notificationsMarkAllRead];
    resolve(nil);
  });
}

- (void)notificationsDismiss:(NSString *)groupId
                     resolve:(RCTPromiseResolveBlock)resolve
                      reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }
    [TreebarsBridge notificationsDismiss:groupId];
    resolve(nil);
  });
}

- (void)setNotificationsSubscribed:(BOOL)subscribed
                           resolve:(RCTPromiseResolveBlock)resolve
                            reject:(RCTPromiseRejectBlock)reject
{
  TreebarsAnswer(reject, ^{
    if (TreebarsRejectedUnstarted(reject)) {
      return;
    }

    NSString *latest = [self noteNotificationsSubscribed:subscribed];

    // Same rule as the renderer, for the same reason: a bell that mounts after a page has
    // already been fetched would otherwise show nothing until the next write.
    if (latest != nil && [self canEmit]) {
      [self emitOnNotificationsChange:latest];
    }
    resolve(nil);
  });
}

/**
 * Deferred deep linking. On iPhone the path arrives through the handoff a Treebars link carries
 * across the App Store (`Handoff.swift` in the iOS SDK), when `deferred_handoff` is on — the App
 * Store itself carries nothing. One React screen subscribes on both platforms, and both answer it.
 *
 * The core delivers on the main thread and catches a throw from us; the guard here is for the emit
 * itself, into a runtime that may have gone.
 */
- (void)setDeferredDeepLinkSubscribed:(BOOL)subscribed
                              resolve:(RCTPromiseResolveBlock)resolve
                               reject:(RCTPromiseRejectBlock)reject
{
  __weak __typeof(self) weakSelf = self;
  if (subscribed) {
    [TreebarsBridge setDeferredDeepLinkSink:^(NSString *path) {
      __typeof(self) strongSelf = weakSelf;
      if ([strongSelf canEmit]) {
        [strongSelf emitOnDeferredDeepLink:path];
      }
    }];
  } else {
    [TreebarsBridge setDeferredDeepLinkSink:nil];
  }
  resolve(nil);
}

// -----------------------------------------------------------------------------------------
// What the core calls back into
// -----------------------------------------------------------------------------------------

/// Takes the slot, superseding whatever held it, and tells JavaScript.
///
/// Called on the main thread, which is where the core invokes a renderer.
- (void)holdPresentation:(NSString *)presentationId
                    json:(NSString *)presentationJson
                     box:(TreebarsPresentation *)presentation
{
  [_lock lock];
  _presentationId = presentationId;
  _presentationJson = presentationJson;
  _presentation = presentation;
  [_lock unlock];

  if ([self canEmit]) {
    [self emitOnInAppPresent:presentationJson];
  }
}

/// The box the id names, or nil once it has been superseded or dismissed.
- (nullable TreebarsPresentation *)presentationFor:(NSString *)presentationId
{
  [_lock lock];
  TreebarsPresentation *presentation =
      (presentationId.length > 0 && [_presentationId isEqualToString:presentationId])
      ? _presentation
      : nil;
  [_lock unlock];
  return presentation;
}

/// The same, and empties the slot — the one operation that ends a presentation.
- (nullable TreebarsPresentation *)takePresentation:(NSString *)presentationId
{
  [_lock lock];
  TreebarsPresentation *presentation = nil;
  if (presentationId.length > 0 && [_presentationId isEqualToString:presentationId]) {
    presentation = _presentation;
    _presentationId = nil;
    _presentationJson = nil;
    _presentation = nil;
  }
  [_lock unlock];
  return presentation;
}

/// What a re-subscribing listener has to be told, or nil when nothing is outstanding.
- (nullable NSString *)outstandingPresentation
{
  [_lock lock];
  NSString *outstanding = _presentationJson;
  [_lock unlock];
  return outstanding;
}

/// Records who is watching and answers with the page they have not seen.
- (nullable NSString *)noteNotificationsSubscribed:(BOOL)subscribed
{
  [_lock lock];
  _notificationsSubscribed = subscribed;
  NSString *latest = subscribed ? _notificationsLatest : nil;
  [_lock unlock];
  return latest;
}

/// Held whether or not anybody is watching; emitted only when somebody is.
- (void)holdNotificationPage:(NSString *)page
{
  [_lock lock];
  _notificationsLatest = page;
  BOOL subscribed = _notificationsSubscribed;
  [_lock unlock];

  if (subscribed && [self canEmit]) {
    [self emitOnNotificationsChange:page];
  }
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
  return std::make_shared<facebook::react::NativeTreebarsSpecJSI>(params);
}

@end
