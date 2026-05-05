// Shared/NoOpTokenResolutionClient.swift

import Foundation

/// Fallback `TokenResolutionClient` used by `CryptoPriceService` when no
/// resolution client is configured. Returns empty results so the service
/// can still resolve registrations for tokens that don't need a
/// provider-side mapping (e.g. user-entered free-text symbols).
struct NoOpTokenResolutionClient: TokenResolutionClient {
  func resolve(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async throws -> TokenResolutionResult {
    TokenResolutionResult()
  }
}
