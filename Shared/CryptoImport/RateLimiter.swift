// Shared/CryptoImport/RateLimiter.swift
import Foundation

/// Token-bucket rate limiter.
///
/// Used to throttle Alchemy calls to 25 req/s (free-tier limit). The clock
/// is injected so tests can pin "now" deterministically — the live caller
/// passes `{ Date() }` and tests pass a closure backed by a counter.
///
/// Concurrency: this is an `actor`; multiple concurrent callers serialise
/// through `acquire()`. Cancellation is honoured between sleeps via
/// `Task.checkCancellation()`.
actor RateLimiter {
  private let permitsPerSecond: Double
  private let now: @Sendable () -> Date
  private var availablePermits: Double
  private var lastRefill: Date

  /// - Parameters:
  ///   - permitsPerSecond: Steady-state refill rate. The bucket capacity
  ///     also equals `permitsPerSecond`, so a freshly-constructed limiter
  ///     allows a burst of that many permits before throttling kicks in.
  ///   - now: Closure returning the current time. Defaults to `Date()`.
  ///     Tests inject a counter so wall-clock variance does not flake them.
  init(
    permitsPerSecond: Double,
    now: @Sendable @escaping () -> Date = { Date() }
  ) {
    precondition(permitsPerSecond > 0, "RateLimiter requires a positive permit rate")
    self.permitsPerSecond = permitsPerSecond
    self.availablePermits = permitsPerSecond
    self.now = now
    self.lastRefill = now()
  }

  /// Awaits until at least one permit is available, then consumes it.
  ///
  /// Cancellation: throws `CancellationError` if the surrounding `Task` is
  /// cancelled while waiting, either before the first refill check or via
  /// `Task.sleep` interruption.
  func acquire() async throws {
    while true {
      try Task.checkCancellation()
      refill()
      if availablePermits >= 1 {
        availablePermits -= 1
        return
      }
      // Compute sleep duration until at least one permit is available.
      let needed = 1 - availablePermits
      let secondsToWait = needed / permitsPerSecond
      // Floor at 1ms so a near-zero deficit still yields a real sleep
      // rather than a busy loop. Convert to nanoseconds for `Task.sleep`.
      let nanos = UInt64(max(0.001, secondsToWait) * 1_000_000_000)
      try await Task.sleep(nanoseconds: nanos)
    }
  }

  /// Refills the bucket based on the time elapsed since the last refill.
  /// Capacity is bounded by `permitsPerSecond`. Always called from inside
  /// the actor's isolation domain.
  private func refill() {
    let currentTime = now()
    let elapsed = currentTime.timeIntervalSince(lastRefill)
    if elapsed > 0 {
      availablePermits = min(
        permitsPerSecond,
        availablePermits + elapsed * permitsPerSecond
      )
      lastRefill = currentTime
    }
  }
}
