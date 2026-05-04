import Foundation
import Testing

@testable import Moolah

@Suite("ValuationMode")
struct ValuationModeTests {
  @Test("raw values are stable wire identifiers")
  func rawValues() {
    #expect(ValuationMode.recordedValue.rawValue == "recordedValue")
    #expect(ValuationMode.calculatedFromTrades.rawValue == "calculatedFromTrades")
  }

  @Test("decodes from raw value")
  func decode() {
    #expect(ValuationMode(rawValue: "recordedValue") == .recordedValue)
    #expect(ValuationMode(rawValue: "calculatedFromTrades") == .calculatedFromTrades)
    #expect(ValuationMode(rawValue: "unknown") == nil)
  }

  @Test("CaseIterable lists both cases")
  func caseIterable() {
    #expect(Set(ValuationMode.allCases) == [.recordedValue, .calculatedFromTrades])
  }
}
