import Foundation

/// Structured outcome of a failed wallet sync cycle. Stored in `WalletSyncState`
/// so the `CryptoSyncStore` can format it for display without coupling the
/// domain model to localised strings.
enum WalletSyncError: Codable, Sendable, Hashable {
  case missingApiKey
  case invalidApiKey
  case rateLimited(retryAfter: Date?)
  case network(underlyingDescription: String)
  case providerMalformedResponse(stage: String)
}
