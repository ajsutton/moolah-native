import Foundation
import Testing

@testable import Moolah

@Suite("InstrumentSearchService")
@MainActor
struct InstrumentSearchServiceTests {
  @MainActor
  func makeSubject(
    registered: [Instrument] = [],
    cryptoRegistrations: [CryptoRegistration] = [],
    catalogEntries: [CatalogEntry] = [],
    stockHits: [StockSearchHit] = [],
    stockSearchThrows: Bool = false,
    resolvedRegistration: CryptoRegistration? = nil
  ) -> InstrumentSearchService {
    let registry = StubRegistry(
      instruments: registered, cryptoRegistrations: cryptoRegistrations)
    let catalog = StubCatalog(entries: catalogEntries)
    let stock = StubStockSearchClient(hits: stockHits, shouldThrow: stockSearchThrows)
    let resolver = StubTokenResolutionClient(resolved: resolvedRegistration)
    let validator = StubStockTickerValidator()
    return InstrumentSearchService(
      registry: registry,
      catalog: catalog,
      resolutionClient: resolver,
      stockSearchClient: stock,
      stockValidator: validator
    )
  }

  @Test("fiat prefix match on ISO code")
  func fiatPrefixMatch() async throws {
    let service = makeSubject()
    let results = await service.search(query: "usd")
    #expect(results.contains { $0.instrument.id == "USD" })
    #expect(results.allSatisfy { $0.instrument.kind == .fiatCurrency })
  }

  @Test("fiat substring match on localized name")
  func fiatNameMatch() async throws {
    let service = makeSubject()
    let results = await service.search(query: "dollar")
    let ids = results.map(\.instrument.id)
    #expect(ids.contains("USD") || ids.contains("AUD"))
  }

  @Test("crypto results loaded from catalog with platform binding")
  func cryptoResultsCarryCatalogPlatform() async throws {
    let entry = CatalogEntry(
      coingeckoId: "uniswap",
      symbol: "UNI",
      name: "Uniswap",
      platforms: [
        PlatformBinding(
          slug: "ethereum",
          chainId: 1,
          contractAddress: "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"
        )
      ]
    )
    let service = makeSubject(catalogEntries: [entry])
    let results = await service.search(query: "uni", kinds: [.cryptoToken])
    let hit = try #require(results.first)
    #expect(hit.instrument.kind == .cryptoToken)
    #expect(hit.instrument.chainId == 1)
    #expect(hit.instrument.contractAddress == "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984")
    #expect(hit.instrument.ticker == "UNI")
    #expect(hit.requiresResolution == true)
    #expect(hit.cryptoMapping == nil)
    #expect(hit.isRegistered == false)
  }

  @Test("crypto results for platformless entries fall back to native id")
  func cryptoNativeEntryMaps() async throws {
    let entry = CatalogEntry(
      coingeckoId: "bitcoin",
      symbol: "BTC",
      name: "Bitcoin",
      platforms: []
    )
    let service = makeSubject(catalogEntries: [entry])
    let results = await service.search(query: "btc", kinds: [.cryptoToken])
    let hit = try #require(results.first)
    #expect(hit.instrument.kind == .cryptoToken)
    #expect(hit.instrument.contractAddress == nil)
    #expect(hit.instrument.ticker == "BTC")
    #expect(hit.requiresResolution == true)
  }

  @Test("registered crypto overrides catalog hit and carries mapping")
  func registeredCryptoOverridesCatalogResult() async throws {
    let registeredInstrument = Instrument.crypto(
      chainId: 1,
      contractAddress: "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984",
      symbol: "UNI",
      name: "Uniswap",
      decimals: 18
    )
    let mapping = CryptoProviderMapping(
      instrumentId: registeredInstrument.id,
      coingeckoId: "uniswap",
      cryptocompareSymbol: "UNI",
      binanceSymbol: "UNIUSDT"
    )
    let registration = CryptoRegistration(
      instrument: registeredInstrument, mapping: mapping)
    let entry = CatalogEntry(
      coingeckoId: "uniswap",
      symbol: "UNI",
      name: "Uniswap",
      platforms: [
        PlatformBinding(
          slug: "ethereum",
          chainId: 1,
          contractAddress: "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"
        )
      ]
    )
    let service = makeSubject(
      registered: [registeredInstrument],
      cryptoRegistrations: [registration],
      catalogEntries: [entry]
    )
    let results = await service.search(query: "uni", kinds: [.cryptoToken])
    let matching = results.filter { $0.instrument.id == registeredInstrument.id }
    #expect(matching.count == 1)
    let hit = try #require(matching.first)
    #expect(hit.isRegistered == true)
    #expect(hit.requiresResolution == false)
    #expect(hit.cryptoMapping?.coingeckoId == "uniswap")
  }

  @Test("nil catalog returns no crypto results")
  func nilCatalogYieldsEmptyCrypto() async {
    let registry = StubRegistry()
    let service = InstrumentSearchService(
      registry: registry,
      catalog: nil,
      resolutionClient: StubTokenResolutionClient(),
      stockSearchClient: StubStockSearchClient(),
      stockValidator: StubStockTickerValidator()
    )
    let results = await service.search(query: "btc", kinds: [.cryptoToken])
    #expect(results.isEmpty)
  }

