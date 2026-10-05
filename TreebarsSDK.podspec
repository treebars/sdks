require "json"

# The Swift core, as a pod.
#
# The same source is also a Swift package (`Package.swift`), which is what a Swift Package
# Manager integrator uses. This spec is its CocoaPods face, and the one the React Native
# package depends on, since a pod cannot depend on a SwiftPM package.
#
# **One name: the pod, the module and the Swift package's library are all `TreebarsSDK`.** The
# React Native package's own pod is `TreebarsReactNative` for that reason: CocoaPods names
# `Pods/Headers/Public/<name>/`, `Pods/Target Support Files/<name>/` and `lib<name>.a` after
# `s.name`, and on a case-insensitive volume a bridge pod called `TreebarsSdk` would share every
# one of them with this one, last write wins.
#
# 0.3.0 was first published as `TreebarsCore`, which is deprecated in favour of this name.
Pod::Spec.new do |s|
  s.name         = "TreebarsSDK"
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
  s.resource_bundles = { "TreebarsSDK_Privacy" => ["ios/Sources/TreebarsSDK/PrivacyInfo.xcprivacy"] }

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
