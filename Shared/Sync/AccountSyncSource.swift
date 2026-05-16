import Foundation

/// Provider-neutral sync source. Both on-chain wallets and centralised
/// exchanges conform; `SyncedAccountStore` owns the orchestration (staleness,
/// in-flight set, state persistence) and never branches on account type.
protocol AccountSyncSource: Sendable {
  /// True if this source can sync the given account (type + required config).
  func handles(_ account: Account) -> Bool
  /// Fetch + build candidates. Throw `WalletSyncError` for typed failures
  /// (missing/invalid credential, network, malformed) so the store maps one
  /// error model for all providers.
  func build(account: Account) async throws -> WalletSyncBuildResult
}
