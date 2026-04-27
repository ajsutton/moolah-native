import Foundation

/// One coin from the cached CoinGecko catalogue snapshot. Carries every
/// platform binding the picker needs to call `TokenResolutionClient.resolve()`.
struct CatalogEntry: Sendable, Hashable, Identifiable {
  let coingeckoId: String
  let symbol: String
  let name: String
  let platforms: [PlatformBinding]

  var id: String { coingeckoId }

  /// First platform binding by canonical priority — used by the picker to
  /// resolve a search hit to a `(chainId, contractAddress)` pair. `nil`
  /// when the coin is platformless (cross-chain natives like BTC, ETH).
  var preferredPlatform: PlatformBinding? { platforms.first }
}

/// One coin's binding to a single chain. `chainId` is `nil` when the
/// platform slug isn't known to `/asset_platforms` (typically non-EVM).
struct PlatformBinding: Sendable, Hashable {
  let slug: String
  let chainId: Int?
  let contractAddress: String

  init(slug: String, chainId: Int?, contractAddress: String) {
    self.slug = slug
    self.chainId = chainId
    self.contractAddress = contractAddress.lowercased()
  }
}

/// Read-only catalogue of CoinGecko coins. Backed by a refreshable SQLite
/// snapshot of `/coins/list?include_platform=true`. See
/// `plans/2026-04-27-instrument-registry-ui-design.md` §4.1 / §6 for shape.
protocol CoinGeckoCatalog: Sendable {
  /// Returns up to `limit` matching entries with their full platform list
  /// attached, ordered by FTS BM25 rank. Empty when the snapshot is missing
  /// or the query has no hits.
  func search(query: String, limit: Int) async -> [CatalogEntry]

  /// Triggered once per app session. Never blocks the caller; refresh runs
  /// on a background task and logs failures via `os_log`. Honours the 24 h
  /// max-age and ETag conditional-GET semantics described in design §5.4.
  func refreshIfStale() async
}
