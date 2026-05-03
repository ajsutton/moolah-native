// Shared/CryptoPriceService+Persistence.swift

import Foundation
import GRDB

// MARK: - CryptoPriceService SQL persistence

// SQL persistence for `CryptoPriceService`. Lives in its own file so the
// main actor body stays under SwiftLint's `type_body_length` and
// `file_length` thresholds.

extension CryptoPriceService {
  /// Hydrates `caches[tokenId]` from `crypto_price` + `crypto_token_meta`.
  /// The meta row's `symbol` is display-only — used to populate
  /// `CryptoPriceCache.symbol` on the way back; not used for lookups.
  ///
  /// Marks the token id as hydrated even when no rows exist so we don't
  /// re-query on every miss.
  func loadCache(tokenId: String) async throws {
    let snapshot: CryptoPriceCache? = try await database.read { database in
      let metaRecord =
        try CryptoTokenMetaRecord
        .filter(CryptoTokenMetaRecord.Columns.tokenId == tokenId)
        .fetchOne(database)
      guard let metaRecord else { return nil }
      let priceRecords =
        try CryptoPriceRecord
        .filter(CryptoPriceRecord.Columns.tokenId == tokenId)
        .fetchAll(database)
      // See `ExchangeRateService.loadCache` for the rationale on the
      // String-via-Decimal round-trip; preserves source precision instead
      // of inheriting the binary `Decimal(_: Double)` tail.
      var prices: [String: Decimal] = [:]
      for record in priceRecords {
        prices[record.date] = Decimal(string: String(record.priceUsd)) ?? Decimal(record.priceUsd)
      }
      return CryptoPriceCache(
        tokenId: tokenId,
        symbol: metaRecord.symbol,
        earliestDate: metaRecord.earliestDate,
        latestDate: metaRecord.latestDate,
        prices: prices
      )
    }
    if let snapshot { caches[tokenId] = snapshot }
    hydratedTokenIds.insert(tokenId)
  }

  /// Persists the rows produced by `mergeReturningDelta` for `tokenId`
  /// plus the latest meta-bounds, all in a single transaction.
  ///
  /// Each delta row is written `INSERT OR REPLACE`; the meta row is
  /// `INSERT OR REPLACE`d via `CryptoTokenMetaRecord`'s `.replace`
  /// conflict policy. There is no `deleteAll` — historic prices never
  /// change, and rewriting the whole token on every fetch saturated the
  /// GRDB queue. The rollback contract still holds because every
  /// statement runs inside one `database.write` closure and any failure
  /// rolls them back together.
  ///
  /// Captures `caches[tokenId]` before suspending on `database.write`.
  /// Actor re-entrancy is acceptable here: a concurrent merge will
  /// produce its own delta with its own `persistDelta` afterwards, so
  /// the disk converges to the latest in-memory state. A crash between
  /// two writes leaves the disk at an intermediate-but-consistent
  /// snapshot — acceptable for a best-effort persistent cache.
  func persistDelta(tokenId: String, deltaRecords: [CryptoPriceRecord]) async throws {
    guard let cache = caches[tokenId] else { return }
    let meta = CryptoTokenMetaRecord(
      tokenId: tokenId,
      symbol: cache.symbol,
      earliestDate: cache.earliestDate,
      latestDate: cache.latestDate
    )
    try await database.write { database in
      for record in deltaRecords {
        try record.insert(database, onConflict: .replace)
      }
      try meta.insert(database)
    }
  }
}
