// Shared/CryptoPriceService.swift

import Foundation
import GRDB
import OSLog

actor CryptoPriceService {
  private let clients: [CryptoPriceClient]

  // MARK: - Cross-extension internals
  // `caches`, `hydratedTokenIds`, `database`, and `logger` are accessed
  // by the SQL persistence extension in
  // `CryptoPriceService+Persistence.swift` and the merge extension in
  // `CryptoPriceService+Merge.swift`. The methods
  // `loadCache(tokenId:)` / `persistDelta(tokenId:deltaRecords:)`
  // (persistence) and `mergeReturningDelta(tokenId:symbol:newPrices:)`
  // (merge) are defined there and called from this file, which is why
  // both they and these properties are `internal` rather than `private`.
  // They remain actor-isolated; the access modifier is internal so the
  // sibling-file extensions can see them.
  var caches: [String: CryptoPriceCache] = [:]
  /// Loaded token ids — set on first hydration so we don't re-read SQL when
  /// the cache is genuinely empty.
  var hydratedTokenIds: Set<String> = []
  let database: any DatabaseWriter
  let logger = Logger(
    subsystem: "com.moolah.app", category: "CryptoPriceService")

  private let dateFormatter: ISO8601DateFormatter
  private let resolutionClient: TokenResolutionClient

  init(
    clients: [CryptoPriceClient],
    database: any DatabaseWriter,
    resolutionClient: (any TokenResolutionClient)? = nil
  ) {
    self.clients = clients
    self.database = database
    self.resolutionClient = resolutionClient ?? NoOpTokenResolutionClient()
    self.dateFormatter = ISO8601DateFormatter()
    self.dateFormatter.formatOptions = [.withFullDate]
  }

  // MARK: - Token resolution

  func resolveRegistration(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async throws -> CryptoRegistration {
    let result = try await resolutionClient.resolve(
      chainId: chainId,
      contractAddress: contractAddress,
      symbol: symbol,
      isNative: isNative
    )
    let resolvedSymbol = result.resolvedSymbol ?? symbol ?? "???"
    let resolvedName = result.resolvedName ?? symbol ?? "Unknown Token"
    let resolvedDecimals = result.resolvedDecimals ?? 18

    let instrument = Instrument.crypto(
      chainId: chainId,
      contractAddress: isNative ? nil : contractAddress,
      symbol: resolvedSymbol,
      name: resolvedName,
      decimals: resolvedDecimals
    )
    let mapping = CryptoProviderMapping(
      instrumentId: instrument.id,
      coingeckoId: result.coingeckoId,
      cryptocompareSymbol: result.cryptocompareSymbol,
      binanceSymbol: result.binanceSymbol
    )
    return CryptoRegistration(instrument: instrument, mapping: mapping)
  }

  /// Drops any cached price data for the given instrument id — removes both
  /// the in-memory cache entry and the on-disk rows. Called when an
  /// instrument is un-registered so we don't retain stale prices for
  /// something the user no longer cares about.
  func purgeCache(instrumentId: String) async {
    caches.removeValue(forKey: instrumentId)
    hydratedTokenIds.remove(instrumentId)
    do {
      try await database.write { database in
        try CryptoPriceRecord
          .filter(CryptoPriceRecord.Columns.tokenId == instrumentId)
          .deleteAll(database)
        try CryptoTokenMetaRecord
          .filter(CryptoTokenMetaRecord.Columns.tokenId == instrumentId)
          .deleteAll(database)
      }
    } catch {
      logger.warning(
        "purgeCache failed for \(instrumentId, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  // MARK: - Single price

  func price(
    for instrument: Instrument,
    mapping: CryptoProviderMapping,
    on date: Date
  ) async throws -> Decimal {
    let tokenId = instrument.id
    let dateString = dateFormatter.string(from: date)

    if let cached = lookupPrice(tokenId: tokenId, dateString: dateString) {
      return cached
    }

    if !hydratedTokenIds.contains(tokenId) {
      try await loadCache(tokenId: tokenId)
    }

    if let cached = lookupPrice(tokenId: tokenId, dateString: dateString) {
      return cached
    }

    if let inRange = try inRangeFallback(tokenId: tokenId, dateString: dateString) {
      return inRange
    }

    // Out of cached range — extend toward the requested date and try
    // each provider in order. Continues past providers that return
    // empty so a fallback chain (CoinGecko → CryptoCompare → Binance)
    // can collectively fill in the dates one of them has.
    let symbol = instrument.ticker ?? instrument.name
    let fetchInterval = extensionWindow(
      for: tokenId, requestedDate: date, dateString: dateString)
    var lastError: (any Error)?
    for client in clients {
      do {
        let fetched = try await client.dailyPrices(for: mapping, in: fetchInterval)
        if !fetched.isEmpty {
          let delta = mergeReturningDelta(
            tokenId: tokenId, symbol: symbol, newPrices: fetched)
          if !delta.isEmpty {
            try await persistDelta(tokenId: tokenId, deltaRecords: delta)
          }
          if let price = lookupPrice(tokenId: tokenId, dateString: dateString) {
            return price
          }
        }
      } catch {
        lastError = error
        continue
      }
    }

    if let fallback = fallbackPrice(tokenId: tokenId, dateString: dateString) {
      return fallback
    }

    throw lastError ?? CryptoPriceError.noPriceAvailable(tokenId: tokenId, date: dateString)
  }

  /// Resolves the request from the in-memory cache when the requested
  /// date sits inside the `[earliestDate, latestDate]` window. Returns
  /// the prior-trading-day fallback price if available and `nil` if the
  /// date is out of range (the caller then triggers an extension fetch).
  ///
  /// Throws `noPriceAvailable` for the rare in-range case where the
  /// cache has bounds set but no row on or before the requested date —
  /// surfacing as missing rather than re-fetching is intentional.
  /// Without this short-circuit every weekend / non-trading-day in a
  /// chart's visible range dispatched a network probe and a `saveCache`
  /// rewrite, saturating the GRDB queue. Mirrors
  /// `ExchangeRateService.rate(...)`'s in-range branch.
  private func inRangeFallback(tokenId: String, dateString: String) throws -> Decimal? {
    guard let cache = caches[tokenId],
      dateString >= cache.earliestDate, dateString <= cache.latestDate
    else { return nil }
    if let fallback = fallbackPrice(tokenId: tokenId, dateString: dateString) {
      return fallback
    }
    throw CryptoPriceError.noPriceAvailable(tokenId: tokenId, date: dateString)
  }

  /// Returns the date range a fetch should cover when the cache cannot
  /// satisfy the request directly. Mirrors the extension shape used by
  /// `StockPriceService.fetchToCoverDate` and `ExchangeRateService`:
  ///
  /// - **Cache exists, requested date past `latestDate`:** forward
  ///   extension from the day after `latestDate` to the requested date.
  /// - **Cache exists, requested date before `earliestDate`:** backward
  ///   extension from the requested date to the day before
  ///   `earliestDate`.
  /// - **Cold cache (no entry for token):** 30-day surrounding window so
  ///   a first-ever request on a non-trading day can still fall back
  ///   to a recent prior price.
  ///
  /// The in-range case is unreachable here — `price(...)` short-circuits
  /// before calling this — but a defensive single-day window is returned
  /// just in case.
  private func extensionWindow(
    for tokenId: String, requestedDate: Date, dateString: String
  ) -> ClosedRange<Date> {
    let calendar = Calendar(identifier: .gregorian)
    if let cache = caches[tokenId] {
      if dateString > cache.latestDate,
        let latestDate = dateFormatter.date(from: cache.latestDate),
        let fetchStart = calendar.date(byAdding: .day, value: 1, to: latestDate)
      {
        return fetchStart...requestedDate
      }
      if dateString < cache.earliestDate,
        let earliestDate = dateFormatter.date(from: cache.earliestDate),
        let fetchEnd = calendar.date(byAdding: .day, value: -1, to: earliestDate)
      {
        return requestedDate...fetchEnd
      }
      return requestedDate...requestedDate
    }
    let fetchStart = calendar.date(byAdding: .day, value: -30, to: requestedDate) ?? requestedDate
    return fetchStart...requestedDate
  }

  // MARK: - Date range

  func prices(
    for instrument: Instrument,
    mapping: CryptoProviderMapping,
    in range: ClosedRange<Date>
  ) async throws -> [(date: Date, price: Decimal)] {
    let tokenId = instrument.id

    if !hydratedTokenIds.contains(tokenId) {
      try await loadCache(tokenId: tokenId)
    }

    let rangeStart = dateFormatter.string(from: range.lowerBound)
    let rangeEnd = dateFormatter.string(from: range.upperBound)

    let gregorian = Calendar(identifier: .gregorian)
    if let cache = caches[tokenId] {
      if rangeStart < cache.earliestDate,
        let earliestDate = dateFormatter.date(from: cache.earliestDate),
        let fetchEnd = gregorian.date(byAdding: .day, value: -1, to: earliestDate)
      {
        try await fetchRange(
          instrument: instrument, mapping: mapping, from: range.lowerBound, to: fetchEnd)
      }
      if rangeEnd > cache.latestDate,
        let latestDate = dateFormatter.date(from: cache.latestDate),
        let fetchStart = gregorian.date(byAdding: .day, value: 1, to: latestDate)
      {
        try await fetchRange(
          instrument: instrument, mapping: mapping, from: fetchStart, to: range.upperBound)
      }
    } else {
      try await fetchRange(
        instrument: instrument, mapping: mapping, from: range.lowerBound, to: range.upperBound)
    }

    let dates = generateDateSeries(in: range)
    var results: [(date: Date, price: Decimal)] = []
    var lastKnownPrice: Decimal?

    for date in dates {
      let dateString = dateFormatter.string(from: date)
      if let price = caches[tokenId]?.prices[dateString] {
        lastKnownPrice = price
        results.append((date, price))
      } else if let fallback = lastKnownPrice {
        results.append((date, fallback))
      }
    }

    return results
  }

  // MARK: - Batch current prices

  func currentPrices(for mappings: [CryptoProviderMapping]) async throws -> [String: Decimal] {
    var result: [String: Decimal] = [:]
    for client in clients {
      do {
        let prices = try await client.currentPrices(for: mappings)
        for (id, price) in prices where result[id] == nil {
          result[id] = price
        }
        if result.count == mappings.count { break }
      } catch {
        // Best-effort: try the next client. Log so a silent total miss
        // (all clients failed → empty dict) is diagnosable.
        logger.debug(
          "currentPrices: client \(type(of: client), privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
        )
        continue
      }
    }
    if result.isEmpty && !mappings.isEmpty {
      logger.warning("currentPrices: all clients failed; returning empty result")
    }
    return result
  }

  // MARK: - Prefetch

  func prefetchLatest(for registrations: [CryptoRegistration]) async {
    let mappings = registrations.map(\.mapping)
    let prices: [String: Decimal]
    do {
      prices = try await currentPrices(for: mappings)
    } catch {
      logger.warning(
        "Prefetch failed (best-effort): \(error.localizedDescription, privacy: .public)"
      )
      return
    }
    let dateString = dateFormatter.string(from: Date())
    for (tokenId, price) in prices {
      let registration = registrations.first { $0.id == tokenId }
      let symbol = registration?.instrument.ticker ?? registration?.instrument.name ?? ""
      let delta = mergeReturningDelta(
        tokenId: tokenId, symbol: symbol, newPrices: [dateString: price])
      // Skip the disk write when the latest price is identical to the
      // already-cached value — periodic "no change" polling would
      // otherwise rewrite the partition on every tick.
      guard !delta.isEmpty else { continue }
      do {
        try await persistDelta(tokenId: tokenId, deltaRecords: delta)
      } catch {
        logger.warning(
          // Best-effort: continue the loop so a single bad token doesn't
          // poison the rest of the prefetch.
          "prefetchLatest: persistDelta failed for \(tokenId, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
  }
}

// MARK: - Cache lookup & merge

extension CryptoPriceService {
  private func lookupPrice(tokenId: String, dateString: String) -> Decimal? {
    caches[tokenId]?.prices[dateString]
  }

  private func fallbackPrice(tokenId: String, dateString: String) -> Decimal? {
    guard let cache = caches[tokenId] else { return nil }
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

  private func fetchRange(
    instrument: Instrument, mapping: CryptoProviderMapping, from: Date, to: Date
  ) async throws {
    let tokenId = instrument.id
    let symbol = instrument.ticker ?? instrument.name
    var lastError: (any Error)?
    for client in clients {
      do {
        let fetched = try await client.dailyPrices(for: mapping, in: from...to)
        if !fetched.isEmpty {
          let delta = mergeReturningDelta(
            tokenId: tokenId, symbol: symbol, newPrices: fetched)
          if !delta.isEmpty {
            try await persistDelta(tokenId: tokenId, deltaRecords: delta)
          }
          return
        }
      } catch {
        lastError = error
        continue
      }
    }
    if let error = lastError { throw error }
  }

  // `mergeReturningDelta` lives in `CryptoPriceService+Merge.swift` so
  // the main actor body stays under SwiftLint's `type_body_length` and
  // `file_length` thresholds.
}

/// Fallback when no resolution client is configured. Returns empty results.
private struct NoOpTokenResolutionClient: TokenResolutionClient {
  func resolve(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async throws -> TokenResolutionResult {
    TokenResolutionResult()
  }
}
