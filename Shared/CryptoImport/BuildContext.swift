// Shared/CryptoImport/BuildContext.swift
import Foundation

/// Per-call context bundle giving `TransferEventBuilder`'s helpers the
/// account, chain, discovery actor, and import audit fields. Built once
/// in `build(...)` and passed by value down the call tree.
struct BuildContext: Sendable {
  let account: Account
  let walletAddress: String
  let chain: ChainConfig
  let discovery: CryptoTokenDiscoveryService
  let importOrigin: ImportOrigin
}

/// Result of mapping a transfer's direction onto a leg's sign + the
/// other-party address.
struct SignAndCounterparty {
  let signedQuantity: Decimal
  let counterpartyAddress: String?
}
