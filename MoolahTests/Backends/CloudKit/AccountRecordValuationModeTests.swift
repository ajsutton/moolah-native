import Foundation
import Testing

@testable import Moolah

@Suite("AccountRecord (SwiftData mirror) valuationMode")
struct AccountRecordValuationModeTests {
  @Test("from(_:) writes valuationMode")
  func fromAccountWritesField() {
    let account = Account(
      name: "Brokerage", type: .investment, instrument: .AUD,
      valuationMode: .calculatedFromTrades)
    let record = AccountRecord.from(account)
    #expect(record.valuationMode == "calculatedFromTrades")
  }

  @Test("toDomain carries valuationMode through")
  func toDomainCarriesField() throws {
    let record = AccountRecord(
      name: "Brokerage", type: "investment",
      instrumentId: "AUD", position: 0, isHidden: false)
    record.valuationMode = "calculatedFromTrades"
    let account = try record.toDomain()
    #expect(account.valuationMode == .calculatedFromTrades)
  }

  @Test("missing column defaults to recordedValue")
  func legacyRowDecodesAsRecordedValue() throws {
    let record = AccountRecord(
      name: "Old", type: "investment",
      instrumentId: "AUD", position: 0, isHidden: false)
    let account = try record.toDomain()
    #expect(account.valuationMode == .recordedValue)
  }
}
