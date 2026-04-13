import Foundation

/// Bridges async code into synchronous XCTest measure blocks.
/// Only for use in benchmarks — never in production code.
///
/// XCTest's `measure` block runs on the main thread. Our repository methods
/// use `MainActor.run` internally, so the main RunLoop must keep spinning
/// for the async work to complete. A semaphore-based approach deadlocks
/// because it blocks the main thread.
///
/// Instead, we use RunLoop spinning to keep the main thread responsive
/// while waiting for the async task to complete.
func awaitSync<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
  nonisolated(unsafe) var result: Result<T, Error>?
  Task {
    do {
      result = .success(try await work())
    } catch {
      result = .failure(error)
    }
  }
  // Spin the RunLoop to let MainActor work execute
  while result == nil {
    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
  }
  return try result!.get()
}
