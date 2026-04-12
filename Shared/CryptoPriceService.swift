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

  func resolveToken(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async throws -> CryptoToken {
    let result = try await resolutionClient.resolve(
      chainId: chainId,
      contractAddress: contractAddress,
      symbol: symbol,
      isNative: isNative
    )
    return CryptoToken(
      chainId: chainId,
      contractAddress: isNative ? nil : contractAddress,
      symbol: result.resolvedSymbol ?? symbol ?? "???",
      name: result.resolvedName ?? symbol ?? "Unknown Token",
      decimals: result.resolvedDecimals ?? 18,
      coingeckoId: result.coingeckoId,
      cryptocompareSymbol: result.cryptocompareSymbol,
      binanceSymbol: result.binanceSymbol
    )
  }

  // MARK: - Token management

  func registeredTokens() async -> [CryptoToken] {
    (try? await tokenRepository.loadTokens()) ?? []
  }

  func registerToken(_ token: CryptoToken) async throws {
    var tokens = try await tokenRepository.loadTokens()
    tokens.removeAll { $0.id == token.id }
    tokens.append(token)
    try await tokenRepository.saveTokens(tokens)
  }

  func removeToken(_ token: CryptoToken) async throws {
    var tokens = try await tokenRepository.loadTokens()
    tokens.removeAll { $0.id == token.id }
    try await tokenRepository.saveTokens(tokens)
    // Remove cached price data
    caches.removeValue(forKey: token.id)
    let url = cacheFileURL(tokenId: token.id)
    try? FileManager.default.removeItem(at: url)
  }

  // MARK: - Single price

  func price(for token: CryptoToken, on date: Date) async throws -> Decimal {
    let dateString = dateFormatter.string(from: date)

    if let cached = lookupPrice(tokenId: token.id, dateString: dateString) {
      return cached
    }

    if caches[token.id] == nil {
      loadCacheFromDisk(tokenId: token.id)
    }

    if let cached = lookupPrice(tokenId: token.id, dateString: dateString) {
      return cached
    }

    var lastError: (any Error)?
    for client in clients {
      do {
        let fetched = try await client.dailyPrices(for: token, in: date...date)
        if !fetched.isEmpty {
          merge(tokenId: token.id, symbol: token.symbol, newPrices: fetched)
          saveCacheToDisk(tokenId: token.id)
          if let price = lookupPrice(tokenId: token.id, dateString: dateString) {
            return price
          }
        }
      } catch {
        lastError = error
        continue
      }
    }

    if let fallback = fallbackPrice(tokenId: token.id, dateString: dateString) {
      return fallback
    }

    throw lastError ?? CryptoPriceError.noPriceAvailable(tokenId: token.id, date: dateString)
  }

  // MARK: - Date range

  func prices(
    for token: CryptoToken, in range: ClosedRange<Date>
  ) async throws -> [(date: Date, price: Decimal)] {
    if caches[token.id] == nil {
      loadCacheFromDisk(tokenId: token.id)
    }

    let rangeStart = dateFormatter.string(from: range.lowerBound)
    let rangeEnd = dateFormatter.string(from: range.upperBound)

    if let cache = caches[token.id] {
      if rangeStart < cache.earliestDate {
        let fetchEnd = Calendar(identifier: .gregorian)
          .date(
            byAdding: .day, value: -1,
            to: dateFormatter.date(from: cache.earliestDate)!)!
        try await fetchRange(for: token, from: range.lowerBound, to: fetchEnd)
      }
      if rangeEnd > cache.latestDate {
        let fetchStart = Calendar(identifier: .gregorian)
          .date(
            byAdding: .day, value: 1,
            to: dateFormatter.date(from: cache.latestDate)!)!
        try await fetchRange(for: token, from: fetchStart, to: range.upperBound)
      }
    } else {
      try await fetchRange(for: token, from: range.lowerBound, to: range.upperBound)
    }

    let dates = generateDateSeries(in: range)
    var results: [(date: Date, price: Decimal)] = []
    var lastKnownPrice: Decimal?

    for date in dates {
      let dateString = dateFormatter.string(from: date)
      if let price = caches[token.id]?.prices[dateString] {
        lastKnownPrice = price
        results.append((date, price))
      } else if let fallback = lastKnownPrice {
        results.append((date, fallback))
      }
    }

    return results
  }

  // MARK: - Batch current prices

  func currentPrices(for tokens: [CryptoToken]) async throws -> [String: Decimal] {
    var result: [String: Decimal] = [:]
    for client in clients {
      do {
        let prices = try await client.currentPrices(for: tokens)
        for (id, price) in prices where result[id] == nil {
          result[id] = price
        }
        if result.count == tokens.count { break }
      } catch {
        continue
      }
    }
    return result
  }

  // MARK: - Prefetch

  /// Prefetch latest prices for all registered tokens.
  func prefetchLatest() async {
    let tokens = await registeredTokens()
    guard !tokens.isEmpty else { return }
    await prefetchLatest(for: tokens)
  }

  func prefetchLatest(for tokens: [CryptoToken]) async {
    do {
      let prices = try await currentPrices(for: tokens)
      let dateString = dateFormatter.string(from: Date())
      for (tokenId, price) in prices {
        let symbol = tokens.first { $0.id == tokenId }?.symbol ?? ""
        merge(tokenId: tokenId, symbol: symbol, newPrices: [dateString: price])
        saveCacheToDisk(tokenId: tokenId)
      }
    } catch {
      // Prefetch is best-effort
    }
  }

  // MARK: - Private helpers

  private func lookupPrice(tokenId: String, dateString: String) -> Decimal? {
    caches[tokenId]?.prices[dateString]
  }

  private func fallbackPrice(tokenId: String, dateString: String) -> Decimal? {
    guard let cache = caches[tokenId] else { return nil }
    let sortedDates = cache.prices.keys.sorted().reversed()
    for cachedDate in sortedDates {
      if cachedDate <= dateString {
        return cache.prices[cachedDate]
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

  private func fetchRange(for token: CryptoToken, from: Date, to: Date) async throws {
    var lastError: (any Error)?
    for client in clients {
      do {
        let fetched = try await client.dailyPrices(for: token, in: from...to)
        if !fetched.isEmpty {
          merge(tokenId: token.id, symbol: token.symbol, newPrices: fetched)
          saveCacheToDisk(tokenId: token.id)
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

  // MARK: - Instrument bridging

  /// Bridge an Instrument + CryptoProviderMapping to the legacy CryptoToken type
  /// for use with the existing CryptoPriceClient API.
  static nonisolated func bridgeToToken(
    instrument: Instrument, mapping: CryptoProviderMapping
  ) -> CryptoToken {
    CryptoToken(
      chainId: instrument.chainId ?? 0,
      contractAddress: instrument.contractAddress,
      symbol: instrument.ticker ?? instrument.name,
      name: instrument.name,
      decimals: instrument.decimals,
      coingeckoId: mapping.coingeckoId,
      cryptocompareSymbol: mapping.cryptocompareSymbol,
      binanceSymbol: mapping.binanceSymbol
    )
  }

  /// Fetch price for an instrument using its provider mapping.
  func price(
    for instrument: Instrument,
    mapping: CryptoProviderMapping,
    on date: Date
  ) async throws -> Decimal {
    let token = Self.bridgeToToken(instrument: instrument, mapping: mapping)
    return try await price(for: token, on: date)
  }

  /// Fetch price range for an instrument using its provider mapping.
  func prices(
    for instrument: Instrument,
    mapping: CryptoProviderMapping,
    in range: ClosedRange<Date>
  ) async throws -> [(date: Date, price: Decimal)] {
    let token = Self.bridgeToToken(instrument: instrument, mapping: mapping)
    return try await prices(for: token, in: range)
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