  @Test("stock results loaded from search client with quoteType-derived ids")
  func stockResultsAreLoadedFromSearchClient() async throws {
    let hits = [
      StockSearchHit(
        symbol: "AAPL", name: "Apple Inc.", exchange: "NASDAQ", quoteType: .equity),
      StockSearchHit(
        symbol: "MSFT", name: "Microsoft Corp.", exchange: "NASDAQ", quoteType: .equity),
    ]
    let service = makeSubject(stockHits: hits)
    let results = await service.search(query: "apple", kinds: [.stock])
    let aapl = try #require(results.first { $0.instrument.ticker == "AAPL" })
    #expect(aapl.instrument.id == "NASDAQ:AAPL")
    #expect(aapl.instrument.kind == .stock)
    #expect(aapl.instrument.name == "Apple Inc.")
    #expect(aapl.requiresResolution == true)
    #expect(aapl.isRegistered == false)
  }

  @Test("registered stock overrides Yahoo hit")
  func registeredStockOverridesSearchHit() async throws {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP Group")
    let hit = StockSearchHit(
      symbol: "BHP.AX", name: "BHP Group", exchange: "ASX", quoteType: .equity)
    let service = makeSubject(registered: [bhp], stockHits: [hit])
    let results = await service.search(query: "bhp", kinds: [.stock])
    let matching = results.filter { $0.instrument.id == "ASX:BHP.AX" }
    #expect(matching.count == 1)
    #expect(matching.first?.isRegistered == true)
    #expect(matching.first?.requiresResolution == false)
  }

  @Test("stock search throw is absorbed; other kinds still return")
  func stockSearchThrowAbsorbed() async throws {
    let service = makeSubject(stockSearchThrows: true)
    let results = await service.search(query: "usd")
    #expect(results.contains { $0.instrument.id == "USD" })
  }

  @Test("empty query returns the registered set")
  func emptyQueryReturnsRegistered() async throws {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let service = makeSubject(registered: [bhp])
    let results = await service.search(query: "")
    #expect(results.contains { $0.instrument.id == "ASX:BHP.AX" })
    #expect(results.allSatisfy { $0.isRegistered })
  }

  @Test("registered instruments ranked first")
  func registeredRankFirst() async throws {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let extraHit = StockSearchHit(
      symbol: "BHP.NS", name: "BHP", exchange: "NSE", quoteType: .equity)
    let service = makeSubject(registered: [bhp], stockHits: [extraHit])
    let results = await service.search(query: "BHP", kinds: [.stock])
    let bhpResult = try #require(results.first { $0.instrument.id == "ASX:BHP.AX" })
    #expect(bhpResult.isRegistered == true)
    let registeredIdx = results.firstIndex { $0.instrument.id == "ASX:BHP.AX" } ?? 0
    let providerIdx =
      results.firstIndex { $0.instrument.kind == .stock && !$0.isRegistered } ?? Int.max
    #expect(registeredIdx < providerIdx)
  }
}

// MARK: - Stubs

private struct StubRegistry: InstrumentRegistryRepository, @unchecked Sendable {
  let instruments: [Instrument]
  let cryptoRegistrations: [CryptoRegistration]

  init(instruments: [Instrument] = [], cryptoRegistrations: [CryptoRegistration] = []) {
    self.instruments = instruments
    self.cryptoRegistrations = cryptoRegistrations
  }

  func all() async throws -> [Instrument] { instruments }
  func allCryptoRegistrations() async throws -> [CryptoRegistration] {
    cryptoRegistrations
  }
  func registerCrypto(
    _ instrument: Instrument, mapping: CryptoProviderMapping
  ) async throws {}
  func registerStock(_ instrument: Instrument) async throws {}
  func remove(id: String) async throws {}
  @MainActor
  func observeChanges() -> AsyncStream<Void> { AsyncStream { _ in } }
}

private struct StubCatalog: CoinGeckoCatalog {
  let entries: [CatalogEntry]

  init(entries: [CatalogEntry] = []) { self.entries = entries }

  func search(query: String, limit: Int) async -> [CatalogEntry] {
    Array(entries.prefix(limit))
  }
  func refreshIfStale() async {}
}

private struct StubStockSearchClient: StockSearchClient {
  let hits: [StockSearchHit]
  let shouldThrow: Bool

  init(hits: [StockSearchHit] = [], shouldThrow: Bool = false) {
    self.hits = hits
    self.shouldThrow = shouldThrow
  }

  func search(query: String) async throws -> [StockSearchHit] {
    if shouldThrow { throw URLError(.cannotConnectToHost) }
    return hits
  }
}

private struct StubStockTickerValidator: StockTickerValidator {
  func validate(query: String) async throws -> ValidatedStockTicker? { nil }
}

private struct StubTokenResolutionClient: TokenResolutionClient {
  let resolved: CryptoRegistration?

  init(resolved: CryptoRegistration? = nil) { self.resolved = resolved }

  func resolve(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async throws -> TokenResolutionResult {
    guard let resolved else { return TokenResolutionResult() }
    return TokenResolutionResult(
      coingeckoId: resolved.mapping.coingeckoId,
      cryptocompareSymbol: resolved.mapping.cryptocompareSymbol,
      binanceSymbol: resolved.mapping.binanceSymbol,
      resolvedName: resolved.instrument.name,
      resolvedSymbol: resolved.instrument.ticker,
      resolvedDecimals: resolved.instrument.decimals
    )
  }
}
