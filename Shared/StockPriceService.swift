// Shared/StockPriceService.swift

import Foundation
import GRDB
import OSLog

enum StockPriceError: Error, Equatable {
  case noPriceAvailable(ticker: String, date: String)
  case unknownTicker(String)
}

actor StockPriceService {
  private let client: StockPriceClient
  private var caches: [String: StockPriceCache] = [:]
  /// Loaded tickers — set on first hydration so we don't re-read SQL when
  /// the cache is genuinely empty.
  private var hydratedTickers: Set<String> = []
  private let database: any DatabaseWriter
  private let dateFormatter: ISO8601DateFormatter
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "StockPriceService")

  init(client: StockPriceClient, database: any DatabaseWriter) {
    self.client = client
    self.database = database
    self.dateFormatter = ISO8601DateFormatter()
    self.dateFormatter.formatOptions = [.withFullDate]
  }

  // MARK: - Public API

  func price(ticker: String, on date: Date) async throws -> Decimal {
    let dateString = dateFormatter.string(from: date)

    // Check in-memory cache
    if let cached = lookupPrice(ticker: ticker, dateString: dateString) {
      return cached
    }

    // Hydrate from SQL on first access
    if !hydratedTickers.contains(ticker) {
      try await loadCache(ticker: ticker)
    }

    // Check again after disk load
    if let cached = lookupPrice(ticker: ticker, dateString: dateString) {
      return cached
    }

    // Fetch from client — expand range to fill gap between cache and requested date
    do {
      try await fetchToCoverDate(ticker: ticker, date: date, dateString: dateString)
      if let cached = lookupPrice(ticker: ticker, dateString: dateString) {
        return cached
      }
    } catch {
      // Network failure — try fallback to most recent prior date
      if let fallback = fallbackPrice(ticker: ticker, dateString: dateString) {
        return fallback
      }
      throw error
    }

    // Fetch succeeded but no price for this date — try fallback
    if let fallback = fallbackPrice(ticker: ticker, dateString: dateString) {
      return fallback
    }

    throw StockPriceError.noPriceAvailable(ticker: ticker, date: dateString)
  }

  func prices(
    ticker: String, in range: ClosedRange<Date>
  ) async throws -> [(date: Date, price: Decimal)] {
    // Hydrate cache if not already in memory
    if !hydratedTickers.contains(ticker) {
      try await loadCache(ticker: ticker)
    }

    // Determine what we need to fetch
    let rangeStart = dateFormatter.string(from: range.lowerBound)
    let rangeEnd = dateFormatter.string(from: range.upperBound)

    let gregorian = Calendar(identifier: .gregorian)
    if let cache = caches[ticker] {
      if rangeStart < cache.earliestDate,
        let earliestDate = dateFormatter.date(from: cache.earliestDate),
        let fetchEnd = gregorian.date(byAdding: .day, value: -1, to: earliestDate)
      {
        try await fetchInChunks(ticker: ticker, from: range.lowerBound, to: fetchEnd)
      }
      if rangeEnd > cache.latestDate,
        let latestDate = dateFormatter.date(from: cache.latestDate),
        let fetchStart = gregorian.date(byAdding: .day, value: 1, to: latestDate)
      {
        try await fetchInChunks(ticker: ticker, from: fetchStart, to: range.upperBound)
      }
    } else {
      try await fetchInChunks(ticker: ticker, from: range.lowerBound, to: range.upperBound)
    }

    // Build result series
    let dates = generateDateSeries(in: range)
    var results: [(date: Date, price: Decimal)] = []
    var lastKnownPrice: Decimal?

    for date in dates {
      let dateString = dateFormatter.string(from: date)
      if let price = caches[ticker]?.prices[dateString] {
        lastKnownPrice = price
        results.append((date, price))
      } else if let fallback = lastKnownPrice {
        results.append((date, fallback))
      }
    }

    return results
  }

  func instrument(for ticker: String) async throws -> Instrument {
    if let cache = caches[ticker] {
      return cache.instrument
    }
    if !hydratedTickers.contains(ticker) {
      try await loadCache(ticker: ticker)
    }
    if let cache = caches[ticker] {
      return cache.instrument
    }
    throw StockPriceError.unknownTicker(ticker)
  }

  // MARK: - Private helpers

  /// Fetches the surrounding window needed to cover `date`. Cold cache fetches
  /// a month-wide window so a request on a weekend / holiday can still resolve
  /// via `fallbackPrice`. Warm cache extends only the gap between the cache
  /// edge and the requested date.
  ///
  /// Unlike `ExchangeRateService.fetchToCoverDate`, this method propagates
  /// fetch errors so `price(ticker:on:)` can surface network failures when
  /// the fallback cache is also empty.
  private func fetchToCoverDate(ticker: String, date: Date, dateString: String) async throws {
    let gregorian = Calendar(identifier: .gregorian)
    if let cache = caches[ticker] {
      if dateString > cache.latestDate,
        let latestDate = dateFormatter.date(from: cache.latestDate),
        let fetchStart = gregorian.date(byAdding: .day, value: 1, to: latestDate)
      {
        try await fetchInChunks(ticker: ticker, from: fetchStart, to: date)
      } else if dateString < cache.earliestDate,
        let earliestDate = dateFormatter.date(from: cache.earliestDate),
        let fetchEnd = gregorian.date(byAdding: .day, value: -1, to: earliestDate)
      {
        try await fetchInChunks(ticker: ticker, from: date, to: fetchEnd)
      }
    } else if let fetchStart = gregorian.date(byAdding: .day, value: -30, to: date) {
      try await fetchInChunks(ticker: ticker, from: fetchStart, to: date)
    } else {
      try await fetchAndMerge(ticker: ticker, from: date, to: date)
    }
  }

  private func lookupPrice(ticker: String, dateString: String) -> Decimal? {
    caches[ticker]?.prices[dateString]
  }

  private func fallbackPrice(ticker: String, dateString: String) -> Decimal? {
    guard let cache = caches[ticker] else { return nil }
    let sortedDates = cache.prices.keys.sorted().reversed()
    for cachedDate in sortedDates where cachedDate <= dateString {
      return cache.prices[cachedDate]
    }
    return nil
  }

  private func generateDateSeries(in range: ClosedRange<Date>) -> [Date] {
    let calendar = Calendar(identifier: .gregorian)
    var dates: [Date] = []
    var current = range.lowerBound
    while current <= range.upperBound {
      dates.append(current)
      guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
      current = next
    }
    return dates
  }

  private func fetchInChunks(ticker: String, from: Date, to: Date) async throws {
    let calendar = Calendar(identifier: .gregorian)
    var chunkStart = from
    while chunkStart <= to {
      let nextYear = calendar.date(byAdding: .year, value: 1, to: chunkStart) ?? to
      let chunkEnd = min(nextYear, to)
      try await fetchAndMerge(ticker: ticker, from: chunkStart, to: chunkEnd)
      guard let next = calendar.date(byAdding: .day, value: 1, to: chunkEnd) else { break }
      chunkStart = next
    }
  }

  private func fetchAndMerge(ticker: String, from: Date, to: Date) async throws {
    let response = try await client.fetchDailyPrices(ticker: ticker, from: from, to: to)
    merge(ticker: ticker, instrument: response.instrument, newPrices: response.prices)
    try await saveCache(ticker: ticker)
  }

  private func merge(ticker: String, instrument: Instrument, newPrices: [String: Decimal]) {
    guard !newPrices.isEmpty else { return }
    let sortedDates = newPrices.keys.sorted()
    guard let earliest = sortedDates.first, let latest = sortedDates.last else { return }
    if var existing = caches[ticker] {
      for (dateKey, price) in newPrices {
        existing.prices[dateKey] = price
      }
      if earliest < existing.earliestDate {
        existing.earliestDate = earliest
      }
      if latest > existing.latestDate {
        existing.latestDate = latest
      }
      caches[ticker] = existing
    } else {
      caches[ticker] = StockPriceCache(
        ticker: ticker,
        instrument: instrument,
        earliestDate: earliest,
        latestDate: latest,
        prices: newPrices
      )
    }
  }

  // MARK: - SQL persistence

  /// Hydrates `caches[ticker]` from `stock_price` + `stock_ticker_meta`.
  /// The meta row records the price denomination (`instrument_id`, e.g.
  /// `"AUD"` for `BHP.AX`); on load we reconstruct a fiat `Instrument` from
  /// the stored code, mirroring the `Instrument.fiat(code:)` factory used
  /// when the price API first responds.
  ///
  /// Marks the ticker as hydrated even when no rows exist so we don't
  /// re-query on every miss.
  private func loadCache(ticker: String) async throws {
    let snapshot: StockPriceCache? = try await database.read { database in
      let metaRecord =
        try StockTickerMetaRecord
        .filter(StockTickerMetaRecord.Columns.ticker == ticker)
        .fetchOne(database)
      guard let metaRecord else { return nil }
      let priceRecords =
        try StockPriceRecord
        .filter(StockPriceRecord.Columns.ticker == ticker)
        .fetchAll(database)
      // See `ExchangeRateService.loadCache` for the rationale on the
      // String-via-Decimal round-trip; preserves source precision instead
      // of inheriting the binary `Decimal(_: Double)` tail.
      var prices: [String: Decimal] = [:]
      for record in priceRecords {
        prices[record.date] = Decimal(string: String(record.price)) ?? Decimal(record.price)
      }
      return StockPriceCache(
        ticker: ticker,
        instrument: Instrument.fiat(code: metaRecord.instrumentId),
        earliestDate: metaRecord.earliestDate,
        latestDate: metaRecord.latestDate,
        prices: prices
      )
    }
    if let snapshot { caches[ticker] = snapshot }
    hydratedTickers.insert(ticker)
  }

  /// Persists `caches[ticker]` to SQLite. Replaces prior rows for this
  /// ticker in a single transaction and writes the meta row via
  /// `INSERT OR REPLACE` alongside so the price denomination is never out
  /// of sync with the prices.
  ///
  /// Multi-statement; covered by a rollback test in
  /// `StockPriceServiceTests.swift`.
  ///
  /// Captures `caches[ticker]` before suspending on `database.write`.
  /// Actor re-entrancy is acceptable here: a concurrent merge will trigger
  /// its own `saveCache` afterwards, so the disk converges to the latest
  /// in-memory state. A crash between the two writes leaves the disk at
  /// an intermediate-but-consistent snapshot — acceptable for a
  /// best-effort persistent cache.
  private func saveCache(ticker: String) async throws {
    guard let cache = caches[ticker] else { return }
    let records: [StockPriceRecord] = cache.prices.map { dateString, price in
      StockPriceRecord(
        ticker: ticker,
        date: dateString,
        price: NSDecimalNumber(decimal: price).doubleValue
      )
    }
    // The price denomination in `StockPriceCache` is the API-reported fiat
    // currency the ticker trades in (see `YahooFinanceClient.parseResponse`).
    // Persist its code; load reconstructs via `Instrument.fiat(code:)`.
    let meta = StockTickerMetaRecord(
      ticker: ticker,
      instrumentId: cache.instrument.id,
      earliestDate: cache.earliestDate,
      latestDate: cache.latestDate
    )
    try await database.write { database in
      try StockPriceRecord
        .filter(StockPriceRecord.Columns.ticker == ticker)
        .deleteAll(database)
      for record in records { try record.insert(database) }
      try meta.insert(database)
    }
  }
}
