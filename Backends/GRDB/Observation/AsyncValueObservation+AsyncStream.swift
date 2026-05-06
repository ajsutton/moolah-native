// Backends/GRDB/Observation/AsyncValueObservation+AsyncStream.swift
import GRDB

extension AsyncValueObservation where Element: Sendable {
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
