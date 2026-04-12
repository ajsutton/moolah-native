import Foundation
import Testing

@testable import Moolah

@Suite("CryptoProviderMapping")
struct CryptoProviderMappingTests {
  @Test func initStoresAllFields() {
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

  @Test func nilProviderFieldsAllowed() {
    let mapping = CryptoProviderMapping(
      instrumentId: "1:native",
      coingeckoId: nil,
      cryptocompareSymbol: nil,
      binanceSymbol: nil
    )
    #expect(mapping.coingeckoId == nil)
  }

  @Test func codableRoundTrip() throws {
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

  @Test func identityBasedOnInstrumentId() {
    let a = CryptoProviderMapping(
      instrumentId: "1:native", coingeckoId: "ethereum",
      cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
    )
    let b = CryptoProviderMapping(
      instrumentId: "1:native", coingeckoId: "eth-changed",
      cryptocompareSymbol: nil, binanceSymbol: nil
    )
    #expect(a.id == b.id)
  }

  // MARK: - Conversion from legacy CryptoToken

  @Test func fromCryptoTokenPreservesProviderIds() {
    let token = CryptoToken(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum",
      decimals: 18, coingeckoId: "ethereum", cryptocompareSymbol: "ETH",
      binanceSymbol: "ETHUSDT"
    )
    let mapping = CryptoProviderMapping.from(token)
    #expect(mapping.instrumentId == "1:native")
    #expect(mapping.coingeckoId == "ethereum")
    #expect(mapping.cryptocompareSymbol == "ETH")
    #expect(mapping.binanceSymbol == "ETHUSDT")
  }

  @Test func fromCryptoTokenWithContractAddress() {
    let token = CryptoToken(
      chainId: 10,
      contractAddress: "0x4200000000000000000000000000000000000042",
      symbol: "OP", name: "Optimism", decimals: 18,
      coingeckoId: "optimism", cryptocompareSymbol: "OP",
      binanceSymbol: "OPUSDT"
    )
    let mapping = CryptoProviderMapping.from(token)
    #expect(mapping.instrumentId == "10:0x4200000000000000000000000000000000000042")
  }

  // MARK: - Built-in presets

  @Test func builtInPresetsMatchCryptoTokenPresets() {
    let presets = CryptoProviderMapping.builtInPresets
    #expect(presets.count == 5)

    let btc = presets.first { $0.instrumentId == "0:native" }!
    #expect(btc.coingeckoId == "bitcoin")
    #expect(btc.cryptocompareSymbol == "BTC")
    #expect(btc.binanceSymbol == "BTCUSDT")
  }
}
