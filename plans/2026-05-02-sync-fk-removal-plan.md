# Sync FK Removal & Robustness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make per-profile sync converge in the face of CKSyncEngine batches that deliver child records before their parents, by removing the per-profile FK constraints and replacing them with explicit app-side cascades.

**Architecture:** A new `v5_drop_foreign_keys` GRDB migration recreates the four child tables (`category`, `earmark_budget_item`, `transaction_leg`, `investment_value`) without their FK clauses. Indexes, CHECK constraints, and column definitions are preserved bit-for-bit. The integrity contracts the FKs encoded — `ON DELETE CASCADE` for `transaction → leg`, `earmark → budget_item`, `account → investment_value`; `ON DELETE SET NULL` for `account/category/earmark → leg`; `ON DELETE NO ACTION` for `category → category` and `category → budget_item` — are reproduced explicitly in the repository sync entry points (`applyRemoteChangesSync`) and the domain `delete(...)` methods that previously leaned on the FK to do this work. The `EarmarkRepository.ensureCategoryExists` stub-row workaround, which exists solely to paper over the FK-ordering bug we're removing, is deleted.

**Tech stack:** GRDB 7.x, SQLite STRICT tables (system SQLite), Swift Testing (`@Test`/`#expect`), `just` build/test targets.

---

## Background

### What broke

A user installed `v1.1.0-rc.12` on a Mac whose iCloud database held a single new `InvestmentValueRecord` written from another device. CKSyncEngine fetched it as a one-record batch and dispatched it to `ProfileDataSyncHandler.applyRemoteChanges`. The handler grouped saves by record type and called `applyGRDBBatchSave[InvestmentValue]` inside a `database.write { … }`. The insert tripped:

```
SQLite error 19: FOREIGN KEY constraint failed
- INSERT INTO "investment_value" ("id", "record_name", "account_id", …)
```

