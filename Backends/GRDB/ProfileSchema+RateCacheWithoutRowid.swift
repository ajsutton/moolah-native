// Backends/GRDB/ProfileSchema+RateCacheWithoutRowid.swift

import Foundation
import GRDB

// MARK: - v4 migration body
//
// Rebuilds the three rate-cache `*_meta` tables (created by `v1_initial`
// with default ROWIDs) as `WITHOUT ROWID` per
// `guides/DATABASE_SCHEMA_GUIDE.md` §3 — single-TEXT-PK lookup tables.
//
// `v1_initial` is shipped, so editing its body in place is forbidden by
// §6. The data in the meta tables is derived (date-span summary of the
// matching rate / price table); each row is rebuilt from a single
// `MIN/MAX` aggregation and discarded if the source table is empty.
//
// Companion code change: rate-cache record types now use
// `persistenceConflictPolicy = PersistenceConflictPolicy(insert: .replace)`
// and writers call `record.insert(database)` instead of
// `record.upsert(database)`. GRDB 7's `upsert` hard-codes
// `RETURNING "rowid"` (see
// `MutablePersistableRecord+Upsert.swift:upsertAndFetchWithoutCallbacks`)
// which fails against rowid-less tables. Plain `insert` with
// `INSERT OR REPLACE` does not emit `RETURNING` and the conflict
// resolution semantics are equivalent for these single-PK tables (no
// FKs reference them, no triggers fire on delete).

extension ProfileSchema {
  static func rebuildRateCacheMetaWithoutRowid(_ database: Database) throws {
    try rebuildExchangeRateMeta(database)
    try rebuildStockTickerMeta(database)
    try rebuildCryptoTokenMeta(database)
  }

  private static func rebuildExchangeRateMeta(_ database: Database) throws {
    try database.execute(
      sql: """
        DROP TABLE exchange_rate_meta;

        CREATE TABLE exchange_rate_meta (
            base TEXT PRIMARY KEY,
            earliest_date TEXT NOT NULL,
            latest_date TEXT NOT NULL
        ) STRICT, WITHOUT ROWID;

        INSERT INTO exchange_rate_meta (base, earliest_date, latest_date)
        SELECT base, MIN(date), MAX(date)
        FROM exchange_rate
        GROUP BY base;
        """)
  }

  private static func rebuildStockTickerMeta(_ database: Database) throws {
    // `instrument_id` is not derivable from `stock_price` (price rows
    // have no quote-instrument column). Carry it across via a temp
    // table. If the meta table is empty, the temp join is a no-op and
    // the rebuilt table is empty — next live cache write repopulates.
    try database.execute(
      sql: """
        CREATE TEMP TABLE stock_ticker_meta_carry AS
            SELECT ticker, instrument_id, earliest_date, latest_date
            FROM stock_ticker_meta;

        DROP TABLE stock_ticker_meta;

        CREATE TABLE stock_ticker_meta (
            ticker TEXT PRIMARY KEY,
            instrument_id TEXT NOT NULL,
            earliest_date TEXT NOT NULL,
            latest_date TEXT NOT NULL
        ) STRICT, WITHOUT ROWID;

        INSERT INTO stock_ticker_meta (ticker, instrument_id, earliest_date, latest_date)
        SELECT ticker, instrument_id, earliest_date, latest_date
        FROM stock_ticker_meta_carry;

        DROP TABLE stock_ticker_meta_carry;
        """)
  }

  private static func rebuildCryptoTokenMeta(_ database: Database) throws {
    // `symbol` is not derivable from `crypto_price`; carry across via
    // temp table. Same shape as the stock ticker rebuild above.
    try database.execute(
      sql: """
        CREATE TEMP TABLE crypto_token_meta_carry AS
            SELECT token_id, symbol, earliest_date, latest_date
            FROM crypto_token_meta;

        DROP TABLE crypto_token_meta;

        CREATE TABLE crypto_token_meta (
            token_id TEXT PRIMARY KEY,
            symbol TEXT NOT NULL,
            earliest_date TEXT NOT NULL,
            latest_date TEXT NOT NULL
        ) STRICT, WITHOUT ROWID;

        INSERT INTO crypto_token_meta (token_id, symbol, earliest_date, latest_date)
        SELECT token_id, symbol, earliest_date, latest_date
        FROM crypto_token_meta_carry;

        DROP TABLE crypto_token_meta_carry;
        """)
  }
}
