import CloudKit
import Foundation

// Profile-index repository hook wiring for `SyncCoordinator`. The single
// entry point is invoked from `SyncCoordinator.init`; this file's only
// responsibility is the closure plumbing.
extension SyncCoordinator {

  /// Installs repository-side hooks so app-side mutations (`upsert` /
  /// `delete` on `GRDBProfileIndexRepository`) automatically queue
  /// CKSyncEngine pending changes. Runs at the end of `init` so every
  /// stored property on `self` exists before the closures capture it.
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
