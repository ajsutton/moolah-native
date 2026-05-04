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

  @Test("Codable round-trips through JSON")
  func codableRoundTrip() throws {
    for mode in ValuationMode.allCases {
      let data = try JSONEncoder().encode(mode)
      let decoded = try JSONDecoder().decode(ValuationMode.self, from: data)
      #expect(decoded == mode)
    }
  }

  @Test("CaseIterable lists both cases in order")
  func caseIterable() {
    #expect(ValuationMode.allCases == [.recordedValue, .calculatedFromTrades])
  }
}
