import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("ProfileDataSyncHandler — queue & clear")
@MainActor
struct ProfileDataSyncHandlerQueueTests {

  @Test
  func deleteLocalDataWipesSurvivingTablesButNotPerProfileInstruments() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerAndDatabase()
    let handler = harness.handler

    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try ProfileDataSyncHandlerTestSupport.accountRow(
        id: UUID(), name: "Acc"
      ).upsert(database)
      try ProfileDataSyncHandlerTestSupport.transactionRow(
        id: UUID(), payee: "Test"
      ).upsert(database)
      try ProfileDataSyncHandlerTestSupport.categoryRow(
        id: UUID(), name: "Cat"
      ).upsert(database)
      try ProfileDataSyncHandlerTestSupport.instrumentRow(
        id: "AUD", kind: "fiatCurrency", name: "Australian Dollar", decimals: 2
      ).upsert(database)
    }

    let changedTypes = handler.deleteLocalData()

    let counts = try await harness.database.read { database -> DeleteLocalDataCounts in
      try DeleteLocalDataCounts.fetch(from: database)
    }
    #expect(counts.accounts == 0)
    #expect(counts.transactions == 0)
    #expect(counts.categories == 0)
    // The per-profile `instrument` table is NOT wiped: instrument data
    // is owned by the shared, iCloud-account-scoped profile-index
    // registry, and a single-profile purge must not wipe instruments
    // shared by every other profile. (The per-profile table is also
    // about to be removed by `v10_drop_shared_instrument_legacy`, after
    // which a wipe against it would throw `no such table`.)
    #expect(
      counts.instruments == 1,
      "deleteLocalData must not wipe the per-profile instrument table")
    #expect(changedTypes == Set(RecordTypeRegistry.allTypes.keys))
  }

  @Test
  func queueAllExistingRecordsReturnsAllRecordIDs() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let handler = harness.handler

    let accountId = UUID()
    let txnId = UUID()
    let instrumentId = "AUD"

    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try ProfileDataSyncHandlerTestSupport.accountRow(
        id: accountId, name: "Acc"
      ).upsert(database)
      try ProfileDataSyncHandlerTestSupport.transactionRow(
        id: txnId, payee: "Test"
      ).upsert(database)
      try ProfileDataSyncHandlerTestSupport.instrumentRow(
        id: instrumentId, kind: "fiatCurrency",
        name: "Australian Dollar", decimals: 2
      ).upsert(database)
    }

    let recordIDs = handler.queueAllExistingRecords()

    // Instrument ids are queued by the shared registry on the
    // profile-index zone (via
    // `SyncCoordinator.queueUnsyncedSharedInstruments`), not by the
    // per-profile handler. The seeded `AUD` instrument is therefore
    // not part of the per-profile queue.
    #expect(recordIDs.count == 2)

    let recordNames = Set(recordIDs.map(\.recordName))
    #expect(recordNames.contains("\(AccountRow.recordType)|\(accountId.uuidString)"))
    #expect(recordNames.contains("\(TransactionRow.recordType)|\(txnId.uuidString)"))
    #expect(!recordNames.contains(instrumentId))

    for recordID in recordIDs {
      #expect(recordID.zoneID == handler.zoneID)
    }
  }

  @Test
  func queueUnsyncedRecordsReturnsRecordsWithNilSystemFields() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let handler = harness.handler

    let unsyncedAccountId = UUID()
    let syncedAccountId = UUID()
    let unsyncedInstrumentId = "AUD"
    let syncedInstrumentId = "USD"

    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try ProfileDataSyncHandlerTestSupport.accountRow(
        id: unsyncedAccountId, name: "Unsynced"
      ).upsert(database)
      try ProfileDataSyncHandlerTestSupport.accountRow(
        id: syncedAccountId, name: "Synced", position: 1,
        encodedSystemFields: Data([0x01, 0x02, 0x03])
      ).upsert(database)
      try ProfileDataSyncHandlerTestSupport.instrumentRow(
        id: unsyncedInstrumentId, kind: "fiatCurrency",
        name: "Australian Dollar", decimals: 2
      ).upsert(database)
      try ProfileDataSyncHandlerTestSupport.instrumentRow(
        id: syncedInstrumentId, kind: "fiatCurrency",
        name: "US Dollar", decimals: 2,
        encodedSystemFields: Data([0x04, 0x05])
      ).upsert(database)
    }

    let recordIDs = handler.queueUnsyncedRecords()
    let recordNames = Set(recordIDs.map(\.recordName))

    // The per-profile handler no longer enumerates instrument rows.
    // The shared registry's
    // `SyncCoordinator.queueUnsyncedSharedInstruments` covers them.
    #expect(
      recordNames.contains("\(AccountRow.recordType)|\(unsyncedAccountId.uuidString)"))
    #expect(!recordNames.contains(unsyncedInstrumentId))
    #expect(
      !recordNames.contains("\(AccountRow.recordType)|\(syncedAccountId.uuidString)"))
    #expect(!recordNames.contains(syncedInstrumentId))
  }

  @Test
  func queueUnsyncedRecordsReturnsEmptyWhenAllSynced() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let handler = harness.handler

    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try ProfileDataSyncHandlerTestSupport.accountRow(
        id: UUID(), name: "Acc",
        encodedSystemFields: Data([0x01])
      ).upsert(database)
    }

    let recordIDs = handler.queueUnsyncedRecords()
    #expect(recordIDs.isEmpty)
  }

  private struct AllRecordSeed {
    let accountId = UUID()
    let txnId = UUID()
    let legId = UUID()
    let categoryId = UUID()
    let earmarkId = UUID()
    let budgetItemId = UUID()
    let investmentValueId = UUID()
    let instrumentId = "AUD"

    func insert(into database: Database) throws {
      try ProfileDataSyncHandlerTestSupport.instrumentRow(
        id: instrumentId, kind: "fiatCurrency", name: "AUD Dollar", decimals: 2
      ).upsert(database)
      try ProfileDataSyncHandlerTestSupport.accountRow(
        id: accountId, name: "Acc", instrumentId: instrumentId
      ).upsert(database)
      try ProfileDataSyncHandlerTestSupport.categoryRow(
        id: categoryId, name: "Food"
      ).upsert(database)
      try ProfileDataSyncHandlerTestSupport.earmarkRow(
        id: earmarkId, name: "Holiday", instrumentId: instrumentId
      ).upsert(database)
      try ProfileDataSyncHandlerTestSupport.earmarkBudgetItemRow(
        id: budgetItemId, earmarkId: earmarkId, categoryId: categoryId,
        instrumentId: instrumentId
      ).upsert(database)
      try ProfileDataSyncHandlerTestSupport.investmentValueRow(
        id: investmentValueId, accountId: accountId,
        instrumentId: instrumentId
      ).upsert(database)
      try ProfileDataSyncHandlerTestSupport.transactionRow(
        id: txnId, payee: "Test"
      ).upsert(database)
      try ProfileDataSyncHandlerTestSupport.transactionLegRow(
        id: legId, transactionId: txnId, accountId: accountId,
        instrumentId: instrumentId
      ).upsert(database)
    }
  }

  @Test
  func queueUnsyncedRecordsReturnsAllWhenNoneSynced() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let handler = harness.handler
    let seed = AllRecordSeed()
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try seed.insert(into: database)
    }

    let recordIDs = handler.queueUnsyncedRecords()
    let recordNames = Set(recordIDs.map(\.recordName))

    // The per-profile handler no longer enumerates instrument rows
    // (count would be 8 if it did; the shared registry covers them).
    #expect(recordNames.count == 7)
    #expect(!recordNames.contains(seed.instrumentId))
    #expect(recordNames.contains("\(AccountRow.recordType)|\(seed.accountId.uuidString)"))
    #expect(recordNames.contains("\(CategoryRow.recordType)|\(seed.categoryId.uuidString)"))
    #expect(recordNames.contains("\(EarmarkRow.recordType)|\(seed.earmarkId.uuidString)"))
    #expect(
      recordNames.contains(
        "\(EarmarkBudgetItemRow.recordType)|\(seed.budgetItemId.uuidString)"))
    #expect(
      recordNames.contains(
        "\(InvestmentValueRow.recordType)|\(seed.investmentValueId.uuidString)"))
    #expect(recordNames.contains("\(TransactionRow.recordType)|\(seed.txnId.uuidString)"))
    #expect(recordNames.contains("\(TransactionLegRow.recordType)|\(seed.legId.uuidString)"))
    for recordID in recordIDs {
      #expect(recordID.zoneID == handler.zoneID)
    }
  }

  @Test
  func clearAllSystemFieldsClearsAllRecordTypes() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerAndDatabase()
    let handler = harness.handler
    let database = harness.database

    let accountId = UUID()
    let ckRecord = CKRecord(
      recordType: "AccountRecord",
      recordID: CKRecord.ID(
        recordType: AccountRow.recordType, uuid: accountId, zoneID: handler.zoneID)
    )
    ckRecord["name"] = "Test" as CKRecordValue
    ckRecord["type"] = "bank" as CKRecordValue
    ckRecord["position"] = 0 as CKRecordValue
    ckRecord["isHidden"] = 0 as CKRecordValue

    _ = handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let preRow = try await database.read { database in
      try AccountRow.filter(AccountRow.Columns.id == accountId).fetchOne(database)
    }
    #expect(preRow?.encodedSystemFields != nil)

    handler.clearAllSystemFields()

    let postRow = try await database.read { database in
      try AccountRow.filter(AccountRow.Columns.id == accountId).fetchOne(database)
    }
    #expect(postRow?.encodedSystemFields == nil)
  }
}

/// Per-table row counts for `deleteLocalDataRemovesAllRecordTypes`.
/// Replaces a four-tuple to satisfy SwiftLint's `large_tuple` policy.
private struct DeleteLocalDataCounts {
  let accounts: Int
  let transactions: Int
  let categories: Int
  let instruments: Int

  static func fetch(from database: Database) throws -> DeleteLocalDataCounts {
    DeleteLocalDataCounts(
      accounts: try AccountRow.fetchCount(database),
      transactions: try TransactionRow.fetchCount(database),
      categories: try CategoryRow.fetchCount(database),
      instruments: try InstrumentRow.fetchCount(database))
  }
}
