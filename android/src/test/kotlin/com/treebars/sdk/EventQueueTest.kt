package com.treebars.sdk

import com.treebars.sdk.generated.TreebarsConstants
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/*
 * What the queue owes anyone who calls it: an event handed to `append` is in the queue when
 * `append` returns, whatever else was happening at the time.
 *
 * Two events queued milliseconds apart — `device_context` and `push_token_registered` at launch,
 * say — must both survive. An append that read the array before the other had written it would
 * write over the first event, and the flush that followed would upload one.
 *
 * Nothing in this class awaits inside its critical section — `persist()` is blocking IO under a
 * [kotlinx.coroutines.sync.Mutex] — so the only thing that can race it is a second thread. Hence `runBlocking` with
 * `Dispatchers.Default` rather than `runTest`: virtual time would run these coroutines one
 * after another and every assertion below would hold against a class with no locking at all.
 */
@RunWith(RobolectricTestRunner::class)
class EventQueueTest {

    // A fresh root per test: the queue is a file, and one test's leftovers would be another
    // test's starting contents.
    // `@JvmField` because JUnit collects rules by reflecting over public fields, and a plain
    // Kotlin `val` is a private field behind a getter it never looks at — the rule is then
    // simply never run, and every test fails on a folder nobody created.
    @Rule
    @JvmField
    val temp = TemporaryFolder()

    private fun event(name: String): JSONObject = JSONObject()
        .put("event_id", name)
        .put("session_id", "s1")
        .put("device_id", "d1")
        .put("event_name", name)
        .put("properties", JSONObject())
        .put("timestamp", "2026-08-22T12:00:00.000Z")
        .put("sdk_version", TreebarsConstants.SDK_VERSION)

    private suspend fun EventQueue.names(): List<String> =
        peek(Int.MAX_VALUE).map { it.getString("event_name") }

    /** What survived a process death: the file, read by a queue that has no memory of this one. */
    private suspend fun onDisk(directory: File): List<String> = EventQueue(directory).names()

    @Test
    fun `two appends that overlap both survive`() {
        val directory = temp.newFolder()
        val queue = EventQueue(directory)

        runBlocking {
            listOf("device_context", "push_token_registered")
                .map { name -> launch(Dispatchers.Default) { queue.append(event(name)) } }
                .joinAll()

            // Which of the two reaches the lock first is the scheduler's business, so the
            // claim is survival rather than sequence — the bug being pinned is an event that
            // vanished, not one that arrived second.
            assertEquals(setOf("device_context", "push_token_registered"), queue.names().toSet())
            assertEquals(2, queue.size())
        }
    }

    @Test
    fun `a burst keeps every event, and each writer's events keep their order`() {
        val directory = temp.newFolder()
        val queue = EventQueue(directory)
        val writers = 5
        val each = 5

        runBlocking {
            (0 until writers)
                .map { w ->
                    launch(Dispatchers.Default) {
                        for (i in 0 until each) queue.append(event("w${w}_$i"))
                    }
                }
                .joinAll()

            val queued = queue.names()
            assertEquals("nothing was lost", writers * each, queued.size)
            assertEquals("and nothing was written twice", writers * each, queued.toSet().size)

            /*
             * Order, as far as this class can be held to it. A global sequence would pin the
             * dispatcher — the order 25 coroutines reach the lock in is not the queue's to
             * decide. What the queue does owe is FIFO, because `remove(count)` takes from the
             * front and trusts that the front is the oldest; an append that spliced an event
             * in anywhere else would make a flush drop an event it never uploaded.
             */
            for (w in 0 until writers) {
                assertEquals(
                    (0 until each).map { "w${w}_$it" },
                    queued.filter { it.startsWith("w${w}_") },
                )
            }

            // The in-memory list agreeing with itself proves the lock; the file agreeing with
            // it proves the persist under that lock was not half-written by the next append.
            assertEquals(queued, onDisk(directory))
        }
    }

