// Backends/GRDB/ProfileSchema+ExchangeAccountFields.swift

import Foundation
import GRDB

extension ProfileSchema {
  /// v11 migration body. Rebuilds `account` to widen the `type` CHECK to
  /// include `'exchange'` and add the nullable `exchange_provider` column
  /// (CHECK-pinned to the `ExchangeProvider` raw values). SQLite cannot
  /// alter a CHECK in place — same table-rebuild pattern as v5/v8.
  ///
  /// Retention: an `.exchange` account's read-only token lives only in the
  /// keychain (`ExchangeTokenStore`), never in this table. `AccountRepository`
  /// delete must also clear that keychain entry and the `wallet_sync_state`
  /// row (see Task 12 final-verification item).
  static func addExchangeAccountFields(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE account_new (
            id                     BLOB    NOT NULL PRIMARY KEY,
            record_name            TEXT    NOT NULL UNIQUE,
            name                   TEXT    NOT NULL,
            type                   TEXT    NOT NULL
                CHECK (type IN ('bank', 'cc', 'asset', 'investment', 'crypto', 'exchange')),
            instrument_id          TEXT    NOT NULL,
            position               INTEGER NOT NULL CHECK (position >= 0),
            is_hidden              INTEGER NOT NULL CHECK (is_hidden IN (0, 1)),
            valuation_mode         TEXT    NOT NULL DEFAULT 'recordedValue'
                CHECK (valuation_mode IN ('recordedValue', 'calculatedFromTrades')),
            wallet_address         TEXT,
            chain_id               INTEGER,
            exchange_provider      TEXT
                CHECK (exchange_provider IS NULL OR exchange_provider IN ('coinstash')),
            encoded_system_fields  BLOB
        ) STRICT;

        INSERT INTO account_new
          (id, record_name, name, type, instrument_id, position, is_hidden,
           valuation_mode, wallet_address, chain_id, encoded_system_fields)
        SELECT
          id, record_name, name, type, instrument_id, position, is_hidden,
          valuation_mode, wallet_address, chain_id, encoded_system_fields
        FROM account;

        DROP TABLE account;
        ALTER TABLE account_new RENAME TO account;

        CREATE INDEX account_by_position ON account(position);
        CREATE INDEX account_by_type     ON account(type);
        """)
  }
}
