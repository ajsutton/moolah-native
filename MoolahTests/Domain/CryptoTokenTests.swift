// MoolahTests/Domain/CryptoTokenTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("CryptoToken")
struct CryptoTokenTests {
  // MARK: - Identity

  @Test func nativeTokenIdUsesChainIdAndNative() {
    let eth = CryptoToken(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum",
      decimals: 18, coingeckoId: "ethereum", cryptocompareSymbol: "ETH",
      binanceSymbol: "ETHUSDT"
    )
    #expect(eth.id == "1:native")
  }

  @Test func contractTokenIdUsesChainIdAndLowercasedAddress() {
    let op = CryptoToken(
      chainId: 10,
      contractAddress: "0x4200000000000000000000000000000000000042",
      symbol: "OP", name: "Optimism", decimals: 18,
      coingeckoId: "optimism", cryptocompareSymbol: "OP",
      binanceSymbol: "OPUSDT"
    )
    #expect(op.id == "10:0x4200000000000000000000000000000000000042")
  }

  @Test func contractAddressIsNormalizedToLowercase() {
    let token = CryptoToken(
      chainId: 1,
      contractAddress: "0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72",
      symbol: "ENS", name: "Ethereum Name Service", decimals: 18,
      coingeckoId: nil, cryptocompareSymbol: nil, binanceSymbol: nil
    )
    #expect(token.id == "1:0xc18360217d8f7ab5e7c516566761ea12ce7f9d72")
  }

  // MARK: - Equality based on identity

  @Test func tokensWithSameChainAndAddressAreEqual() {
    let a = CryptoToken(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum",
      decimals: 18, coingeckoId: "ethereum", cryptocompareSymbol: "ETH",
      binanceSymbol: "ETHUSDT"
    )
    let b = CryptoToken(
      chainId: 1, contractAddress: nil, symbol: "Ether", name: "Ether",
      decimals: 18, coingeckoId: nil, cryptocompareSymbol: nil,
      binanceSymbol: nil
    )
    #expect(a == b)
  }

  @Test func tokensOnDifferentChainsAreNotEqual() {
    let ethMainnet = CryptoToken(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum",
      decimals: 18, coingeckoId: nil, cryptocompareSymbol: nil, binanceSymbol: nil
    )
    let ethOptimism = CryptoToken(
      chainId: 10, contractAddress: nil, symbol: "ETH", name: "Ethereum",
      decimals: 18, coingeckoId: nil, cryptocompareSymbol: nil, binanceSymbol: nil
    )
    #expect(ethMainnet != ethOptimism)
  }

  // MARK: - Codable round-trip

  @Test func codableRoundTrip() throws {
    let token = CryptoToken(
      chainId: 10,
      contractAddress: "0x4200000000000000000000000000000000000042",
      symbol: "OP", name: "Optimism", decimals: 18,
      coingeckoId: "optimism", cryptocompareSymbol: "OP",
      binanceSymbol: "OPUSDT"
    )
    let data = try JSONEncoder().encode(token)
    let decoded = try JSONDecoder().decode(CryptoToken.self, from: data)
    #expect(decoded == token)
    #expect(decoded.coingeckoId == "optimism")
    #expect(decoded.cryptocompareSymbol == "OP")
    #expect(decoded.binanceSymbol == "OPUSDT")
  }

  @Test func codableWithNilProviderFields() throws {
    let token = CryptoToken(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum",
      decimals: 18, coingeckoId: nil, cryptocompareSymbol: nil, binanceSymbol: nil
    )
    let data = try JSONEncoder().encode(token)
    let decoded = try JSONDecoder().decode(CryptoToken.self, from: data)
    #expect(decoded == token)
    #expect(decoded.coingeckoId == nil)
  }

  // MARK: - Built-in presets

  @Test func builtInPresetsContainExpectedTokens() {
    let presets = CryptoToken.builtInPresets
    #expect(presets.count == 5)

    let symbols = Set(presets.map(\.symbol))
    #expect(symbols == ["BTC", "ETH", "OP", "UNI", "ENS"])
  }

  @Test func btcPresetUsesChainIdZero() {
    let btc = CryptoToken.builtInPresets.first { $0.symbol == "BTC" }!
    #expect(btc.chainId == 0)
    #expect(btc.contractAddress == nil)
    #expect(btc.id == "0:native")
    #expect(btc.coingeckoId == "bitcoin")
  }

  @Test func opPresetUsesCorrectContractAddress() {
    let op = CryptoToken.builtInPresets.first { $0.symbol == "OP" }!
    #expect(op.chainId == 10)
    #expect(op.contractAddress == "0x4200000000000000000000000000000000000042")
    #expect(op.coingeckoId == "optimism")
  }
}
