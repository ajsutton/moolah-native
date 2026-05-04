// MoolahTests/Backends/GRDB/AccountRowValuationModeTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("AccountRow.valuationMode")
struct AccountRowValuationModeTests {
  @Test("init(domain:) writes valuationMode")
  func initFromDomain() {
    let account = Account(
      name: "Brokerage", type: .investment, instrument: .AUD,
      valuationMode: .calculatedFromTrades)
    let row = AccountRow(domain: account)
    #expect(row.valuationMode == "calculatedFromTrades")
  }

  @Test("toDomain carries the column back")
  func toDomain() throws {
    let row = AccountRow(
      id: UUID(), recordName: "AccountRecord|x", name: "B",
      type: "investment", instrumentId: "AUD", position: 0,
      isHidden: false, encodedSystemFields: nil,
      valuationMode: "calculatedFromTrades")
    let account = try row.toDomain()
    #expect(account.valuationMode == .calculatedFromTrades)
  }

  @Test("toDomain falls back to recordedValue on unknown raw value")
  func toDomainUnknownValue() throws {
    let row = AccountRow(
      id: UUID(), recordName: "AccountRecord|x", name: "B",
      type: "investment", instrumentId: "AUD", position: 0,
      isHidden: false, encodedSystemFields: nil,
      valuationMode: "garbage")
    let account = try row.toDomain()
    #expect(account.valuationMode == .recordedValue)
  }
}
