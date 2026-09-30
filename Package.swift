// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TreebarsSDK",
    // macOS is declared so `swift build` runs on a host with no simulator — but that is a smoke
    // check, not a real build of the SDK. Every UIKit path in this target sits behind
    // `#if canImport(UIKit)`, which is false on macOS, so a plain `swift build` compiles the
    // `#else` branch — os_name "macOS", device_type "desktop", no screen metrics, no lifecycle
    // observer — and would succeed with a syntax error in the shipping code. Build and test with
    // `xcodebuild` against an iOS destination. What actually pins this to Apple platforms rather
    // than Linux is `import Security` and `import Compression`, not UIKit.
    // Both minimums are set high enough for Swift structured concurrency.
    //
    // iOS 15.1 is the same minimum both podspecs declare (`TreebarsCore.podspec` and the React
    // Native package's), so Swift Package Manager and CocoaPods integrators build against one
    // floor. The sources use iOS 15 APIs unguarded, such as `Handoff.swift`'s
    // `NotificationCenter.notifications(named:)`, the async sequence that waits for the app to
    // become active.
    platforms: [.iOS("15.1"), .macOS(.v12)],
    products: [
        .library(name: "TreebarsSDK", targets: ["TreebarsSDK"]),
    ],
    targets: [
        // The privacy manifest is a resource, so SwiftPM ships it in the SDK's bundle for Xcode to
        // fold into the app's privacy report. Without one the App Store refuses an app whose SDKs
        // read UserDefaults and do not say why (ITMS-91053).
        .target(
            name: "TreebarsSDK",
            path: "ios/Sources/TreebarsSDK",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "TreebarsSDKTests",
            dependencies: ["TreebarsSDK"],
            path: "ios/Tests/TreebarsSDKTests",
            // The shared fixtures in `Fixtures/` are read from `#filePath`, as the other shared scenarios are,
            // rather than bundled: excluded so SwiftPM does not ask what they are.
            exclude: ["Fixtures"]
        ),
    ]
)
