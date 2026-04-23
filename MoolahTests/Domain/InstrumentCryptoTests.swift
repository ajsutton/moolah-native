import Foundation
import Testing

@testable import Moolah

@Suite("Instrument — Crypto")
struct InstrumentCryptoTests {
  // MARK: - Factory

  @Test
  func nativeTokenProperties() {
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

  @Test
  func contractTokenProperties() {
    let optimism = Instrument.crypto(
      chainId: 10,
      contractAddress: "0x4200000000000000000000000000000000000042",
      symbol: "OP", name: "Optimism", decimals: 18
    )
    #expect(optimism.id == "10:0x4200000000000000000000000000000000000042")
    #expect(optimism.kind == .cryptoToken)
    #expect(optimism.name == "Optimism")
    #expect(optimism.chainId == 10)
    #expect(optimism.contractAddress == "0x4200000000000000000000000000000000000042")
  }

  @Test
  func contractAddressNormalizedToLowercase() {
    let ens = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72",
      symbol: "ENS", name: "Ethereum Name Service", decimals: 18
    )
    #expect(ens.id == "1:0xc18360217d8f7ab5e7c516566761ea12ce7f9d72")
    #expect(ens.contractAddress == "0xc18360217d8f7ab5e7c516566761ea12ce7f9d72")
  }

  @Test
  func btcUsesChainIdZero() {
    let btc = Instrument.crypto(
      chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8
    )
    #expect(btc.id == "0:native")
    #expect(btc.decimals == 8)
  }

  @Test
  func cryptoInstrumentIdUsesChainAndAddressScheme() {
    let instrument = Instrument.crypto(
      chainId: 10,
      contractAddress: "0x4200000000000000000000000000000000000042",
      symbol: "OP", name: "Optimism", decimals: 18
    )
    #expect(instrument.id == "10:0x4200000000000000000000000000000000000042")
  }

  @Test
  func equality() {
    let first = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let second = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "Ether", name: "Ether", decimals: 18)
    // Same chain + address = same id, but Instrument equality is based on all fields
    // Since ticker differs ("ETH" vs "Ether"), these are not equal via Hashable default
    // However the id matches, which is the important thing for lookups
    #expect(first.id == second.id)
  }

  @Test
  func codableRoundTrip() throws {
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

  @Test
  func cryptoInstrumentHasNoCurrencySymbol() {
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    #expect(eth.currencySymbol == nil)
  }

  @Test
  func cryptoDisplaySymbolUsesName() {
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    #expect(eth.displaySymbol == "ETH")
  }

  // MARK: - Cross-chain / multi-chain edge cases

  @Test
  func sameSymbolOnDifferentChainsAreDistinctInstruments() {
    // USDC on Ethereum (chainId 1) vs USDC on Polygon (chainId 137) — different ids.
    let ethUsdc = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      symbol: "USDC", name: "USD Coin", decimals: 6
    )
    let polyUsdc = Instrument.crypto(
      chainId: 137,
      contractAddress: "0x2791bca1f2de4661ed88a30c99a7a9449aa84174",
      symbol: "USDC", name: "USD Coin", decimals: 6
    )
    #expect(ethUsdc.id != polyUsdc.id)
    #expect(ethUsdc != polyUsdc)
  }

  @Test
  func nativeAndErc20OnSameChainAreDistinct() {
    // Native ETH on chain 1 vs first ERC20 on chain 1 must be different.
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil,
      symbol: "ETH", name: "Ethereum", decimals: 18
    )
    let weth = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
      symbol: "WETH", name: "Wrapped Ether", decimals: 18
    )
    #expect(eth.id == "1:native")
    #expect(weth.id == "1:0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2")
    #expect(eth != weth)
  }

  @Test
  func optimismChainIdPersistedInInstrumentId() {
    let optimism = Instrument.crypto(
      chainId: 10,
      contractAddress: "0x4200000000000000000000000000000000000042",
      symbol: "OP", name: "Optimism", decimals: 18
    )
    #expect(optimism.id.hasPrefix("10:"))
    #expect(optimism.chainId == 10)
  }

  @Test
  func cryptoDecimalsDifferenceMakesInstrumentsNotEqual() {
    // Two instruments with the same id+address but different stated decimals must still
    // be considered unequal under Hashable/Equatable (all fields matter).
    let first = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
    )
    let second = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 8
    )
    #expect(first != second)
  }
}
