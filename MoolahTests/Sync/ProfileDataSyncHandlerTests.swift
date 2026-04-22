import CloudKit
import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("ProfileDataSyncHandler — remote changes & record building")
@MainActor
struct ProfileDataSyncHandlerTests {

  // MARK: - Remote Insert

  @Test func applyRemoteInsertCreatesLocalRecord() throws {
    let (handler, container) = try ProfileDataSyncHandlerTestSupport.makeHandler()

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
    let (handler, container) = try ProfileDataSyncHandlerTestSupport.makeHandler()

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
    let (handler, container) = try ProfileDataSyncHandlerTestSupport.makeHandler()

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
    let (handler, container) = try ProfileDataSyncHandlerTestSupport.makeHandler()

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
    let (handler, container) = try ProfileDataSyncHandlerTestSupport.makeHandler()

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
    let (handler, container) = try ProfileDataSyncHandlerTestSupport.makeHandler()

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
}