    @Test
    fun `removing a batch while another event arrives drops only the batch`() {
        val directory = temp.newFolder()
        val queue = EventQueue(directory)

        runBlocking {
            queue.append(event("first"))
            queue.append(event("second"))

            // What an upload does: take a batch, then drop exactly that many — while the app
            // keeps tracking. The late arrival must outlive the removal.
            listOf(
                launch(Dispatchers.Default) { queue.remove(2) },
                launch(Dispatchers.Default) { queue.append(event("during_upload")) },
            ).joinAll()

            // Deterministic despite the race, and that is the property: `remove` is "the two
            // oldest", not "two". Whichever order the lock is taken in, the arrival is not one
            // of the two events the uploader had in hand.
            assertEquals(listOf("during_upload"), queue.names())
            assertEquals(listOf("during_upload"), onDisk(directory))
        }
    }

    @Test
    fun `a write that fails does not stop later events from queueing`() {
        val directory = temp.newFolder()
        // `persist()` writes a temp file and renames it over the live one. A directory sitting
        // on that path cannot be opened for writing, which is the nearest a test gets to full
        // storage.
        val blocker = File(directory, "treebars-queue.json.tmp")
        assertTrue(blocker.mkdirs())

        val queue = EventQueue(directory)

        runBlocking {
            /*
             * `persist()` swallows the failure in a `runCatching` and returns normally, so
             * `append` cannot fail — the event is in memory and only its durability was lost.
             * Nothing is stubbed to make it throw;
             * the assertions below are on what this class actually does.
             */
            queue.append(event("lost"))
            assertEquals(listOf("lost"), queue.names())
            assertEquals("the write really did fail", emptyList<String>(), onDisk(directory))

            assertTrue(blocker.delete())
            queue.append(event("kept"))

            // One failed write does not settle the queue into a state later appends inherit.
            assertEquals(listOf("lost", "kept"), queue.names())
            // And because every persist rewrites the whole array rather than appending to it,
            // the next successful write carries the earlier event back to disk with it.
            assertEquals(listOf("lost", "kept"), onDisk(directory))
        }
    }

    /*
     * `File.renameTo` reports a refusal by returning false, not by throwing, so a save whose rename is
     * refused has to be noticed and written in place. Otherwise the file stays at whatever the last good
     * rename left, and the next launch reads a queue missing every event since and still holding the
     * ones already uploaded. No filesystem a test runs on refuses a rename that its own write then
     * manages, so the rename is handed in.
     */
    @Test
    fun `a save whose rename is refused is written in place`() {
        val directory = temp.newFolder()
        val queue = EventQueue(directory, rename = { _, _ -> false })

        runBlocking {
            queue.append(event("first"))
            queue.append(event("second"))
            assertEquals(listOf("first", "second"), onDisk(directory))

            // A removal is a save too: the uploaded event must leave the file with it.
            assertEquals(1, queue.removeIds(setOf("first")))
            assertEquals(listOf("second"), onDisk(directory))
        }
        assertFalse("the temp file is not left beside it", File(directory, "treebars-queue.json.tmp").exists())
    }

    /*
     * The cap is the reason a handset that spends a fortnight offline does not fill its own
     * storage, and the direction it drops in
     * is a product decision: recent behaviour is worth more than stale behaviour.
     */
    @Test
    fun `the cap drops the oldest and keeps the newest`() {
        val directory = temp.newFolder()
        val queue = EventQueue(directory)
        val cap = TreebarsConstants.QUEUE_CAP
        val overflow = 5

        runBlocking {
            for (i in 0 until cap + overflow) queue.append(event("event_$i"))

            assertEquals(cap, queue.size())

            val queued = queue.names()
            assertEquals("the oldest went", "event_$overflow", queued.first())
            assertEquals("the newest stayed", "event_${cap + overflow - 1}", queued.last())
            for (i in 0 until overflow) {
                assertFalse("event_$i should have been dropped", queued.contains("event_$i"))
            }

            // A cap enforced only in memory would let the file grow forever, which is the half
            // of this that costs a user their storage.
            assertEquals(cap, JSONArray(File(directory, "treebars-queue.json").readText()).length())
        }
    }
}
