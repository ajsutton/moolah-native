import Foundation
import Testing

@testable import Moolah

@Suite("InstrumentConversionService — Crypto")
struct InstrumentConversionServiceCryptoTests {
  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
  )
  private let btc = Instrument.crypto(
    chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8
  )
  private let aud = Instrument.AUD
  private let usd = Instrument.USD

  private func date(_ string: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    return f.date(from: string)!
  }

  private func makeService(
    cryptoPrices: [String: [String: Decimal]] = [:],
    exchangeRates: [String: [String: Decimal]] = [:],
    providerMappings: [CryptoProviderMapping] = []
  ) -> FullConversionService {
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
    let stockService = StockPriceService(client: FixedStockPriceClient())
    return FullConversionService(
      exchangeRates: exchangeService,
      stockPrices: stockService,
      cryptoPrices: cryptoService,
      providerMappings: providerMappings
    )
  }

  // MARK: - Crypto -> Fiat (USD)

  @Test func cryptoToUsdUsesDirectPrice() async throws {
    let service = makeService(
      cryptoPrices: ["1:native": ["2026-04-10": Decimal(string: "1623.45")!]],
      providerMappings: [
        CryptoProviderMapping(
          instrumentId: "1:native", coingeckoId: "ethereum",
          cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
        )
      ]
    )
    let result = try await service.convert(
      Decimal(string: "2.5")!, from: eth, to: usd, on: date("2026-04-10")
    )
    // 2.5 * 1623.45 = 4058.625
    #expect(result == Decimal(string: "4058.625")!)
  }

  // MARK: - Crypto -> Fiat (non-USD, two-hop)

  @Test func cryptoToAudGoesViaUsd() async throws {
    let service = makeService(
      cryptoPrices: ["1:native": ["2026-04-10": Decimal(string: "1623.45")!]],
      exchangeRates: ["2026-04-10": ["AUD": Decimal(string: "1.58")!]],
      providerMappings: [
        CryptoProviderMapping(
          instrumentId: "1:native", coingeckoId: "ethereum",
          cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
        )
      ]
    )
    let result = try await service.convert(
      Decimal(string: "2.5")!, from: eth, to: aud, on: date("2026-04-10")
    )
    let expected =
      Decimal(string: "2.5")! * Decimal(string: "1623.45")! * Decimal(string: "1.58")!
    #expect(result == expected)
  }

  // MARK: - Crypto -> Crypto (both non-fiat)

  @Test func cryptoToCryptoChainsThroughUsd() async throws {
    let service = makeService(
      cryptoPrices: [
        "1:native": ["2026-04-10": Decimal(string: "1623.45")!],
        "0:native": ["2026-04-10": Decimal(string: "63000.00")!],
      ],
      providerMappings: [
        CryptoProviderMapping(
          instrumentId: "1:native", coingeckoId: "ethereum",
          cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
        ),
        CryptoProviderMapping(
          instrumentId: "0:native", coingeckoId: "bitcoin",
          cryptocompareSymbol: "BTC", binanceSymbol: "BTCUSDT"
        ),
      ]
    )
    let result = try await service.convert(
      Decimal(10), from: eth, to: btc, on: date("2026-04-10")
    )
    let usdValue = Decimal(10) * Decimal(string: "1623.45")!
    let expected = usdValue / Decimal(string: "63000.00")!
    #expect(result == expected)
  }

  // MARK: - Missing provider mapping throws

  @Test func missingProviderMappingThrows() async throws {
    let service = makeService(
      cryptoPrices: ["1:native": ["2026-04-10": Decimal(string: "1623.45")!]]
    )
    await #expect(throws: (any Error).self) {
      _ = try await service.convert(Decimal(1), from: eth, to: usd, on: date("2026-04-10"))
    }
  }

  // MARK: - Fiat -> Crypto (reverse direction)

  @Test func fiatToCryptoIsInverseOfCryptoToFiat() async throws {
    let service = makeService(
      cryptoPrices: ["1:native": ["2026-04-10": Decimal(string: "1623.45")!]],
      providerMappings: [
        CryptoProviderMapping(
          instrumentId: "1:native", coingeckoId: "ethereum",
          cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
        )
      ]
    )
    let result = try await service.convert(
      Decimal(5000), from: usd, to: eth, on: date("2026-04-10")
    )
    let expected = Decimal(5000) / Decimal(string: "1623.45")!
    #expect(result == expected)
  }

  // MARK: - Bridge token test

  @Test func bridgeToTokenPreservesIdentity() {
    let instrument = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let mapping = CryptoProviderMapping(
      instrumentId: "1:native", coingeckoId: "ethereum",
      cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
    )
    let bridgedToken = CryptoPriceService.bridgeToToken(
      instrument: instrument, mapping: mapping)
    #expect(bridgedToken.id == "1:native")
    #expect(bridgedToken.coingeckoId == "ethereum")
  }
}
