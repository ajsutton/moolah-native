// Backends/GRDB/ProfileSchema+CoreFinancialGraph.swift

import Foundation
import GRDB

// MARK: - v3 migration body
//
// Eight tables ship together so foreign-key references resolve in one
// transaction. Order: instrument → category → account → earmark →
// earmark_budget_item → "transaction" → transaction_leg →
// investment_value (parents before children).
//
// CHECK constraints pin the SQL-side invariants per
// `DATABASE_SCHEMA_GUIDE.md` §3:
//   * Booleans on Bool-typed columns are restricted to 0/1.
//   * Enum-shaped TEXT columns are restricted to the raw values from
//     the matching Swift enum (`Instrument.Kind`, `AccountType`,
//     `RecurPeriod`, `TransactionType`). Update the SQL CHECK clause
//     and the column lists in lock-step if any enum's raw values
//     change.
//   * Bounded INTEGER columns (`decimals`, `position`, `recur_every`,
//     `sort_order`) are non-negative or strictly positive as
//     applicable.
//
// Foreign keys:
//   * `transaction_leg.transaction_id` → `transaction.id` ON DELETE
//     CASCADE — legs cannot outlive their transaction.
//   * `transaction_leg.account_id` → `account.id` ON DELETE SET NULL —
//     account-less legs are valid (`Domain/Models/TransactionLeg.swift`
//     `accountId: UUID?`).
//   * `transaction_leg.category_id` / `earmark_id` → SET NULL —
//     repository-managed delete-with-replacement.
//   * `category.parent_id` → `category.id` ON DELETE NO ACTION —
//     hierarchy deletion is an explicit repository step.
//   * `earmark_budget_item.earmark_id` → `earmark.id` ON DELETE
//     CASCADE — items belong to their earmark.
//   * `earmark_budget_item.category_id` → `category.id` ON DELETE NO
//     ACTION — silent budget mutation is unsafe.
//   * `investment_value.account_id` → `account.id` ON DELETE CASCADE —
//     values belong to the account.
//
// No FK on `*.instrument_id`: `Instrument` is dual-role — synced
// stocks/crypto have rows; ambient fiat (`Locale.Currency`) does not.
// Integrity is enforced at the application boundary.