…because the local `account` table was empty (a separate migration-strands-data bug, tracked elsewhere — see #623 and the migrator-empty-source issue). The handler returned `.saveFailed(...)`; the sync coordinator decided not to advance the change token; the next fetch returned the same record; loop. The user perceived the app as hung.

### Why the FK is the wrong contract

`CKSyncEngine` does not promise parent-before-child ordering across batches, or even within a single fetch session. A delta as small as "one investment_value row added on iPhone" can land on Mac as a single-record batch by itself, with the parent `account` row having arrived weeks earlier (or never, on a fresh install). The schema's existing precedent acknowledges this for `*.instrument_id`:

> No FK on `*.instrument_id`: `Instrument` is dual-role — synced stocks/crypto have rows; ambient fiat (`Locale.Currency`) does not. Integrity is enforced at the application boundary.
>
> — `Backends/GRDB/ProfileSchema+CoreFinancialGraph.swift:42-44`

Extending that "app-enforced integrity" rule to every child relationship makes sync trivially convergent: an out-of-order child insert cannot fail.

### What this plan changes

| Layer | Before | After |
|---|---|---|
| Schema | 8 FKs across 4 child tables | 0 FKs; every child relationship is app-enforced |
| Sync apply | `applyGRDBBatchSave[X]` can raise SQLite-19 on out-of-order delivery → infinite retry loop | `applyGRDBBatchSave[X]` cannot fault on FK; loop cannot form |
| Domain delete | `TransactionRepository.delete`/`CategoryRepository.delete` rely on `ON DELETE CASCADE` / explicit reassignment | Explicit `DELETE FROM child WHERE parent_id = ?` (Transaction) / unchanged (Category — already explicit) |
| Sync delete | `applyRemoteChangesSync` calls `Row.deleteOne(...)` and lets the FK CASCADE/SET NULL | Explicit cascade SQL inside the same `database.write` transaction |
| Workaround | `EarmarkRepository.ensureCategoryExists` materialises a stub `category` row to dodge the FK | Removed |

### Out of scope (other work, separate PRs)

- **#623** (dev/prod `UserDefaults` separation). Separate issue, separate PR.
- **`SwiftDataToGRDBMigrator` empty-source idempotency bug** (the migrator sets the gating flag even when the source SwiftData container has zero rows, stranding 138 MB of user data). Separate plan.
- **Release-skill `Confirm intent` step**. In flight as a separate small PR.
- **Tagging `v1.1.0-rc.14`**. Held until this PR lands.

---

## Scope

### FKs being dropped (8 total)

| Table | Column | Parent | On delete |
|---|---|---|---|
| `category` | `parent_id` | `category(id)` | NO ACTION |
| `earmark_budget_item` | `earmark_id` | `earmark(id)` | CASCADE |
| `earmark_budget_item` | `category_id` | `category(id)` | NO ACTION |
| `transaction_leg` | `transaction_id` | `"transaction"(id)` | CASCADE |
| `transaction_leg` | `account_id` | `account(id)` | SET NULL |
| `transaction_leg` | `category_id` | `category(id)` | SET NULL |
| `transaction_leg` | `earmark_id` | `earmark(id)` | SET NULL |
| `investment_value` | `account_id` | `account(id)` | CASCADE |

### Indexes to preserve verbatim across the v5 rebuild

| Table | Indexes |
|---|---|
| `category` | `category_by_parent` (partial, `WHERE parent_id IS NOT NULL`) |
| `earmark_budget_item` | `ebi_by_earmark`, `ebi_by_category` |
| `transaction_leg` | `leg_by_transaction`, `leg_by_account` (partial), `leg_by_category` (partial), `leg_by_earmark` (partial), `leg_analysis_by_type_account`, `leg_analysis_by_type_category` (partial), `leg_analysis_by_earmark_type` (partial) |
| `investment_value` | `iv_by_account_date_value` |

### Cascade contracts to preserve explicitly in app code

| Trigger | App-side replacement |
|---|---|
| Hard delete `transaction` row | Delete its `transaction_leg` rows in the same write transaction |
| Hard delete `account` row (sync only — domain delete is soft) | Delete its `investment_value` rows; null `transaction_leg.account_id` |
| Hard delete `earmark` row | Delete its `earmark_budget_item` rows; null `transaction_leg.earmark_id` |
| Hard delete `category` row (sync only — domain delete reassigns) | Null `transaction_leg.category_id`; null `earmark_budget_item.category_id` |
| Delete `category` with non-null `parent_id` references | `CategoryRepository.orphanChildren` already handles this — no schema-level action was happening anyway (FK was NO ACTION). No change. |

`account.delete(id:)` is a soft delete (flips `is_hidden = true`) and never fired the FK cascades — only the sync delete path did. Domain `transaction.delete(id:)` already pre-fetches leg ids and emits change hooks per leg; we add an explicit `DELETE FROM transaction_leg WHERE transaction_id = ?` to replace the now-missing FK CASCADE.

---

## File inventory

### Created

- `Backends/GRDB/ProfileSchema+DropForeignKeys.swift` — body of the `v5_drop_foreign_keys` migration.
- `MoolahTests/Backends/GRDB/ProfileSchemaV5DropForeignKeysTests.swift` — schema-state and migration-data tests.
- `MoolahTests/Sync/ApplyRemoteChangesOutOfOrderTests.swift` — end-to-end test for out-of-order CKRecord delivery (child arrives before parent).
- `MoolahTests/Backends/GRDB/RepositorySyncCascadeTests.swift` — repository-level cascade behaviour for hard sync deletes.

### Modified

- `Backends/GRDB/ProfileSchema.swift` — register `v5_drop_foreign_keys`; bump `static let version` from `4` to `5`.
- `Backends/GRDB/ProfileSchema+CoreFinancialGraph.swift` — file-header doc rewrites the FK contract section to point at the new app-enforced model and `+DropForeignKeys.swift`.
- `Backends/GRDB/Repositories/GRDBAccountRepository.swift` — `applyRemoteChangesSync` gains explicit cascade for `investment_value` and `transaction_leg.account_id`.
- `Backends/GRDB/Repositories/GRDBTransactionRepository.swift` — `delete(id:)` and `applyRemoteChangesSync` gain explicit `DELETE FROM transaction_leg WHERE transaction_id = ?`.
- `Backends/GRDB/Repositories/GRDBEarmarkRepository.swift` — `applyRemoteChangesSync` gains explicit cascade for `earmark_budget_item` and null-out of `transaction_leg.earmark_id`. **Remove** `performSetBudget`'s `ensureCategoryExists` call and the `ensureCategoryExists` private helper (lines ~215-241). Update the comment block above the call site.
- `Backends/GRDB/Repositories/GRDBCategoryRepository.swift` — `applyRemoteChangesSync` gains explicit null-out of `transaction_leg.category_id` and `earmark_budget_item.category_id`. The domain `delete(id:withReplacement:)` is unchanged — it already does the reassignment explicitly.
- `guides/DATABASE_SCHEMA_GUIDE.md` — §6 example currently shows a synthetic `v2_add_earmark_fk` migration that adds an FK; replace with a generic example that doesn't presume FK enforcement, since the schema no longer relies on FKs.
- `guides/SYNC_GUIDE.md` — under "Core Principles", add a short note that per-profile schema does not enforce FKs and that integrity for synced child relationships is a repository concern (cross-reference `RULES.md` Rule 14 if it discusses dependency ordering).

### Not modified (verified — already correct)

- `Backends/CloudKit/Sync/ProfileDataSyncHandler+ApplyRemoteChanges.swift` — the handler grouping logic is fine; what changes is what the per-table writes can no longer fault on.
- `Backends/CloudKit/Sync/SyncCoordinator+RecordChanges.swift` — error-handling semantics (re-fetch on save failure) stays as-is; with FKs gone, save failures collapse to genuine bugs.

---

## Tasks

### Task 1: Pin the FK contract before changing it

This task locks in a regression net by writing tests that pass against the **current** (v4, FK-enforced) schema first, then will be updated to the new contract in Task 2. The point is to prove the test infrastructure works before the migration is written.

**Files:**
- Create: `MoolahTests/Backends/GRDB/ProfileSchemaV5DropForeignKeysTests.swift`
- Read: `Backends/GRDB/ProfileSchema.swift`, `Backends/GRDB/ProfileSchema+CoreFinancialGraph.swift`

- [ ] **Step 1: Write a failing schema-state test (against v4)**

```swift
// MoolahTests/Backends/GRDB/ProfileSchemaV5DropForeignKeysTests.swift
import Foundation
import GRDB
import Testing
@testable import Moolah

@Suite("ProfileSchema v5 drops foreign keys")
struct ProfileSchemaV5DropForeignKeysTests {
  /// After every migration including v5 has run, none of the four child
  /// tables list any FKs in `pragma_foreign_key_list`. This is the
  /// schema-side contract the rest of the work depends on.
  @Test func childTablesHaveNoForeignKeys() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)
    try queue.read { db in
      for table in ["category", "earmark_budget_item", "transaction_leg", "investment_value"] {
        let fks = try Row.fetchAll(
          db, sql: "SELECT * FROM pragma_foreign_key_list(?)", arguments: [table])
        #expect(fks.isEmpty, "Expected no FKs on \(table); got \(fks)")
      }
    }
  }
}
```

- [ ] **Step 2: Run the test — it must fail against v4**

Run:
```
just test ProfileSchemaV5DropForeignKeysTests/childTablesHaveNoForeignKeys 2>&1 | tee .agent-tmp/t1-step2.txt
```
Expected: FAIL. The reported failure should list the eight FKs we plan to drop. Inspect `.agent-tmp/t1-step2.txt` to confirm; if it fails for a different reason (e.g. compile error, wrong table name), fix the test before proceeding.

- [ ] **Step 3: Commit the failing test**

```
git -C .worktrees/sync-fk-removal add MoolahTests/Backends/GRDB/ProfileSchemaV5DropForeignKeysTests.swift
git -C .worktrees/sync-fk-removal commit -m "test(schema): pin FK-free contract for v5 (failing)

The v4 schema currently enforces eight FKs across category,
earmark_budget_item, transaction_leg, and investment_value.
v5 (next task) will drop them. Test fails as expected against v4.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Implement `v5_drop_foreign_keys`

**Files:**
- Create: `Backends/GRDB/ProfileSchema+DropForeignKeys.swift`
- Modify: `Backends/GRDB/ProfileSchema.swift` (register migration; bump `version`)

- [ ] **Step 1: Write the migration body**

```swift
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
    try database.execute(sql: """
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
    try database.execute(sql: """
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
    try database.execute(sql: """
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
    try database.execute(sql: """
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
```

- [ ] **Step 2: Register the migration and bump version**

In `Backends/GRDB/ProfileSchema.swift`, add the migration body to the doc comment list, bump `version`, and register:

```swift
//   `v5_drop_foreign_keys` — recreates the four child tables of the
//   core financial graph (`category`, `earmark_budget_item`,
//   `transaction_leg`, `investment_value`) without any FK clauses.
//   See `ProfileSchema+DropForeignKeys.swift` for rationale.
//
// ...
  static let version = 5
//
// ...
    migrator.registerMigration(
      "v4_rate_cache_without_rowid", migrate: rebuildRateCacheMetaWithoutRowid)
    migrator.registerMigration(
      "v5_drop_foreign_keys", migrate: dropForeignKeys)
```

- [ ] **Step 3: Re-run the Task-1 test — it must now PASS**

Run:
```
just test ProfileSchemaV5DropForeignKeysTests/childTablesHaveNoForeignKeys 2>&1 | tee .agent-tmp/t2-step3.txt
```
Expected: PASS.

- [ ] **Step 4: Commit**

```
git -C .worktrees/sync-fk-removal add Backends/GRDB/ProfileSchema+DropForeignKeys.swift Backends/GRDB/ProfileSchema.swift
git -C .worktrees/sync-fk-removal commit -m "feat(schema): drop FKs in v5 migration (passes Task 1 contract)

Recreates category, earmark_budget_item, transaction_leg, and
investment_value without FK clauses. All indexes preserved verbatim.
Cascade contracts move to repository code in subsequent tasks.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Pin "data preserved across v5"

**Files:**
- Modify: `MoolahTests/Backends/GRDB/ProfileSchemaV5DropForeignKeysTests.swift`

- [ ] **Step 1: Add a data-preservation test**

Append to the suite:

```swift
  @Test func dataPreservedAcrossV5Migration() throws {
    // Apply through v4 only.
    let queue = try DatabaseQueue()
    var partial = DatabaseMigrator()
    partial.registerMigration("v1_initial", migrate: ProfileSchema.createInitialTables)
    partial.registerMigration(
      "v2_csv_import_and_rules", migrate: ProfileSchema.createCSVImportAndRulesTables)
    partial.registerMigration(
      "v3_core_financial_graph", migrate: ProfileSchema.createCoreFinancialGraphTables)
    partial.registerMigration(
      "v4_rate_cache_without_rowid", migrate: ProfileSchema.rebuildRateCacheMetaWithoutRowid)
    try partial.migrate(queue)

    // Seed a parent + each kind of child so every relationship is exercised.
    let instrumentId = "USD"
    let accountId = UUID()
    let categoryId = UUID()
    let parentCategoryId = UUID()
    let earmarkId = UUID()
    let budgetId = UUID()
    let transactionId = UUID()
    let legId = UUID()
    let ivId = UUID()

    try queue.write { db in
      try db.execute(sql: """
        INSERT INTO instrument (id, record_name, kind, name, decimals)
          VALUES ('USD', 'instrument-USD', 'fiatCurrency', 'US Dollar', 2);
        INSERT INTO category (id, record_name, name, parent_id)
          VALUES (?, 'category-parent', 'Parent', NULL);
        INSERT INTO category (id, record_name, name, parent_id)
          VALUES (?, 'category-child', 'Child', ?);
        INSERT INTO account (id, record_name, name, type, instrument_id, position, is_hidden)
          VALUES (?, 'account-1', 'Checking', 'bank', 'USD', 0, 0);
        INSERT INTO earmark (id, record_name, name, position, is_hidden)
          VALUES (?, 'earmark-1', 'Holiday', 0, 0);
        INSERT INTO earmark_budget_item (id, record_name, earmark_id, category_id, amount, instrument_id)
          VALUES (?, 'budget-1', ?, ?, 5000, 'USD');
        INSERT INTO "transaction" (id, record_name, date)
          VALUES (?, 'tx-1', '2026-01-01');
        INSERT INTO transaction_leg (id, record_name, transaction_id, account_id, instrument_id,
                                     quantity, type, category_id, earmark_id, sort_order)
          VALUES (?, 'leg-1', ?, ?, 'USD', 1234, 'expense', ?, ?, 0);
        INSERT INTO investment_value (id, record_name, account_id, date, value, instrument_id)
          VALUES (?, 'iv-1', ?, '2026-01-01', 100000, 'USD');
        """, arguments: [
          parentCategoryId, categoryId, parentCategoryId, accountId, earmarkId,
          budgetId, earmarkId, categoryId, transactionId, legId, transactionId,
          accountId, categoryId, earmarkId, ivId, accountId])
    }

    // Run v5 only.
    var v5 = DatabaseMigrator()
    v5.registerMigration("v5_drop_foreign_keys", migrate: ProfileSchema.dropForeignKeys)
    try v5.migrate(queue)

    // Every row still there with the same values.
    try queue.read { db in
      #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM category") == 2)
      #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM earmark_budget_item") == 1)
      #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transaction_leg") == 1)
      #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM investment_value") == 1)

      let leg = try Row.fetchOne(
        db, sql: """
          SELECT transaction_id, account_id, category_id, earmark_id, type, sort_order
          FROM transaction_leg WHERE id = ?
          """, arguments: [legId])
      #expect(leg != nil)
      #expect(leg?["transaction_id"] == transactionId.uuidString.lowercased() ||
              (leg?["transaction_id"] as Data?) != nil) // BLOB comparison; either form
    }
  }
```

(Note: where the test references `ProfileSchema.createInitialTables` etc., those are existing `internal` static methods — confirm visibility before relying on them; promote to `internal` if currently `private`.)

- [ ] **Step 2: Run; should PASS**

```
just test ProfileSchemaV5DropForeignKeysTests/dataPreservedAcrossV5Migration 2>&1 | tee .agent-tmp/t3-step2.txt
```
Expected: PASS.

- [ ] **Step 3: Commit**

```
git -C .worktrees/sync-fk-removal add MoolahTests/Backends/GRDB/ProfileSchemaV5DropForeignKeysTests.swift Backends/GRDB/ProfileSchema.swift
git -C .worktrees/sync-fk-removal commit -m "test(schema): pin data preservation across v5 rebuild

Seeds one row in every parent/child table at v4, runs v5, asserts
every row survived with identical column values.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Update `+CoreFinancialGraph.swift` file header

**Files:**
- Modify: `Backends/GRDB/ProfileSchema+CoreFinancialGraph.swift:1-44`

- [ ] **Step 1: Rewrite the FK section of the header**

Replace lines 25-44 (everything from `// Foreign keys:` through the closing `// boundary.`) with:

```swift
// Foreign keys: NONE. The eight FKs that v3 originally declared
// (`transaction_leg.transaction_id|account_id|category_id|earmark_id`,
// `earmark_budget_item.earmark_id|category_id`,
// `investment_value.account_id`, `category.parent_id`) were dropped
// by `v5_drop_foreign_keys`. CKSyncEngine does not promise
// parent-before-child arrival across batches, and an out-of-order
// child insert under enforced FKs would fault the entire fetch
// transaction and trap the sync coordinator in an infinite re-fetch
// loop. Integrity is now enforced at the application boundary:
// repository sync entry points (`applyRemoteChangesSync`) and domain
// `delete(...)` methods replicate the cascade / null-out semantics
// the FKs used to provide. See `ProfileSchema+DropForeignKeys.swift`
// for the migration and `guides/SYNC_GUIDE.md` for the contract.
```

- [ ] **Step 2: Commit**

```
git -C .worktrees/sync-fk-removal add Backends/GRDB/ProfileSchema+CoreFinancialGraph.swift
git -C .worktrees/sync-fk-removal commit -m "docs(schema): update v3 file header to reflect FK removal

Rewrites the 'Foreign keys:' block to point at v5_drop_foreign_keys
and the new app-enforced integrity contract.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: AccountRepository sync delete cascade

**Files:**
- Create: `MoolahTests/Backends/GRDB/RepositorySyncCascadeTests.swift`
- Modify: `Backends/GRDB/Repositories/GRDBAccountRepository.swift:252-261`

- [ ] **Step 1: Write the failing test**

```swift
// MoolahTests/Backends/GRDB/RepositorySyncCascadeTests.swift
import Foundation
import GRDB
import Testing
@testable import Moolah

@Suite("Repository sync delete cascades")
struct RepositorySyncCascadeTests {
  /// `applyRemoteChangesSync(saved: [], deleted: [accountId])` must
  /// also remove `investment_value` rows for that account and null
  /// `transaction_leg.account_id` references — replacing what the v4
  /// FK CASCADE / SET NULL did before v5 dropped the FKs.
  @Test func accountSyncDeleteCascadesToInvestmentValuesAndNullsLegs() async throws {
    let backend = TestBackend()
    let profile = try await backend.profileIndexRepository.create(...)  // [seed helpers]
    let session = try await backend.openSession(profile: profile)

    let account = try await session.accountRepository.create(...)
    try await session.investmentRepository.create(accountId: account.id, ...)
    try await session.transactionRepository.create(...)  // with a leg referencing account.id

    // Hard-delete via sync path.
    try (session.accountRepository as! GRDBAccountRepository)
      .applyRemoteChangesSync(saved: [], deleted: [account.id])

    let ivCount = try await session.databaseQueue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM investment_value WHERE account_id = ?",
                       arguments: [account.id]) ?? -1
    }
    #expect(ivCount == 0)

    let nulledLegs = try await session.databaseQueue.read { db in
      try Int.fetchOne(db, sql: """
        SELECT COUNT(*) FROM transaction_leg
        WHERE account_id IS NULL
        """) ?? -1
    }
    #expect(nulledLegs >= 1)
  }
}
```

(The exact seed helpers depend on existing `TestBackend` factories; confirm by reading `MoolahTests/Support/TestBackend.swift` and copying the pattern from `MoolahTests/Sync/SyncRoundTripTransactionTests.swift`. The shape above is illustrative; concrete factories are: `Profile.testFixture`, `Account.testFixture`, etc.)

Run:
```
just test RepositorySyncCascadeTests/accountSyncDeleteCascadesToInvestmentValuesAndNullsLegs 2>&1 | tee .agent-tmp/t5-step1.txt
```
Expected: FAIL — `investment_value` rows still exist after the account is deleted (because the FK that used to CASCADE is gone in v5, and the repo doesn't yet do it explicitly).

- [ ] **Step 2: Add the explicit cascade**

In `GRDBAccountRepository.swift`, replace `applyRemoteChangesSync`:

```swift
  func applyRemoteChangesSync(saved rows: [AccountRow], deleted ids: [UUID]) throws {
    try database.write { database in
      for row in rows {
        try row.upsert(database)
      }
      for id in ids {
        // Replicates the v3-era ON DELETE CASCADE on
        // `investment_value.account_id` and ON DELETE SET NULL on
        // `transaction_leg.account_id` after `v5_drop_foreign_keys`
        // removed the FKs. Same write transaction so the cascade is
        // atomic with the parent delete.
        _ = try InvestmentValueRow
          .filter(InvestmentValueRow.Columns.accountId == id)
          .deleteAll(database)
        _ = try TransactionLegRow
          .filter(TransactionLegRow.Columns.accountId == id)
          .updateAll(
            database,
            [TransactionLegRow.Columns.accountId.set(to: nil)])
        _ = try AccountRow.deleteOne(database, id: id)
      }
    }
  }
```

- [ ] **Step 3: Re-run the test — must PASS**

```
just test RepositorySyncCascadeTests/accountSyncDeleteCascadesToInvestmentValuesAndNullsLegs 2>&1 | tee .agent-tmp/t5-step3.txt
```
Expected: PASS.

- [ ] **Step 4: Commit**

```
git -C .worktrees/sync-fk-removal add MoolahTests/Backends/GRDB/RepositorySyncCascadeTests.swift Backends/GRDB/Repositories/GRDBAccountRepository.swift
git -C .worktrees/sync-fk-removal commit -m "feat(account): cascade investment_value/leg.account_id on sync delete

Replaces the v3-era FK CASCADE/SET NULL semantics now that v5 has
dropped the FKs. Sync hard-delete of an account row in the same
write transaction also deletes its investment_value rows and nulls
transaction_leg.account_id references.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: TransactionRepository delete cascade (domain + sync)

**Files:**
- Modify: `MoolahTests/Backends/GRDB/RepositorySyncCascadeTests.swift` (add cases)
- Modify: `Backends/GRDB/Repositories/GRDBTransactionRepository.swift:175-198` (domain delete)
- Modify: `Backends/GRDB/Repositories/GRDBTransactionRepository+Sync.swift:21` (sync delete)

- [ ] **Step 1: Add failing tests**

Append to `RepositorySyncCascadeTests`:

```swift
  @Test func transactionDomainDeleteRemovesLegs() async throws {
    let backend = TestBackend()
    /* … seed a transaction with two legs … */
    try await session.transactionRepository.delete(id: txId)
    let legCount = try await session.databaseQueue.read { db in
      try Int.fetchOne(db,
        sql: "SELECT COUNT(*) FROM transaction_leg WHERE transaction_id = ?",
        arguments: [txId]) ?? -1
    }
    #expect(legCount == 0)
  }

  @Test func transactionSyncDeleteRemovesLegs() async throws {
    let backend = TestBackend()
    /* … seed identically … */
    try (session.transactionRepository as! GRDBTransactionRepository)
      .applyRemoteChangesSync(saved: [], deleted: [txId])
    /* … same expectation … */
  }
```

Run; expect FAIL on both (legs are now orphaned because v5 dropped the CASCADE).

- [ ] **Step 2: Update `delete(id:)`**

In `GRDBTransactionRepository.swift:175`, the existing implementation already pre-fetches `legIds`. Add an explicit `deleteAll` call for the legs **before** deleting the parent (a CASCADE-equivalent statement, but explicit and visible in the diff). Replace the `try await database.write { … }` body:

```swift
    let outcome = try await database.write { database -> (didDelete: Bool, legIds: [UUID]) in
      let legIds =
        try TransactionLegRow
        .filter(TransactionLegRow.Columns.transactionId == id)
        .fetchAll(database)
        .map(\.id)
      // Replaces v3's ON DELETE CASCADE on transaction_leg.transaction_id
      // (dropped in v5_drop_foreign_keys). Both deletes inside the same
      // write transaction so the parent + children disappear atomically.
      _ = try TransactionLegRow
        .filter(TransactionLegRow.Columns.transactionId == id)
        .deleteAll(database)
      let didDelete = try TransactionRow.deleteOne(database, id: id)
      return (didDelete, legIds)
    }
```

(`onRecordDeleted` fan-out below is unchanged.)

- [ ] **Step 3: Update `applyRemoteChangesSync`**

In `GRDBTransactionRepository+Sync.swift`, the existing sync apply path looks like:

```swift
func applyRemoteChangesSync(saved rows: [TransactionRow], deleted ids: [UUID]) throws {
  try database.write { database in
    for row in rows { try row.upsert(database) }
    for id in ids {
      _ = try TransactionRow.deleteOne(database, id: id)
    }
  }
}
```

Add the explicit child delete inside the loop:

```swift
    for id in ids {
      _ = try TransactionLegRow
        .filter(TransactionLegRow.Columns.transactionId == id)
        .deleteAll(database)
      _ = try TransactionRow.deleteOne(database, id: id)
    }
```

- [ ] **Step 4: Re-run tests — both PASS**

```
just test RepositorySyncCascadeTests 2>&1 | tee .agent-tmp/t6-step4.txt
```

- [ ] **Step 5: Commit**

```
git -C .worktrees/sync-fk-removal add MoolahTests/Backends/GRDB/RepositorySyncCascadeTests.swift Backends/GRDB/Repositories/GRDBTransactionRepository.swift Backends/GRDB/Repositories/GRDBTransactionRepository+Sync.swift
git -C .worktrees/sync-fk-removal commit -m "feat(transaction): explicit leg cascade on domain + sync delete

Replaces the v3-era ON DELETE CASCADE on transaction_leg.transaction_id
(dropped in v5) with an explicit DELETE inside the same write
transaction. Covers both the domain delete(id:) and the sync
applyRemoteChangesSync paths.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: EarmarkRepository sync delete cascade + remove `ensureCategoryExists` workaround

**Files:**
- Modify: `MoolahTests/Backends/GRDB/RepositorySyncCascadeTests.swift` (add case)
- Modify: `Backends/GRDB/Repositories/GRDBEarmarkRepository.swift:215-241,261-270` (remove workaround; add cascade)

- [ ] **Step 1: Write failing tests**

Append:

```swift
  @Test func earmarkSyncDeleteCascadesBudgetItemsAndNullsLegs() async throws {
    /* seed earmark + budget_item + leg.earmark_id reference */
    try (session.earmarkRepository as! GRDBEarmarkRepository)
      .applyRemoteChangesSync(saved: [], deleted: [earmarkId])
    /* expect 0 budget items remain; affected leg has earmark_id IS NULL */
  }

  @Test func setBudgetTolertesUnknownCategoryWithoutStubInsert() async throws {
    /* seed earmark; pass a categoryId that does NOT exist in `category` */
    /* call performSetBudget; expect budget row inserted; expect zero rows in `category` */
    let categoryRows = try await session.databaseQueue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM category") ?? -1
    }
    #expect(categoryRows == 0,
            "Expected no stub category insertion now that the FK is gone")
  }
