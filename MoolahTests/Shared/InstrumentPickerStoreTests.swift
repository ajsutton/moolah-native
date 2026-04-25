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

  @Test("typed query narrows to matching ISO codes")
  func typedQueryNarrows() async throws {
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
    store.updateQuery("usd")
    // Wait one debounce tick.
    try? await Task.sleep(for: .milliseconds(350))
    #expect(store.results.contains { $0.instrument.id == "USD" })
    #expect(
      store.results.allSatisfy {
        $0.instrument.id.lowercased().contains("usd")
          || $0.instrument.name.localizedCaseInsensitiveContains("dollar")
      })
  }

  @Test("select of registered fiat returns the instrument without registry write")
  func selectRegisteredFiat() async throws {
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
    let usd = try #require(store.results.first { $0.instrument.id == "USD" })
    let picked = await store.select(usd)
    #expect(picked?.id == "USD")
    // Registry should be unchanged: no new stock/crypto rows added.
    let registered = try await backend.instrumentRegistry.all()
    #expect(registered.allSatisfy { $0.kind == .fiatCurrency })
  }

  @Test("select of unregistered Yahoo stock auto-registers and returns")
  func selectStockAutoRegisters() async throws {
    let (backend, _) = try TestBackend.create()
    let validated = ValidatedStockTicker(ticker: "AAPL", exchange: "NASDAQ")
    let service = InstrumentSearchService(
      registry: backend.instrumentRegistry,
      cryptoSearchClient: StubCryptoSearchClient(),
      resolutionClient: StubTokenResolutionClient(),
      stockValidator: StubStockTickerValidator(validated: validated)
    )
    let store = InstrumentPickerStore(
      searchService: service,
      registry: backend.instrumentRegistry,
      kinds: Set(Instrument.Kind.allCases)
    )
    store.updateQuery("AAPL")
    try? await Task.sleep(for: .milliseconds(350))
    let hit = try #require(store.results.first { $0.instrument.ticker == "AAPL" })
    #expect(hit.isRegistered == false)
    let picked = await store.select(hit)
    #expect(picked?.ticker == "AAPL")
    let registered = try await backend.instrumentRegistry.all()
    #expect(registered.contains { $0.id == "NASDAQ:AAPL" })
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
