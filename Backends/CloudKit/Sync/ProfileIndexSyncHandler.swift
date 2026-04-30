@preconcurrency import CloudKit
import Foundation
import OSLog

/// Stateless batch processing logic for the profile-index zone.
/// Contains all data transformation, upsert, deletion, and record-building
/// logic with no CKSyncEngine dependency.
///
/// The coordinator owns the CKSyncEngine instance and delegates data processing
/// to this handler. Methods return results (record IDs, failures) instead of
/// directly interacting with CKSyncEngine state.
///
/// Backed by `GRDBProfileIndexRepository`. The legacy SwiftData
/// `ProfileRecord` class is no longer touched by the runtime — it stays
/// in the build only as the one-shot migrator's source, copying any
/// existing rows into `profile-index.sqlite` on first launch.
///
/// **Concurrency.** Nonisolated and `Sendable`. Every synchronous method
/// calls into the repository's `*Sync(...)` helpers which block the
/// calling thread on the GRDB queue. Declaring this `@MainActor` would
/// force every caller to block the UI thread; instead, callers that
/// care can hop off-actor (`Task.detached { handler.deleteLocalData() }`).
/// All stored properties are themselves `Sendable` (`CKRecordZone.ID`,
/// `GRDBProfileIndexRepository`, `Logger`), so the conformance holds
/// without `@unchecked`.
final class ProfileIndexSyncHandler: Sendable {
  let zoneID: CKRecordZone.ID
  let repository: GRDBProfileIndexRepository

  private let logger = Logger(
    subsystem: "com.moolah.app", category: "ProfileIndexSyncHandler")

  init(repository: GRDBProfileIndexRepository) {
    self.repository = repository
    self.zoneID = CKRecordZone.ID(
      zoneName: "profile-index",
      ownerName: CKCurrentUserDefaultName
    )
  }

  // MARK: - Applying Remote Changes

  /// Applies remote changes (inserts/updates/deletions) to the local GRDB store.
  /// The whole batch runs inside a single GRDB write so a mid-batch failure
  /// rolls back cleanly — required by the rollback contract in
  /// `guides/DATABASE_CODE_GUIDE.md`.
  func applyRemoteChanges(saved: [CKRecord], deleted: [CKRecord.ID]) -> ApplyResult {
    var savedRows: [ProfileRow] = []
    savedRows.reserveCapacity(saved.count)
    for ckRecord in saved {
      guard ckRecord.recordType == ProfileRow.recordType else { continue }
      guard var values = ProfileRow.fieldValues(from: ckRecord) else {
        logger.error(
          "applyRemoteChanges: malformed recordID '\(ckRecord.recordID.recordName)' (recordType \(ckRecord.recordType, privacy: .public)) — skipping"
        )
        continue
      }
      values.encodedSystemFields = ckRecord.encodedSystemFields
      savedRows.append(values)
    }

    var deletedIds: [UUID] = []
    deletedIds.reserveCapacity(deleted.count)
    for recordID in deleted {
      guard let profileId = recordID.uuid else {
        logger.error(
          "applyRemoteChanges: malformed deleted recordID '\(recordID.recordName)' — skipping"
        )
        continue
      }
      deletedIds.append(profileId)
    }

    do {
      try repository.applyRemoteChangesSync(saved: savedRows, deleted: deletedIds)
      return .success(changedTypes: Set(saved.map(\.recordType)))
    } catch {
      logger.error("Failed to save remote profile changes: \(error, privacy: .public)")
      return .saveFailed(error.localizedDescription)
    }
  }

  // MARK: - Building CKRecords

  /// Builds a CKRecord from a local ProfileRow for upload.
  ///
  /// If cached system fields exist on the row, applies fields directly
  /// onto the cached record to preserve the change tag and avoid
  /// `.serverRecordChanged` conflicts. If the cached system fields
  /// reference a *different* zone than this handler's own zone, they
  /// are discarded and the record is uploaded as a fresh create in the
  /// handler's zone — defence-in-depth against legacy corruption from
  /// before per-zone fetches were introduced.
  func buildCKRecord(for row: ProfileRow) -> CKRecord {
    let freshRecord = row.toCKRecord(in: zoneID)
    if let cachedData = row.encodedSystemFields,
      let cachedRecord = CKRecord.fromEncodedSystemFields(cachedData),
      cachedRecord.recordID.zoneID == zoneID,
      CKRecordIDRecordName.isUsableCachedRecordName(cachedRecord.recordID.recordName)
    {
      for key in freshRecord.allKeys() {
        cachedRecord[key] = freshRecord[key]
      }
      return cachedRecord
    }
    return freshRecord
  }

  // MARK: - Record Lookup for Upload

  /// Looks up a ProfileRow by CKRecord.ID and builds a CKRecord for upload.
  func recordToSave(for recordID: CKRecord.ID) -> CKRecord? {
    guard let profileId = recordID.uuid else { return nil }
    do {
      guard let row = try repository.fetchRowSync(id: profileId) else { return nil }
      return buildCKRecord(for: row)
    } catch {
      logger.error("recordToSave: failed to fetch row: \(error, privacy: .public)")
      return nil
    }
  }

