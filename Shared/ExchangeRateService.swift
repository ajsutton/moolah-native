// Shared/ExchangeRateService.swift
import Foundation

enum ExchangeRateError: Error, Equatable {
  case noRateAvailable(base: String, quote: String, date: String)
}

actor ExchangeRateService {
  private let client: ExchangeRateClient
  private var caches: [String: ExchangeRateCache] = [:]
  private let cacheDirectory: URL
  private let dateFormatter: ISO8601DateFormatter

  init(client: ExchangeRateClient, cacheDirectory: URL? = nil) {
    self.client = client
    self.cacheDirectory =
      cacheDirectory
      ?? FileManager.default.urls(
        for: .cachesDirectory, in: .userDomainMask
      ).first!.appendingPathComponent("exchange-rates")
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

    // Load from disk if not already loaded
    if caches[base] == nil {
      loadCacheFromDisk(base: base)
    }

    // Check again after disk load
    if let cached = lookupRate(base: base, quote: quote, dateString: dateString) {
      return cached
    }

    // Fetch from client
    do {
      try await fetchAndMerge(base: base, from: date, to: date)
      if let cached = lookupRate(base: base, quote: quote, dateString: dateString) {
        return cached
      }
    } catch {
      // Network failure — try fallback
      if let fallback = fallbackRate(base: base, quote: quote, dateString: dateString) {
        return fallback
      }
      throw error
    }

    // Fetch succeeded but no rate for this date — try fallback
    if let fallback = fallbackRate(base: base, quote: quote, dateString: dateString) {
      return fallback
    }

    throw ExchangeRateError.noRateAvailable(base: base, quote: quote, date: dateString)
  }

  func rates(
    from: Instrument, to: Instrument, in range: ClosedRange<Date>
  ) async throws -> [(date: Date, rate: Decimal)] {
    if from.id == to.id {
      return generateDateSeries(in: range).map { ($0, Decimal(1)) }
    }

    let base = from.id
    let quote = to.id

    // Load cache if not already in memory
    if caches[base] == nil {
      loadCacheFromDisk(base: base)
    }

    // Determine what we need to fetch
    let rangeStart = dateFormatter.string(from: range.lowerBound)
    let rangeEnd = dateFormatter.string(from: range.upperBound)

    if let cache = caches[base] {
      if rangeStart < cache.earliestDate {
        let fetchEnd = Calendar(identifier: .gregorian)
          .date(
            byAdding: .day, value: -1,
            to: dateFormatter.date(from: cache.earliestDate)!)!
        try await fetchInChunks(base: base, from: range.lowerBound, to: fetchEnd)
      }
      if rangeEnd > cache.latestDate {
        let fetchStart = Calendar(identifier: .gregorian)
          .date(
            byAdding: .day, value: 1,
            to: dateFormatter.date(from: cache.latestDate)!)!
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

    if caches[code] == nil {
      loadCacheFromDisk(base: code)
    }

    let calendar = Calendar(identifier: .gregorian)
    let today = Date()
    let todayString = dateFormatter.string(from: today)

    if let cache = caches[code], cache.latestDate >= todayString {
      return  // Already up to date
    }

    let fetchFrom: Date
    if let cache = caches[code],
      let latestDate = dateFormatter.date(from: cache.latestDate)
    {
      fetchFrom = calendar.date(byAdding: .day, value: 1, to: latestDate)!
    } else {
      fetchFrom = calendar.date(byAdding: .day, value: -30, to: today)!
    }

    do {
      try await fetchAndMerge(base: code, from: fetchFrom, to: today)
    } catch {
      // Prefetch is best-effort — silently ignore network errors
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
      current = calendar.date(byAdding: .day, value: 1, to: current)!
    }
    return dates
  }

  private func fetchInChunks(base: String, from: Date, to: Date) async throws {
    let calendar = Calendar(identifier: .gregorian)
    var chunkStart = from
    while chunkStart <= to {
      let chunkEnd = min(
        calendar.date(byAdding: .year, value: 1, to: chunkStart)!,
        to
      )
      try await fetchAndMerge(base: base, from: chunkStart, to: chunkEnd)
      chunkStart = calendar.date(byAdding: .day, value: 1, to: chunkEnd)!
    }
  }

  private func fetchAndMerge(base: String, from: Date, to: Date) async throws {
    let fetched = try await client.fetchRates(base: base, from: from, to: to)
    merge(base: base, newRates: fetched)
    saveCacheToDisk(base: base)
  }

  private func merge(base: String, newRates: [String: [String: Decimal]]) {
    guard !newRates.isEmpty else { return }
    let sortedDates = newRates.keys.sorted()
    if var existing = caches[base] {
      for (dateKey, dayRates) in newRates {
        existing.rates[dateKey] = dayRates
      }
      if let first = sortedDates.first, first < existing.earliestDate {
        existing.earliestDate = first
      }
      if let last = sortedDates.last, last > existing.latestDate {
        existing.latestDate = last
      }
      caches[base] = existing
    } else {
      caches[base] = ExchangeRateCache(
        base: base,
        earliestDate: sortedDates.first!,
        latestDate: sortedDates.last!,
        rates: newRates
      )
    }
  }

  private func cacheFileURL(base: String) -> URL {
    cacheDirectory.appendingPathComponent("rates-\(base).json.gz")
  }

  private func loadCacheFromDisk(base: String) {
    let url = cacheFileURL(base: base)
    guard let compressed = try? Data(contentsOf: url) else { return }
    guard let data = decompress(compressed) else { return }
    guard let cache = try? JSONDecoder().decode(ExchangeRateCache.self, from: data) else { return }
    caches[base] = cache
  }

  private func saveCacheToDisk(base: String) {
    guard let cache = caches[base] else { return }
    guard let data = try? JSONEncoder().encode(cache) else { return }
    guard let compressed = compress(data) else { return }
    try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    try? compressed.write(to: cacheFileURL(base: base), options: .atomic)
  }

  private func compress(_ data: Data) -> Data? {
    try? (data as NSData).compressed(using: .zlib) as Data
  }

  private func decompress(_ data: Data) -> Data? {
    try? (data as NSData).decompressed(using: .zlib) as Data
  }
}