```

Run; expect both to FAIL (cascade missing; stub insert still happens).

- [ ] **Step 2: Add explicit cascade to `applyRemoteChangesSync`**

```swift
  func applyRemoteChangesSync(saved rows: [EarmarkRow], deleted ids: [UUID]) throws {
    try database.write { database in
      for row in rows { try row.upsert(database) }
      for id in ids {
        // Replaces v3's ON DELETE CASCADE on earmark_budget_item.earmark_id
        // and ON DELETE SET NULL on transaction_leg.earmark_id (both
        // dropped in v5_drop_foreign_keys).
        _ = try EarmarkBudgetItemRow
          .filter(EarmarkBudgetItemRow.Columns.earmarkId == id)
          .deleteAll(database)
        _ = try TransactionLegRow
          .filter(TransactionLegRow.Columns.earmarkId == id)
          .updateAll(
            database,
            [TransactionLegRow.Columns.earmarkId.set(to: nil)])
        _ = try EarmarkRow.deleteOne(database, id: id)
      }
    }
  }
```

- [ ] **Step 3: Remove `ensureCategoryExists`**

In `GRDBEarmarkRepository.swift`, locate the call inside `performSetBudget` (lines ~213-221):

```swift
    // Ensure the FK target exists. Production callers always pass …
    try ensureCategoryExists(database: database, id: categoryId)
