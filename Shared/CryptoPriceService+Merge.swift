// Shared/CryptoPriceService+Merge.swift

import Foundation

// MARK: - CryptoPriceService merge / delta computation

// In-memory merge for `CryptoPriceService`. Lives in its own file so the
// main actor body stays under SwiftLint's `type_body_length` and
// `file_length` thresholds. The persistence-side companion is in
// `CryptoPriceService+Persistence.swift`.

extension CryptoPriceService {
  /// Merges `newPrices` into `caches[tokenId]` and returns the rows that
  /// actually changed so the persistence layer can `INSERT OR REPLACE`
  /// only those (rather than rewriting every cached row for the token
  /// on every fetch). The comparison is per-date so a fetch returning
  /// the same prices already in cache produces an empty delta — which
  /// the call sites use to skip the disk write entirely.
  func mergeReturningDelta(
    tokenId: String, symbol: String, newPrices: [String: Decimal]
  ) -> [CryptoPriceRecord] {
    guard !newPrices.isEmpty else { return [] }
    let sortedDates = newPrices.keys.sorted()
    guard let earliest = sortedDates.first, let latest = sortedDates.last else { return [] }

    var deltaRecords: [CryptoPriceRecord] = []

    if var existing = caches[tokenId] {
      for (dateKey, price) in newPrices where existing.prices[dateKey] != price {
        deltaRecords.append(priceRecord(tokenId: tokenId, date: dateKey, price: price))
        existing.prices[dateKey] = price
      }
      if earliest < existing.earliestDate {
        existing.earliestDate = earliest
      }
      if latest > existing.latestDate {
        existing.latestDate = latest
      }
      caches[tokenId] = existing
    } else {
      caches[tokenId] = CryptoPriceCache(
        tokenId: tokenId,
        symbol: symbol,
        earliestDate: earliest,
        latestDate: latest,
        prices: newPrices
      )
      for (dateKey, price) in newPrices {
        deltaRecords.append(priceRecord(tokenId: tokenId, date: dateKey, price: price))
      }
    }

    return deltaRecords
  }

  /// Marshalls a `(date, price)` pair into the GRDB record shape.
  /// `Decimal → Double` round-trips via `NSDecimalNumber` (the same path
  /// GRDB itself takes), keeping the precision-preservation contract in
  /// sync with `loadCache`'s decode.
  private func priceRecord(tokenId: String, date: String, price: Decimal) -> CryptoPriceRecord {
    CryptoPriceRecord(
      tokenId: tokenId,
      date: date,
      priceUsd: NSDecimalNumber(decimal: price).doubleValue
    )
  }
}
