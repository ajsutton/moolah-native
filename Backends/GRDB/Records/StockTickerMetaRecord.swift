// Backends/GRDB/Records/StockTickerMetaRecord.swift

import Foundation
import GRDB

/// One row per ticker in `stock_ticker_meta`. Records the ticker's native
/// instrument denomination (discovered from the price API on first fetch)
/// and the date span we have prices for.
///
/// Mirrors the `instrument` / `earliestDate` / `latestDate` fields on the
/// legacy `StockPriceCache` JSON struct.
struct StockTickerMetaRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "stock_ticker_meta"

  enum Columns: String, ColumnExpression, CaseIterable {
    case ticker
    case instrumentId = "instrument_id"
    case earliestDate = "earliest_date"
    case latestDate = "latest_date"
  }

  enum CodingKeys: String, CodingKey {
    case ticker
    case instrumentId = "instrument_id"
    case earliestDate = "earliest_date"
    case latestDate = "latest_date"
  }

  var ticker: String
  /// Instrument code in which the ticker is priced (e.g. `"AUD"` for
  /// `BHP.AX`, `"USD"` for `AAPL`). Discovered from the price API.
  var instrumentId: String
  var earliestDate: String
  var latestDate: String
}
