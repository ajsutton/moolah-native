@preconcurrency import CloudKit
import Foundation
import OSLog
import os

// `CKSyncEngineDelegate` conformance for `SyncCoordinator`. The delegate runs
// on CKSyncEngine's internal executor; both entry points hop to `@MainActor`
// for all state access. Helper methods extracted from `nextRecordZoneChangeBatch`
// keep the parent under the SwiftLint complexity / body-length limits.
extension SyncCoordinator: CKSyncEngineDelegate {
  nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    if case .fetchedRecordZoneChanges(let changes) = event {
      await handleFetchedRecordZoneChangesAsync(changes)
    } else {
      await MainActor.run {
        handleEventOnMain(event)
      }
    }
  }

  @MainActor
  private func handleEventOnMain(_ event: CKSyncEngine.Event) {
    switch event {
    case .stateUpdate(let stateUpdate):
      saveStateSerialization(stateUpdate.stateSerialization)

    case .accountChange(let accountChange):
      handleAccountChange(accountChange)

    case .fetchedDatabaseChanges(let changes):
      handleFetchedDatabaseChanges(changes)

    case .fetchedRecordZoneChanges:
      // Handled by handleFetchedRecordZoneChangesAsync
      break

    case .sentRecordZoneChanges(let sentChanges):
      handleSentRecordZoneChanges(sentChanges)

    case .willFetchChanges:
      beginFetchingChanges()

    case .didFetchChanges:
      endFetchingChanges()

    case .sentDatabaseChanges,
      .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
      .willSendChanges, .didSendChanges:
      break

    @unknown default:
      logger.debug("Unknown sync engine event")
    }
  }

  nonisolated func nextRecordZoneChangeBatch(
    _ context: CKSyncEngine.SendChangesContext,
    syncEngine: CKSyncEngine
  ) async -> CKSyncEngine.RecordZoneChangeBatch? {
    await MainActor.run {
      nextRecordZoneChangeBatchOnMain(context, syncEngine: syncEngine)
    }
  }

  @MainActor
  private func nextRecordZoneChangeBatchOnMain(
    _ context: CKSyncEngine.SendChangesContext,
    syncEngine: CKSyncEngine
  ) -> CKSyncEngine.RecordZoneChangeBatch? {
    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(
      .begin, log: Signposts.sync, name: "nextBatch", signpostID: signpostID)
    defer {
      os_signpost(.end, log: Signposts.sync, name: "nextBatch", signpostID: signpostID)
    }

    let pendingChanges = dedupedPendingChanges(
      syncEngine: syncEngine, scope: context.options.scope)
    guard !pendingChanges.isEmpty else { return nil }

    // Partition by zone-kind so atomicByZone can be set correctly per kind.
    // Profile-index records are independent (atomicByZone: false); profile-data
    // records within a zone must commit together (atomicByZone: true). See issue #61.
    guard let batchKind = Self.selectBatchKind(from: pendingChanges) else { return nil }
    let kindChanges = Self.filterChanges(pendingChanges, matching: batchKind)

    let batchLimit = 400
    let batch = Array(kindChanges.prefix(batchLimit))

    // Group saves by zone for efficient batch lookup
    var savesByZone: [CKRecordZone.ID: [CKRecord.ID]] = [:]
    var deletesByBatch: [CKRecord.ID] = []

    for change in batch {
      switch change {
      case .saveRecord(let recordID):
        savesByZone[recordID.zoneID, default: []].append(recordID)
      case .deleteRecord(let recordID):
        deletesByBatch.append(recordID)
      @unknown default:
        break
      }
    }

    let recordsToSave = buildRecordsToSave(savesByZone: savesByZone)

    guard !recordsToSave.isEmpty || !deletesByBatch.isEmpty else { return nil }

    let zoneCount = Set(recordsToSave.map(\.recordID.zoneID)).union(deletesByBatch.map(\.zoneID))
      .count
    os_signpost(
      .event, log: Signposts.sync, name: "nextBatch", signpostID: signpostID,
      "%{public}d records across %{public}d zones", recordsToSave.count + deletesByBatch.count,
      zoneCount)

    return CKSyncEngine.RecordZoneChangeBatch(
      recordsToSave: recordsToSave,
      recordIDsToDelete: deletesByBatch,
      atomicByZone: batchKind.atomicByZone
    )
  }

  /// Returns pending changes filtered to the delegate's scope, deduplicated by
  /// record ID, with records in zones awaiting creation skipped (they'll be
  /// re-queued by `ensureProfileZone` once the zone exists). Extracted so
  /// `nextRecordZoneChangeBatchOnMain` stays under the complexity limit; see
  /// SYNC_GUIDE Rule 12.
  @MainActor
  private func dedupedPendingChanges(
    syncEngine: CKSyncEngine,
    scope: CKSyncEngine.SendChangesOptions.Scope
  ) -> [CKSyncEngine.PendingRecordZoneChange] {
    var seenSaves = Set<CKRecord.ID>()
    var seenDeletes = Set<CKRecord.ID>()
    return syncEngine.state.pendingRecordZoneChanges
      .filter { scope.contains($0) }
      .filter { change in
        switch change {
        case .saveRecord(let id): return seenSaves.insert(id).inserted
        case .deleteRecord(let id): return seenDeletes.insert(id).inserted
        @unknown default: return true
        }
      }
      .filter { change in
        // Skip records whose zone is in pendingZoneCreation
        let zoneID: CKRecordZone.ID
        switch change {
        case .saveRecord(let id): zoneID = id.zoneID
        case .deleteRecord(let id): zoneID = id.zoneID
        @unknown default: return true
        }
        return pendingZoneCreation[zoneID] == nil
      }
  }

  /// Builds `CKRecord`s to save for each zone in the batch, dispatching on zone
  /// kind. Records that have been deleted locally before the batch was built are
  /// converted to server deletions via `handleMissingRecordToSave`.
  @MainActor
  private func buildRecordsToSave(
    savesByZone: [CKRecordZone.ID: [CKRecord.ID]]
  ) -> [CKRecord] {
    var recordsToSave: [CKRecord] = []
    for (zoneID, recordIDs) in savesByZone {
      let zoneType = Self.parseZone(zoneID)

      switch zoneType {
      case .profileIndex:
        appendProfileIndexRecords(recordIDs: recordIDs, into: &recordsToSave)

      case .profileData(let profileId):
        appendProfileDataRecords(
          profileId: profileId, zoneID: zoneID,
          recordIDs: recordIDs, into: &recordsToSave)

      case .unknown:
        logger.warning("Pending save for unknown zone: \(zoneID.zoneName)")
      }
    }
    return recordsToSave
  }

  /// Looks up each profile-index record by ID and either appends it to
  /// `recordsToSave` or queues a server deletion if the local record has been
  /// deleted since the pending change was queued.
  @MainActor
  private func appendProfileIndexRecords(
    recordIDs: [CKRecord.ID],
    into recordsToSave: inout [CKRecord]
  ) {
    for recordID in recordIDs {
      if let record = profileIndexHandler.recordToSave(for: recordID) {
        recordsToSave.append(record)
      } else {
        // Bug fix #2: record deleted locally, queue server deletion
        handleMissingRecordToSave(recordID)
      }
    }
  }

  /// Looks up profile-data records using a batch UUID lookup (plus an
  /// individual lookup for string-keyed `InstrumentRecord`s), appending any
  /// hits to `recordsToSave` and converting misses to server deletions.
  @MainActor
  private func appendProfileDataRecords(
    profileId: UUID,
    zoneID: CKRecordZone.ID,
    recordIDs: [CKRecord.ID],
    into recordsToSave: inout [CKRecord]
  ) {
    guard let handler = try? handlerForProfileZone(profileId: profileId, zoneID: zoneID)
    else {
      return
    }

    // Separate UUID-based and string-based record names for batch lookup
    var uuidRecordNames: [(CKRecord.ID, UUID)] = []
    var stringRecordIDs: [CKRecord.ID] = []
    for recordID in recordIDs {
      if let uuid = UUID(uuidString: recordID.recordName) {
        uuidRecordNames.append((recordID, uuid))
      } else {
        stringRecordIDs.append(recordID)
      }
    }

    // Batch-load UUID-based records
    let recordLookup = handler.buildBatchRecordLookup(for: Set(uuidRecordNames.map(\.1)))

    for (recordID, uuid) in uuidRecordNames {
      if let record = recordLookup[uuid] {
        recordsToSave.append(record)
      } else {
        handleMissingRecordToSave(recordID)
      }
    }

    // Look up string-based records individually (InstrumentRecord)
    for recordID in stringRecordIDs {
      if let record = handler.recordToSave(for: recordID) {
        recordsToSave.append(record)
      } else {
        handleMissingRecordToSave(recordID)
      }
    }
  }

  /// Bug fix #2: When `recordToSave` returns nil (record deleted locally before batch built),
  /// queue a `.deleteRecord` if one isn't already pending.
  @MainActor
  private func handleMissingRecordToSave(_ recordID: CKRecord.ID) {
    guard let syncEngine else { return }
    let hasPendingDelete = syncEngine.state.pendingRecordZoneChanges.contains(
      .deleteRecord(recordID))
    if !hasPendingDelete {
      logger.info(
        "Record \(recordID.recordName) deleted locally before batch — queueing server deletion")
      syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
    }
  }
}
