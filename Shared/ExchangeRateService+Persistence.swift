// Shared/ExchangeRateService+Persistence.swift

import Foundation
import GRDB

// MARK: - ExchangeRateService SQL persistence

// SQL persistence for `ExchangeRateService`. Lives in its own file so the
// main actor body stays under SwiftLint's `type_body_length` and
// `file_length` thresholds.

extension ExchangeRateService {
  /// Hydrates `caches[base]` from the GRDB-backed `exchange_rate` /
  /// `exchange_rate_meta` tables. No-op when the base has no rows; marks the
  /// base as hydrated either way so we don't re-query on every miss.
  ///
  /// Rates are stored as `REAL` (`Double`) in SQLite per
  /// `guides/DATABASE_CODE_GUIDE.md` §3, and converted back to `Decimal` at
  /// the boundary so the in-memory cache stays decimal-precise.
  func loadCache(base: String) async throws {
    let snapshot: ExchangeRateCache? = try await database.read { database in
      let metaRecord =
        try ExchangeRateMetaRecord
        .filter(ExchangeRateMetaRecord.Columns.base == base)
        .fetchOne(database)
      guard let metaRecord else { return nil }
      let rateRecords =
        try ExchangeRateRecord
        .filter(ExchangeRateRecord.Columns.base == base)
        .fetchAll(database)
      // Decode via the `String` form of the stored `Double` so we recover
      // the source decimal exactly (e.g. `0.581`), avoiding the precision
      // tail that `Decimal(_: Double)` would introduce
      // (`0.5810000000000001024`).
      var rates: [String: [String: Decimal]] = [:]
      for record in rateRecords {
        let value = Decimal(string: String(record.rate)) ?? Decimal(record.rate)
        rates[record.date, default: [:]][record.quote] = value
      }
      return ExchangeRateCache(
        base: base,
        earliestDate: metaRecord.earliestDate,
        latestDate: metaRecord.latestDate,
        rates: rates
      )
    }
    if let snapshot { caches[base] = snapshot }
    hydratedBases.insert(base)
  }

  /// Persists the rows produced by `mergeReturningDelta` for `base` plus
  /// the latest meta-bounds, all in a single transaction.
  ///
  /// Each delta row is written `INSERT OR REPLACE` so a re-fetched date
  /// updates in place; the meta row uses `ExchangeRateMetaRecord`'s
  /// `.replace` conflict policy. Critically there is no `deleteAll` here
  /// — historic rates never change, and rewriting the entire base on
  /// every fetch saturated the GRDB queue during chart renders. The
  /// rollback contract remains intact because the whole batch runs in
  /// one transaction and any failure rolls every statement back.
  ///
  /// Captures `caches[base]` before suspending on `database.write`. Actor
  /// re-entrancy is acceptable here: a concurrent merge will produce its
  /// own delta with its own `persistDelta` afterwards, so the disk
  /// converges to the latest in-memory state. A crash between two writes
  /// leaves the disk at an intermediate-but-consistent snapshot —
  /// acceptable for a best-effort persistent cache.
  func persistDelta(base: String, deltaRecords: [ExchangeRateRecord]) async throws {
    guard let cache = caches[base] else { return }
    let meta = ExchangeRateMetaRecord(
      base: base, earliestDate: cache.earliestDate, latestDate: cache.latestDate
    )
    try await database.write { database in
      // GRDB caches the insert statement internally; no explicit cachedStatement needed.
      for record in deltaRecords {
        try record.insert(database, onConflict: .replace)
      }
      try meta.insert(database, onConflict: .replace)
    }
  }
}
