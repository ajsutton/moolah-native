import CloudKit
import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("ProfileIndexSyncEngine")
@MainActor
struct ProfileIndexSyncEngineTests {

  private func makeIndexContainer() throws -> ModelContainer {
    let schema = Schema([ProfileRecord.self])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
  }

  // MARK: - Zone ID

  @Test func zoneIDIsProfileIndex() throws {
    let container = try makeIndexContainer()
    let engine = ProfileIndexSyncEngine(modelContainer: container)

    #expect(engine.zoneID.zoneName == "profile-index")
    #expect(engine.zoneID.ownerName == CKCurrentUserDefaultName)
  }

  // MARK: - Applying Remote Changes

  @Test func applyRemoteInsertCreatesProfileRecord() throws {
    let container = try makeIndexContainer()
    let engine = ProfileIndexSyncEngine(modelContainer: container)

    let profileId = UUID()
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let ckRecord = CKRecord(
      recordType: "CD_ProfileRecord",
      recordID: CKRecord.ID(recordName: profileId.uuidString, zoneID: engine.zoneID)
    )
    ckRecord["label"] = "My Budget" as CKRecordValue
    ckRecord["currencyCode"] = "AUD" as CKRecordValue
    ckRecord["financialYearStartMonth"] = 7 as CKRecordValue
    ckRecord["createdAt"] = createdAt as CKRecordValue

    engine.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let context = ModelContext(container)
    let descriptor = FetchDescriptor<ProfileRecord>(
      predicate: #Predicate { $0.id == profileId }
    )
    let records = try context.fetch(descriptor)
    #expect(records.count == 1)
    #expect(records.first?.label == "My Budget")
    #expect(records.first?.currencyCode == "AUD")
    #expect(records.first?.financialYearStartMonth == 7)
    #expect(records.first?.createdAt == createdAt)
  }

  @Test func applyRemoteUpdateModifiesExistingProfile() throws {
    let container = try makeIndexContainer()
    let engine = ProfileIndexSyncEngine(modelContainer: container)

    // Insert a profile first
    let profileId = UUID()
    let context = ModelContext(container)
    let existing = ProfileRecord(
      id: profileId, label: "Old Label", currencyCode: "USD", financialYearStartMonth: 1
    )
    context.insert(existing)
    try context.save()

    // Simulate remote update
    let ckRecord = CKRecord(
      recordType: "CD_ProfileRecord",
      recordID: CKRecord.ID(recordName: profileId.uuidString, zoneID: engine.zoneID)
    )
    ckRecord["label"] = "New Label" as CKRecordValue
    ckRecord["currencyCode"] = "AUD" as CKRecordValue
    ckRecord["financialYearStartMonth"] = 7 as CKRecordValue
    ckRecord["createdAt"] = Date() as CKRecordValue

    engine.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let freshContext = ModelContext(container)
    let descriptor = FetchDescriptor<ProfileRecord>(
      predicate: #Predicate { $0.id == profileId }
    )
    let records = try freshContext.fetch(descriptor)
    #expect(records.count == 1)
    #expect(records.first?.label == "New Label")
    #expect(records.first?.currencyCode == "AUD")
  }

  @Test func applyRemoteDeleteRemovesProfile() throws {
    let container = try makeIndexContainer()
    let engine = ProfileIndexSyncEngine(modelContainer: container)

    // Insert a profile first
    let profileId = UUID()
    let context = ModelContext(container)
    let existing = ProfileRecord(
      id: profileId, label: "To Delete", currencyCode: "AUD"
    )
    context.insert(existing)
    try context.save()

    // Simulate remote deletion
    let recordID = CKRecord.ID(recordName: profileId.uuidString, zoneID: engine.zoneID)
    engine.applyRemoteChanges(saved: [], deleted: [recordID])

    let freshContext = ModelContext(container)
    let descriptor = FetchDescriptor<ProfileRecord>(
      predicate: #Predicate { $0.id == profileId }
    )
    let records = try freshContext.fetch(descriptor)
    #expect(records.isEmpty)
  }

  // MARK: - Callback

  @Test func onRemoteChangesAppliedCalledAfterInsert() throws {
    let container = try makeIndexContainer()
    let engine = ProfileIndexSyncEngine(modelContainer: container)

    var callbackInvoked = false
    engine.onRemoteChangesApplied = { callbackInvoked = true }

    let ckRecord = CKRecord(
      recordType: "CD_ProfileRecord",
      recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: engine.zoneID)
    )
    ckRecord["label"] = "Test" as CKRecordValue
    ckRecord["currencyCode"] = "AUD" as CKRecordValue
    ckRecord["financialYearStartMonth"] = 7 as CKRecordValue
    ckRecord["createdAt"] = Date() as CKRecordValue

    engine.applyRemoteChanges(saved: [ckRecord], deleted: [])

    #expect(callbackInvoked)
  }
}
