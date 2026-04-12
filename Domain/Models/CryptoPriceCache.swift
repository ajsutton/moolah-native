// Domain/Models/CryptoPriceCache.swift
import Foundation

/// On-disk cache for a single crypto token. Contains daily closing prices in USD.
struct CryptoPriceCache: Codable, Sendable, Equatable {
  let tokenId: String  // e.g. "1:native"
  let symbol: String  // e.g. "ETH" — display only
  var earliestDate: String  // ISO date string "YYYY-MM-DD"
  var latestDate: String  // ISO date string "YYYY-MM-DD"
  var prices: [String: Decimal]  // date string -> daily closing price in USD
}
