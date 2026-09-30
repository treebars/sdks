package com.treebars.sdk

import com.treebars.sdk.generated.TreebarsConstants
import kotlinx.coroutines.delay
import org.json.JSONObject

/*
 * Asking for a reward again. The web and iOS SDKs follow the same rule, and all three run the same shared scenarios.
 *
 * Asking again is safe because a person has ONE answer per reward pool and campaign: a repeated claim is answered with
 * the first answer, whether that answer was lost on the way back or never given. Without asking again, a claim that had
 * been recorded as a win could be reported to its page as failed. So a claim that met a 429, a 503 or no answer at all
 * is asked again — `REWARD_CLAIM_RETRIES` times at most, and never past `REWARD_CLAIM_BUDGET_MS` from the first attempt,
 * because a page is spinning a wheel the whole time. Any other refusal is final.
 *
 * Free of HTTP and of the clock, as the uploader is: the request, the clocks and the jitter are handed in.
 */

/** One ask's outcome: the status (-1 when no answer arrived), the `Retry-After` it carried, and the answer on a 200. */
internal data class RewardAttempt(val status: Int, val retryAfter: String? = null, val answer: JSONObject? = null)

/**
 * How long to wait before asking again, or null to stop and tell the page what the last answer said.
 *
 * [retry] counts the retries already made. The jitter is drawn only when there is a retry to spend it on, and the wait is
 * the server's `Retry-After` or the draw, whichever is longer — the header is a floor, never shortened, and the draw
 * spreads a crowd the server refused in one instant, which a bare `Retry-After: 1` would bring back in one instant. A
 * wait that would carry the asking past the budget is not waited: a `Retry-After` longer than the budget ends it at once.
 */
internal fun rewardRetryWaitMs(retry: Int, status: Int, retryAfter: String?, elapsedMs: Long, now: Long, random: () -> Double): Long? {
    val retryable = status < 0 || status in TreebarsConstants.RETRY_AFTER_STATUSES
    if (!retryable || retry >= TreebarsConstants.REWARD_CLAIM_RETRIES) return null
    val asked = if (status < 0) null else retryAfterDelayMs(retryAfter, now)
    val wait = maxOf(asked?.takeIf { it > 0 } ?: 0L, jitterMs(retry, random()))
    return wait.takeIf { elapsedMs + it <= TreebarsConstants.REWARD_CLAIM_BUDGET_MS }
}

/** Asks until there is an answer, a refusal that is not worth asking again, or no more time; the last attempt. */
internal suspend fun claimWithRetries(
    ask: suspend () -> RewardAttempt,
    // Monotonic, so a wall clock changed mid-claim can neither stretch the budget nor spend it.
    elapsed: () -> Long = { System.nanoTime() / 1_000_000 },
    now: () -> Long = System::currentTimeMillis,
    sleep: suspend (Long) -> Unit = { delay(it) },
    random: () -> Double = Math::random,
): RewardAttempt {
    val started = elapsed()
    var retry = 0
    while (true) {
        val attempt = ask()
        if (attempt.answer != null) return attempt
        val wait = rewardRetryWaitMs(retry, attempt.status, attempt.retryAfter, elapsed() - started, now(), random) ?: return attempt
        sleep(wait)
        retry += 1
    }
}

/** What the page is told when the last attempt carried no answer. */
internal fun rewardRefusalReason(attempt: RewardAttempt): String = when {
    attempt.status == 404 -> "not_available"
    attempt.status < 0 -> "offline"
    else -> "failed"
}
