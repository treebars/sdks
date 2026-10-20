# @treebars/react-native-sdk

The React Native SDK for [Treebars](https://treebars.com): events, identity, sessions, in-app messages, push, the
notification centre and remote config. A TurboModule over the Treebars iOS and Android SDKs, for React Native 0.76 and later with the
New Architecture.

```bash
npm install @treebars/react-native-sdk
cd ios && pod install
```

```ts
import treebars from '@treebars/react-native-sdk';

await treebars.init({ write_key: 'pk_live_…' });

await treebars.track('signup_completed', { plan: 'pro' });
await treebars.identify('user_123', { email: 'ada@example.com' });
```

Your write key is on the dashboard's Data → Setup page, which shows this snippet with the key filled in.

## Push taps

Every tap on a Treebars push reaches the SDK by itself — in front, in the background, or when the tap starts the app —
with nothing native to write on iOS or Android. Route a tapped push's link where your app routes the links it is opened
with, and the push lands on the same screen a link does. With React Navigation:

```ts
const linking = {
  prefixes: ['yourapp://'],
  subscribe(listener: (url: string) => void) {
    const links = Linking.addEventListener('url', ({ url }) => listener(url));
    const pushes = treebars.onPushOpened(({ link }) => link && listener(link));
    return () => { links.remove(); pushes(); };
  },
};
```

A tap that started the app is held until you listen. While anything listens, the SDK does not open the link itself;
with nothing listening, it opens it with the system. A Treebars push that arrives while the app is open is shown.

## App actions

A tap on an in-app message's button, on a push or on one of its buttons can fire a named action with a small JSON
payload, which your app subscribes to by name — before or after `init()`:

```ts
const stop = treebars.onAction('add_to_cart', ({ payload }) => cart.add(payload.sku as string));
treebars.onAction('navigate', ({ payload }) => navigation.navigate(payload.screen as string)); // "Open an app screen"
```

A name is lower-case letters, digits, dots and underscores. An action fired before anything subscribed to it waits a
few seconds for the first handler that does — so the push tap that started the app reaches a handler subscribed from a screen's effect. Each action is recorded as the `app_action` event with
whether a handler took it — never its payload — so the dashboard can show a button that found nothing listening.

## Remote config

Values your app reads by key and you change from the dashboard, without a release: a feature flag, a price, a headline.

```ts
await treebars.init({ write_key: 'pk_live_…' });

if (treebars.getConfig('new_checkout', false)) showNewCheckout();

const headline = treebars.getConfig('home_headline', 'Welcome');
const limit = treebars.getConfig('upload_limit_mb', 25);
const layout = treebars.getConfig('home_layout', { columns: 2 });
```

The fallback is what the read answers until this install holds a value for the key, and whenever what it holds is a
different kind. Pass the value your app uses today, so adding the read changes nothing by itself. It also says which
kind you expect: the kind is read from the fallback, never from what was published, so a flag somebody set to the text
`"false"` does not read as on.

With no fallback to give, name the kind, and the read answers `null` until a value is held:

```ts
const banner = treebars.getConfigString('promo_banner'); // string | null
```

`getConfigBoolean`, `getConfigString`, `getConfigNumber` and `getConfigJson` each work this way, and each also takes a fallback.

- **A read never waits.** It is synchronous and answers from what the install already holds; the SDK asks for the
  values by itself, when a newer config has been published and when who is asking changes.
- **Read after `init()` has resolved.** `init()` is asynchronous here, and a read made before it resolves answers the
  fallback. Await `init()`, or `configReady()`, before the first screen that reads.
- **A key keeps its answer for the session.** The first read of a key fixes it until the session ends, so a screen
  never changes under somebody half-way through. A key not read yet takes the newest values; `activateConfig()`
  applies them to the rest at a moment you can redraw.
- **A first launch starts on your fallbacks**, because its values arrive a moment after the app opens. To start on the
  published values instead, wait for them — two seconds at most by default: `await treebars.configReady()`.
- **Rules can read what you know about the install.** `treebars.setConfigAttributes({ plan: 'pro' })` — the whole set
  each time. Platform, app version, language, country and whether somebody is signed in need nothing from you.
- **Signing out forgets the account's values at once**, before the next ones arrive.
- `onConfigChange(() => { … })` is called when a read may answer differently; it returns the function that stops it.
- `await treebars.setConfigOverride('new_checkout', true)` answers a key locally while you build. The next launch
  forgets it.
- **An experiment's variant is reported when your app reads it.** The first read that answers one records
  `experiment_exposed`, and at most once a day after that — so who saw which variant is counted from what your app
  showed, not from what it was sent. An override reports nothing.

A person who opted out is never asked about, and reads answer your fallbacks.

## Documentation

[treebars.com/docs](https://treebars.com/docs)

## License

MIT
