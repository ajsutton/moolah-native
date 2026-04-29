import Foundation
import GRDB
import OSLog

/// Local logger for database-maintenance work — scoped here so the
/// extension does not need access to `ProfileSession`'s private `logger`
/// instance. Same subsystem/category for log-stream continuity.
private let maintenanceLogger = Logger(
  subsystem: "com.moolah.app", category: "ProfileSession")

// `PRAGMA optimize` cadence per `guides/DATABASE_SCHEMA_GUIDE.md` §5,
// extracted from the main `ProfileSession` body so it stays under
// SwiftLint's `type_body_length` and `file_length` thresholds.
extension ProfileSession {

  // MARK: - Database maintenance

  /// Runs `PRAGMA optimize` on the per-profile DB. Best-effort: failures
  /// are logged but never propagated. Per
  /// `guides/DATABASE_SCHEMA_GUIDE.md` §5, the recommended cadence is once
  /// on app resign-active and at most once per hour while active. The
  /// on-resign hook is wired by
  /// `MoolahApp+Lifecycle.handleScenePhaseChange`; the periodic
  /// while-active tick is owned by `startPeriodicPragmaOptimize(interval:)`
  /// and started from `init` with a one-hour interval.
  ///
  /// Runs inside `database.write` because `PRAGMA optimize` may invoke
  /// `ANALYZE` and update the `sqlite_stat1` / `sqlite_stat4` tables — a
  /// read-only transaction would either silently no-op the analyze step
  /// or surface a write-from-read error.
  func runPragmaOptimize() async {
    let database = self.database
    defer { pragmaOptimizeRunCount += 1 }
    do {
      try await database.write { database in
        try database.execute(sql: "PRAGMA optimize")
      }
    } catch {
      maintenanceLogger.warning(
        "PRAGMA optimize failed for profile \(self.profile.id): \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  /// Schedules a best-effort `PRAGMA optimize` on a tracked background
  /// task. Cancels any prior pending optimize before scheduling so we
  /// never run two concurrently for the same session, and leaves the
  /// handle in `pragmaOptimizeTask` so `cleanupSync` can cancel it on
  /// teardown (per `guides/CONCURRENCY_GUIDE.md` §8 — fire-and-forget
  /// tasks must be tracked).
  func schedulePragmaOptimize() {
    pragmaOptimizeTask?.cancel()
    pragmaOptimizeTask = Task { [weak self] in
      await self?.runPragmaOptimize()
    }
  }

  /// Starts the long-lived "at most once per `interval`" `PRAGMA optimize`
  /// tick required by `guides/DATABASE_SCHEMA_GUIDE.md` §5. Each iteration
  /// sleeps for `interval` first and then runs the optimize, so the first
  /// tick fires one interval after this method is called rather than
  /// immediately — the resign-active path
  /// (`MoolahApp+Lifecycle.runPragmaOptimizeOnAllSessions`) covers the
  /// "right now" case.
  ///
  /// Replaces any previously-scheduled periodic task (the prior handle is
  /// cancelled first) so callers can change the cadence without leaking
  /// loops. The handle is tracked on `periodicPragmaOptimizeTask` and
  /// cancelled in `cleanupSync(coordinator:)` per `guides/CONCURRENCY_GUIDE.md`
  /// §8.
  ///
  /// `interval` is parameterised so tests can drive the cadence with a
  /// millisecond-scale value; production uses the default (one hour).
  func startPeriodicPragmaOptimize(interval: Duration = .seconds(3600)) {
    periodicPragmaOptimizeTask?.cancel()
    periodicPragmaOptimizeTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: interval)
        } catch {
          // `sleep(for:)` throws CancellationError on task cancellation;
          // exit the loop rather than continuing past teardown.
          return
        }
        guard !Task.isCancelled else { return }
        await self?.runPragmaOptimize()
      }
    }
  }
}
