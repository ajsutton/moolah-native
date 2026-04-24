import Foundation
import Testing

@testable import Moolah

@Suite("InstrumentSearchService")
@MainActor
struct InstrumentSearchServiceTests {
  @MainActor
  func makeSubject(
    registered: [Instrument] = [],
    cryptoHits: [CryptoSearchHit] = [],
    cryptoSearchThrows: Bool = false,
    stockValidated: ValidatedStockTicker? = nil,
    stockValidatorThrows: Bool = false,
    resolvedRegistration: CryptoRegistration? = nil
  ) -> InstrumentSearchService {
    let registry = StubRegistry(instruments: registered)
    let crypto = StubCryptoSearchClient(hits: cryptoHits, shouldThrow: cryptoSearchThrows)
    let stock = StubStockTickerValidator(
      validated: stockValidated, shouldThrow: stockValidatorThrows)
    let resolver = StubTokenResolutionClient(resolved: resolvedRegistration)
    return InstrumentSearchService(
      registry: registry,
      cryptoSearchClient: crypto,
      resolutionClient: resolver,
      stockValidator: stock
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
    // At minimum USD and AUD should surface; asserting "at least one" keeps
    // the test robust against locale variation.
    let ids = results.map(\.instrument.id)
    #expect(ids.contains("USD") || ids.contains("AUD"))
  }

  @Test("crypto hits marked requiresResolution = true with populated coingeckoId")
  func cryptoHitsMarkedForResolution() async throws {
    let hits = [
      CryptoSearchHit(
        coingeckoId: "bitcoin", symbol: "BTC", name: "Bitcoin", thumbnail: nil),
      CryptoSearchHit(
        coingeckoId: "ethereum", symbol: "ETH", name: "Ethereum", thumbnail: nil),
    ]
    let service = makeSubject(cryptoHits: hits)
    let results = await service.search(query: "bitcoin", kinds: [.cryptoToken])
    #expect(results.contains { $0.instrument.ticker == "BTC" && $0.requiresResolution })
    #expect(
      results.contains {
        $0.cryptoMapping?.coingeckoId == "bitcoin"
      }
    )
  }

  @Test("crypto query matching contract-address pattern bypasses search and calls resolver")
  func contractAddressBypassesSearch() async throws {
    let eth = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xdac17f958d2ee523a2206206994597c13d831ec7",
      symbol: "USDT", name: "Tether", decimals: 6)
    let mapping = CryptoProviderMapping(
      instrumentId: eth.id,
      coingeckoId: "tether",
      cryptocompareSymbol: "USDT",
      binanceSymbol: "USDTUSDT")
    let service = makeSubject(
      cryptoHits: [],  // would cause the test to fail if the search path was used
      resolvedRegistration: CryptoRegistration(instrument: eth, mapping: mapping)
    )
    let results = await service.search(
      query: "0xdAC17F958D2ee523a2206206994597C13D831ec7", kinds: [.cryptoToken])
    #expect(results.count == 1)
    #expect(results.first?.requiresResolution == false)
    #expect(results.first?.cryptoMapping?.cryptocompareSymbol == "USDT")
  }

  @Test("valid typed stock ticker yields one result")
  func stockValidTypedTicker() async throws {
    let validated = ValidatedStockTicker(ticker: "BHP.AX", exchange: "ASX")
    let service = makeSubject(stockValidated: validated)
    let results = await service.search(query: "BHP.AX", kinds: [.stock])
    #expect(results.count == 1)
    #expect(results.first?.instrument.id == "ASX:BHP.AX")
    #expect(results.first?.requiresResolution == false)
  }

  @Test("invalid stock ticker yields no stock results")
  func stockInvalidTicker() async throws {
    let service = makeSubject(stockValidated: nil)
    let results = await service.search(query: "UNKNOWN", kinds: [.stock])
    #expect(results.isEmpty)
  }

  @Test("stock validator throw is absorbed; other kinds still return")
  func stockValidatorThrowAbsorbed() async throws {
    let service = makeSubject(stockValidatorThrows: true)
    let results = await service.search(query: "usd")
    // Fiat results still surface.
    #expect(results.contains { $0.instrument.id == "USD" })
  }

  @Test("registered instruments marked isRegistered = true and ranked first")
  func registeredRankFirst() async throws {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let service = makeSubject(registered: [bhp])
    let results = await service.search(query: "BHP", kinds: [.stock])
    let bhpResult = try #require(results.first { $0.instrument.id == "ASX:BHP.AX" })
    #expect(bhpResult.isRegistered == true)
    // It appears before any non-registered stock result.
    let idx = results.firstIndex { $0.instrument.id == "ASX:BHP.AX" } ?? 0
    let otherStockIdx =
      results.firstIndex {
        $0.instrument.kind == .stock && !$0.isRegistered
      } ?? Int.max
    #expect(idx < otherStockIdx)
  }

  @Test("provider hit sharing an id with a registered entry is dropped")
  func dedupePreferRegistered() async throws {
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH",
      name: "Ethereum", decimals: 18)
    // registered ETH exists; crypto search hit also claims ETH (same id).
    let hit = CryptoSearchHit(
      coingeckoId: "ethereum", symbol: "ETH", name: "Ethereum", thumbnail: nil)
    let service = makeSubject(registered: [eth], cryptoHits: [hit])
    let results = await service.search(query: "ETH", kinds: [.cryptoToken])
    let matching = results.filter { $0.instrument.id == eth.id }
    #expect(matching.count == 1)
    #expect(matching.first?.isRegistered == true)
  }

  @Test("empty query returns the registered set")
  func emptyQueryReturnsRegistered() async throws {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let service = makeSubject(registered: [bhp])
    let results = await service.search(query: "")
    #expect(results.contains { $0.instrument.id == "ASX:BHP.AX" })
    #expect(results.allSatisfy { $0.isRegistered })
  }
}

// MARK: - Stubs

private struct StubRegistry: InstrumentRegistryRepository, @unchecked Sendable {
  let instruments: [Instrument]

  func all() async throws -> [Instrument] { instruments }
  func allCryptoRegistrations() async throws -> [CryptoRegistration] { [] }
  func registerCrypto(
    _ instrument: Instrument, mapping: CryptoProviderMapping
  ) async throws {}
  func registerStock(_ instrument: Instrument) async throws {}
  func remove(id: String) async throws {}
  @MainActor
  func observeChanges() -> AsyncStream<Void> { AsyncStream { _ in } }
}

private struct StubCryptoSearchClient: CryptoSearchClient {
  let hits: [CryptoSearchHit]
  let shouldThrow: Bool

  func search(query: String) async throws -> [CryptoSearchHit] {
    if shouldThrow { throw URLError(.cannotConnectToHost) }
    return hits
  }
}

private struct StubStockTickerValidator: StockTickerValidator {
  let validated: ValidatedStockTicker?
  let shouldThrow: Bool

  func validate(query: String) async throws -> ValidatedStockTicker? {
    if shouldThrow { throw URLError(.cannotConnectToHost) }
    return validated
  }
}

private struct StubTokenResolutionClient: TokenResolutionClient {
  let resolved: CryptoRegistration?

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
