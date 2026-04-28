// Backends/GRDB/ProfileSchema.swift

import Foundation
import GRDB

/// Schema definition for a profile's `data.sqlite`.
///
/// Each profile has exactly one such database. v1 of the schema covers the
/// rate caches only (FX, stocks, crypto). v2 adds the first synced
/// user-data tables (`csv_import_profile`, `import_rule`). Subsequent
/// slices of `plans/grdb-migration.md` add accounts, transactions,
/// earmarks, etc. under further `v3_…`, `v4_…` migrations.
///
/// **Retention policy for the cache tables.** All six cache tables created
/// by `v1_initial` (`exchange_rate`, `exchange_rate_meta`, `stock_price`,
/// `stock_ticker_meta`, `crypto_price`, `crypto_token_meta`) are **kept
/// forever** — needed for historic-conversion correctness on reports older
/// than the upstream rate APIs can serve. See `plans/grdb-migration.md` §4
/// and `guides/DATABASE_SCHEMA_GUIDE.md` §9.
///
/// See `guides/DATABASE_SCHEMA_GUIDE.md` for the rules this schema follows
/// and `plans/grdb-migration.md` for the slice sequencing.
enum ProfileSchema {
  /// Bumped each time a migration is added. Surfaced for open-time
  /// integrity checks; not used by `DatabaseMigrator` (which keys on the
  /// stable string IDs of registered migrations).
  static let version = 2

  static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()

    #if DEBUG
      migrator.eraseDatabaseOnSchemaChange = true
    #endif

    // Once shipped, migration IDs are frozen forever, so the rate-cache
    // slice is intentionally registered as a single `v1_initial` migration
    // rather than three sub-migrations. Splitting later is fine; merging
    // post-ship is not.
    migrator.registerMigration("v1_initial", migrate: createInitialTables)
    // Slice 0 of `plans/grdb-migration.md`: first synced user-data tables.
    migrator.registerMigration(
      "v2_csv_import_and_rules", migrate: createCSVImportAndRulesTables)

    return migrator
  }

  // MARK: - v1 migration body

  private static func createInitialTables(_ database: Database) throws {
    try createExchangeRateTables(database)
    try createStockPriceTables(database)
    try createCryptoPriceTables(database)
  }

  private static func createExchangeRateTables(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE exchange_rate (
            base TEXT NOT NULL,
            quote TEXT NOT NULL,
            date TEXT NOT NULL,
            rate REAL NOT NULL,
            PRIMARY KEY (base, date, quote)
        ) STRICT, WITHOUT ROWID;

        CREATE INDEX exchange_rate_lookup
            ON exchange_rate (base, quote, date);

        CREATE TABLE exchange_rate_meta (
            base TEXT PRIMARY KEY,
            earliest_date TEXT NOT NULL,
            latest_date TEXT NOT NULL
        ) STRICT;
        """)
  }

  private static func createStockPriceTables(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE stock_price (
            ticker TEXT NOT NULL,
            date TEXT NOT NULL,
            price REAL NOT NULL,
            PRIMARY KEY (ticker, date)
        ) STRICT, WITHOUT ROWID;

        CREATE TABLE stock_ticker_meta (
            ticker TEXT PRIMARY KEY,
            instrument_id TEXT NOT NULL,
            earliest_date TEXT NOT NULL,
            latest_date TEXT NOT NULL
        ) STRICT;
        """)
  }

  private static func createCryptoPriceTables(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE crypto_price (
            token_id TEXT NOT NULL,
            date TEXT NOT NULL,
            price_usd REAL NOT NULL,
            PRIMARY KEY (token_id, date)
        ) STRICT, WITHOUT ROWID;

        CREATE TABLE crypto_token_meta (
            token_id TEXT PRIMARY KEY,
            symbol TEXT NOT NULL,
            earliest_date TEXT NOT NULL,
            latest_date TEXT NOT NULL
        ) STRICT;
        """)
  }

  // MARK: - v2 migration body
  //
  // Both tables hold synced user data, so each one carries
  // `encoded_system_fields BLOB` (the cached CKRecord change tag) and
  // `record_name TEXT NOT NULL UNIQUE` (the canonical CloudKit recordName,
  // e.g. `"CSVImportProfileRecord|<uuid>"`) per
  // `plans/grdb-migration.md` §4. ROWID is kept (single-column UUID PK +
  // wide rows — `WITHOUT ROWID` is not justified per
  // `DATABASE_SCHEMA_GUIDE.md` §3).

  private static func createCSVImportAndRulesTables(_ database: Database) throws {
    try createCSVImportProfileTable(database)
    try createImportRuleTable(database)
  }

  private static func createCSVImportProfileTable(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE csv_import_profile (
            id                              BLOB    NOT NULL PRIMARY KEY,
            record_name                     TEXT    NOT NULL UNIQUE,
            account_id                      BLOB    NOT NULL,
            parser_identifier               TEXT    NOT NULL,
            header_signature                TEXT    NOT NULL,
            filename_pattern                TEXT,
            delete_after_import             INTEGER NOT NULL,
            created_at                      TEXT    NOT NULL,
            last_used_at                    TEXT,
            date_format_raw_value           TEXT,
            column_role_raw_values_encoded  TEXT,
            encoded_system_fields           BLOB
        ) STRICT;

        CREATE INDEX csv_import_profile_account
            ON csv_import_profile(account_id);
        CREATE INDEX csv_import_profile_created
            ON csv_import_profile(created_at);
        """)
  }

  private static func createImportRuleTable(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE import_rule (
            id                     BLOB    NOT NULL PRIMARY KEY,
            record_name            TEXT    NOT NULL UNIQUE,
            name                   TEXT    NOT NULL,
            enabled                INTEGER NOT NULL,
            position               INTEGER NOT NULL,
            match_mode             TEXT    NOT NULL,
            conditions_json        BLOB    NOT NULL,
            actions_json           BLOB    NOT NULL,
            account_scope          BLOB,
            encoded_system_fields  BLOB
        ) STRICT;

        CREATE INDEX import_rule_position
            ON import_rule(position);
        CREATE INDEX import_rule_account_scope
            ON import_rule(account_scope) WHERE account_scope IS NOT NULL;
        """)
  }
}
