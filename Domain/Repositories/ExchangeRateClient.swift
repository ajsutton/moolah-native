// Domain/Repositories/ExchangeRateClient.swift
import Foundation

/// Abstraction for fetching exchange rates from an external source.
/// Production: FrankfurterClient. Tests: FixedRateClient.
protocol ExchangeRateClient: Sendable {
  /// Fetch rates for a base currency over a date range.
  /// Returns a dictionary keyed by ISO date string, each value mapping quote currency codes to rates.
  func fetchRates(base: String, from: Date, to: Date) async throws -> [String: [String: Decimal]]
}
