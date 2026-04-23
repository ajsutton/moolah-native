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
    #expect(recordNames.contains(id1.uuidString))
    #expect(recordNames.contains(id2.uuidString))
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
    #expect(ckRecord.recordID.recordName == profileId.uuidString)
    #expect(ckRecord.recordID.zoneID == handler.zoneID)
    #expect(ckRecord["label"] as? String == "Test Profile")
    #expect(ckRecord["currencyCode"] as? String == "AUD")
    #expect(ckRecord["financialYearStartMonth"] as? Int == 7)
  }

  @Test
  func buildCKRecordPreservesCachedSystemFields() throws {
    let (handler, container) = try makeHandler()

    let profileId = UUID()
    let originalCK = CKRecord(
      recordType: ProfileRecord.recordType,
      recordID: CKRecord.ID(recordName: profileId.uuidString, zoneID: handler.zoneID)
    )
    originalCK["label"] = "Test" as CKRecordValue
    originalCK["currencyCode"] = "AUD" as CKRecordValue
    originalCK["financialYearStartMonth"] = 7 as CKRecordValue
    originalCK["createdAt"] = Date() as CKRecordValue

    // Apply remote changes to store system fields
    _ = handler.applyRemoteChanges(saved: [originalCK], deleted: [])

    let context = ModelContext(container)
    let records = try context.fetch(
      FetchDescriptor<ProfileRecord>(predicate: #Predicate { $0.id == profileId })
    )
    let profile = try #require(records.first)
    #expect(profile.encodedSystemFields != nil)

    let built = handler.buildCKRecord(for: profile)
    #expect(built.recordID.recordName == profileId.uuidString)
    #expect(built.recordID.zoneID == handler.zoneID)
    #expect(built["label"] as? String == "Test")
  }

  // MARK: - recordToSave

  @Test
  func recordToSaveFindsProfileByUUID() throws {
    let (handler, container) = try makeHandler()

    let profileId = UUID()
    let context = ModelContext(container)
    context.insert(ProfileRecord(id: profileId, label: "Found", currencyCode: "AUD"))
    try context.save()

    let recordID = CKRecord.ID(recordName: profileId.uuidString, zoneID: handler.zoneID)
    let result = handler.recordToSave(for: recordID)
    #expect(result != nil)
    #expect(result?.recordType == ProfileRecord.recordType)
    #expect(result?["label"] as? String == "Found")
  }

  @Test
  func recordToSaveReturnsNilForMissingProfile() throws {
    let (handler, _) = try makeHandler()

    let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: handler.zoneID)
    let result = handler.recordToSave(for: recordID)
    #expect(result == nil)
  }

  // MARK: - clearAllSystemFields

  @Test
  func clearAllSystemFieldsClearsOnAllProfiles() throws {
    let (handler, container) = try makeHandler()

    let profileId = UUID()
    let ckRecord = CKRecord(
      recordType: ProfileRecord.recordType,
      recordID: CKRecord.ID(recordName: profileId.uuidString, zoneID: handler.zoneID)
    )
    ckRecord["label"] = "Test" as CKRecordValue
    ckRecord["currencyCode"] = "AUD" as CKRecordValue
    ckRecord["financialYearStartMonth"] = 7 as CKRecordValue
    ckRecord["createdAt"] = Date() as CKRecordValue

    _ = handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    // Verify system fields are set
    let preContext = ModelContext(container)
    let preRecords = try preContext.fetch(
      FetchDescriptor<ProfileRecord>(predicate: #Predicate { $0.id == profileId })
    )
    #expect(preRecords.first?.encodedSystemFields != nil)

    handler.clearAllSystemFields()

    let postContext = ModelContext(container)
    let postRecords = try postContext.fetch(
      FetchDescriptor<ProfileRecord>(predicate: #Predicate { $0.id == profileId })
    )
    #expect(postRecords.first?.encodedSystemFields == nil)
  }

  // MARK: - updateEncodedSystemFields / clearEncodedSystemFields

  @Test
  func updateEncodedSystemFieldsSetsDataOnMatchingProfile() throws {
    let (handler, container) = try makeHandler()

    let profileId = UUID()
    let context = ModelContext(container)
    context.insert(ProfileRecord(id: profileId, label: "Test", currencyCode: "AUD"))
    try context.save()

    let testData = Data([0x01, 0x02, 0x03])
    let recordID = CKRecord.ID(recordName: profileId.uuidString, zoneID: handler.zoneID)
    handler.updateEncodedSystemFields(recordID, data: testData)

    let freshContext = ModelContext(container)
    let records = try freshContext.fetch(
      FetchDescriptor<ProfileRecord>(predicate: #Predicate { $0.id == profileId })
    )
    #expect(records.first?.encodedSystemFields == testData)
  }

  @Test
  func clearEncodedSystemFieldsClearsDataOnMatchingProfile() throws {
    let (handler, container) = try makeHandler()

    let profileId = UUID()
    let context = ModelContext(container)
    let profile = ProfileRecord(id: profileId, label: "Test", currencyCode: "AUD")
    profile.encodedSystemFields = Data([0x01, 0x02])
    context.insert(profile)
    try context.save()

    let recordID = CKRecord.ID(recordName: profileId.uuidString, zoneID: handler.zoneID)
    handler.clearEncodedSystemFields(recordID)

    let freshContext = ModelContext(container)
    let records = try freshContext.fetch(
      FetchDescriptor<ProfileRecord>(predicate: #Predicate { $0.id == profileId })
    )
    #expect(records.first?.encodedSystemFields == nil)
  }

  // MARK: - handleSentRecordZoneChanges

  @Test
  func handleSentRecordZoneChangesUpdatesSystemFieldsFromSavedRecords() throws {
    let (handler, container) = try makeHandler()

    let profileId = UUID()
    let context = ModelContext(container)
    context.insert(ProfileRecord(id: profileId, label: "Test", currencyCode: "AUD"))
    try context.save()

    // Build a CKRecord with encoded system fields (produced by applyRemoteChanges on a
    // real record so the system fields blob is valid).
    let ckRecord = CKRecord(
      recordType: ProfileRecord.recordType,
      recordID: CKRecord.ID(recordName: profileId.uuidString, zoneID: handler.zoneID)
    )
    ckRecord["label"] = "Test" as CKRecordValue
    ckRecord["currencyCode"] = "AUD" as CKRecordValue
    ckRecord["financialYearStartMonth"] = 7 as CKRecordValue
    ckRecord["createdAt"] = Date() as CKRecordValue
    let expectedSystemFields = ckRecord.encodedSystemFields

    let failures = handler.handleSentRecordZoneChanges(
      savedRecords: [ckRecord],
      failedSaves: [],
      failedDeletes: []
    )

    #expect(failures.conflicts.isEmpty)
    #expect(failures.unknownItems.isEmpty)
    #expect(failures.requeue.isEmpty)
    #expect(failures.requeueDeletes.isEmpty)

    // Read the updated system fields back through a FRESH context. If the handler had
    // mutated the shared mainContext without saving (or reused a stale context), a new
    // context would not see the change. Using a fresh context here verifies the write
    // was actually persisted to the store.
    let freshContext = ModelContext(container)
    let records = try freshContext.fetch(
      FetchDescriptor<ProfileRecord>(predicate: #Predicate { $0.id == profileId })
    )
    #expect(records.first?.encodedSystemFields == expectedSystemFields)
  }

  @Test
  func handleSentRecordZoneChangesWithNoRecordsReturnsEmptyFailures() throws {
    let (handler, _) = try makeHandler()

    let failures = handler.handleSentRecordZoneChanges(
      savedRecords: [],
      failedSaves: [],
      failedDeletes: []
    )

    #expect(failures.conflicts.isEmpty)
    #expect(failures.unknownItems.isEmpty)
    #expect(failures.requeue.isEmpty)
    #expect(failures.requeueDeletes.isEmpty)
  }
}
