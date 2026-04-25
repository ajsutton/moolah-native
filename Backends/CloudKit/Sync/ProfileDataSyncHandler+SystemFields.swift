@preconcurrency import CloudKit
import Foundation
import SwiftData

extension ProfileDataSyncHandler {
  // MARK: - System Fields Management

  /// Clears `encodedSystemFields` on all model records in the local store.
  /// Called before re-uploading after an `encryptedDataReset`.
  func clearAllSystemFields() {
    let context = ModelContext(modelContainer)

    func clearAll<T: PersistentModel & SystemFieldsCacheable>(_ type: T.Type) {
      for record in Self.fetchOrLog(FetchDescriptor<T>(), context: context) {
        record.encodedSystemFields = nil
      }
    }

    clearAll(AccountRecord.self)
    clearAll(TransactionRecord.self)
    clearAll(TransactionLegRecord.self)
    clearAll(CategoryRecord.self)
    clearAll(EarmarkRecord.self)
    clearAll(EarmarkBudgetItemRecord.self)
    clearAll(InvestmentValueRecord.self)
    clearAll(InstrumentRecord.self)
    clearAll(CSVImportProfileRecord.self)
    clearAll(ImportRuleRecord.self)

    do {
      try context.save()
      logger.info("Cleared all system fields for profile \(self.profileId)")
    } catch {
      logger.error("Failed to save after clearing system fields: \(error, privacy: .public)")
    }
  }

  /// Applies (or clears, when `data` is nil) the encoded system fields on the UUID-keyed
  /// model record matching the given type. Returns `true` when a local row was found
  /// and mutated; `false` when the dispatch table has no entry for the record type or
  /// no local row matched the UUID.
  @discardableResult
  nonisolated static func setEncodedSystemFields(
    _ id: UUID, data: Data?, recordType: String, context: ModelContext
  ) -> Bool {
    guard let setter = systemFieldSetters[recordType] else { return false }
    return setter(id, data, context)
  }

