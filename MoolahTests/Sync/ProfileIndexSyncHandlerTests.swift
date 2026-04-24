import CloudKit
import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("ProfileIndexSyncHandler")
@MainActor
struct ProfileIndexSyncHandlerTests {

  private func makeHandler() throws -> (ProfileIndexSyncHandler, ModelContainer) {
    let schema = Schema([ProfileRecord.self])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [config])
    let handler = ProfileIndexSyncHandler(modelContainer: container)
    return (handler, container)
  }

  // MARK: - Remote Insert

  @Test
  func applyRemoteInsertCreatesProfileRecord() throws {
    let (handler, container) = try makeHandler()

    let profileId = UUID()
    let ckRecord = CKRecord(
      recordType: ProfileRecord.recordType,
      recordID: CKRecord.ID(recordName: profileId.uuidString, zoneID: handler.zoneID)
    )
    ckRecord["label"] = "My Profile" as CKRecordValue
    ckRecord["currencyCode"] = "AUD" as CKRecordValue
    ckRecord["financialYearStartMonth"] = 7 as CKRecordValue
    ckRecord["createdAt"] = Date() as CKRecordValue

    _ = handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let context = ModelContext(container)
    let records = try context.fetch(
      FetchDescriptor<ProfileRecord>(predicate: #Predicate { $0.id == profileId })
    )
    #expect(records.count == 1)
    #expect(records.first?.label == "My Profile")
    #expect(records.first?.currencyCode == "AUD")
    #expect(records.first?.financialYearStartMonth == 7)
    #expect(records.first?.encodedSystemFields != nil)
  }

  // MARK: - Remote Update

  @Test
  func applyRemoteUpdateModifiesExistingRecord() throws {
    let (handler, container) = try makeHandler()

    let profileId = UUID()
    let context = ModelContext(container)
    let existing = ProfileRecord(
      id: profileId, label: "Old Label", currencyCode: "USD"
    )
    context.insert(existing)
    try context.save()

    let ckRecord = CKRecord(
      recordType: ProfileRecord.recordType,
      recordID: CKRecord.ID(recordName: profileId.uuidString, zoneID: handler.zoneID)
    )
    ckRecord["label"] = "New Label" as CKRecordValue
    ckRecord["currencyCode"] = "EUR" as CKRecordValue
    ckRecord["financialYearStartMonth"] = 1 as CKRecordValue
    ckRecord["createdAt"] = Date() as CKRecordValue

    _ = handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let freshContext = ModelContext(container)
    let records = try freshContext.fetch(
      FetchDescriptor<ProfileRecord>(predicate: #Predicate { $0.id == profileId })
    )
    #expect(records.count == 1)
    #expect(records.first?.label == "New Label")
    #expect(records.first?.currencyCode == "EUR")
    #expect(records.first?.financialYearStartMonth == 1)
  }

  // MARK: - Remote Deletion

  @Test
  func applyRemoteDeletionRemovesProfileRecord() throws {
    let (handler, container) = try makeHandler()

    let profileId = UUID()
    let context = ModelContext(container)
    let existing = ProfileRecord(
      id: profileId, label: "To Delete", currencyCode: "AUD"
    )
    context.insert(existing)
    try context.save()

    let recordID = CKRecord.ID(recordName: profileId.uuidString, zoneID: handler.zoneID)
    _ = handler.applyRemoteChanges(saved: [], deleted: [recordID])

    let freshContext = ModelContext(container)
    let records = try freshContext.fetch(
      FetchDescriptor<ProfileRecord>(predicate: #Predicate { $0.id == profileId })
    )
    #expect(records.isEmpty)
  }

  @Test
  func applyRemoteChangesSkipsNonProfileRecordTypes() throws {
    let (handler, container) = try makeHandler()

    let ckRecord = CKRecord(
      recordType: "CD_SomeOtherType",
      recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: handler.zoneID)
    )
    ckRecord["label"] = "Ignored" as CKRecordValue

    _ = handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let context = ModelContext(container)
    let records = try context.fetch(FetchDescriptor<ProfileRecord>())
    #expect(records.isEmpty)
  }

  // MARK: - deleteLocalData

  @Test
  func deleteLocalDataRemovesAllProfiles() throws {
    let (handler, container) = try makeHandler()

    let context = ModelContext(container)
    context.insert(ProfileRecord(label: "Profile 1", currencyCode: "AUD"))
    context.insert(ProfileRecord(label: "Profile 2", currencyCode: "USD"))
    context.insert(ProfileRecord(label: "Profile 3", currencyCode: "EUR"))
    try context.save()

    handler.deleteLocalData()

    let freshContext = ModelContext(container)
    let records = try freshContext.fetch(FetchDescriptor<ProfileRecord>())
    #expect(records.isEmpty)
  }

  // MARK: - queueAllExistingRecords

  @Test
  func queueAllExistingRecordsReturnsCorrectIDs() throws {
    let (handler, container) = try makeHandler()

    let id1 = UUID()
    let id2 = UUID()
    let context = ModelContext(container)
    context.insert(ProfileRecord(id: id1, label: "P1", currencyCode: "AUD"))
    context.insert(ProfileRecord(id: id2, label: "P2", currencyCode: "USD"))
    try context.save()

    let recordIDs = handler.queueAllExistingRecords()

    #expect(recordIDs.count == 2)
    let recordNames = Set(recordIDs.map(\.recordName))
    #expect(
      recordNames.contains(
        "\(ProfileRecord.recordType)|\(id1.uuidString)"))
    #expect(
      recordNames.contains(
        "\(ProfileRecord.recordType)|\(id2.uuidString)"))
    for recordID in recordIDs {
      #expect(recordID.zoneID == handler.zoneID)
    }
  }

  @Test
  func queueAllExistingRecordsReturnsEmptyWhenNoRecords() throws {
    let (handler, _) = try makeHandler()
    let recordIDs = handler.queueAllExistingRecords()
    #expect(recordIDs.isEmpty)
  }

  // MARK: - buildCKRecord

  @Test
  func buildCKRecordProducesCorrectRecord() throws {
    let (handler, container) = try makeHandler()

    let profileId = UUID()
    let profile = ProfileRecord(
      id: profileId, label: "Test Profile", currencyCode: "AUD",
      financialYearStartMonth: 7
    )
    let context = ModelContext(container)
    context.insert(profile)
    try context.save()

    let ckRecord = handler.buildCKRecord(for: profile)

    #expect(ckRecord.recordType == ProfileRecord.recordType)
    #expect(
      ckRecord.recordID.recordName
        == "\(ProfileRecord.recordType)|\(profileId.uuidString)")
    #expect(ckRecord.recordID.zoneID == handler.zoneID)
    #expect(ckRecord["label"] as? String == "Test Profile")
    #expect(ckRecord["currencyCode"] as? String == "AUD")
    #expect(ckRecord["financialYearStartMonth"] as? Int == 7)
  }
}
