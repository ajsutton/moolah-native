import Foundation
import Testing

@testable import Moolah

@Suite("TransactionType")
struct TransactionTypeTests {
  @Test("trade case has stable raw value")
  func tradeRawValue() {
    #expect(TransactionType.trade.rawValue == "trade")
  }

  @Test("trade is in CaseIterable.allCases")
  func tradeInAllCases() {
    #expect(TransactionType.allCases.contains(.trade))
  }

  @Test("trade displayName is Trade")
  func tradeDisplayName() {
    #expect(TransactionType.trade.displayName == "Trade")
  }

  @Test("trade is user-editable")
  func tradeIsUserEditable() {
    #expect(TransactionType.trade.isUserEditable == true)
  }

  @Test("trade is in userSelectableTypes")
  func tradeIsUserSelectable() {
    #expect(TransactionType.userSelectableTypes.contains(.trade))
  }

  @Test("trade Codable round-trips")
  func tradeCodableRoundTrip() throws {
    let encoded = try JSONEncoder().encode(TransactionType.trade)
    let decoded = try JSONDecoder().decode(TransactionType.self, from: encoded)
    #expect(decoded == .trade)
    let raw = String(data: encoded, encoding: .utf8)
    #expect(raw == "\"trade\"")
  }
}
