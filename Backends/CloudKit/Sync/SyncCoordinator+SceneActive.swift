import Foundation

// Scene-active scheduling extracted from `SyncCoordinator+Lifecycle.swift`
// so each file stays under SwiftLint's `file_length` threshold. Owns the
// cancel-and-replace pattern that `MoolahApp+Lifecycle` uses on
// `.active` to avoid stacking concurrent fetches.
extension SyncCoordinator {

  /// Cancels any pending scene-active fetch and schedules a new one.
  /// Called from `MoolahApp+Lifecycle.handleScenePhaseChange(.active)`;
  /// rapid scene-phase cycling can call this repeatedly without
  /// stacking concurrent fetches. The handle is stored on
  /// `fetchChangesTask` and cancelled by `stop()` for orderly teardown.
  func scheduleFetchChanges() {
    fetchChangesTask?.cancel()
    fetchChangesTask = Task { [weak self] in
      await self?.fetchChanges()
    }
  }
}
