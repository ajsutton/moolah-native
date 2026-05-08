// Backends/GRDB/Observation/ValueObservation+RetryingAsyncStream.swift
import Foundation
import GRDB
import os

private let logger = Logger(
  subsystem: "com.moolah.app", category: "GRDBObservation")

/// Default backoff schedule used by `toRetryingAsyncStream(...)` when the
/// caller does not override it. Indexed by the number of consecutive
/// transient failures already seen (1-based: the first delay is at
/// index 0). The schedule clamps at the last entry — a sixth failure
/// would still wait 30 s, but the retry-budget check fires first so
/// that case never executes.
private let defaultBackoffs: [Duration] = [
  .seconds(1), .seconds(5), .seconds(30),
]

/// Categorises a database error as a programmer-bug (`SQLITE_ERROR`
/// class — malformed SQL, missing tables, schema mismatches). Returned
/// `true` means *do not retry*: the underlying problem is in the code
/// or the schema, not in transient I/O state, and retrying will keep
/// hitting the same error.
///
/// Internal so the retry helper's tests can verify the categorisation
/// in isolation, without the full `ValueObservation` machinery. The
/// scope is `internal` rather than `private` because the test target
/// imports `Moolah` via `@testable import` — that is the project's
/// standard way to reach module-internal helpers from tests (see
/// `guides/TEST_GUIDE.md` §Public APIs vs Test Hooks).
func isProgrammerBugError(_ error: any Error) -> Bool {
  guard let dbError = error as? DatabaseError else { return false }
  return dbError.resultCode == .SQLITE_ERROR
}

extension ValueObservation where Reducer.Value: Sendable & Equatable {

  /// Wraps the single-shot `toAsyncStream(onError:)` bridge in an outer
  /// `AsyncStream` that re-creates the observation on transient errors
  /// with backoff. Implements the error categorisation contract from
  /// `guides/DATABASE_CODE_GUIDE.md` §2 convention 5:
  ///
  /// - **Programmer bugs** (`SQLITE_ERROR` from malformed SQL, missing
  ///   tables) — `assertionFailure` in debug; `errorChannel.surfaceAndFinish`
  ///   in release; the outer stream completes (no restart).
  /// - **Transient I/O** (`SQLITE_FULL`, `SQLITE_IOERR`, anything not
  ///   in the programmer-bug class) — log at error level, increment
  ///   the failure counter, sleep for the next backoff interval, then
  ///   restart the inner observation. The counter resets on any
  ///   successful emission so a brief outage doesn't permanently
  ///   poison long-running observations.
  /// - **Budget exhaustion** (`maxFailures` consecutive transient
  ///   failures with no successful emission between them) — surface
  ///   the most recent error to `errorChannel`; the outer stream
  ///   completes.
  ///
  /// **Cancellation.** When the consumer cancels their `Task`, the
  /// outer stream's `onTermination` cancels the wrapper's worker
  /// `Task`. The worker's `for await` over the inner stream observes
  /// the cancellation, breaks out, and the wrapper finishes — which
  /// in turn cancels the inner bridge's worker via its own
  /// `onTermination`, tearing down the GRDB `ValueObservation`
  /// cleanly via `DatabaseCancellable`.
  ///
  /// **Why the helper takes `self` and not the bridge result.** Restart
  /// requires re-calling `.values(in:)` on a fresh `ValueObservation`,
  /// which can only happen here — the bridge holds an `AsyncValueObservation`
  /// (already attached to the writer) and cannot recreate it. So the
  /// helper does the full pipeline inside each retry attempt:
  /// `self.removeDuplicates().values(in:).toAsyncStream(...)`.
  ///
  /// **Why `Equatable` on `Reducer.Value`.** `removeDuplicates()` is the
  /// default per `DATABASE_CODE_GUIDE.md` §2 convention 2; the `Equatable`
  /// constraint enforces it at compile time. `Void`-emitting tick streams
  /// (which must NOT use `removeDuplicates`) cannot use this helper —
  /// they implement their own retry loop, which is acceptable because
  /// they're a small special case and the helper would have to expose a
  /// `removeDuplicates: Bool` parameter to support them.
  ///
  /// - Parameters:
  ///   - database: The writer the inner observation runs against. The
  ///     same writer is used for every retry attempt.
  ///   - errorChannel: Where to surface a non-recoverable error. The
  ///     channel is shared across all observations on a repository
  ///     instance (see `GRDBAccountRepository.errorChannel`).
  ///   - repoMethod: Used in log lines and assertion messages to make
  ///     observation errors greppable. Form: `"<Repo>.<method>"` (e.g.
  ///     `"GRDBAccountRepository.observeAll"`).
  ///   - maxFailures: How many *consecutive* transient failures to
  ///     tolerate before surfacing the most recent error. Default 5.
  ///   - backoffs: Sleep durations between retry attempts, indexed by
  ///     `(failureCount - 1)`. The last entry is reused if the failure
  ///     count exceeds the array length. Default `[1s, 5s, 30s]`.
  func toRetryingAsyncStream(
    in database: any DatabaseWriter,
    errorChannel: ObservationErrorChannel,
    repoMethod: String,
    maxFailures: Int = 5,
    backoffs: [Duration] = defaultBackoffs
  ) -> AsyncStream<Reducer.Value> {
    // Capture into a local so the per-attempt factory closure does not
    // need to retain `self` (`ValueObservation` is a value type, so the
    // capture is cheap; this is mostly about clarity).
    let observation = self
    return makeRetryingAsyncStream(
      makeAttempt: { errorSink in
        observation
          .removeDuplicates()
          .values(in: database)
          .toAsyncStream(onError: errorSink)
      },
      policy: RetryingAsyncStreamPolicy(
        errorChannel: errorChannel,
        repoMethod: repoMethod,
        maxFailures: maxFailures,
        backoffs: backoffs))
  }
}

