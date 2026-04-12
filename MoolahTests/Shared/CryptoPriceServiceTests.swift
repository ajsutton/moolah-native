// MoolahTests/Shared/CryptoPriceServiceTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("CryptoPriceService")
struct CryptoPriceServiceTests {
  private let eth = CryptoToken(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum",
    decimals: 18, coingeckoId: "ethereum", cryptocompareSymbol: "ETH",
    binanceSymbol: "ETHUSDT"
  )

  private let btc = CryptoToken(
    chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin",
    decimals: 8, coingeckoId: "bitcoin", cryptocompareSymbol: "BTC",
    binanceSymbol: "BTCUSDT"
  )

  private func makeService(
    clients: [CryptoPriceClient]? = nil,
    prices: [String: [String: Decimal]] = [:],
    shouldFail: Bool = false,
    cacheDirectory: URL? = nil,
    tokenRepository: CryptoTokenRepository? = nil,
    resolutionClient: (any TokenResolutionClient)? = nil
  ) -> CryptoPriceService {
    let clientList = clients ?? [FixedCryptoPriceClient(prices: prices, shouldFail: shouldFail)]
    let cacheDir =
      cacheDirectory
      ?? FileManager.default.temporaryDirectory
      .appendingPathComponent("crypto-price-tests")
      .appendingPathComponent(UUID().uuidString)
    return CryptoPriceService(
      clients: clientList,
      cacheDirectory: cacheDir,
      tokenRepository: tokenRepository ?? InMemoryTokenRepository(),
      resolutionClient: resolutionClient
    )
  }

  private func date(_ string: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    return f.date(from: string)!
  }

  // MARK: - Cache miss and hit

  @Test func cacheMissFetchesFromClient() async throws {
    let service = makeService(prices: [
      "1:native": ["2026-04-10": Decimal(string: "1623.45")!]
    ])
    let price = try await service.price(for: eth, on: date("2026-04-10"))
    #expect(price == Decimal(string: "1623.45")!)
  }

  @Test func cacheHitDoesNotRefetch() async throws {
    let service = makeService(prices: [
      "1:native": ["2026-04-10": Decimal(string: "1623.45")!]
    ])
    let first = try await service.price(for: eth, on: date("2026-04-10"))
    let second = try await service.price(for: eth, on: date("2026-04-10"))
    #expect(first == second)
  }

  // MARK: - Provider fallback

  @Test func firstClientFailsFallsToSecond() async throws {
    let failing = FixedCryptoPriceClient(shouldFail: true)
    let working = FixedCryptoPriceClient(prices: [
      "1:native": ["2026-04-10": Decimal(string: "1623.45")!]
    ])
    let service = makeService(clients: [failing, working])
    let price = try await service.price(for: eth, on: date("2026-04-10"))
    #expect(price == Decimal(string: "1623.45")!)
  }

  @Test func allClientsFail_fallsBackToCachedPriorDate() async throws {
    let working = FixedCryptoPriceClient(prices: [
      "1:native": ["2026-04-09": Decimal(string: "1600.00")!]
    ])
    let service = makeService(clients: [working])
    _ = try await service.price(for: eth, on: date("2026-04-09"))

    // Request a later date — client has no data for it, triggering fallback
    let price = try await service.price(for: eth, on: date("2026-04-10"))
    #expect(price == Decimal(string: "1600.00")!)
  }

