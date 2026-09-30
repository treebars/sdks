package com.treebars.sdk

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Adopting an identity a wrapper is handing down, and refusing to overwrite one we already have.
 *
 * A wrapper may hold `device_id`, `fetch_secret`, `first_seen_at` and the two user keys in storage
 * this core cannot read — AsyncStorage, for a React Native app: a SQLite database on Android, a
 * manifest file on iOS. So adoption cannot be "the native reads the old key"; it is the wrapper
 * reading its own store and passing values in, and if that path is wrong the failures are
 * permanent and silent:
 *
 *  - **The fetch secret cannot be recreated.** It is random, and the device's in-app messages
 *    and inbox (`/v1/in-app`, `/v1/notifications`) are fetched with it.
 *  - **A missed `device_id`** splits a person's history and orphans their push token and inbox.
 *  - **A missed `first_seen_at`** reports `is_first_launch: true` on every existing install at
 *    once, firing any onboarding campaign filtered on it — and a message, once sent, cannot be
 *    recalled.
 *
 * The second test is the one that makes this safe to call on every launch rather than only the
 * first, which is the difference between an integration a wrapper can get right and one it has
 * to remember to stop doing.
 */
@RunWith(RobolectricTestRunner::class)
class AdoptionTest {

    private fun prefs(name: String) = ApplicationProvider.getApplicationContext<Context>()
        .getSharedPreferences("$name-${UUID.randomUUID()}", Context.MODE_PRIVATE)

    @Test
    fun `an empty store takes everything the wrapper hands down`() {
        val store = prefs("empty")
        val adoption = Adoption(
            deviceId = "dev_from_js",
            fetchSecret = "secret_from_js",
            firstSeenAt = "2020-01-01T00:00:00.000Z",
            signedInUser = "user_9",
            identifiedUser = "user_9",
            inAppLedgerJson = """{"done":{"del_1":true},"shown":{}}""",
        )
        adoption.applyTo(store)

        // The id and its secret are handed to the identity store as one pair, and never to prefs,
        // which Auto Backup copies (`DeviceIdentityStore`; `DeviceIdentityStoreTest` has the rest).
        assertEquals(DeviceIdentity("dev_from_js", "secret_from_js"), adoption.identity())
        assertNull(store.getString("device_id", null))
        assertNull(store.getString("fetch_secret", null))
        assertEquals("2020-01-01T00:00:00.000Z", store.getString("first_seen_at", null))
        assertEquals("user_9", store.getString("signed_in_user", null))
        assertEquals("user_9", store.getString("identified_user", null))
        assertEquals(
            """{"done":{"del_1":true},"shown":{}}""",
            store.getString("in_app_ledger", null),
        )
    }

    /*
     * The asymmetry that makes this safe. A wrapper passes these unconditionally on every
     * launch and stops thinking about it; a stale copy it keeps handing down cannot overwrite
     * the value this device has since decided for itself.
     */
    @Test
    fun `a store that already answered keeps its own answer`() {
        val store = prefs("occupied")
        store.edit().putString("first_seen_at", "2019-06-01T00:00:00.000Z").commit()

        Adoption(firstSeenAt = "2020-01-01T00:00:00.000Z").applyTo(store)

        assertEquals("2019-06-01T00:00:00.000Z", store.getString("first_seen_at", null))
    }

    /*
     * An id handed down without its secret keeps the id and gets a fresh secret: a wrapper that
     * never had a secret never used one, so a fresh one loses nothing. A secret with no id is
     * nothing — there is no device for it to prove.
     */
    @Test
    fun `the id and its secret travel as one pair`() {
        val withoutSecret = Adoption(deviceId = "dev_from_js").identity()
        assertEquals("dev_from_js", withoutSecret?.id)
        assertEquals(64, withoutSecret?.secret?.length)

        assertNull(Adoption(fetchSecret = "secret_from_js").identity())
    }

    @Test
    fun `nothing to adopt writes nothing, which is every launch after the first`() {
        val store = prefs("none")
        val adoption = Adoption()
        adoption.applyTo(store)

        assertNull(adoption.identity())
        assertNull(store.getString("first_seen_at", null))
    }

    /*
     * An empty string is what a wrapper hands down when its own store answered "nothing here",
     * and it must not be mistaken for a value — a device id of "" is worse than no device id,
     * because `contains()` would then report the key as answered forever.
     */
    @Test
    fun `an empty string is nothing, not a value`() {
        val store = prefs("blank")
        val adoption = Adoption(deviceId = "", fetchSecret = "", firstSeenAt = "")
        adoption.applyTo(store)

        assertNull(adoption.identity())
        assertNull(store.getString("first_seen_at", null))
    }
}
