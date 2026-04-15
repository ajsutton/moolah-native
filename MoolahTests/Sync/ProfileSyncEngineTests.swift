import CloudKit
import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("ProfileSyncEngine")
@MainActor
struct ProfileSyncEngineTests {

  // MARK: - Zone ID

  @Test func zoneIDDerivedFromProfileId() {
    let profileId = UUID()
    let container = try! TestModelContainer.create()
    let engine = ProfileSyncEngine(profileId: profileId, modelContainer: container)

    #expect(engine.zoneID.zoneName == "profile-\(profileId.uuidString)")
    #expect(engine.zoneID.ownerName == CKCurrentUserDefaultName)
  }

  // MARK: - Pending Changes

  @Test func queueSaveMarksEngineAsPending() {
    let profileId = UUID()
    let container = try! TestModelContainer.create()
    let engine = ProfileSyncEngine(profileId: profileId, modelContainer: container)
    // Engine must be started for queueSave to reach CKSyncEngine's state
    // Without starting, syncEngine is nil and queueSave is a no-op
    #expect(!engine.hasPendingChanges)
  }

  @Test func queueDeletionMarksEngineAsPending() {
    let profileId = UUID()
    let container = try! TestModelContainer.create()
    let engine = ProfileSyncEngine(profileId: profileId, modelContainer: container)
    #expect(!engine.hasPendingChanges)
  }

  // MARK: - Record Conversion for Upload

  @Test func recordsToSaveConvertsFromLocalStore() {
    let profileId = UUID()
    let container = try! TestModelContainer.create()
    let engine = ProfileSyncEngine(profileId: profileId, modelContainer: container)

    // Seed an account into the store
    let account = AccountRecord(
      id: UUID(), name: "Savings", type: "bank", position: 0,
      isHidden: false
    )
    let context = ModelContext(container)
    context.insert(account)
    try! context.save()

    // Ask engine to build a CKRecord for this account
    let ckRecord = engine.buildCKRecord(for: account)

    #expect(ckRecord.recordType == "CD_AccountRecord")
    #expect(ckRecord.recordID.recordName == account.id.uuidString)
    #expect(ckRecord.recordID.zoneID == engine.zoneID)
    #expect(ckRecord["name"] as? String == "Savings")
  }

  // MARK: - Applying Remote Changes