  @Test func allClientsFailWithEmptyCacheThrows() async throws {
    let service = makeService(shouldFail: true)
    await #expect(throws: (any Error).self) {
      try await service.price(for: eth, on: date("2026-04-10"))
    }
  }

  // MARK: - Fallback never uses future dates

  @Test func fallbackNeverUsesFutureDate() async throws {
    let working = FixedCryptoPriceClient(prices: [
      "1:native": ["2026-04-15": Decimal(string: "1700.00")!]
    ])
    let service = makeService(clients: [working])
    _ = try await service.price(for: eth, on: date("2026-04-15"))

    await #expect(throws: (any Error).self) {
      try await service.price(for: eth, on: date("2026-04-10"))
    }
  }

  // MARK: - Date range

  @Test func rangeFetchReturnsPricesForEachDay() async throws {
    let service = makeService(prices: [
      "1:native": [
        "2026-04-07": Decimal(string: "1600.00")!,
        "2026-04-08": Decimal(string: "1610.00")!,
        "2026-04-09": Decimal(string: "1620.00")!,
      ]
    ])
    let results = try await service.prices(
      for: eth, in: date("2026-04-07")...date("2026-04-09")
    )
    #expect(results.count == 3)
    #expect(results[0].price == Decimal(string: "1600.00")!)
    #expect(results[2].price == Decimal(string: "1620.00")!)
  }

  @Test func rangeFetchOnlyRequestsMissingSegments() async throws {
    let service = makeService(prices: [
      "1:native": [
        "2026-04-07": Decimal(string: "1600.00")!,
        "2026-04-08": Decimal(string: "1610.00")!,
        "2026-04-09": Decimal(string: "1620.00")!,
        "2026-04-10": Decimal(string: "1630.00")!,
        "2026-04-11": Decimal(string: "1640.00")!,
      ]
    ])
    _ = try await service.prices(for: eth, in: date("2026-04-08")...date("2026-04-09"))
    let results = try await service.prices(
      for: eth, in: date("2026-04-07")...date("2026-04-11")
    )
    #expect(results.count == 5)
    #expect(results[0].price == Decimal(string: "1600.00")!)
    #expect(results[4].price == Decimal(string: "1640.00")!)
  }

  @Test func rangeFillsWeekendGapsWithLastKnownPrice() async throws {
    let service = makeService(prices: [
      "1:native": [
        "2026-04-10": Decimal(string: "1630.00")!
      ]
    ])
    let results = try await service.prices(
      for: eth, in: date("2026-04-10")...date("2026-04-12")
    )
    #expect(results.count == 3)
    #expect(results[1].price == Decimal(string: "1630.00")!)
    #expect(results[2].price == Decimal(string: "1630.00")!)
  }

  // MARK: - Batch current prices

  @Test func currentPricesFetchesForAllTokens() async throws {
    let service = makeService(prices: [
      "1:native": ["2026-04-11": Decimal(string: "1640.00")!],
      "0:native": ["2026-04-11": Decimal(string: "67890.00")!],
    ])
    let prices = try await service.currentPrices(for: [eth, btc])
    #expect(prices["1:native"] == Decimal(string: "1640.00")!)
    #expect(prices["0:native"] == Decimal(string: "67890.00")!)
  }

  // MARK: - Gzip round-trip

  @Test func gzipRoundTripPreservesData() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("crypto-price-tests")
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let service1 = makeService(
      prices: ["1:native": ["2026-04-10": Decimal(string: "1623.45")!]],
      cacheDirectory: tempDir
    )
    let price = try await service1.price(for: eth, on: date("2026-04-10"))
    #expect(price == Decimal(string: "1623.45")!)

    let service2 = makeService(shouldFail: true, cacheDirectory: tempDir)
    let cached = try await service2.price(for: eth, on: date("2026-04-10"))
    #expect(cached == Decimal(string: "1623.45")!)
  }

  // MARK: - Prefetch

  @Test func prefetchLatest_usesRegisteredTokensWhenNoneProvided() async throws {
    let repo = InMemoryTokenRepository()
    try await repo.saveTokens([eth, btc])

    let service = makeService(
      prices: [
        "1:native": ["2026-04-11": Decimal(string: "1640.00")!],
        "0:native": ["2026-04-11": Decimal(string: "67890.00")!],
      ],
      tokenRepository: repo
    )
    await service.prefetchLatest()
    let ethPrice = try await service.price(for: eth, on: date("2026-04-11"))
    #expect(ethPrice == Decimal(string: "1640.00")!)
  }

  @Test func prefetchUpdatesCacheForRegisteredTokens() async throws {
    let service = makeService(prices: [
      "1:native": ["2026-04-11": Decimal(string: "1640.00")!],
      "0:native": ["2026-04-11": Decimal(string: "67890.00")!],
    ])
    await service.prefetchLatest(for: [eth, btc])
    let ethPrice = try await service.price(for: eth, on: date("2026-04-11"))
    #expect(ethPrice == Decimal(string: "1640.00")!)
  }

  // MARK: - Multiple tokens cached independently

  @Test func differentTokensAreCachedIndependently() async throws {
    let service = makeService(prices: [
      "1:native": ["2026-04-10": Decimal(string: "1623.45")!],
      "0:native": ["2026-04-10": Decimal(string: "67890.00")!],
    ])
    let ethPrice = try await service.price(for: eth, on: date("2026-04-10"))
    let btcPrice = try await service.price(for: btc, on: date("2026-04-10"))
    #expect(ethPrice == Decimal(string: "1623.45")!)
    #expect(btcPrice == Decimal(string: "67890.00")!)
  }

  // MARK: - Token management

  @Test func registerTokenAddsToList() async throws {
    let service = makeService()
    let token = CryptoToken.builtInPresets[0]
    try await service.registerToken(token)
    let tokens = await service.registeredTokens()
    #expect(tokens.count == 1)
    #expect(tokens[0].id == token.id)
  }

  @Test func removeTokenDeletesFromList() async throws {
    let service = makeService()
    let token = CryptoToken.builtInPresets[0]
    try await service.registerToken(token)
    try await service.removeToken(token)
    let tokens = await service.registeredTokens()
    #expect(tokens.isEmpty)
  }

  @Test func registeredTokensPersistViaRepository() async throws {
    let repo = InMemoryTokenRepository()
    let service1 = makeService(tokenRepository: repo)
    try await service1.registerToken(CryptoToken.builtInPresets[0])

    let service2 = makeService(tokenRepository: repo)
    let tokens = await service2.registeredTokens()
    #expect(tokens.count == 1)
  }

  // MARK: - Token resolution

  @Test func resolveToken_populatesProviderFields() async throws {
    let result = TokenResolutionResult(
      coingeckoId: "uniswap",
      cryptocompareSymbol: "UNI",
      binanceSymbol: "UNIUSDT",
      resolvedName: "Uniswap",
      resolvedSymbol: "UNI",
      resolvedDecimals: 18
    )
    let service = makeService(resolutionClient: FixedTokenResolutionClient(result: result))

    let token = try await service.resolveToken(
      chainId: 1,
      contractAddress: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984",
      symbol: nil,
      isNative: false
    )
    #expect(token.coingeckoId == "uniswap")
    #expect(token.cryptocompareSymbol == "UNI")
    #expect(token.binanceSymbol == "UNIUSDT")
    #expect(token.name == "Uniswap")
  }

  @Test func resolveToken_noProvidersMatch_returnsPartialToken() async throws {
    let service = makeService(
      resolutionClient: FixedTokenResolutionClient(result: TokenResolutionResult())
    )
    let token = try await service.resolveToken(
      chainId: 999,
      contractAddress: "0xunknown",
      symbol: "UNKNOWN",
      isNative: false
    )
    #expect(token.coingeckoId == nil)
    #expect(token.cryptocompareSymbol == nil)
    #expect(token.binanceSymbol == nil)
    #expect(token.symbol == "UNKNOWN")
  }

  @Test func resolveToken_resolutionFails_throws() async throws {
    let service = makeService(
      resolutionClient: FixedTokenResolutionClient(shouldFail: true)
    )
    await #expect(throws: (any Error).self) {
      try await service.resolveToken(
        chainId: 1, contractAddress: "0xabc", symbol: nil, isNative: false
      )
    }
  }
}
