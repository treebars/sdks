# The iOS half of the Treebars Flutter SDK.
#
# The pod is named after the Dart package, which is how Flutter finds it. It depends on the Swift
# SDK's pod, `TreebarsSDK`, pinned to the exact version this package carries: a wrapper that floats
# against its SDK is a version pair nobody can reproduce.
Pod::Spec.new do |s|
  s.name             = "treebars_flutter_sdk"
  s.version          = "0.12.3"
  s.summary          = "The iOS bridge for the Treebars Flutter SDK"
  s.description      = "The Flutter plugin that carries every SDK call down to the Swift Treebars SDK."
  s.homepage         = "https://treebars.com"
  s.license          = { :type => "MIT", :file => "../LICENSE" }
  s.authors          = { "Treebars" => "accounts@treebars.com" }
  s.source           = { :path => "." }
  s.source_files     = "Classes/**/*.swift"
  s.platform         = :ios, "15.1"
  s.swift_version    = "5.10"

  s.dependency "Flutter"
  s.dependency "TreebarsSDK", "0.12.3"

  # The Swift SDK is a static framework, and an app built with `use_frameworks!` (Flutter's default)
  # refuses a dynamic pod that depends on a static one. So this pod is static too.
  s.static_framework = true

  s.pod_target_xcconfig = { "DEFINES_MODULE" => "YES", "EXCLUDED_ARCHS[sdk=iphonesimulator*]" => "i386" }
end