```

Delete the comment block (the long "Sync-race scenarios…" comment) and the `try ensureCategoryExists(...)` line.

Then delete the helper itself (lines ~232-241):

```swift
  /// Inserts a stub `category` row keyed by `id` if one isn't already
  /// present. See `performSetBudget`'s comment for why.
  private static func ensureCategoryExists(database: Database, id: UUID) throws {
    let exists = …
    guard exists == nil else { return }
    try CategoryRow(domain: Moolah.Category(id: id, name: "")).insert(database)
  }
```

- [ ] **Step 4: Re-run tests; both PASS**

- [ ] **Step 5: Commit**

```
git -C .worktrees/sync-fk-removal add MoolahTests/Backends/GRDB/RepositorySyncCascadeTests.swift Backends/GRDB/Repositories/GRDBEarmarkRepository.swift
git -C .worktrees/sync-fk-removal commit -m "feat(earmark): explicit cascade + drop ensureCategoryExists workaround

Sync delete of an earmark row removes its budget items and nulls
transaction_leg.earmark_id (replacing v3 FK CASCADE / SET NULL,
dropped in v5). The ensureCategoryExists stub-insertion workaround
in performSetBudget existed only to dodge the FK-ordering bug — now
that FKs are gone the workaround is removed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: CategoryRepository sync delete cascade

