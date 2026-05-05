import Foundation

/// Per-device sync checkpoints for crypto wallet accounts.
///
/// Why this is a domain concern: `CryptoSyncStore` decides which accounts
/// to sync at launch (`loadAll`) and how far back to refetch from Alchemy
/// (`load`). Implementations are GRDB-local — these checkpoints are NOT
/// synced cross-device, so a restored-from-backup device falls back to a
/// genesis-style refetch rather than trusting a stale shared checkpoint.
protocol WalletSyncStateRepository: Sendable {
  /// Why: at app launch the store needs to know which accounts are stale
  /// (`lastSyncedAt > 24h ago`). Returning every checkpoint avoids N round
  /// trips through `load(accountId:)`.
  func loadAll() async throws -> [WalletSyncState]
  /// Why: per-sync-cycle, the engine reads `lastSyncedBlockNumber` so the
  /// reorg window starts at `block - 32`. `nil` means "never synced — fetch
  /// from genesis or chain config's seed block".
  func load(accountId: UUID) async throws -> WalletSyncState?
  /// Why: the engine writes the checkpoint after every cycle (success or
  /// failure — failures populate `lastError` so the UI can surface staleness
  /// without losing the prior block-number checkpoint). Upsert on `id`.
  func save(_ state: WalletSyncState) async throws
  /// Why: account deletion races with sync; if the engine writes a row right
  /// after the account is deleted, the next account-deletion path needs to
  /// idempotently clean up — succeeds with no effect when no row exists.
  func delete(accountId: UUID) async throws
}
