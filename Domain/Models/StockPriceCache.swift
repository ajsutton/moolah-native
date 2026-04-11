// Domain/Models/StockPriceCache.swift
import Foundation

/// On-disk cache for a single stock ticker. Contains adjusted close prices for every cached trading day.
struct StockPriceCache: Codable, Sendable, Equatable {
  let ticker: String  // e.g. "BHP.AX"
  let currency: Currency  // denomination discovered from API (e.g. .AUD)
  var earliestDate: String  // ISO date string "YYYY-MM-DD"
  var latestDate: String  // ISO date string "YYYY-MM-DD"
  var prices: [String: Decimal]  // date string -> adjusted close price
}
