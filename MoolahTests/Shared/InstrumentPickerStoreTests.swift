import Foundation
import Testing
import os

@testable import Moolah

@Suite("InstrumentPickerStore")
@MainActor
struct InstrumentPickerStoreTests {
  @Test("start() yields registered + ambient fiat for fiat-only kinds")
  func startYieldsFiatList() async throws {
    let (backend, _) = try TestBackend.create()
    let service = InstrumentSearchService(
      registry: backend.instrumentRegistry,
      catalog: nil,
      resolutionClient: StubTokenResolutionClient(),
      stockSearchClient: StubStockSearchClient()
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
      catalog: nil,
      resolutionClient: StubTokenResolutionClient(),
      stockSearchClient: StubStockSearchClient()
    )
    let store = InstrumentPickerStore(
      searchService: service,
      registry: backend.instrumentRegistry,
      kinds: [.fiatCurrency]
    )
    await store.start()
    store.updateQuery("usd")
    await store.waitForPendingSearch()
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
      catalog: nil,
      resolutionClient: StubTokenResolutionClient(),
      stockSearchClient: StubStockSearchClient()
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

  @Test("kinds: [.fiatCurrency] excludes registered stocks")
  func kindsFilterExcludesStocks() async throws {
    let (backend, _) = try TestBackend.create()
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    try await backend.instrumentRegistry.registerStock(bhp)
    let service = InstrumentSearchService(
      registry: backend.instrumentRegistry,
      catalog: nil,
      resolutionClient: StubTokenResolutionClient(),
      stockSearchClient: StubStockSearchClient()
    )
    let store = InstrumentPickerStore(
      searchService: service,
      registry: backend.instrumentRegistry,
      kinds: [.fiatCurrency]
    )
    await store.start()
    #expect(store.results.allSatisfy { $0.instrument.kind == .fiatCurrency })
    #expect(store.results.contains { $0.instrument.id == "ASX:BHP.AX" } == false)
  }

  @Test("no-service mode returns Instrument.commonFiatCodes filtered by kinds")
  func noServiceFiatList() async {
    let store = InstrumentPickerStore(kinds: [.fiatCurrency])
    await store.start()
    for code in Instrument.commonFiatCodes {
      #expect(store.results.contains { $0.instrument.id == code })
    }
  }

  @Test("no-service mode narrows by typed query")
  func noServiceTypedQuery() async throws {
    let store = InstrumentPickerStore(kinds: [.fiatCurrency])
    await store.start()
    store.updateQuery("usd")
    await store.waitForPendingSearch()
    #expect(store.results.contains { $0.instrument.id == "USD" })
    #expect(
      store.results.allSatisfy {
        $0.instrument.id == "USD"
          || $0.instrument.name.localizedCaseInsensitiveContains("dollar")
      })
  }

  @Test("no-service mode returns empty when kinds excludes fiat")
  func noServiceNonFiatKinds() async {
    let store = InstrumentPickerStore(kinds: [.stock])
    await store.start()
    #expect(store.results.isEmpty)
  }

  @Test("select of unregistered Yahoo stock auto-registers and returns")
  func selectStockAutoRegisters() async throws {
    let (backend, _) = try TestBackend.create()
    let stockHit = StockSearchHit(
      symbol: "AAPL", name: "Apple Inc.", exchange: "NASDAQ", quoteType: .equity)
    let service = InstrumentSearchService(
      registry: backend.instrumentRegistry,
      catalog: nil,
      resolutionClient: StubTokenResolutionClient(),
      stockSearchClient: StubStockSearchClient(hits: [stockHit])
    )
    let store = InstrumentPickerStore(
      searchService: service,
      registry: backend.instrumentRegistry,
      kinds: Set(Instrument.Kind.allCases)
    )
    store.updateQuery("AAPL")
    await store.waitForPendingSearch()
    let hit = try #require(store.results.first { $0.instrument.ticker == "AAPL" })
    #expect(hit.isRegistered == false)
    let picked = await store.select(hit)
    #expect(picked?.ticker == "AAPL")
    let registered = try await backend.instrumentRegistry.all()
    #expect(registered.contains { $0.id == "NASDAQ:AAPL" })
  }

}

