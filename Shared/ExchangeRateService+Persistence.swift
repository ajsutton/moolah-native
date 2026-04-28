// Shared/ExchangeRateService+Persistence.swift

import Foundation
import GRDB

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

  /// Persists `caches[base]` to SQLite. Replaces the prior rows for this
  /// base in a single transaction (delete-and-rewrite) and upserts the meta
  /// row alongside, so the meta is never out of sync with the rates.
  ///
  /// Multi-statement; covered by a rollback test in
  /// `ExchangeRateServicePersistenceTests.swift`.
  ///
  /// Captures `caches[base]` before suspending on `database.write`. Actor
  /// re-entrancy is acceptable here: a concurrent merge will trigger its
  /// own `saveCache` afterwards, so the disk converges to the latest
  /// in-memory state. A crash between the two writes leaves the disk at
  /// an intermediate-but-consistent snapshot — acceptable for a
  /// best-effort persistent cache.
  func saveCache(base: String) async throws {
    guard let cache = caches[base] else { return }
    // `Decimal` lacks a direct `Double` accessor; round-trip via
    // `NSDecimalNumber` (`doubleValue`) — same path GRDB would take.
    let records: [ExchangeRateRecord] = cache.rates.flatMap { dateString, quotes in
      quotes.map { quote, rate in
        ExchangeRateRecord(
          base: base,
          quote: quote,
          date: dateString,
          rate: NSDecimalNumber(decimal: rate).doubleValue
        )
      }
    }
    let meta = ExchangeRateMetaRecord(
      base: base, earliestDate: cache.earliestDate, latestDate: cache.latestDate
    )
    try await database.write { database in
      try ExchangeRateRecord
        .filter(ExchangeRateRecord.Columns.base == base)
        .deleteAll(database)
      for record in records { try record.insert(database) }
      try meta.upsert(database)
    }
  }
}
