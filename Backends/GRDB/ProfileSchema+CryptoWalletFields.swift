// Backends/GRDB/ProfileSchema+CryptoWalletFields.swift

import Foundation
import GRDB

extension ProfileSchema {
  /// v8 migration body. Adds the crypto-wallet auto-import primitives:
  /// - `account.wallet_address` (TEXT, nullable; required when type='crypto')
  /// - `account.chain_id` (INTEGER, nullable; required when type='crypto')
  /// - `account.type` CHECK extended to include `'crypto'` (SQLite cannot
  ///   alter a CHECK constraint in place, so we use the documented
  ///   table-rebuild pattern — same approach as `v5_drop_foreign_keys`).
  /// - `transaction_leg.external_id` (TEXT, nullable) + a partial UNIQUE
  ///   index on `(account_id, external_id)` enforcing per-account dedup
  ///   for non-NULL externalIds.
  /// - `instrument.pricing_status` (TEXT, NOT NULL, default `'priced'`)
  ///   with a CHECK pinning the `TokenPricingStatus` raw values.
  /// - `wallet_sync_state` table — per-device sync checkpoints, NOT
  ///   synced via CKSyncEngine (each device owns its own checkpoint).
  ///
  /// Retention: `wallet_sync_state` rows are application-scoped to their
  /// account. `AccountRepository.delete(_:)` must also call
  /// `WalletSyncStateRepository.delete(accountId:)`. There is no FK
  /// constraint (the project drops FKs per v5; cross-table cascade lives
  /// in repository code).
  static func addCryptoWalletFields(_ database: Database) throws {
    try rebuildAccountForCrypto(database)
    try addExternalIdToTransactionLeg(database)
    try addPricingStatusToInstrument(database)
    try createWalletSyncStateTable(database)
  }

  /// Rebuilds `account` to widen the type CHECK and add the two new
  /// optional crypto fields. Preserves existing rows and indexes.
  private static func rebuildAccountForCrypto(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE account_new (
            id                     BLOB    NOT NULL PRIMARY KEY,
            record_name            TEXT    NOT NULL UNIQUE,
            name                   TEXT    NOT NULL,
            type                   TEXT    NOT NULL
                CHECK (type IN ('bank', 'cc', 'asset', 'investment', 'crypto')),
            instrument_id          TEXT    NOT NULL,
            position               INTEGER NOT NULL CHECK (position >= 0),
            is_hidden              INTEGER NOT NULL CHECK (is_hidden IN (0, 1)),
            valuation_mode         TEXT    NOT NULL DEFAULT 'recordedValue'
                CHECK (valuation_mode IN ('recordedValue', 'calculatedFromTrades')),
            wallet_address         TEXT,
            chain_id               INTEGER,
            encoded_system_fields  BLOB
        ) STRICT;

        INSERT INTO account_new
          (id, record_name, name, type, instrument_id, position, is_hidden,
           valuation_mode, wallet_address, chain_id, encoded_system_fields)
        SELECT
          id, record_name, name, type, instrument_id, position, is_hidden,
          valuation_mode, NULL, NULL, encoded_system_fields
        FROM account;

        DROP TABLE account;
        ALTER TABLE account_new RENAME TO account;

        CREATE INDEX account_by_position ON account(position);
        CREATE INDEX account_by_type     ON account(type);
        """)
  }

  /// `transaction_leg.external_id` + partial UNIQUE dedup index. NULL
  /// external_ids are excluded (existing rows + manual transactions).
  /// Same on-chain hash on different accounts is fine (cross-account
  /// transfer); same hash on the same account is rejected at the DB
  /// layer (defence in depth — application dedup is the primary check).
  private static func addExternalIdToTransactionLeg(_ database: Database) throws {
    try database.execute(
      sql: """
        ALTER TABLE transaction_leg ADD COLUMN external_id TEXT;

        CREATE UNIQUE INDEX leg_dedup_by_account_external
            ON transaction_leg(account_id, external_id)
            WHERE external_id IS NOT NULL;
        """)
  }

  /// `instrument.pricing_status` (TokenPricingStatus enum raw values).
  /// Default `'priced'` so existing rows + built-in presets behave
  /// unchanged. CHECK pins the enum.
  private static func addPricingStatusToInstrument(_ database: Database) throws {
    try database.execute(
      sql: """
        ALTER TABLE instrument
          ADD COLUMN pricing_status TEXT NOT NULL DEFAULT 'priced'
            CHECK (pricing_status IN ('priced', 'unpriced', 'spam'));
        """)
  }

  /// `wallet_sync_state` — per-device sync checkpoints. `account_id` is
  /// BLOB matching `account.id` (UUID-as-BLOB). `last_error_json`
  /// validated by `json_valid()` per DATABASE_SCHEMA_GUIDE §3.
  private static func createWalletSyncStateTable(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE wallet_sync_state (
            account_id                BLOB    NOT NULL PRIMARY KEY,
            last_synced_block_number  INTEGER NOT NULL,
            last_synced_at            TEXT    NOT NULL,
            last_error_json           TEXT
                CHECK (last_error_json IS NULL OR json_valid(last_error_json))
        ) STRICT;
        """)
  }
}
