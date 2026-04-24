@preconcurrency import CloudKit
import Foundation
import OSLog
import SwiftData

/// Stateless batch processing logic for the profile-index zone.
/// Contains all data transformation, upsert, deletion, and record-building
/// logic with no CKSyncEngine dependency.
///
/// The coordinator owns the CKSyncEngine instance and delegates data processing
/// to this handler. Methods return results (record IDs, failures) instead of
/// directly interacting with CKSyncEngine state.
@MainActor
final class ProfileIndexSyncHandler {
  nonisolated let zoneID: CKRecordZone.ID
  nonisolated let modelContainer: ModelContainer

  nonisolated private let logger = Logger(
    subsystem: "com.moolah.app", category: "ProfileIndexSyncHandler")

  init(modelContainer: ModelContainer) {
    self.modelContainer = modelContainer
    self.zoneID = CKRecordZone.ID(
      zoneName: "profile-index",
      ownerName: CKCurrentUserDefaultName
    )
  }

  /// Fetches records using the given descriptor, logging errors instead of silently discarding them.
  nonisolated private func fetchOrLog<T: PersistentModel>(
    _ descriptor: FetchDescriptor<T>,
    context: ModelContext
  ) -> [T] {
    do {
      return try context.fetch(descriptor)
    } catch {
      logger.error("SwiftData fetch failed for \(T.self): \(error)")
      return []
    }
  }

  // MARK: - Applying Remote Changes

  /// Applies remote changes (inserts/updates/deletions) to the local SwiftData store.
  /// Creates a fresh ModelContext per call for isolation.
  nonisolated func applyRemoteChanges(saved: [CKRecord], deleted: [CKRecord.ID]) -> ApplyResult {
    let context = ModelContext(modelContainer)

    for ckRecord in saved {
      guard ckRecord.recordType == ProfileRecord.recordType else { continue }
      guard let profileId = ckRecord.recordID.uuid else { continue }

      let systemFieldsData = ckRecord.encodedSystemFields
      let values = ProfileRecord.fieldValues(from: ckRecord)
      let descriptor = FetchDescriptor<ProfileRecord>(
        predicate: #Predicate { $0.id == profileId }
      )
      if let existing = fetchOrLog(descriptor, context: context).first {
        existing.label = values.label
        existing.currencyCode = values.currencyCode
        existing.financialYearStartMonth = values.financialYearStartMonth
        existing.createdAt = values.createdAt
        existing.encodedSystemFields = systemFieldsData
      } else {
        values.encodedSystemFields = systemFieldsData
        context.insert(values)
      }
    }

    for recordID in deleted {
      guard let profileId = recordID.uuid else { continue }
      let descriptor = FetchDescriptor<ProfileRecord>(
        predicate: #Predicate { $0.id == profileId }
      )
      if let existing = fetchOrLog(descriptor, context: context).first {
        context.delete(existing)
      }
    }

    do {
      try context.save()
      return .success(changedTypes: Set(saved.map(\.recordType)))
    } catch {
      logger.error("Failed to save remote profile changes: \(error)")
      return .saveFailed(error.localizedDescription)
    }
  }

  // MARK: - Building CKRecords

  /// Builds a CKRecord from a local ProfileRecord for upload.
  /// If cached system fields exist on the model, applies fields directly onto the
  /// cached record to preserve the change tag and avoid `.serverRecordChanged` conflicts.
  func buildCKRecord(for record: ProfileRecord) -> CKRecord {
    let freshRecord = record.toCKRecord(in: zoneID)
    if let cachedData = record.encodedSystemFields,
      let cachedRecord = CKRecord.fromEncodedSystemFields(cachedData)
    {
      for key in freshRecord.allKeys() {
        cachedRecord[key] = freshRecord[key]
      }
      return cachedRecord
    }
    return freshRecord
  }

  // MARK: - Record Lookup for Upload

  /// Looks up a ProfileRecord by CKRecord.ID and builds a CKRecord for upload.
  func recordToSave(for recordID: CKRecord.ID) -> CKRecord? {
    guard let profileId = recordID.uuid else { return nil }
    let context = ModelContext(modelContainer)
    let descriptor = FetchDescriptor<ProfileRecord>(
      predicate: #Predicate { $0.id == profileId }
    )
    guard let record = fetchOrLog(descriptor, context: context).first else { return nil }
    return buildCKRecord(for: record)
  }

  // MARK: - Queue All Existing Records

