import CloudKit
import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("Record-name collision fix — issue #416")
@MainActor
struct RecordNameCollisionTests {

  // MARK: - 1. UUID collision between types (regression test)

  @Test("Account and Transaction sharing a UUID both upload as distinct CKRecords")
  func collidingUUIDsYieldDistinctPrefixedRecordNames() throws {
    let (handler, container) =
      try ProfileDataSyncHandlerTestSupport
      .makeHandler()

    let sharedId = UUID()
    let context = ModelContext(container)
    context.insert(
      AccountRecord(
        id: sharedId, name: "Shares", type: "bank", position: 0,
        isHidden: false))
    context.insert(
      TransactionRecord(
        id: sharedId, date: Date(), payee: "Opening balance"))
    try context.save()

    let lookup = handler.buildBatchRecordLookup(for: [sharedId])

    // buildBatchRecordLookup returns [UUID: CKRecord] — dedupes by UUID.
    // The distinction between the two record types is carried on the
    // recordName prefix, which we assert next.
    let record = try #require(lookup[sharedId])
    let expectedPrefix = "\(record.recordType)|\(sharedId.uuidString)"
    #expect(record.recordID.recordName == expectedPrefix)
  }

  @Test("queueUnsyncedRecords produces prefixed recordNames per type")
  func queueUnsyncedProducesPrefixedRecordNamesPerType() throws {
    let (handler, container) =
      try ProfileDataSyncHandlerTestSupport
      .makeHandler()

    let sharedId = UUID()
    let context = ModelContext(container)
    context.insert(
      AccountRecord(
        id: sharedId, name: "Shares", type: "bank", position: 0,
        isHidden: false))
    context.insert(
      TransactionRecord(
        id: sharedId, date: Date(), payee: "Opening balance"))
    try context.save()

    let recordIDs = handler.queueUnsyncedRecords()
    let names = Set(recordIDs.map(\.recordName))
    #expect(
      names.contains("\(AccountRecord.recordType)|\(sharedId.uuidString)"))
    #expect(
      names.contains(
        "\(TransactionRecord.recordType)|\(sharedId.uuidString)"))
  }

  // MARK: - 2. Uplink uses prefixed name for new records

  @Test("buildCKRecord for a brand-new AccountRecord emits a prefixed recordName")
  func buildCKRecordEmitsPrefixedRecordNameForNewRecords() throws {
    let (handler, container) =
      try ProfileDataSyncHandlerTestSupport
      .makeHandler()

    let accountId = UUID()
    let account = AccountRecord(
      id: accountId, name: "New", type: "bank", position: 0,
      isHidden: false)
    let context = ModelContext(container)
    context.insert(account)
    try context.save()

    let built = handler.buildCKRecord(for: account)
    #expect(
      built.recordID.recordName
        == "\(AccountRecord.recordType)|\(accountId.uuidString)")
  }

  // MARK: - 3. Uplink ignores stale bare-UUID cached system fields

  @Test("buildCKRecord ignores legacy bare-UUID recordName in cached system fields")
  func buildCKRecordIgnoresLegacyBareUUIDCachedSystemFields() throws {
    let (handler, container) =
      try ProfileDataSyncHandlerTestSupport
      .makeHandler()

    let accountId = UUID()
    // Seed an encodedSystemFields blob whose recordID uses the legacy
    // bare-UUID recordName. Reusing this would re-upload the record under
    // the legacy form and round-trip nowhere (the downlink path drops it),
    // so `buildCKRecord` must ignore the stale cache and emit a fresh
    // prefixed recordID.
    let legacyRecord = CKRecord(
      recordType: "CD_AccountRecord",
      recordID: CKRecord.ID(
        recordName: accountId.uuidString, zoneID: handler.zoneID))
    let legacySystemFields = legacyRecord.encodedSystemFields

    let context = ModelContext(container)
    let account = AccountRecord(
      id: accountId, name: "Legacy", type: "bank", position: 0,
      isHidden: false)
    account.encodedSystemFields = legacySystemFields
    context.insert(account)
    try context.save()

    account.name = "Updated"
    let built = handler.buildCKRecord(for: account)
    #expect(
      built.recordID.recordName
        == "\(AccountRecord.recordType)|\(accountId.uuidString)")
    #expect(built["name"] as? String == "Updated")
  }

  // MARK: - 4. Downlink rejects bare-UUID CKRecords

  @Test("applyRemoteChanges drops bare-UUID CKRecords and ingests prefixed ones")
  func applyRemoteChangesRejectsBareUUIDAcceptsPrefixed() throws {
    let (handler, container) =
      try ProfileDataSyncHandlerTestSupport
      .makeHandler()

    let legacyId = UUID()
    let legacyCK = CKRecord(
      recordType: "CD_AccountRecord",
      recordID: CKRecord.ID(
        recordName: legacyId.uuidString, zoneID: handler.zoneID))
    legacyCK["name"] = "Legacy" as CKRecordValue
    legacyCK["type"] = "bank" as CKRecordValue
    legacyCK["position"] = 0 as CKRecordValue
    legacyCK["isHidden"] = 0 as CKRecordValue

    let newId = UUID()
    let newCK = CKRecord(
      recordType: "CD_AccountRecord",
      recordID: CKRecord.ID(
        recordType: "CD_AccountRecord",
        uuid: newId,
        zoneID: handler.zoneID))
    newCK["name"] = "Prefixed" as CKRecordValue
    newCK["type"] = "bank" as CKRecordValue
    newCK["position"] = 1 as CKRecordValue
    newCK["isHidden"] = 0 as CKRecordValue

    _ = handler.applyRemoteChanges(saved: [legacyCK, newCK], deleted: [])

    let context = ModelContext(container)
    let all = try context.fetch(FetchDescriptor<AccountRecord>())
    let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    #expect(byId[legacyId] == nil, "bare-UUID record should not be ingested")
    #expect(byId[newId]?.name == "Prefixed")
    #expect(byId[newId]?.encodedSystemFields != nil)
  }

  // MARK: - 5. System-fields round-trip for prefixed records

  @Test("handleSentRecordZoneChanges writes system fields back using recordType")
  func handleSentRecordZoneChangesAppliesSystemFieldsForPrefixedRecords() throws {
    let (handler, container) =
      try ProfileDataSyncHandlerTestSupport
      .makeHandler()

    let accountId = UUID()
    let context = ModelContext(container)
    let account = AccountRecord(
      id: accountId, name: "Test", type: "bank", position: 0,
      isHidden: false)
    context.insert(account)
    try context.save()
    #expect(account.encodedSystemFields == nil)

    // Simulate a CK round-trip where the server returns a prefixed
    // CKRecord as "saved".
    let savedCK = CKRecord(
      recordType: "CD_AccountRecord",
      recordID: CKRecord.ID(
        recordType: "CD_AccountRecord",
        uuid: accountId,
        zoneID: handler.zoneID))
    savedCK["name"] = "Test" as CKRecordValue

    _ = handler.handleSentRecordZoneChanges(
      savedRecords: [savedCK], failedSaves: [], failedDeletes: [])

    let fresh = ModelContext(container)
    let reloaded = try fresh.fetch(
      FetchDescriptor<AccountRecord>(
        predicate: #Predicate { $0.id == accountId })
    ).first
    #expect(reloaded?.encodedSystemFields != nil)
  }

  // MARK: - 6. ProfileIndexSyncHandler dual-format

  private func makeProfileIndexHandler() throws -> (ProfileIndexSyncHandler, ModelContainer) {
    let schema = Schema([ProfileRecord.self])
    let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    let container = try ModelContainer(for: schema, configurations: [config])
    let handler = ProfileIndexSyncHandler(modelContainer: container)
    return (handler, container)
  }

  @Test("ProfileIndexSyncHandler.recordToSave accepts prefixed recordID")
  func profileIndexRecordToSaveAcceptsPrefixedRecordID() throws {
    let (handler, container) = try makeProfileIndexHandler()

    let profileId = UUID()
    let profile = ProfileRecord(
      id: profileId, label: "Test", currencyCode: "AUD",
      financialYearStartMonth: 7, createdAt: Date())
    let context = ModelContext(container)
    context.insert(profile)
    try context.save()

    let prefixedID = CKRecord.ID(
      recordType: ProfileRecord.recordType,
      uuid: profileId,
      zoneID: handler.zoneID)

    let result = try #require(handler.recordToSave(for: prefixedID))
    #expect(result.recordType == ProfileRecord.recordType)
    #expect(
      result.recordID.recordName
        == "\(ProfileRecord.recordType)|\(profileId.uuidString)")
  }

  @Test("ProfileIndexSyncHandler.applyRemoteChanges accepts prefixed ProfileRecord")
  func profileIndexApplyRemoteChangesAcceptsPrefixedProfileRecord() throws {
    let (handler, container) = try makeProfileIndexHandler()

    let profileId = UUID()
    let prefixedCK = CKRecord(
      recordType: ProfileRecord.recordType,
      recordID: CKRecord.ID(
        recordType: ProfileRecord.recordType,
        uuid: profileId,
        zoneID: handler.zoneID))
    prefixedCK["label"] = "Prefixed" as CKRecordValue
    prefixedCK["currencyCode"] = "AUD" as CKRecordValue
    prefixedCK["financialYearStartMonth"] = 7 as CKRecordValue
    prefixedCK["createdAt"] = Date() as CKRecordValue

    _ = handler.applyRemoteChanges(saved: [prefixedCK], deleted: [])

    let context = ModelContext(container)
    let records = try context.fetch(
      FetchDescriptor<ProfileRecord>(
        predicate: #Predicate { $0.id == profileId })
    )
    #expect(records.count == 1)
    #expect(records.first?.label == "Prefixed")
    #expect(records.first?.encodedSystemFields != nil)
  }

  @Test(
    "ProfileIndexSyncHandler.handleSentRecordZoneChanges caches system fields for prefixed records"
  )
  func profileIndexHandleSentCachesSystemFieldsForPrefixedRecord() throws {
    let (handler, container) = try makeProfileIndexHandler()

    let profileId = UUID()
    let context = ModelContext(container)
    let profile = ProfileRecord(
      id: profileId, label: "Test", currencyCode: "AUD",
      financialYearStartMonth: 7, createdAt: Date())
    context.insert(profile)
    try context.save()
    #expect(profile.encodedSystemFields == nil)

    let savedCK = CKRecord(
      recordType: ProfileRecord.recordType,
      recordID: CKRecord.ID(
        recordType: ProfileRecord.recordType,
        uuid: profileId,
        zoneID: handler.zoneID))
    savedCK["label"] = "Test" as CKRecordValue

    _ = handler.handleSentRecordZoneChanges(
      savedRecords: [savedCK], failedSaves: [], failedDeletes: [])

    let fresh = ModelContext(container)
    let reloaded = try fresh.fetch(
      FetchDescriptor<ProfileRecord>(
        predicate: #Predicate { $0.id == profileId })
    ).first
    #expect(reloaded?.encodedSystemFields != nil)
  }
}
