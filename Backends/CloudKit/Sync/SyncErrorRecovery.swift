import CloudKit
import os

/// Shared error classification and recovery for CKSyncEngine send failures.
///
/// Both `ProfileSyncEngine` and `ProfileIndexSyncEngine` use identical error
/// classification logic — only the system-fields storage differs. This helper
/// extracts the common dispatch so bug fixes apply everywhere.
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
    /// All other re-queueable failures (quotaExceeded, limitExceeded, unexpected errors).
    var requeue: [CKRecord.ID] = []
  }

  /// Classifies all failed saves and deletes from a sent-changes event.
  static func classify(
    _ sentChanges: CKSyncEngine.Event.SentRecordZoneChanges,
    logger: Logger
  ) -> ClassifiedFailures {
    var result = ClassifiedFailures()

    for failure in sentChanges.failedRecordSaves {
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
        result.requeue.append(recordID)

      case .limitExceeded:
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

    for (recordID, error) in sentChanges.failedRecordDeletes {
      if error.code == .zoneNotFound || error.code == .userDeletedZone {
        result.zoneNotFoundDeletes.append(recordID)
      } else {
        logger.error("Failed to delete record \(recordID.recordName): \(error)")
      }
    }

    return result
  }

  /// Re-queues all classified failures and creates the zone if needed.
  ///
  /// Call this **after** handling engine-specific work (e.g., updating system fields
  /// for conflicts and unknownItems).
  static func recover(
    _ failures: ClassifiedFailures,
    syncEngine: CKSyncEngine?,
    zoneID: CKRecordZone.ID,
    logger: Logger
  ) {
    // Re-queue conflicts, unknownItems, and other failures
    var pendingSaves: [CKSyncEngine.PendingRecordZoneChange] = []
    for (recordID, _) in failures.conflicts {
      pendingSaves.append(.saveRecord(recordID))
    }
    for (recordID, _) in failures.unknownItems {
      pendingSaves.append(.saveRecord(recordID))
    }
    for recordID in failures.requeue {
      pendingSaves.append(.saveRecord(recordID))
    }
    if !pendingSaves.isEmpty {
      syncEngine?.state.add(pendingRecordZoneChanges: pendingSaves)
    }

    // Handle zone-not-found: create zone once and re-queue all affected records
    if !failures.zoneNotFoundSaves.isEmpty || !failures.zoneNotFoundDeletes.isEmpty {
      let saveCount = failures.zoneNotFoundSaves.count
      let deleteCount = failures.zoneNotFoundDeletes.count
      logger.info(
        "Zone missing — creating zone and re-queuing \(saveCount) saves, \(deleteCount) deletes"
      )
      Task {
        do {
          let zone = CKRecordZone(zoneID: zoneID)
          try await CKContainer.default().privateCloudDatabase.save(zone)
          logger.info("Created zone \(zoneID.zoneName)")
          var zoneChanges: [CKSyncEngine.PendingRecordZoneChange] =
            failures.zoneNotFoundSaves.map { .saveRecord($0) }
          zoneChanges += failures.zoneNotFoundDeletes.map { .deleteRecord($0) }
          syncEngine?.state.add(pendingRecordZoneChanges: zoneChanges)
        } catch {
          logger.error("Failed to create zone: \(error)")
        }
      }
    }
  }
}
