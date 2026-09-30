package com.treebars.sdk

import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.Job

/**
 * The records `track` has launched and not yet finished, so a `flush()` can wait for the ones launched before it.
 *
 * `track` and `flush` are two independent launches on a multi-threaded dispatcher, and nothing else orders them:
 * without this, a flush called on the very next line could drain before the event reached the queue, and the event
 * would then wait for the thirty-second tick. The lifecycle's own background flush avoids the race by recording and
 * flushing in one coroutine (`onStop`); an app's `track(); flush()` cannot be one coroutine, so the flush waits for
 * the jobs instead.
 *
 * The snapshot is taken synchronously in `flush()`, after `track()` has returned and so after its job is in here —
 * that ordering is the happens-before, and it holds across threads because the set is concurrent.
 */
internal class InFlight {
    private val jobs: MutableSet<Job> = ConcurrentHashMap.newKeySet()

    /** Added before its completion handler is, so a job that has already finished is removed at once rather than kept. */
    fun add(job: Job) {
        jobs += job
        job.invokeOnCompletion { jobs -= job }
    }

    /** The jobs launched so far and not yet finished — what a flush called now has to wait for. */
    fun snapshot(): List<Job> = jobs.toList()
}
