# Changelog — @treebars/web-sdk

Every release of the Treebars SDKs carries one version number across Android, iOS, React Native and
the web. Releases before 0.9.0 are not described here.

## 0.12.1

- No change of its own: released beside the other three, which share one version.

## 0.12.0

- No change of its own: released beside the other three, which share one version. A message sent to show
  "Immediately" shows at the next page or event, as before — nothing can wake a browser tab.

## 0.11.0

- **App actions: `treebars.onAction(name, handler)`.** A button in an in-app message can now fire a named action with a
  small JSON payload — `add_to_cart` with `{ sku, qty }` — and the page subscribes to it by name. `onAction(handler)`
  subscribes to every action, and both return a function that unsubscribes. The handler receives
  `{ name, payload, source }`, where `source` names the message.
- **`navigate` is the one name Treebars fires itself**, with `{ screen, props }`, for a message's "Open an app screen".
  `navigateToScreen` in a message now fires it too.
- **An action nothing has subscribed to yet waits a few seconds** for the first handler that does, so subscribing after
  the first message is drawn is not too late.
- **Whether a handler took it is recorded** as the `app_action` event, with `app_action` (the name), `handled`, `source`
  and the message. The payload is never recorded. A preview's actions reach the page and are not recorded.
- **The in-app bridge is version 3**: `treebars.appAction(name, payload)`, for a message's own script. A name that is
  not lower-case letters, digits, dots and underscores, or a payload over 4 KB, is refused by name.

Nothing a page already calls has changed. A message's `custom` button still reaches `TREEBARS_ONSITE_MESSAGE_CLICKED`
as before, and on a page with an earlier version an app action button does too, with the name and payload as keys.

## 0.10.1

- **`holdInApp()` now holds a message that was already waiting for its moment** — a delay, a scroll depth or the
  pointer leaving. A message whose moment came while the page held the screen was drawn over whatever the page was
  holding it for. It now waits, unspent, and is drawn after `releaseInApp()`.

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