@Suite("InstrumentPickerStore.select crypto branches")
@MainActor
struct InstrumentPickerStoreCryptoSelectTests {
  @Test("selecting unregistered crypto resolves and registers via the resolver")
  func selectUnregisteredCryptoRunsResolveAndRegisters() async throws {
    let registry = StubInstrumentRegistry()
    let resolver = RecordingTokenResolutionClient(
      result: TokenResolutionResult(
        coingeckoId: "uniswap",
        cryptocompareSymbol: "UNI",
        binanceSymbol: "UNIUSDT",
        resolvedName: "Uniswap",
        resolvedSymbol: "UNI",
        resolvedDecimals: 18
      )
    )
    let result = InstrumentSearchResult(
      instrument: Instrument.crypto(
        chainId: 1, contractAddress: "0xuni", symbol: "UNI", name: "Uniswap", decimals: 18
      ),
      cryptoMapping: nil,
      isRegistered: false,
      requiresResolution: true
    )
    let store = InstrumentPickerStore(
      registry: registry,
      resolutionClient: resolver,
      kinds: [.cryptoToken]
    )

    let selected = await store.select(result)

    #expect(selected != nil)
    #expect(selected?.id == "1:0xuni")
    let snapshot = registry.snapshot()
    #expect(snapshot.registeredCryptos.count == 1)
    #expect(snapshot.registeredCryptos.first?.mapping.coingeckoId == "uniswap")
    #expect(snapshot.registeredCryptos.first?.mapping.cryptocompareSymbol == "UNI")
    #expect(snapshot.registeredCryptos.first?.mapping.binanceSymbol == "UNIUSDT")
    #expect(store.error == nil)
    #expect(store.isResolving == false)
    let resolverCalls = resolver.calls
    #expect(resolverCalls.count == 1)
    #expect(resolverCalls.first?.chainId == 1)
    #expect(resolverCalls.first?.contractAddress == "0xuni")
    #expect(resolverCalls.first?.isNative == false)
  }

  @Test("selecting unregistered native crypto resolves with isNative=true and nil contract")
  func selectUnregisteredNativeCryptoUsesIsNativeTrue() async throws {
    let registry = StubInstrumentRegistry()
    let resolver = RecordingTokenResolutionClient(
      result: TokenResolutionResult(
        coingeckoId: "bitcoin",
        cryptocompareSymbol: "BTC",
        binanceSymbol: "BTCUSDT",
        resolvedName: "Bitcoin",
        resolvedSymbol: "BTC",
        resolvedDecimals: 8
      )
    )
    let result = InstrumentSearchResult(
      instrument: Instrument.crypto(
        chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8
      ),
      cryptoMapping: nil,
      isRegistered: false,
      requiresResolution: true
    )
    let store = InstrumentPickerStore(
      registry: registry,
      resolutionClient: resolver,
      kinds: [.cryptoToken]
    )

    let selected = await store.select(result)

    #expect(selected?.id == "0:native")
    let resolverCalls = resolver.calls
    #expect(resolverCalls.count == 1)
    #expect(resolverCalls.first?.isNative == true)
    #expect(resolverCalls.first?.contractAddress == nil)
    let snapshot = registry.snapshot()
    #expect(snapshot.registeredCryptos.count == 1)
  }

  @Test("selecting unregistered crypto with no provider mapping fails and writes nothing")
  func selectUnregisteredCryptoWithoutAnyMappingFailsAndDoesNotWrite() async throws {
    let registry = StubInstrumentRegistry()
    let resolver = RecordingTokenResolutionClient(
      result: TokenResolutionResult()
    )
    let result = InstrumentSearchResult(
      instrument: Instrument.crypto(
        chainId: 1, contractAddress: "0xfoo", symbol: "FOO", name: "Foo", decimals: 18
      ),
      cryptoMapping: nil,
      isRegistered: false,
      requiresResolution: true
    )
    let store = InstrumentPickerStore(
      registry: registry,
      resolutionClient: resolver,
      kinds: [.cryptoToken]
    )

    let selected = await store.select(result)

    #expect(selected == nil)
    #expect(store.error != nil)
    #expect(store.isResolving == false)
    let snapshot = registry.snapshot()
    #expect(snapshot.registeredCryptos.isEmpty)
  }

