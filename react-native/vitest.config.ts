import { defineConfig } from 'vitest/config';
import { fileURLToPath } from 'node:url';

/**
 * `react-native` stands in for the real thing.
 *
 * The stub's `TurboModuleRegistry` resolves nothing, as in a JS-only host — a Jest run, an
 * Expo Go client, a bundle inside a binary built without the native module. A test that needs a
 * native side installs a fake one on the SDK itself.
 */
export default defineConfig({
  resolve: {
    alias: {
      'react-native': fileURLToPath(new URL('./test/react-native.stub.ts', import.meta.url)),
    },
  },
});
