// Shared/CryptoImport/BlockExplorerLink.swift
import Foundation

/// Per-chain block-explorer URL builder. Maps a chain ID + on-chain hash
/// or address to the canonical explorer URL for that chain.
///
/// Returns `nil` if the chain id is unknown — callers (the wallet account
/// header, the per-leg link in the transaction detail) can omit the link
/// rather than crashing on a future chain that ships before its
/// `ChainConfig` entry. Adding a new chain to `ChainConfig.all` is the
/// only change required for both `transactionURL` and `addressURL` to
/// pick it up.
///
/// Foundation-only by design: this lives next to `ChainConfig` in
/// `Shared/CryptoImport` and is intentionally usable from any layer
/// (Domain, Features) without dragging in SwiftUI.
enum BlockExplorerLink {
  /// Canonical transaction URL for the given chain — e.g.
  /// `https://etherscan.io/tx/<hash>`,
  /// `https://optimistic.etherscan.io/tx/<hash>`,
  /// `https://basescan.org/tx/<hash>`,
  /// `https://polygonscan.com/tx/<hash>`.
  ///
  /// `hash` is the lowercased on-chain transaction hash recorded as
  /// `TransactionLeg.externalId` at import time.
  static func transactionURL(chainId: Int, hash: String) -> URL? {
    guard let chain = ChainConfig.config(for: chainId) else { return nil }
    return chain.blockExplorerBaseURL
      .appendingPathComponent("tx", isDirectory: false)
      .appendingPathComponent(hash, isDirectory: false)
  }

  /// Canonical address URL for the given chain — e.g.
  /// `https://etherscan.io/address/<addr>`. Used by the wallet-account
  /// header's "View on block explorer" overflow menu item.
  static func addressURL(chainId: Int, address: String) -> URL? {
    guard let chain = ChainConfig.config(for: chainId) else { return nil }
    return chain.blockExplorerBaseURL
      .appendingPathComponent("address", isDirectory: false)
      .appendingPathComponent(address, isDirectory: false)
  }

  /// Convenience for the per-leg "View on block explorer" link in the
  /// transaction detail. Wallet-importer legs persist `externalId` in
  /// Alchemy's `uniqueId` form `<hash>:<category>:<index>` (transfer
  /// legs) or `<hash>:gas` (gas legs) — the suffix scopes the
  /// `(accountId, externalId)` namespace so a multi-event transaction
  /// can persist multiple legs from one on-chain hash. The explorer
  /// expects the bare hash, so this method strips the first `:` and
  /// everything after before forwarding to
  /// `transactionURL(chainId:hash:)`. A bare hash (no `:`) is accepted
  /// unchanged for non-importer call sites. An empty hash portion
  /// returns `nil`. See issue #848.
  static func transactionURL(chainId: Int, externalId: String) -> URL? {
    let parts = externalId.split(
      separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard let first = parts.first, !first.isEmpty else { return nil }
    return transactionURL(chainId: chainId, hash: String(first))
  }
}
