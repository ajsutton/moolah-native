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

  @Test func addPendingChangeTracksRecordForUpload() {
    let profileId = UUID()
    let container = try! TestModelContainer.create()
    let engine = ProfileSyncEngine(profileId: profileId, modelContainer: container)

    let recordId = UUID()
    engine.addPendingChange(
      .saveRecord(
        CKRecord.ID(
          recordName: recordId.uuidString,
          zoneID: engine.zoneID
        )))

    #expect(engine.hasPendingChanges)
  }

  @Test func addPendingDeletionTracksRecordForDeletion() {
    let profileId = UUID()
    let container = try! TestModelContainer.create()
    let engine = ProfileSyncEngine(profileId: profileId, modelContainer: container)

    let recordId = UUID()
    engine.addPendingChange(
      .deleteRecord(
        CKRecord.ID(
          recordName: recordId.uuidString,
          zoneID: engine.zoneID
        )))

    #expect(engine.hasPendingChanges)
  }

  // MARK: - Record Conversion for Upload

  @Test func recordsToSaveConvertsFromLocalStore() {
    let profileId = UUID()
    let container = try! TestModelContainer.create()
    let engine = ProfileSyncEngine(profileId: profileId, modelContainer: container)

    // Seed an account into the store
    let account = AccountRecord(
      id: UUID(), name: "Savings", type: "bank", position: 0,
      isHidden: false, currencyCode: "AUD", cachedBalance: nil
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
    ckRecord["currencyCode"] = "USD" as CKRecordValue

    engine.applyRemoteChanges(saved: [ckRecord], deleted: [])

    // Verify it was persisted locally
    let context = ModelContext(container)
    let descriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.id == accountId }
    )
    let records = try! context.fetch(descriptor)
    #expect(records.count == 1)
    #expect(records.first?.name == "Remote Account")
    #expect(records.first?.currencyCode == "USD")
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
      isHidden: false, currencyCode: "AUD", cachedBalance: nil
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
    ckRecord["currencyCode"] = "AUD" as CKRecordValue

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
      isHidden: false, currencyCode: "AUD", cachedBalance: nil
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
    let accountId = UUID()
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    let ckRecord = CKRecord(
      recordType: "CD_TransactionRecord",
      recordID: CKRecord.ID(recordName: txnId.uuidString, zoneID: engine.zoneID)
    )
    ckRecord["type"] = "expense" as CKRecordValue
    ckRecord["date"] = date as CKRecordValue
    ckRecord["accountId"] = accountId.uuidString as CKRecordValue
    ckRecord["amount"] = -1500 as CKRecordValue
    ckRecord["currencyCode"] = "AUD" as CKRecordValue
    ckRecord["payee"] = "Coffee" as CKRecordValue

    engine.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let context = ModelContext(container)
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.id == txnId }
    )
    let records = try! context.fetch(descriptor)
    #expect(records.count == 1)
    #expect(records.first?.payee == "Coffee")
    #expect(records.first?.amount == -1500)
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
}
