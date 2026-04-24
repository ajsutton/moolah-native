// MoolahTests/Shared/CryptoPriceServiceTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("CryptoPriceService — Part 2")
struct CryptoPriceServiceTestsMore {
  private let ethInstrument = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
  )
  private let ethMapping = CryptoProviderMapping(
    instrumentId: "1:native", coingeckoId: "ethereum",
    cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
  )

  private let btcInstrument = Instrument.crypto(
    chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8
  )
  private let btcMapping = CryptoProviderMapping(
    instrumentId: "0:native", coingeckoId: "bitcoin",
    cryptocompareSymbol: "BTC", binanceSymbol: "BTCUSDT"
  )

  private var ethRegistration: CryptoRegistration {
    CryptoRegistration(instrument: ethInstrument, mapping: ethMapping)
  }
  private var btcRegistration: CryptoRegistration {
    CryptoRegistration(instrument: btcInstrument, mapping: btcMapping)
  }

  private func makeService(
    clients: [CryptoPriceClient] = [],
    prices: [String: [String: Decimal]] = [:],
    shouldFail: Bool = false,
    cacheDirectory: URL? = nil,
    resolutionClient: (any TokenResolutionClient)? = nil
  ) -> CryptoPriceService {
    let clientList =
      clients.isEmpty
      ? [FixedCryptoPriceClient(prices: prices, shouldFail: shouldFail)]
      : clients
    let cacheDir =
      cacheDirectory
      ?? FileManager.default.temporaryDirectory
      .appendingPathComponent("crypto-price-tests")
      .appendingPathComponent(UUID().uuidString)
    return CryptoPriceService(
      clients: clientList,
      cacheDirectory: cacheDir,
      resolutionClient: resolutionClient
    )
  }

  private func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter.date(from: string)!
  }

  @Test
  func gzipRoundTripPreservesData() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("crypto-price-tests")
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let service1 = makeService(
      prices: ["1:native": ["2026-04-10": dec("1623.45")]],
      cacheDirectory: tempDir
    )
    let price = try await service1.price(
      for: ethInstrument, mapping: ethMapping, on: date("2026-04-10"))
    #expect(price == dec("1623.45"))

    let service2 = makeService(shouldFail: true, cacheDirectory: tempDir)
    let cached = try await service2.price(
      for: ethInstrument, mapping: ethMapping, on: date("2026-04-10"))
    #expect(cached == dec("1623.45"))
  }

  // MARK: - Prefetch

  @Test
  func prefetchUpdatesCacheForRegisteredItems() async throws {
    let service = makeService(prices: [
      "1:native": ["2026-04-11": dec("1640.00")],
      "0:native": ["2026-04-11": dec("67890.00")],
    ])
    await service.prefetchLatest(for: [ethRegistration, btcRegistration])
    let ethPrice = try await service.price(
      for: ethInstrument, mapping: ethMapping, on: date("2026-04-11"))
    #expect(ethPrice == dec("1640.00"))
  }

  // MARK: - Multiple tokens cached independently

  @Test
  func differentTokensAreCachedIndependently() async throws {
    let service = makeService(prices: [
      "1:native": ["2026-04-10": dec("1623.45")],
      "0:native": ["2026-04-10": dec("67890.00")],
    ])
    let ethPrice = try await service.price(
      for: ethInstrument, mapping: ethMapping, on: date("2026-04-10"))
    let btcPrice = try await service.price(
      for: btcInstrument, mapping: btcMapping, on: date("2026-04-10"))
    #expect(ethPrice == dec("1623.45"))
    #expect(btcPrice == dec("67890.00"))
  }

  // MARK: - Token resolution

  @Test
  func resolveRegistration_populatesProviderFields() async throws {
    let result = TokenResolutionResult(
      coingeckoId: "uniswap",
      cryptocompareSymbol: "UNI",
      binanceSymbol: "UNIUSDT",
      resolvedName: "Uniswap",
      resolvedSymbol: "UNI",
      resolvedDecimals: 18
    )
    let service = makeService(resolutionClient: FixedTokenResolutionClient(result: result))

    let registration = try await service.resolveRegistration(
      chainId: 1,
      contractAddress: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984",
      symbol: nil,
      isNative: false
    )
    #expect(registration.mapping.coingeckoId == "uniswap")
    #expect(registration.mapping.cryptocompareSymbol == "UNI")
    #expect(registration.mapping.binanceSymbol == "UNIUSDT")
    #expect(registration.instrument.name == "Uniswap")
  }

  @Test
  func resolveRegistration_noProvidersMatch_returnsPartialRegistration() async throws {
    let service = makeService(
      resolutionClient: FixedTokenResolutionClient(result: TokenResolutionResult())
    )
    let registration = try await service.resolveRegistration(
      chainId: 999,
      contractAddress: "0xunknown",
      symbol: "UNKNOWN",
      isNative: false
    )
    #expect(registration.mapping.coingeckoId == nil)
    #expect(registration.mapping.cryptocompareSymbol == nil)
    #expect(registration.mapping.binanceSymbol == nil)
    #expect(registration.instrument.ticker == "UNKNOWN")
  }

  @Test
  func resolveRegistration_resolutionFails_throws() async throws {
    let service = makeService(
      resolutionClient: FixedTokenResolutionClient(shouldFail: true)
    )
    await #expect(throws: (any Error).self) {
      try await service.resolveRegistration(
        chainId: 1, contractAddress: "0xabc", symbol: nil, isNative: false
      )
    }
  }
}
