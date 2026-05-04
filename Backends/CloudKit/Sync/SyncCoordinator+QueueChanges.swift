import CloudKit
import Foundation

// `queueSave` / `queueDeletion` overloads extracted from
// `SyncCoordinator+Lifecycle.swift` so that file stays under SwiftLint's
// 400-line `file_length` threshold. Same per-method behaviour: append a
// `pendingRecordZoneChange` to the engine's state and refresh the
// sidebar mirror so the pending-uploads counter stays in sync.
extension SyncCoordinator {

  // MARK: - Pending Changes

  // During the short window between `start()` returning and `completeStart`
  // installing the engine, these queue calls silently no-op. That's safe
  // because no user-driven edits can reach `queueSave`/`queueDeletion` before
  // the UI is ready, and any already-persisted records are re-queued by
  // `queueAllExistingRecordsForAllZones` / `queueUnsyncedRecordsForAllProfiles`
  // inside `completeStart`.
  func queueSave(recordType: String, id: UUID, zoneID: CKRecordZone.ID) {
    let recordID = CKRecord.ID(
      recordType: recordType, uuid: id, zoneID: zoneID)
    syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    refreshPendingUploadsMirror()
  }

  func queueSave(recordName: String, zoneID: CKRecordZone.ID) {
    let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
    syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    refreshPendingUploadsMirror()
  }

  func queueDeletion(recordType: String, id: UUID, zoneID: CKRecordZone.ID) {
    let recordID = CKRecord.ID(
      recordType: recordType, uuid: id, zoneID: zoneID)
    syncEngine?.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
    refreshPendingUploadsMirror()
  }

  func queueDeletion(recordName: String, zoneID: CKRecordZone.ID) {
    let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
    syncEngine?.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
    refreshPendingUploadsMirror()
  }
}
