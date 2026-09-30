/**
 * The one-time hand-down of this install's identity to the native SDK.
 *
 * An install that ran an earlier version of this package holds its identity in AsyncStorage,
 * and the native SDKs **cannot read AsyncStorage**: it is a SQLite database (`RKStorage`) on
 * Android and a manifest file under `Documents/RCTAsyncLocalStorage_V1` on iOS — neither is
 * `SharedPreferences` and neither is `UserDefaults`. So adoption is not "the native side reads
 * the old key"; it is this file reading its own store and passing the values down.
 *
 * **What each value protects:**
 *
 * - **The device id and its secret.** Together they are this device's identity with
 *   Treebars. Lose them and the install starts again as a new device: split history, an
 *   orphaned push token and an orphaned inbox.
 * - **`first_seen_at`.** Lose it and every existing install reports `is_first_launch: true` at
 *   once, firing any onboarding campaign filtered on it.
 * - **The in-app ledger.** It records which messages this device has already shown and closed.
 *   Lose it and a message somebody already dismissed can be drawn again.
 *
 * **A failed read is not an empty store, and the difference is the whole file.** A storage that
 * will not answer must not look like a fresh install, or the native SDK would be handed an
 * empty adoption. So this reads through `getItem` directly and lets it throw: on any failure it
 * hands down **nothing** and tries again next launch. The native SDK honours adoption only into
 * an empty key, so a retry costs nothing and a wrong answer costs everything.
 *
 * **And once the native SDK has them, they go** (`forgetAdoption`). The native SDK keeps the
 * device id and secret in storage that device backups do not include (`DeviceIdentityStore` on
 * both platforms); AsyncStorage — a SQLite file on Android, a file under `Documents` on iOS — is
 * in every backup. So `init()` deletes the keys once the native `initialize` has resolved, and a
 * backup restored onto another phone has no identity to hand down to it. By then the native SDK
 * has taken the pair into its own store, or kept the one it already had.
 */

/** Exactly the keys the native SDK can adopt. The others are caches it rebuilds. */
const KEYS = {
  deviceId: '@treebars/device_id',
  fetchSecret: '@treebars/fetch_secret',
  firstSeenAt: '@treebars/first_seen_at',
  signedInUser: '@treebars/signed_in_user',
  identifiedUser: '@treebars/identified_user',
  inAppLedgerJson: '@treebars/in_app_ledger',
} as const;

export interface Adoption {
  deviceId?: string;
  fetchSecret?: string;
  firstSeenAt?: string;
  signedInUser?: string;
  identifiedUser?: string;
  inAppLedgerJson?: string;
}

interface AsyncStorageLike {
  getItem(key: string): Promise<string | null>;
  removeItem(key: string): Promise<void>;
}

/**
 * AsyncStorage, or null when the host never installed it.
 *
 * An optional peer dependency, so a host that never added it has nothing to migrate FROM —
 * which is a legitimately empty adoption rather than a failure, and the one case where
 * returning nothing is the right answer.
 */
function storage(): AsyncStorageLike | null {
  try {
    return require('@react-native-async-storage/async-storage').default as AsyncStorageLike;
  } catch {
    return null;
  }
}

/**
 * Everything this install has that the native SDK could adopt, or nothing at all.
 *
 * All-or-nothing on purpose. A partial hand-down caused by one key failing to read could pass
 * the old device id without its secret, pairing it with a newly minted one — which is neither
 * the old device nor a clean new one.
 */
export async function readAdoption(store: AsyncStorageLike | null = storage()): Promise<Adoption> {
  if (!store) return {};

  try {
    const entries = await Promise.all(
      Object.entries(KEYS).map(async ([field, key]) => [field, await store.getItem(key)] as const),
    );

    const adoption: Adoption = {};
    for (const [field, value] of entries) {
      // An empty string is what the store answers for a key it does not hold in some
      // implementations, and it must not be handed down as a value — the native SDK treats a
      // present key as answered, so `""` would mean "this device has no id, forever".
      if (value) adoption[field as keyof Adoption] = value;
    }
    return adoption;
  } catch {
    /*
     * Deliberately silent about which key failed, and deliberately total.
     *
     * There is nothing a caller can do with the distinction, and the safe action is the same
     * either way: hand down nothing, let the native SDK keep whatever it already has, and try again
     * on the next launch. The one thing that must not happen is a partial adoption being
     * mistaken for a complete one.
     */
    return {};
  }
}

/**
 * Deletes the handed-down copy, once the native SDK has taken it.
 *
 * Called after the native `initialize` resolves — which it does only after the native SDK has
 * written the pair into its own store or kept the one it had (`Adoption.applyTo` and
 * `DeviceIdentityStore` on Android, `Adoption.apply` and `DeviceInfo.adopt` on iOS) — and never
 * after a rejected one, so a failed launch keeps everything for the next. A key that will not
 * delete is left for the next launch to try again: the native SDK takes a hand-down only into an
 * empty store, so one handed down twice costs nothing.
 */
export async function forgetAdoption(store: AsyncStorageLike | null = storage()): Promise<void> {
  if (!store) return;
  await Promise.all(Object.values(KEYS).map((key) => store.removeItem(key).catch(() => undefined)));
}
