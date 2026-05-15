// Backends/GRDB/ProfileIndexSchema+SharedInstrumentRegistry.swift

import Foundation
import GRDB

/// Body of the `v3_shared_instrument_registry` migration. Creates the
/// `instrument` table (same shape as the per-profile one in
/// `ProfileSchema+CoreFinancialGraph.swift` +
/// `ProfileSchema+CryptoWalletFields.swift`) plus the six rate-cache
/// tables (same shape as the per-profile ones in
/// `ProfileSchema+RateCaches.swift` and
/// `ProfileSchema+RateCacheWithoutRowid.swift`).
///
/// **Verbatim semantics.** Each `CREATE TABLE` reflects the table's
/// final shape in a single statement; fresh-table creation does not
/// replay per-profile migration steps.
///
/// **`WITHOUT ROWID` decisions.**
/// * `instrument` — **not** `WITHOUT ROWID`. The `encoded_system_fields`
///   `BLOB` dominates row size, which makes `WITHOUT ROWID`'s
///   interior-page packing a net loss (per
///   `guides/DATABASE_SCHEMA_GUIDE.md` §3 decision table). Matches the
///   per-profile decision.
/// * All six rate-cache tables — `WITHOUT ROWID`. The body tables
///   (`exchange_rate`, `stock_price`, `crypto_price`) carry composite
///   primary keys that are themselves the natural lookup index, and
///   the row payload is small (3-5 columns of TEXT/REAL). The meta
///   tables are single-TEXT-PK lookup tables. Both shapes are the
///   §3-recommended `WITHOUT ROWID` form.
///
/// **Retention policy for the cache tables.** All six tables are
/// **kept forever** — needed for historic-conversion correctness on
/// reports older than the upstream rate APIs can serve. See
/// `guides/DATABASE_SCHEMA_GUIDE.md` §9 and the equivalent rationale
/// in `ProfileSchema.swift:48-55`.
///
/// **`WITHOUT ROWID` + `ValueObservation` caveat.** SQLite's
/// `sqlite3_update_hook` does **not** fire for `WITHOUT ROWID` tables,
/// so GRDB's `ValueObservation.tracking(regions:)` would silently fail
/// to re-fire after writes. Any caller writing into the rate-cache
/// tables (`CryptoPriceService`, `StockPriceService`,
/// `ExchangeRateService` persistence paths) MUST call
/// `db.notifyRateCacheChange(...)` inside the same `db.write { … }`
/// block so `RateCacheTickStream`'s observation re-fires. See
/// `Backends/GRDB/Observation/RateCacheTable.swift` for the helper and
/// the call-site pattern; the same contract is documented on the
/// per-profile schema (`ProfileSchema+RateCaches.swift:17-27`).
///
/// **`exchange_rate_lookup` index — intentionally omitted.** No
/// production query predicates on `(base, quote, date)`. `loadCache`
/// fetches `WHERE base = ?` (PK leading-column scan) and resolves
/// quote/date lookups in-memory from the loaded `caches[base]`
/// dictionary. Carrying the per-profile `exchange_rate_lookup` index
/// forward would add write amplification on a write-heavy table for
/// zero read benefit. Plan-pinning tests in `RateQueryPlanTests`
/// confirm the PK is the chosen access path on the shared DB.
extension ProfileIndexSchema {
  static func createSharedInstrumentRegistryTables(_ database: Database) throws {
    try createInstrumentTable(database)
    try createRateCacheTables(database)
  }

  private static func createInstrumentTable(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE instrument (
            id                     TEXT    NOT NULL PRIMARY KEY,
            record_name            TEXT    NOT NULL UNIQUE,
            kind                   TEXT    NOT NULL
                CHECK (kind IN ('fiatCurrency', 'stock', 'cryptoToken')),
            name                   TEXT    NOT NULL,
            decimals               INTEGER NOT NULL CHECK (decimals >= 0),
            ticker                 TEXT,
            exchange               TEXT,
            chain_id               INTEGER,
            contract_address       TEXT,
            coingecko_id           TEXT,
            cryptocompare_symbol   TEXT,
            binance_symbol         TEXT,
            encoded_system_fields  BLOB,
            pricing_status         TEXT    NOT NULL DEFAULT 'priced'
                CHECK (pricing_status IN ('priced', 'unpriced', 'spam'))
        ) STRICT;
        """)
  }

  private static func createRateCacheTables(_ database: Database) throws {
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

        CREATE TABLE exchange_rate_meta (
            base TEXT PRIMARY KEY,
            earliest_date TEXT NOT NULL,
            latest_date TEXT NOT NULL
        ) STRICT, WITHOUT ROWID;
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
        ) STRICT, WITHOUT ROWID;
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
        ) STRICT, WITHOUT ROWID;
        """)
  }
}
