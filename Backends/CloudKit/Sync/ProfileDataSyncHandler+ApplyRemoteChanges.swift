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

    // GRDB-routed batches throw on write failure so CKSyncEngine refetches
    // instead of advancing past a dropped record (silent data loss). The
    // SwiftData branches still buffer in `context` and surface failure via
    // `context.save()` below.
    let upsertStart = ContinuousClock.now
    if let failure = runBatchSavesPhase(
      saved: saved, context: context, systemFields: systemFields, signpostID: signpostID)
    {
      return failure
    }
    let upsertDuration = ContinuousClock.now - upsertStart

    if let failure = runBatchDeletionsPhase(
      deleted: deleted, context: context, signpostID: signpostID)
    {
      return failure
    }

    return persistAndNotify(
      saved: saved,
      deleted: deleted,
      context: context,
      timing: BatchTiming(batchStart: batchStart, upsertDuration: upsertDuration),
      signpostID: signpostID)
  }

  /// Bundles per-batch timing markers so `persistAndNotify` stays under
  /// the SwiftLint parameter budget. Both fields are populated up front
  /// in `applyRemoteChanges`; treat as an inline value, not shared state.
  nonisolated struct BatchTiming {
    let batchStart: ContinuousClock.Instant
    let upsertDuration: Duration
  }

  /// Wraps `applyBatchSaves` in its signpost + signpost-on-throw cleanup
  /// and converts a thrown error into a `.saveFailed(...)` result.
  /// Returns `nil` on success so the caller falls through to the next
  /// phase. Extracted from `applyRemoteChanges` to keep that function
  /// inside the SwiftLint body-length budget.
  nonisolated private func runBatchSavesPhase(
    saved: [CKRecord],
    context: ModelContext,
    systemFields: [String: Data],
    signpostID: OSSignpostID
  ) -> ApplyResult? {
    os_signpost(
      .begin, log: Signposts.sync, name: "applyBatchSaves", signpostID: signpostID,
      "%{public}d records", saved.count)
    do {
      try applyBatchSaves(saved, context: context, systemFields: systemFields)
      os_signpost(.end, log: Signposts.sync, name: "applyBatchSaves", signpostID: signpostID)
      return nil
    } catch {
      os_signpost(.end, log: Signposts.sync, name: "applyBatchSaves", signpostID: signpostID)
      logger.error(
        """
        GRDB write failed during applyBatchSaves for profile \
        \(self.profileId, privacy: .public): \
        \(error.localizedDescription, privacy: .public)
        """)
      return .saveFailed(error.localizedDescription)
    }
  }

  /// Companion to `runBatchSavesPhase` for the deletions branch.
  nonisolated private func runBatchDeletionsPhase(
    deleted: [(CKRecord.ID, String)],
    context: ModelContext,
    signpostID: OSSignpostID
  ) -> ApplyResult? {
    os_signpost(
      .begin, log: Signposts.sync, name: "applyBatchDeletions", signpostID: signpostID,
      "%{public}d records", deleted.count)
    do {
      try applyBatchDeletions(deleted, context: context)
      os_signpost(.end, log: Signposts.sync, name: "applyBatchDeletions", signpostID: signpostID)
      return nil
    } catch {
      os_signpost(.end, log: Signposts.sync, name: "applyBatchDeletions", signpostID: signpostID)
      logger.error(
        """
        GRDB write failed during applyBatchDeletions for profile \
        \(self.profileId, privacy: .public): \
        \(error.localizedDescription, privacy: .public)
        """)
      return .saveFailed(error.localizedDescription)
    }
  }

  /// Commits the buffered SwiftData writes, fires the instrument observer
  /// hop on success, and reports timings. Returns `.saveFailed(...)` if
  /// `context.save()` throws.
  nonisolated private func persistAndNotify(
    saved: [CKRecord],
    deleted: [(CKRecord.ID, String)],
    context: ModelContext,
    timing: BatchTiming,
    signpostID: OSSignpostID
  ) -> ApplyResult {
    do {
      os_signpost(.begin, log: Signposts.sync, name: "contextSave", signpostID: signpostID)
      let saveStart = ContinuousClock.now
      try context.save()
      let saveDuration = ContinuousClock.now - saveStart
      os_signpost(.end, log: Signposts.sync, name: "contextSave", signpostID: signpostID)
      logBatchDuration(
        batchStart: timing.batchStart,
        upsertDuration: timing.upsertDuration,
        saveDuration: saveDuration,
        saveCount: saved.count,
        deleteCount: deleted.count)
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
  ///
  /// Throws when a GRDB-routed batch fails to write so the caller can return
  /// `.saveFailed(...)` and CKSyncEngine refetches instead of advancing past
  /// the dropped record (silent data loss). SwiftData branches still buffer
  /// in `context` and surface failures via `context.save()` upstream.
  nonisolated func applyBatchSaves(
    _ records: [CKRecord], context: ModelContext, systemFields: [String: Data]
  ) throws {
    let grouped = Dictionary(grouping: records, by: \.recordType)
    for (recordType, ckRecords) in grouped {
      if try applyGRDBBatchSave(
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
  ///
  /// Throws when a GRDB-routed deletion batch fails. See `applyBatchSaves`
  /// for the rationale: propagating the failure ensures CKSyncEngine
  /// refetches rather than dropping the deletion record silently.
  nonisolated func applyBatchDeletions(
    _ deletions: [(CKRecord.ID, String)], context: ModelContext
  ) throws {
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
      if try applyGRDBBatchDeletion(recordType: recordType, ids: ids) {
        continue
      }
      Self.dispatchUUIDDeletion(recordType: recordType, ids: ids, context: context)
    }
    for (recordType, names) in stringGrouped {
      Self.dispatchStringDeletion(recordType: recordType, names: names, context: context)
    }
  }

  // MARK: - Private Helpers

  nonisolated private static func dispatchUUIDDeletion(
    recordType: String, ids: [UUID], context: ModelContext
  ) {
    if let delete = uuidDeleters[recordType] {
      delete(ids, context)
    } else if recordType != ProfileRecord.recordType {
      // ProfileRecord is handled by ProfileIndexSyncHandler.
      batchLogger.warning("applyBatchDeletions: unknown record type '\(recordType)' — skipping")
    }
  }

  nonisolated private static func dispatchStringDeletion(
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
