import Foundation
import Testing

@testable import Moolah

@Suite("FullConversionService — providerMappings throws")
struct FullConversionErrorPropagationTests {
  struct FakeRegistryError: Error {}

  /// When the `providerMappings` closure throws (e.g. registry read failure),
  /// the error must propagate through `convert(_:from:to:on:)` for a crypto
  /// conversion rather than being silently collapsed to an empty mapping
  /// table — which would masquerade as a spurious `noProviderMapping` error
  /// and violate Rule 11 of `guides/INSTRUMENT_CONVERSION_GUIDE.md`.
  @Test
  func cryptoConversionPropagatesRegistryError() async throws {
    let cryptoService = CryptoPriceService(
      clients: [FixedCryptoPriceClient()],
      cacheDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    )
    let exchangeService = ExchangeRateService(
      client: FixedRateClient(rates: [:]),
      cacheDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    )
    let stockService = StockPriceService(client: FixedStockPriceClient())

    let service = FullConversionService(
      exchangeRates: exchangeService,
      stockPrices: stockService,
      cryptoPrices: cryptoService,
      providerMappings: { () async throws -> [CryptoProviderMapping] in
        throw FakeRegistryError()
      }
    )

    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH",
      name: "Ethereum", decimals: 18
    )

    await #expect(throws: FakeRegistryError.self) {
      _ = try await service.convert(
        Decimal(1), from: eth, to: Instrument.USD, on: Date()
      )
    }
  }
}
