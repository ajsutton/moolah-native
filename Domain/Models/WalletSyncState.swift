import Foundation

/// Per-device sync checkpoint for an auto-imported account (on-chain
/// wallet or exchange). NOT synced cross-device — each device tracks its
/// own fetch progress so a restored-from-backup device re-fetches rather
/// than trusting a stale shared checkpoint. For a wallet that means
/// re-fetching from `lastSyncedBlockNumber - 32`; for an exchange the
/// apply pass dedups by per-leg `externalId` so a full re-fetch is safe.
///
/// `id` doubles as the account UUID for `Identifiable` consumers.
struct WalletSyncState: Codable, Sendable, Identifiable, Hashable {
  let id: UUID
  /// Highest confirmed block applied for a wallet account, used to size
  /// the next cycle's reorg-window re-fetch. Always `0` for exchange
  /// accounts (block-window re-fetch is wallet-only).
  var lastSyncedBlockNumber: UInt64
  var lastSyncedAt: Date
  var lastError: WalletSyncError?
}