/// Bundles the retry-loop policy knobs that don't change across
/// attempts. Keeps `runRetryLoop`'s parameter list under SwiftLint's
/// `function_parameter_count` ceiling and groups the related fields
/// together at call sites for readability.
struct RetryingAsyncStreamPolicy: Sendable {
  /// Surfaces non-recoverable errors to the repository consumer.
  let errorChannel: ObservationErrorChannel
  /// Used in log lines and assertion messages. Form: `"<Repo>.<method>"`.
  let repoMethod: String
  /// Consecutive-transient-failure budget before surfacing the most
  /// recent error.
  let maxFailures: Int
  /// Sleep schedule indexed by `(failureCount - 1)`, clamped at the
  /// last entry.
  let backoffs: [Duration]
}

/// Generic retry-loop driver shared by every `toRetryingAsyncStream`
/// caller. Lifted out of the `ValueObservation` extension so the loop
/// body can be exercised by tests without standing up a real GRDB
/// `ValueObservation` (injecting `SQLITE_FULL` into a real database is
/// non-trivial and would couple the test to SQLite VFS internals).
///
/// `makeAttempt` is the per-attempt factory: it returns a fresh
/// `AsyncStream<Value>` *and* receives an `errorSink` closure that the
/// stream invokes with the underlying error before completing. The
/// driver waits for the inner stream to finish, then reads the sink to
/// see whether to retry, surface, or end. In production the factory
/// re-creates a `ValueObservation` pipeline per attempt; in tests the
/// factory can return a stub stream backed by canned errors.
///
/// Internal (not `private`) so contract tests can drive the loop with a
/// synthetic factory and verify the retry / budget / categorisation
/// branches without a live GRDB instance.
///
/// **No `Equatable` constraint on `Value`.** The retry loop body never
/// compares emitted values — `removeDuplicates()` is applied by the
/// `ValueObservation`-side wrapper (`toRetryingAsyncStream`) before the
/// stream reaches this driver. Keeping `Value` constrained only by
/// `Sendable` lets `Void`-emitting callers (notably the rate-cache
/// tick stream — `Void == Void` always, so `removeDuplicates()` would
/// suppress every emission after the first) reuse the same retry,
/// categorisation, and logging plumbing without duplicating it.
func makeRetryingAsyncStream<Value: Sendable>(
  makeAttempt:
    @escaping @Sendable (
      _ errorSink: @escaping @Sendable (any Error) async -> Void
    ) -> AsyncStream<Value>,
  policy: RetryingAsyncStreamPolicy
) -> AsyncStream<Value> {
  AsyncStream { continuation in
    let task = Task {
      await runRetryLoop(
        makeAttempt: makeAttempt,
        policy: policy,
        continuation: continuation)
    }
    continuation.onTermination = { _ in task.cancel() }
  }
}

