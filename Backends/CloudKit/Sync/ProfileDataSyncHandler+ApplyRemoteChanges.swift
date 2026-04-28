// swiftlint:disable multiline_arguments

@preconcurrency import CloudKit
import Foundation
import OSLog
import SwiftData
import os

extension ProfileDataSyncHandler {
  // MARK: - Applying Remote Changes

  /// Applies remote changes (inserts/updates/deletions) to the local SwiftData store.
  /// Creates a fresh ModelContext per call for isolation.
  /// Returns the set of changed record type strings.
  nonisolated func applyRemoteChanges(
    saved: [CKRecord],
    deleted: [(CKRecord.ID, String)],
    preExtractedSystemFields: [(String, Data)] = []
  ) -> ApplyResult {
    let batchStart = ContinuousClock.now
    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(
      .begin, log: Signposts.sync, name: "applyRemoteChanges", signpostID: signpostID,
      "%{public}d saves, %{public}d deletes", saved.count, deleted.count)
    defer {
      os_signpost(.end, log: Signposts.sync, name: "applyRemoteChanges", signpostID: signpostID)
    }

    logIncomingBatch(saved: saved, deleted: deleted)

    let systemFields = Self.systemFieldsLookup(
      saved: saved, preExtracted: preExtractedSystemFields)
    let context = ModelContext(modelContainer)

    os_signpost(
      .begin, log: Signposts.sync, name: "applyBatchSaves", signpostID: signpostID,
      "%{public}d records", saved.count)
    let upsertStart = ContinuousClock.now
    applyBatchSaves(saved, context: context, systemFields: systemFields)
    let upsertDuration = ContinuousClock.now - upsertStart
    os_signpost(.end, log: Signposts.sync, name: "applyBatchSaves", signpostID: signpostID)

    os_signpost(
      .begin, log: Signposts.sync, name: "applyBatchDeletions", signpostID: signpostID,
      "%{public}d records", deleted.count)
    applyBatchDeletions(deleted, context: context)
    os_signpost(.end, log: Signposts.sync, name: "applyBatchDeletions", signpostID: signpostID)

    do {
      os_signpost(.begin, log: Signposts.sync, name: "contextSave", signpostID: signpostID)
      let saveStart = ContinuousClock.now
      try context.save()
      let saveDuration = ContinuousClock.now - saveStart
      os_signpost(.end, log: Signposts.sync, name: "contextSave", signpostID: signpostID)
      logBatchDuration(
        batchStart: batchStart, upsertDuration: upsertDuration, saveDuration: saveDuration,
        saveCount: saved.count, deleteCount: deleted.count)
      let changedTypes = Set(saved.map(\.recordType) + deleted.map(\.1))
      // Fan out the instrument-touched signal exactly once per batch (not per
      // record). Picker UIs subscribe to the registry's `observeChanges()`
      // stream, which is local-write-driven; without this hop a token
      // registered on another device would not surface until the next app
      // launch. Fired only after a successful `context.save()` so observers
      // never see speculative state.
      if changedTypes.contains(InstrumentRecord.recordType) {
        onInstrumentRemoteChange()
      }
      return .success(changedTypes: changedTypes)
    } catch {
      os_signpost(.end, log: Signposts.sync, name: "contextSave", signpostID: signpostID)
      logger.error("Failed to save remote changes: \(error, privacy: .public)")
      return .saveFailed(error.localizedDescription)
    }
  }

  // MARK: - Batch Processing

