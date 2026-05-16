// MoolahTests/Shared/CryptoImport/BlockExplorerLinkTests.swift
import Foundation
import Testing

@testable import Moolah

/// URL-builder contract tests for `BlockExplorerLink`. Asserts the exact
/// canonical form per chain (Etherscan / Optimistic Etherscan / BaseScan)
/// and the `nil` defensive return for unsupported chains. Polygon (chain 137)
/// is unsupported — it has no first-party public Blockscout instance.
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

  @Test("Polygon (chain 137) transaction URL is nil — no public Blockscout instance")
  func polygonTransactionURLIsNil() {
    let url = BlockExplorerLink.transactionURL(chainId: 137, hash: Self.txHash)
    #expect(url == nil)
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

  @Test("Polygon (chain 137) address URL is nil — no public Blockscout instance")
  func polygonAddressURLIsNil() {
    let url = BlockExplorerLink.addressURL(chainId: 137, address: Self.address)
    #expect(url == nil)
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

  // MARK: - transactionURL(chainId:externalId:)

  /// Wallet-importer transfer legs persist `externalId` in Alchemy's
  /// `uniqueId` form `<hash>:<category>:<index>` so a multi-event
  /// transaction can produce multiple legs without tripping the
  /// schema's partial unique index. The transaction-detail "View on
  /// block explorer" link must strip the `:<suffix>` to recover the
  /// bare hash — passing the full `externalId` to the explorer
  /// produced a 404 (issue #848).
  @Test("strips Alchemy transfer-leg uniqueId suffix to recover bare hash")
  func stripsTransferLegUniqueIdSuffix() {
    let externalId = "\(Self.txHash):external:0"
    let url = BlockExplorerLink.transactionURL(chainId: 1, externalId: externalId)
    #expect(url?.absoluteString == "https://etherscan.io/tx/\(Self.txHash)")
  }

  /// `TransferReceiptCoalescer` tags the gas leg `<hash>:gas` so it
  /// shares the `(accountId, externalId)` namespace with the transfer
  /// legs. The strip rule must cover this form too.
  @Test("strips gas-leg :gas suffix to recover bare hash")
  func stripsGasLegSuffix() {
    let externalId = "\(Self.txHash):gas"
    let url = BlockExplorerLink.transactionURL(chainId: 1, externalId: externalId)
    #expect(url?.absoluteString == "https://etherscan.io/tx/\(Self.txHash)")
  }

  /// A bare hash (no colon) is valid input — the wallet importer is
  /// the only producer of the `<hash>:<suffix>` form today, but
  /// callers passing the bare hash should get the correct URL too.
  @Test("accepts a bare hash with no suffix")
  func acceptsBareHash() {
    let url = BlockExplorerLink.transactionURL(chainId: 1, externalId: Self.txHash)
    #expect(url?.absoluteString == "https://etherscan.io/tx/\(Self.txHash)")
  }

  /// An empty externalId — or one whose hash portion is empty
  /// (`":gas"`) — has nothing to link to. Return `nil` so the caller
  /// can omit the row rather than building a malformed URL.
  @Test("returns nil for empty externalId / empty hash before colon")
  func returnsNilForEmptyHash() {
    #expect(BlockExplorerLink.transactionURL(chainId: 1, externalId: "") == nil)
    #expect(BlockExplorerLink.transactionURL(chainId: 1, externalId: ":gas") == nil)
  }

  /// Unsupported chains continue to return `nil` even when the
  /// externalId is well-formed — the chain-config gate happens after
  /// the suffix strip.
  @Test("returns nil for unsupported chain even with well-formed externalId")
  func returnsNilForUnsupportedChain() {
    #expect(
      BlockExplorerLink.transactionURL(chainId: 42_161, externalId: "\(Self.txHash):external:0")
        == nil)
  }
}
