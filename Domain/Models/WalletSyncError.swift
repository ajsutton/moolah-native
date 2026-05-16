import Foundation

/// Structured outcome of a failed wallet sync cycle. Stored in `WalletSyncState`
/// so the `SyncedAccountStore` can format it for display without coupling the
/// domain model to localised strings.
///
/// Conforms to `Error` so the wallet-sync data layer (Stage 4 onward) can
/// throw it directly. The associated values are persisted by JSON-encoding
/// the value via `Codable`, so the conformance is additive — no shape
/// change to existing storage.
enum WalletSyncError: Error, Codable, Sendable, Hashable {
  case missingApiKey
  case invalidApiKey
  case rateLimited(retryAfter: Date?)
  case network(underlyingDescription: String)
  case providerMalformedResponse(stage: String)
}
