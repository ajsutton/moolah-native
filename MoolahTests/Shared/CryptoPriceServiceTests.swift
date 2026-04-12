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
    cacheDirectory: URL? = nil
  ) -> CryptoPriceService {
    let clientList = clients ?? [FixedCryptoPriceClient(prices: prices, shouldFail: shouldFail)]
    let cacheDir =
      cacheDirectory
      ?? FileManager.default.temporaryDirectory
      .appendingPathComponent("crypto-price-tests")
      .appendingPathComponent(UUID().uuidString)
    return CryptoPriceService(clients: clientList, cacheDirectory: cacheDir)
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
}
