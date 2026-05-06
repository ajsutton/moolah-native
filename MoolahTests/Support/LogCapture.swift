// MoolahTests/Support/LogCapture.swift
import Foundation
import OSLog

/// Test seam for asserting `os.Logger` emissions.
///
/// `Logger` does not expose a public sink for in-process inspection, so
/// production code is never asked to log through an indirection. Instead,
/// tests retrieve emissions after the fact via `OSLogStore` scoped to the
/// current process. The helper records the position of the unified log
/// before `body` runs and reads back the entries written between that
/// position and the end of the body.
///
/// Scope is `.currentProcessIdentifier` (no `com.apple.logging.local-store`
/// entitlement required) and works on macOS and the iOS Simulator.
enum LogCapture {
  /// One captured log entry. Equatable so tests can assert against an
  /// expected list with `#expect(captured == [...])`.
  struct Entry: Sendable, Equatable {
    /// `OSLogEntryLog.Level` — `.debug`, `.info`, `.notice`, `.error`,
    /// `.fault`. `Logger.warning(_:)` emits at level `.error`; `.notice`
    /// is the default level for `Logger.notice(_:)`. See
    /// `developer.apple.com/documentation/oslog/oslogentrylog/level`.
    let level: OSLogEntryLog.Level
    let subsystem: String
    let category: String
    let message: String
  }

  /// Captures `os.Logger` entries emitted by `body` for the given
  /// `subsystem`. When `category` is non-`nil`, entries from other
  /// categories on the same subsystem are filtered out.
  ///
  /// Entries are returned in the order they were written.
  ///
  /// - Note: `os.Logger` flushes asynchronously. The helper polls the
  ///   store for up to `flushTimeout` after `body` returns, returning as
  ///   soon as the count stops changing for two consecutive reads. The
  ///   default of 250 ms is comfortably above what we observe on M-series
  ///   Macs and the iOS Simulator (typical settle: 5–30 ms).
  static func capture(
    subsystem: String,
    category: String? = nil,
    flushTimeout: Duration = .milliseconds(250),
    during body: () async throws -> Void
  ) async throws -> [Entry] {
    let store = try OSLogStore(scope: .currentProcessIdentifier)
    let startPosition = store.position(timeIntervalSinceEnd: 0)
    try await body()
    return try await readEntriesWhenSettled(
      store: store,
      from: startPosition,
      subsystem: subsystem,
      category: category,
      flushTimeout: flushTimeout)
  }

  /// Polls `store.getEntries(at:matching:)` until the matching entry
  /// count is stable across two consecutive reads, or `flushTimeout`
  /// elapses. Returns the most recent matching list.
  ///
  /// The predicate filters on `subsystem` (and `category`, when provided)
  /// at the storage level — without it, the unified log forces the caller
  /// to iterate every entry produced by the test process, which on a
  /// busy iOS Simulator can stall for tens of seconds and trip the test
  /// runner's hang detector.
  private static func readEntriesWhenSettled(
    store: OSLogStore,
    from startPosition: OSLogPosition,
    subsystem: String,
    category: String?,
    flushTimeout: Duration
  ) async throws -> [Entry] {
    let predicate = matchPredicate(subsystem: subsystem, category: category)
    let pollInterval: Duration = .milliseconds(20)
    let deadline = ContinuousClock.now.advanced(by: flushTimeout)
    var lastCount = -1
    var matched: [Entry] = []
    while ContinuousClock.now < deadline {
      try await Task.sleep(for: pollInterval)
      let entries = try store.getEntries(at: startPosition, matching: predicate)
      matched = entries.compactMap { entry -> Entry? in
        guard let log = entry as? OSLogEntryLog else { return nil }
        return Entry(
          level: log.level,
          subsystem: log.subsystem,
          category: log.category,
          message: log.composedMessage)
      }
      if matched.count == lastCount { return matched }
      lastCount = matched.count
    }
    return matched
  }

  /// Builds an NSPredicate matching `subsystem == X` (and `category == Y`
  /// when a category is supplied). The unified log evaluates the predicate
  /// against `OSLogEntry`-derived attributes (`subsystem`, `category`).
  private static func matchPredicate(subsystem: String, category: String?) -> NSPredicate {
    if let category {
      return NSPredicate(
        format: "subsystem == %@ AND category == %@", subsystem, category)
    }
    return NSPredicate(format: "subsystem == %@", subsystem)
  }
}