  /// Scans all ProfileRecords in the local store and returns their CKRecord.IDs.
  /// Called on first start when there's no saved sync state.
  /// Returns record IDs for the coordinator to queue.
  func queueAllExistingRecords() -> [CKRecord.ID] {
    let context = ModelContext(modelContainer)
    let descriptor = FetchDescriptor<ProfileRecord>()
    let records = fetchOrLog(descriptor, context: context)
    guard !records.isEmpty else { return [] }

    let recordIDs = records.map { record in
      CKRecord.ID(
        recordType: ProfileRecord.recordType, uuid: record.id, zoneID: zoneID)
    }
    logger.info("Collected \(recordIDs.count) existing profiles for upload")
    return recordIDs
  }

  // MARK: - Local Data Deletion

  /// Deletes all local ProfileRecords.
  /// Called on account sign-out, account switch, and zone deletion.
  func deleteLocalData() {
    let context = ModelContext(modelContainer)
    let records = fetchOrLog(FetchDescriptor<ProfileRecord>(), context: context)
    if !records.isEmpty {
      for record in records {
        context.delete(record)
      }
    }
    do {
      try context.save()
      logger.info("Deleted all local profile index data")
    } catch {
      logger.error("Failed to delete local profile data: \(error)")
    }
  }

  // MARK: - System Fields Management

  /// Clears encoded system fields on all ProfileRecords.
  /// Called on encrypted data reset where we keep data but must re-upload fresh.
  func clearAllSystemFields() {
    let context = ModelContext(modelContainer)
    let records = fetchOrLog(FetchDescriptor<ProfileRecord>(), context: context)
    if !records.isEmpty {
      for record in records {
        record.encodedSystemFields = nil
      }
      do {
        try context.save()
      } catch {
        logger.error("Failed to save cleared system fields: \(error)")
      }
    }
  }

  /// Updates `encodedSystemFields` on the ProfileRecord matching the given record ID.
  func updateEncodedSystemFields(_ recordID: CKRecord.ID, data: Data) {
    guard let profileId = recordID.uuid else { return }
    let context = ModelContext(modelContainer)
    let descriptor = FetchDescriptor<ProfileRecord>(
      predicate: #Predicate { $0.id == profileId }
    )
    if let record = fetchOrLog(descriptor, context: context).first {
      record.encodedSystemFields = data
      do {
        try context.save()
      } catch {
        logger.error("Failed to save updated system fields: \(error)")
      }
    }
  }

  /// Clears `encodedSystemFields` on the ProfileRecord matching the given record ID.
  /// Called on `.unknownItem` — the server deleted the record, so the stale change tag
  /// must be cleared so the next upload creates a fresh record.
  func clearEncodedSystemFields(_ recordID: CKRecord.ID) {
    guard let profileId = recordID.uuid else { return }
    let context = ModelContext(modelContainer)
    let descriptor = FetchDescriptor<ProfileRecord>(
      predicate: #Predicate { $0.id == profileId }
    )
    if let record = fetchOrLog(descriptor, context: context).first {
      record.encodedSystemFields = nil
      do {
        try context.save()
      } catch {
        logger.error("Failed to save cleared system fields for record: \(error)")
      }
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

  /// Persist updated CKRecord system fields onto matching `ProfileRecord` rows
  /// after a successful upload.
  private func persistSystemFields(for savedRecords: [CKRecord]) {
    guard !savedRecords.isEmpty else { return }
    let context = ModelContext(modelContainer)
    for saved in savedRecords {
      updateSystemFields(
        for: saved.recordID,
        context: context,
        to: saved.encodedSystemFields
      )
    }
    do {
      try context.save()
    } catch {
      logger.error("Failed to save system fields after upload: \(error)")
    }
  }

  /// Apply server-side system fields from conflicts, and clear system fields for
  /// records the server has already deleted.
  private func resolveSystemFields(for failures: SyncErrorRecovery.ClassifiedFailures) {
    guard !failures.conflicts.isEmpty || !failures.unknownItems.isEmpty else { return }
    let context = ModelContext(modelContainer)
    for (_, serverRecord) in failures.conflicts {
      updateSystemFields(
        for: serverRecord.recordID,
        context: context,
        to: serverRecord.encodedSystemFields
      )
    }
    for (recordID, _) in failures.unknownItems {
      updateSystemFields(
        for: recordID,
        context: context,
        to: nil
      )
    }
    do {
      try context.save()
    } catch {
      logger.error("Failed to save system fields after conflict resolution: \(error)")
    }
  }

  /// Look up a `ProfileRecord` by id string and replace its cached system fields.
  private func updateSystemFields(
    for recordID: CKRecord.ID,
    context: ModelContext,
    to data: Data?
  ) {
    guard let profileId = recordID.uuid else { return }
    let descriptor = FetchDescriptor<ProfileRecord>(
      predicate: #Predicate { $0.id == profileId }
    )
    if let record = fetchOrLog(descriptor, context: context).first {
      record.encodedSystemFields = data
    }
  }
}
