// Backends/GRDB/Records/WalletSyncStateRow.swift

import Foundation
import GRDB

/// One row in the `wallet_sync_state` table — per-device sync
/// checkpoints for crypto wallet accounts. NOT synced cross-device
/// (excluded from CKSyncEngine; each device tracks its own Alchemy
/// fetch progress so a restored-from-backup device falls back to a
/// genesis-style refetch rather than trusting a stale shared
/// checkpoint).
///
/// `account_id` is `BLOB` matching `account.id` (UUID-as-BLOB in this
/// project's GRDB convention). `lastErrorJson` is JSON-encoded
/// `WalletSyncError` rather than flattened to columns because the
/// error type has associated values; the table is local-only and never
/// queried by error shape, so the JSON column is fine per
/// DATABASE_CODE_GUIDE §3. The `wallet_sync_state` row also has a
/// `json_valid` CHECK constraint at the schema layer (DATABASE_SCHEMA
/// migration v8) defending against malformed JSON at the DB boundary.
struct WalletSyncStateRow {
  static let databaseTableName = "wallet_sync_state"

  enum Columns: String, ColumnExpression, CaseIterable {
    case accountId = "account_id"
    case lastSyncedBlockNumber = "last_synced_block_number"
    case lastSyncedAt = "last_synced_at"
    case lastErrorJson = "last_error_json"
  }

  enum CodingKeys: String, CodingKey {
    case accountId = "account_id"
    case lastSyncedBlockNumber = "last_synced_block_number"
    case lastSyncedAt = "last_synced_at"
    case lastErrorJson = "last_error_json"
  }

  var accountId: UUID
  var lastSyncedBlockNumber: Int64
  var lastSyncedAt: Date
  var lastErrorJson: String?
}

extension WalletSyncStateRow: Codable {}
extension WalletSyncStateRow: Sendable {}
extension WalletSyncStateRow: FetchableRecord {}
extension WalletSyncStateRow: PersistableRecord {}