/// What the retry loop should do after one observation attempt
/// finishes. Decoupling the decision from the action lets the loop
/// body stay short and lets `categoriseAttemptOutcome` be unit-tested
/// in isolation if we ever need that.
private enum AttemptOutcome {
  case finish  // clean completion or programmer bug → end the outer stream
  case sleep(Duration)  // transient failure under budget → wait and retry
}

/// Body of the retry loop. Pulled out of `makeRetryingAsyncStream` so
/// the surrounding `Task { ... }` and `onTermination` wiring stay
/// readable; the loop itself is what the unit tests exercise.
private func runRetryLoop<Value: Sendable>(
  makeAttempt:
    @Sendable (
      _ errorSink: @escaping @Sendable (any Error) async -> Void
    ) -> AsyncStream<Value>,
  policy: RetryingAsyncStreamPolicy,
  continuation: AsyncStream<Value>.Continuation
) async {
  var transientFailures = 0
  while !Task.isCancelled {
    let errorBox = OSAllocatedUnfairLock<(any Error)?>(initialState: nil)
    let inner = makeAttempt({ error in errorBox.withLock { $0 = error } })

    // Drain one observation lifetime. A successful emission resets
    // the transient counter so a brief outage doesn't poison a
    // long-running observation; we track it here rather than after
    // the loop because the inner stream may complete cleanly without
    // any emission (consumer cancelled before the first value).
    var sawEmission = false
    for await value in inner {
      if Task.isCancelled { break }
      continuation.yield(value)
      sawEmission = true
    }
    if sawEmission { transientFailures = 0 }
    if Task.isCancelled { break }

    let outcome = await categoriseAttemptOutcome(
      capturedError: errorBox.withLock { $0 },
      transientFailuresBefore: transientFailures,
      policy: policy)
    switch outcome {
    case .finish:
      continuation.finish()
      return
    case .sleep(let delay):
      transientFailures += 1
      do {
        try await Task.sleep(for: delay)
      } catch {
        break  // Sleep cancelled — caller's Task is shutting down.
      }
    }
  }
  continuation.finish()
}

/// Per-attempt categorisation: looks at what (if anything) the
/// observation deposited into the error box and returns whether the
/// loop should finish (clean completion, programmer bug, or budget
/// exhausted) or sleep-then-retry. Side-effects are limited to logging
/// and (on a terminal error) `errorChannel.surfaceAndFinish`.
private func categoriseAttemptOutcome(
  capturedError: (any Error)?,
  transientFailuresBefore: Int,
  policy: RetryingAsyncStreamPolicy
) async -> AttemptOutcome {
  guard let error = capturedError else {
    // Inner finished cleanly with no error. The underlying
    // ValueObservation should not normally complete on its own, but
    // treating "clean completion" as a terminal signal here prevents
    // an infinite tight loop if it does.
    return .finish
  }
  if isProgrammerBugError(error) {
    assertionFailure(
      "GRDB observation programmer bug in \(policy.repoMethod): \(error)")
    logger.error(
      "GRDB observation error in \(policy.repoMethod, privacy: .public) [programmer-bug]: \(error.localizedDescription, privacy: .public)"
    )
    await policy.errorChannel.surfaceAndFinish(error)
    return .finish
  }
  // Transient — log, decide whether to restart.
  logger.error(
    "GRDB observation error in \(policy.repoMethod, privacy: .public) [transient]: \(error.localizedDescription, privacy: .public)"
  )
  let nextFailureCount = transientFailuresBefore + 1
  if nextFailureCount >= policy.maxFailures {
    await policy.errorChannel.surfaceAndFinish(error)
    return .finish
  }
  // Sleep schedule indexed by `(failureCount - 1)`, clamped at the
  // last entry so we never index past the array.
  let delayIndex = min(nextFailureCount - 1, policy.backoffs.count - 1)
  return .sleep(policy.backoffs[delayIndex])
}
