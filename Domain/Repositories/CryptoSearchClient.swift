import Foundation

/// A hit from a crypto-token search provider. Does not yet include
/// chain / contract / decimals — callers that want to persist the hit
/// must subsequently resolve those via `TokenResolutionClient`.
struct CryptoSearchHit: Sendable, Hashable {
  let coingeckoId: String
  let symbol: String
  let name: String
  let thumbnail: URL?
}

/// Abstract search service for crypto tokens, typically backed by
/// CoinGecko's `/search` endpoint.
protocol CryptoSearchClient: Sendable {
  func search(query: String) async throws -> [CryptoSearchHit]
}
