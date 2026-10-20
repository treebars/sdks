# Changelog — com.treebars:sdk-android

Every release of the Treebars SDKs carries one version number across Android, iOS, React Native and
the web. Releases before 0.9.0 are not described here.

## 0.12.1

- **A tap that launched the app is held until the app listens, however long its start takes.** 0.12.0 held it only
  until the SDK was initialised, so an app that initialises during its splash screen and listens once its first screen
  is up had the link opened by the system in between. It is now held for the whole launch wait after initialisation.

## 0.12.0

- **Every tap on a Treebars push reaches the SDK, and `TreebarsPush.setOpenListener { open -> … }` receives it** with
  the push's link (`PushOpen.link`), the pressed button, the delivery and the author's data — whether the app was in front,
  in the background or not running. A tap that launched the app is held until a listener is set. With a listener the SDK
  does not open the link itself; without one it opens it with the system, as before.
- **A plain push — one the system draws — now opens the SDK's own `TreebarsPushActivity`** through its `click_action`,
  declared in the SDK's manifest, so its tap is handled exactly as a push the SDK drew. Nothing to add to the app's own
  activities; `trackNotificationOpened` is no longer needed for it, and an open reported twice counts once.
- **A Treebars push that arrives while the app is in front is drawn** when the app passes it to `TreebarsPush.handle`, as
  it already does for rich pushes. `com.treebars.sdk.show_push_in_foreground` set to false under `<application>` turns
  that off.
- **A test sent from the dashboard acts when tapped** — its link opened, its action run — and is never recorded.
- **A screen or an app action from a push brings the app forward** with an action listener set, where it used to stay
  in the background; and a link nothing on the device opens launches the app instead of doing nothing.
- **A message sent from the dashboard to show "Immediately" is drawn the moment it arrives**, over whatever is on screen,
  as a test send already was (`InAppTrigger.onArrival`). The app's messaging service hands the silent push that brings it
  to `TreebarsPush.handle`, as it does every Treebars push.

## 0.11.0

- **App actions: `Treebars.onAction(name) { action -> … }`.** A tap on an in-app message's button, on a push or on one
  of its buttons can now fire a named action with a small JSON payload — `add_to_cart` with `{ sku, qty }` — and the app
  subscribes to it by name, on the main thread. `onAction { … }` subscribes to every action, and both return an
  `AppActionSubscription` to `cancel()`. The handler receives `AppAction(name, payload, source)`.
- **`navigate` is the one name Treebars fires itself**, with `{ screen, props }`: a message's "Open an app screen", a
  push's "Open a screen" and `navigateToScreen` in a message all fire it, beside the click listeners that already
  heard them.
- **A push can carry its own tap action** (`treebars_action`): an app action or a screen, run when the notification
  itself is tapped, before its deep link.
- **An action nothing has subscribed to yet waits a few seconds** for the first handler that does — the push tap that
  started the app reaches the screen that subscribes once it is built.
- **Whether a handler took it is recorded** as the `app_action` event, with `app_action` (the name), `handled`, `source`
  and the message. The payload is never recorded. A preview's actions reach the app and are not recorded.
- **The in-app bridge is version 3**: `treebars.appAction(name, payload)`, for a message's own script. A name that is
  not lower-case letters, digits, dots and underscores, or a payload over 4 KB, is refused by name.

Nothing an app already calls has changed: `setClickActionListener` and the push listener still hear every tap they did,
and an app action as well, with the name under `app_action` among its values.

## 0.10.1

- **`Treebars.holdInApp()` now holds a message that was already waiting out its display delay.** A message whose
  trigger fired before the hold, and whose delay ended while the app held the screen, was drawn over whatever the app
  was holding it for. It now waits, unspent, and is drawn after `releaseInApp()`.
- **`Treebars.holdInApp()` now holds a message that was already on its way to the screen.** A hold that began after a
  message was chosen and before it was drawn — while an HTML message's files were being fetched, say — did not stop it,
  and the message was drawn over whatever the app was holding the screen for. The hold is now asked again as the
  message is drawn: nothing is drawn or spent, and the message is drawn after `releaseInApp()`.

## 0.10.0

- **An HTML in-app message draws itself, and the SDK paints nothing behind it.** No dimmed backdrop, no white box
  and no rounded corners of the SDK's own. A modal, a sheet, a full-screen message or a canvas is a transparent
  WebView over the whole window — edge to edge under the status and navigation bars and through the display cutout,
  on every Android version from 7.0 — and the message draws its own scrim, card, corners and shadow, so a rounded card
  has nothing square behind its corners. A banner or a nudge is a transparent WebView at its edge, and a touch outside
  the message's own box, in the room it leaves for its shadow, reaches the app — TalkBack's explore-by-touch too.
- **The message is told the screen it is on, and told again when it changes.** The insets of the bars and the cutout,
  the keyboard's height (and, from Android 11, how long it takes to move), which way the device is held, light or dark,
  and the system's font scale reach the page when it is drawn and on every change, so a field stays above the keyboard.
  The WebView no longer resizes for the keyboard and draws text at 100%: the page moves and scales itself.
- **Back goes back a screen first.** In a message with several screens Back returns to the one before; on the first, a
  message that can be dismissed closes. A banner's and a nudge's Back is still the app's.
- **The message's own entrance replaces the SDK's.** A message is shown once it has laid itself out; until then every
  touch and Back is the app's. The status bar's icons follow the message when it asks for light or dark, and the
  app's otherwise.

In-app messages made with Treebars' in-app builder need this version; earlier versions do not receive them. Nothing
an app calls has changed.

## 0.9.0

- **Links that carry values open the app on the right screen.** A link can carry up to six values after
  its key — `https://links.example.com/spring/u_123/p_9` — and `handleLink` now asks the link host about
  the whole address, so `onPath` receives the link's deep-link path with those values filled in. Before,
  only a link's bare key was asked about, and an App Link with values opened the app on its home screen.
- **A link that only goes to a website opens the website.** When a link set to go to a website opens
  the app — because the app claims the link's domain — `handleLink` opens that website in the browser and
  calls `onPath` with null. Only an `https` address is opened, and never one on the app's own
  `linkHosts`, which would open the app again. No `link_opened` is sent for it.
- **`link_opened` names only the link, not its values.** On one of the app's `linkHosts`, `open_url`
  carries the link's key (`https://links.example.com/spring`) and never the values after it, which can
  be a person's own identifier.

Nothing an app calls has changed.
