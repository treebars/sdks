# Treebars Android SDK

Events, identity, sessions, in-app messages, push and the notification centre for [Treebars](https://treebars.com).
Android 7.0 (API 24) and later.

## Install

From Maven Central, in your app's `build.gradle.kts`:

```kotlin
dependencies {
    implementation("com.treebars:sdk-android:0.4.0")
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

## Documentation

[treebars.com/docs](https://treebars.com/docs)

## License

MIT
