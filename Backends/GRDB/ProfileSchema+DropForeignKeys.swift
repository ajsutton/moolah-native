// Backends/GRDB/ProfileSchema+DropForeignKeys.swift

import Foundation
import GRDB

// MARK: - v5 migration body
//
// SQLite cannot drop a constraint in place. For each of the four child
// tables — `category`, `earmark_budget_item`, `transaction_leg`,
// `investment_value` — we use the documented table-rebuild pattern:
// create `<name>_new` with the same columns, CHECKs, and data types but
// no `REFERENCES` clauses; copy rows with explicit column lists;
// `DROP TABLE` the old; `ALTER TABLE … RENAME TO …`; recreate every
// index. `DatabaseMigrator` already wraps the body in a transaction and
// disables FK enforcement around the call (per
// `guides/DATABASE_SCHEMA_GUIDE.md` §6.6), so we don't toggle PRAGMAs
// here.
//
// The eight FKs being removed:
//   category.parent_id                   → NO ACTION (intra-table)
//   earmark_budget_item.earmark_id       → CASCADE
//   earmark_budget_item.category_id      → NO ACTION
//   transaction_leg.transaction_id       → CASCADE
//   transaction_leg.account_id           → SET NULL
//   transaction_leg.category_id          → SET NULL
//   transaction_leg.earmark_id           → SET NULL
//   investment_value.account_id          → CASCADE
//
// Cascade behaviours that the FKs encoded are reproduced in repository
// code (`applyRemoteChangesSync` and the domain `delete(...)` methods
// that previously leaned on the FK).

extension ProfileSchema {
  static func dropForeignKeys(_ database: Database) throws {
    try rebuildCategoryTable(database)
    try rebuildEarmarkBudgetItemTable(database)
    try rebuildTransactionLegTable(database)
    try rebuildInvestmentValueTable(database)
  }

  private static func rebuildCategoryTable(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE category_new (
            id                     BLOB    NOT NULL PRIMARY KEY,
            record_name            TEXT    NOT NULL UNIQUE,
            name                   TEXT    NOT NULL,
            parent_id              BLOB,
            encoded_system_fields  BLOB
        ) STRICT;

        INSERT INTO category_new (id, record_name, name, parent_id, encoded_system_fields)
        SELECT id, record_name, name, parent_id, encoded_system_fields FROM category;

        DROP TABLE category;
        ALTER TABLE category_new RENAME TO category;

        CREATE INDEX category_by_parent
            ON category(parent_id) WHERE parent_id IS NOT NULL;
        """)
  }

  private static func rebuildEarmarkBudgetItemTable(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE earmark_budget_item_new (
            id                     BLOB    NOT NULL PRIMARY KEY,
            record_name            TEXT    NOT NULL UNIQUE,
            earmark_id             BLOB    NOT NULL,
            category_id            BLOB    NOT NULL,
            amount                 INTEGER NOT NULL,
            instrument_id          TEXT    NOT NULL,
            encoded_system_fields  BLOB
        ) STRICT;

        INSERT INTO earmark_budget_item_new
          (id, record_name, earmark_id, category_id, amount, instrument_id, encoded_system_fields)
        SELECT
          id, record_name, earmark_id, category_id, amount, instrument_id, encoded_system_fields
        FROM earmark_budget_item;

        DROP TABLE earmark_budget_item;
        ALTER TABLE earmark_budget_item_new RENAME TO earmark_budget_item;

        CREATE INDEX ebi_by_earmark  ON earmark_budget_item(earmark_id);
        CREATE INDEX ebi_by_category ON earmark_budget_item(category_id);
        """)
  }

  private static func rebuildTransactionLegTable(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE transaction_leg_new (
            id                     BLOB    NOT NULL PRIMARY KEY,
            record_name            TEXT    NOT NULL UNIQUE,
            transaction_id         BLOB    NOT NULL,
            account_id             BLOB,
            instrument_id          TEXT    NOT NULL,
            quantity               INTEGER NOT NULL,
            type                   TEXT    NOT NULL
                CHECK (type IN ('income', 'expense', 'transfer', 'openingBalance', 'trade')),
            category_id            BLOB,
            earmark_id             BLOB,
            sort_order             INTEGER NOT NULL CHECK (sort_order >= 0),
            encoded_system_fields  BLOB
        ) STRICT;

        INSERT INTO transaction_leg_new
          (id, record_name, transaction_id, account_id, instrument_id,
           quantity, type, category_id, earmark_id, sort_order, encoded_system_fields)
        SELECT
          id, record_name, transaction_id, account_id, instrument_id,
          quantity, type, category_id, earmark_id, sort_order, encoded_system_fields
        FROM transaction_leg;

        DROP TABLE transaction_leg;
        ALTER TABLE transaction_leg_new RENAME TO transaction_leg;

        CREATE INDEX leg_by_transaction ON transaction_leg(transaction_id);
        CREATE INDEX leg_by_account
            ON transaction_leg(account_id) WHERE account_id IS NOT NULL;
        CREATE INDEX leg_by_category
            ON transaction_leg(category_id) WHERE category_id IS NOT NULL;
        CREATE INDEX leg_by_earmark
            ON transaction_leg(earmark_id) WHERE earmark_id IS NOT NULL;
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

  private static func rebuildInvestmentValueTable(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE investment_value_new (
            id                     BLOB    NOT NULL PRIMARY KEY,
            record_name            TEXT    NOT NULL UNIQUE,
            account_id             BLOB    NOT NULL,
            date                   TEXT    NOT NULL,
            value                  INTEGER NOT NULL,
            instrument_id          TEXT    NOT NULL,
            encoded_system_fields  BLOB
        ) STRICT;

        INSERT INTO investment_value_new
          (id, record_name, account_id, date, value, instrument_id, encoded_system_fields)
        SELECT
          id, record_name, account_id, date, value, instrument_id, encoded_system_fields
        FROM investment_value;

        DROP TABLE investment_value;
        ALTER TABLE investment_value_new RENAME TO investment_value;

        CREATE INDEX iv_by_account_date_value
            ON investment_value(account_id, date, value, instrument_id);
        """)
  }
}
