import CloudKit
import Foundation

// `queueSave` / `queueDeletion` overloads for `SyncCoordinator`. Each
// appends a `pendingRecordZoneChange` to the engine's state and refreshes
// the sidebar mirror so the pending-uploads counter stays in sync.
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

  /// Subset of `candidates` whose record IDs are NOT already queued for
  /// deletion in `pendingChanges`. Builds a `Set<CKRecord.ID>` from the
  /// pending `.deleteRecord` entries once (O(pending)) and then filters
  /// `candidates` against it (O(candidates)). Replaces a prior per-record
  /// `Sequence.contains(_:)` scan that was O(candidates × pending) on the
  /// main thread — pathological when a deleted profile leaves tens of
  /// thousands of stale uploads queued (the same record names re-surface
  /// every `nextRecordZoneChangeBatch` cycle until the queue drains).
  ///
  /// Pending `.saveRecord` entries do not shadow a candidate: a stale
  /// save and a fresh deletion can legitimately co-exist in the queue,
  /// and CKSyncEngine resolves the order itself. We only dedup against
  /// existing `.deleteRecord` entries so the same record-name isn't
  /// queued for deletion twice.
  nonisolated static func newMissingDeleteIDs(
    among candidates: [CKRecord.ID],
    pendingChanges: [CKSyncEngine.PendingRecordZoneChange]
  ) -> [CKRecord.ID] {
    guard !candidates.isEmpty else { return [] }
    var pendingDeleteIds: Set<CKRecord.ID> = []
    pendingDeleteIds.reserveCapacity(pendingChanges.count)
    for change in pendingChanges {
      if case .deleteRecord(let id) = change {
        pendingDeleteIds.insert(id)
      }
    }
    if pendingDeleteIds.isEmpty { return candidates }
    return candidates.filter { !pendingDeleteIds.contains($0) }
  }
}
