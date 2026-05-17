import Foundation
import os

/// Binds a `CoinstashClient` to a per-account bearer token so the
/// provider-neutral `ExchangeAssetMetadataResolving` seam carries no
/// token. Constructed fresh per build run by `CoinstashSyncSource` via
/// `metadataResolverFactory`, so its lifetime equals one build run.
///
/// `getCoinBySymbol` results are cached for the duration of that build
/// run to avoid N identical network round-trips when N rows share the same
/// symbol. The cache is keyed by uppercased symbol and stores `nil` for
/// definitive unknowns too, so a second call never re-hits the network.
/// Transient errors are NOT cached — a throw leaves no cache entry so the
/// next retry can succeed.
///
/// `Sendable` by design: all access to the mutable cache dictionary is
/// guarded by `OSAllocatedUnfairLock`. The lock is never held across an
/// `await`, so there is no deadlock risk. A benign double-fetch on a true
/// concurrent miss (e.g. two async tasks calling for the same symbol at
/// the same instant before either result is cached) is acceptable because
/// build calls are sequential in practice; correctness > perfect coalescing.
final class CoinstashAssetMetadataResolver: ExchangeAssetMetadataResolving, Sendable {
  private let client: CoinstashClient
  private let token: String
  /// Lock-guarded per-build-run cache. `nil` as a value means "definitively
  /// no usable EVM metadata for this symbol" and is stored so re-calls skip
  /// the network. The key is always uppercased.
  private let cache = OSAllocatedUnfairLock<[String: ExchangeAssetMetadata?]>(
    initialState: [:])

  init(client: CoinstashClient, token: String) {
    self.client = client
    self.token = token
  }

  func assetMetadata(forSymbol symbol: String) async throws -> ExchangeAssetMetadata? {
    let key = symbol.uppercased()
    // Read under lock; release before any await.
    if let cached = cache.withLock({ $0[key] }) {
      return cached
    }
    // Check whether the key itself is present (covers cached nil).
    let hasEntry = cache.withLock { $0.keys.contains(key) }
    if hasEntry {
      return nil
    }
    // Cache miss: fetch from network (lock NOT held across await).
    let result = try await client.coinMetadata(symbol: symbol, token: token)
    // Store on success (including definitive nil); do not cache on throw.
    cache.withLock { $0[key] = result }
    return result
  }
}
