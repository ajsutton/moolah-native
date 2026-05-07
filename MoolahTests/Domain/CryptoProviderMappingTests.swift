import Foundation
import Testing

@testable import Moolah

@Suite("CryptoProviderMapping")
struct CryptoProviderMappingTests {
  @Test
  func initStoresAllFields() {
    let mapping = CryptoProviderMapping(
      instrumentId: "1:native",
      coingeckoId: "ethereum",
      cryptocompareSymbol: "ETH",
      binanceSymbol: "ETHUSDT"
    )
    #expect(mapping.instrumentId == "1:native")
    #expect(mapping.coingeckoId == "ethereum")
    #expect(mapping.cryptocompareSymbol == "ETH")
    #expect(mapping.binanceSymbol == "ETHUSDT")
  }

  @Test
  func nilProviderFieldsAllowed() {
    let mapping = CryptoProviderMapping(
      instrumentId: "1:native",
      coingeckoId: nil,
      cryptocompareSymbol: nil,
      binanceSymbol: nil
    )
    #expect(mapping.coingeckoId == nil)
  }

  @Test
  func codableRoundTrip() throws {
    let original = CryptoProviderMapping(
      instrumentId: "10:0x4200000000000000000000000000000000000042",
      coingeckoId: "optimism",
      cryptocompareSymbol: "OP",
      binanceSymbol: "OPUSDT"
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(CryptoProviderMapping.self, from: data)
    #expect(decoded == original)
  }

  @Test
  func identityBasedOnInstrumentId() {
    let first = CryptoProviderMapping(
      instrumentId: "1:native", coingeckoId: "ethereum",
      cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
    )
    let second = CryptoProviderMapping(
      instrumentId: "1:native", coingeckoId: "eth-changed",
      cryptocompareSymbol: nil, binanceSymbol: nil
    )
    #expect(first.id == second.id)
  }

  // MARK: - Built-in presets

  @Test
  func builtInPresetsContainExpectedTokens() throws {
    let presets = CryptoProviderMapping.builtInPresets

    let btc = try #require(presets.first { $0.instrumentId == "0:native" })
    #expect(btc.coingeckoId == "bitcoin")
    #expect(btc.cryptocompareSymbol == "BTC")
    #expect(btc.binanceSymbol == "BTCUSDT")

    // Every chain native gas instrument carries a real provider
    // mapping so transaction detail / running-balance / aggregation
    // resolves them from session start (issue #791).
    for id in ["1:native", "10:native", "137:native", "8453:native"] {
      let preset = try #require(presets.first { $0.instrumentId == id })
      #expect(preset.cryptocompareSymbol != nil, "missing CC mapping for \(id)")
      #expect(preset.binanceSymbol != nil, "missing Binance mapping for \(id)")
    }
  }
}
