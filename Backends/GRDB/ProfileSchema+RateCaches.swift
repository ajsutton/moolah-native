// Backends/GRDB/ProfileSchema+RateCaches.swift

import Foundation
import GRDB

// MARK: - v1 migration body

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
