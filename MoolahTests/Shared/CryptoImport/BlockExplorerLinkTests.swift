// MoolahTests/Shared/CryptoImport/BlockExplorerLinkTests.swift
import Foundation
import Testing

@testable import Moolah

/// URL-builder contract tests for `BlockExplorerLink`. Asserts the exact
/// canonical form per chain (Etherscan / Optimistic Etherscan / BaseScan
/// / PolygonScan) and the `nil` defensive return for unsupported chains.
@Suite("BlockExplorerLink")
struct BlockExplorerLinkTests {
  /// 32-byte tx hash (64 hex chars + `0x` prefix). Reused so the
  /// assertion stays anchored on the URL shape rather than literals.
  private static let txHash =
    "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
  private static let address = "0x1234567890abcdef1234567890abcdef12345678"

  // MARK: - transactionURL

  @Test("Ethereum transaction URL points at etherscan.io/tx/<hash>")
  func ethereumTransactionURL() {
    let url = BlockExplorerLink.transactionURL(chainId: 1, hash: Self.txHash)
    #expect(url?.absoluteString == "https://etherscan.io/tx/\(Self.txHash)")
  }

  @Test("OP Mainnet transaction URL points at optimistic.etherscan.io/tx/<hash>")
  func optimismTransactionURL() {
    let url = BlockExplorerLink.transactionURL(chainId: 10, hash: Self.txHash)
    #expect(url?.absoluteString == "https://optimistic.etherscan.io/tx/\(Self.txHash)")
  }

  @Test("Base transaction URL points at basescan.org/tx/<hash>")
  func baseTransactionURL() {
    let url = BlockExplorerLink.transactionURL(chainId: 8453, hash: Self.txHash)
    #expect(url?.absoluteString == "https://basescan.org/tx/\(Self.txHash)")
  }

  @Test("Polygon transaction URL points at polygonscan.com/tx/<hash>")
  func polygonTransactionURL() {
    let url = BlockExplorerLink.transactionURL(chainId: 137, hash: Self.txHash)
    #expect(url?.absoluteString == "https://polygonscan.com/tx/\(Self.txHash)")
  }

  @Test("Unknown chain id returns nil for transactionURL")
  func unknownChainTransactionURLIsNil() {
    #expect(BlockExplorerLink.transactionURL(chainId: 0, hash: Self.txHash) == nil)
    #expect(BlockExplorerLink.transactionURL(chainId: 42_161, hash: Self.txHash) == nil)
    #expect(BlockExplorerLink.transactionURL(chainId: 999_999, hash: Self.txHash) == nil)
  }

  // MARK: - addressURL

  @Test("Ethereum address URL points at etherscan.io/address/<addr>")
  func ethereumAddressURL() {
    let url = BlockExplorerLink.addressURL(chainId: 1, address: Self.address)
    #expect(url?.absoluteString == "https://etherscan.io/address/\(Self.address)")
  }

  @Test("OP Mainnet address URL points at optimistic.etherscan.io/address/<addr>")
  func optimismAddressURL() {
    let url = BlockExplorerLink.addressURL(chainId: 10, address: Self.address)
    #expect(url?.absoluteString == "https://optimistic.etherscan.io/address/\(Self.address)")
  }

  @Test("Base address URL points at basescan.org/address/<addr>")
  func baseAddressURL() {
    let url = BlockExplorerLink.addressURL(chainId: 8453, address: Self.address)
    #expect(url?.absoluteString == "https://basescan.org/address/\(Self.address)")
  }

  @Test("Polygon address URL points at polygonscan.com/address/<addr>")
  func polygonAddressURL() {
    let url = BlockExplorerLink.addressURL(chainId: 137, address: Self.address)
    #expect(url?.absoluteString == "https://polygonscan.com/address/\(Self.address)")
  }

  @Test("Unknown chain id returns nil for addressURL")
  func unknownChainAddressURLIsNil() {
    #expect(BlockExplorerLink.addressURL(chainId: 0, address: Self.address) == nil)
    #expect(BlockExplorerLink.addressURL(chainId: 42_161, address: Self.address) == nil)
  }

  // MARK: - URL well-formedness

  @Test("Generated URLs have exactly one slash between segments (no doubles)")
  func urlsAreWellFormed() {
    // Smoke test against every supported chain — the appendingPathComponent
    // contract guarantees this, but the test pins it so a future
    // refactor that switches to string concatenation can't silently
    // regress double-slash handling.
    for chain in ChainConfig.all {
      let txURL = BlockExplorerLink.transactionURL(chainId: chain.chainId, hash: Self.txHash)
      let addressURL = BlockExplorerLink.addressURL(
        chainId: chain.chainId, address: Self.address)
      #expect(txURL?.absoluteString.contains("//tx/") == false)
      #expect(addressURL?.absoluteString.contains("//address/") == false)
      // The `https://` prefix is the only legitimate `//` in the URL.
      #expect((txURL?.absoluteString.components(separatedBy: "//").count ?? 0) == 2)
      #expect((addressURL?.absoluteString.components(separatedBy: "//").count ?? 0) == 2)
    }
  }
}
