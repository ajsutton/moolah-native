// Backends/GRDB/Records/StockPriceRecord.swift

import Foundation
import GRDB

/// One row in `stock_price` — one (ticker, date) pair with the day's
/// adjusted close price in the ticker's native instrument.
///
/// The instrument denomination is recorded once per ticker in
/// `stock_ticker_meta` rather than duplicated on every price row.
struct StockPriceRecord {
  static let databaseTableName = "stock_price"

  enum Columns: String, ColumnExpression, CaseIterable {
    case ticker, date, price
  }

  /// Ticker symbol (e.g. `"BHP.AX"`).
  var ticker: String
  /// ISO-8601 date (`YYYY-MM-DD`).
  var date: String
  /// Adjusted close price in the ticker's native instrument.
  var price: Double
}

extension StockPriceRecord: Codable {}
extension StockPriceRecord: Sendable {}
extension StockPriceRecord: FetchableRecord {}
extension StockPriceRecord: PersistableRecord {}
