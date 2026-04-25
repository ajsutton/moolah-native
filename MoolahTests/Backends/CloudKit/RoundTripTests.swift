import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("CloudKit record round trip")
struct RoundTripTests {

  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  @Test("AccountRecord round-trips through toCKRecord + fieldValues")
  func accountRoundTrip() throws {
    let original = AccountRecord(
      id: UUID(),
      name: "Sample",
      type: "bank",
      instrumentId: "AUD",
      position: 7,
      isHidden: true
    )
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(AccountRecord.fieldValues(from: record))
    #expect(decoded.id == original.id)
    #expect(decoded.name == original.name)
    #expect(decoded.type == original.type)
    #expect(decoded.instrumentId == original.instrumentId)
    #expect(decoded.position == original.position)
    #expect(decoded.isHidden == original.isHidden)
  }
}
