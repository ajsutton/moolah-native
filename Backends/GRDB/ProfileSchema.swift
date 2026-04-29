// Backends/GRDB/ProfileSchema.swift

import Foundation
import GRDB

/// Schema definition for a profile's `data.sqlite`.
///
/// Each profile has exactly one such database. Migration history:
/// `v1_initial` — rate caches (FX, stocks, crypto). See
/// `ProfileSchema+RateCaches.swift`.
/// `v2_csv_import_and_rules` — CSV import profiles and import rules.
/// See `ProfileSchema+CSVImportAndRules.swift`.
/// `v3_core_financial_graph` — core financial graph (instrument,
/// account, transaction, transaction_leg, category, earmark,
/// earmark_budget_item, investment_value). See
/// `ProfileSchema+CoreFinancialGraph.swift`.
/// `v4_rate_cache_without_rowid` — rebuilds the three rate-cache
/// `*_meta` tables as `WITHOUT ROWID` so they round-trip through
/// `record.insert(database)` (with `persistenceConflictPolicy =
/// .replace`) instead of `record.upsert(database)` — GRDB 7's
/// `upsert` hard-codes `RETURNING "rowid"` which fails against
/// rowid-less tables. See `ProfileSchema+RateCacheWithoutRowid.swift`.
///
/// **Retention policy for the cache tables.** All six cache tables
/// created by `v1_initial` (`exchange_rate`, `exchange_rate_meta`,
/// `stock_price`, `stock_ticker_meta`, `crypto_price`,
/// `crypto_token_meta`) are **kept forever** — needed for
/// historic-conversion correctness on reports older than the upstream
/// rate APIs can serve. See `guides/DATABASE_SCHEMA_GUIDE.md` §9.
///
/// Each migration body lives in its own sibling-extension file so
/// `ProfileSchema.swift` stays a small index of registered migrations.
/// New migrations get a new sibling file, registered here. Once
/// shipped, migration IDs are frozen forever; splitting later is
/// fine, merging post-ship is not.
///
/// See `guides/DATABASE_SCHEMA_GUIDE.md` for the rules this schema
/// follows.
enum ProfileSchema {
  /// Bumped each time a migration is added. Surfaced for open-time
  /// integrity checks; not used by `DatabaseMigrator` (which keys on
  /// the stable string IDs of registered migrations).
  static let version = 4

  static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()

    #if DEBUG
      migrator.eraseDatabaseOnSchemaChange = true
    #endif

    migrator.registerMigration("v1_initial", migrate: createInitialTables)
    migrator.registerMigration(
      "v2_csv_import_and_rules", migrate: createCSVImportAndRulesTables)
    migrator.registerMigration(
      "v3_core_financial_graph", migrate: createCoreFinancialGraphTables)
    migrator.registerMigration(
      "v4_rate_cache_without_rowid", migrate: rebuildRateCacheMetaWithoutRowid)

    return migrator
  }
}
