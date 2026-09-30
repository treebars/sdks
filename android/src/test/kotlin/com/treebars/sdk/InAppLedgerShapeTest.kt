package com.treebars.sdk

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * How `done` is spelled on disk.
 *
 * Every implementation persists the ledger's `done` as an object keyed by delivery id —
 * `[String: Bool]` on iOS, and the same in a ledger a wrapper hands down (`Adoption`) — so one
 * store can read what another wrote. Asking `optJSONArray("done")` of a JSON object answers
 * null rather than throwing, which would drop the whole dismissal history in silence and draw
 * again every message the person had already dismissed.
 *
 * An array is still READ, so a ledger written in that form keeps its dismissals.
 */
@RunWith(RobolectricTestRunner::class)
class InAppLedgerShapeTest {

    private val context: Context get() = ApplicationProvider.getApplicationContext()

    private fun prefsName() = "treebars.inapp.${UUID.randomUUID()}"

    private fun seed(prefs: String, ledger: String) {
        context.getSharedPreferences(prefs, Context.MODE_PRIVATE)
            .edit().putString("in_app_ledger", ledger).apply()
    }

    private fun ledgerOn(prefs: String): JSONObject =
        JSONObject(
            context.getSharedPreferences(prefs, Context.MODE_PRIVATE)
                .getString("in_app_ledger", null)!!,
        )

    private fun message(deliveryId: String) = JSONObject()
        .put("delivery_id", deliveryId)
        .put(
            "in_app",
            JSONObject()
                .put("surface", "overlay")
                .put("layout", "modal")
                .put("trigger", JSONObject().put("kind", "session_start")),
        )

    private fun response(deliveryId: String) = JSONObject()
        .put("messages", JSONArray().put(message(deliveryId)))
        .put("server_time", Iso8601.now())

    /**
     * The shape a wrapper hands down. Without the object branch in `restoreLedger` this passes
     * `allows`, which is the message being drawn again.
     */
    @Test
    fun `a dismissal handed down as an object map is honoured`() {
        val prefs = prefsName()
        seed(prefs, """{"shown":{"del_1":1},"done":{"del_1":true},"last_shown_at":1,"since_sync":0}""")

        val store = InAppStore(context, prefs)
        store.accept(response("del_1"))

        assertFalse(store.allows(store.list().first { it.deliveryId == "del_1" }))
    }

    /** A ledger in the array form. Dropping this would clear its history. */
    @Test
    fun `a dismissal written by an older build as an array is still honoured`() {
        val prefs = prefsName()
        seed(prefs, """{"shown":{"del_1":1},"done":["del_1"],"last_shown_at":1,"since_sync":0}""")

        val store = InAppStore(context, prefs)
        store.accept(response("del_1"))

        assertFalse(store.allows(store.list().first { it.deliveryId == "del_1" }))
    }

    /**
     * And what this SDK writes is the shape the others read. An array here would make the
     * ledger one-directional — readable by this SDK and by nothing else.
     */
    @Test
    fun `what is persisted is an object map, not an array`() {
        val prefs = prefsName()
        val store = InAppStore(context, prefs)
        store.accept(response("del_1"))
        store.markDone("del_1")

        val done = ledgerOn(prefs)
        assertNull("done must be a map, not an array", done.optJSONArray("done"))
        assertNotNull(done.optJSONObject("done"))
        assertTrue(done.getJSONObject("done").optBoolean("del_1"))
    }
}
