// Backends/GRDB/Records/CryptoTokenMetaRecord.swift

import Foundation
import GRDB

/// One row per token in `crypto_token_meta`. Records the display symbol and
/// the date span we have USD prices for.
///
/// Mirrors the `symbol` / `earliestDate` / `latestDate` fields on the
/// legacy `CryptoPriceCache` JSON struct.
struct CryptoTokenMetaRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "crypto_token_meta"

  enum Columns: String, ColumnExpression, CaseIterable {
    case tokenId, symbol, earliestDate, latestDate
  }

  var tokenId: String
  /// Display symbol (e.g. `"ETH"`). Not used for lookups; kept for support
  /// tooling.
  var symbol: String
  var earliestDate: String
  var latestDate: String
}