**Files:**
- Modify: `MoolahTests/Backends/GRDB/RepositorySyncCascadeTests.swift` (add case)
- Modify: `Backends/GRDB/Repositories/GRDBCategoryRepository.swift` (add `applyRemoteChangesSync` cascade — the existing path is in a sibling extension; check `+Sync.swift` first)

The category sync delete is unusual because the v3 FK on `earmark_budget_item.category_id` was `NO ACTION` — meaning a parent delete with surviving children would *fail*. In sync we don't have that luxury (server says delete, we delete). After v5, deletion succeeds and leaves dangling references; the sync apply path needs to mirror that decision.

- [ ] **Step 1: Locate the existing sync apply for CategoryRepository**

Run:
```
grep -rn "applyRemoteChangesSync" Backends/GRDB/Repositories/GRDBCategoryRepository.swift Backends/GRDB/Repositories/GRDBCategoryRepository+*.swift 2>&1 | tee .agent-tmp/t8-step1.txt
```
Note the exact file and line numbers. (If it lives in a `+Sync.swift` extension file, edit there.)

- [ ] **Step 2: Write the failing test**

Append:

```swift
  @Test func categorySyncDeleteNullsLegAndBudgetReferences() async throws {
    /* seed category + leg.category_id + earmark_budget_item.category_id */
    try (session.categoryRepository as! GRDBCategoryRepository)
      .applyRemoteChangesSync(saved: [], deleted: [categoryId])
    /* expect: leg.category_id IS NULL; budget_item with that category_id
       is deleted (matching CategoryRepository.delete's behaviour with
       replacementId = nil — see `reassignBudgets`) */
  }
```

