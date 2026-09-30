require "json"

# The Swift core, as a pod.
#
# The same source is also a Swift package (`Package.swift`), which is what a Swift Package
# Manager integrator uses. This spec is its CocoaPods face, and the one the React Native
# package depends on, since a pod cannot depend on a SwiftPM package.
#
# **The name is `TreebarsCore` and the module is `TreebarsSDK`, and that split is not
# cosmetic.** CocoaPods derives `Pods/Headers/Public/<name>/`, `Pods/Target Support Files/<name>/`
# and `lib<name>.a` from `s.name`, while the Swift module an importer names comes from
# `s.module_name`. A pod actually called `TreebarsSDK` would collide with the existing
# `TreebarsSdk` — the React Native package — on a default case-insensitive APFS volume: one
# xcconfig file, one static library, one header directory, last write wins. The symptom is not
# a clean `pod install` error; it is one pod's header search paths and linker flags silently
# overwriting the other's.
#
# So `import TreebarsSDK` keeps working, in this package's own tests and in a host app, and
# nothing on disk collides.
Pod::Spec.new do |s|
  s.name         = "TreebarsCore"
  s.module_name  = "TreebarsSDK"
  # Pinned to the same value the generated constants carry, so a core and a wrapper cannot
  # disagree about which SDK they are. `sdks/android`'s Gradle coordinate uses the same one.
  s.version      = "0.3.0"
  s.summary      = "The Treebars iOS SDK core"
  s.description  = "Events, sessions, the queue, in-app messages and the notification centre."
  s.homepage     = "https://treebars.com"
  s.license      = { :type => "MIT", :file => "LICENSE" }
  s.authors      = { "Treebars" => "accounts@treebars.com" }
  s.platforms    = { :ios => "15.1" }
  # The spec sits at the root of github.com/treebars/sdks, beside `Package.swift`, because a pod fetched
  # from git resolves every path below against the repository's root.
  s.source       = { :git => "https://github.com/treebars/sdks.git", :tag => "#{s.version}" }

  s.swift_version = "5.10"
  s.source_files  = "ios/Sources/TreebarsSDK/**/*.swift"

  # The privacy manifest, in a bundle of its own: a resource bundle is what a static framework can
  # carry into the app, and Xcode reads every bundle's `PrivacyInfo.xcprivacy` into the app's
  # privacy report. The same file SwiftPM ships (`Package.swift`), so the two faces cannot disagree.
  s.resource_bundles = { "TreebarsCore_Privacy" => ["ios/Sources/TreebarsSDK/PrivacyInfo.xcprivacy"] }

  # Every framework this target imports unconditionally. UIKit is behind `#if canImport`, and
  # is listed anyway because the iOS build always has it and a missing weak link is a launch
  # crash rather than a compile error.
  #
  # **`Compression` is deliberately absent.** `Compressor.swift` does `import Compression`, so
  # listing it looks obviously right — and it fails the LINK, not the compile:
  # `ld: framework 'Compression' not found`. It is a Clang module in the SDK backed by libSystem
  # rather than a framework on disk, so it imports without being linked and cannot be linked by
  # name. The error would surface at the app's final link step, naming the app rather than this file.
  # WebKit and StoreKit for the HTML in-app host: the WKWebView a markup body is drawn in, and the
  # store review a message may ask for.
  s.frameworks = "Foundation", "Security", "Network", "UIKit", "UserNotifications", "WebKit", "StoreKit"

  # Swift in a pod that a static-library host links: without this, CocoaPods builds it as a
  # dynamic framework and the host has to embed it. `use_frameworks!` in the app's Podfile
  # overrides this, which is the case worth knowing about if the linkage ever changes.
  s.static_framework = true
end
