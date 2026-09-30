import Foundation

/*
 Asking for a reward again, one of three implementations — the web and Kotlin SDKs carry the other two — and all three
 are held to the same shared set of scenarios.

 A claim that meets a busy server is asked again rather than reported as `failed`, because a page told it failed may
 belong to somebody the server has just recorded as a winner. Asking again is safe because the server keeps ONE answer
 per person, pool and campaign: a repeat is answered with the first answer, whether that answer was lost on the way back
 or never given. So a 429, a 503 and no answer at all are asked again, `rewardClaimRetries` times at most and never past
 `rewardClaimBudget` from the first attempt, because a page is spinning a wheel the whole time.

 Free of HTTP and of the clock, as the uploader is: the request, the clocks and the jitter are handed in.
 */

/// One ask's outcome: the status (-1 when no answer arrived), the `Retry-After` it carried, and the answer on a 200.
struct RewardAttempt {
    let status: Int
    var retryAfter: String? = nil
    var answer: [String: Any]? = nil
}

/**
 How long to wait before asking again, in milliseconds, or nil to stop and tell the page what the last answer said.

 `retry` counts the retries already made. The jitter is drawn only when there is a retry to spend it on, and the wait is
 the server's `Retry-After` or the draw, whichever is longer — the header is a floor, never shortened, and the draw
 spreads a crowd the server refused in one instant, which a bare `Retry-After: 1` would bring back in one instant. A wait
 that would carry the asking past the budget is not waited: a 429's sixty seconds ends it at once.
 */
func rewardRetryWaitMs(retry: Int, status: Int, retryAfter: String?, elapsedMs: Int64, now: Int64, random: () -> Double) -> Int64? {
    let retryable = status < 0 || TreebarsConstants.retryAfterStatuses.contains(status)
    guard retryable, retry < TreebarsConstants.rewardClaimRetries else { return nil }
    let asked = status < 0 ? nil : retryAfterDelayMs(retryAfter, now: now)
    let wait = max(asked.map { max($0, 0) } ?? 0, jitterMs(attempt: retry, random: random()))
    return elapsedMs + wait <= Int64(TreebarsConstants.rewardClaimBudget * 1000) ? wait : nil
}

/// Asks until there is an answer, a refusal that is not worth asking again, or no more time; the last attempt.
func claimWithRetries(
    ask: () async -> RewardAttempt,
    // Monotonic, so a wall clock changed mid-claim can neither stretch the budget nor spend it.
    elapsed: () -> Int64 = { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) },
    now: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
    sleep: (Int64) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0)) * 1_000_000) },
    random: () -> Double = { Double.random(in: 0..<1) }
) async -> RewardAttempt {
    let started = elapsed()
    var retry = 0
    while true {
        let attempt = await ask()
        if attempt.answer != nil { return attempt }
        guard let wait = rewardRetryWaitMs(
            retry: retry, status: attempt.status, retryAfter: attempt.retryAfter,
            elapsedMs: elapsed() - started, now: now(), random: random
        ) else { return attempt }
        await sleep(wait)
        retry += 1
    }
}

/// What the page is told when the last attempt carried no answer.
func rewardRefusalReason(_ attempt: RewardAttempt) -> String {
    if attempt.status == 404 { return "not_available" }
    return attempt.status < 0 ? "offline" : "failed"
}
