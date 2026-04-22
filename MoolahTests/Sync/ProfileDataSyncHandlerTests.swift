import CloudKit
import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("ProfileDataSyncHandler")
@MainActor
struct ProfileDataSyncHandlerTests {

  private func makeHandler() throws -> (ProfileDataSyncHandler, ModelContainer) {
    let container = try TestModelContainer.create()
    let profileId = UUID()
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName
    )
    let handler = ProfileDataSyncHandler(
      profileId: profileId, zoneID: zoneID, modelContainer: container)
    return (handler, container)
  }

  // MARK: - Remote Insert

  @Test func applyRemoteInsertCreatesLocalRecord() throws {
    let (handler, container) = try makeHandler()

    let accountId = UUID()
    let ckRecord = CKRecord(
      recordType: "CD_AccountRecord",
      recordID: CKRecord.ID(recordName: accountId.uuidString, zoneID: handler.zoneID)
    )
    ckRecord["name"] = "Remote Account" as CKRecordValue
    ckRecord["type"] = "bank" as CKRecordValue
    ckRecord["position"] = 1 as CKRecordValue
    ckRecord["isHidden"] = 0 as CKRecordValue

    let result = handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let context = ModelContext(container)
    let records = try context.fetch(
      FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == accountId })
    )
    #expect(records.count == 1)
    #expect(records.first?.name == "Remote Account")
    guard case .success(let changedTypes) = result else {
      Issue.record("Expected .success but got \(result)")
      return
    }
    #expect(changedTypes.contains("CD_AccountRecord"))
  }

  // MARK: - Remote Update

  @Test func applyRemoteUpdateModifiesExistingRecord() throws {
    let (handler, container) = try makeHandler()

    let accountId = UUID()
    let context = ModelContext(container)
    let existing = AccountRecord(
      id: accountId, name: "Old Name", type: "bank", position: 0,
      isHidden: false
    )
    context.insert(existing)
    try context.save()

    let ckRecord = CKRecord(
      recordType: "CD_AccountRecord",
      recordID: CKRecord.ID(recordName: accountId.uuidString, zoneID: handler.zoneID)
    )
    ckRecord["name"] = "Updated Name" as CKRecordValue
    ckRecord["type"] = "bank" as CKRecordValue
    ckRecord["position"] = 5 as CKRecordValue
    ckRecord["isHidden"] = 1 as CKRecordValue

    _ = handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let freshContext = ModelContext(container)
    let records = try freshContext.fetch(
      FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == accountId })
    )
    #expect(records.count == 1)
    #expect(records.first?.name == "Updated Name")
    #expect(records.first?.position == 5)
    #expect(records.first?.isHidden == true)
  }

  // MARK: - Remote Deletion

  @Test func applyRemoteDeletionRemovesLocalRecord() throws {
    let (handler, container) = try makeHandler()

    let accountId = UUID()
    let context = ModelContext(container)
    let existing = AccountRecord(
      id: accountId, name: "To Delete", type: "bank", position: 0,
      isHidden: false
    )
    context.insert(existing)
    try context.save()

    let recordID = CKRecord.ID(recordName: accountId.uuidString, zoneID: handler.zoneID)
    let result = handler.applyRemoteChanges(
      saved: [], deleted: [(recordID, "CD_AccountRecord")])

    let freshContext = ModelContext(container)
    let records = try freshContext.fetch(
      FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == accountId })
    )
    #expect(records.isEmpty)
    guard case .success(let changedTypes) = result else {
      Issue.record("Expected .success but got \(result)")
      return
    }
    #expect(changedTypes.contains("CD_AccountRecord"))
  }

  // MARK: - buildCKRecord

  @Test func buildCKRecordProducesCorrectRecord() throws {
    let (handler, container) = try makeHandler()

    let account = AccountRecord(
      id: UUID(), name: "Savings", type: "bank", position: 0,
      isHidden: false
    )
    let context = ModelContext(container)
    context.insert(account)
    try context.save()

    let ckRecord = handler.buildCKRecord(for: account)

    #expect(ckRecord.recordType == "CD_AccountRecord")
    #expect(ckRecord.recordID.recordName == account.id.uuidString)
    #expect(ckRecord.recordID.zoneID == handler.zoneID)
    #expect(ckRecord["name"] as? String == "Savings")
  }

  @Test("buildCKRecord drops cached system fields when they point to a different zone")
  func buildCKRecordDropsCachedFieldsOnZoneMismatch() throws {
    let (handler, container) = try makeHandler()

    // Simulate legacy corruption: a local AccountRecord whose
    // encodedSystemFields blob references a DIFFERENT profile's zone.
    // Historically this happened pre-April-15 when per-profile sync engines
    // received fetch events for every zone in the database and upserted
    // records by UUID into the wrong container. buildCKRecord must NOT reuse
    // those system fields — doing so ships the record with a stale change
    // tag that lives in another zone and triggers an unbreakable
    // `serverRecordChanged` loop on every send.
    let foreignZone = CKRecordZone.ID(
      zoneName: "profile-\(UUID().uuidString)",
      ownerName: CKCurrentUserDefaultName
    )
    let accountId = UUID()
    let foreignCK = CKRecord(
      recordType: "CD_AccountRecord",
      recordID: CKRecord.ID(recordName: accountId.uuidString, zoneID: foreignZone)
    )
    let foreignSystemFields = foreignCK.encodedSystemFields

    let context = ModelContext(container)
    let account = AccountRecord(
      id: accountId, name: "Corrupt", type: "bank", position: 0, isHidden: false
    )
    account.encodedSystemFields = foreignSystemFields
    context.insert(account)
    try context.save()

    let built = handler.buildCKRecord(for: account)

    #expect(built.recordID.zoneID == handler.zoneID)
    // A fresh (unsent) CKRecord has no change tag. Sending with the foreign
    // tag would be rejected with serverRecordChanged forever.
    #expect(built.recordChangeTag == nil)
    #expect(built.recordID.recordName == accountId.uuidString)
    #expect(built["name"] as? String == "Corrupt")
  }

  @Test func buildCKRecordPreservesCachedSystemFields() throws {
    let (handler, container) = try makeHandler()

    let accountId = UUID()
    // Create a CKRecord to get system fields from
    let originalCK = CKRecord(
      recordType: "CD_AccountRecord",
      recordID: CKRecord.ID(recordName: accountId.uuidString, zoneID: handler.zoneID)
    )
    originalCK["name"] = "Test" as CKRecordValue
    originalCK["type"] = "bank" as CKRecordValue
    originalCK["position"] = 0 as CKRecordValue
    originalCK["isHidden"] = 0 as CKRecordValue

    // Apply remote changes which stores system fields on the model
    _ = handler.applyRemoteChanges(saved: [originalCK], deleted: [])

    // Fetch the record back
    let context = ModelContext(container)
    let records = try context.fetch(
      FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == accountId })
    )
    let account = try #require(records.first)
    #expect(account.encodedSystemFields != nil)

    // Build a CKRecord — should use cached system fields
    let built = handler.buildCKRecord(for: account)
    #expect(built.recordID.recordName == accountId.uuidString)
    #expect(built.recordID.zoneID == handler.zoneID)
    #expect(built["name"] as? String == "Test")
  }

  // MARK: - deleteLocalData

  @Test func deleteLocalDataRemovesAllRecordTypes() throws {
    let (handler, container) = try makeHandler()

    // Seed multiple record types
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

    // Verify all records deleted
    let freshContext = ModelContext(container)
    let accounts = try freshContext.fetch(FetchDescriptor<AccountRecord>())
    let transactions = try freshContext.fetch(FetchDescriptor<TransactionRecord>())
    let categories = try freshContext.fetch(FetchDescriptor<CategoryRecord>())
    let instruments = try freshContext.fetch(FetchDescriptor<InstrumentRecord>())

    #expect(accounts.isEmpty)
    #expect(transactions.isEmpty)
    #expect(categories.isEmpty)
    #expect(instruments.isEmpty)

    // Verify changed types returned
    #expect(changedTypes == Set(RecordTypeRegistry.allTypes.keys))
  }

  // MARK: - queueAllExistingRecords

  @Test func queueAllExistingRecordsReturnsAllRecordIDs() throws {
    let (handler, container) = try makeHandler()

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
    #expect(recordNames.contains(accountId.uuidString))
    #expect(recordNames.contains(txnId.uuidString))
    #expect(recordNames.contains(instrumentId))

    // All should be in the correct zone
    for recordID in recordIDs {
      #expect(recordID.zoneID == handler.zoneID)
    }
  }

  // MARK: - queueUnsyncedRecords

  @Test func queueUnsyncedRecordsReturnsRecordsWithNilSystemFields() throws {
    let (handler, container) = try makeHandler()

    let unsyncedAccountId = UUID()
    let syncedAccountId = UUID()
    let unsyncedInstrumentId = "AUD"
    let syncedInstrumentId = "USD"

    let context = ModelContext(container)

    // Record without system fields (never synced, e.g. just migrated)
    context.insert(
      AccountRecord(
        id: unsyncedAccountId, name: "Unsynced", type: "bank", position: 0,
        isHidden: false))

    // Record with system fields (already synced)
    let synced = AccountRecord(
      id: syncedAccountId, name: "Synced", type: "bank", position: 1,
      isHidden: false)
    synced.encodedSystemFields = Data([0x01, 0x02, 0x03])
    context.insert(synced)

    // Instruments follow the same rule (string-keyed)
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

    #expect(recordNames.contains(unsyncedAccountId.uuidString))
    #expect(recordNames.contains(unsyncedInstrumentId))
    #expect(!recordNames.contains(syncedAccountId.uuidString))
    #expect(!recordNames.contains(syncedInstrumentId))
  }

  @Test func queueUnsyncedRecordsReturnsEmptyWhenAllSynced() throws {
    let (handler, container) = try makeHandler()

    let context = ModelContext(container)
    let account = AccountRecord(
      id: UUID(), name: "Acc", type: "bank", position: 0, isHidden: false)
    account.encodedSystemFields = Data([0x01])
    context.insert(account)
    try context.save()

    let recordIDs = handler.queueUnsyncedRecords()
    #expect(recordIDs.isEmpty)
  }

  @Test func queueUnsyncedRecordsReturnsAllWhenNoneSynced() throws {
    let (handler, container) = try makeHandler()

    let accountId = UUID()
    let txnId = UUID()
    let legId = UUID()
    let categoryId = UUID()
    let earmarkId = UUID()
    let budgetItemId = UUID()
    let investmentValueId = UUID()
    let instrumentId = "AUD"

    let context = ModelContext(container)
    context.insert(
      InstrumentRecord(
        id: instrumentId, kind: "fiatCurrency",
        name: "Australian Dollar", decimals: 2))
    context.insert(
      AccountRecord(id: accountId, name: "Acc", type: "bank", position: 0, isHidden: false))
    context.insert(
      CategoryRecord(id: categoryId, name: "Food", parentId: nil))
    context.insert(
      EarmarkRecord(id: earmarkId, name: "Holiday", instrumentId: instrumentId))
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

    let recordIDs = handler.queueUnsyncedRecords()
    let recordNames = Set(recordIDs.map(\.recordName))

    #expect(recordNames.count == 8)
    #expect(recordNames.contains(instrumentId))
    #expect(recordNames.contains(accountId.uuidString))
    #expect(recordNames.contains(categoryId.uuidString))
    #expect(recordNames.contains(earmarkId.uuidString))
    #expect(recordNames.contains(budgetItemId.uuidString))
    #expect(recordNames.contains(investmentValueId.uuidString))
    #expect(recordNames.contains(txnId.uuidString))
    #expect(recordNames.contains(legId.uuidString))

    for recordID in recordIDs {
      #expect(recordID.zoneID == handler.zoneID)
    }
  }

  // MARK: - buildBatchRecordLookup

  @Test func buildBatchRecordLookupFindsRecordsByUUID() throws {
    let (handler, container) = try makeHandler()

    let accountId = UUID()
    let txnId = UUID()

    let context = ModelContext(container)
    context.insert(
      AccountRecord(id: accountId, name: "Acc", type: "bank", position: 0, isHidden: false))
    context.insert(
      TransactionRecord(id: txnId, date: Date(), payee: "Test"))
    try context.save()

    let lookup = handler.buildBatchRecordLookup(for: [accountId, txnId])

    #expect(lookup.count == 2)
    #expect(lookup[accountId] != nil)
    #expect(lookup[txnId] != nil)
    #expect(lookup[accountId]?.recordType == "CD_AccountRecord")
    #expect(lookup[txnId]?.recordType == "CD_TransactionRecord")
  }

  // MARK: - clearAllSystemFields

  @Test func clearAllSystemFieldsClearsAllRecordTypes() throws {
    let (handler, container) = try makeHandler()

    // Seed a record with system fields
    let accountId = UUID()
    let ckRecord = CKRecord(
      recordType: "CD_AccountRecord",
      recordID: CKRecord.ID(recordName: accountId.uuidString, zoneID: handler.zoneID)
    )
    ckRecord["name"] = "Test" as CKRecordValue
    ckRecord["type"] = "bank" as CKRecordValue
    ckRecord["position"] = 0 as CKRecordValue
    ckRecord["isHidden"] = 0 as CKRecordValue

    _ = handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    // Verify system fields are set
    let preContext = ModelContext(container)
    let preRecords = try preContext.fetch(
      FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == accountId })
    )
    #expect(preRecords.first?.encodedSystemFields != nil)

    // Clear all system fields
    handler.clearAllSystemFields()

    // Verify they are cleared
    let postContext = ModelContext(container)
    let postRecords = try postContext.fetch(
      FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == accountId })
    )
    #expect(postRecords.first?.encodedSystemFields == nil)
  }

  // MARK: - recordToSave

  @Test func recordToSaveFindsAccountByUUID() throws {
    let (handler, container) = try makeHandler()

    let accountId = UUID()
    let context = ModelContext(container)
    context.insert(
      AccountRecord(id: accountId, name: "Found", type: "bank", position: 0, isHidden: false))
    try context.save()

    let recordID = CKRecord.ID(recordName: accountId.uuidString, zoneID: handler.zoneID)
    let result = handler.recordToSave(for: recordID)
    #expect(result != nil)
    #expect(result?.recordType == "CD_AccountRecord")
    #expect(result?["name"] as? String == "Found")
  }

  @Test func recordToSaveFindsInstrumentByStringID() throws {
    let (handler, container) = try makeHandler()

    let context = ModelContext(container)
    context.insert(
      InstrumentRecord(
        id: "ASX:BHP", kind: "stock", name: "BHP Group", decimals: 2,
        ticker: "BHP", exchange: "ASX"))
    try context.save()

    let recordID = CKRecord.ID(recordName: "ASX:BHP", zoneID: handler.zoneID)
    let result = handler.recordToSave(for: recordID)
    #expect(result != nil)
    #expect(result?.recordType == "CD_InstrumentRecord")
    #expect(result?["name"] as? String == "BHP Group")
  }

  @Test func recordToSaveReturnsNilForMissingRecord() throws {
    let (handler, _) = try makeHandler()

    let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: handler.zoneID)
    let result = handler.recordToSave(for: recordID)
    #expect(result == nil)
  }
}
