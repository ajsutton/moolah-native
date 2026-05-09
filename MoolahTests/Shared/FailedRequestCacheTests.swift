// MoolahTests/Shared/FailedRequestCacheTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("FailedRequestCache")
struct FailedRequestCacheTests {

  // MARK: - Clock helper

  /// Hand-rolled monotonic clock so tests can advance "now" without
  /// relying on `Task.sleep` and avoid wall-clock flake. Same pattern
  /// as `RateLimitGateTests.FakeClock`.
  final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
      self.current = start
    }

    func now() -> Date {
      lock.lock()
      defer { lock.unlock() }
      return current
    }

    func advance(_ seconds: TimeInterval) {
      lock.lock()
      defer { lock.unlock() }
      current = current.addingTimeInterval(seconds)
    }
  }

  // MARK: - Initial state

  @Test
  func freshCacheIsOpen() async throws {
    let cache = FailedRequestCache()
    try await cache.ensureAvailable(for: "https://example.com/x")
  }

  // MARK: - HTTP failure cooldown (fixed)

  @Test
  func httpFailureIsMutedUntilFixedCooldownExpires() async throws {
    let clock = FakeClock()
    let cache = FailedRequestCache(httpCooldownDuration: 60, now: { clock.now() })

    let deadline = await cache.recordHTTPFailure(for: "https://example.com/x")
    #expect(deadline == clock.now().addingTimeInterval(60))

    // Just before expiry — still muted.
    clock.advance(59)
    await #expect(throws: FailedRequestCacheError.self) {
      try await cache.ensureAvailable(for: "https://example.com/x")
    }

    // After expiry — request goes through cleanly again.
    clock.advance(2)
    try await cache.ensureAvailable(for: "https://example.com/x")
  }

  @Test
  func repeatedHTTPFailuresKeepFixedCooldown() async throws {
    let clock = FakeClock()
    let cache = FailedRequestCache(httpCooldownDuration: 60, now: { clock.now() })

    // The HTTP path is intentionally not exponential — every recorded
    // failure resets to a fresh fixed cooldown anchored at "now".
    _ = await cache.recordHTTPFailure(for: "https://example.com/x")
    clock.advance(30)
    let second = await cache.recordHTTPFailure(for: "https://example.com/x")
    #expect(second == clock.now().addingTimeInterval(60))
  }

  // MARK: - Transport failure cooldown (exponential)

  @Test
  func transportFailureUsesBaseBackoff() async throws {
    let clock = FakeClock()
    let cache = FailedRequestCache(
      transportBaseBackoff: 5, transportMaxBackoff: 120, now: { clock.now() })

    let deadline = await cache.recordTransportFailure(for: "https://example.com/x")
    #expect(deadline == clock.now().addingTimeInterval(5))
  }

  @Test
  func consecutiveTransportFailuresGrowExponentially() async throws {
    let clock = FakeClock()
    let cache = FailedRequestCache(
      transportBaseBackoff: 5, transportMaxBackoff: 120, now: { clock.now() })

    let first = await cache.recordTransportFailure(for: "https://example.com/x")
    #expect(first == clock.now().addingTimeInterval(5))

    let second = await cache.recordTransportFailure(for: "https://example.com/x")
    #expect(second == clock.now().addingTimeInterval(10))

    let third = await cache.recordTransportFailure(for: "https://example.com/x")
    #expect(third == clock.now().addingTimeInterval(20))

    let fourth = await cache.recordTransportFailure(for: "https://example.com/x")
    #expect(fourth == clock.now().addingTimeInterval(40))
  }

  @Test
  func transportBackoffSaturatesAtMax() async throws {
    let clock = FakeClock()
    let cache = FailedRequestCache(
      transportBaseBackoff: 5, transportMaxBackoff: 30, now: { clock.now() })

    _ = await cache.recordTransportFailure(for: "https://example.com/x")
    _ = await cache.recordTransportFailure(for: "https://example.com/x")
    _ = await cache.recordTransportFailure(for: "https://example.com/x")
    let fourth = await cache.recordTransportFailure(for: "https://example.com/x")

    #expect(fourth == clock.now().addingTimeInterval(30))
  }

  @Test
  func transportFailuresAreTrackedPerURL() async throws {
    let clock = FakeClock()
    let cache = FailedRequestCache(
      transportBaseBackoff: 5, transportMaxBackoff: 120, now: { clock.now() })

    // URL `a` racks up two transport failures.
    _ = await cache.recordTransportFailure(for: "https://example.com/a")
    _ = await cache.recordTransportFailure(for: "https://example.com/a")

    // URL `b`'s first failure is still at base backoff — counters are
    // independent, otherwise an unrelated URL would inherit punishment.
    let bFirst = await cache.recordTransportFailure(for: "https://example.com/b")
    #expect(bFirst == clock.now().addingTimeInterval(5))
  }

  @Test
  func httpFailureResetsTransportCounter() async throws {
    let clock = FakeClock()
    let cache = FailedRequestCache(
      httpCooldownDuration: 60,
      transportBaseBackoff: 5,
      transportMaxBackoff: 120,
      now: { clock.now() })

    _ = await cache.recordTransportFailure(for: "https://example.com/x")
    _ = await cache.recordTransportFailure(for: "https://example.com/x")
    // Server then responds with a 4xx/5xx — proves the transport path
    // is healthy, so subsequent transport failures should restart at
    // base backoff rather than continue the exponential climb.
    _ = await cache.recordHTTPFailure(for: "https://example.com/x")

    clock.advance(61)  // wait out the HTTP cooldown
    let next = await cache.recordTransportFailure(for: "https://example.com/x")
    #expect(next == clock.now().addingTimeInterval(5))
  }

  @Test
  func successResetsTransportCounter() async throws {
    let clock = FakeClock()
    let cache = FailedRequestCache(
      transportBaseBackoff: 5, transportMaxBackoff: 120, now: { clock.now() })

    _ = await cache.recordTransportFailure(for: "https://example.com/x")
    _ = await cache.recordTransportFailure(for: "https://example.com/x")
    await cache.recordSuccess(for: "https://example.com/x")

    let next = await cache.recordTransportFailure(for: "https://example.com/x")
    #expect(next == clock.now().addingTimeInterval(5))
  }

  // MARK: - Cross-cutting

  @Test
  func differentKeysAreIndependent() async throws {
    let clock = FakeClock()
    let cache = FailedRequestCache(httpCooldownDuration: 60, now: { clock.now() })

    _ = await cache.recordHTTPFailure(for: "https://example.com/a")

    // A different URL must NOT be affected — this is the entire point
    // of a per-URL cache versus a host-wide gate.
    try await cache.ensureAvailable(for: "https://example.com/b")
  }

  @Test
  func recordSuccessClearsEntry() async throws {
    let clock = FakeClock()
    let cache = FailedRequestCache(httpCooldownDuration: 60, now: { clock.now() })

    _ = await cache.recordHTTPFailure(for: "https://example.com/x")
    await cache.recordSuccess(for: "https://example.com/x")

    // The 2xx is evidence that the resource is reachable; cooldown
    // dropped immediately so the next caller goes through.
    try await cache.ensureAvailable(for: "https://example.com/x")
  }

  // MARK: - Bounded growth

  @Test
  func boundedByMaxEntriesViaPruningExpired() async throws {
    let clock = FakeClock()
    let cache = FailedRequestCache(
      httpCooldownDuration: 60, maxEntries: 2, now: { clock.now() })

    _ = await cache.recordHTTPFailure(for: "https://example.com/a")
    _ = await cache.recordHTTPFailure(for: "https://example.com/b")

    // Both entries are still within their cooldowns. Letting them
    // expire and then inserting a third lets the cache prune.
    clock.advance(61)
    _ = await cache.recordHTTPFailure(for: "https://example.com/c")

    // The expired ones are gone — open again.
    try await cache.ensureAvailable(for: "https://example.com/a")
    try await cache.ensureAvailable(for: "https://example.com/b")
    // And the new one is muted as expected.
    await #expect(throws: FailedRequestCacheError.self) {
      try await cache.ensureAvailable(for: "https://example.com/c")
    }
  }

  @Test
  func boundedByMaxEntriesViaOldestEviction() async throws {
    let clock = FakeClock()
    let cache = FailedRequestCache(
      httpCooldownDuration: 600, maxEntries: 2, now: { clock.now() })

    _ = await cache.recordHTTPFailure(for: "https://example.com/a")
    clock.advance(1)
    _ = await cache.recordHTTPFailure(for: "https://example.com/b")
    clock.advance(1)
    // All three are within their (long) cooldown; nothing to prune.
    // The oldest (`a`) gets evicted to make room for `c`.
    _ = await cache.recordHTTPFailure(for: "https://example.com/c")

    try await cache.ensureAvailable(for: "https://example.com/a")
    await #expect(throws: FailedRequestCacheError.self) {
      try await cache.ensureAvailable(for: "https://example.com/b")
    }
    await #expect(throws: FailedRequestCacheError.self) {
      try await cache.ensureAvailable(for: "https://example.com/c")
    }
  }

  // MARK: - ensureAvailable side-effect

  @Test
  func ensureAvailableClearsExpiredEntry() async throws {
    let clock = FakeClock()
    let cache = FailedRequestCache(httpCooldownDuration: 60, now: { clock.now() })

    _ = await cache.recordHTTPFailure(for: "https://example.com/x")
    clock.advance(61)
    try await cache.ensureAvailable(for: "https://example.com/x")
    // After the side-effect prune, a subsequent failure starts a fresh
    // cooldown anchored at the current clock — same shape as the gate.
    let next = await cache.recordHTTPFailure(for: "https://example.com/x")
    #expect(next == clock.now().addingTimeInterval(60))
  }
}
