import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("AccountRow ↔ CKRecord round-trip (valuationMode)")
struct AccountRowCloudKitFieldsTests {
  @Test("explicit valuationMode round-trips")
  func roundTrip() throws {
    for raw in ["recordedValue", "calculatedFromTrades"] {
      let row = AccountRow(
        id: UUID(), recordName: "AccountRecord|x", name: "B",
        type: "investment", instrumentId: "AUD", position: 0,
        isHidden: false, encodedSystemFields: nil, valuationMode: raw)
      let zoneID = CKRecordZone.ID(zoneName: "z", ownerName: CKCurrentUserDefaultName)
      let record = row.toCKRecord(in: zoneID)
      let decoded = try #require(AccountRow.fieldValues(from: record))
      #expect(decoded.valuationMode == raw)
    }
  }

  @Test("missing CKRecord field decodes as recordedValue")
  func missingFieldFallsBack() throws {
    let zoneID = CKRecordZone.ID(zoneName: "z", ownerName: CKCurrentUserDefaultName)
    let recordID = CKRecord.ID(
      recordType: AccountRow.recordType, uuid: UUID(), zoneID: zoneID)
    let record = CKRecord(recordType: AccountRow.recordType, recordID: recordID)
    record["name"] = "B"
    record["type"] = "investment"
    record["instrumentId"] = "AUD"
    record["position"] = Int64(0)
    record["isHidden"] = Int64(0)
    // valuationMode intentionally not set
    let decoded = try #require(AccountRow.fieldValues(from: record))
    #expect(decoded.valuationMode == "recordedValue")
  }
}
