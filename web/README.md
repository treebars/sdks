# @treebars/web-sdk

The browser SDK for [Treebars](https://treebars.com): events, identity, in-app messages, web push and remote config.

```bash
npm install @treebars/web-sdk
```

```ts
import treebars from '@treebars/web-sdk';

treebars.init({ writeKey: 'pk_live_…' });

treebars.track('signup_completed', { plan: 'pro' });
treebars.identify('user_123', { email: 'ada@example.com' });
```

Your write key is on the dashboard's Data → Setup page, which also shows this snippet with the key filled in.

## What a property can hold

Text, a number, true or false, a list, or an object:

```ts
treebars.track('purchase', {
  value: 129,
  gift: true,
  tags: ['new', 'sale'],
  delivery: { method: 'express' },
  line_items: [
    { category: 'shoes', qty: 1 },
    { category: 'bags', qty: 2 },
  ],
});
```

- An object is read by its path: `delivery.method`.
- A list is asked which items it holds — contains any of, all of, or none of. Its items are compared as text, exactly
  and by case, and a list keeps its first hundred different items.
- A list of objects is one list per field: `line_items.category` holds `shoes` and `bags`. The fields of one item are
  not kept together.
- A key you send with a dot in it, `{ 'delivery.method': 'express' }`, is read as that same path.

## When events are uploaded

An event is uploaded about a second after it happens, and a burst inside that second is one upload. A page that keeps
producing events is held to one upload every few seconds — a spacing Treebars names in its answer to each upload, so
it can be tuned for your project without a release — and to one a second under a `pk_test_` key, so what you do while
integrating shows up as you do it. A browser asked to save data keeps thirty seconds between uploads.

- `flushIntervalMs` sets that spacing yourself: the least time between two uploads while the page is busy. It is not
  a timer, and the first event after a quiet spell still goes a second after it happens.
- A full batch (`batchSize`, 50 by default), the upload as the page is hidden, a `flush()` you call and an event a
  live campaign or journey is waiting on never wait for the spacing.
- What could not be sent — the network was down, the server said to wait — is kept in the browser and sent when the
  wait is over, when the network comes back, or on the next page load.
- `appName` is what `app_open`, `app_foreground` and `app_background` carry as `name`, so a list of events says which
  app each is about. It defaults to the page's hostname.
- `app_background` is recorded once the page has stayed hidden for two seconds, with the time it was hidden, and
  `app_foreground` when it is shown again after that. A page hidden and shown again sooner — a glance at another tab —
  records neither.

## One device across your subdomains

A browser's storage belongs to one origin, so on its own `example.com` and `app.example.com` would each mint a device,
and one visitor in one browser would be two anonymous people. By default the SDK also keeps the device in a
first-party cookie on the parent domain, and every subdomain running the SDK adopts the device it finds there — so
somebody who reads your site and then opens your app is one person, before they sign in as well as after.

- **The cookie** is `tbrs_dv_live`, or `tbrs_dv_test` under a `pk_test_` key, so a staging site never shares a device
  with the production site beside it. It holds the device id and the device's secret, lasts 400 days from the last
  visit, and is `SameSite=Lax`, and `Secure` on https. It is set on the widest domain the browser allows:
  `example.com` for `app.example.com`, `example.co.uk` for `shop.example.co.uk`. If your site lists its cookies, add
  this one. To find that domain the SDK sets a cookie named `tbrs_probe_…` and removes it in the same step; it holds
  nothing and does not outlive the call.
- **Who can read it.** As with any cookie a page sets: scripts on every subdomain of that domain, which can also
  replace it, and those subdomains' servers. The secret is what a browser proves itself with when it reads its in-app
  messages and notifications, so turn sharing off when the parent domain is shared with sites you do not control:

  ```ts
  treebars.init({ writeKey: 'pk_live_…', shareAcrossSubdomains: false });
  ```

  The device then lives in that origin's storage alone, and a cookie another subdomain set is neither read nor removed.
- **It follows the SDK's other storage rules.** It is neither set nor read with `disableStorage: true` or after
  `optOut()`, and `wipeLocalData()` replaces the device in it with a new one.
- **An origin that already had a device** moves to the shared one on its next load, and a person signed in there is
  signed in again on it.
- **Unrelated domains are not joined.** `example.com` and `example.org` stay two devices; calling `identify()` with
  the same user id on both is what makes them one person's.

## In-app messages

A page that calls `init` shows its in-app messages; there is nothing else to call. The SDK asks for the messages
waiting for this browser and draws them itself, in a shadow root, so your page's styles and the message's never meet.

- **When it asks.** As a session starts, when the tab comes back after being hidden, and as a page opens. A visitor
  reading through a site of many pages asks at most once in thirty seconds; a reload always asks.
  `syncInAppMessages()` asks now.
- **When a message shows.** On the event it was set to wait for. One that arrives as the page opens — you published
  it since their last page — is shown on that page, provided the answer is back within ten seconds. Later than that,
  it waits for the next page rather than appear over somebody who is already reading. A page opened in a background
  tab opens, for this, when it is first looked at.
- **To switch it off,** pass `inAppEnabled: false` to `init`. No message is fetched and none is drawn.
- **To draw messages yourself,** hand `setInAppRenderer` a function. It is given each message in place of the SDK's
  renderer. `setInAppRenderer(null)` draws nothing and keeps fetching, for a page that only reads `inbox`. Call it
  before `init` or in the same script as `init` — the first message of a page is drawn once that script has run, so
  either order works. The same goes for `onsite.getSelfHandledOSM`.
- **What your project is told.** The browser's `device_context` event says which of these the page does, as
  `in_app_display`: `sdk` when the SDK draws, `app` when your own renderer does, and `off` when nothing will be drawn —
  `inAppEnabled: false`, or `setInAppRenderer(null)`. So a project can see that a site has messages switched off,
  rather than wonder why nobody saw one. It is never reported from inside `init`, so a renderer set in the same
  script is the answer given; after that it is reported again only when the answer changes and stays changed for a
  couple of seconds, so registering your renderer on every render reports nothing new.
- **A strict Content-Security-Policy.** An HTML message runs in a sandboxed frame. Where your policy refuses inline
  scripts, the SDK draws it in a frame served by Treebars instead, which your policy allows with one line:

  ```
  Content-Security-Policy: frame-src https://frame.treebars.com
  ```

  A site that allows no outside frame shows no HTML message, and the campaign's report says its frame was blocked.

## App actions

A button in an in-app message can fire a named action with a small JSON payload, which your page subscribes to by name:

```ts
const stop = treebars.onAction('add_to_cart', ({ payload }) => cart.add(payload.sku, payload.qty));
treebars.onAction('navigate', ({ payload }) => router.push(payload.screen)); // "Open an app screen"
treebars.onAction((action) => console.log(action.name, action.payload, action.source)); // every action
```

A name is lower-case letters, digits, dots and underscores. An action fired before anything subscribed to it waits a
few seconds for the first handler that does. Each action is recorded as the `app_action` event with
whether a handler took it — never its payload — so the dashboard can show a button that found nothing listening.

## Web push

Serve `treebars-sw.js` from this package at your site's root (`https://yoursite.com/treebars-sw.js`), or
`importScripts('/treebars-sw.js')` from a service worker you already have. It only draws pushes that carry a
Treebars payload, so it leaves any other push your site sends alone.

## Remote config

Values your page reads by key and you change from the dashboard, without a deploy: a feature flag, a price, a headline.

```ts
if (treebars.getConfig('new_checkout', false)) showNewCheckout();

const headline = treebars.getConfig('home_headline', 'Welcome');
const limit = treebars.getConfig('upload_limit_mb', 25);
const layout = treebars.getConfig('home_layout', { columns: 2 });
```

The second argument is the fallback: what the read answers until this browser holds a value for the key, and whenever
what it holds is a different kind. Pass the value your page uses today, so adding the read changes nothing by itself.
It also says which kind you expect: the kind is read from the fallback, never from what was published, so a flag
somebody set to the text `"false"` does not read as on.

With no fallback to give, name the kind, and the read answers `null` until a value is held:

```ts
const banner = treebars.getConfigString('promo_banner'); // string | null
```

`getConfigBoolean`, `getConfigString`, `getConfigNumber` and `getConfigJson` each work this way, and each also takes a fallback.

- **A read never waits.** It answers from what the browser already holds. The SDK asks for the values by itself, when
  a newer config has been published and when who is asking changes.
- **A key keeps its answer for the session.** The first read of a key fixes it until the session ends, so a page never
  changes under somebody half-way through. A key not read yet takes the newest values; `activateConfig()` applies them
  to the rest at a moment you can redraw.
- **A first visit starts on your fallbacks**, because its values arrive a moment after the page opens. To start on the
  published values instead, wait for them — two seconds at most by default:

  ```ts
  await treebars.configReady();
  render();
  ```

- **Rules can read what you know about the visitor.** `treebars.setConfigAttributes({ plan: 'pro', seats: 5 })` — the
  whole set each time. Platform, language, country and whether somebody is signed in need nothing from you.
- **Signing out forgets the account's values at once**, before the next ones arrive.
- `onConfigChange(callback)` is called when a read may answer differently; it returns the function that stops it.
- `setConfigOverride('new_checkout', true)` answers a key locally while you build. A reload forgets it.
- **An experiment's variant is reported when your app reads it.** The first read that answers one records
  `experiment_exposed`, and at most once a day after that — so who saw which variant is counted from what your app
  showed, not from what it was sent. An override reports nothing.

A visitor who opted out is never asked about, and reads answer your fallbacks.

## Documentation

[treebars.com/docs](https://treebars.com/docs)

## License

MIT
