// Backends/GRDB/Records/ExchangeRateRecord.swift

import Foundation
import GRDB

/// One row in the `exchange_rate` table — one (base, quote, date) triple.
///
/// Rates are `Double` (SQL `REAL`) per `guides/DATABASE_CODE_GUIDE.md` §3.
/// `Decimal` is forbidden in record structs; conversion to/from `Decimal`
/// for use by `ExchangeRateService` happens at the service boundary.
struct ExchangeRateRecord {
  static let databaseTableName = "exchange_rate"

  enum Columns: String, ColumnExpression, CaseIterable {
    case base, quote, date, rate
  }

  /// Base instrument code (e.g. `"USD"`).
  var base: String
  /// Quote instrument code (e.g. `"AUD"`).
  var quote: String
  /// ISO-8601 date (`YYYY-MM-DD`).
  var date: String
  /// Price of one unit of `base` in `quote` on `date`.
  var rate: Double
}

extension ExchangeRateRecord: Codable {}
extension ExchangeRateRecord: Sendable {}
extension ExchangeRateRecord: FetchableRecord {}
extension ExchangeRateRecord: PersistableRecord {}
