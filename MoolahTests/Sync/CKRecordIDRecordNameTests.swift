import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("CKRecord.ID — recordName helpers")
struct CKRecordIDRecordNameTests {

  private let zoneID = CKRecordZone.ID(
    zoneName: "profile-test",
    ownerName: CKCurrentUserDefaultName
  )

  // MARK: - init(recordType:uuid:zoneID:)

  @Test
  func initBuildsPrefixedRecordName() throws {
    let uuid = try #require(UUID(uuidString: "1CAC9567-574B-481A-BADA-D595325CBE0C"))
    let recordID = CKRecord.ID(
      recordType: "AccountRecord", uuid: uuid, zoneID: zoneID)
    #expect(
      recordID.recordName
        == "AccountRecord|1CAC9567-574B-481A-BADA-D595325CBE0C")
    #expect(recordID.zoneID == zoneID)
  }

  // MARK: - uuid

  @Test
  func uuidStripsPrefix() throws {
    let uuid = try #require(UUID(uuidString: "1CAC9567-574B-481A-BADA-D595325CBE0C"))
    let recordID = CKRecord.ID(
      recordName: "AccountRecord|1CAC9567-574B-481A-BADA-D595325CBE0C",
      zoneID: zoneID)
    #expect(recordID.uuid == uuid)
  }

  @Test
  func uuidReturnsNilForBareUUIDLegacyFormat() {
    // Pre-issue #416 records used `<UUID>` directly. Persisted CKSyncEngine
    // state from that era could collide with the new `<TYPE>|<UUID>` form
    // during batch build (both would resolve to the same SwiftData row,
    // causing the same `CKRecord` to be appended twice and CloudKit to
    // reject the entire batch). Treating bare UUIDs as non-UUID names
    // breaks the collision and lets the lifecycle's purge routine drop the
    // stale entries.
    let recordID = CKRecord.ID(
      recordName: "1CAC9567-574B-481A-BADA-D595325CBE0C",
      zoneID: zoneID)
    #expect(recordID.uuid == nil)
  }

  @Test
  func uuidReturnsNilForInstrumentIDs() {
    #expect(CKRecord.ID(recordName: "AUD", zoneID: zoneID).uuid == nil)
    #expect(CKRecord.ID(recordName: "ASX:BHP", zoneID: zoneID).uuid == nil)
  }

  @Test
  func uuidReturnsNilForNonUUIDAfterPrefix() {
    let recordID = CKRecord.ID(
      recordName: "AccountRecord|not-a-uuid",
      zoneID: zoneID)
    #expect(recordID.uuid == nil)
  }

  // MARK: - prefixedRecordType

  @Test
  func prefixedRecordTypeReturnsTypeFromPrefix() {
    let recordID = CKRecord.ID(
      recordName: "AccountRecord|1CAC9567-574B-481A-BADA-D595325CBE0C",
      zoneID: zoneID)
    #expect(recordID.prefixedRecordType == "AccountRecord")
  }

  @Test
  func prefixedRecordTypeReturnsNilForBareUUID() {
    let recordID = CKRecord.ID(
      recordName: "1CAC9567-574B-481A-BADA-D595325CBE0C",
      zoneID: zoneID)
    #expect(recordID.prefixedRecordType == nil)
  }

  @Test
  func prefixedRecordTypeReturnsNilForInstrumentID() {
    #expect(CKRecord.ID(recordName: "AUD", zoneID: zoneID).prefixedRecordType == nil)
    #expect(CKRecord.ID(recordName: "ASX:BHP", zoneID: zoneID).prefixedRecordType == nil)
  }

  // MARK: - systemFieldsKey

  @Test
  func systemFieldsKeyStripsTypePrefixForPrefixedRecord() {
    let recordID = CKRecord.ID(
      recordName: "AccountRecord|1CAC9567-574B-481A-BADA-D595325CBE0C",
      zoneID: zoneID)
    #expect(recordID.systemFieldsKey == "1CAC9567-574B-481A-BADA-D595325CBE0C")
  }

  @Test
  func systemFieldsKeyReturnsBareUUIDForLegacyRecord() {
    let recordID = CKRecord.ID(
      recordName: "1CAC9567-574B-481A-BADA-D595325CBE0C",
      zoneID: zoneID)
    #expect(recordID.systemFieldsKey == "1CAC9567-574B-481A-BADA-D595325CBE0C")
  }

  @Test
  func systemFieldsKeyReturnsRecordNameForInstrument() {
    let recordID = CKRecord.ID(recordName: "ASX:BHP", zoneID: zoneID)
    #expect(recordID.systemFieldsKey == "ASX:BHP")
  }
}
