// MoolahTests/Shared/RateLimitGateTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("RateLimitGate")
struct RateLimitGateTests {

  // MARK: - Clock helper

  /// Hand-rolled monotonic clock so tests can advance "now" without
  /// relying on `Task.sleep` and avoid wall-clock flake.
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
  func freshGateIsOpen() async throws {
    let gate = RateLimitGate(now: { Date() })
    try await gate.ensureAvailable()
  }

  // MARK: - Retry-After path

  @Test
  func retryAfterSetsCooldownToServerSuppliedDeadline() async throws {
    let clock = FakeClock()
    let gate = RateLimitGate(now: { clock.now() })

    let deadline = await gate.recordRateLimit(retryAfter: 60)

    #expect(deadline == clock.now().addingTimeInterval(60))

    // Just before the deadline — gate is closed.
    clock.advance(59)
    await #expect(throws: RateLimitGateError.self) {
      try await gate.ensureAvailable()
    }

    // After the deadline — gate is open again.
    clock.advance(2)
    try await gate.ensureAvailable()
  }

  @Test
  func retryAfterIsCappedAtMaxBackoff() async throws {
    let clock = FakeClock()
    let gate = RateLimitGate(maxBackoff: 120, now: { clock.now() })

    let deadline = await gate.recordRateLimit(retryAfter: 9_999)

    #expect(deadline == clock.now().addingTimeInterval(120))
  }

  // MARK: - Exponential fallback

  @Test
  func missingRetryAfterUsesBaseBackoff() async throws {
    let clock = FakeClock()
    let gate = RateLimitGate(baseBackoff: 30, maxBackoff: 600, now: { clock.now() })

    let deadline = await gate.recordRateLimit(retryAfter: nil)

    #expect(deadline == clock.now().addingTimeInterval(30))
  }

  @Test
  func consecutiveFailuresGrowExponentially() async throws {
    let clock = FakeClock()
    let gate = RateLimitGate(baseBackoff: 30, maxBackoff: 600, now: { clock.now() })

    let first = await gate.recordRateLimit()
    #expect(first == clock.now().addingTimeInterval(30))

    let second = await gate.recordRateLimit()
    #expect(second == clock.now().addingTimeInterval(60))

    let third = await gate.recordRateLimit()
    #expect(third == clock.now().addingTimeInterval(120))
  }

  @Test
  func exponentialBackoffSaturatesAtMax() async throws {
    let clock = FakeClock()
    let gate = RateLimitGate(baseBackoff: 30, maxBackoff: 100, now: { clock.now() })

    _ = await gate.recordRateLimit()
    _ = await gate.recordRateLimit()
    let third = await gate.recordRateLimit()

    #expect(third == clock.now().addingTimeInterval(100))
  }

  // MARK: - Reset on success

  @Test
  func successAfterCooldownClearsGateAndResetsCounter() async throws {
    let clock = FakeClock()
    let gate = RateLimitGate(baseBackoff: 30, maxBackoff: 600, now: { clock.now() })

    _ = await gate.recordRateLimit()
    _ = await gate.recordRateLimit()

    // Wait past the cooldown so the next request is allowed; recording
    // its success then resets state for the next failure cycle.
    clock.advance(121)
    try await gate.ensureAvailable()
    await gate.recordSuccess()
    try await gate.ensureAvailable()

    // Counter reset — next failure starts at base backoff again.
    let next = await gate.recordRateLimit()
    #expect(next == clock.now().addingTimeInterval(30))
  }

  // MARK: - Concurrent-success-doesn't-erase-cooldown race

  @Test
  func successDoesNotClearActiveCooldown() async throws {
    let clock = FakeClock()
    let gate = RateLimitGate(baseBackoff: 30, maxBackoff: 600, now: { clock.now() })

    // A racing 429 closes the gate. A different in-flight request that
    // already passed `ensureAvailable` then completes 2xx and reports
    // success. The cooldown set by the 429 must survive — otherwise the
    // next caller would skip the cooldown that the gate just installed.
    _ = await gate.recordRateLimit(retryAfter: 60)
    await gate.recordSuccess()

    await #expect(throws: RateLimitGateError.self) {
      try await gate.ensureAvailable()
    }

    // The deadline survives, but the failure counter still resets — the
    // 2xx is evidence the host is mostly healthy, so the next failure
    // (after the cooldown expires) starts at base backoff again rather
    // than continuing the exponential climb.
    clock.advance(61)
    try await gate.ensureAvailable()
    let next = await gate.recordRateLimit()
    #expect(next == clock.now().addingTimeInterval(30))
  }

  // MARK: - Cooldown clears on expiry

  @Test
  func ensureAvailableClearsExpiredCooldown() async throws {
    let clock = FakeClock()
    let gate = RateLimitGate(baseBackoff: 30, maxBackoff: 600, now: { clock.now() })

    _ = await gate.recordRateLimit(retryAfter: 30)
    clock.advance(31)
    try await gate.ensureAvailable()

    // The next failure progresses exponential backoff because the
    // counter is cleared only on success — auto-reopen alone shouldn't
    // forget that the host previously rate-limited us.
    let next = await gate.recordRateLimit()
    #expect(next == clock.now().addingTimeInterval(60))
  }
}

