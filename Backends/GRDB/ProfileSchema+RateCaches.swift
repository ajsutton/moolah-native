// Backends/GRDB/ProfileSchema+RateCaches.swift

import Foundation
import GRDB

// MARK: - v1 migration body
//
// The three `*_meta` tables ship here as ROWID tables — the shape
// originally chosen because GRDB 7's `PersistableRecord.upsert(_:)`
// hard-codes `RETURNING "rowid"` and trips on `WITHOUT ROWID` tables.
// `v4_rate_cache_without_rowid` rebuilds them as `WITHOUT ROWID`
// (single-TEXT-PK lookup tables per
// `guides/DATABASE_SCHEMA_GUIDE.md` §3) once the writers switched
// away from `upsert` to `insert(onConflict: .replace)`. Editing this
// body in place would violate §6 (frozen migrations).

extension ProfileSchema {
  static func createInitialTables(_ database: Database) throws {
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
