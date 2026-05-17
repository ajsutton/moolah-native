import Foundation

/// One chain on which a provider lists a token. `contractAddress == nil`
/// means the chain's native asset (the provider's native-token sentinel
/// has already been collapsed by the mapping layer).
struct ExchangeAssetChain: Sendable, Hashable {
  let chainId: Int
  let contractAddress: String?
  let decimals: Int
}

/// Provider-neutral token metadata. `chains` is restricted to
/// EVM chains with a known chain id, in the provider's own listing order.
struct ExchangeAssetMetadata: Sendable, Hashable {
  let symbol: String
  let name: String
  let chains: [ExchangeAssetChain]
}

/// Resolves an exchange asset symbol to neutral token metadata.
///
/// Returns `nil` for a *definitive* "no usable EVM metadata" answer
/// (symbol unknown to the provider, or it lists the token only on
/// non-EVM chains). Throws for *transient* failures (network / provider
/// error) so the caller's sync retries instead of mis-resolving.
protocol ExchangeAssetMetadataResolving: Sendable {
  func assetMetadata(forSymbol symbol: String) async throws -> ExchangeAssetMetadata?
}
