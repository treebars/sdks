package com.treebars.sdk.rn

import com.facebook.react.BaseReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfo
import com.facebook.react.module.model.ReactModuleInfoProvider

/**
 * What autolinking looks for.
 *
 * The React Native CLI finds an Android module by globbing for a file whose name ends in
 * `Package.kt` inside the package's `android` directory, so this file's name is
 * load-bearing — renaming it to anything else makes the whole library invisible to the
 * autolinker, with no error anywhere.
 *
 * Lazy by construction: `getModule` is only called when JS actually asks for the module,
 * so an app that never initialises Treebars pays nothing at startup.
 */
class TreebarsSdkPackage : BaseReactPackage() {

  override fun getModule(name: String, reactContext: ReactApplicationContext): NativeModule? =
    if (name == TreebarsNativeModule.NAME) TreebarsNativeModule(reactContext) else null

  override fun getReactModuleInfoProvider(): ReactModuleInfoProvider = ReactModuleInfoProvider {
    mapOf(
      TreebarsNativeModule.NAME to
        ReactModuleInfo(
          TreebarsNativeModule.NAME,
          TreebarsNativeModule.NAME,
          // canOverrideExistingModule: false. If some other library ever registered this
          // name we want the loud failure, not a silent swap of whose module answers.
          false,
          // needsEagerInit: false — nothing here has to exist before JS asks for it.
          false,
          // isCxxModule
          false,
          // isTurboModule
          true,
        ),
    )
  }
}
