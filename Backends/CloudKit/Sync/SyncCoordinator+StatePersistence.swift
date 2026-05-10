// Backends/CloudKit/Sync/SyncCoordinator+StatePersistence.swift

@preconcurrency import CloudKit
import Foundation

/// CKSyncEngine state-serialization persistence helpers, extracted
/// from `SyncCoordinator.swift` so the main file stays under
/// SwiftLint's `file_length` budget. Load of the state serialization
/// happens off-actor in `prepareEngine` on `+Lifecycle`; this file
/// owns the write / delete paths invoked from `CKSyncEngineDelegate`
/// callbacks.
extension SyncCoordinator {

  /// Atomically writes the engine's serialised state to disk so a
  /// crash between batches doesn't lose the cursor.
  func saveStateSerialization(_ serialization: CKSyncEngine.State.Serialization) {
    do {
      let data = try JSONEncoder().encode(serialization)
      try data.write(to: stateFileURL, options: .atomic)
    } catch {
      logger.error("Failed to save sync state: \(error, privacy: .public)")
    }
  }

  /// Removes the persisted serialised state — invoked on sign-out and
  /// account-switch lifecycle paths so the next launch fetches a
  /// fresh changeset rather than replaying stale cursor state. A
  /// failure to delete leaves stale state on disk, which would silently
  /// drive the next launch off the wrong cursor; logging here is the
  /// only signal a future debugger has.
  func deleteStateSerialization() {
    do {
      try FileManager.default.removeItem(at: stateFileURL)
    } catch CocoaError.fileNoSuchFile {
      // Already gone — no-op.
    } catch {
      logger.error(
        """
        Failed to delete sync state at \(self.stateFileURL.path, privacy: .public): \
        \(error.localizedDescription, privacy: .public)
        """
      )
    }
  }
}
