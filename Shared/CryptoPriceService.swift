// Shared/CryptoPriceService.swift
import Foundation

actor CryptoPriceService {
  private let clients: [CryptoPriceClient]
  private var caches: [String: CryptoPriceCache] = [:]
  private let cacheDirectory: URL
  private let dateFormatter: ISO8601DateFormatter
  private let tokenRepository: CryptoTokenRepository
  private let resolutionClient: TokenResolutionClient

  init(
    clients: [CryptoPriceClient], cacheDirectory: URL? = nil,
    tokenRepository: CryptoTokenRepository = ICloudTokenRepository(),
    resolutionClient: (any TokenResolutionClient)? = nil
  ) {
    self.clients = clients
    self.tokenRepository = tokenRepository
    self.resolutionClient = resolutionClient ?? NoOpTokenResolutionClient()
    self.cacheDirectory =
      cacheDirectory
      ?? FileManager.default.urls(
        for: .cachesDirectory, in: .userDomainMask
      ).first!.appendingPathComponent("crypto-prices")
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

  // MARK: - Registration management

  func registeredItems() async -> [CryptoRegistration] {
    (try? await tokenRepository.loadRegistrations()) ?? []
  }

  func register(_ registration: CryptoRegistration) async throws {
    var registrations = try await tokenRepository.loadRegistrations()
    registrations.removeAll { $0.id == registration.id }
    registrations.append(registration)
    try await tokenRepository.saveRegistrations(registrations)
  }

  func remove(_ registration: CryptoRegistration) async throws {
    var registrations = try await tokenRepository.loadRegistrations()
    registrations.removeAll { $0.id == registration.id }
    try await tokenRepository.saveRegistrations(registrations)
    // Remove cached price data
    caches.removeValue(forKey: registration.id)
    let url = cacheFileURL(tokenId: registration.id)
    try? FileManager.default.removeItem(at: url)
  }

  func removeById(_ instrumentId: String) async throws {
    var registrations = try await tokenRepository.loadRegistrations()
    registrations.removeAll { $0.id == instrumentId }
    try await tokenRepository.saveRegistrations(registrations)
    caches.removeValue(forKey: instrumentId)
    let url = cacheFileURL(tokenId: instrumentId)
    try? FileManager.default.removeItem(at: url)
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

    if caches[tokenId] == nil {
      loadCacheFromDisk(tokenId: tokenId)
    }

    if let cached = lookupPrice(tokenId: tokenId, dateString: dateString) {
      return cached
    }

    let symbol = instrument.ticker ?? instrument.name
    var lastError: (any Error)?
    for client in clients {
      do {
        let fetched = try await client.dailyPrices(for: mapping, in: date...date)
        if !fetched.isEmpty {
          merge(tokenId: tokenId, symbol: symbol, newPrices: fetched)
          saveCacheToDisk(tokenId: tokenId)
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

  // MARK: - Date range

  func prices(
    for instrument: Instrument,
    mapping: CryptoProviderMapping,
    in range: ClosedRange<Date>
  ) async throws -> [(date: Date, price: Decimal)] {
    let tokenId = instrument.id

    if caches[tokenId] == nil {
      loadCacheFromDisk(tokenId: tokenId)
    }

    let rangeStart = dateFormatter.string(from: range.lowerBound)
    let rangeEnd = dateFormatter.string(from: range.upperBound)

    if let cache = caches[tokenId] {
      if rangeStart < cache.earliestDate {
        let fetchEnd = Calendar(identifier: .gregorian)
          .date(
            byAdding: .day, value: -1,
            to: dateFormatter.date(from: cache.earliestDate)!)!
        try await fetchRange(
          instrument: instrument, mapping: mapping, from: range.lowerBound, to: fetchEnd)
      }
      if rangeEnd > cache.latestDate {
        let fetchStart = Calendar(identifier: .gregorian)
          .date(
            byAdding: .day, value: 1,
            to: dateFormatter.date(from: cache.latestDate)!)!
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
        continue
      }
    }
    return result
  }

  // MARK: - Prefetch

  /// Prefetch latest prices for all registered items.
  func prefetchLatest() async {
    let items = await registeredItems()
    guard !items.isEmpty else { return }
    await prefetchLatest(for: items)
  }

  func prefetchLatest(for registrations: [CryptoRegistration]) async {
    let mappings = registrations.map(\.mapping)
    do {
      let prices = try await currentPrices(for: mappings)
      let dateString = dateFormatter.string(from: Date())
      for (tokenId, price) in prices {
        let symbol =
          registrations.first { $0.id == tokenId }?.instrument.ticker
          ?? registrations.first { $0.id == tokenId }?.instrument.name ?? ""
        merge(tokenId: tokenId, symbol: symbol, newPrices: [dateString: price])
        saveCacheToDisk(tokenId: tokenId)
      }
    } catch {
      // Prefetch is best-effort
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
      current = calendar.date(byAdding: .day, value: 1, to: current)!
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
          merge(tokenId: tokenId, symbol: symbol, newPrices: fetched)
          saveCacheToDisk(tokenId: tokenId)
          return
        }
      } catch {
        lastError = error
        continue
      }
    }
    if let error = lastError { throw error }
  }

  private func merge(tokenId: String, symbol: String, newPrices: [String: Decimal]) {
    guard !newPrices.isEmpty else { return }
    let sortedDates = newPrices.keys.sorted()
    if var existing = caches[tokenId] {
      for (dateKey, price) in newPrices {
        existing.prices[dateKey] = price
      }
      if let first = sortedDates.first, first < existing.earliestDate {
        existing.earliestDate = first
      }
      if let last = sortedDates.last, last > existing.latestDate {
        existing.latestDate = last
      }
      caches[tokenId] = existing
    } else {
      caches[tokenId] = CryptoPriceCache(
        tokenId: tokenId,
        symbol: symbol,
        earliestDate: sortedDates.first!,
        latestDate: sortedDates.last!,
        prices: newPrices
      )
    }
  }
}

// MARK: - Disk cache I/O

extension CryptoPriceService {
  private func cacheFileURL(tokenId: String) -> URL {
    let safeName = tokenId.replacingOccurrences(of: ":", with: "-")
    return cacheDirectory.appendingPathComponent("prices-\(safeName).json.gz")
  }

  private func loadCacheFromDisk(tokenId: String) {
    let url = cacheFileURL(tokenId: tokenId)
    guard let compressed = try? Data(contentsOf: url) else { return }
    guard let data = decompress(compressed) else { return }
    guard let cache = try? JSONDecoder().decode(CryptoPriceCache.self, from: data) else { return }
    caches[tokenId] = cache
  }

  private func saveCacheToDisk(tokenId: String) {
    guard let cache = caches[tokenId] else { return }
    guard let data = try? JSONEncoder().encode(cache) else { return }
    guard let compressed = compress(data) else { return }
    try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    try? compressed.write(to: cacheFileURL(tokenId: tokenId), options: .atomic)
  }

  private func compress(_ data: Data) -> Data? {
    try? (data as NSData).compressed(using: .zlib) as Data
  }

  private func decompress(_ data: Data) -> Data? {
    try? (data as NSData).decompressed(using: .zlib) as Data
  }
}

/// Fallback when no resolution client is configured. Returns empty results.
private struct NoOpTokenResolutionClient: TokenResolutionClient {
  func resolve(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async throws -> TokenResolutionResult {
    TokenResolutionResult()
  }
}
