import Foundation
import OSLog

private let retryLogger = Logger(
  subsystem: "com.moolah.app", category: "HTTPRetry")

/// Runs `operation`, retrying per `policy` while `isRetryable` says so.
///
/// - Backoff is the policy's exponential ceiling passed through `jitter`
///   (default: uniform full jitter in `0...ceiling` — `0...0` is a valid closed range, so a zero ceiling collapses to 0; tests pass identity).
/// - `clock` / `sleep` are injected so tests advance a fake clock and never
///   block. The default `sleep` is `Task.sleep`, which throws on cancellation.
/// - Stops when `maxAttempts` is reached, when the next delay would exceed
///   `totalBudget`, when the error is not retryable, or on cancellation. On
///   any stop the **last** thrown error propagates unchanged.
func withRetry<T: Sendable>(
  policy: HTTPRetryPolicy,
  isRetryable: @Sendable (any Error) -> HTTPRetryDecision,
  clock: @Sendable () -> Date = { Date() },
  sleep: @Sendable (TimeInterval) async throws -> Void = {
    try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000))
  },
  jitter: @Sendable (TimeInterval) -> TimeInterval = {
    TimeInterval.random(in: 0...max(0, $0))
  },
  operation: @Sendable () async throws -> T
) async throws -> T {
  let start = clock()
  var attempt = 1
  while true {
    do {
      return try await operation()
    } catch {
      // A cancellation thrown by the operation is terminal.
      try Task.checkCancellation()
      let decision = isRetryable(error)
      let delay: TimeInterval
      switch decision {
      case .doNotRetry:
        throw error
      case .retryAfterBackoff:
        delay = jitter(policy.backoffCeiling(forAttempt: attempt))
      case .retryAfter(let serverDelay):
        delay = max(0, serverDelay)
      }
      guard attempt < policy.maxAttempts else { throw error }
      let elapsed = clock().timeIntervalSince(start)
      guard elapsed + delay <= policy.totalBudget else { throw error }
      retryLogger.notice(
        """
        Retry attempt \(attempt + 1, privacy: .public) of \
        \(policy.maxAttempts, privacy: .public) after \
        \(delay, privacy: .public)s: \
        \(error.localizedDescription, privacy: .public)
        """
      )
      try await sleep(delay)
      attempt += 1
    }
  }
}
