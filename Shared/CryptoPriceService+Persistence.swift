// Shared/CryptoPriceService+Persistence.swift

import Foundation
import GRDB

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

  /// Persists `caches[tokenId]` to SQLite. Replaces prior rows for this
  /// token in a single transaction and upserts the meta row alongside so
  /// the symbol is never out of sync with the prices.
  ///
  /// Multi-statement; covered by a rollback test in
  /// `CryptoPriceServiceTests.swift`.
  ///
  /// Captures `caches[tokenId]` before suspending on `database.write`.
  /// Actor re-entrancy is acceptable here: a concurrent merge will trigger
  /// its own `saveCache` afterwards, so the disk converges to the latest
  /// in-memory state. A crash between the two writes leaves the disk at an
  /// intermediate-but-consistent snapshot — acceptable for a best-effort
  /// persistent cache.
  func saveCache(tokenId: String) async throws {
    guard let cache = caches[tokenId] else { return }
    let records: [CryptoPriceRecord] = cache.prices.map { dateString, price in
      CryptoPriceRecord(
        tokenId: tokenId,
        date: dateString,
        priceUsd: NSDecimalNumber(decimal: price).doubleValue
      )
    }
    let meta = CryptoTokenMetaRecord(
      tokenId: tokenId,
      symbol: cache.symbol,
      earliestDate: cache.earliestDate,
      latestDate: cache.latestDate
    )
    try await database.write { database in
      try CryptoPriceRecord
        .filter(CryptoPriceRecord.Columns.tokenId == tokenId)
        .deleteAll(database)
      for record in records { try record.insert(database) }
      try meta.upsert(database)
    }
  }
}
