import CloudKit
import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("ProfileDataSyncHandler — queue & clear")
@MainActor
struct ProfileDataSyncHandlerQueueTests {

  @Test
  func deleteLocalDataRemovesAllRecordTypes() throws {
    let (handler, container) = try ProfileDataSyncHandlerTestSupport.makeHandler()

    let context = ModelContext(container)
    context.insert(
      AccountRecord(id: UUID(), name: "Acc", type: "bank", position: 0, isHidden: false))
    context.insert(
      TransactionRecord(id: UUID(), date: Date(), payee: "Test"))
    context.insert(
      CategoryRecord(id: UUID(), name: "Cat", parentId: nil))
    context.insert(
      InstrumentRecord(
        id: "AUD", kind: "fiatCurrency", name: "Australian Dollar", decimals: 2))
    try context.save()

    let changedTypes = handler.deleteLocalData()

    let freshContext = ModelContext(container)
    let accounts = try freshContext.fetch(FetchDescriptor<AccountRecord>())
    let transactions = try freshContext.fetch(FetchDescriptor<TransactionRecord>())
    let categories = try freshContext.fetch(FetchDescriptor<CategoryRecord>())
    let instruments = try freshContext.fetch(FetchDescriptor<InstrumentRecord>())

    #expect(accounts.isEmpty)
    #expect(transactions.isEmpty)
    #expect(categories.isEmpty)
    #expect(instruments.isEmpty)
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
    try context.save()

    let recordIDs = handler.queueAllExistingRecords()

    #expect(recordIDs.count == 3)

    let recordNames = Set(recordIDs.map(\.recordName))
    #expect(recordNames.contains("\(AccountRecord.recordType)|\(accountId.uuidString)"))
    #expect(recordNames.contains("\(TransactionRecord.recordType)|\(txnId.uuidString)"))
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

    try context.save()

    let recordIDs = handler.queueUnsyncedRecords()
    let recordNames = Set(recordIDs.map(\.recordName))

    #expect(
      recordNames.contains("\(AccountRecord.recordType)|\(unsyncedAccountId.uuidString)"))
    #expect(recordNames.contains(unsyncedInstrumentId))
    #expect(
      !recordNames.contains("\(AccountRecord.recordType)|\(syncedAccountId.uuidString)"))
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
    try context.save()

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
      try context.save()
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
    #expect(recordNames.contains("\(AccountRecord.recordType)|\(seed.accountId.uuidString)"))
    #expect(recordNames.contains("\(CategoryRecord.recordType)|\(seed.categoryId.uuidString)"))
    #expect(recordNames.contains("\(EarmarkRecord.recordType)|\(seed.earmarkId.uuidString)"))
    #expect(
      recordNames.contains(
        "\(EarmarkBudgetItemRecord.recordType)|\(seed.budgetItemId.uuidString)"))
    #expect(
      recordNames.contains(
        "\(InvestmentValueRecord.recordType)|\(seed.investmentValueId.uuidString)"))
    #expect(recordNames.contains("\(TransactionRecord.recordType)|\(seed.txnId.uuidString)"))
    #expect(recordNames.contains("\(TransactionLegRecord.recordType)|\(seed.legId.uuidString)"))
    for recordID in recordIDs {
      #expect(recordID.zoneID == handler.zoneID)
    }
  }

  @Test
  func clearAllSystemFieldsClearsAllRecordTypes() throws {
    let (handler, container) = try ProfileDataSyncHandlerTestSupport.makeHandler()

    let accountId = UUID()
    let ckRecord = CKRecord(
      recordType: "AccountRecord",
      recordID: CKRecord.ID(
        recordType: AccountRecord.recordType, uuid: accountId, zoneID: handler.zoneID)
    )
    ckRecord["name"] = "Test" as CKRecordValue
    ckRecord["type"] = "bank" as CKRecordValue
    ckRecord["position"] = 0 as CKRecordValue
    ckRecord["isHidden"] = 0 as CKRecordValue

    _ = handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let preContext = ModelContext(container)
    let preRecords = try preContext.fetch(
      FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == accountId })
    )
    #expect(preRecords.first?.encodedSystemFields != nil)

    handler.clearAllSystemFields()

    let postContext = ModelContext(container)
    let postRecords = try postContext.fetch(
      FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == accountId })
    )
    #expect(postRecords.first?.encodedSystemFields == nil)
  }
}
