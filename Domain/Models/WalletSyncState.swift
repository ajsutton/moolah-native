import Foundation

/// Per-device sync checkpoint for a wallet account. NOT synced cross-device —
/// each device tracks its own Alchemy-fetch progress so a restored-from-backup
/// device re-fetches from `lastSyncedBlockNumber - 32` rather than trusting a
/// stale shared checkpoint.
///
/// `id` doubles as the account UUID for `Identifiable` consumers.
struct WalletSyncState: Codable, Sendable, Identifiable, Hashable {
  let id: UUID
  var lastSyncedBlockNumber: UInt64
  var lastSyncedAt: Date
  var lastError: WalletSyncError?
}
