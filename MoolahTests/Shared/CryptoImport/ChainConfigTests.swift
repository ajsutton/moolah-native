// MoolahTests/Shared/CryptoImport/ChainConfigTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("ChainConfig")
struct ChainConfigTests {
  @Test
  func ethereumConfigIsCorrect() {
    let config = ChainConfig.ethereum
    #expect(config.chainId == 1)
    #expect(config.alchemyNetworkSlug == "eth-mainnet")
    #expect(config.supportsInternalTransfers == true)
    #expect(config.displayName == "Ethereum")
    #expect(config.blockExplorerBaseURL.absoluteString == "https://etherscan.io")
    #expect(config.nativeInstrument.ticker == "ETH")
    #expect(config.nativeInstrument.chainId == 1)
    #expect(config.nativeInstrument.contractAddress == nil)
    #expect(config.nativeInstrument.decimals == 18)
  }

  @Test
  func optimismConfigIsCorrect() {
    let config = ChainConfig.optimism
    #expect(config.chainId == 10)
    #expect(config.alchemyNetworkSlug == "opt-mainnet")
    #expect(config.supportsInternalTransfers == false)
    #expect(config.displayName == "OP Mainnet")
    #expect(config.blockExplorerBaseURL.absoluteString == "https://optimistic.etherscan.io")
    #expect(config.nativeInstrument.ticker == "ETH")
    #expect(config.nativeInstrument.chainId == 10)
  }

  @Test
  func baseConfigIsCorrect() {
    let config = ChainConfig.base
    #expect(config.chainId == 8453)
    #expect(config.alchemyNetworkSlug == "base-mainnet")
    #expect(config.supportsInternalTransfers == false)
    #expect(config.displayName == "Base")
    #expect(config.blockExplorerBaseURL.absoluteString == "https://basescan.org")
    #expect(config.nativeInstrument.ticker == "ETH")
    #expect(config.nativeInstrument.chainId == 8453)
  }

  @Test
  func polygonConfigIsCorrect() {
    let config = ChainConfig.polygon
    #expect(config.chainId == 137)
    #expect(config.alchemyNetworkSlug == "polygon-mainnet")
    #expect(config.supportsInternalTransfers == true)
    #expect(config.displayName == "Polygon")
    #expect(config.blockExplorerBaseURL.absoluteString == "https://polygonscan.com")
    #expect(config.nativeInstrument.ticker == "MATIC")
    #expect(config.nativeInstrument.chainId == 137)
  }

  @Test
  func allChainsAreUnique() {
    let chainIds = ChainConfig.all.map(\.chainId)
    #expect(Set(chainIds).count == chainIds.count)
    #expect(chainIds == [1, 10, 8453, 137])
  }

  @Test
  func lookupByIdReturnsMatchingConfig() {
    #expect(ChainConfig.config(for: 1) == .ethereum)
    #expect(ChainConfig.config(for: 10) == .optimism)
    #expect(ChainConfig.config(for: 8453) == .base)
    #expect(ChainConfig.config(for: 137) == .polygon)
  }

  @Test
  func lookupByIdReturnsNilForUnsupportedChain() {
    #expect(ChainConfig.config(for: 0) == nil)
    #expect(ChainConfig.config(for: 42_161) == nil)  // Arbitrum, not yet supported
    #expect(ChainConfig.config(for: 999_999) == nil)
  }

  @Test
  func nativeInstrumentsUseCorrectFactoryFormat() {
    // The crypto factory normalises native instruments to "<chainId>:native".
    #expect(ChainConfig.ethereum.nativeInstrument.id == "1:native")
    #expect(ChainConfig.optimism.nativeInstrument.id == "10:native")
    #expect(ChainConfig.base.nativeInstrument.id == "8453:native")
    #expect(ChainConfig.polygon.nativeInstrument.id == "137:native")
  }

  @Test
  func internalTransferSupportMatchesDesignDoc() {
    // Per design open question 3: ETH and Polygon support `internal`,
    // OP and Base do not. This invariant is load-bearing for the
    // request shape Stage 4 builds.
    let supports = Dictionary(
      uniqueKeysWithValues: ChainConfig.all.map { ($0.chainId, $0.supportsInternalTransfers) }
    )
    #expect(supports[1] == true)
    #expect(supports[137] == true)
    #expect(supports[10] == false)
    #expect(supports[8453] == false)
  }
}
