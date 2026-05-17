import Foundation

/// Tunable, per-call HTTP retry/timeout policy. A plain value so each client
/// can hold its own and tests can construct variants freely. See
/// `plans/2026-05-17-http-timeout-retry-design.md`.
struct HTTPRetryPolicy: Sendable, Equatable {
  /// Applied via `URLRequest.timeoutInterval`. Default is deliberately long
  /// (Blockscout's public instances are slow — the goal is to *extend* the
  /// effective timeout, not shorten it).
  var requestTimeout: TimeInterval = 120
  /// Total attempts including the first (1 initial + `maxAttempts - 1` retries).
  var maxAttempts: Int = 3
  /// Exponential backoff base; ceiling for attempt `n` is
  /// `min(backoffCap, backoffBase * 2^(n-1))`, then jittered.
  var backoffBase: TimeInterval = 0.5
  /// Upper bound for the pre-jitter backoff ceiling; see `backoffBase`.
  var backoffCap: TimeInterval = 5
  /// Hard ceiling across all attempts so a dead provider cannot stall one
  /// request for `maxAttempts * requestTimeout`. Retrying stops when either
  /// `maxAttempts` or `totalBudget` is exhausted, whichever comes first.
  var totalBudget: TimeInterval = 300
  /// When true, a rate-limit response carrying a `Retry-After` no longer than
  /// `maxRateLimitWait` is waited out and the (idempotent) request retried
  /// in-place instead of failing. Default false preserves the fallback-chain
  /// clients' behavior.
  var honorsRetryAfterInPlace: Bool = false
  /// `Retry-After` longer than this is not waited out in-place.
  var maxRateLimitWait: TimeInterval = 60

  /// Pre-jitter backoff ceiling for a 1-based attempt number.
  func backoffCeiling(forAttempt attempt: Int) -> TimeInterval {
    let raw = backoffBase * pow(2, Double(max(0, attempt - 1)))
    return min(backoffCap, raw)
  }
}

/// Internal error an operation throws to ask `withRetry` for a retry. The
/// integration layer (e.g. `LiveBlockscoutClient`) only throws this when it
/// has *decided* a retry is wanted; a terminal error is thrown directly so it
/// propagates unchanged on exhaustion.
struct HTTPRetrySignal: Error, Sendable, Equatable {
  /// `nil` → use policy backoff (e.g. 5xx without `Retry-After`).
  /// non-`nil` → server-requested delay already vetted against the policy.
  let retryAfter: TimeInterval?
}
