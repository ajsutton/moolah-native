// Backends/GRDB/Records/StockTickerMetaRecord.swift

import Foundation
import GRDB

/// One row per ticker in `stock_ticker_meta`. Records the ticker's native
/// instrument denomination (discovered from the price API on first fetch)
/// and the date span we have prices for.
///
/// Mirrors the `instrument` / `earliestDate` / `latestDate` fields on the
/// legacy `StockPriceCache` JSON struct.
struct StockTickerMetaRecord {
  static let databaseTableName = "stock_ticker_meta"

  // `INSERT OR REPLACE` instead of GRDB's default `INSERT ... ON CONFLICT
  // DO UPDATE`. The latter hard-codes `RETURNING "rowid"` (see
  // GRDB 7's `MutablePersistableRecord+Upsert.swift`) which breaks
  // against this table's `WITHOUT ROWID` shape. No FK references this
  // table and no triggers fire on delete, so the delete-then-insert
  // semantics of `.replace` are observably equivalent here.
  static let persistenceConflictPolicy = PersistenceConflictPolicy(insert: .replace)

  enum Columns: String, ColumnExpression, CaseIterable {
    case ticker
    case instrumentId = "instrument_id"
    case earliestDate = "earliest_date"
    case latestDate = "latest_date"
  }

  // `CodingKeys` is required (not redundant with `Columns`): GRDB's
  // FetchableRecord/PersistableRecord conformance is Codable-derived, so
  // this enum drives the snake_case ⇄ camelCase mapping when rows decode
  // and parameters bind. `Columns` is consumed by the query interface only.
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

extension StockTickerMetaRecord: Codable {}
extension StockTickerMetaRecord: Sendable {}
extension StockTickerMetaRecord: FetchableRecord {}
extension StockTickerMetaRecord: PersistableRecord {}
