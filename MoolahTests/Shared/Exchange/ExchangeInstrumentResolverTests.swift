import Testing

@testable import Moolah

@Suite("ExchangeInstrumentResolver")
struct ExchangeInstrumentResolverTests {
  private let optimism = Instrument.crypto(
    chainId: 10, contractAddress: "0x4200000000000000000000000000000000000042",
    symbol: "OP", name: "Optimism", decimals: 18)

  @Test
  func fiatResolvesToInjectedFiatInstrument() async throws {
    let resolver = ExchangeInstrumentResolver(
      registry: StubInstrumentRegistry(), fiatInstrument: .AUD)
    #expect(try await resolver.instrument(forSymbol: nil, isFiat: true) == .AUD)
  }

  @Test
  func assetResolvesViaRegistry() async throws {
    let resolver = ExchangeInstrumentResolver(
      registry: StubInstrumentRegistry(instruments: [optimism]), fiatInstrument: .AUD)
    #expect(try await resolver.instrument(forSymbol: "OP", isFiat: false) == optimism)
  }

  @Test
  func unknownAssetReturnsNil() async throws {
    let resolver = ExchangeInstrumentResolver(
      registry: StubInstrumentRegistry(), fiatInstrument: .AUD)
    #expect(try await resolver.instrument(forSymbol: "ZZZ", isFiat: false) == nil)
  }
}
