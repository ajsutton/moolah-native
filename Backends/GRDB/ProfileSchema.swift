// Backends/GRDB/ProfileSchema.swift

import Foundation
import GRDB

/// Schema definition for a profile's `data.sqlite`.
///
/// Each profile has exactly one such database. v1 of the schema covers the
/// rate caches only (FX, stocks, crypto). User-data tables — accounts,
/// transactions, earmarks, etc. — are added in later migrations as the
/// remaining slices of the GRDB migration land.
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
  static let version = 1

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
}
