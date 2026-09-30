/*
 * Before the codegen umbrella, and it has to be first.
 *
 * The generated spec header uses `RCTPromiseResolveBlock` and `RCTPromiseRejectBlock` without
 * importing what declares them. Under `use_modular_headers!` every pod is a Clang module, so
 * clang does not merely fail to find the typedef — it finds it inside whichever module it
 * happened to parse first and refuses it, with `declaration of 'RCTPromiseRejectBlock' must be
 * imported from module 'ReactCodegen.rnasyncstorage.rnasyncstorage' before it is required`.
 * That names another library's codegen and nothing this package owns, which is why it reads as
 * a problem with AsyncStorage rather than with this file's import order.
 */
#import <React/RCTBridgeModule.h>

#import <RNTreebarsSpec/RNTreebarsSpec.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * The whole iOS bridge, and everything below it is `TreebarsSDK`.
 *
 * The class name is the module name JavaScript asks for — `RCT_EXPORT_MODULE()` takes no
 * argument, so React Native derives the name from the `@implementation` — which makes a rename
 * here a rename of the module, with nothing about the edit looking like it would. It must
 * match `TurboModuleRegistry.get` in `src/NativeTreebars.ts` and `NAME` in the Kotlin module.
 *
 * `NativeTreebarsSpecBase` rather than `NSObject`: the `emitOn…` methods are declared on the
 * generated base class, and a module that subclasses `NSObject` instead compiles right up
 * until it tries to emit.
 */
@interface TreebarsNative : NativeTreebarsSpecBase <NativeTreebarsSpec>
@end

NS_ASSUME_NONNULL_END
