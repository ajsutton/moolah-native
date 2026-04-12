// Domain/Repositories/CryptoPriceClient.swift
import Foundation

enum CryptoPriceError: Error, Equatable {
  case noPriceAvailable(tokenId: String, date: String)
  case noProviderMapping(tokenId: String, provider: String)
  case allProvidersFailed(tokenId: String)
}

/// Abstraction for fetching cryptocurrency prices from an external source.
/// Implementations: CryptoCompareClient (default), BinanceClient (fallback), CoinGeckoClient (premium).
/// All prices are denominated in USD.
protocol CryptoPriceClient: Sendable {
  /// Fetch the daily closing price for a token in USD on a specific date.
  func dailyPrice(for token: CryptoToken, on date: Date) async throws -> Decimal

  /// Fetch daily closing prices for a token in USD over a date range.
  /// Returns prices keyed by ISO date string for each available trading day.
  func dailyPrices(for token: CryptoToken, in range: ClosedRange<Date>) async throws -> [String:
    Decimal]

  /// Fetch current prices for multiple tokens in a single request (where supported).
  /// Returns prices keyed by token ID.
  func currentPrices(for tokens: [CryptoToken]) async throws -> [String: Decimal]
}
