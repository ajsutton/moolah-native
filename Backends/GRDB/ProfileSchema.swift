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
/// `v5_drop_foreign_keys` — recreates the four child tables of the
/// core financial graph (`category`, `earmark_budget_item`,
/// `transaction_leg`, `investment_value`) without any FK clauses.
/// See `ProfileSchema+DropForeignKeys.swift` for rationale.
/// `v6_account_valuation_mode` — adds the `valuation_mode` column to
/// the `account` table (per-account choice between recorded value and
/// calculated-from-trades). See
/// `ProfileSchema+AccountValuationMode.swift`.
/// `v7_purge_intraday_cached_prices` — one-shot `DELETE FROM` of all
/// six rate-cache tables to clear poisoned intraday rows persisted by
/// pre-cap builds. See `ProfileSchema+PurgeIntradayCaches.swift` and
/// `Shared/PriceCacheCap.swift` for the cap-at-yesterday rule that
/// prevents re-poisoning.
/// `v8_add_crypto_wallet_fields` — adds `wallet_address`/`chain_id`
/// to `account` (rebuilding the table to widen the type CHECK to
/// include `'crypto'`), `external_id` + partial-unique dedup index
/// to `transaction_leg`, `pricing_status` to `instrument`, and the
/// per-device `wallet_sync_state` table. See
/// `ProfileSchema+CryptoWalletFields.swift`.
/// `v9_add_counterparty_address` — adds `counterparty_address` to
/// `transaction_leg`. Populated by `TransferEventBuilder` from the
/// Alchemy transfer's `from`/`to` (whichever isn't this wallet);
/// `nil` for non-crypto legs and gas/self-send legs. Surfaced in the
/// transaction detail's "On-chain counterparty" row. See
/// `ProfileSchema+CounterpartyAddress.swift`.
/// `v10_drop_shared_instrument_legacy` — drops the seven legacy
/// per-profile tables (`instrument`, `exchange_rate`,
/// `exchange_rate_meta`, `stock_price`, `stock_ticker_meta`,
/// `crypto_price`, `crypto_token_meta`). Their data lives in the
/// shared profile-index registry, so the per-profile copies have no
/// reader. Permitted per `guides/DATABASE_SCHEMA_GUIDE.md` §1 rule 3 /
/// §6 rule 7. See `ProfileSchema+DropSharedInstrumentLegacy.swift` for
/// the full rationale.
///
/// **Retention policy for the cache tables.** The six rate-cache
/// tables are kept forever — needed for historic-conversion
/// correctness on reports older than the upstream rate APIs can serve
/// (see `guides/DATABASE_SCHEMA_GUIDE.md` §9). The retained copy lives
/// on the **shared** `profile-index.sqlite` DB, not per-profile; the
/// per-profile copies are dropped as duplicated derived caches.
///
/// Each migration body lives in its own sibling-extension file so
/// `ProfileSchema.swift` stays a small index of registered migrations.
/// New migrations get a new sibling file, registered here. Migration
/// IDs are frozen forever once shipped; splitting later is fine,
/// merging post-ship is not.
///
/// See `guides/DATABASE_SCHEMA_GUIDE.md` for the rules this schema
/// follows.
enum ProfileSchema {
  /// Bumped each time a migration is added. Surfaced for open-time
  /// integrity checks; not used by `DatabaseMigrator` (which keys on
  /// the stable string IDs of registered migrations).
  static let version = 10

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
    migrator.registerMigration(
      "v5_drop_foreign_keys", migrate: dropForeignKeys)
    migrator.registerMigration(
      "v6_account_valuation_mode", migrate: addAccountValuationMode)
    migrator.registerMigration(
      "v7_purge_intraday_cached_prices", migrate: purgeIntradayCachedPrices)
    migrator.registerMigration(
      "v8_add_crypto_wallet_fields", migrate: addCryptoWalletFields)
    migrator.registerMigration(
      "v9_add_counterparty_address", migrate: addCounterpartyAddressToTransactionLeg)
    migrator.registerMigration(
      "v10_drop_shared_instrument_legacy", migrate: dropSharedInstrumentLegacy)

    return migrator
  }
}
