// Domain/Models/ExchangeRateCache.swift
import Foundation

/// On-disk cache for a single base currency. Contains rates for every cached trading day.
struct ExchangeRateCache: Codable, Sendable, Equatable {
  let base: String
  var earliestDate: String  // ISO date string "YYYY-MM-DD"
  var latestDate: String  // ISO date string "YYYY-MM-DD"
  var rates: [String: [String: Decimal]]  // date string -> { quote code -> rate }
}
