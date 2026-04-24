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

  // MARK: - uuidRecordName()

  @Test
  func uuidRecordNameStripsPrefix() throws {
    let uuid = try #require(UUID(uuidString: "1CAC9567-574B-481A-BADA-D595325CBE0C"))
    let recordID = CKRecord.ID(
      recordName: "CD_AccountRecord|1CAC9567-574B-481A-BADA-D595325CBE0C",
      zoneID: zoneID)
    #expect(recordID.uuidRecordName() == uuid)
  }

  @Test
  func uuidRecordNameAcceptsBareUUIDLegacyFormat() throws {
    let uuid = try #require(UUID(uuidString: "1CAC9567-574B-481A-BADA-D595325CBE0C"))
    let recordID = CKRecord.ID(
      recordName: "1CAC9567-574B-481A-BADA-D595325CBE0C",
      zoneID: zoneID)
    #expect(recordID.uuidRecordName() == uuid)
  }

  @Test
  func uuidRecordNameReturnsNilForInstrumentIDs() {
    #expect(
      CKRecord.ID(recordName: "AUD", zoneID: zoneID).uuidRecordName() == nil)
    #expect(
      CKRecord.ID(recordName: "ASX:BHP", zoneID: zoneID).uuidRecordName()
        == nil)
  }

  @Test
  func uuidRecordNameReturnsNilForNonUUIDAfterPrefix() {
    let recordID = CKRecord.ID(
      recordName: "CD_AccountRecord|not-a-uuid",
      zoneID: zoneID)
    #expect(recordID.uuidRecordName() == nil)
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
