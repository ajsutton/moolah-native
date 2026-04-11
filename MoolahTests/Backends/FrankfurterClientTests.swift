// MoolahTests/Backends/FrankfurterClientTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("FrankfurterClient")
struct FrankfurterClientTests {
  @Test func parsesV2ResponseFormat() throws {
    let json = """
      [
        {"date": "2026-04-11", "base": "AUD", "quote": "USD", "rate": 0.632},
        {"date": "2026-04-11", "base": "AUD", "quote": "EUR", "rate": 0.581},
        {"date": "2026-04-10", "base": "AUD", "quote": "USD", "rate": 0.629}
      ]
      """
    let data = Data(json.utf8)
    let result = try FrankfurterClient.parseResponse(data)

    #expect(result.count == 2)  // 2 dates
    #expect(result["2026-04-11"]?["USD"] == Decimal(string: "0.632")!)
    #expect(result["2026-04-11"]?["EUR"] == Decimal(string: "0.581")!)
    #expect(result["2026-04-10"]?["USD"] == Decimal(string: "0.629")!)
  }

  @Test func parsesEmptyResponse() throws {
    let data = Data("[]".utf8)
    let result = try FrankfurterClient.parseResponse(data)
    #expect(result.isEmpty)
  }
}
