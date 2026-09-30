export const Platform = {
  OS: 'android',
  Version: 37,
  constants: {
    Manufacturer: 'Google',
    Model: 'sdk_gphone64_arm64',
    Release: '16',
    uiMode: 'normal',
  },
};
export const Dimensions = { get: () => ({ width: 412, height: 915 }) };
export const PixelRatio = { get: () => 2.625 };
// The shape of a JS-only environment: the registry resolves nothing.
export const TurboModuleRegistry = { get: () => null, getEnforcing: () => { throw new Error('absent'); } };

/**
 * `AppState` as a JS-only host has it: absent. Nothing in this package reads it; the native
 * SDKs track foreground and background themselves.
 */
export const AppState: undefined = undefined;