// MARK: - Retry-After header parsing

@Suite("HTTPURLResponse.retryAfterSeconds")
struct RetryAfterSecondsTests {
  private static let stubURL = URL(fileURLWithPath: "/")

  // swiftlint:disable force_unwrapping
  // `HTTPURLResponse(url:statusCode:httpVersion:headerFields:)` only fails on a
  // malformed `httpVersion`, and `"HTTP/1.1"` is a hardcoded literal — so the
  // force-unwrap below is provably safe. CODE_GUIDE §9 permits this in tests.
  private func response(retryAfter value: String?) -> HTTPURLResponse {
    var headers: [String: String] = [:]
    if let value { headers["Retry-After"] = value }
    return HTTPURLResponse(
      url: Self.stubURL,
      statusCode: 429,
      httpVersion: "HTTP/1.1",
      headerFields: headers
    )!
  }
  // swiftlint:enable force_unwrapping

  /// Fixed reference instant — anchor used by all tests that don't
  /// otherwise care about the clock value. Pinned to a concrete second
  /// so the parser's relative-seconds output is stable.
  private static let referenceNow = Date(timeIntervalSince1970: 1_500_000_000)

  @Test
  func missingHeaderReturnsNil() {
    #expect(response(retryAfter: nil).retryAfterSeconds(now: Self.referenceNow) == nil)
  }

  @Test
  func deltaSecondsParse() {
    #expect(response(retryAfter: "120").retryAfterSeconds(now: Self.referenceNow) == 120)
  }

  @Test
  func deltaSecondsTrimsWhitespace() {
    #expect(response(retryAfter: "  90 ").retryAfterSeconds(now: Self.referenceNow) == 90)
  }

  @Test
  func httpDateInFutureReturnsRelativeSeconds() {
    let now = Date(timeIntervalSince1970: 1_445_412_400)  // 2015-10-21 07:26:40 GMT
    // 80 seconds in the future:
    let future = "Wed, 21 Oct 2015 07:28:00 GMT"
    let parsed = response(retryAfter: future).retryAfterSeconds(now: now)
    #expect(parsed == 80)
  }

  @Test
  func httpDateInPastClampsToZero() {
    let past = "Wed, 21 Oct 2015 07:28:00 GMT"
    #expect(response(retryAfter: past).retryAfterSeconds(now: Self.referenceNow) == 0)
  }

  @Test
  func malformedReturnsNil() {
    #expect(response(retryAfter: "garbage").retryAfterSeconds(now: Self.referenceNow) == nil)
  }
}
