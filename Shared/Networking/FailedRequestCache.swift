// Shared/Networking/FailedRequestCache.swift
import Foundation

/// Thrown by `URLSession.dataRespectingRateLimit(for:gate:failureCache:)`
/// when a recently-failed request is repeated before its cooldown
/// expires. The `until` payload is the deadline after which the same
/// request will be allowed through again.
enum FailedRequestCacheError: Error, Equatable {
  case cooldown(until: Date)
}

/// Per-URL cooldown so a request that just failed isn't re-issued in a
/// hot loop.
///
/// Complements `RateLimitGate`: the gate is host-wide and trips only on
/// `429` / `418` / `503-Retry-After` (so other URLs to the same host
/// keep working); this cache is per-URL and trips on **any** non-2xx
/// (so a different URL to the same host is unaffected). Together they
/// handle the two common "spam loop" shapes:
///
/// - The host has rate-limited us → host-wide gate → fall through to
///   the next provider in the price-service chain.
/// - A specific resource permanently 404s (deleted ticker, unknown
///   coin, malformed symbol) → per-URL cache → that one provider stops
///   probing for that one resource until the cooldown lapses.
///
/// Concurrency: actor. The internal map is bounded by `maxEntries`;
/// when full, expired entries are pruned in bulk before inserting a
/// new entry. There is no per-eviction LRU because the typical working
/// set (failing tickers / coin ids per session) is far below the
/// default ceiling.
actor FailedRequestCache {
  private let cooldownDuration: TimeInterval
  private let maxEntries: Int
  private let now: @Sendable () -> Date
  private var deadlines: [String: Date] = [:]

  /// - Parameters:
  ///   - cooldownDuration: How long a failed request is muted for.
  ///     Defaults to 5 minutes — long enough that a chart redraw / live
  ///     price tick won't re-probe immediately, short enough that a
  ///     user fixing a typo and resubmitting still sees a fresh attempt.
  ///   - maxEntries: Soft cap on the cache size. When exceeded, expired
  ///     entries are pruned; if all entries are still active, the new
  ///     entry replaces the oldest deadline. Defaults to 256 — covers a
  ///     plausible session-worth of failing tickers without unbounded
  ///     growth.
  ///   - now: Closure returning the current time. Defaults to `Date()`.
  init(
    cooldownDuration: TimeInterval = 300,
    maxEntries: Int = 256,
    now: @Sendable @escaping () -> Date = { Date() }
  ) {
    self.cooldownDuration = cooldownDuration
    self.maxEntries = maxEntries
    self.now = now
  }

  /// Throws `FailedRequestCacheError.cooldown(until:)` when `key` is
  /// still within its failure window. As a side effect, clears an
  /// expired entry so the next call goes through cleanly.
  func ensureAvailable(for key: String) throws {
    guard let deadline = deadlines[key] else { return }
    if now() < deadline {
      throw FailedRequestCacheError.cooldown(until: deadline)
    }
    deadlines.removeValue(forKey: key)
  }

  /// Drops `key`'s entry. Called after a 2xx so a transient failure
  /// doesn't outlive the recovery.
  func recordSuccess(for key: String) {
    deadlines.removeValue(forKey: key)
  }

  /// Records a failure for `key` and arms the cooldown.
  @discardableResult
  func recordFailure(for key: String) -> Date {
    if deadlines.count >= maxEntries {
      pruneExpired()
      if deadlines.count >= maxEntries {
        evictOldest()
      }
    }
    let deadline = now().addingTimeInterval(cooldownDuration)
    deadlines[key] = deadline
    return deadline
  }

  private func pruneExpired() {
    let currentTime = now()
    deadlines = deadlines.filter { $0.value > currentTime }
  }

  /// Removes the entry with the smallest deadline so the cache can
  /// accept a new entry under sustained-failure pressure. Picks one
  /// deterministically; a tie on deadline removes whichever
  /// `min(by:)` selects first, which is acceptable because both
  /// entries have identical staleness.
  private func evictOldest() {
    guard let oldestKey = deadlines.min(by: { $0.value < $1.value })?.key else { return }
    deadlines.removeValue(forKey: oldestKey)
  }
}