  /// Applies (or clears, when `data` is nil) the encoded system fields on an
  /// `InstrumentRecord` identified by its string ID (e.g. "AUD", "ASX:BHP.AX").
  nonisolated static func setInstrumentSystemFields(
    _ id: String, data: Data?, context: ModelContext
  ) {
    let records = fetchOrLog(
      FetchDescriptor<InstrumentRecord>(predicate: #Predicate { $0.id == id }),
      context: context)
    records.first?.encodedSystemFields = data
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
    if !savedRecords.isEmpty {
      updateSystemFieldsForSaved(savedRecords)
    }

    let failures = SyncErrorRecovery.classify(
      failedSaves: failedSaves, failedDeletes: failedDeletes, logger: logger)

    if !failures.conflicts.isEmpty || !failures.unknownItems.isEmpty {
      updateSystemFieldsForFailures(
        conflicts: failures.conflicts, unknownItems: failures.unknownItems)
    }

    return failures
  }

  /// Writes each successfully-sent record's latest system fields back onto the
  /// matching local model row, then commits the write.
  private func updateSystemFieldsForSaved(_ savedRecords: [CKRecord]) {
    let context = ModelContext(modelContainer)
    for saved in savedRecords {
      applySystemFields(from: saved, in: context)
    }
    let hadChanges = context.hasChanges
    do {
      try context.save()
      logger.info(
        "Applied system fields for \(savedRecords.count) saved records (hadChanges=\(hadChanges))"
      )
    } catch {
      logger.error("Failed to save system fields after upload: \(error, privacy: .public)")
    }
  }

  /// Reconciles system fields after conflicts (adopt the server copy) and
  /// unknownItem failures (clear the stale cache so the record re-uploads as a
  /// fresh create).
  private func updateSystemFieldsForFailures(
    conflicts: [(recordID: CKRecord.ID, serverRecord: CKRecord)],
    unknownItems: [(recordID: CKRecord.ID, recordType: String)]
  ) {
    let context = ModelContext(modelContainer)
    for (_, serverRecord) in conflicts {
      applySystemFields(from: serverRecord, in: context)
    }
    for (recordID, recordType) in unknownItems {
      clearSystemFields(for: recordID, recordType: recordType, in: context)
    }
    do {
      try context.save()
    } catch {
      logger.error(
        "Failed to save system fields after conflict resolution: \(error, privacy: .public)")
    }
  }

  private func applySystemFields(from ckRecord: CKRecord, in context: ModelContext) {
    let data = ckRecord.encodedSystemFields
    // Dispatch by ckRecord.recordType — the authoritative type from the
    // server — rather than by parsing recordName. This avoids the
    // historical collision where two record types with colliding UUIDs
    // both matched the same recordName (issue #416).
    if ckRecord.recordType == InstrumentRecord.recordType {
      Self.setInstrumentSystemFields(
        ckRecord.recordID.systemFieldsKey, data: data, context: context)
      return
    }
    guard let uuid = ckRecord.recordID.uuid else {
      logger.warning(
        "applySystemFields: recordName \(ckRecord.recordID.recordName) has no UUID component for \(ckRecord.recordType)"
      )
      return
    }
    let applied = Self.setEncodedSystemFields(
      uuid, data: data, recordType: ckRecord.recordType, context: context)
    if !applied {
      logger.warning(
        "No local row to cache system fields for \(ckRecord.recordType) \(uuid.uuidString)"
      )
    }
  }

  private func clearSystemFields(
    for recordID: CKRecord.ID, recordType: String, in context: ModelContext
  ) {
    if recordType == InstrumentRecord.recordType {
      Self.setInstrumentSystemFields(
        recordID.systemFieldsKey, data: nil, context: context)
      return
    }
    guard let uuid = recordID.uuid else {
      logger.warning(
        "clearSystemFields: recordName \(recordID.recordName) has no UUID component for \(recordType)"
      )
      return
    }
    Self.setEncodedSystemFields(
      uuid, data: nil, recordType: recordType, context: context)
  }

  // MARK: - Dispatch Table

  /// Dispatch table mapping UUID-keyed record type strings to a closure that writes
  /// `encodedSystemFields` on the matching record. Replaces the former ten-case
  /// switch statement, keeping `setEncodedSystemFields` at cyclomatic complexity 1.
  nonisolated(unsafe) private static let systemFieldSetters:
    [String: (UUID, Data?, ModelContext) -> Bool] = [
      AccountRecord.recordType: { id, data, context in
        applyByUUID(AccountRecord.self, id: id, data: data, context: context)
      },
      TransactionRecord.recordType: { id, data, context in
        applyByUUID(TransactionRecord.self, id: id, data: data, context: context)
      },
      TransactionLegRecord.recordType: { id, data, context in
        applyByUUID(TransactionLegRecord.self, id: id, data: data, context: context)
      },
      CategoryRecord.recordType: { id, data, context in
        applyByUUID(CategoryRecord.self, id: id, data: data, context: context)
      },
      EarmarkRecord.recordType: { id, data, context in
        applyByUUID(EarmarkRecord.self, id: id, data: data, context: context)
      },
      EarmarkBudgetItemRecord.recordType: { id, data, context in
        applyByUUID(EarmarkBudgetItemRecord.self, id: id, data: data, context: context)
      },
      InvestmentValueRecord.recordType: { id, data, context in
        applyByUUID(InvestmentValueRecord.self, id: id, data: data, context: context)
      },
      CSVImportProfileRecord.recordType: { id, data, context in
        applyByUUID(CSVImportProfileRecord.self, id: id, data: data, context: context)
      },
      ImportRuleRecord.recordType: { id, data, context in
        applyByUUID(ImportRuleRecord.self, id: id, data: data, context: context)
      },
    ]

  /// Fetches the local row matching `id` and assigns `data` to its cached system
  /// fields. Returns `true` when a row was found (and mutated), `false` when the
  /// fetch returned empty. Shared helper so `systemFieldSetters` can signal
  /// missing-row outcomes without repeating the two-line body per case.
  nonisolated private static func applyByUUID<T>(
    _ type: T.Type, id: UUID, data: Data?, context: ModelContext
  ) -> Bool
  where T: PersistentModel & IdentifiableRecord & SystemFieldsCacheable {
    let records = fetchOrLog(
      FetchDescriptor<T>(predicate: #Predicate { $0.id == id }),
      context: context)
    guard let record = records.first else { return false }
    record.encodedSystemFields = data
    return true
  }
}