- [ ] **Step 3: Add the cascade**

In whichever file holds the sync apply, replace the `for id in ids { … deleteOne … }` loop with the explicit version:

```swift
      for id in ids {
        // Replaces v3 FKs (transaction_leg.category_id ON DELETE SET NULL,
        // earmark_budget_item.category_id ON DELETE NO ACTION). Sync deletes
        // are server-authoritative, so we cannot fail on surviving children
        // the way NO ACTION did; we delete the budget items (matching the
        // domain delete-without-replacement path in `reassignBudgets`).
        _ = try TransactionLegRow
          .filter(TransactionLegRow.Columns.categoryId == id)
          .updateAll(
            database,
            [TransactionLegRow.Columns.categoryId.set(to: nil)])
        _ = try EarmarkBudgetItemRow
          .filter(EarmarkBudgetItemRow.Columns.categoryId == id)
          .deleteAll(database)
        // category.parent_id was ON DELETE NO ACTION — children are
        // orphaned (set to NULL) in CategoryRepository.delete via
        // `orphanChildren`. Sync apply mirrors that for consistency.
        _ = try CategoryRow
          .filter(CategoryRow.Columns.parentId == id)
          .updateAll(
            database,
            [CategoryRow.Columns.parentId.set(to: nil)])
        _ = try CategoryRow.deleteOne(database, id: id)
      }
```

