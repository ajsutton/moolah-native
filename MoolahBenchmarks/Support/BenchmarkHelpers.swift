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

/// Non-throwing variant of `awaitSync` for use inside `measure` blocks,
/// `class func setUp`, and other non-throwing benchmark contexts.
///
/// Any thrown error is treated as a benchmark-infrastructure failure and
/// traps with `preconditionFailure`. This keeps call sites free of `try!`
/// while preserving the crash-on-unexpected-failure semantics that
/// benchmarks rely on: if the repository can't be built or a fetch fails,
/// the benchmark's timings would be meaningless anyway.
func awaitSyncExpecting<T>(
  _ work: @escaping @Sendable () async throws -> T,
  file: StaticString = #file,
  line: UInt = #line
) -> T {
  do {
    return try awaitSync(work)
  } catch {
    preconditionFailure(
      "benchmark awaitSync failed: \(error)",
      file: file,
      line: line
    )
  }
}

/// Runs a throwing closure in a non-throwing context and traps on failure.
/// Used at benchmark call sites (e.g., inside `class func setUp`) where a
/// failure is infrastructure breakage and timings would be meaningless.
/// Keeps call sites free of `try!` while making the intent explicit.
func expecting<T>(
  _ description: @autoclosure () -> String = "benchmark setup failed",
  file: StaticString = #file,
  line: UInt = #line,
  _ work: () throws -> T
) -> T {
  do {
    return try work()
  } catch {
    preconditionFailure("\(description()): \(error)", file: file, line: line)
  }
}
