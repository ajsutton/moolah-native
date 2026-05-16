import Foundation

/// Per-device sync checkpoints for auto-imported accounts (on-chain
/// wallets and exchanges).
///
/// Why this is a domain concern: `SyncedAccountStore` decides which
/// accounts to sync at launch (`loadAll`) and how far back to refetch
/// (`load`). Implementations are GRDB-local — these checkpoints are NOT
/// synced cross-device, so a restored-from-backup device falls back to a
/// genesis-style refetch rather than trusting a stale shared checkpoint.
protocol WalletSyncStateRepository: Sendable {
  /// Returns every checkpoint on this device. `SyncedAccountStore`
  /// calls this at launch to identify stale accounts (`lastSyncedAt`
  /// older than 24 h) without paying N round-trips through
  /// `load(accountId:)`.
  func loadAll() async throws -> [WalletSyncState]
  /// Returns one account's checkpoint, or `nil` when the account has
  /// never been synced on this device — callers should treat that as a
  /// genesis-fetch (start from the chain config's seed block).
  /// `WalletSyncEngine` calls this per wallet sync cycle to derive the
  /// reorg window's `fromBlock = lastSyncedBlockNumber - 32`. For
  /// exchange accounts `lastSyncedBlockNumber` is always `0` (no block
  /// concept — the apply pass dedups by per-leg `externalId`, so a full
  /// re-fetch each cycle is safe).
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
