// Shared/CryptoImport/SyncErrorAttribution.swift
import Foundation

/// Attributes any `WalletSyncError` escaping `body` to `provider`, unless a
/// deeper boundary already attributed it (`WalletSyncError.attributed(to:)`
/// is innermost-wins). Non-`WalletSyncError` errors (e.g. `CancellationError`)
/// propagate untouched. Used at each live provider client's boundary so a
/// failure carries its source provider regardless of which orchestrator
/// invoked the client.
func attributingErrors<T>(
  to provider: SyncProvider,
  _ body: () async throws -> T
) async throws -> T {
  do {
    return try await body()
  } catch let error as WalletSyncError {
    throw error.attributed(to: provider)
  }
}
