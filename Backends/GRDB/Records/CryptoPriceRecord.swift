// Backends/GRDB/Records/CryptoPriceRecord.swift

import Foundation
import GRDB

/// One row in `crypto_price` — one (token_id, date) pair with the day's
/// closing price in USD.
///
/// Crypto prices are always denominated in USD (`CoinGeckoCatalog`'s
/// canonical anchor). Multi-step conversion to other reporting instruments
/// happens in Swift via the conversion service.
struct CryptoPriceRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "crypto_price"

  enum Columns: String, ColumnExpression, CaseIterable {
    case tokenId = "token_id"
    case date
    case priceUsd = "price_usd"
  }

  enum CodingKeys: String, CodingKey {
    case tokenId = "token_id"
    case date
    case priceUsd = "price_usd"
  }

  /// Token id (e.g. `"1:native"`).
  var tokenId: String
  /// ISO-8601 date (`YYYY-MM-DD`).
  var date: String
  /// Daily closing price in USD.
  var priceUsd: Double
}
