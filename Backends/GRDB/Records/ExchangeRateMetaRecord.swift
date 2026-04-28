// Backends/GRDB/Records/ExchangeRateMetaRecord.swift

import Foundation
import GRDB

/// One row in `exchange_rate_meta` — one entry per cached base instrument,
/// recording the date span we have rates for.
///
/// Mirrors the `earliestDate` / `latestDate` fields on the legacy
/// `ExchangeRateCache` JSON struct.
struct ExchangeRateMetaRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "exchange_rate_meta"

  enum Columns: String, ColumnExpression, CaseIterable {
    case base
    case earliestDate = "earliest_date"
    case latestDate = "latest_date"
  }

  enum CodingKeys: String, CodingKey {
    case base
    case earliestDate = "earliest_date"
    case latestDate = "latest_date"
  }

  var base: String
  /// ISO-8601 date string of the earliest cached rate.
  var earliestDate: String
  /// ISO-8601 date string of the latest cached rate.
  var latestDate: String
}
