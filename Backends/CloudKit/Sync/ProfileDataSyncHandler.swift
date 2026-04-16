@preconcurrency import CloudKit
import Foundation
import OSLog
import SwiftData
import os

/// Result of applying remote changes from CKSyncEngine.
enum ApplyResult: Sendable {
  /// Changes saved successfully. Contains the set of changed record types.
  case success(changedTypes: Set<String>)
  /// context.save() failed. The coordinator should schedule a re-fetch.
  case saveFailed(String)
}

/// Stateless batch processing logic for a single profile's data zone.
/// Contains all data transformation, upsert, deletion, and record-building
/// logic with no CKSyncEngine dependency.
///
/// The coordinator owns the CKSyncEngine instance and delegates data processing
/// to this handler. Methods return results (changed types, record IDs, failures)
/// instead of directly interacting with CKSyncEngine state.
@MainActor
final class ProfileDataSyncHandler: Sendable {
  nonisolated let profileId: UUID
  nonisolated let zoneID: CKRecordZone.ID
  nonisolated let modelContainer: ModelContainer

  private nonisolated let logger = Logger(
    subsystem: "com.moolah.app", category: "ProfileDataSyncHandler")

  init(profileId: UUID, zoneID: CKRecordZone.ID, modelContainer: ModelContainer) {
    self.profileId = profileId
    self.zoneID = zoneID
    self.modelContainer = modelContainer
  }

  // MARK: - Applying Remote Changes

  /// Applies remote changes (inserts/updates/deletions) to the local SwiftData store.
  /// Creates a fresh ModelContext per call for isolation.
  /// Returns the set of changed record type strings.
  nonisolated func applyRemoteChanges(
    saved: [CKRecord],
    deleted: [(CKRecord.ID, String)],
    preExtractedSystemFields: [(String, Data)]? = nil
  ) -> ApplyResult {
    let batchStart = ContinuousClock.now

    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(
      .begin, log: Signposts.sync, name: "applyRemoteChanges", signpostID: signpostID,
      "%{public}d saves, %{public}d deletes", saved.count, deleted.count)
    defer {
      os_signpost(.end, log: Signposts.sync, name: "applyRemoteChanges", signpostID: signpostID)
    }

    let typeCounts = Dictionary(grouping: saved, by: { $0.recordType })
      .mapValues(\.count)
    logger.info("applyRemoteChanges: \(saved.count) saves \(typeCounts), \(deleted.count) deletes")

    // Build system fields lookup for batch upserts.
    var systemFields: [String: Data]
    if let preExtracted = preExtractedSystemFields {
      systemFields = Dictionary(preExtracted, uniquingKeysWith: { _, last in last })
    } else {
      systemFields = Dictionary(
        uniqueKeysWithValues: saved.map { ($0.recordID.recordName, $0.encodedSystemFields) }
      )
    }

    let context = ModelContext(modelContainer)

    os_signpost(
      .begin, log: Signposts.sync, name: "applyBatchSaves", signpostID: signpostID,
      "%{public}d records", saved.count)
    let upsertStart = ContinuousClock.now
    Self.applyBatchSaves(saved, context: context, systemFields: systemFields)
    let upsertDuration = ContinuousClock.now - upsertStart
    os_signpost(.end, log: Signposts.sync, name: "applyBatchSaves", signpostID: signpostID)

    os_signpost(
      .begin, log: Signposts.sync, name: "applyBatchDeletions", signpostID: signpostID,
      "%{public}d records", deleted.count)
    Self.applyBatchDeletions(deleted, context: context)
    os_signpost(.end, log: Signposts.sync, name: "applyBatchDeletions", signpostID: signpostID)

    let changedTypes: Set<String>
    var saveDuration: Duration = .zero
    do {
      os_signpost(.begin, log: Signposts.sync, name: "contextSave", signpostID: signpostID)
      let saveStart = ContinuousClock.now
      try context.save()
      saveDuration = ContinuousClock.now - saveStart
      os_signpost(.end, log: Signposts.sync, name: "contextSave", signpostID: signpostID)
      changedTypes = Set(saved.map(\.recordType) + deleted.map(\.1))
    } catch {
      os_signpost(.end, log: Signposts.sync, name: "contextSave", signpostID: signpostID)
      logger.error("Failed to save remote changes: \(error)")
      return .saveFailed(error.localizedDescription)
    }

    // Log batch performance
    let batchDuration = ContinuousClock.now - batchStart
    let batchMs = batchDuration.inMilliseconds
    let upsertMs = upsertDuration.inMilliseconds
    let saveMs = saveDuration.inMilliseconds

    if batchMs > 100 {
      logger.info(
        """
        applyRemoteChanges took \(batchMs)ms \
        (upsert: \(upsertMs)ms, save: \(saveMs)ms, \(saved.count) saves, \(deleted.count) deletes)
        """)
    }

    return .success(changedTypes: changedTypes)
  }

