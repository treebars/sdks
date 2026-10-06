# @treebars/web-sdk

The browser SDK for [Treebars](https://treebars.com): events, identity, in-app messages and web push.

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

## Web push

Serve `treebars-sw.js` from this package at your site's root (`https://yoursite.com/treebars-sw.js`), or
`importScripts('/treebars-sw.js')` from a service worker you already have. It only draws pushes that carry a
Treebars payload, so it leaves any other push your site sends alone.

## Documentation

[treebars.com/docs](https://treebars.com/docs)

## License

MIT
