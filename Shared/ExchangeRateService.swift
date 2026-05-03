// Shared/ExchangeRateService.swift

import Foundation
import GRDB
import OSLog

enum ExchangeRateError: Error, Equatable {
  case noRateAvailable(base: String, quote: String, date: String)
}

actor ExchangeRateService {
  private let client: ExchangeRateClient

  // MARK: - Cross-extension internals
  // `caches`, `hydratedBases`, `database`, and `logger` are accessed by
  // the SQL persistence extension in `ExchangeRateService+Persistence.swift`.
  // They remain actor-isolated; the access modifier is internal so the
  // sibling-file extension can see them.
  var caches: [String: ExchangeRateCache] = [:]
  /// Loaded bases — set on first hydration so we don't re-read SQL when the
  /// cache is genuinely empty.
  var hydratedBases: Set<String> = []
  let database: any DatabaseWriter
  let logger = Logger(
    subsystem: "com.moolah.app", category: "ExchangeRateService")

  private let dateFormatter: ISO8601DateFormatter

  init(client: ExchangeRateClient, database: any DatabaseWriter) {
    self.client = client
    self.database = database
    self.dateFormatter = ISO8601DateFormatter()
    self.dateFormatter.formatOptions = [.withFullDate]
  }

  func rate(from: Instrument, to: Instrument, on date: Date) async throws -> Decimal {
    if from.id == to.id { return Decimal(1) }

    let dateString = dateFormatter.string(from: date)
    let base = from.id
    let quote = to.id

    // Check in-memory cache
    if let cached = lookupRate(base: base, quote: quote, dateString: dateString) {
      return cached
    }

    // Hydrate from SQL on first access
    if !hydratedBases.contains(base) {
      try await loadCache(base: base)
    }

    // Check again after disk load
    if let cached = lookupRate(base: base, quote: quote, dateString: dateString) {
      return cached
    }

    // In-range short-circuit: if the requested date is within the cached
    // `[earliestDate, latestDate]` window, the exact miss is a weekend /
    // holiday / Frankfurter-not-yet-posted gap. `fallbackRate` resolves it
    // from the most-recent prior cached rate without going to the network.
    // Skipping the fetch here is what keeps repeat chart renders cheap —
    // see `guides/INSTRUMENT_CONVERSION_GUIDE.md` and the perf rationale
    // in `Shared/ExchangeRateService+Persistence.swift`.
    if let cache = caches[base],
      dateString >= cache.earliestDate, dateString <= cache.latestDate
    {
      if let fallback = fallbackRate(base: base, quote: quote, dateString: dateString) {
        return fallback
      }
      // In-range with no fallback only happens when this quote currency
      // has never been seen for this base — surface as missing rather
      // than triggering a fetch + full cache rewrite.
      throw ExchangeRateError.noRateAvailable(base: base, quote: quote, date: dateString)
    }

    // Out of cached range — extend toward the requested date.
    await fetchToCoverDate(base: base, date: date, dateString: dateString)

    // Exact hit after fetch?
    if let cached = lookupRate(base: base, quote: quote, dateString: dateString) {
      return cached
    }

    // Fall back to the most-recent cached rate on or before the requested date.
    if let fallback = fallbackRate(base: base, quote: quote, dateString: dateString) {
      return fallback
    }

    throw ExchangeRateError.noRateAvailable(base: base, quote: quote, date: dateString)
  }

  /// Extends the cached range toward `date`, fetching only the gap between
  /// the requested date and the existing `[earliestDate, latestDate]`
  /// window. `rate()` short-circuits in-range requests before calling
  /// this, so we only ever extend the boundary — never refetch dates we
  /// already cover. Errors are swallowed; callers fall back to cached
  /// rates when the fetch fails.
  private func fetchToCoverDate(base: String, date: Date, dateString: String) async {
    let calendar = Calendar(identifier: .gregorian)
    do {
      if let cache = caches[base] {
        if dateString > cache.latestDate,
          let latestDate = dateFormatter.date(from: cache.latestDate),
          let fetchStart = calendar.date(byAdding: .day, value: 1, to: latestDate)
        {
          try await fetchInChunks(base: base, from: fetchStart, to: date)
        } else if dateString < cache.earliestDate,
          let earliestDate = dateFormatter.date(from: cache.earliestDate),
          let fetchEnd = calendar.date(byAdding: .day, value: -1, to: earliestDate)
        {
          try await fetchInChunks(base: base, from: date, to: fetchEnd)
        }
      } else if let fetchStart = calendar.date(byAdding: .day, value: -30, to: date) {
        // Cold cache: fetch a month-wide surrounding range so we pick up
        // at least one trading day alongside the requested date.
        try await fetchInChunks(base: base, from: fetchStart, to: date)
      }
    } catch {
      // Fetch failed — proceed to fallback lookup. Logged so disk-write
      // failures (which would otherwise be silently swallowed alongside
      // expected network 404s) are still observable.
      logger.warning(
        "fetchToCoverDate failed for base \(base, privacy: .public) on \(dateString, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  func rates(
    from: Instrument, to: Instrument, in range: ClosedRange<Date>
  ) async throws -> [(date: Date, rate: Decimal)] {
    if from.id == to.id {
      return generateDateSeries(in: range).map { ($0, Decimal(1)) }
    }

    let base = from.id
    let quote = to.id

    // Hydrate cache if not already in memory
    if !hydratedBases.contains(base) {
      try await loadCache(base: base)
    }

    // Determine what we need to fetch
    let rangeStart = dateFormatter.string(from: range.lowerBound)
    let rangeEnd = dateFormatter.string(from: range.upperBound)

    let gregorian = Calendar(identifier: .gregorian)
    if let cache = caches[base] {
      if rangeStart < cache.earliestDate,
        let earliestDate = dateFormatter.date(from: cache.earliestDate),
        let fetchEnd = gregorian.date(byAdding: .day, value: -1, to: earliestDate)
      {
        try await fetchInChunks(base: base, from: range.lowerBound, to: fetchEnd)
      }
      if rangeEnd > cache.latestDate,
        let latestDate = dateFormatter.date(from: cache.latestDate),
        let fetchStart = gregorian.date(byAdding: .day, value: 1, to: latestDate)
      {
        try await fetchInChunks(base: base, from: fetchStart, to: range.upperBound)
      }
    } else {
      try await fetchInChunks(base: base, from: range.lowerBound, to: range.upperBound)
    }

    // Build result series
    let dates = generateDateSeries(in: range)
    var results: [(date: Date, rate: Decimal)] = []
    var lastKnownRate: Decimal?

    for date in dates {
      let dateString = dateFormatter.string(from: date)
      if let rate = caches[base]?.rates[dateString]?[quote] {
        lastKnownRate = rate
        results.append((date, rate))
      } else if let fallback = lastKnownRate {
        results.append((date, fallback))
      }
    }

    return results
  }

  func convert(_ amount: InstrumentAmount, to instrument: Instrument, on date: Date) async throws
    -> InstrumentAmount
  {
    if amount.instrument.id == instrument.id { return amount }

    let exchangeRate = try await rate(from: amount.instrument, to: instrument, on: date)
    let converted = amount.quantity * exchangeRate
    return InstrumentAmount(quantity: converted, instrument: instrument)
  }

  func prefetchLatest(base: Instrument) async {
    let code = base.id

    if !hydratedBases.contains(code) {
      do {
        try await loadCache(base: code)
      } catch {
        logger.warning(
          "prefetchLatest: loadCache failed for base \(code, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
    }

    let calendar = Calendar(identifier: .gregorian)
    let today = Date()
    let todayString = dateFormatter.string(from: today)

    if let cache = caches[code], cache.latestDate >= todayString {
      return  // Already up to date
    }

    let fetchFrom: Date
    if let cache = caches[code],
      let latestDate = dateFormatter.date(from: cache.latestDate),
      let next = calendar.date(byAdding: .day, value: 1, to: latestDate)
    {
      fetchFrom = next
    } else if let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: today) {
      fetchFrom = thirtyDaysAgo
    } else {
      fetchFrom = today
    }

    do {
      try await fetchAndMerge(base: code, from: fetchFrom, to: today)
    } catch {
      // Prefetch is best-effort — log so disk-write failures (which would
      // otherwise be conflated with expected network errors) are observable.
      logger.warning(
        "prefetchLatest: fetchAndMerge failed for base \(code, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  // MARK: - Private helpers

  private func lookupRate(base: String, quote: String, dateString: String) -> Decimal? {
    caches[base]?.rates[dateString]?[quote]
  }

  private func fallbackRate(base: String, quote: String, dateString: String) -> Decimal? {
    guard let cache = caches[base] else { return nil }
    let sortedDates = cache.rates.keys.sorted().reversed()
    for cachedDate in sortedDates {
      if cachedDate <= dateString, let rate = cache.rates[cachedDate]?[quote] {
        return rate
      }
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

  private func fetchInChunks(base: String, from: Date, to: Date) async throws {
    let calendar = Calendar(identifier: .gregorian)
    var chunkStart = from
    while chunkStart <= to {
      let nextYear = calendar.date(byAdding: .year, value: 1, to: chunkStart) ?? to
      let chunkEnd = min(nextYear, to)
      try await fetchAndMerge(base: base, from: chunkStart, to: chunkEnd)
      guard let next = calendar.date(byAdding: .day, value: 1, to: chunkEnd) else { break }
      chunkStart = next
    }
  }

  private func fetchAndMerge(base: String, from: Date, to: Date) async throws {
    let fetched = try await client.fetchRates(base: base, from: from, to: to)
    // Frankfurter (and the chunked extension call sites in this service)
    // legitimately return an empty payload for weekend / holiday / future
    // single-day probes. Skip the disk write entirely — there is nothing
    // new to persist.
    guard !fetched.isEmpty else { return }
    let delta = mergeReturningDelta(base: base, newRates: fetched)
    // The fetch may also return rates we already have (e.g. an extension
    // chunk that overlaps the cached range due to rounding). When merge
    // observes no change we have nothing to write.
    guard !delta.isEmpty else { return }
    try await persistDelta(base: base, deltaRecords: delta)
  }

  /// Merges `newRates` into `caches[base]` and returns the rows that
  /// actually changed so the persistence layer can `INSERT OR REPLACE`
  /// only those (rather than rewriting every cached row for the base on
  /// every fetch).
  ///
  /// The comparison is per-(date, quote) so a fetch that returns the
  /// same rates already in cache produces an empty delta. This is what
  /// lets `fetchAndMerge` skip the disk write on a no-op extension probe.
  private func mergeReturningDelta(
    base: String, newRates: [String: [String: Decimal]]
  ) -> [ExchangeRateRecord] {
    guard !newRates.isEmpty else { return [] }
    let sortedDates = newRates.keys.sorted()
    guard let earliest = sortedDates.first, let latest = sortedDates.last else { return [] }

    var deltaRecords: [ExchangeRateRecord] = []

    if var existing = caches[base] {
      for (dateKey, dayRates) in newRates {
        let existingDayRates = existing.rates[dateKey] ?? [:]
        for (quote, rate) in dayRates where existingDayRates[quote] != rate {
          deltaRecords.append(rateRecord(base: base, quote: quote, date: dateKey, rate: rate))
        }
        existing.rates[dateKey] = dayRates
      }
      if earliest < existing.earliestDate {
        existing.earliestDate = earliest
      }
      if latest > existing.latestDate {
        existing.latestDate = latest
      }
      caches[base] = existing
    } else {
      caches[base] = ExchangeRateCache(
        base: base,
        earliestDate: earliest,
        latestDate: latest,
        rates: newRates
      )
      for (dateKey, dayRates) in newRates {
        for (quote, rate) in dayRates {
          deltaRecords.append(rateRecord(base: base, quote: quote, date: dateKey, rate: rate))
        }
      }
    }

    return deltaRecords
  }

  /// Marshalls a `(date, quote, rate)` triple into the GRDB record shape.
  /// `Decimal → Double` round-trips via `NSDecimalNumber` (the same path
  /// GRDB itself takes), keeping the precision-preservation contract in
  /// sync with `loadCache`'s decode.
  private func rateRecord(
    base: String, quote: String, date: String, rate: Decimal
  ) -> ExchangeRateRecord {
    ExchangeRateRecord(
      base: base,
      quote: quote,
      date: date,
      rate: NSDecimalNumber(decimal: rate).doubleValue
    )
  }

  // SQL persistence (`loadCache` / `persistDelta`) lives in
  // `ExchangeRateService+Persistence.swift` so this file stays under
  // SwiftLint's `type_body_length` and `file_length` thresholds.
}
