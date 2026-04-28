@preconcurrency import CloudKit
import Foundation
import OSLog
import SwiftData
import os

extension ProfileDataSyncHandler {
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

    // Queue in dependency order:
    // 1. Instruments (no dependencies)
    // 2. Categories (no dependencies)
    // 3. Accounts (no dependencies)
    // 4. Earmarks (reference instruments)
    // 5. Budget items (reference earmarks + categories + instruments)
    // 6. Investment values (reference accounts + instruments)
    // 7. Transactions (header only)
    // 8. Transaction legs (reference transactions, accounts, instruments)
    // 9. CSV import profiles (reference accounts)
    // 10. Import rules (optionally reference accounts via accountScope)
    collectAllStringIDs(InstrumentRecord.self, into: &recordIDs) { $0.id }
    collectAllUUIDs(CategoryRecord.self, into: &recordIDs)
    collectAllUUIDs(AccountRecord.self, into: &recordIDs)
    collectAllUUIDs(EarmarkRecord.self, into: &recordIDs)
    collectAllUUIDs(EarmarkBudgetItemRecord.self, into: &recordIDs)
    collectAllUUIDs(InvestmentValueRecord.self, into: &recordIDs)
    collectAllUUIDs(TransactionRecord.self, into: &recordIDs)
    collectAllUUIDs(TransactionLegRecord.self, into: &recordIDs)
    collectAllGRDBUUIDs(
      ids: { try grdbRepositories.csvImportProfiles.allRowIdsSync() },
      recordType: CSVImportProfileRow.recordType,
      into: &recordIDs)
    collectAllGRDBUUIDs(
      ids: { try grdbRepositories.importRules.allRowIdsSync() },
      recordType: ImportRuleRow.recordType,
      into: &recordIDs)