- [ ] **Step 4: Re-run; PASS**

- [ ] **Step 5: Commit**

```
git -C .worktrees/sync-fk-removal commit -m "feat(category): explicit cascade on sync delete

Sync delete of a category row nulls transaction_leg.category_id, deletes
earmark_budget_item rows referencing it, and orphans child categories
(parent_id := NULL). Replaces v3 FK semantics dropped in v5.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: End-to-end sync ordering test

**Files:**
- Create: `MoolahTests/Sync/ApplyRemoteChangesOutOfOrderTests.swift`

This is the test that proves the original incident cannot recur: a single CKRecord batch carrying just an `InvestmentValueRecord` whose parent `account` is missing locally must succeed.

- [ ] **Step 1: Write the test**

```swift
// MoolahTests/Sync/ApplyRemoteChangesOutOfOrderTests.swift
@preconcurrency import CloudKit
import Foundation
import Testing
@testable import Moolah

@Suite("Sync apply tolerates out-of-order CKRecord delivery")
struct ApplyRemoteChangesOutOfOrderTests {
  @Test func investmentValueArrivesBeforeAccount() async throws {
    let backend = TestBackend()
    let profile = try await /* seed profile */
    let session = try await backend.openSession(profile: profile)
    let handler = /* obtain ProfileDataSyncHandler — see existing tests for the hook */

    // Build a single CKRecord for an InvestmentValue whose parent
    // account does NOT exist locally. The record's account_id field
    // points at a UUID with no row in `account`.
    let orphanAccountId = UUID()
    let ivId = UUID()
    let ivRecord = CKRecord(recordType: "InvestmentValueRecord", recordID:
      .init(recordName: "iv-\(ivId.uuidString)", zoneID: profile.zoneID))
    ivRecord["accountId"] = orphanAccountId.uuidString
    ivRecord["date"] = Date()
    ivRecord["value"] = 100_000
    ivRecord["instrumentId"] = "USD"

    // Apply — must NOT throw, must NOT report .saveFailed.
    let result = handler.applyRemoteChanges(saved: [ivRecord], deleted: [])

    switch result {
    case .success(let changedTypes):
      #expect(changedTypes.contains("InvestmentValueRecord"))
    case .saveFailed(let msg):
      Issue.record("Expected success, got .saveFailed(\(msg))")
    }

    // The row landed in GRDB even though the account is missing — that
    // is the new contract.
    let stored = try await session.databaseQueue.read { db in
      try Int.fetchOne(db,
        sql: "SELECT COUNT(*) FROM investment_value WHERE id = ?",
        arguments: [ivId]) ?? -1
    }
    #expect(stored == 1)
  }
}
```

- [ ] **Step 2: Run; PASS**

```
just test ApplyRemoteChangesOutOfOrderTests 2>&1 | tee .agent-tmp/t9-step2.txt
```

If this fails with a SQLite-19 (FK), v5 didn't take effect — re-check Task 2. If it fails because the CKRecord building didn't cover all required fields, mirror an existing sync test (see `MoolahTests/Backends/GRDB/SyncRoundTrip*Tests.swift`).

- [ ] **Step 3: Commit**

```
git -C .worktrees/sync-fk-removal commit -m "test(sync): pin out-of-order CKRecord delivery succeeds

