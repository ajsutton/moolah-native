import Foundation
import Testing

@testable import Moolah

@Suite("withRetry")
struct HTTPRetryTests {
  /// Deterministic clock + sleeper: `sleep` advances the clock instead of
  /// blocking, and records every requested delay.
  final class FakeScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_700_000_000)
    private(set) var sleeps: [TimeInterval] = []

    func now() -> Date {
      lock.withLock { current }
    }

    func sleep(_ seconds: TimeInterval) async throws {
      try Task.checkCancellation()
      lock.withLock {
        sleeps.append(seconds)
        current = current.addingTimeInterval(seconds)
      }
    }
  }

  @Test
  func succeedsOnFirstTryWithoutSleeping() async throws {
    let sched = FakeScheduler()
    let result = try await withRetry(
      policy: HTTPRetryPolicy(),
      isRetryable: { HTTPRetryClassifier.decision(for: $0, idempotent: true) },
      clock: { sched.now() },
      sleep: { try await sched.sleep($0) },
      jitter: { $0 },
      operation: { 42 })
    #expect(result == 42)
    #expect(sched.sleeps.isEmpty)
  }

  @Test
  func retriesTransientThenSucceeds() async throws {
    let sched = FakeScheduler()
    let attempts = Counter()
    let result = try await withRetry(
      policy: HTTPRetryPolicy(),
      isRetryable: { HTTPRetryClassifier.decision(for: $0, idempotent: true) },
      clock: { sched.now() },
      sleep: { try await sched.sleep($0) },
      jitter: { $0 },
      operation: {
        if await attempts.next() < 2 { throw URLError(.timedOut) }
        return "ok"
      })
    #expect(result == "ok")
    #expect(sched.sleeps == [0.5, 1.0])
  }

  @Test
  func exhaustsAndRethrowsLastError() async throws {
    let sched = FakeScheduler()
    await #expect(throws: URLError.self) {
      try await withRetry(
        policy: HTTPRetryPolicy(),
        isRetryable: {
          HTTPRetryClassifier.decision(for: $0, idempotent: true)
        },
        clock: { sched.now() },
        sleep: { try await sched.sleep($0) },
        jitter: { $0 },
        operation: { throw URLError(.timedOut) })
    }
    #expect(sched.sleeps == [0.5, 1.0])
  }

  @Test
  func nonRetryableErrorIsNotRetried() async throws {
    let sched = FakeScheduler()
    struct Boom: Error, Equatable {}
    await #expect(throws: Boom.self) {
      try await withRetry(
        policy: HTTPRetryPolicy(),
        isRetryable: {
          HTTPRetryClassifier.decision(for: $0, idempotent: true)
        },
        clock: { sched.now() },
        sleep: { try await sched.sleep($0) },
        jitter: { $0 },
        operation: { throw Boom() })
    }
    #expect(sched.sleeps.isEmpty)
  }

  @Test
  func honorsServerRetryAfterDelay() async throws {
    let sched = FakeScheduler()
    let attempts = Counter()
    _ = try await withRetry(
      policy: HTTPRetryPolicy(honorsRetryAfterInPlace: true),
      isRetryable: { HTTPRetryClassifier.decision(for: $0, idempotent: true) },
      clock: { sched.now() },
      sleep: { try await sched.sleep($0) },
      jitter: { $0 },
      operation: { () async throws -> Int in
        if await attempts.next() < 1 { throw HTTPRetrySignal(retryAfter: 7) }
        return 1
      })
    #expect(sched.sleeps == [7])
  }

  @Test
  func stopsWhenTotalBudgetWouldBeExceeded() async throws {
    let sched = FakeScheduler()
    var policy = HTTPRetryPolicy()
    policy.backoffBase = 1000
    policy.backoffCap = 1000
    policy.totalBudget = 10
    await #expect(throws: URLError.self) {
      try await withRetry(
        policy: policy,
        isRetryable: {
          HTTPRetryClassifier.decision(for: $0, idempotent: true)
        },
        clock: { sched.now() },
        sleep: { try await sched.sleep($0) },
        jitter: { $0 },
        operation: { throw URLError(.timedOut) })
    }
    #expect(sched.sleeps.isEmpty)
  }

  @Test
  func stopsOnCancellationMidBackoff() async throws {
    let sched = FakeScheduler()
    let task = Task {
      try await withRetry(
        policy: HTTPRetryPolicy(),
        isRetryable: {
          HTTPRetryClassifier.decision(for: $0, idempotent: true)
        },
        clock: { sched.now() },
        sleep: { _ in
          try Task.checkCancellation()
          throw URLError(.timedOut)
        },
        jitter: { $0 },
        operation: { throw URLError(.timedOut) })
    }
    task.cancel()
    await #expect(throws: (any Error).self) { try await task.value }
  }

  /// Minimal async counter so the closures stay `Sendable`.
  actor Counter {

    private var value = 0

    func next() -> Int {
      defer { value += 1 }
      return value
    }
  }
}