  /// Groups saved records by type and batch-upserts each group. Dispatch is driven by
  /// `batchUpserters` to keep cyclomatic complexity at 1; record types covered by the
  /// GRDB migration short-circuit through `grdbRepositories` instead of SwiftData.
  nonisolated func applyBatchSaves(
    _ records: [CKRecord], context: ModelContext, systemFields: [String: Data]
  ) {
    let grouped = Dictionary(grouping: records, by: \.recordType)
    for (recordType, ckRecords) in grouped {
      if applyGRDBBatchSave(
        recordType: recordType, ckRecords: ckRecords, systemFields: systemFields)
      {
        continue
      }
      if let upsert = Self.batchUpserters[recordType] {
        upsert(ckRecords, context, systemFields)
      } else if recordType != ProfileRecord.recordType {
        // ProfileRecord is handled by ProfileIndexSyncHandler.
        Self.batchLogger.warning(
          "applyBatchSaves: unknown record type '\(recordType)' — skipping")
      }
    }
  }

  /// Handles batch deletions. Groups by record type for one IN-predicate fetch per type,
  /// then dispatches via `uuidDeleters` (or the string-keyed instrument deleter).
  nonisolated func applyBatchDeletions(
    _ deletions: [(CKRecord.ID, String)], context: ModelContext
  ) {
    var uuidGrouped: [String: [UUID]] = [:]
    var stringGrouped: [String: [String]] = [:]

    for (recordID, recordType) in deletions {
      if let uuid = recordID.uuid {
        uuidGrouped[recordType, default: []].append(uuid)
      } else {
        stringGrouped[recordType, default: []].append(recordID.recordName)
      }
    }

    for (recordType, ids) in uuidGrouped {
      if applyGRDBBatchDeletion(recordType: recordType, ids: ids) {
        continue
      }
      Self.dispatchUUIDDeletion(recordType: recordType, ids: ids, context: context)
    }
    for (recordType, names) in stringGrouped {
      Self.dispatchStringDeletion(recordType: recordType, names: names, context: context)
    }
  }

  /// Routes a per-record-type batch through the GRDB repos when the type
  /// has been migrated. Returns `true` when the dispatch was handled here
  /// (caller skips the SwiftData path for this group), `false` for
  /// SwiftData-managed types.
  nonisolated private func applyGRDBBatchSave(
    recordType: String,
    ckRecords: [CKRecord],
    systemFields: [String: Data]
  ) -> Bool {
    switch recordType {
    case CSVImportProfileRow.recordType:
      let rows = ckRecords.compactMap { ckRecord -> CSVImportProfileRow? in
        guard var row = CSVImportProfileRow.fieldValues(from: ckRecord) else {
          Self.logMalformed("applyGRDBBatchSave[CSVImportProfile]", ckRecord)
          return nil
        }
        row.encodedSystemFields = systemFields[row.id.uuidString]
        return row
      }
      do {
        try grdbRepositories.csvImportProfiles.applyRemoteChangesSync(
          saved: rows, deleted: [])
      } catch {
        Self.batchLogger.error(
          """
          applyGRDBBatchSave[CSVImportProfile] failed: \
          \(error.localizedDescription, privacy: .public)
          """)
      }
      return true
    case ImportRuleRow.recordType:
      let rows = ckRecords.compactMap { ckRecord -> ImportRuleRow? in
        guard var row = ImportRuleRow.fieldValues(from: ckRecord) else {
          Self.logMalformed("applyGRDBBatchSave[ImportRule]", ckRecord)
          return nil
        }
        row.encodedSystemFields = systemFields[row.id.uuidString]
        return row
      }
      do {
        try grdbRepositories.importRules.applyRemoteChangesSync(
          saved: rows, deleted: [])
      } catch {
        Self.batchLogger.error(
          """
          applyGRDBBatchSave[ImportRule] failed: \
          \(error.localizedDescription, privacy: .public)
          """)
      }
      return true
    default:
      return false
    }
  }

