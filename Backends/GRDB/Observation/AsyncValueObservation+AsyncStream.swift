// Backends/GRDB/Observation/AsyncValueObservation+AsyncStream.swift
import GRDB

extension AsyncValueObservation where Element: Sendable {

  /// Bridges a GRDB `AsyncValueObservation` to a non-throwing
  /// `AsyncStream<Element>`.
  ///
  /// Cancellation: when the consumer's Task cancels, the
  /// `continuation.onTermination` handler cancels the inner Task that
  /// drives the observation, which tears down the underlying
  /// `AsyncValueObservation` cleanly via `DatabaseCancellable`.
  ///
  /// Errors: this bridge is single-shot. The first error from the
  /// underlying observation is delivered verbatim to `onError` and the
  /// stream completes (`finish()`). The bridge does NOT retry, NOT
  /// distinguish error categories, and NOT log. All of that is the
  /// caller's responsibility:
  ///
  /// - Repositories typically wrap `toAsyncStream(onError:)` in a
  ///   restart loop that re-creates the observation on transient
  ///   errors (`SQLITE_FULL`, `SQLITE_IOERR`) with backoff.
  /// - Programmer-bug errors (`SQLITE_ERROR` from malformed SQL or
  ///   missing tables) should `fatalError` in debug and surface to the
  ///   `ObservationErrorChannel` in release — the caller's `onError`
  ///   does the categorisation.
  /// - Per-method conventions for repositories live in
  ///   `guides/DATABASE_CODE_GUIDE.md` §2.
  ///
  /// The bridge keeps this simple shape because `AsyncValueObservation`
  /// is itself single-shot — restart requires re-calling
  /// `.values(in:)` on a fresh `ValueObservation`, which the bridge
  /// (which only holds `self`, not the underlying writer) cannot do.
  func toAsyncStream(
    onError: @Sendable @escaping (any Error) -> Void
  ) -> AsyncStream<Element> {
    AsyncStream { continuation in
      // Note on ordering: the AsyncStream init closure is synchronous,
      // and the continuation is not vended to any consumer until this
      // closure returns. The runtime cannot invoke `onTermination` while
      // we are still inside the closure, so assigning `onTermination`
      // after starting `task` is race-free in practice. We keep the
      // intent self-documenting by naming the variable up-front.
      let task = Task {
        do {
          for try await value in self {
            if Task.isCancelled { break }
            continuation.yield(value)
          }
          continuation.finish()
        } catch {
          onError(error)
          continuation.finish()
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
