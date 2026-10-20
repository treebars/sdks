# Changelog — TreebarsSDK (iOS)

Every release of the Treebars SDKs carries one version number across Android, iOS, React Native and
the web. Releases before 0.9.0 are not described here.

## 0.12.0

- **Every tap on a Treebars push reaches the SDK, with no delegate code in the app.** The SDK stands in front of whatever
  notification delegate the app or a notification library sets, answers its own pushes, and passes every other
  notification through unchanged. `TreebarsHandlesPushTaps` set to NO in Info.plist turns that off, for an app that
  forwards responses to `handleNotificationResponse` itself.
- **`Treebars.onPushOpened { open in … }`** receives every tap with the push's link (`PushOpen.link`), the pressed
  button, the delivery and the author's data, in every state of the app. A tap that launched the app is held until a
  handler is set. With a handler the SDK does not open the link itself; without one it opens it with the system.
- **A Treebars push that arrives while the app is in front is shown as a banner.** `TreebarsShowsPushInForeground` set to
  NO in Info.plist leaves that to the app's own delegate.
- **A test sent from the dashboard acts when tapped** and is never recorded; an open reported twice counts once.
- `installPushTaps()` puts the SDK in front of the delegate before `initialize`, for an app that initialises late.
- **A message sent from the dashboard to show "Immediately" is drawn the moment it arrives**, over whatever is on screen,
  as a test send already was (`InAppTrigger.on_arrival`).
- **The silent push that tells the SDK a message is waiting reaches it with no app code**: the SDK answers it on the app
  delegate and passes every other remote notification to what was there before. A test or an "Immediately" message now
  appears on an open app within seconds, where an app that did not forward the push saw it only after a relaunch.

## 0.11.0

- **App actions: `Treebars.onAction("add_to_cart") { action in … }`.** A tap on an in-app message's button, on a push or
  on one of its buttons can now fire a named action with a small JSON payload, and the app subscribes to it by name, on
  the main actor. `Treebars.onAction { … }` subscribes to every action, and both return an `AppActionSubscription` to
  `cancel()`. The handler receives an `AppAction` with `name`, `payload` and `source`.
- **`navigate` is the one name Treebars fires itself**, with `["screen": …, "props": …]`: a message's "Open an app
  screen", a push's "Open a screen" and `navigateToScreen` in a message all fire it, beside the delegate calls that
  already heard them.
- **A push can carry its own tap action** (`treebars_action`): an app action or a screen, run when the notification
  itself is tapped, before its deep link.
- **An action nothing has subscribed to yet waits a few seconds** for the first handler that does — the push tap that
  launched the app reaches the screen that subscribes once it is built.
- **Whether a handler took it is recorded** as the `app_action` event, with `app_action` (the name), `handled`, `source`
  and the message. The payload is never recorded. A preview's actions reach the app and are not recorded.
- **The in-app bridge is version 3**: `treebars.appAction(name, payload)`, for a message's own script. A name that is
  not lower-case letters, digits, dots and underscores, or a payload over 4 KB, is refused by name.

Nothing an app already calls has changed: the in-app delegate and the push handler still hear every tap they did, and
an app action as well, with the name under `app_action` among its values.

## 0.10.1

- **`holdInApp()` now holds a message that was already waiting out its display delay.** A message whose trigger
  fired before the hold, and whose delay ended while the app held the screen, was drawn over whatever the app was
  holding it for. It now waits, unspent, and is drawn after `releaseInApp()`.
- **`holdInApp()` now holds a message that was already on its way to the screen.** A hold that began after a message
  was chosen and before it was drawn — while an HTML message's files were being fetched, say — did not stop it, and the
  message was drawn over whatever the app was holding the screen for. The hold is now asked again as the message is
  drawn: nothing is drawn or spent, and the message is drawn after `releaseInApp()`.
- **A delayed in-app message that cannot be drawn when its turn comes now waits, rather than being lost.** One whose
  draw found the app held, or no longer active, was let go without being shown or reported, until its trigger fired
  again. It now waits, unspent, and is drawn once it can be.

## 0.10.0

- **An HTML in-app message draws itself, and the SDK paints nothing behind it.** No dimmed backdrop, no white box
  and no rounded corners of the SDK's own. A modal, a sheet, a full-screen message or a canvas is a transparent
  WebView over the whole window, under the status bar and the home indicator, and the message draws its own scrim,
  card, corners and shadow — so a rounded card has nothing square behind its corners, and its shadow is never
  clipped. A banner or a nudge is a transparent WebView at its edge, and a touch outside the message's own box — in
  the room it leaves for its shadow — reaches the app.
- **The message is told the screen it is on, and told again when it changes.** The safe-area insets, the keyboard's
  height and how long it takes to move, which way the device is held, light or dark, and the text size (the body
  style's size against its default) reach the page when it is drawn and on every change — a rotation, a split view,
  the keyboard coming up — so a full-screen message stays clear of the Dynamic Island and a field stays above the
  keyboard. A floating or split iPad keyboard covers nothing the page needs to move for.
- **The page itself no longer scrolls; the message's screens do.** WebKit revealing a focused field no longer slides
  the whole message up.
- **The message's own entrance replaces the SDK's fade.** A message is shown once it has laid itself out.
- **VoiceOver stays inside a message that covers the screen, and the escape gesture closes one that can be
  dismissed.** The status bar's text follows the message when it asks for light or dark, and the app's otherwise.

In-app messages made with Treebars' in-app builder need this version; earlier versions do not receive them. Nothing
an app calls has changed.

## 0.9.0

- **Links that carry values open the app on the right screen.** A link can carry up to six values after
  its key — `https://links.example.com/spring/u_123/p_9` — and `handleLink` now asks the link host about
  the whole address, so `completion` receives the link's deep-link path with those values filled in.
  Before, only a link's bare key was asked about, and a Universal Link with values opened the app on its
  home screen.
- **A link that only goes to a website opens the website.** When a link set to go to a website opens
  the app — because the app claims the link's domain — `handleLink` opens that website in the browser and
  calls `completion` with nil. Only an `https` address is opened, and never one on the app's own
  `linkHosts`, which would open the app again. No `link_opened` is sent for it.
- **`link_opened` names only the link, not its values.** On one of the app's `linkHosts`, `open_url`
  carries the link's key (`https://links.example.com/spring`) and never the values after it, which can
  be a person's own identifier.

Nothing an app calls has changed.