  nonisolated private func applyGRDBBatchDeletion(
    recordType: String, ids: [UUID]
  ) -> Bool {
    switch recordType {
    case CSVImportProfileRow.recordType:
      do {
        try grdbRepositories.csvImportProfiles.applyRemoteChangesSync(
          saved: [], deleted: ids)
      } catch {
        Self.batchLogger.error(
          """
          applyGRDBBatchDeletion[CSVImportProfile] failed: \
          \(error.localizedDescription, privacy: .public)
          """)
      }
      return true
    case ImportRuleRow.recordType:
      do {
        try grdbRepositories.importRules.applyRemoteChangesSync(
          saved: [], deleted: ids)
      } catch {
        Self.batchLogger.error(
          """
          applyGRDBBatchDeletion[ImportRule] failed: \
          \(error.localizedDescription, privacy: .public)
          """)
      }
      return true
    default:
      return false
    }
  }

  /// Logs a malformed incoming CKRecord at error level so the skip is
  /// visible in diagnostics rather than silently dropped. Mirror of the
  /// SwiftData-path helper so GRDB and SwiftData log lines look uniform.
  nonisolated static func logMalformed(_ site: String, _ ckRecord: CKRecord) {
    batchLogger.error(
      "\(site): malformed recordID '\(ckRecord.recordID.recordName)' (recordType \(ckRecord.recordType)) — skipping"
    )
  }

  // MARK: - Private Helpers

  nonisolated static func dispatchUUIDDeletion(
    recordType: String, ids: [UUID], context: ModelContext
  ) {
    if let delete = uuidDeleters[recordType] {
      delete(ids, context)
    } else if recordType != ProfileRecord.recordType {
      // ProfileRecord is handled by ProfileIndexSyncHandler.
      batchLogger.warning("applyBatchDeletions: unknown record type '\(recordType)' — skipping")
    }
  }