extension ProfileSchema {
  static func createCoreFinancialGraphTables(_ database: Database) throws {
    try createInstrumentTable(database)
    try createCategoryTable(database)
    try createAccountTable(database)
    try createEarmarkTable(database)
    try createEarmarkBudgetItemTable(database)
    try createTransactionTable(database)
    try createTransactionLegTable(database)
    try createInvestmentValueTable(database)
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
            encoded_system_fields  BLOB
        ) STRICT;
        """)
  }

  private static func createCategoryTable(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE category (
            id                     BLOB    NOT NULL PRIMARY KEY,
            record_name            TEXT    NOT NULL UNIQUE,
            name                   TEXT    NOT NULL,
            parent_id              BLOB    REFERENCES category(id) ON DELETE NO ACTION,
            encoded_system_fields  BLOB
        ) STRICT;

        -- Hierarchy display in CategoryStore. Partial because most rows
        -- are root categories (parent_id IS NULL).
        CREATE INDEX category_by_parent
            ON category(parent_id) WHERE parent_id IS NOT NULL;
        """)
  }

  private static func createAccountTable(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE account (
            id                     BLOB    NOT NULL PRIMARY KEY,
            record_name            TEXT    NOT NULL UNIQUE,
            name                   TEXT    NOT NULL,
            type                   TEXT    NOT NULL
                CHECK (type IN ('bank', 'cc', 'asset', 'investment')),
            instrument_id          TEXT    NOT NULL,
            position               INTEGER NOT NULL CHECK (position >= 0),
            is_hidden              INTEGER NOT NULL CHECK (is_hidden IN (0, 1)),
            encoded_system_fields  BLOB
        ) STRICT;

        CREATE INDEX account_by_position ON account(position);
        CREATE INDEX account_by_type     ON account(type);
        """)
  }

  private static func createEarmarkTable(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE earmark (
            id                            BLOB    NOT NULL PRIMARY KEY,
            record_name                   TEXT    NOT NULL UNIQUE,
            name                          TEXT    NOT NULL,
            position                      INTEGER NOT NULL CHECK (position >= 0),
            is_hidden                     INTEGER NOT NULL CHECK (is_hidden IN (0, 1)),
            instrument_id                 TEXT,
            savings_target                INTEGER,
            savings_target_instrument_id  TEXT,
            savings_start_date            TEXT,
            savings_end_date              TEXT,
            encoded_system_fields         BLOB
        ) STRICT;

        CREATE INDEX earmark_by_position ON earmark(position);
        """)
  }

  private static func createEarmarkBudgetItemTable(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE earmark_budget_item (
            id                     BLOB    NOT NULL PRIMARY KEY,
            record_name            TEXT    NOT NULL UNIQUE,
            earmark_id             BLOB    NOT NULL REFERENCES earmark(id)  ON DELETE CASCADE,
            category_id            BLOB    NOT NULL REFERENCES category(id) ON DELETE NO ACTION,
            amount                 INTEGER NOT NULL,
            instrument_id          TEXT    NOT NULL,
            encoded_system_fields  BLOB
        ) STRICT;

        -- FK child indexes per DATABASE_SCHEMA_GUIDE.md §4 — mandatory.
        CREATE INDEX ebi_by_earmark  ON earmark_budget_item(earmark_id);
        CREATE INDEX ebi_by_category ON earmark_budget_item(category_id);
        """)
  }

  private static func createTransactionTable(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE "transaction" (
            id                                BLOB    NOT NULL PRIMARY KEY,
            record_name                       TEXT    NOT NULL UNIQUE,
            date                              TEXT    NOT NULL,
            payee                             TEXT,
            notes                             TEXT,
            recur_period                      TEXT
                CHECK (recur_period IS NULL
                       OR recur_period IN ('ONCE', 'DAY', 'WEEK', 'MONTH', 'YEAR')),
            recur_every                       INTEGER
                CHECK (recur_every IS NULL OR recur_every > 0),
            -- Denormalised ImportOrigin (eight columns) — matches the
            -- existing CKRecord wire format byte-for-byte.
            import_origin_raw_description     TEXT,
            import_origin_bank_reference      TEXT,
            import_origin_raw_amount          TEXT,
            import_origin_raw_balance         TEXT,
            import_origin_imported_at         TEXT,
            import_origin_import_session_id   BLOB,
            import_origin_source_filename     TEXT,
            import_origin_parser_identifier   TEXT,
            encoded_system_fields             BLOB
        ) STRICT;

        CREATE INDEX transaction_by_date
            ON "transaction"(date);
        -- Partial: scheduled rows are rare; non-NULL recur_period is the
        -- selective predicate. Mirrors the SwiftData (recur_period, date).
        CREATE INDEX transaction_scheduled
            ON "transaction"(recur_period, date)
            WHERE recur_period IS NOT NULL;
        CREATE INDEX transaction_by_payee
            ON "transaction"(payee) WHERE payee IS NOT NULL;
        CREATE INDEX transaction_by_session
            ON "transaction"(import_origin_import_session_id)
            WHERE import_origin_import_session_id IS NOT NULL;
        """)
  }

  private static func createTransactionLegTable(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE transaction_leg (
            id                     BLOB    NOT NULL PRIMARY KEY,
            record_name            TEXT    NOT NULL UNIQUE,
            transaction_id         BLOB    NOT NULL REFERENCES "transaction"(id) ON DELETE CASCADE,
            account_id             BLOB             REFERENCES account(id)        ON DELETE SET NULL,
            instrument_id          TEXT    NOT NULL,
            quantity               INTEGER NOT NULL,
            type                   TEXT    NOT NULL
                CHECK (type IN ('income', 'expense', 'transfer', 'openingBalance', 'trade')),
            category_id            BLOB             REFERENCES category(id) ON DELETE SET NULL,
            earmark_id             BLOB             REFERENCES earmark(id)  ON DELETE SET NULL,
            sort_order             INTEGER NOT NULL CHECK (sort_order >= 0),
            encoded_system_fields  BLOB
        ) STRICT;

        -- FK child indexes per DATABASE_SCHEMA_GUIDE.md §4 — mandatory.
        CREATE INDEX leg_by_transaction ON transaction_leg(transaction_id);
        CREATE INDEX leg_by_account
            ON transaction_leg(account_id) WHERE account_id IS NOT NULL;
        CREATE INDEX leg_by_category
            ON transaction_leg(category_id) WHERE category_id IS NOT NULL;
        CREATE INDEX leg_by_earmark
            ON transaction_leg(earmark_id) WHERE earmark_id IS NOT NULL;
        -- Composite covering indexes for the analysis hot paths
        -- (`fetchIncomeAndExpense`, `fetchExpenseBreakdown`,
        -- `fetchCategoryBalances`, sidebar `computePositions`). Order:
        -- equality (type) → FK group dimension → instrument → join key
        -- (transaction_id) → measure (quantity). Plan-pinning tests
        -- assert these covering indexes are used.
        CREATE INDEX leg_analysis_by_type_account
            ON transaction_leg(type, account_id, instrument_id, transaction_id, quantity);
        CREATE INDEX leg_analysis_by_type_category
            ON transaction_leg(type, category_id, instrument_id, transaction_id, quantity)
            WHERE category_id IS NOT NULL;
        CREATE INDEX leg_analysis_by_earmark_type
            ON transaction_leg(earmark_id, type, instrument_id, transaction_id, quantity)
            WHERE earmark_id IS NOT NULL;
        """)
  }

  private static func createInvestmentValueTable(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE investment_value (
            id                     BLOB    NOT NULL PRIMARY KEY,
            record_name            TEXT    NOT NULL UNIQUE,
            account_id             BLOB    NOT NULL REFERENCES account(id) ON DELETE CASCADE,
            date                   TEXT    NOT NULL,
            value                  INTEGER NOT NULL,
            instrument_id          TEXT    NOT NULL,
            encoded_system_fields  BLOB
        ) STRICT;

        -- Covering for the daily-balance latest-value-per-account-per-date
        -- lookup driven by `fetchDailyBalances` and the paginated
        -- per-account reads in `fetchValues(accountId:)`. The
        -- (account_id, date) prefix makes a separate narrow index
        -- redundant.
        CREATE INDEX iv_by_account_date_value
            ON investment_value(account_id, date, value, instrument_id);
        """)
  }
}
