import CloudKit
import Foundation
import GRDB
import SwiftData
import Testing

@testable import Moolah

@Suite("ProfileDataSyncHandler — queue & clear")
@MainActor
struct ProfileDataSyncHandlerQueueTests {

  @Test
  func deleteLocalDataRemovesAllRecordTypes() throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerAndDatabase()
    let handler = harness.handler

    let context = ModelContext(harness.container)
    context.insert(
      AccountRecord(id: UUID(), name: "Acc", type: "bank", position: 0, isHidden: false))
    context.insert(
      TransactionRecord(id: UUID(), date: Date(), payee: "Test"))
    context.insert(
      CategoryRecord(id: UUID(), name: "Cat", parentId: nil))
    context.insert(
      InstrumentRecord(
        id: "AUD", kind: "fiatCurrency", name: "Australian Dollar", decimals: 2))
    try ProfileDataSyncHandlerTestSupport.saveAndMirror(context: context)

    let changedTypes = handler.deleteLocalData()

    let counts = try harness.database.read { database -> DeleteLocalDataCounts in
      try DeleteLocalDataCounts.fetch(from: database)
    }
    #expect(counts.accounts == 0)
    #expect(counts.transactions == 0)
    #expect(counts.categories == 0)
    #expect(counts.instruments == 0)
    #expect(changedTypes == Set(RecordTypeRegistry.allTypes.keys))
  }

  @Test
  func queueAllExistingRecordsReturnsAllRecordIDs() throws {
    let (handler, container) = try ProfileDataSyncHandlerTestSupport.makeHandler()

    let accountId = UUID()
    let txnId = UUID()
    let instrumentId = "AUD"

    let context = ModelContext(container)
    context.insert(
      AccountRecord(id: accountId, name: "Acc", type: "bank", position: 0, isHidden: false))
    context.insert(
      TransactionRecord(id: txnId, date: Date(), payee: "Test"))
    context.insert(
      InstrumentRecord(
        id: instrumentId, kind: "fiatCurrency", name: "Australian Dollar", decimals: 2))
    try ProfileDataSyncHandlerTestSupport.saveAndMirror(context: context)

    let recordIDs = handler.queueAllExistingRecords()

    #expect(recordIDs.count == 3)

    let recordNames = Set(recordIDs.map(\.recordName))
    #expect(recordNames.contains("\(AccountRow.recordType)|\(accountId.uuidString)"))
    #expect(recordNames.contains("\(TransactionRow.recordType)|\(txnId.uuidString)"))
    #expect(recordNames.contains(instrumentId))

    for recordID in recordIDs {
      #expect(recordID.zoneID == handler.zoneID)
    }
  }

  @Test
  func queueUnsyncedRecordsReturnsRecordsWithNilSystemFields() throws {
    let (handler, container) = try ProfileDataSyncHandlerTestSupport.makeHandler()

    let unsyncedAccountId = UUID()
    let syncedAccountId = UUID()
    let unsyncedInstrumentId = "AUD"
    let syncedInstrumentId = "USD"

    let context = ModelContext(container)

    context.insert(
      AccountRecord(
        id: unsyncedAccountId, name: "Unsynced", type: "bank", position: 0,
        isHidden: false))

    let synced = AccountRecord(
      id: syncedAccountId, name: "Synced", type: "bank", position: 1,
      isHidden: false)
    synced.encodedSystemFields = Data([0x01, 0x02, 0x03])
    context.insert(synced)

    context.insert(
      InstrumentRecord(
        id: unsyncedInstrumentId, kind: "fiatCurrency",
        name: "Australian Dollar", decimals: 2))
    let syncedInstrument = InstrumentRecord(
      id: syncedInstrumentId, kind: "fiatCurrency",
      name: "US Dollar", decimals: 2)
    syncedInstrument.encodedSystemFields = Data([0x04, 0x05])
    context.insert(syncedInstrument)

    try ProfileDataSyncHandlerTestSupport.saveAndMirror(context: context)

    let recordIDs = handler.queueUnsyncedRecords()
    let recordNames = Set(recordIDs.map(\.recordName))

    #expect(
      recordNames.contains("\(AccountRow.recordType)|\(unsyncedAccountId.uuidString)"))
    #expect(recordNames.contains(unsyncedInstrumentId))
    #expect(
      !recordNames.contains("\(AccountRow.recordType)|\(syncedAccountId.uuidString)"))
    #expect(!recordNames.contains(syncedInstrumentId))
  }

  @Test
  func queueUnsyncedRecordsReturnsEmptyWhenAllSynced() throws {
    let (handler, container) = try ProfileDataSyncHandlerTestSupport.makeHandler()

    let context = ModelContext(container)
    let account = AccountRecord(
      id: UUID(), name: "Acc", type: "bank", position: 0, isHidden: false)
    account.encodedSystemFields = Data([0x01])
    context.insert(account)
    try ProfileDataSyncHandlerTestSupport.saveAndMirror(context: context)

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

    @MainActor
    func insert(into context: ModelContext) throws {
      context.insert(
        InstrumentRecord(id: instrumentId, kind: "fiatCurrency", name: "AUD Dollar", decimals: 2))
      context.insert(
        AccountRecord(id: accountId, name: "Acc", type: "bank", position: 0, isHidden: false))
      context.insert(CategoryRecord(id: categoryId, name: "Food", parentId: nil))
      context.insert(EarmarkRecord(id: earmarkId, name: "Holiday", instrumentId: instrumentId))
      context.insert(
        EarmarkBudgetItemRecord(
          id: budgetItemId, earmarkId: earmarkId, categoryId: categoryId,
          amount: 0, instrumentId: instrumentId))
      context.insert(
        InvestmentValueRecord(
          id: investmentValueId, accountId: accountId, date: Date(),
          value: 0, instrumentId: instrumentId))
      context.insert(TransactionRecord(id: txnId, date: Date(), payee: "Test"))
      context.insert(
        TransactionLegRecord(
          id: legId, transactionId: txnId, accountId: accountId,
          instrumentId: instrumentId, quantity: 0, type: "income", sortOrder: 0))
      try ProfileDataSyncHandlerTestSupport.saveAndMirror(context: context)
    }
  }

  @Test
  func queueUnsyncedRecordsReturnsAllWhenNoneSynced() throws {
    let (handler, container) = try ProfileDataSyncHandlerTestSupport.makeHandler()
    let seed = AllRecordSeed()
    try seed.insert(into: ModelContext(container))

    let recordIDs = handler.queueUnsyncedRecords()
    let recordNames = Set(recordIDs.map(\.recordName))

    #expect(recordNames.count == 8)
    #expect(recordNames.contains(seed.instrumentId))
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
  func clearAllSystemFieldsClearsAllRecordTypes() throws {
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

    let preRow = try database.read { database in
      try AccountRow.filter(AccountRow.Columns.id == accountId).fetchOne(database)
    }
    #expect(preRow?.encodedSystemFields != nil)

    handler.clearAllSystemFields()

    let postRow = try database.read { database in
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
