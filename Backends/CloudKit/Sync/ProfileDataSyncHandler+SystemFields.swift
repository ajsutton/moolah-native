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
      logger.error("Failed to save after clearing system fields: \(error)")
    }
  }

  /// Applies (or clears, when `data` is nil) the encoded system fields on the UUID-keyed
  /// model record matching the given type. Replaces the former `update`/`clear`
  /// per-UUID pair and reduces cyclomatic complexity by dispatching through
  /// `systemFieldSetters`.
  nonisolated static func setEncodedSystemFields(
    _ id: UUID, data: Data?, recordType: String, context: ModelContext
  ) {
    systemFieldSetters[recordType]?(id, data, context)
  }

  /// Applies (or clears, when `data` is nil) the encoded system fields on an
  /// `InstrumentRecord` identified by its string ID (e.g. "AUD", "ASX:BHP").
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
    do {
      try context.save()
    } catch {
      logger.error("Failed to save system fields after upload: \(error)")
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
      logger.error("Failed to save system fields after conflict resolution: \(error)")
    }
  }

  private func applySystemFields(from ckRecord: CKRecord, in context: ModelContext) {
    let recordName = ckRecord.recordID.recordName
    let data = ckRecord.encodedSystemFields
    if let uuid = UUID(uuidString: recordName) {
      Self.setEncodedSystemFields(
        uuid, data: data, recordType: ckRecord.recordType, context: context)
    } else {
      Self.setInstrumentSystemFields(recordName, data: data, context: context)
    }
  }

  private func clearSystemFields(
    for recordID: CKRecord.ID, recordType: String, in context: ModelContext
  ) {
    let recordName = recordID.recordName
    if let uuid = UUID(uuidString: recordName) {
      Self.setEncodedSystemFields(uuid, data: nil, recordType: recordType, context: context)
    } else {
      Self.setInstrumentSystemFields(recordName, data: nil, context: context)
    }
  }

  // MARK: - Dispatch Table

  /// Dispatch table mapping UUID-keyed record type strings to a closure that writes
  /// `encodedSystemFields` on the matching record. Replaces the former ten-case
  /// switch statement, keeping `setEncodedSystemFields` at cyclomatic complexity 1.
  nonisolated(unsafe) private static let systemFieldSetters:
    [String: (UUID, Data?, ModelContext) -> Void] = [
      AccountRecord.recordType: { id, data, context in
        let records = fetchOrLog(
          FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == id }),
          context: context)
        records.first?.encodedSystemFields = data
      },
      TransactionRecord.recordType: { id, data, context in
        let records = fetchOrLog(
          FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.id == id }),
          context: context)
        records.first?.encodedSystemFields = data
      },
      TransactionLegRecord.recordType: { id, data, context in
        let records = fetchOrLog(
          FetchDescriptor<TransactionLegRecord>(predicate: #Predicate { $0.id == id }),
          context: context)
        records.first?.encodedSystemFields = data
      },
      CategoryRecord.recordType: { id, data, context in
        let records = fetchOrLog(
          FetchDescriptor<CategoryRecord>(predicate: #Predicate { $0.id == id }),
          context: context)
        records.first?.encodedSystemFields = data
      },
      EarmarkRecord.recordType: { id, data, context in
        let records = fetchOrLog(
          FetchDescriptor<EarmarkRecord>(predicate: #Predicate { $0.id == id }),
          context: context)
        records.first?.encodedSystemFields = data
      },
      EarmarkBudgetItemRecord.recordType: { id, data, context in
        let records = fetchOrLog(
          FetchDescriptor<EarmarkBudgetItemRecord>(predicate: #Predicate { $0.id == id }),
          context: context)
        records.first?.encodedSystemFields = data
      },
      InvestmentValueRecord.recordType: { id, data, context in
        let records = fetchOrLog(
          FetchDescriptor<InvestmentValueRecord>(predicate: #Predicate { $0.id == id }),
          context: context)
        records.first?.encodedSystemFields = data
      },
      CSVImportProfileRecord.recordType: { id, data, context in
        let records = fetchOrLog(
          FetchDescriptor<CSVImportProfileRecord>(predicate: #Predicate { $0.id == id }),
          context: context)
        records.first?.encodedSystemFields = data
      },
      ImportRuleRecord.recordType: { id, data, context in
        let records = fetchOrLog(
          FetchDescriptor<ImportRuleRecord>(predicate: #Predicate { $0.id == id }),
          context: context)
        records.first?.encodedSystemFields = data
      },
    ]
}
