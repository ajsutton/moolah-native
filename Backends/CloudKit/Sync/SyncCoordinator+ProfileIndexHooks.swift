import CloudKit
import Foundation

// Profile-index repository hook wiring split out of the main
// `SyncCoordinator` body so it stays under SwiftLint's `file_length`
// threshold. The single entry point is invoked from
// `SyncCoordinator.init`, so this file's only responsibility is the
// closure plumbing.
extension SyncCoordinator {

  /// Installs repository-side hooks so app-side mutations (`upsert` /
  /// `delete` on `GRDBProfileIndexRepository`) automatically queue
  /// CKSyncEngine pending changes. Runs at the end of `init` so every
  /// stored property on `self` exists before the closures capture it.
  ///
  /// Double-firing with the store-side `onProfileChanged` /
  /// `onProfileDeleted` callbacks is benign: `queueSave` /
  /// `queueDeletion` are idempotent on `(recordType, id, zoneID)`. The
  /// store-side callbacks remain as a belt-and-braces transition until
  /// a follow-up release deletes them once every active device has run
  /// a release with the repository hooks installed.
  func wireProfileIndexHooks() {
    let zoneID = profileIndexHandler.zoneID
    containerManager.profileIndexRepository.attachSyncHooks(
      onRecordChanged: { [weak self] id in
        Task { @MainActor [weak self] in
          self?.queueSave(recordType: ProfileRow.recordType, id: id, zoneID: zoneID)
        }
      },
      onRecordDeleted: { [weak self] id in
        Task { @MainActor [weak self] in
          self?.queueDeletion(recordType: ProfileRow.recordType, id: id, zoneID: zoneID)
        }
      })
  }
}
