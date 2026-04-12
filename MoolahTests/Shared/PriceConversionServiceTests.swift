// MoolahTests/Shared/PriceConversionServiceTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("PriceConversionService")
struct PriceConversionServiceTests {
  private let eth = CryptoToken(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum",
    decimals: 18, coingeckoId: "ethereum", cryptocompareSymbol: "ETH",
    binanceSymbol: "ETHUSDT"
  )

  private func date(_ string: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    return f.date(from: string)!
  }

  private func makeService(
    cryptoPrices: [String: [String: Decimal]] = [:],
    exchangeRates: [String: [String: Decimal]] = [:]
  ) -> PriceConversionService {
    let cryptoClient = FixedCryptoPriceClient(prices: cryptoPrices)
    let cryptoService = CryptoPriceService(
      clients: [cryptoClient],
      cacheDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    )
    let exchangeClient = FixedRateClient(rates: exchangeRates)
    let exchangeService = ExchangeRateService(
      client: exchangeClient,
      cacheDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    )
    return PriceConversionService(
      cryptoPrices: cryptoService, exchangeRates: exchangeService
    )
  }

  // MARK: - Multi-hop conversion (TOKEN -> USD -> AUD)

  @Test func convertTokenToNonUsdCurrency() async throws {
    let service = makeService(
      cryptoPrices: ["1:native": ["2026-04-10": Decimal(string: "1623.45")!]],
      exchangeRates: ["2026-04-10": ["AUD": Decimal(string: "1.58")!]]
    )
    let result = try await service.convert(
      amount: Decimal(string: "2.5")!, token: eth, to: .AUD, on: date("2026-04-10")
    )
    #expect(result.instrument == .AUD)
    // 2.5 * 1623.45 = 4058.625; 4058.625 * 1.58 = 6412.6275
    #expect(
      result.quantity == Decimal(string: "2.5")! * Decimal(string: "1623.45")! * Decimal(
        string: "1.58")!)
  }

  // MARK: - USD profile short-circuits exchange rate

  @Test func convertTokenToUsdSkipsExchangeRate() async throws {
    let service = makeService(
      cryptoPrices: ["1:native": ["2026-04-10": Decimal(string: "1623.45")!]]
    )
    let result = try await service.convert(
      amount: Decimal(1), token: eth, to: .USD, on: date("2026-04-10")
    )
    #expect(result.instrument == .USD)
    #expect(result.quantity == Decimal(string: "1623.45")!)
  }

  // MARK: - Unit price

  @Test func unitPriceReturnsDecimalInTargetCurrency() async throws {
    let service = makeService(
      cryptoPrices: ["1:native": ["2026-04-10": Decimal(string: "1623.45")!]],
      exchangeRates: ["2026-04-10": ["AUD": Decimal(string: "1.58")!]]
    )
    let price = try await service.unitPrice(for: eth, in: .AUD, on: date("2026-04-10"))
    #expect(price == Decimal(string: "1623.45")! * Decimal(string: "1.58")!)
  }

  // MARK: - Error propagation

  @Test func missingCryptoPriceThrows() async throws {
    let service = makeService()
    await #expect(throws: (any Error).self) {
      try await service.convert(
        amount: Decimal(1), token: eth, to: .AUD, on: date("2026-04-10")
      )
    }
  }

  @Test func missingExchangeRateThrows() async throws {
    let service = makeService(
      cryptoPrices: ["1:native": ["2026-04-10": Decimal(string: "1623.45")!]]
    )
    await #expect(throws: (any Error).self) {
      try await service.convert(
        amount: Decimal(1), token: eth, to: .AUD, on: date("2026-04-10")
      )
    }
  }

  // MARK: - Price history

  @Test func priceHistoryReturnsValuesForEachDay() async throws {
    let service = makeService(
      cryptoPrices: [
        "1:native": [
          "2026-04-07": Decimal(string: "1600.00")!,
          "2026-04-08": Decimal(string: "1610.00")!,
          "2026-04-09": Decimal(string: "1620.00")!,
        ]
      ],
      exchangeRates: [
        "2026-04-07": ["AUD": Decimal(string: "1.58")!],
        "2026-04-08": ["AUD": Decimal(string: "1.59")!],
        "2026-04-09": ["AUD": Decimal(string: "1.57")!],
      ]
    )
    let history = try await service.priceHistory(
      for: eth, in: .AUD, over: date("2026-04-07")...date("2026-04-09")
    )
    #expect(history.count == 3)
    #expect(history[0].price == Decimal(string: "1600.00")! * Decimal(string: "1.58")!)
  }
}
