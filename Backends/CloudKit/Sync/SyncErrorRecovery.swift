import CloudKit
import os

/// Shared error classification and recovery for CKSyncEngine send failures.
///
/// Classifies failed record saves and deletes into categories (conflicts,
/// zone-not-found, unknown items, etc.) and provides recovery helpers.
/// Used by `SyncCoordinator` to handle send failures across all zones.
enum SyncErrorRecovery {

  /// Categorized results from classifying failed record saves and deletes.
  struct ClassifiedFailures {
    /// Records that failed because the zone doesn't exist. Need zone creation + re-queue.
    var zoneNotFoundSaves: [CKRecord.ID] = []
    /// Deletes that failed because the zone doesn't exist.
    var zoneNotFoundDeletes: [CKRecord.ID] = []
    /// Conflict: server has a newer version. Caller should update system fields, then re-queue.
    var conflicts: [(recordID: CKRecord.ID, serverRecord: CKRecord)] = []
    /// Record was deleted on server — caller should clear system fields, then re-queue.
    var unknownItems: [(recordID: CKRecord.ID, recordType: String)] = []
    /// Records that failed because the user's iCloud quota is exceeded.
    var quotaExceeded: [CKRecord.ID] = []
    /// All other re-queueable failures (limitExceeded, unexpected errors).
    var requeue: [CKRecord.ID] = []
    /// Failed deletes that should be re-queued (conflicts, limitExceeded, unexpected errors).
    /// CKSyncEngine drops failed deletes from its queue; re-queuing prevents permanent
    /// server-side orphans.
    var requeueDeletes: [CKRecord.ID] = []
  }

  /// Classifies all failed saves and deletes from a sent-changes event.
  static func classify(
    failedSaves: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave],
    failedDeletes: [(CKRecord.ID, CKError)],
    logger: Logger
  ) -> ClassifiedFailures {
    var result = ClassifiedFailures()

    for failure in failedSaves {
      let recordID = failure.record.recordID

      switch failure.error.code {
      case .zoneNotFound, .userDeletedZone:
        result.zoneNotFoundSaves.append(recordID)

      case .serverRecordChanged:
        if let serverRecord = failure.error.serverRecord {
          result.conflicts.append((recordID: recordID, serverRecord: serverRecord))
        } else {
          // Server record unavailable — re-queue so the record isn't silently lost
          logger.warning(
            "serverRecordChanged with no serverRecord for \(recordID.recordName) — re-queuing")
          result.requeue.append(recordID)
        }

      case .unknownItem:
        result.unknownItems.append((recordID: recordID, recordType: failure.record.recordType))

      case .quotaExceeded:
        logger.error(
          "iCloud quota exceeded — sync paused for record \(recordID.recordName)")
        result.quotaExceeded.append(recordID)

      case .limitExceeded, .batchRequestFailed:
        result.requeue.append(recordID)

      default:
        // Re-queue unexpected errors. CKSyncEngine handles transient errors
        // (network, rate limiting) automatically, but other errors drop the
        // record from the queue. Re-queuing ensures we don't silently lose data.
        logger.error(
          "Save error (code=\(failure.error.code.rawValue)) for \(recordID.recordName): \(failure.error) — re-queuing"
        )
        result.requeue.append(recordID)
      }
    }

    for (recordID, error) in failedDeletes {
      switch error.code {
      case .zoneNotFound, .userDeletedZone:
        result.zoneNotFoundDeletes.append(recordID)

      case .unknownItem:
        // Record is already gone from the server — the delete has effectively
        // succeeded. Don't re-queue (would loop forever) and don't treat as a
        // failure. CKSyncEngine has already removed it from its pending queue.
        logger.info(
          "Delete returned unknownItem for \(recordID.recordName) — record already gone, treating as success"
        )

      default:
        // Re-queue any other delete failure (serverRecordChanged, limitExceeded,
        // unexpected errors). CKSyncEngine drops failed items from its queue, so
        // not re-queuing would leave the record on the server permanently.
        logger.error(
          "Delete error (code=\(error.code.rawValue)) for \(recordID.recordName): \(error) — re-queuing"
        )
        result.requeueDeletes.append(recordID)
      }
    }

    return result
  }

  /// Re-queues all classified failures except zone-not-found records.
  /// Returns zone-not-found save and delete IDs for the caller to handle zone creation.
  static func requeueFailures(
    _ failures: ClassifiedFailures,
    syncEngine: CKSyncEngine?,
    logger: Logger
  ) -> (zoneNotFoundSaves: [CKRecord.ID], zoneNotFoundDeletes: [CKRecord.ID]) {
    // Re-queue conflicts, unknownItems, and other failures (same logic as current recover())
    var pendingChanges: [CKSyncEngine.PendingRecordZoneChange] = []
    for (recordID, _) in failures.conflicts {
      pendingChanges.append(.saveRecord(recordID))
    }
    for (recordID, _) in failures.unknownItems {
      pendingChanges.append(.saveRecord(recordID))
    }
    for recordID in failures.requeue {
      pendingChanges.append(.saveRecord(recordID))
    }
    for recordID in failures.quotaExceeded {
      pendingChanges.append(.saveRecord(recordID))
    }
    for recordID in failures.requeueDeletes {
      pendingChanges.append(.deleteRecord(recordID))
    }
    if !pendingChanges.isEmpty {
      syncEngine?.state.add(pendingRecordZoneChanges: pendingChanges)
    }

    return (failures.zoneNotFoundSaves, failures.zoneNotFoundDeletes)
  }

}
