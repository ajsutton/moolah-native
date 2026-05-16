// Shared/StockPriceService+Merge.swift

import Foundation

// MARK: - StockPriceService merge / delta computation

// In-memory merge for `StockPriceService`. Split out of
// `StockPriceService.swift` to keep that file within the type/file
// length budget, mirroring the `CryptoPriceService+Merge.swift` split.

extension StockPriceService {
  /// Merges `newPrices` into `caches[ticker]` and returns the rows that
  /// actually changed so the persistence layer can `INSERT OR REPLACE`
  /// only those (rather than rewriting every cached row for the ticker
  /// on every fetch).
  ///
  /// The comparison is per-date so a fetch that returns the same prices
  /// already in cache produces an empty delta. This is what lets
  /// `fetchAndMerge` skip the disk write on a no-op extension probe.
  func mergeReturningDelta(
    ticker: String, instrument: Instrument, newPrices: [String: Decimal]
  ) -> [StockPriceRecord] {
    guard !newPrices.isEmpty else { return [] }
    let sortedDates = newPrices.keys.sorted()
    guard let earliest = sortedDates.first, let latest = sortedDates.last else { return [] }

    var deltaRecords: [StockPriceRecord] = []

    if var existing = caches[ticker] {
      for (dateKey, price) in newPrices {
        guard let key = DateKey.from(isoString: dateKey) else { continue }
        if existing.prices.exact(key) != price {
          deltaRecords.append(priceRecord(ticker: ticker, date: dateKey, price: price))
          existing.prices.upsert(key, price)
        }
      }
      if earliest < existing.earliestDate {
        existing.earliestDate = earliest
      }
      if latest > existing.latestDate {
        existing.latestDate = latest
      }
      caches[ticker] = existing
    } else {
      var series = SortedDateSeries<Decimal>()
      for (dateKey, price) in newPrices {
        guard let key = DateKey.from(isoString: dateKey) else { continue }
        series.upsert(key, price)
        deltaRecords.append(priceRecord(ticker: ticker, date: dateKey, price: price))
      }
      caches[ticker] = StockPriceCache(
        ticker: ticker,
        instrument: instrument,
        earliestDate: earliest,
        latestDate: latest,
        prices: series
      )
    }

    return deltaRecords
  }

  /// Marshalls a `(date, price)` pair into the GRDB record shape.
  /// `Decimal → Double` round-trips via `NSDecimalNumber` (the same path
  /// GRDB itself takes), keeping the precision-preservation contract in
  /// sync with `loadCache`'s decode.
  private func priceRecord(ticker: String, date: String, price: Decimal) -> StockPriceRecord {
    StockPriceRecord(
      ticker: ticker,
      date: date,
      price: NSDecimalNumber(decimal: price).doubleValue
    )
  }
}