    if !recordIDs.isEmpty {
      logger.info("Collected \(recordIDs.count) existing records for upload")
    }
    return recordIDs
  }

  /// Scans all record types and returns CKRecord.IDs for records that have never been
  /// successfully sent to CloudKit (i.e. `encodedSystemFields == nil`). Used on startup
  /// to backfill uploads for profiles whose data landed via migration or any other path
  /// that bypassed the repository `onRecordChanged` hooks.
  func queueUnsyncedRecords() -> [CKRecord.ID] {
    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(
      .begin, log: Signposts.sync, name: "queueUnsyncedRecords", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.sync, name: "queueUnsyncedRecords", signpostID: signpostID)
    }

    var recordIDs: [CKRecord.ID] = []
    // Same dependency order as queueAllExistingRecords.
    collectUnsyncedInstruments(into: &recordIDs)
    collectUnsynced(CategoryRecord.self, into: &recordIDs)
    collectUnsynced(AccountRecord.self, into: &recordIDs)
    collectUnsynced(EarmarkRecord.self, into: &recordIDs)
    collectUnsynced(EarmarkBudgetItemRecord.self, into: &recordIDs)
    collectUnsynced(InvestmentValueRecord.self, into: &recordIDs)
    collectUnsynced(TransactionRecord.self, into: &recordIDs)
    collectUnsynced(TransactionLegRecord.self, into: &recordIDs)
    collectAllGRDBUUIDs(
      ids: { try grdbRepositories.csvImportProfiles.unsyncedRowIdsSync() },
      recordType: CSVImportProfileRow.recordType,
      into: &recordIDs)
    collectAllGRDBUUIDs(
      ids: { try grdbRepositories.importRules.unsyncedRowIdsSync() },
      recordType: ImportRuleRow.recordType,
      into: &recordIDs)

    if !recordIDs.isEmpty {
      logger.info("Collected \(recordIDs.count) unsynced records for upload")
    }
    return recordIDs
  }

  // MARK: - Local Data Deletion

  /// Deletes all local records for this profile's zone.
  /// Returns the set of all record type strings (for notification).
  func deleteLocalData() -> Set<String> {
    let context = ModelContext(modelContainer)

    func deleteAll<T: PersistentModel>(_ type: T.Type) {
      for record in Self.fetchOrLog(FetchDescriptor<T>(), context: context) {
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
    } catch {
      logger.error("Failed to delete local data: \(error, privacy: .public)")
      return []
    }

    // GRDB-backed tables — wiped via the per-table repository helpers.
    // Failures are logged but never propagated; partial wipe is preferable
    // to leaving local data in an inconsistent state. Track success so
    // the "Deleted all local data" info log only fires when every wipe
    // (SwiftData + GRDB) actually completed; mirrors `clearAllSystemFields`.
    var clearedAll = true
    do {
      try grdbRepositories.csvImportProfiles.deleteAllSync()
    } catch {
      clearedAll = false
      logger.error(
        """
        Failed to delete CSV import profiles from GRDB for profile \
        \(self.profileId, privacy: .public): \
        \(error.localizedDescription, privacy: .public)
        """)
    }
    do {
      try grdbRepositories.importRules.deleteAllSync()
    } catch {
      clearedAll = false
      logger.error(
        """
        Failed to delete import rules from GRDB for profile \
        \(self.profileId, privacy: .public): \
        \(error.localizedDescription, privacy: .public)
        """)
    }
    if clearedAll {
      logger.info("Deleted all local data for profile \(self.profileId)")
    }
    // Always return all types so the caller fans out the change
    // notification even on partial failure (the SwiftData branch above
    // followed the same convention before this change).
    return Set(RecordTypeRegistry.allTypes.keys)
  }

  // MARK: - Private Helpers

  private func collectAllUUIDs<
    T: PersistentModel & CloudKitRecordConvertible & IdentifiableRecord
  >(
    _ type: T.Type, into recordIDs: inout [CKRecord.ID]
  ) {
    let context = ModelContext(modelContainer)
    for record in Self.fetchOrLog(FetchDescriptor<T>(), context: context) {
      recordIDs.append(
        CKRecord.ID(recordType: T.recordType, uuid: record.id, zoneID: zoneID))
    }
  }

  private func collectAllStringIDs<T: PersistentModel>(
    _ type: T.Type, into recordIDs: inout [CKRecord.ID], extract: (T) -> String
  ) {
    let context = ModelContext(modelContainer)
    for record in Self.fetchOrLog(FetchDescriptor<T>(), context: context) {
      recordIDs.append(CKRecord.ID(recordName: extract(record), zoneID: zoneID))
    }
  }

  private func collectUnsynced<
    T: PersistentModel & SystemFieldsCacheable & CloudKitRecordConvertible
      & IdentifiableRecord
  >(
    _ type: T.Type, into recordIDs: inout [CKRecord.ID]
  ) {
    let context = ModelContext(modelContainer)
    for record in Self.fetchOrLog(FetchDescriptor<T>(), context: context)
    where record.encodedSystemFields == nil {
      recordIDs.append(
        CKRecord.ID(recordType: T.recordType, uuid: record.id, zoneID: zoneID))
    }
  }

  /// Reads UUIDs from a GRDB-backed repo and appends one prefixed
  /// `CKRecord.ID` per id. The closure is the synchronous repo entry
  /// point (e.g. `allRowIdsSync` / `unsyncedRowIdsSync`); fetch failures
  /// are logged and produce zero records (mirroring the SwiftData path's
  /// `fetchOrLog` behaviour).
  private func collectAllGRDBUUIDs(
    ids: () throws -> [UUID],
    recordType: String,
    into recordIDs: inout [CKRecord.ID]
  ) {
    do {
      for id in try ids() {
        recordIDs.append(
          CKRecord.ID(recordType: recordType, uuid: id, zoneID: zoneID))
      }
    } catch {
      logger.error(
        """
        GRDB fetch failed for \(recordType, privacy: .public) on profile \
        \(self.profileId, privacy: .public): \
        \(error.localizedDescription, privacy: .public)
        """)
    }
  }

  private func collectUnsyncedInstruments(
    into recordIDs: inout [CKRecord.ID]
  ) {
    let context = ModelContext(modelContainer)
    for record in Self.fetchOrLog(
      FetchDescriptor<InstrumentRecord>(), context: context)
    where record.encodedSystemFields == nil {
      recordIDs.append(
        CKRecord.ID(recordName: record.id, zoneID: zoneID))
    }
  }
}