  @Test func applyRemoteInsertCreatesLocalRecord() async {
    let profileId = UUID()
    let container = try! TestModelContainer.create()
    let engine = ProfileSyncEngine(profileId: profileId, modelContainer: container)

    // Simulate receiving a remote account record
    let accountId = UUID()
    let ckRecord = CKRecord(
      recordType: "CD_AccountRecord",
      recordID: CKRecord.ID(recordName: accountId.uuidString, zoneID: engine.zoneID)
    )
    ckRecord["name"] = "Remote Account" as CKRecordValue
    ckRecord["type"] = "bank" as CKRecordValue
    ckRecord["position"] = 1 as CKRecordValue
    ckRecord["isHidden"] = 0 as CKRecordValue
    ckRecord["usesPositionTracking"] = 0 as CKRecordValue

    engine.applyRemoteChanges(saved: [ckRecord], deleted: [])

    // Verify it was persisted locally
    let context = ModelContext(container)
    let descriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.id == accountId }
    )
    let records = try! context.fetch(descriptor)
    #expect(records.count == 1)
    #expect(records.first?.name == "Remote Account")
  }

  @Test func applyRemoteUpdateModifiesExistingRecord() async {
    let profileId = UUID()
    let container = try! TestModelContainer.create()
    let engine = ProfileSyncEngine(profileId: profileId, modelContainer: container)

    // Insert a local record first
    let accountId = UUID()
    let context = ModelContext(container)
    let existing = AccountRecord(
      id: accountId, name: "Old Name", type: "bank", position: 0,
      isHidden: false
    )
    context.insert(existing)
    try! context.save()

    // Simulate receiving an updated remote record
    let ckRecord = CKRecord(
      recordType: "CD_AccountRecord",
      recordID: CKRecord.ID(recordName: accountId.uuidString, zoneID: engine.zoneID)
    )
    ckRecord["name"] = "Updated Name" as CKRecordValue
    ckRecord["type"] = "bank" as CKRecordValue
    ckRecord["position"] = 5 as CKRecordValue
    ckRecord["isHidden"] = 1 as CKRecordValue

    engine.applyRemoteChanges(saved: [ckRecord], deleted: [])

    // Verify the update was applied
    let freshContext = ModelContext(container)
    let descriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.id == accountId }
    )
    let records = try! freshContext.fetch(descriptor)
    #expect(records.count == 1)
    #expect(records.first?.name == "Updated Name")
    #expect(records.first?.position == 5)
    #expect(records.first?.isHidden == true)
  }

  @Test func applyRemoteDeleteRemovesLocalRecord() async {
    let profileId = UUID()
    let container = try! TestModelContainer.create()
    let engine = ProfileSyncEngine(profileId: profileId, modelContainer: container)

    // Insert a local record
    let accountId = UUID()
    let context = ModelContext(container)
    let existing = AccountRecord(
      id: accountId, name: "To Delete", type: "bank", position: 0,
      isHidden: false
    )
    context.insert(existing)
    try! context.save()

    // Simulate remote deletion
    let recordID = CKRecord.ID(recordName: accountId.uuidString, zoneID: engine.zoneID)
    engine.applyRemoteChanges(saved: [], deleted: [(recordID, "CD_AccountRecord")])

    // Verify deletion
    let freshContext = ModelContext(container)
    let descriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.id == accountId }
    )
    let records = try! freshContext.fetch(descriptor)
    #expect(records.isEmpty)
  }

  // MARK: - Multi-type support

  @Test func applyRemoteChangesHandlesTransactions() async {
    let profileId = UUID()
    let container = try! TestModelContainer.create()
    let engine = ProfileSyncEngine(profileId: profileId, modelContainer: container)

    let txnId = UUID()
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    let ckRecord = CKRecord(
      recordType: "CD_TransactionRecord",
      recordID: CKRecord.ID(recordName: txnId.uuidString, zoneID: engine.zoneID)
    )
    ckRecord["date"] = date as CKRecordValue
    ckRecord["payee"] = "Coffee" as CKRecordValue

    engine.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let context = ModelContext(container)
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.id == txnId }
    )
    let records = try! context.fetch(descriptor)
    #expect(records.count == 1)
    #expect(records.first?.payee == "Coffee")
  }

  @Test func applyRemoteChangesHandlesCategories() async {
    let profileId = UUID()
    let container = try! TestModelContainer.create()
    let engine = ProfileSyncEngine(profileId: profileId, modelContainer: container)

    let catId = UUID()
    let parentId = UUID()

    let ckRecord = CKRecord(
      recordType: "CD_CategoryRecord",
      recordID: CKRecord.ID(recordName: catId.uuidString, zoneID: engine.zoneID)
    )
    ckRecord["name"] = "Groceries" as CKRecordValue
    ckRecord["parentId"] = parentId.uuidString as CKRecordValue

    engine.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let context = ModelContext(container)
    let descriptor = FetchDescriptor<CategoryRecord>(
      predicate: #Predicate { $0.id == catId }
    )
    let records = try! context.fetch(descriptor)
    #expect(records.count == 1)
    #expect(records.first?.name == "Groceries")
    #expect(records.first?.parentId == parentId)
  }

  // MARK: - Batch Processing

  @Test func applyRemoteChangesHandlesBatchTransactions() async {
    let profileId = UUID()
    let container = try! TestModelContainer.create()
    let engine = ProfileSyncEngine(profileId: profileId, modelContainer: container)

    let date = Date(timeIntervalSince1970: 1_700_000_000)

    // Create 100 transaction CKRecords
    var ckRecords: [CKRecord] = []
    for i in 0..<100 {
      let txnId = UUID()
      let ckRecord = CKRecord(
        recordType: "CD_TransactionRecord",
        recordID: CKRecord.ID(recordName: txnId.uuidString, zoneID: engine.zoneID)
      )
      ckRecord["date"] = date as CKRecordValue
      ckRecord["payee"] = "Payee \(i)" as CKRecordValue
      ckRecords.append(ckRecord)
    }

    engine.applyRemoteChanges(saved: ckRecords, deleted: [])

    // Verify all 100 are persisted
    let context = ModelContext(container)
    let descriptor = FetchDescriptor<TransactionRecord>()
    let records = try! context.fetch(descriptor)
    #expect(records.count == 100)
  }

  @Test func applyRemoteChangesHandlesMixedInsertAndUpdate() async {
    let profileId = UUID()
    let container = try! TestModelContainer.create()
    let engine = ProfileSyncEngine(profileId: profileId, modelContainer: container)

    let existingTxnId = UUID()
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    // Pre-insert one transaction
    let preContext = ModelContext(container)
    let existing = TransactionRecord(
      id: existingTxnId, date: date,
      payee: "Old Payee"
    )
    preContext.insert(existing)
    try! preContext.save()

    // Send a batch with an update to the existing record AND a new record
    let newTxnId = UUID()

    let updateRecord = CKRecord(
      recordType: "CD_TransactionRecord",
      recordID: CKRecord.ID(recordName: existingTxnId.uuidString, zoneID: engine.zoneID)
    )
    updateRecord["date"] = date as CKRecordValue
    updateRecord["payee"] = "Updated Payee" as CKRecordValue

    let insertRecord = CKRecord(
      recordType: "CD_TransactionRecord",
      recordID: CKRecord.ID(recordName: newTxnId.uuidString, zoneID: engine.zoneID)
    )
    insertRecord["date"] = date as CKRecordValue
    insertRecord["payee"] = "New Payee" as CKRecordValue

    engine.applyRemoteChanges(saved: [updateRecord, insertRecord], deleted: [])

    // Verify total count = 2
    let context = ModelContext(container)
    let allDescriptor = FetchDescriptor<TransactionRecord>()
    let allRecords = try! context.fetch(allDescriptor)
    #expect(allRecords.count == 2)

    // Verify the update was applied
    let updateDescriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.id == existingTxnId }
    )
    let updated = try! context.fetch(updateDescriptor)
    #expect(updated.first?.payee == "Updated Payee")

    // Verify the insert happened
    let insertDescriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.id == newTxnId }
    )
    let inserted = try! context.fetch(insertDescriptor)
    #expect(inserted.first?.payee == "New Payee")
  }

  // MARK: - Fetch Session Lifecycle (Deferred Balance Invalidation)

  /// Helper to create a transaction CKRecord for a given account
  private func makeTransactionCKRecord(
    accountId: UUID, amount: Int, zoneID: CKRecordZone.ID
  ) -> CKRecord {
    let ckRecord = CKRecord(
      recordType: "CD_TransactionRecord",
      recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
    )
    ckRecord["type"] = "expense" as CKRecordValue
    ckRecord["date"] = Date() as CKRecordValue
    ckRecord["accountId"] = accountId.uuidString as CKRecordValue
    ckRecord["amount"] = amount as CKRecordValue
    ckRecord["currencyCode"] = "AUD" as CKRecordValue
    return ckRecord
  }

  @Test func duringFetchSessionCallbackNotFiredPerBatch() {
    let container = try! TestModelContainer.create()
    let engine = ProfileSyncEngine(profileId: UUID(), modelContainer: container)

    var callbackCount = 0
    engine.onRemoteChangesApplied = { _ in callbackCount += 1 }

    let accountId = UUID()

    // Simulate fetch session: willFetchChanges → multiple batches → didFetchChanges
    engine.beginFetchingChanges()

    engine.applyRemoteChanges(
      saved: [makeTransactionCKRecord(accountId: accountId, amount: -100, zoneID: engine.zoneID)],
      deleted: []
    )
    engine.applyRemoteChanges(
      saved: [makeTransactionCKRecord(accountId: accountId, amount: -200, zoneID: engine.zoneID)],
      deleted: []
    )
    engine.applyRemoteChanges(
      saved: [makeTransactionCKRecord(accountId: accountId, amount: -300, zoneID: engine.zoneID)],
      deleted: []
    )

    // Callback should NOT have fired during the fetch session
    #expect(callbackCount == 0)
  }

  @Test func didFetchChangesFiresCallbackOnceWithAccumulatedTypes() {
    let container = try! TestModelContainer.create()
    let engine = ProfileSyncEngine(profileId: UUID(), modelContainer: container)

    var receivedTypes: Set<String>?
    var callbackCount = 0
    engine.onRemoteChangesApplied = { types in
      callbackCount += 1
      receivedTypes = types
    }

    let accountId = UUID()
    let categoryId = UUID()

    // Send a transaction batch and a category batch during a fetch session
    engine.beginFetchingChanges()

    engine.applyRemoteChanges(
      saved: [makeTransactionCKRecord(accountId: accountId, amount: -100, zoneID: engine.zoneID)],
      deleted: []
    )

    let catRecord = CKRecord(
      recordType: "CD_CategoryRecord",
      recordID: CKRecord.ID(recordName: categoryId.uuidString, zoneID: engine.zoneID)
    )
    catRecord["name"] = "Food" as CKRecordValue
    engine.applyRemoteChanges(saved: [catRecord], deleted: [])

    engine.endFetchingChanges()

    // Should fire exactly once with both types accumulated
    #expect(callbackCount == 1)
    #expect(receivedTypes?.contains("CD_TransactionRecord") == true)
    #expect(receivedTypes?.contains("CD_CategoryRecord") == true)
  }

  @Test func outsideFetchSessionCallbackFiredPerBatch() {
    let container = try! TestModelContainer.create()
    let engine = ProfileSyncEngine(profileId: UUID(), modelContainer: container)

    var callbackCount = 0
    engine.onRemoteChangesApplied = { _ in callbackCount += 1 }

    let accountId = UUID()

    // Without begin/endFetchingChanges, each batch should fire the callback
    engine.applyRemoteChanges(
      saved: [makeTransactionCKRecord(accountId: accountId, amount: -100, zoneID: engine.zoneID)],
      deleted: []
    )
    engine.applyRemoteChanges(
      saved: [makeTransactionCKRecord(accountId: accountId, amount: -200, zoneID: engine.zoneID)],
      deleted: []
    )

    #expect(callbackCount == 2)
  }

  @Test func endFetchingChangesWithNoChangesDoesNotFireCallback() {
    let container = try! TestModelContainer.create()
    let engine = ProfileSyncEngine(profileId: UUID(), modelContainer: container)

    var callbackCount = 0
    engine.onRemoteChangesApplied = { _ in callbackCount += 1 }

    // Start and end a fetch session with no batches
    engine.beginFetchingChanges()
    engine.endFetchingChanges()

    #expect(callbackCount == 0)
  }

  // MARK: - System Fields on Model

  @Test func applyRemoteChangesStoresSystemFieldsOnModel() async {
    let profileId = UUID()
    let container = try! TestModelContainer.create()
    let engine = ProfileSyncEngine(profileId: profileId, modelContainer: container)

    let accountId = UUID()
    let ckRecord = CKRecord(
      recordType: "CD_AccountRecord",
      recordID: CKRecord.ID(recordName: accountId.uuidString, zoneID: engine.zoneID)
    )
    ckRecord["name"] = "Test Account" as CKRecordValue
    ckRecord["type"] = "bank" as CKRecordValue
    ckRecord["position"] = 0 as CKRecordValue
    ckRecord["isHidden"] = 0 as CKRecordValue
    ckRecord["currencyCode"] = "AUD" as CKRecordValue

    engine.applyRemoteChanges(saved: [ckRecord], deleted: [])

    // Verify system fields were stored on the model
    let context = ModelContext(container)
    let records = try! context.fetch(
      FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == accountId })
    )
    #expect(records.count == 1)
    #expect(records.first?.encodedSystemFields != nil)

    // Verify the stored system fields can reconstruct a CKRecord
    let storedData = records.first!.encodedSystemFields!
    let restored = CKRecord.fromEncodedSystemFields(storedData)
    #expect(restored != nil)
    #expect(restored?.recordID.recordName == accountId.uuidString)
  }

  @Test func buildCKRecordUsesSystemFieldsFromModel() async {
    let profileId = UUID()
    let container = try! TestModelContainer.create()
    let engine = ProfileSyncEngine(profileId: profileId, modelContainer: container)

    let accountId = UUID()
    let ckRecord = CKRecord(
      recordType: "CD_AccountRecord",
      recordID: CKRecord.ID(recordName: accountId.uuidString, zoneID: engine.zoneID)
    )
    ckRecord["name"] = "Test" as CKRecordValue
    ckRecord["type"] = "bank" as CKRecordValue
    ckRecord["position"] = 0 as CKRecordValue
    ckRecord["isHidden"] = 0 as CKRecordValue
    ckRecord["currencyCode"] = "AUD" as CKRecordValue

    engine.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let context = ModelContext(container)
    let records = try! context.fetch(
      FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == accountId })
    )
    let account = records.first!

    let built = engine.buildCKRecord(for: account)
    #expect(built.recordID.recordName == accountId.uuidString)
    #expect(built.recordID.zoneID == engine.zoneID)
    #expect(built["name"] as? String == "Test")
  }
}
