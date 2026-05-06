import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("ProfileRow — dataFormatVersion plumbing")
struct ProfileRowDataFormatVersionTests {
  @Test("init(domain:) carries dataFormatVersion through")
  func mappingFromDomain() {
    let profile = Profile(label: "Carries", dataFormatVersion: 1)
    let row = ProfileRow(domain: profile)
    #expect(row.dataFormatVersion == 1)
  }

  @Test("toDomain() carries dataFormatVersion through")
  func mappingToDomain() {
    let row = ProfileRow(
      id: UUID(),
      recordName: "ProfileRecord|abc",
      label: "Carries",
      currencyCode: "AUD",
      financialYearStartMonth: 7,
      createdAt: Date(),
      encodedSystemFields: nil,
      dataFormatVersion: 1)
    #expect(row.toDomain().dataFormatVersion == 1)
  }

  @Test("Columns and CodingKeys both expose dataFormatVersion")
  func columnsAndCodingKeysAlign() {
    #expect(ProfileRow.Columns.dataFormatVersion.rawValue == "data_format_version")
    #expect(ProfileRow.CodingKeys.dataFormatVersion.rawValue == "data_format_version")
  }

  @Test("toCKRecord uploads dataFormatVersion as Int64")
  func toCKRecordIncludesDataFormatVersion() {
    let row = ProfileRow(
      id: UUID(),
      recordName: "ProfileRecord|abc",
      label: "Test",
      currencyCode: "AUD",
      financialYearStartMonth: 7,
      createdAt: Date(),
      encodedSystemFields: nil,
      dataFormatVersion: 1)
    let zoneID = CKRecordZone.ID(zoneName: "profile-index", ownerName: "_defaultOwner")
    let record = row.toCKRecord(in: zoneID)
    #expect(record["dataFormatVersion"] as? Int64 == 1)
  }

  @Test("fieldValues(from:) reads dataFormatVersion from the CKRecord")
  func fieldValuesReadsDataFormatVersion() throws {
    let zoneID = CKRecordZone.ID(zoneName: "profile-index", ownerName: "_defaultOwner")
    let recordID = CKRecord.ID(
      recordType: ProfileRow.recordType, uuid: UUID(), zoneID: zoneID)
    let record = CKRecord(recordType: ProfileRow.recordType, recordID: recordID)
    record["createdAt"] = Date()
    record["currencyCode"] = "AUD"
    record["financialYearStartMonth"] = Int64(7)
    record["label"] = "Test"
    record["dataFormatVersion"] = Int64(2)
    let row = try #require(ProfileRow.fieldValues(from: record))
    #expect(row.dataFormatVersion == 2)
  }

  @Test("fieldValues(from:) treats absent dataFormatVersion as 0 — pre-gate baseline")
  func fieldValuesAbsentMeansZero() throws {
    let zoneID = CKRecordZone.ID(zoneName: "profile-index", ownerName: "_defaultOwner")
    let recordID = CKRecord.ID(
      recordType: ProfileRow.recordType, uuid: UUID(), zoneID: zoneID)
    let record = CKRecord(recordType: ProfileRow.recordType, recordID: recordID)
    record["createdAt"] = Date()
    record["currencyCode"] = "AUD"
    record["financialYearStartMonth"] = Int64(7)
    record["label"] = "Test"
    // Deliberately omit dataFormatVersion.
    let row = try #require(ProfileRow.fieldValues(from: record))
    #expect(row.dataFormatVersion == 0)
  }
}
