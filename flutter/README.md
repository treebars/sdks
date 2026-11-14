# treebars_flutter_sdk

The Flutter SDK for [Treebars](https://treebars.com): events, identity, sessions, in-app messages, push, the
notification centre and remote config. A plugin over the Treebars iOS and Android SDKs: the native SDKs queue, send,
retry, keep sessions and draw messages, and this package hands your calls to them.

Requires Flutter 3.24 or later, iOS 15.1 or later, and Android API 24 or later.

```bash
flutter pub add treebars_flutter_sdk
```

On iOS, raise the app's target to 15.1 in `ios/Podfile` — a new Flutter app starts lower, and `pod install` refuses the
plugin until it matches:

```ruby
platform :ios, '15.1'
```

```dart
import 'package:treebars_flutter_sdk/treebars_flutter_sdk.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await treebars.init(const TreebarsConfig(
    writeKey: 'pk_live_…',
    backendUrl: 'https://ingest.treebars.com',
  ));
  runApp(const MyApp());
}

await treebars.track('signup_completed', {'plan': 'pro'});
await treebars.identify('user_123', attributes: {'email': 'ada@example.com'});
await treebars.screen('checkout');
await treebars.reset(); // on sign-out
```

Your write key is on the dashboard's Data → Setup page.

Every call returns a `Future`, and calls reach the native SDK in the order you make them: an event tracked right
after `identify()` belongs to the person who just signed in, and one tracked right after `reset()` to nobody. A call
the native SDK refuses throws a `TreebarsException` with a `code`: `bad_config`, `bad_payload`, `not_initialized`
or `unexpected`.

## Push

Register the token your push plugin gives you, with the provider it came from:

```dart
await treebars.requestPushPermission();
await treebars.registerPushToken(token, Platform.isIOS ? PushProvider.apns : PushProvider.fcm);
```

On iOS an APNs token is the device token as hex. Every tap on a Treebars push reaches the SDK by itself — in front,
in the background, or when the tap starts the app. Route a tapped push's link where your app routes the links it is
opened with:

```dart
final stop = treebars.on('pushOpened', (data) {
  final link = (data as Map?)?['link'] as String?;
  if (link != null) router.go(Uri.parse(link).path);
});
```

A tap that started the app is held until you listen. While anything listens, the SDK does not open the link itself;
with nothing listening, it opens it with the system.

If your push plugin hands you a message's data instead, pass it on: `handleRemotePush(data)` answers whether it was a
Treebars push and draws it; `trackNotificationOpened(data)` and `trackNotificationDismissed(data)` report what the
person did with it.

## In-app messages

The native SDK fetches and draws in-app messages itself; there is nothing to render in Dart.

```dart
await treebars.setCurrentContext(['checkout']); // the screen messages can be aimed at
await treebars.holdInApp();                     // keep messages back during a video or a payment
await treebars.releaseInApp();
```

To draw a message in your own widgets, listen for `inAppCampaignSelfHandled`, then report what happened with
`selfHandledShown`, `selfHandledClicked` and `selfHandledDismissed`. `inbox()` lists the messages kept for later.

## App actions

A tap on an in-app message's button, on a push or on one of its buttons can fire a named action with a small JSON
payload, which your app subscribes to by name — before or after `init()`:

```dart
final stop = treebars.onAction('add_to_cart', (action) => cart.add(action.payload['sku'] as String));
treebars.onAction('navigate', (action) => router.go(action.payload['screen'] as String));
```

An action fired before anything subscribed to it waits a few seconds for the first handler that does, so the push tap
that started the app still reaches a handler subscribed from a screen.

## Notification centre

```dart
final page = await treebars.notifications(limit: 20);
print(page.unreadCount);
await treebars.markAllNotificationsRead();

final stop = treebars.onNotificationsChange((page) => setState(() => _page = page));
```

## Remote config

Values your app reads by key and you change from the dashboard, without a release: a feature flag, a price, a
headline.

```dart
if (await treebars.getConfigBoolean('new_checkout', false) ?? false) showNewCheckout();

final headline = await treebars.getConfigString('home_headline', 'Welcome');
final limit = await treebars.getConfigNumber('upload_limit_mb', 25);
final layout = await treebars.getConfigJson('home_layout', {'columns': 2});
```

The fallback is what the read answers until this install holds a value for the key, and whenever what it holds is a
different kind. Pass the value your app uses today, so adding the read changes nothing by itself. With no fallback, a
read answers `null` until a value is held.

- **A read never waits for the network.** It answers from what the install already holds; the SDK asks for new
  values by itself.
- **A key keeps its answer for the session**, so a screen never changes under somebody half-way through.
  `activateConfig()` applies newer values at a moment you can redraw.
- **A first launch starts on your fallbacks.** To start on the published values instead, wait for them — two seconds
  at most by default: `await treebars.configReady()`.
- **Rules can read what you know about the install**: `setConfigAttributes({'plan': 'pro'})`, the whole set each
  time.
- `onConfigChange(() { … })` is called when a read may answer differently.
- `setConfigOverride('new_checkout', true)` answers a key locally while you build. The next launch forgets it.

## Privacy

```dart
await treebars.optOut();                     // nothing is collected until optIn()
await treebars.optIn();
await treebars.setAcquisitionConsent(false); // no install referrer, no Apple ad attribution
await treebars.wipeLocalData();              // forget this device
```

## Documentation

[treebars.com/docs](https://treebars.com/docs)

## License

MIT
