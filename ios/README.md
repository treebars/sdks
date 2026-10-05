# Treebars iOS SDK

Events, identity, sessions, in-app messages, push and the notification centre for [Treebars](https://treebars.com).
iOS 15.1 and later.

## Install

**Swift Package Manager** — in Xcode, File → Add Package Dependencies…, enter `https://github.com/treebars/sdks`,
and add the `TreebarsSDK` library to your app target.

**CocoaPods**

```ruby
pod 'TreebarsSDK'
```


## Use

```swift
import TreebarsSDK

// Once, as early as you can — in application(_:didFinishLaunchingWithOptions:).
Treebars.initialize(writeKey: "pk_live_…", backendURL: URL(string: "https://ingest.treebars.com")!)

Treebars.log("signup_completed", properties: ["plan": "pro"])
Treebars.identify("user_123", attributes: ["email": "ada@example.com"])
```

Your write key is on the dashboard's Data → Setup page, which shows this snippet with the key filled in.

## Documentation

[treebars.com/docs](https://treebars.com/docs)

## License

MIT
