import Foundation
import Testing

@testable import Moolah

@Suite("InstrumentPickerStore")
@MainActor
struct InstrumentPickerStoreTests {
  @Test("start() yields registered + ambient fiat for fiat-only kinds")
  func startYieldsFiatList() async throws {
    let (backend, _) = try TestBackend.create()
    let service = InstrumentSearchService(
      registry: backend.instrumentRegistry,
      cryptoSearchClient: StubCryptoSearchClient(),
      resolutionClient: StubTokenResolutionClient(),
      stockValidator: StubStockTickerValidator()
    )
    let store = InstrumentPickerStore(
      searchService: service,
      registry: backend.instrumentRegistry,
      kinds: [.fiatCurrency]
    )
    await store.start()
    #expect(store.results.contains { $0.instrument.id == "USD" })
    #expect(store.results.allSatisfy { $0.instrument.kind == .fiatCurrency })
  }
}

private struct StubCryptoSearchClient: CryptoSearchClient {
  func search(query: String) async throws -> [CryptoSearchHit] { [] }
}

private struct StubTokenResolutionClient: TokenResolutionClient {
  func resolve(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async throws -> TokenResolutionResult {
    .init()
  }
}

private struct StubStockTickerValidator: StockTickerValidator {
  let validated: ValidatedStockTicker?

  init(validated: ValidatedStockTicker? = nil) { self.validated = validated }

  func validate(query: String) async throws -> ValidatedStockTicker? { validated }
}