  @Test("selecting registered crypto returns immediately without resolving")
  func selectRegisteredCryptoReturnsImmediately() async throws {
    let registered = Instrument.crypto(
      chainId: 1, contractAddress: "0xuni", symbol: "UNI", name: "Uniswap", decimals: 18
    )
    let mapping = CryptoProviderMapping(
      instrumentId: registered.id,
      coingeckoId: "uniswap",
      cryptocompareSymbol: nil,
      binanceSymbol: nil
    )
    let registry = StubInstrumentRegistry(
      instruments: [registered],
      cryptoRegistrations: [CryptoRegistration(instrument: registered, mapping: mapping)]
    )
    let resolver = RecordingTokenResolutionClient(result: TokenResolutionResult())
    let result = InstrumentSearchResult(
      instrument: registered,
      cryptoMapping: mapping,
      isRegistered: true,
      requiresResolution: false
    )
    let store = InstrumentPickerStore(
      registry: registry,
      resolutionClient: resolver,
      kinds: [.cryptoToken]
    )

    let selected = await store.select(result)

    #expect(selected?.id == registered.id)
    #expect(resolver.calls.isEmpty)
    let snapshot = registry.snapshot()
    #expect(snapshot.registeredCryptos.isEmpty)
  }

  @Test("selecting unregistered crypto surfaces resolver errors")
  func selectUnregisteredCryptoSurfacesResolverError() async throws {
    let registry = StubInstrumentRegistry()
    let resolver = RecordingTokenResolutionClient(
      result: TokenResolutionResult(),
      shouldFail: true
    )
    let result = InstrumentSearchResult(
      instrument: Instrument.crypto(
        chainId: 1, contractAddress: "0xbar", symbol: "BAR", name: "Bar", decimals: 18
      ),
      cryptoMapping: nil,
      isRegistered: false,
      requiresResolution: true
    )
    let store = InstrumentPickerStore(
      registry: registry,
      resolutionClient: resolver,
      kinds: [.cryptoToken]
    )

    let selected = await store.select(result)

    #expect(selected == nil)
    #expect(store.error != nil)
    let snapshot = registry.snapshot()
    #expect(snapshot.registeredCryptos.isEmpty)
  }
}

private struct StubStockSearchClient: StockSearchClient {
  let hits: [StockSearchHit]

  init(hits: [StockSearchHit] = []) { self.hits = hits }

  func search(query: String) async throws -> [StockSearchHit] { hits }
}

private struct StubTokenResolutionClient: TokenResolutionClient {
  func resolve(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async throws -> TokenResolutionResult {
    .init()
  }
}

/// Test resolver that records each `resolve` call so tests can assert on
/// chainId / contractAddress / isNative — all three matter for the picker's
/// branch logic in Task 9.
private final class RecordingTokenResolutionClient: TokenResolutionClient, Sendable {
  struct Call: Sendable {
    let chainId: Int
    let contractAddress: String?
    let symbol: String?
    let isNative: Bool
  }

  private let recordedCalls: OSAllocatedUnfairLock<[Call]> = .init(initialState: [])
  private let result: TokenResolutionResult
  private let shouldFail: Bool

  init(result: TokenResolutionResult, shouldFail: Bool = false) {
    self.result = result
    self.shouldFail = shouldFail
  }

  var calls: [Call] { recordedCalls.withLock { $0 } }

  func resolve(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async throws -> TokenResolutionResult {
    recordedCalls.withLock { calls in
      calls.append(
        Call(
          chainId: chainId,
          contractAddress: contractAddress,
          symbol: symbol,
          isNative: isNative
        )
      )
    }
    if shouldFail { throw URLError(.notConnectedToInternet) }
    return result
  }
}
