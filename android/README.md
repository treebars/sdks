# Treebars Android SDK

Events, identity, sessions, in-app messages, push and the notification centre for [Treebars](https://treebars.com).
Android 7.0 (API 24) and later.

## Install

From Maven Central, in your app's `build.gradle.kts`:

```kotlin
dependencies {
    implementation("com.treebars:sdk-android:0.6.0")
}
```

## Use

```kotlin
// Application.onCreate()
Treebars.initialize(
    context = this,
    writeKey = "pk_live_…",
    backendUrl = "https://ingest.treebars.com",
)

Treebars.track("signup_completed", mapOf("plan" to "pro"))
Treebars.identify("user_123", mapOf("email" to "ada@example.com"))
```

Your write key is on the dashboard's Data → Setup page, which shows this snippet with the key filled in.

## Remote config

Values your app reads by key and you change from the dashboard, without a release: a feature flag, a price, a headline.

```kotlin
if (Treebars.getConfig("new_checkout", false)) showNewCheckout()

val headline = Treebars.getConfig("home_headline", "Welcome")
val limit = Treebars.getConfig("upload_limit_mb", 25)
val layout = Treebars.getConfigJson("home_layout") // JSON text or null, to decode with your own decoder
```

The second argument is the fallback: what the read answers until this install holds a value for the key, and whenever
what it holds is a different kind. Pass the value your app uses today, so adding the read changes nothing by itself.
It also says which kind you expect: the kind is read from the fallback, never from what was published, so a flag
somebody set to the text `"false"` does not read as on. A whole-number fallback answers a whole number.

With no fallback to give, name the kind, and the read answers `null` until a value is held:

```kotlin
Treebars.getConfigString("promo_banner")?.let { showBanner(it) }
```

`getConfigBoolean`, `getConfigString`, `getConfigNumber` and `getConfigJson` each work this way, and each also takes a fallback.

- **A read never waits**, and is safe on the main thread. It answers from what the install already holds; the SDK asks
  for the values by itself, when a newer config has been published and when who is asking changes.
- **A key keeps its answer for the session.** The first read of a key fixes it until the session ends, so a screen
  never changes under somebody half-way through. A key not read yet takes the newest values; `activateConfig()`
  applies them to the rest at a moment you can redraw.
- **A first launch starts on your fallbacks**, because its values arrive a moment after the app opens. To start on the
  published values instead, wait for them — two seconds at most by default: `Treebars.configReady()` (a `suspend`
  function).
- **Rules can read what you know about the install.** `Treebars.setConfigAttributes(mapOf("plan" to "pro"))` — the
  whole set each time. Platform, app version, language, country and whether somebody is signed in need nothing from you.
- **Signing out forgets the account's values at once**, before the next ones arrive.
- `onConfigChange { … }` is called when a read may answer differently; it returns the function that stops it.
- `setConfigOverride("new_checkout", true)` answers a key locally while you build. The next launch forgets it.
- **An experiment's variant is reported when your app reads it.** The first read that answers one records
  `experiment_exposed`, and at most once a day after that — so who saw which variant is counted from what your app
  showed, not from what it was sent. An override reports nothing.

A person who opted out is never asked about, and reads answer your fallbacks.

## Documentation

[treebars.com/docs](https://treebars.com/docs)

## License

MIT
