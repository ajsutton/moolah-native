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
  func cancellationDuringBackoffStopsBeforeNextOperation() async throws {
    let opCount = Counter()
    let sleepEntered = Gate()
    let task = Task {
      try await withRetry(
        policy: HTTPRetryPolicy(),
        isRetryable: { HTTPRetryClassifier.decision(for: $0, idempotent: true) },
        clock: { Date() },
        sleep: { _ in
          await sleepEntered.signal()
          // Long real sleep so the only way out is cancellation arriving
          // mid-backoff.
          try await Task.sleep(nanoseconds: 10_000_000_000)
        },
        jitter: { $0 },
        operation: {
          _ = await opCount.next()
          throw URLError(.timedOut)
        }
      )
    }
    await sleepEntered.wait()  // first operation ran; we are now in backoff
    task.cancel()  // cancel mid-backoff
    await #expect(throws: CancellationError.self) { try await task.value }
    let count = await opCount.value()
    #expect(count == 1)  // operation NOT retried after cancellation
  }

  /// Minimal async counter so the closures stay `Sendable`.
  actor Counter {

    private var count = 0

    func next() -> Int {
      defer { count += 1 }
      return count
    }

    func value() -> Int { count }
  }

  /// One-shot async rendezvous: `wait()` suspends until `signal()` fires.
  actor Gate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var signaled = false

    func signal() {
      signaled = true
      for continuation in continuations { continuation.resume() }
      continuations.removeAll()
    }

    func wait() async {
      if signaled { return }
      await withCheckedContinuation { continuations.append($0) }
    }
  }
}
