@preconcurrency import CloudKit
import Foundation

// Re-fetch scheduling for `SyncCoordinator`. When a fetched batch fails to
// apply locally (e.g. SwiftData save error), we schedule an exponentially
// backed-off re-fetch. After the short-retry budget is exhausted we fall
// back to a slow periodic probe so a device that recovers later (disk
// freed, schema migrated, transient corruption cleared) resyncs without
// requiring an app restart. See issue #77.
@MainActor
extension SyncCoordinator {

  /// Schedules a re-fetch after an exponentially-backed-off delay. Multiple calls coalesce
  /// into one re-fetch. Gives up after `maxRefetchAttempts` consecutive failures to avoid
  /// looping forever on a persistent save failure (e.g. SwiftData corruption).
  ///
  /// The attempt counter is reset by `resetRefetchAttempts()` whenever a fetch batch applies
  /// successfully.
  func scheduleRefetch() {
    let nextAttempt = refetchAttempts + 1
    guard let delay = Self.refetchBackoff(forAttempt: nextAttempt) else {
      logger.error(
        """
        Giving up on short re-fetch chain after \(self.refetchAttempts) consecutive save \
        failures. Local SwiftData writes appear to be persistently failing. Scheduling a \
        last-resort retry in \(Self.longRetryInterval) so a recovered device (disk freed, \
        schema migrated, transient corruption cleared) resyncs without requiring an app \
        restart.
        """)
      refetchTask?.cancel()
      refetchTask = nil
      scheduleLongRetry()
      return
    }
    refetchAttempts = nextAttempt
    refetchTask?.cancel()
    refetchTask = Task { [delay, nextAttempt] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      self.logger.info(
        "Re-fetching changes after save failure (attempt \(nextAttempt)/\(Self.maxRefetchAttempts))"
      )
      await self.fetchChanges()
    }
  }

  /// Schedules a last-resort periodic retry after the short-retry budget is exhausted.
  /// On fire, resets the short-retry counter and re-triggers a fetch. If that fetch also
  /// fails to save, the short-retry chain runs again and, on exhaustion, reschedules
  /// another long retry — producing a slow periodic probe that eventually recovers once
  /// the underlying fault clears. Coalesces with any existing long-retry task.
  private func scheduleLongRetry() {
    longRetryTask?.cancel()
    longRetryTask = Task { [interval = Self.longRetryInterval] in
      try? await Task.sleep(for: interval)
      guard !Task.isCancelled else { return }
      self.logger.info(
        "Last-resort re-fetch firing after \(interval) — short-retry chain previously exhausted"
      )
      // Reset the short-retry counter so the next save failure gets a fresh backoff
      // budget instead of immediately re-exhausting.
      self.refetchAttempts = 0
      self.longRetryTask = nil
      await self.fetchChanges()
    }
  }

  /// Resets the re-fetch attempt counter and cancels any pending long-retry task.
  /// Called on every successful apply of fetched changes — a single successful apply
  /// proves local writes are working, so the slow recovery timer is no longer needed.
  func resetRefetchAttempts() {
    refetchAttempts = 0
    longRetryTask?.cancel()
    longRetryTask = nil
  }

  /// Cancels any pending short-retry and long-retry tasks and resets the attempt
  /// counter. Called from `stop()` so a later `start()` begins from a clean slate.
  func cancelRefetchTasks() {
    refetchTask?.cancel()
    refetchTask = nil
    longRetryTask?.cancel()
    longRetryTask = nil
    refetchAttempts = 0
  }
}
