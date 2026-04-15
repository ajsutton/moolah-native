// MoolahTests/Support/FixedStockPriceClient.swift
import Foundation

@testable import Moolah

/// Test double that returns pre-configured stock prices without network calls.
struct FixedStockPriceClient: StockPriceClient, Sendable {
  /// Pre-loaded responses keyed by ticker.
  let responses: [String: StockPriceResponse]

  /// If true, throws on any fetch call (simulates network failure).
  let shouldFail: Bool

  init(responses: [String: StockPriceResponse] = [:], shouldFail: Bool = false) {
    self.responses = responses
    self.shouldFail = shouldFail
  }

  func fetchDailyPrices(ticker: String, from: Date, to: Date) async throws -> StockPriceResponse {
    if shouldFail {
      throw URLError(.notConnectedToInternet)
    }
    guard let response = responses[ticker] else {
      return StockPriceResponse(instrument: .AUD, prices: [:])
    }

    let calendar = Calendar(identifier: .gregorian)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]

    // Filter to only return prices within the requested date range
    var filtered: [String: Decimal] = [:]
    var current = from
    while current <= to {
      let key = formatter.string(from: current)
      if let price = response.prices[key] {
        filtered[key] = price
      }
      current = calendar.date(byAdding: .day, value: 1, to: current)!
    }
    return StockPriceResponse(instrument: response.instrument, prices: filtered)
  }
}