  // MARK: - Queue All Existing Records

  /// Scans all ProfileRows in the local store and returns their CKRecord.IDs.
  /// Called on first start when there's no saved sync state.
  /// Returns record IDs for the coordinator to queue.
  func queueAllExistingRecords() -> [CKRecord.ID] {
    let ids: [UUID]
    do {
      ids = try repository.allRowIdsSync()
    } catch {
      logger.error("queueAllExistingRecords: failed to fetch row ids: \(error, privacy: .public)")
      return []
    }
    guard !ids.isEmpty else { return [] }

    let recordIDs = ids.map { id in
      CKRecord.ID(
        recordType: ProfileRow.recordType, uuid: id, zoneID: zoneID)
    }
    logger.info("Collected \(recordIDs.count) existing profiles for upload")
    return recordIDs
  }

  // MARK: - Local Data Deletion

  /// Deletes all local ProfileRows.
  /// Called on account sign-out, account switch, and zone deletion.
  func deleteLocalData() {
    do {
      try repository.deleteAllSync()
      logger.info("Deleted all local profile index data")
    } catch {
      logger.error("Failed to delete local profile data: \(error, privacy: .public)")
    }
  }

  // MARK: - System Fields Management

  /// Clears encoded system fields on all ProfileRows.
  /// Called on encrypted data reset where we keep data but must re-upload fresh.
  func clearAllSystemFields() {
    do {
      try repository.clearAllSystemFieldsSync()
    } catch {
      logger.error("Failed to clear system fields: \(error, privacy: .public)")
    }
  }

  /// Updates `encoded_system_fields` on the ProfileRow matching the given record ID.
  func updateEncodedSystemFields(_ recordID: CKRecord.ID, data: Data) {
    guard let profileId = recordID.uuid else { return }
    do {
      _ = try repository.setEncodedSystemFieldsSync(id: profileId, data: data)
    } catch {
      logger.error("Failed to save updated system fields: \(error, privacy: .public)")
    }
  }

  /// Clears `encoded_system_fields` on the ProfileRow matching the given record ID.
  /// Called on `.unknownItem` — the server deleted the record, so the stale change tag
  /// must be cleared so the next upload creates a fresh record.
  func clearEncodedSystemFields(_ recordID: CKRecord.ID) {
    guard let profileId = recordID.uuid else { return }
    do {
      _ = try repository.setEncodedSystemFieldsSync(id: profileId, data: nil)
    } catch {
      logger.error(
        "Failed to save cleared system fields for record: \(error, privacy: .public)")
    }
  }

  // MARK: - Handle Sent Record Zone Changes

  /// Processes results from a successful CKSyncEngine send.
  /// Updates system fields on successfully saved records, classifies failures,
  /// and handles conflict/unknownItem system fields updates.
  /// Returns classified failures for the coordinator to re-queue.
  func handleSentRecordZoneChanges(
    savedRecords: [CKRecord],
    failedSaves: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave],
    failedDeletes: [(CKRecord.ID, CKError)]
  ) -> SyncErrorRecovery.ClassifiedFailures {
    persistSystemFields(for: savedRecords)
    let failures = SyncErrorRecovery.classify(
      failedSaves: failedSaves,
      failedDeletes: failedDeletes,
      logger: logger)
    resolveSystemFields(for: failures)
    return failures
  }

  /// Persist updated CKRecord system fields onto matching `ProfileRow` rows
  /// after a successful upload.
  private func persistSystemFields(for savedRecords: [CKRecord]) {
    guard !savedRecords.isEmpty else { return }
    for saved in savedRecords {
      writeSystemFields(for: saved.recordID, to: saved.encodedSystemFields)
    }
  }

  /// Apply server-side system fields from conflicts, and clear system fields for
  /// records the server has already deleted.
  private func resolveSystemFields(for failures: SyncErrorRecovery.ClassifiedFailures) {
    guard !failures.conflicts.isEmpty || !failures.unknownItems.isEmpty else { return }
    for (_, serverRecord) in failures.conflicts {
      writeSystemFields(for: serverRecord.recordID, to: serverRecord.encodedSystemFields)
    }
    for (recordID, _) in failures.unknownItems {
      writeSystemFields(for: recordID, to: nil)
    }
  }

  /// Look up a `ProfileRow` by id and replace its cached system fields blob.
  private func writeSystemFields(for recordID: CKRecord.ID, to data: Data?) {
    guard let profileId = recordID.uuid else { return }
    do {
      _ = try repository.setEncodedSystemFieldsSync(id: profileId, data: data)
    } catch {
      logger.error(
        "Failed to save system fields for \(recordID.recordName, privacy: .public): \(error, privacy: .public)"
      )
    }
  }
}
