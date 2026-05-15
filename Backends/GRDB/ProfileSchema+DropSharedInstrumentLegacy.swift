// Backends/GRDB/ProfileSchema+DropSharedInstrumentLegacy.swift

import Foundation
import GRDB

// MARK: - v10 migration body
//
// Drops the seven legacy per-profile tables: `instrument`,
// `exchange_rate`, `exchange_rate_meta`, `stock_price`,
// `stock_ticker_meta`, `crypto_price`, `crypto_token_meta`.
//
// Why the drop is permitted (DATABASE_SCHEMA_GUIDE §1 rule 3 / §6
// rule 7 — "drop-and-recreate is allowed only for derived caches
// whose source of truth is elsewhere"):
//
// * `instrument` is no longer the source of truth. Instrument
//   identity now lives on the shared `profile-index.sqlite`
//   registry (`ProfileIndexSchema`'s `instrument` table), authored
//   once per iCloud account and fanned out to every profile. The
//   per-profile copy was a transitional duplicate; every device has
//   completed the one-time union into the shared registry, so the
//   per-profile rows have no remaining reader.
// * The six rate-cache tables (`exchange_rate{,_meta}`,
//   `stock_price` / `stock_ticker_meta`, `crypto_price` /
//   `crypto_token_meta`) are network-derived caches whose source of
//   truth is the upstream price/FX APIs. They are now persisted on
//   the shared profile-index DB so two profiles holding the same
//   instrument share one cache; the per-profile copies are dead and
//   re-fetch on demand if ever needed.
//
// `DROP TABLE IF EXISTS` is idempotent, so a profile DB that somehow
// never created one of these tables migrates cleanly. The whole
// statement is one `database.execute(sql:)` — `DatabaseMigrator`
// wraps every migration in a single transaction, so no explicit
// BEGIN/COMMIT (a nested one would error).
//
// No FK / PRAGMA handling: the per-profile schema declares no
// foreign keys (as of `v5_drop_foreign_keys`) and none of the seven
// tables is an FK target, so `PRAGMA foreign_keys` toggling is
// unnecessary.
//
// No sidecar / file cleanup: this migration only issues SQL inside
// the migrator's transaction — it never touches the `*.sqlite` file
// or its `-wal` / `-shm` sidecars, so DATABASE_SCHEMA_GUIDE §7's
// file-removal sidecar rule does not apply.

extension ProfileSchema {
  static func dropSharedInstrumentLegacy(_ database: Database) throws {
    try database.execute(
      sql: """
        DROP TABLE IF EXISTS instrument;
        DROP TABLE IF EXISTS exchange_rate;
        DROP TABLE IF EXISTS exchange_rate_meta;
        DROP TABLE IF EXISTS stock_price;
        DROP TABLE IF EXISTS stock_ticker_meta;
        DROP TABLE IF EXISTS crypto_price;
        DROP TABLE IF EXISTS crypto_token_meta;
        """)
  }
}