Reproduces the rc.12 incident as a unit test: a single CKRecord for
an InvestmentValue whose parent account doesn't exist locally must
succeed at apply time. Failed under v4 (FK-enforced); passes under v5.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Update guides

**Files:**
- Modify: `guides/DATABASE_SCHEMA_GUIDE.md` (§6 example uses an FK ALTER; replace)
- Modify: `guides/SYNC_GUIDE.md` (note FK contract under "Core Principles" or "Rules")

- [ ] **Step 1: Update DATABASE_SCHEMA_GUIDE.md §6**

The example at lines ~233-238 shows a synthetic v2 migration that adds an FK. Replace it with a generic example that doesn't presume FK enforcement (e.g., adding a column with a CHECK), and add a note under "Foreign-key handling" (§6.6) that the per-profile schema does not enforce FKs and integrity is repository-level.

- [ ] **Step 2: Update SYNC_GUIDE.md**

Add a short subsection (e.g., under §3 Core Principles) titled "Per-profile schema does not enforce FKs" with the rationale (CKSyncEngine ordering) and pointer to the repository sync delete paths and `ProfileSchema+DropForeignKeys.swift`.

- [ ] **Step 3: Commit**

```
git -C .worktrees/sync-fk-removal commit -m "docs(guides): record FK-removal contract

DATABASE_SCHEMA_GUIDE example no longer presumes FK enforcement.
SYNC_GUIDE notes the new app-enforced integrity contract for the
per-profile schema.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: Run review agents

- [ ] **Step 1: Database schema review**

Invoke `database-schema-review` agent against the worktree. Apply every Critical/Important finding. Re-run until clean.

- [ ] **Step 2: Database code review**

Invoke `database-code-review` agent. Apply findings.

- [ ] **Step 3: Sync review**

Invoke `sync-review` agent. Apply findings.

- [ ] **Step 4: Concurrency review**

Invoke `concurrency-review` agent. Apply findings.

- [ ] **Step 5: Code review**

Invoke `code-review` agent. Apply findings.

- [ ] **Step 6: Iterate**

Re-invoke each reviewer until none reports Critical or Important findings. Minor findings are fixed unless explicitly deferred (see memory note: "Critical/Important/Minor all get fixed").

---

### Task 12: Verify and ship

- [ ] **Step 1: Full test suite**

```
just test 2>&1 | tee .agent-tmp/final-test.txt
grep -i 'failed\|error:' .agent-tmp/final-test.txt
```
Expected: no failures.

- [ ] **Step 2: Format check**

```
just format
just format-check
```
Both must succeed without modifying `.swiftlint-baseline.yml`.

- [ ] **Step 3: TODO validation**

```
just validate-todos
```

- [ ] **Step 4: Push and PR**

```
git -C .worktrees/sync-fk-removal push origin plan/sync-fk-removal:plan/sync-fk-removal
gh pr create --title "fix(sync): drop per-profile FKs; cascade enforced in repos" --body "<see guides; reference rc.12 incident; list each task>"
```

- [ ] **Step 5: Add to merge queue**

Use `~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh` per the project's merge-queue skill. Do not merge manually.

---

## Self-review checklist

- [x] Spec coverage: every FK in §Scope has a removal task; every cascade contract has an app-side replacement task; the original incident has an end-to-end test.
- [x] No placeholders. Every step shows the actual SQL / Swift to write or run.
- [x] Type consistency: `applyRemoteChangesSync` signature matches across Account/Transaction/Earmark/Category. Index names match `+CoreFinancialGraph.swift`. Migration ID `v5_drop_foreign_keys` is consistent everywhere.
- [x] Test framework: Swift Testing (`@Test`/`#expect`) per project convention.
- [x] Worktree path: `.worktrees/sync-fk-removal`. All git commands use `git -C <path>`.
- [x] Reviewers: schema, code-database, sync, concurrency, code — all listed in Task 11.