  // MARK: - Building CKRecords

  /// Builds a CKRecord from a local SwiftData record for upload.
  /// If cached system fields exist for this record, applies fields directly onto the
  /// cached record to preserve the change tag and avoid `.serverRecordChanged` conflicts.
  func buildCKRecord<T: CloudKitRecordConvertible & SystemFieldsCacheable>(
    for record: T
  ) -> CKRecord {
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

  // MARK: - Batch Record Lookup

  /// Fetches records using the given descriptor, logging errors instead of silently discarding them.
  private func fetchOrLog<T: PersistentModel>(
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

  /// Looks up records by UUID for a batch of pending changes.
  /// Uses IN-predicate fetches per record type, pruning the remaining set after each type.
  func buildBatchRecordLookup(for uuids: Set<UUID>) -> [UUID: CKRecord] {
    let context = ModelContext(modelContainer)
    var lookup: [UUID: CKRecord] = [:]
    var remaining = uuids

    // Check most common types first (transactions and legs make up the majority)
    let ids = Array(remaining)
    let transactions = fetchOrLog(
      FetchDescriptor<TransactionRecord>(predicate: #Predicate { ids.contains($0.id) }),
      context: context)
    for r in transactions {
      lookup[r.id] = buildCKRecord(for: r)
      remaining.remove(r.id)
    }

    if !remaining.isEmpty {
      let rIds = Array(remaining)
      let legs = fetchOrLog(
        FetchDescriptor<TransactionLegRecord>(predicate: #Predicate { rIds.contains($0.id) }),
        context: context)
      for r in legs {
        lookup[r.id] = buildCKRecord(for: r)
        remaining.remove(r.id)
      }
    }

    if !remaining.isEmpty {
      let rIds = Array(remaining)
      let investmentValues = fetchOrLog(
        FetchDescriptor<InvestmentValueRecord>(predicate: #Predicate { rIds.contains($0.id) }),
        context: context)
      for r in investmentValues {
        lookup[r.id] = buildCKRecord(for: r)
        remaining.remove(r.id)
      }
    }

    if !remaining.isEmpty {
      let rIds = Array(remaining)
      let accounts = fetchOrLog(
        FetchDescriptor<AccountRecord>(predicate: #Predicate { rIds.contains($0.id) }),
        context: context)
      for r in accounts {
        lookup[r.id] = buildCKRecord(for: r)
        remaining.remove(r.id)
      }
    }

    if !remaining.isEmpty {
      let rIds = Array(remaining)
      let categories = fetchOrLog(
        FetchDescriptor<CategoryRecord>(predicate: #Predicate { rIds.contains($0.id) }),
        context: context)
      for r in categories {
        lookup[r.id] = buildCKRecord(for: r)
        remaining.remove(r.id)
      }
    }

    if !remaining.isEmpty {
      let rIds = Array(remaining)
      let earmarks = fetchOrLog(
        FetchDescriptor<EarmarkRecord>(predicate: #Predicate { rIds.contains($0.id) }),
        context: context)
      for r in earmarks {
        lookup[r.id] = buildCKRecord(for: r)
        remaining.remove(r.id)
      }
    }

    if !remaining.isEmpty {
      let rIds = Array(remaining)
      let budgetItems = fetchOrLog(
        FetchDescriptor<EarmarkBudgetItemRecord>(predicate: #Predicate { rIds.contains($0.id) }),
        context: context)
      for r in budgetItems {
        lookup[r.id] = buildCKRecord(for: r)
        remaining.remove(r.id)
      }
    }

    if !remaining.isEmpty {
      logger.warning(
        "Batch lookup: \(remaining.count) of \(uuids.count) records not found in local store")
    }

    return lookup
  }

  // MARK: - Record Lookup for Upload

  /// Looks up a single record by CKRecord.ID and builds a CKRecord for upload.
  /// Tries InstrumentRecord (string ID) first, then UUID-based types.
  func recordToSave(for recordID: CKRecord.ID) -> CKRecord? {
    let context = ModelContext(modelContainer)
    let recordName = recordID.recordName

    // InstrumentRecord uses String IDs (e.g. "AUD", "ASX:BHP"), not UUIDs.
    // Try it first before UUID-based lookups.
    if let record = fetchInstrument(id: recordName, context: context) {
      return buildCKRecord(for: record)
    }

    guard let uuid = UUID(uuidString: recordName) else {
      logger.warning("Could not find local record for non-UUID ID: \(recordName)")
      return nil
    }

    // Try each UUID-based record type until we find the one with this ID.
    if let record = fetchAccount(id: uuid, context: context) {
      return buildCKRecord(for: record)
    }
    if let record = fetchTransaction(id: uuid, context: context) {
      return buildCKRecord(for: record)
    }
    if let record = fetchTransactionLeg(id: uuid, context: context) {
      return buildCKRecord(for: record)
    }
    if let record = fetchCategory(id: uuid, context: context) {
      return buildCKRecord(for: record)
    }
    if let record = fetchEarmark(id: uuid, context: context) {
      return buildCKRecord(for: record)
    }
    if let record = fetchEarmarkBudgetItem(id: uuid, context: context) {
      return buildCKRecord(for: record)
    }
    if let record = fetchInvestmentValue(id: uuid, context: context) {
      return buildCKRecord(for: record)
    }

    logger.warning("Could not find local record for ID: \(recordName)")
    return nil
  }

  // MARK: - Queue All Existing Records

  /// Scans all record types in the local store and returns their CKRecord.IDs.
  /// Called on first start when there's no saved sync state.
  /// Returns record IDs in dependency order for the coordinator to queue.
  func queueAllExistingRecords() -> [CKRecord.ID] {
    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(
      .begin, log: Signposts.sync, name: "queueAllExistingRecords", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.sync, name: "queueAllExistingRecords", signpostID: signpostID)
    }

    var recordIDs: [CKRecord.ID] = []

    func collectIDs<T: PersistentModel>(_ type: T.Type, extract: (T) -> UUID) {
      let context = ModelContext(modelContainer)
      let records = fetchOrLog(FetchDescriptor<T>(), context: context)
      for r in records {
        let id = CKRecord.ID(recordName: extract(r).uuidString, zoneID: zoneID)
        recordIDs.append(id)
      }
    }

    func collectStringIDs<T: PersistentModel>(_ type: T.Type, extract: (T) -> String) {
      let context = ModelContext(modelContainer)
      let records = fetchOrLog(FetchDescriptor<T>(), context: context)
      for r in records {
        let id = CKRecord.ID(recordName: extract(r), zoneID: zoneID)
        recordIDs.append(id)
      }
    }

    // Queue in dependency order:
    // 1. Instruments (no dependencies)
    // 2. Categories (no dependencies)
    // 3. Accounts (no dependencies)
    // 4. Earmarks (reference instruments)
    // 5. Budget items (reference earmarks + categories + instruments)
    // 6. Investment values (reference accounts + instruments)
    // 7. Transactions (header only)
    // 8. Transaction legs (reference transactions, accounts, instruments)
    collectStringIDs(InstrumentRecord.self) { $0.id }
    collectIDs(CategoryRecord.self) { $0.id }
    collectIDs(AccountRecord.self) { $0.id }
    collectIDs(EarmarkRecord.self) { $0.id }
    collectIDs(EarmarkBudgetItemRecord.self) { $0.id }
    collectIDs(InvestmentValueRecord.self) { $0.id }
    collectIDs(TransactionRecord.self) { $0.id }
    collectIDs(TransactionLegRecord.self) { $0.id }

    if !recordIDs.isEmpty {
      logger.info("Collected \(recordIDs.count) existing records for upload")
    }

    return recordIDs
  }

  // MARK: - Local Data Deletion

  /// Deletes all local records for this profile's zone.
  /// Returns the set of all record type strings (for notification).
  func deleteLocalData() -> Set<String> {
    let context = ModelContext(modelContainer)

    func deleteAll<T: PersistentModel>(_ type: T.Type) {
      let records = fetchOrLog(FetchDescriptor<T>(), context: context)
      for record in records {
        context.delete(record)
      }
    }

    deleteAll(InstrumentRecord.self)
    deleteAll(AccountRecord.self)
    deleteAll(TransactionRecord.self)
    deleteAll(TransactionLegRecord.self)
    deleteAll(CategoryRecord.self)
    deleteAll(EarmarkRecord.self)
    deleteAll(EarmarkBudgetItemRecord.self)
    deleteAll(InvestmentValueRecord.self)

    do {
      try context.save()
      logger.info("Deleted all local data for profile \(self.profileId)")
      return Set(RecordTypeRegistry.allTypes.keys)
    } catch {
      logger.error("Failed to delete local data: \(error)")
      return []
    }
  }

  // MARK: - System Fields Management

  /// Clears `encodedSystemFields` on all model records in the local store.
  /// Called before re-uploading after an `encryptedDataReset`.
  func clearAllSystemFields() {
    let context = ModelContext(modelContainer)

    func clearAll<T: PersistentModel & SystemFieldsCacheable>(_ type: T.Type) {
      let records = fetchOrLog(FetchDescriptor<T>(), context: context)
      for record in records {
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

    do {
      try context.save()
      logger.info("Cleared all system fields for profile \(self.profileId)")
    } catch {
      logger.error("Failed to save after clearing system fields: \(error)")
    }
  }

  /// Updates `encodedSystemFields` on the model record matching the given UUID and type.
  nonisolated static func updateEncodedSystemFields(
    _ id: UUID, data: Data, recordType: String, context: ModelContext
  ) {
    switch recordType {
    case AccountRecord.recordType:
      if let record = fetchOrLog(
        FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == id }),
        context: context
      ).first {
        record.encodedSystemFields = data
      }
    case TransactionRecord.recordType:
      if let record = fetchOrLog(
        FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.id == id }),
        context: context
      ).first {
        record.encodedSystemFields = data
      }
    case TransactionLegRecord.recordType:
      if let record = fetchOrLog(
        FetchDescriptor<TransactionLegRecord>(predicate: #Predicate { $0.id == id }),
        context: context
      ).first {
        record.encodedSystemFields = data
      }
    case CategoryRecord.recordType:
      if let record = fetchOrLog(
        FetchDescriptor<CategoryRecord>(predicate: #Predicate { $0.id == id }),
        context: context
      ).first {
        record.encodedSystemFields = data
      }
    case EarmarkRecord.recordType:
      if let record = fetchOrLog(
        FetchDescriptor<EarmarkRecord>(predicate: #Predicate { $0.id == id }),
        context: context
      ).first {
        record.encodedSystemFields = data
      }
    case EarmarkBudgetItemRecord.recordType:
      if let record = fetchOrLog(
        FetchDescriptor<EarmarkBudgetItemRecord>(predicate: #Predicate { $0.id == id }),
        context: context
      ).first {
        record.encodedSystemFields = data
      }
    case InvestmentValueRecord.recordType:
      if let record = fetchOrLog(
        FetchDescriptor<InvestmentValueRecord>(predicate: #Predicate { $0.id == id }),
        context: context
      ).first {
        record.encodedSystemFields = data
      }
    default:
      break
    }
  }

  /// Updates `encodedSystemFields` on an InstrumentRecord matching the given string ID.
  nonisolated static func updateInstrumentSystemFields(
    _ id: String, data: Data, context: ModelContext
  ) {
    if let record = fetchOrLog(
      FetchDescriptor<InstrumentRecord>(predicate: #Predicate { $0.id == id }),
      context: context
    ).first {
      record.encodedSystemFields = data
    }
  }

  /// Clears `encodedSystemFields` on the model record matching the given UUID and type.
  nonisolated static func clearEncodedSystemFields(
    _ id: UUID, recordType: String, context: ModelContext
  ) {
    switch recordType {
    case AccountRecord.recordType:
      if let record = fetchOrLog(
        FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == id }),
        context: context
      ).first {
        record.encodedSystemFields = nil
      }
    case TransactionRecord.recordType:
      if let record = fetchOrLog(
        FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.id == id }),
        context: context
      ).first {
        record.encodedSystemFields = nil
      }
    case TransactionLegRecord.recordType:
      if let record = fetchOrLog(
        FetchDescriptor<TransactionLegRecord>(predicate: #Predicate { $0.id == id }),
        context: context
      ).first {
        record.encodedSystemFields = nil
      }
    case CategoryRecord.recordType:
      if let record = fetchOrLog(
        FetchDescriptor<CategoryRecord>(predicate: #Predicate { $0.id == id }),
        context: context
      ).first {
        record.encodedSystemFields = nil
      }
    case EarmarkRecord.recordType:
      if let record = fetchOrLog(
        FetchDescriptor<EarmarkRecord>(predicate: #Predicate { $0.id == id }),
        context: context
      ).first {
        record.encodedSystemFields = nil
      }
    case EarmarkBudgetItemRecord.recordType:
      if let record = fetchOrLog(
        FetchDescriptor<EarmarkBudgetItemRecord>(predicate: #Predicate { $0.id == id }),
        context: context
      ).first {
        record.encodedSystemFields = nil
      }
    case InvestmentValueRecord.recordType:
      if let record = fetchOrLog(
        FetchDescriptor<InvestmentValueRecord>(predicate: #Predicate { $0.id == id }),
        context: context
      ).first {
        record.encodedSystemFields = nil
      }
    default:
      break
    }
  }

  /// Clears `encodedSystemFields` on an InstrumentRecord matching the given string ID.
  nonisolated static func clearInstrumentSystemFields(
    _ id: String, context: ModelContext
  ) {
    if let record = fetchOrLog(
      FetchDescriptor<InstrumentRecord>(predicate: #Predicate { $0.id == id }),
      context: context
    ).first {
      record.encodedSystemFields = nil
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
    // Update system fields on model records after successful upload.
    if !savedRecords.isEmpty {
      let context = ModelContext(modelContainer)
      for saved in savedRecords {
        let recordName = saved.recordID.recordName
        if let uuid = UUID(uuidString: recordName) {
          Self.updateEncodedSystemFields(
            uuid, data: saved.encodedSystemFields,
            recordType: saved.recordType, context: context)
        } else {
          Self.updateInstrumentSystemFields(
            recordName, data: saved.encodedSystemFields, context: context)
        }
      }
      do {
        try context.save()
      } catch {
        logger.error("Failed to save system fields after upload: \(error)")
      }
    }

    // Classify failures
    let failures = SyncErrorRecovery.classify(
      failedSaves: failedSaves,
      failedDeletes: failedDeletes,
      logger: logger)

    // Handle system fields updates for conflicts and unknownItems
    if !failures.conflicts.isEmpty || !failures.unknownItems.isEmpty {
      let ctx = ModelContext(modelContainer)
      for (_, serverRecord) in failures.conflicts {
        let recordName = serverRecord.recordID.recordName
        if let uuid = UUID(uuidString: recordName) {
          Self.updateEncodedSystemFields(
            uuid, data: serverRecord.encodedSystemFields,
            recordType: serverRecord.recordType, context: ctx)
        } else {
          Self.updateInstrumentSystemFields(
            recordName, data: serverRecord.encodedSystemFields, context: ctx)
        }
      }
      for (recordID, recordType) in failures.unknownItems {
        let recordName = recordID.recordName
        if let uuid = UUID(uuidString: recordName) {
          Self.clearEncodedSystemFields(
            uuid, recordType: recordType, context: ctx)
        } else {
          Self.clearInstrumentSystemFields(recordName, context: ctx)
        }
      }
      do {
        try ctx.save()
      } catch {
        logger.error("Failed to save system fields after conflict resolution: \(error)")
      }
    }

    return failures
  }

  // MARK: - Batch Processing (Static)

  private nonisolated static let batchLogger = Logger(
    subsystem: "com.moolah.app", category: "ProfileDataSyncHandler")

  /// Static version of fetchOrLog for use in nonisolated static batch methods.
  private nonisolated static func fetchOrLog<T: PersistentModel>(
    _ descriptor: FetchDescriptor<T>,
    context: ModelContext
  ) -> [T] {
    do {
      return try context.fetch(descriptor)
    } catch {
      batchLogger.error("SwiftData fetch failed for \(T.self): \(error)")
      return []
    }
  }

  /// Groups saved records by type and batch-upserts each group.
  nonisolated static func applyBatchSaves(
    _ records: [CKRecord], context: ModelContext, systemFields: [String: Data]
  ) {
    let grouped = Dictionary(grouping: records, by: { $0.recordType })
    for (recordType, ckRecords) in grouped {
      switch recordType {
      case InstrumentRecord.recordType:
        batchUpsertInstruments(ckRecords, context: context, systemFields: systemFields)
      case AccountRecord.recordType:
        batchUpsertAccounts(ckRecords, context: context, systemFields: systemFields)
      case TransactionRecord.recordType:
        batchUpsertTransactions(ckRecords, context: context, systemFields: systemFields)
      case TransactionLegRecord.recordType:
        batchUpsertTransactionLegs(ckRecords, context: context, systemFields: systemFields)
      case CategoryRecord.recordType:
        batchUpsertCategories(ckRecords, context: context, systemFields: systemFields)
      case EarmarkRecord.recordType:
        batchUpsertEarmarks(ckRecords, context: context, systemFields: systemFields)
      case EarmarkBudgetItemRecord.recordType:
        batchUpsertEarmarkBudgetItems(ckRecords, context: context, systemFields: systemFields)
      case InvestmentValueRecord.recordType:
        batchUpsertInvestmentValues(ckRecords, context: context, systemFields: systemFields)
      case ProfileRecord.recordType:
        break  // Handled by ProfileIndexSyncHandler
      default:
        batchLogger.warning("applyBatchSaves: unknown record type '\(recordType)' — skipping")
      }
    }
  }

  /// Handles batch deletions. Groups by record type for one IN-predicate fetch per type.
  nonisolated static func applyBatchDeletions(
    _ deletions: [(CKRecord.ID, String)], context: ModelContext
  ) {
    var uuidGrouped: [String: [UUID]] = [:]
    var stringGrouped: [String: [String]] = [:]

    for (recordID, recordType) in deletions {
      if let uuid = UUID(uuidString: recordID.recordName) {
        uuidGrouped[recordType, default: []].append(uuid)
      } else {
        stringGrouped[recordType, default: []].append(recordID.recordName)
      }
    }

    for (recordType, ids) in uuidGrouped {
      switch recordType {
      case AccountRecord.recordType:
        let records = fetchOrLog(
          FetchDescriptor<AccountRecord>(predicate: #Predicate { ids.contains($0.id) }),
          context: context)
        for record in records { context.delete(record) }
      case TransactionRecord.recordType:
        let records = fetchOrLog(
          FetchDescriptor<TransactionRecord>(predicate: #Predicate { ids.contains($0.id) }),
          context: context)
        for record in records { context.delete(record) }
      case TransactionLegRecord.recordType:
        let records = fetchOrLog(
          FetchDescriptor<TransactionLegRecord>(predicate: #Predicate { ids.contains($0.id) }),
          context: context)
        for record in records { context.delete(record) }
      case CategoryRecord.recordType:
        let records = fetchOrLog(
          FetchDescriptor<CategoryRecord>(predicate: #Predicate { ids.contains($0.id) }),
          context: context)
        for record in records { context.delete(record) }
      case EarmarkRecord.recordType:
        let records = fetchOrLog(
          FetchDescriptor<EarmarkRecord>(predicate: #Predicate { ids.contains($0.id) }),
          context: context)
        for record in records { context.delete(record) }
      case EarmarkBudgetItemRecord.recordType:
        let records = fetchOrLog(
          FetchDescriptor<EarmarkBudgetItemRecord>(predicate: #Predicate { ids.contains($0.id) }),
          context: context)
        for record in records { context.delete(record) }
      case InvestmentValueRecord.recordType:
        let records = fetchOrLog(
          FetchDescriptor<InvestmentValueRecord>(predicate: #Predicate { ids.contains($0.id) }),
          context: context)
        for record in records { context.delete(record) }
      case ProfileRecord.recordType:
        break  // Handled by ProfileIndexSyncHandler
      default:
        batchLogger.warning(
          "applyBatchDeletions: unknown record type '\(recordType)' — skipping")
      }
    }

    for (recordType, names) in stringGrouped {
      switch recordType {
      case InstrumentRecord.recordType:
        let records = fetchOrLog(
          FetchDescriptor<InstrumentRecord>(predicate: #Predicate { names.contains($0.id) }),
          context: context)
        for record in records { context.delete(record) }
      default:
        batchLogger.warning(
          "applyBatchDeletions: unknown string-ID record type '\(recordType)' — skipping")
      }
    }
  }

  // MARK: - Per-Type Batch Upsert

  nonisolated private static func batchUpsertInstruments(
    _ ckRecords: [CKRecord], context: ModelContext, systemFields: [String: Data]
  ) {
    let pairs: [(String, CKRecord)] = ckRecords.map { ck in
      (ck.recordID.recordName, ck)
    }
    let existing = fetchOrLog(FetchDescriptor<InstrumentRecord>(), context: context)
    var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

    for (id, ckRecord) in pairs {
      let values = InstrumentRecord.fieldValues(from: ckRecord)
      if let existing = byID[id] {
        existing.kind = values.kind
        existing.name = values.name
        existing.decimals = values.decimals
        existing.ticker = values.ticker
        existing.exchange = values.exchange
        existing.chainId = values.chainId
        existing.contractAddress = values.contractAddress
        existing.encodedSystemFields = systemFields[id]
      } else {
        values.encodedSystemFields = systemFields[id]
        context.insert(values)
        byID[id] = values
      }
    }
  }

  nonisolated private static func batchUpsertAccounts(
    _ ckRecords: [CKRecord], context: ModelContext, systemFields: [String: Data]
  ) {
    let pairs: [(UUID, CKRecord)] = ckRecords.compactMap { ck in
      guard let id = UUID(uuidString: ck.recordID.recordName) else { return nil }
      return (id, ck)
    }
    let existing: [AccountRecord]
    do {
      existing = try context.fetch(FetchDescriptor<AccountRecord>())
    } catch {
      batchLogger.error("batchUpsertAccounts: fetch failed: \(error)")
      existing = []
    }
    var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
    var insertCount = 0
    var updateCount = 0

    for (id, ckRecord) in pairs {
      let values = AccountRecord.fieldValues(from: ckRecord)
      if let existing = byID[id] {
        existing.name = values.name
        existing.type = values.type
        existing.instrumentId = values.instrumentId
        existing.position = values.position
        existing.isHidden = values.isHidden
        existing.encodedSystemFields = systemFields[id.uuidString]
        updateCount += 1
      } else {
        values.encodedSystemFields = systemFields[id.uuidString]
        context.insert(values)
        byID[id] = values
        insertCount += 1
      }
    }
    batchLogger.info(
      "batchUpsertAccounts: \(pairs.count) incoming, \(existing.count) existing in store, \(insertCount) inserted, \(updateCount) updated"
    )
  }

  nonisolated private static func batchUpsertTransactions(
    _ ckRecords: [CKRecord], context: ModelContext, systemFields: [String: Data]
  ) {
    let pairs: [(UUID, CKRecord)] = ckRecords.compactMap { ck in
      guard let id = UUID(uuidString: ck.recordID.recordName) else { return nil }
      return (id, ck)
    }
    let existing = fetchOrLog(FetchDescriptor<TransactionRecord>(), context: context)
    var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

    for (id, ckRecord) in pairs {
      let values = TransactionRecord.fieldValues(from: ckRecord)
      if let existing = byID[id] {
        existing.date = values.date
        existing.payee = values.payee
        existing.notes = values.notes
        existing.recurPeriod = values.recurPeriod
        existing.recurEvery = values.recurEvery
        existing.encodedSystemFields = systemFields[id.uuidString]
      } else {
        values.encodedSystemFields = systemFields[id.uuidString]
        context.insert(values)
        byID[id] = values
      }
    }
  }

  nonisolated private static func batchUpsertTransactionLegs(
    _ ckRecords: [CKRecord], context: ModelContext, systemFields: [String: Data]
  ) {
    let pairs: [(UUID, CKRecord)] = ckRecords.compactMap { ck in
      guard let id = UUID(uuidString: ck.recordID.recordName) else { return nil }
      return (id, ck)
    }
    let existing = fetchOrLog(FetchDescriptor<TransactionLegRecord>(), context: context)
    var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

    for (id, ckRecord) in pairs {
      let values = TransactionLegRecord.fieldValues(from: ckRecord)
      if let existing = byID[id] {
        existing.transactionId = values.transactionId
        existing.accountId = values.accountId
        existing.instrumentId = values.instrumentId
        existing.quantity = values.quantity
        existing.type = values.type
        existing.categoryId = values.categoryId
        existing.earmarkId = values.earmarkId
        existing.sortOrder = values.sortOrder
        existing.encodedSystemFields = systemFields[id.uuidString]
      } else {
        values.encodedSystemFields = systemFields[id.uuidString]
        context.insert(values)
        byID[id] = values
      }
    }
  }

  nonisolated private static func batchUpsertCategories(
    _ ckRecords: [CKRecord], context: ModelContext, systemFields: [String: Data]
  ) {
    let pairs: [(UUID, CKRecord)] = ckRecords.compactMap { ck in
      guard let id = UUID(uuidString: ck.recordID.recordName) else { return nil }
      return (id, ck)
    }
    let existing = fetchOrLog(FetchDescriptor<CategoryRecord>(), context: context)
    var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

    for (id, ckRecord) in pairs {
      let values = CategoryRecord.fieldValues(from: ckRecord)
      if let existing = byID[id] {
        existing.name = values.name
        existing.parentId = values.parentId
        existing.encodedSystemFields = systemFields[id.uuidString]
      } else {
        values.encodedSystemFields = systemFields[id.uuidString]
        context.insert(values)
        byID[id] = values
      }
    }
  }

  nonisolated private static func batchUpsertEarmarks(
    _ ckRecords: [CKRecord], context: ModelContext, systemFields: [String: Data]
  ) {
    let pairs: [(UUID, CKRecord)] = ckRecords.compactMap { ck in
      guard let id = UUID(uuidString: ck.recordID.recordName) else { return nil }
      return (id, ck)
    }
    let existing = fetchOrLog(FetchDescriptor<EarmarkRecord>(), context: context)
    var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

    for (id, ckRecord) in pairs {
      let values = EarmarkRecord.fieldValues(from: ckRecord)
      if let existing = byID[id] {
        existing.name = values.name
        existing.position = values.position
        existing.isHidden = values.isHidden
        existing.savingsTarget = values.savingsTarget
        existing.savingsTargetInstrumentId = values.savingsTargetInstrumentId
        existing.savingsStartDate = values.savingsStartDate
        existing.savingsEndDate = values.savingsEndDate
        existing.encodedSystemFields = systemFields[id.uuidString]
      } else {
        values.encodedSystemFields = systemFields[id.uuidString]
        context.insert(values)
        byID[id] = values
      }
    }
  }

  nonisolated private static func batchUpsertEarmarkBudgetItems(
    _ ckRecords: [CKRecord], context: ModelContext, systemFields: [String: Data]
  ) {
    let pairs: [(UUID, CKRecord)] = ckRecords.compactMap { ck in
      guard let id = UUID(uuidString: ck.recordID.recordName) else { return nil }
      return (id, ck)
    }
    let existing = fetchOrLog(FetchDescriptor<EarmarkBudgetItemRecord>(), context: context)
    var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

    for (id, ckRecord) in pairs {
      let values = EarmarkBudgetItemRecord.fieldValues(from: ckRecord)
      if let existing = byID[id] {
        existing.earmarkId = values.earmarkId
        existing.categoryId = values.categoryId
        existing.amount = values.amount
        existing.instrumentId = values.instrumentId
        existing.encodedSystemFields = systemFields[id.uuidString]
      } else {
        values.encodedSystemFields = systemFields[id.uuidString]
        context.insert(values)
        byID[id] = values
      }
    }
  }

  nonisolated private static func batchUpsertInvestmentValues(
    _ ckRecords: [CKRecord], context: ModelContext, systemFields: [String: Data]
  ) {
    let pairs: [(UUID, CKRecord)] = ckRecords.compactMap { ck in
      guard let id = UUID(uuidString: ck.recordID.recordName) else { return nil }
      return (id, ck)
    }
    let existing = fetchOrLog(FetchDescriptor<InvestmentValueRecord>(), context: context)
    var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

    for (id, ckRecord) in pairs {
      let values = InvestmentValueRecord.fieldValues(from: ckRecord)
      if let existing = byID[id] {
        existing.accountId = values.accountId
        existing.date = values.date
        existing.value = values.value
        existing.instrumentId = values.instrumentId
        existing.encodedSystemFields = systemFields[id.uuidString]
      } else {
        values.encodedSystemFields = systemFields[id.uuidString]
        context.insert(values)
        byID[id] = values
      }
    }
  }

  // MARK: - Per-Type Fetch Methods

  private func fetchAccount(id: UUID, context: ModelContext) -> AccountRecord? {
    let descriptor = FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == id })
    return fetchOrLog(descriptor, context: context).first
  }

  private func fetchTransaction(id: UUID, context: ModelContext) -> TransactionRecord? {
    let descriptor = FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.id == id })
    return fetchOrLog(descriptor, context: context).first
  }

  private func fetchCategory(id: UUID, context: ModelContext) -> CategoryRecord? {
    let descriptor = FetchDescriptor<CategoryRecord>(predicate: #Predicate { $0.id == id })
    return fetchOrLog(descriptor, context: context).first
  }

  private func fetchEarmark(id: UUID, context: ModelContext) -> EarmarkRecord? {
    let descriptor = FetchDescriptor<EarmarkRecord>(predicate: #Predicate { $0.id == id })
    return fetchOrLog(descriptor, context: context).first
  }

  private func fetchEarmarkBudgetItem(id: UUID, context: ModelContext) -> EarmarkBudgetItemRecord? {
    let descriptor = FetchDescriptor<EarmarkBudgetItemRecord>(
      predicate: #Predicate { $0.id == id })
    return fetchOrLog(descriptor, context: context).first
  }

  private func fetchInvestmentValue(id: UUID, context: ModelContext) -> InvestmentValueRecord? {
    let descriptor = FetchDescriptor<InvestmentValueRecord>(predicate: #Predicate { $0.id == id })
    return fetchOrLog(descriptor, context: context).first
  }

  private func fetchInstrument(id: String, context: ModelContext) -> InstrumentRecord? {
    let descriptor = FetchDescriptor<InstrumentRecord>(predicate: #Predicate { $0.id == id })
    return fetchOrLog(descriptor, context: context).first
  }

  private func fetchTransactionLeg(id: UUID, context: ModelContext) -> TransactionLegRecord? {
    let descriptor = FetchDescriptor<TransactionLegRecord>(predicate: #Predicate { $0.id == id })
    return fetchOrLog(descriptor, context: context).first
  }
}
