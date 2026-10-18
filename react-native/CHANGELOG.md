# Changelog — @treebars/react-native-sdk

Every release of the Treebars SDKs carries one version number across Android, iOS, React Native and
the web, and this package runs the Android and iOS SDKs of the same version. Releases before 0.9.0 are
not described here.

## 0.10.1

Requires `com.treebars:sdk-android` and the `TreebarsSDK` pod at 0.10.1, which this package names.

- **`holdInApp()` now holds a message that was already waiting out its display delay**, on Android and iOS alike. A
  message whose delay ended while the app held the screen was drawn over whatever the app was holding it for. It now
  waits, unspent, and is drawn after `releaseInApp()`.
- **`holdInApp()` now holds a message that was already on its way to the screen**, on Android and iOS alike. A hold
  that began after a message was chosen and before it was drawn — while an HTML message's files were being fetched,
  say — did not stop it, and the message was drawn over whatever the app was holding the screen for. It is now drawn
  after `releaseInApp()`, and nothing is spent meanwhile.

## 0.10.0

Requires `com.treebars:sdk-android` and the `TreebarsSDK` pod at 0.10.0, which this package names.

- **An HTML in-app message draws itself, and the SDK paints nothing behind it** — no dimmed backdrop, no white box,
  no rounded corners of its own. A message that covers the screen is a transparent WebView over the whole window,
  under the bars and through the cutout; a banner or a nudge is one at its edge, and a touch outside the message's
  own box reaches the app.
- **The message is told the screen it is on** — the insets, the keyboard, which way the device is held, light or
  dark, the text size — and told again when it changes, so a field stays above the keyboard and a full-screen message
  clear of the notch.
- **Android's Back goes back a screen first**, and closes a message that can be dismissed only from its first.

In-app messages made with Treebars' in-app builder need this version; earlier versions do not receive them. Nothing
an app calls has changed.

## 0.9.0

Requires `com.treebars:sdk-android` and the `TreebarsSDK` pod at 0.9.0, which this package names.

- **Links that carry values open the app on the right screen.** A link can carry up to six values after
  its key — `https://links.example.com/spring/u_123/p_9` — and `handleLink` now resolves with the link's
  deep-link path with those values filled in. Before, a Universal Link or App Link with values resolved
  with null.
- **A link that only goes to a website opens the website.** When a link set to go to a website opens
  the app — because the app claims the link's domain — `handleLink` opens that website in the browser and
  resolves with null. Only an `https` address is opened, and never one on the app's own `linkHosts`. No
  `link_opened` is sent for it.
- **`link_opened` names only the link, not its values.** On one of the app's `linkHosts`, `open_url`
  carries the link's key and never the values after it.

Nothing an app calls has changed.
