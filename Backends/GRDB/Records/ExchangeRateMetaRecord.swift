// Backends/GRDB/Records/ExchangeRateMetaRecord.swift

import Foundation
import GRDB

/// One row in `exchange_rate_meta` — one entry per cached base instrument,
/// recording the date span we have rates for.
///
/// Mirrors the `earliestDate` / `latestDate` fields on the legacy
/// `ExchangeRateCache` JSON struct.
struct ExchangeRateMetaRecord {
  static let databaseTableName = "exchange_rate_meta"

  // `INSERT OR REPLACE` instead of GRDB's default `INSERT ... ON CONFLICT
  // DO UPDATE`. The latter goes through `upsert(_:)`, which hard-codes
  // `RETURNING "rowid"` and breaks against the `WITHOUT ROWID` shape
  // chosen for this table per `guides/DATABASE_SCHEMA_GUIDE.md` §3. No
  // FK references this table and no triggers fire on delete, so the
  // delete-then-insert semantics of `.replace` are observably equivalent
  // to an in-place `DO UPDATE`.
  static let persistenceConflictPolicy = PersistenceConflictPolicy(insert: .replace)

  enum Columns: String, ColumnExpression, CaseIterable {
    case base
    case earliestDate = "earliest_date"
    case latestDate = "latest_date"
  }

  // `CodingKeys` is required (not redundant with `Columns`): GRDB's
  // FetchableRecord/PersistableRecord conformance is Codable-derived, so
  // this enum drives the snake_case ⇄ camelCase mapping when rows decode
  // and parameters bind. `Columns` is consumed by the query interface only.
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

extension ExchangeRateMetaRecord: Codable {}
extension ExchangeRateMetaRecord: Sendable {}
extension ExchangeRateMetaRecord: FetchableRecord {}
extension ExchangeRateMetaRecord: PersistableRecord {}
