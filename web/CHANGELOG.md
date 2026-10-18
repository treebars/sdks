# Changelog — @treebars/web-sdk

Every release of the Treebars SDKs carries one version number across Android, iOS, React Native and
the web. Releases before 0.9.0 are not described here.

## 0.10.0

- **An HTML in-app message draws itself, and the SDK paints nothing around it.** No backdrop, no white box, no
  rounded corners and no shadow of the SDK's own. A modal, a sheet, a full-screen message or a canvas is a transparent
  frame over the whole window — on a touch device, over the visual viewport, so an on-screen keyboard shrinks it — and
  the message draws its own scrim, card, corners and shadow. A banner or a nudge is a transparent frame at its edge.
- **The message is told the screen it is on.** The safe-area insets, read in the page because a frame's own
  `env(safe-area-inset-*)` is always zero, which way the window is held and the browser's light or dark scheme reach
  the message when it is drawn and again when the window changes — through the Treebars frame on a site with a strict
  Content-Security-Policy too.
- **No opaque backdrop on a dark site.** The frame and the message's own document both say `color-scheme: normal`,
  so a browser no longer paints a white sheet behind a message on a page whose colour scheme differs.
- **The message's own entrance.** A message is shown once it has laid itself out.

In-app messages made with Treebars' in-app builder need this version; earlier versions do not receive them. Nothing
a page calls has changed.

## 0.9.0

No change in the browser. 0.9.0 is a release of the Android and iOS SDKs — links that carry values,
and links that only go to a website — and the web SDK takes the same number so the four stay in step.
