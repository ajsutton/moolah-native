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
      recordType: "CD_AccountRecord", uuid: uuid, zoneID: zoneID)
    #expect(
      recordID.recordName
        == "CD_AccountRecord|1CAC9567-574B-481A-BADA-D595325CBE0C")
    #expect(recordID.zoneID == zoneID)
  }

  // MARK: - uuid

  @Test
  func uuidStripsPrefix() throws {
    let uuid = try #require(UUID(uuidString: "1CAC9567-574B-481A-BADA-D595325CBE0C"))
    let recordID = CKRecord.ID(
      recordName: "CD_AccountRecord|1CAC9567-574B-481A-BADA-D595325CBE0C",
      zoneID: zoneID)
    #expect(recordID.uuid == uuid)
  }

  @Test
  func uuidAcceptsBareUUIDLegacyFormat() throws {
    let uuid = try #require(UUID(uuidString: "1CAC9567-574B-481A-BADA-D595325CBE0C"))
    let recordID = CKRecord.ID(
      recordName: "1CAC9567-574B-481A-BADA-D595325CBE0C",
      zoneID: zoneID)
    #expect(recordID.uuid == uuid)
  }

  @Test
  func uuidReturnsNilForInstrumentIDs() {
    #expect(CKRecord.ID(recordName: "AUD", zoneID: zoneID).uuid == nil)
    #expect(CKRecord.ID(recordName: "ASX:BHP", zoneID: zoneID).uuid == nil)
  }

  @Test
  func uuidReturnsNilForNonUUIDAfterPrefix() {
    let recordID = CKRecord.ID(
      recordName: "CD_AccountRecord|not-a-uuid",
      zoneID: zoneID)
    #expect(recordID.uuid == nil)
  }

  // MARK: - systemFieldsKey

  @Test
  func systemFieldsKeyStripsTypePrefixForPrefixedRecord() {
    let recordID = CKRecord.ID(
      recordName: "CD_AccountRecord|1CAC9567-574B-481A-BADA-D595325CBE0C",
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
