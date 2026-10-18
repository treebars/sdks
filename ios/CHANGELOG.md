# Changelog — TreebarsSDK (iOS)

Every release of the Treebars SDKs carries one version number across Android, iOS, React Native and
the web. Releases before 0.9.0 are not described here.

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
