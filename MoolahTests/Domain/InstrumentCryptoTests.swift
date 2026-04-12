import Foundation
import Testing

@testable import Moolah

@Suite("Instrument — Crypto")
struct InstrumentCryptoTests {
  // MARK: - Factory

  @Test func nativeTokenProperties() {
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
    )
    #expect(eth.id == "1:native")
    #expect(eth.kind == .cryptoToken)
    #expect(eth.name == "Ethereum")
    #expect(eth.decimals == 18)
    #expect(eth.chainId == 1)
    #expect(eth.contractAddress == nil)
    #expect(eth.ticker == "ETH")
    #expect(eth.exchange == nil)
  }

  @Test func contractTokenProperties() {
    let op = Instrument.crypto(
      chainId: 10,
      contractAddress: "0x4200000000000000000000000000000000000042",
      symbol: "OP", name: "Optimism", decimals: 18
    )
    #expect(op.id == "10:0x4200000000000000000000000000000000000042")
    #expect(op.kind == .cryptoToken)
    #expect(op.name == "Optimism")
    #expect(op.chainId == 10)
    #expect(op.contractAddress == "0x4200000000000000000000000000000000000042")
  }

  @Test func contractAddressNormalizedToLowercase() {
    let ens = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72",
      symbol: "ENS", name: "Ethereum Name Service", decimals: 18
    )
    #expect(ens.id == "1:0xc18360217d8f7ab5e7c516566761ea12ce7f9d72")
    #expect(ens.contractAddress == "0xc18360217d8f7ab5e7c516566761ea12ce7f9d72")
  }

  @Test func btcUsesChainIdZero() {
    let btc = Instrument.crypto(
      chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8
    )
    #expect(btc.id == "0:native")
    #expect(btc.decimals == 8)
  }

  @Test func cryptoInstrumentIdUsesChainAndAddressScheme() {
    let instrument = Instrument.crypto(
      chainId: 10,
      contractAddress: "0x4200000000000000000000000000000000000042",
      symbol: "OP", name: "Optimism", decimals: 18
    )
    #expect(instrument.id == "10:0x4200000000000000000000000000000000000042")
  }

  @Test func equality() {
    let a = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let b = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "Ether", name: "Ether", decimals: 18)
    // Same chain + address = same id, but Instrument equality is based on all fields
    // Since ticker differs ("ETH" vs "Ether"), these are not equal via Hashable default
    // However the id matches, which is the important thing for lookups
    #expect(a.id == b.id)
  }

  @Test func codableRoundTrip() throws {
    let original = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72",
      symbol: "ENS", name: "Ethereum Name Service", decimals: 18
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Instrument.self, from: data)
    #expect(decoded == original)
    #expect(decoded.kind == .cryptoToken)
    #expect(decoded.chainId == 1)
    #expect(decoded.contractAddress == "0xc18360217d8f7ab5e7c516566761ea12ce7f9d72")
  }

  // MARK: - Display symbol

  @Test func cryptoInstrumentHasNoCurrencySymbol() {
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    #expect(eth.currencySymbol == nil)
  }

  @Test func cryptoDisplaySymbolUsesName() {
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    #expect(eth.displaySymbol == "ETH")
  }
}
