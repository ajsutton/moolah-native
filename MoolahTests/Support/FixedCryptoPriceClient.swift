// MoolahTests/Support/FixedCryptoPriceClient.swift
import Foundation

@testable import Moolah

/// Test double that returns pre-configured crypto prices without network calls.
struct FixedCryptoPriceClient: CryptoPriceClient, Sendable {
  /// Pre-loaded prices: token ID -> { date string -> price in USD }
  let prices: [String: [String: Decimal]]

  /// If true, throws on any fetch call (simulates network failure).
  let shouldFail: Bool

  init(prices: [String: [String: Decimal]] = [:], shouldFail: Bool = false) {
    self.prices = prices
    self.shouldFail = shouldFail
  }

  func dailyPrice(for token: CryptoToken, on date: Date) async throws -> Decimal {
    if shouldFail { throw URLError(.notConnectedToInternet) }
    let dateString = Self.dateFormatter.string(from: date)
    guard let price = prices[token.id]?[dateString] else {
      throw CryptoPriceError.noPriceAvailable(tokenId: token.id, date: dateString)
    }
    return price
  }

  func dailyPrices(
    for token: CryptoToken, in range: ClosedRange<Date>
  ) async throws -> [String: Decimal] {
    if shouldFail { throw URLError(.notConnectedToInternet) }
    guard let tokenPrices = prices[token.id] else { return [:] }

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

  func currentPrices(for tokens: [CryptoToken]) async throws -> [String: Decimal] {
    if shouldFail { throw URLError(.notConnectedToInternet) }
    var result: [String: Decimal] = [:]
    for token in tokens {
      if let tokenPrices = prices[token.id],
        let latest = tokenPrices.keys.sorted().last
      {
        result[token.id] = tokenPrices[latest]
      }
    }
    return result
  }

  private static nonisolated(unsafe) let dateFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    return f
  }()
}
