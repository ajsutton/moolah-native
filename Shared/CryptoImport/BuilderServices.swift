// Shared/CryptoImport/BuilderServices.swift
import Foundation

/// Shared per-sync-cycle services the builder needs — the chain,
/// the token-discovery actor, and the Alchemy client used for both
/// transfer fetches and per-hash receipt lookups. Bundled into a
/// single value so the public `build(...)` entry point stays inside
/// SwiftLint's parameter-count budget without sacrificing call-site
/// clarity.
///
/// Lives in its own file so `TransferEventBuilder.swift` stays under
/// SwiftLint's `file_length` budget after the merge of
/// `SignAndCounterparty` (issue #754) and `BuilderServices` (issue #762).
struct BuilderServices: Sendable {
  let chain: ChainConfig
  let discovery: CryptoTokenDiscoveryService
  let alchemy: any AlchemyClient
}
