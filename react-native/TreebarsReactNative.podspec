require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

# The iOS half of the Treebars SDK.
#
# The CLI only globs the package root for a podspec, so this file cannot move into ios/.
# The pod name is distinct from RNDeviceInfo and RNCNetInfo so an app that also installs
# those libraries links three separate pods rather than hitting a name clash.
Pod::Spec.new do |s|
  s.name         = "TreebarsReactNative"
  s.version      = package["version"]
  s.summary      = "The iOS bridge for the Treebars React Native SDK"
  s.description  = "The TurboModule that carries every SDK call down to the Swift core."
  s.homepage     = "https://treebars.com"
  s.license      = { :type => "MIT" }
  s.authors      = { "Treebars" => "accounts@treebars.com" }
  s.platforms    = { :ios => "15.1" }
  # An app installs this through React Native autolinking, which reaches the spec by `:path` in
  # `node_modules` and never reads `source`. It names the public repository all the same.
  s.source       = { :git => "https://github.com/treebars/sdks.git", :tag => "#{s.version}" }

  s.swift_version = "5.10"
  s.source_files  = "ios/**/*.{h,m,mm,swift}"

  # Network for NWPathMonitor, which needs no permission; UIKit for the idiom and the screen.
  s.frameworks = "Network", "UIKit"

  # The Swift core, pinned to the exact version rather than a range.
  #
  # `TreebarsSDK` is the core's pod and Swift module alike. This pod is `TreebarsReactNative` so
  # the two never share a directory on a case-insensitive volume; the core's podspec has the
  # reasoning. The `.mm` here reaches the core through `TreebarsSDK-Swift.h`; see the header search
  # path below for why that rather than `@import TreebarsSDK`.
  #
  # Pinned exactly, as the Android half pins its core: a wrapper that floats against its core
  # is a version pair nobody can reproduce.
  s.dependency "TreebarsSDK", "0.5.0"

  # Where Xcode writes the Swift core's Objective-C face, which is the only way a `.mm` can
  # see it.
  #
  # A Swift pod has no headers to install; its ObjC interface is generated during ITS build,
  # into `$(CONFIGURATION_BUILD_DIR)/Swift Compatibility Header/`, and nothing puts that on a
  # dependent's search path. Absent this line the bridge fails as `file not found` on an
  # import that is spelled correctly, after a `pod install` that succeeded.
  #
  # `@import TreebarsSDK` is the alternative and is not free: `@import` in Objective-C++ needs
  # `-fcxx-modules`, which turns every React Native header in the bridge's include graph into
  # a module and moves the failure inside ReactCommon. Adding one search path is the cheaper
  # half of that trade by a wide margin.
  #
  # Set BEFORE `install_modules_dependencies`, which reads the existing `pod_target_xcconfig`
  # out of the spec and APPENDS to `HEADER_SEARCH_PATHS`. Assigning this afterwards would
  # replace everything that helper added instead.
  s.pod_target_xcconfig = {
    "HEADER_SEARCH_PATHS" =>
      "\"${PODS_CONFIGURATION_BUILD_DIR}/TreebarsSDK/Swift Compatibility Header\"",
  }

  # Wires up React-Core, the codegen'd spec and the New Architecture dependencies. Doing
  # this by hand is how podspecs drift out of step with the app's React Native version.
  install_modules_dependencies(s)
end
