# Changelog — com.treebars:sdk-android

Every release of the Treebars SDKs carries one version number across Android, iOS, React Native and
the web. Releases before 0.9.0 are not described here.

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
