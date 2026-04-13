import Foundation

/// Bridges async code into synchronous XCTest measure blocks.
/// Only for use in benchmarks — never in production code.
func awaitSync<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
  let semaphore = DispatchSemaphore(value: 0)
  nonisolated(unsafe) var result: Result<T, Error>!
  Task { @MainActor in
    do {
      result = .success(try await work())
    } catch {
      result = .failure(error)
    }
    semaphore.signal()
  }
  semaphore.wait()
  return try result.get()
}