  nonisolated static func dispatchStringDeletion(
    recordType: String, names: [String], context: ModelContext
  ) {
    if recordType == InstrumentRecord.recordType {
      let records = fetchOrLog(
        FetchDescriptor<InstrumentRecord>(predicate: #Predicate { names.contains($0.id) }),
        context: context)
      for record in records { context.delete(record) }
    } else {
      batchLogger.warning(
        "applyBatchDeletions: unknown string-ID record type '\(recordType)' — skipping")
    }
  }

  /// Builds the record-name → encoded-system-fields lookup used for batch upserts.
  /// When `preExtracted` has entries the caller has already done the extraction (and
  /// filtering) and we use it directly; otherwise we synthesise it from `saved`.
  nonisolated private static func systemFieldsLookup(
    saved: [CKRecord], preExtracted: [(String, Data)]
  ) -> [String: Data] {
    // Both sources key by recordName, but the batchUpsertX methods look up
    // by uuid.uuidString (for UUID records) or record.id (for instruments) —
    // never by the full prefixed recordName. Normalize via the shared
    // `CKRecordIDRecordName.systemFieldsKey(for:)` helper so the downstream
    // lookup works for both the new and legacy recordName formats.
    let keyFor = CKRecordIDRecordName.systemFieldsKey(for:)
    if !preExtracted.isEmpty {
      return Dictionary(
        preExtracted.map { (keyFor($0.0), $0.1) },
        uniquingKeysWith: { _, last in last })
    }
    return Dictionary(
      uniqueKeysWithValues: saved.map {
        ($0.recordID.systemFieldsKey, $0.encodedSystemFields)
      }
    )
  }

  nonisolated private func logIncomingBatch(
    saved: [CKRecord], deleted: [(CKRecord.ID, String)]
  ) {
    let typeCounts = Dictionary(grouping: saved, by: \.recordType).mapValues(\.count)
    logger.info("applyRemoteChanges: \(saved.count) saves \(typeCounts), \(deleted.count) deletes")
  }

  nonisolated private func logBatchDuration(
    batchStart: ContinuousClock.Instant,
    upsertDuration: Duration,
    saveDuration: Duration,
    saveCount: Int,
    deleteCount: Int
  ) {
    let batchMs = (ContinuousClock.now - batchStart).inMilliseconds
    guard batchMs > 100 else { return }
    let upsertMs = upsertDuration.inMilliseconds
    let saveMs = saveDuration.inMilliseconds
    logger.info(
      """
      applyRemoteChanges took \(batchMs)ms \
      (upsert: \(upsertMs)ms, save: \(saveMs)ms, \(saveCount) saves, \(deleteCount) deletes)
      """)
  }

  // MARK: - Delete Dispatch Table

  /// Dispatch table mapping UUID-keyed record type strings to a batch deletion closure.
  /// Keeps `applyBatchDeletions` cyclomatic complexity at 1 by replacing the former
  /// nine-case switch.
  nonisolated(unsafe) private static let uuidDeleters: [String: ([UUID], ModelContext) -> Void] = [
    AccountRecord.recordType: { ids, context in
      let records = fetchOrLog(
        FetchDescriptor<AccountRecord>(predicate: #Predicate { ids.contains($0.id) }),
        context: context)
      for record in records { context.delete(record) }
    },
    TransactionRecord.recordType: { ids, context in
      let records = fetchOrLog(
        FetchDescriptor<TransactionRecord>(predicate: #Predicate { ids.contains($0.id) }),
        context: context)
      for record in records { context.delete(record) }
    },
    TransactionLegRecord.recordType: { ids, context in
      let records = fetchOrLog(
        FetchDescriptor<TransactionLegRecord>(predicate: #Predicate { ids.contains($0.id) }),
        context: context)
      for record in records { context.delete(record) }
    },
    CategoryRecord.recordType: { ids, context in
      let records = fetchOrLog(
        FetchDescriptor<CategoryRecord>(predicate: #Predicate { ids.contains($0.id) }),
        context: context)
      for record in records { context.delete(record) }
    },
    EarmarkRecord.recordType: { ids, context in
      let records = fetchOrLog(
        FetchDescriptor<EarmarkRecord>(predicate: #Predicate { ids.contains($0.id) }),
        context: context)
      for record in records { context.delete(record) }
    },
    EarmarkBudgetItemRecord.recordType: { ids, context in
      let records = fetchOrLog(
        FetchDescriptor<EarmarkBudgetItemRecord>(predicate: #Predicate { ids.contains($0.id) }),
        context: context)
      for record in records { context.delete(record) }
    },
    InvestmentValueRecord.recordType: { ids, context in
      let records = fetchOrLog(
        FetchDescriptor<InvestmentValueRecord>(predicate: #Predicate { ids.contains($0.id) }),
        context: context)
      for record in records { context.delete(record) }
    },
    // CSVImportProfileRow + ImportRuleRow live in GRDB; their deletes are
    // dispatched via `applyGRDBBatchDeletion` before this table is
    // consulted.
  ]

  // MARK: - Upsert Dispatch Table

  /// Dispatch table mapping record type strings to a per-type batch upsert closure.
  /// Keeps `applyBatchSaves` cyclomatic complexity at 1 by replacing the former
  /// ten-case switch.
  nonisolated(unsafe) static let batchUpserters:
    [String: ([CKRecord], ModelContext, [String: Data]) -> Void] = [
      InstrumentRecord.recordType: ProfileDataSyncHandler.batchUpsertInstruments,
      AccountRecord.recordType: ProfileDataSyncHandler.batchUpsertAccounts,
      TransactionRecord.recordType: ProfileDataSyncHandler.batchUpsertTransactions,
      TransactionLegRecord.recordType: ProfileDataSyncHandler.batchUpsertTransactionLegs,
      CategoryRecord.recordType: ProfileDataSyncHandler.batchUpsertCategories,
      EarmarkRecord.recordType: ProfileDataSyncHandler.batchUpsertEarmarks,
      EarmarkBudgetItemRecord.recordType: ProfileDataSyncHandler.batchUpsertEarmarkBudgetItems,
      InvestmentValueRecord.recordType: ProfileDataSyncHandler.batchUpsertInvestmentValues,
      // CSVImportProfileRow + ImportRuleRow live in GRDB; their upserts are
      // dispatched via `applyGRDBBatchSave` before this table is consulted.
    ]
}
