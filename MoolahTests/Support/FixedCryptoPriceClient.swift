// MoolahTests/Support/FixedCryptoPriceClient.swift
import Foundation

@testable import Moolah

/// Test double that returns pre-configured crypto prices without network calls.
struct FixedCryptoPriceClient: CryptoPriceClient, Sendable {
  /// Pre-loaded prices: instrument ID -> { date string -> price in USD }
  let prices: [String: [String: Decimal]]

  /// If true, throws on any fetch call (simulates network failure).
  let shouldFail: Bool

  init(prices: [String: [String: Decimal]] = [:], shouldFail: Bool = false) {
    self.prices = prices
    self.shouldFail = shouldFail
  }

  func dailyPrice(for mapping: CryptoProviderMapping, on date: Date) async throws -> Decimal {
    if shouldFail { throw URLError(.notConnectedToInternet) }
    let dateString = Self.dateFormatter.string(from: date)
    guard let price = prices[mapping.instrumentId]?[dateString] else {
      throw CryptoPriceError.noPriceAvailable(tokenId: mapping.instrumentId, date: dateString)
    }
    return price
  }

  func dailyPrices(
    for mapping: CryptoProviderMapping, in range: ClosedRange<Date>
  ) async throws -> [String: Decimal] {
    if shouldFail { throw URLError(.notConnectedToInternet) }
    guard let tokenPrices = prices[mapping.instrumentId] else { return [:] }

    let calendar = Calendar(identifier: .gregorian)
    var filtered: [String: Decimal] = [:]
    var current = range.lowerBound
    while current <= range.upperBound {
      let key = Self.dateFormatter.string(from: current)
      if let price = tokenPrices[key] {
        filtered[key] = price
      }
      current = calendar.date(byAdding: .day, value: 1, to: current)!
    }
    return filtered
  }

  func currentPrices(for mappings: [CryptoProviderMapping]) async throws -> [String: Decimal] {
    if shouldFail { throw URLError(.notConnectedToInternet) }
    var result: [String: Decimal] = [:]
    for mapping in mappings {
      if let tokenPrices = prices[mapping.instrumentId],
        let latest = tokenPrices.keys.max()
      {
        result[mapping.instrumentId] = tokenPrices[latest]
      }
    }
    return result
  }

  nonisolated(unsafe) private static let dateFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    return f
  }()
}
