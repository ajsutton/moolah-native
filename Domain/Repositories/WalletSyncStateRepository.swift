import Foundation

/// Per-device sync checkpoints for crypto wallet accounts.
///
/// Why this is a domain concern: `CryptoSyncStore` decides which accounts
/// to sync at launch (`loadAll`) and how far back to refetch from Alchemy
/// (`load`). Implementations are GRDB-local — these checkpoints are NOT
/// synced cross-device, so a restored-from-backup device falls back to a
/// genesis-style refetch rather than trusting a stale shared checkpoint.
protocol WalletSyncStateRepository: Sendable {
  /// Returns every wallet checkpoint on this device. `CryptoSyncStore`
  /// calls this at launch to identify stale accounts (`lastSyncedAt`
  /// older than 24 h) without paying N round-trips through
  /// `load(accountId:)`.
  func loadAll() async throws -> [WalletSyncState]
  /// Returns one account's checkpoint, or `nil` when the account has
  /// never been synced on this device — callers should treat that as a
  /// genesis-fetch (start from the chain config's seed block).
  /// `WalletSyncEngine` calls this per sync cycle to derive the reorg
  /// window's `fromBlock = lastSyncedBlockNumber - 32`.
  func load(accountId: UUID) async throws -> WalletSyncState?
  /// Persists a checkpoint, upserting on `id`. Called once per sync
  /// cycle on success and after a failed cycle (to record `lastError`
  /// without dropping the prior block-number checkpoint).
  func save(_ state: WalletSyncState) async throws
  /// Removes a checkpoint by id. Idempotent — succeeds with no effect
  /// when no checkpoint exists. Called from the account-deletion path,
  /// which races with in-flight sync writes; the no-op-on-missing
  /// behaviour absorbs that race without an error.
  func delete(accountId: UUID) async throws
}
