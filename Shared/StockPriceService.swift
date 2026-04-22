// Shared/StockPriceService.swift
import Foundation

enum StockPriceError: Error, Equatable {
  case noPriceAvailable(ticker: String, date: String)
  case unknownTicker(String)
}

actor StockPriceService {
  private let client: StockPriceClient
  private var caches: [String: StockPriceCache] = [:]
  private let cacheDirectory: URL
  private let dateFormatter: ISO8601DateFormatter

  init(client: StockPriceClient, cacheDirectory: URL? = nil) {
    self.client = client
    self.cacheDirectory =
      cacheDirectory
      ?? FileManager.default.urls(
        for: .cachesDirectory, in: .userDomainMask
      ).first!.appendingPathComponent("stock-prices")
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

    // Load from disk if not already loaded
    if caches[ticker] == nil {
      loadCacheFromDisk(ticker: ticker)
    }

    // Check again after disk load
    if let cached = lookupPrice(ticker: ticker, dateString: dateString) {
      return cached
    }

    // Fetch from client — expand range to fill gap between cache and requested date
    do {
      if let cache = caches[ticker] {
        if dateString > cache.latestDate {
          let fetchStart = Calendar(identifier: .gregorian)
            .date(
              byAdding: .day, value: 1,
              to: dateFormatter.date(from: cache.latestDate)!)!
          try await fetchInChunks(ticker: ticker, from: fetchStart, to: date)
        } else if dateString < cache.earliestDate {
          let fetchEnd = Calendar(identifier: .gregorian)
            .date(
              byAdding: .day, value: -1,
              to: dateFormatter.date(from: cache.earliestDate)!)!
          try await fetchInChunks(ticker: ticker, from: date, to: fetchEnd)
        }
      } else {
        try await fetchAndMerge(ticker: ticker, from: date, to: date)
      }
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
  ) async throws -> [(date: String, price: Decimal)] {
    // Load cache if not already in memory
    if caches[ticker] == nil {
      loadCacheFromDisk(ticker: ticker)
    }

    // Determine what we need to fetch
    let rangeStart = dateFormatter.string(from: range.lowerBound)
    let rangeEnd = dateFormatter.string(from: range.upperBound)

    if let cache = caches[ticker] {
      if rangeStart < cache.earliestDate {
        let fetchEnd = Calendar(identifier: .gregorian)
          .date(
            byAdding: .day, value: -1,
            to: dateFormatter.date(from: cache.earliestDate)!)!
        try await fetchInChunks(ticker: ticker, from: range.lowerBound, to: fetchEnd)
      }
      if rangeEnd > cache.latestDate {
        let fetchStart = Calendar(identifier: .gregorian)
          .date(
            byAdding: .day, value: 1,
            to: dateFormatter.date(from: cache.latestDate)!)!
        try await fetchInChunks(ticker: ticker, from: fetchStart, to: range.upperBound)
      }
    } else {
      try await fetchInChunks(ticker: ticker, from: range.lowerBound, to: range.upperBound)
    }

    // Build result series
    let dates = generateDateSeries(in: range)
    var results: [(date: String, price: Decimal)] = []
    var lastKnownPrice: Decimal?

    for date in dates {
      let dateString = dateFormatter.string(from: date)
      if let price = caches[ticker]?.prices[dateString] {
        lastKnownPrice = price
        results.append((dateString, price))
      } else if let fallback = lastKnownPrice {
        results.append((dateString, fallback))
      }
    }

    return results
  }

  func instrument(for ticker: String) async throws -> Instrument {
    if let cache = caches[ticker] {
      return cache.instrument
    }
    loadCacheFromDisk(ticker: ticker)
    if let cache = caches[ticker] {
      return cache.instrument
    }
    throw StockPriceError.unknownTicker(ticker)
  }

  // MARK: - Private helpers

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
      current = calendar.date(byAdding: .day, value: 1, to: current)!
    }
    return dates
  }

  private func fetchInChunks(ticker: String, from: Date, to: Date) async throws {
    let calendar = Calendar(identifier: .gregorian)
    var chunkStart = from
    while chunkStart <= to {
      let chunkEnd = min(
        calendar.date(byAdding: .year, value: 1, to: chunkStart)!,
        to
      )
      try await fetchAndMerge(ticker: ticker, from: chunkStart, to: chunkEnd)
      chunkStart = calendar.date(byAdding: .day, value: 1, to: chunkEnd)!
    }
  }

  private func fetchAndMerge(ticker: String, from: Date, to: Date) async throws {
    let response = try await client.fetchDailyPrices(ticker: ticker, from: from, to: to)
    merge(ticker: ticker, instrument: response.instrument, newPrices: response.prices)
    saveCacheToDisk(ticker: ticker)
  }

  private func merge(ticker: String, instrument: Instrument, newPrices: [String: Decimal]) {
    guard !newPrices.isEmpty else { return }
    let sortedDates = newPrices.keys.sorted()
    if var existing = caches[ticker] {
      for (dateKey, price) in newPrices {
        existing.prices[dateKey] = price
      }
      if let first = sortedDates.first, first < existing.earliestDate {
        existing.earliestDate = first
      }
      if let last = sortedDates.last, last > existing.latestDate {
        existing.latestDate = last
      }
      caches[ticker] = existing
    } else {
      caches[ticker] = StockPriceCache(
        ticker: ticker,
        instrument: instrument,
        earliestDate: sortedDates.first!,
        latestDate: sortedDates.last!,
        prices: newPrices
      )
    }
  }

  private func cacheFileURL(ticker: String) -> URL {
    cacheDirectory.appendingPathComponent("prices-\(ticker).json.gz")
  }

  private func loadCacheFromDisk(ticker: String) {
    let url = cacheFileURL(ticker: ticker)
    guard let compressed = try? Data(contentsOf: url) else { return }
    guard let data = decompress(compressed) else { return }
    guard let cache = try? JSONDecoder().decode(StockPriceCache.self, from: data) else { return }
    caches[ticker] = cache
  }

  private func saveCacheToDisk(ticker: String) {
    guard let cache = caches[ticker] else { return }
    guard let data = try? JSONEncoder().encode(cache) else { return }
    guard let compressed = compress(data) else { return }
    try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    try? compressed.write(to: cacheFileURL(ticker: ticker), options: .atomic)
  }

  private func compress(_ data: Data) -> Data? {
    try? (data as NSData).compressed(using: .zlib) as Data
  }

  private func decompress(_ data: Data) -> Data? {
    try? (data as NSData).decompressed(using: .zlib) as Data
  }
}
