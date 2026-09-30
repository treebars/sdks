import { REWARD_CLAIM_BUDGET_MS, REWARD_CLAIM_RETRIES, RETRY_AFTER_STATUSES } from './generated/constants';
import { jitterMs, retryAfterDelayMs } from './uploader';

/*
 * Asking for a reward again. The iOS and Android SDKs follow the same rule.
 *
 * Asking again is safe because a person has ONE answer per reward pool and campaign: a repeated claim is answered with
 * the first answer, whether that answer was lost on the way back or never given. So a claim that met a 429, a 503 or no
 * answer at all is asked again — `REWARD_CLAIM_RETRIES` times at most, and never past `REWARD_CLAIM_BUDGET_MS` from the
 * first attempt, because a page is spinning a wheel the whole time. Any other refusal is final.
 *
 * Deliberately free of `fetch` and timers, as the uploader is: the request, the clocks and the jitter are handed in.
 */

/** One ask's outcome: the status, or null when no answer arrived; the `Retry-After` it carried; the answer on a 200. */
export interface RewardAttempt {
  status: number | null;
  retryAfter: string | null;
  answer: Record<string, unknown> | null;
}

export interface RewardClaimClock {
  /** Monotonic milliseconds: how long the asking has taken, which a changed wall clock cannot stretch or shrink. */
  elapsed(): number;
  /** Wall-clock milliseconds, which only a `Retry-After` date is read against. */
  now(): number;
  sleep(ms: number): Promise<void>;
  /** In [0, 1). The jitter source. */
  random(): number;
}

/**
 * How long to wait before asking again, or null to stop and tell the page what the last answer said.
 *
 * `retry` counts the retries already made. The jitter is drawn only when there is a retry to spend it on, and the wait
 * is the server's `Retry-After` or the draw, whichever is longer — the header is a floor, never shortened, and the draw
 * spreads a crowd the server refused in one instant, which a bare `Retry-After: 1` would bring back in one instant. A
 * wait that would carry the asking past the budget is not waited: a `Retry-After` longer than the budget ends it at once.
 */
export function rewardRetryWaitMs(
  retry: number,
  status: number | null,
  retryAfter: string | null,
  elapsedMs: number,
  now: number,
  random: () => number,
): number | null {
  const retryable = status === null || (RETRY_AFTER_STATUSES as readonly number[]).includes(status);
  if (!retryable || retry >= REWARD_CLAIM_RETRIES) return null;
  const asked = status === null ? null : retryAfterDelayMs(retryAfter, now);
  const wait = Math.max(asked !== null && asked > 0 ? asked : 0, jitterMs(retry, random()));
  return elapsedMs + wait <= REWARD_CLAIM_BUDGET_MS ? wait : null;
}

/** Asks until there is an answer, a refusal that is not worth asking again, or no more time; the last attempt. */
export async function claimWithRetries(ask: () => Promise<RewardAttempt>, clock: RewardClaimClock): Promise<RewardAttempt> {
  const started = clock.elapsed();
  for (let retry = 0; ; retry += 1) {
    const attempt = await ask();
    if (attempt.answer) return attempt;
    const wait = rewardRetryWaitMs(retry, attempt.status, attempt.retryAfter, clock.elapsed() - started, clock.now(), clock.random);
    if (wait === null) return attempt;
    await clock.sleep(wait);
  }
}

/** What the page is told when the last attempt carried no answer. */
export function rewardRefusal(attempt: RewardAttempt): { ok: false; reason: 'not_available' | 'offline' | 'failed' } {
  return { ok: false, reason: attempt.status === 404 ? 'not_available' : attempt.status === null ? 'offline' : 'failed' };
}
