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
- `MoolahTests/Backends/GRDB/RepositorySyncCascadeTests.swift` — repository-level cascade behaviour for hard sync deletes (Tasks 5–8) and the `ensureFKTargets` no-phantom-rows test (Task 6b).
- `MoolahTests/Backends/GRDB/TransactionDeleteRollbackTests.swift` — paired rollback test for `GRDBTransactionRepository.delete(id:)`, which becomes a multi-statement write under v5 (Task 6).

### Modified

- `Backends/GRDB/ProfileSchema.swift` — register `v5_drop_foreign_keys`; bump `static let version` from `4` to `5`. Promote any `private` migrator-body static methods (`createInitialTables`, `createCSVImportAndRulesTables`, `createCoreFinancialGraphTables`, `rebuildRateCacheMetaWithoutRowid`) to `internal` so the v5 data-preservation test in Task 3 can run them step-wise (Task 0).
- `Backends/GRDB/ProfileSchema+CoreFinancialGraph.swift` — file-header doc rewrites the FK contract section to point at the new app-enforced model. Adds an explicit paragraph about the zombie-row trade-off (a child whose parent CKRecord is never delivered remains as an orphan; this is intentional and accepted, not a bug).
- `Backends/GRDB/Repositories/GRDBAccountRepository.swift` — `applyRemoteChangesSync` gains explicit cascade for `investment_value` and `transaction_leg.account_id`.
- `Backends/GRDB/Repositories/GRDBTransactionRepository.swift` — `delete(id:)` body gains an explicit `DELETE FROM transaction_leg WHERE transaction_id = ?` (the `fetchAll(...).map(\.id)` for hook fan-out must precede the `deleteAll`, otherwise `legIds` is empty). The stale doc-comment at lines 175-180 (`// Legs cascade via the … FK with ON DELETE CASCADE`) and the file-level header at lines 14-16 referencing the FK CASCADE contract are rewritten to describe the explicit-delete contract.
- `Backends/GRDB/Repositories/GRDBTransactionRepository+Sync.swift` — `applyRemoteChangesSync` gains the same explicit `DELETE FROM transaction_leg` before `TransactionRow.deleteOne`.
- `Backends/GRDB/Repositories/GRDBTransactionRepository+FKEnsure.swift` — **Task 6b.** `ensureFKTargets` has four branches: instrument (read-time resolution for non-fiat — KEEP), account / category / earmark (FK-driven stubs — REMOVE). Function is renamed to `ensureInstrumentReadable` (or similar) to make the post-v5 scope obvious; the file header is rewritten to describe the remaining purpose (non-fiat instrument resolution under `fetchAll`), with no FK-ordering reference.
- `Backends/GRDB/Repositories/GRDBEarmarkRepository.swift` — `applyRemoteChangesSync` gains explicit cascade for `earmark_budget_item` and null-out of `transaction_leg.earmark_id`. **Remove** `performSetBudget`'s `ensureCategoryExists` call and the `ensureCategoryExists` private helper (lines ~215-241). Update the comment block above the call site.
- `Backends/GRDB/Repositories/GRDBCategoryRepository.swift` (or its `+Sync.swift` extension if the apply method lives there — verify in Task 8 Step 1) — `applyRemoteChangesSync` gains explicit null-out of `transaction_leg.category_id` and `earmark_budget_item.category_id`. The domain `delete(id:withReplacement:)` is unchanged — it already does the reassignment explicitly.
- `MoolahTests/Support/TestBackend.swift` — update the `ensureLegParents` (~lines 183-188) comment block: remove the FK-ordering justification ("under the GRDB schema's enforced FKs we have to materialise lightweight placeholder rows"). Whatever non-FK reason remains for placeholder seeding stays in the comment; if no reason remains, remove the helper entirely (verify by search after the production `ensureFKTargets` cleanup lands).
- `MoolahTests/Backends/GRDB/SyncRoundTripTransactionTests.swift` — update the `seedLegParents` (~lines 69-100) comment to clarify that parent seeding is now an *optional* setup detail (kept so existing assertions still hold), not a structural requirement of leg sync apply. Future tests of leg sync apply against a missing parent are added in Task 9.
- `guides/DATABASE_SCHEMA_GUIDE.md` — §6 example currently shows a synthetic `v2_add_earmark_fk` migration that adds an FK; replace with a generic example that doesn't presume FK enforcement (e.g., adding a column with a CHECK). The replacement **must** still demonstrate `registerMigration("vN_<name>", …)` with a stable string-literal ID so the §6.2 invariant remains visible in the example.
- `guides/SYNC_GUIDE.md` — under "Core Principles", add a subsection titled "Per-profile schema does not enforce FKs". Required content (three bullets, in order): (1) the no-FK contract and why (CKSyncEngine has no parent-before-child guarantee within or across batches); (2) sync delete paths in repositories must replicate the cascade / null-out semantics that the FKs used to provide — listed by repository; (3) zombie child rows (orphaned because the parent CKRecord was deleted server-side or never delivered) are an expected artefact of the FK-free design, not a bug; do not "fix" them by re-introducing FKs.

### Not modified (verified — already correct)

- `Backends/CloudKit/Sync/ProfileDataSyncHandler+ApplyRemoteChanges.swift` — the handler grouping logic is fine; what changes is what the per-table writes can no longer fault on.
- `Backends/CloudKit/Sync/SyncCoordinator+RecordChanges.swift` — error-handling semantics (re-fetch on save failure) stays as-is; with FKs gone, save failures collapse to genuine bugs.

---

## Tasks

### Task 0: Promote migrator-body visibility

The data-preservation test in Task 3 calls `ProfileSchema.createInitialTables`, `createCSVImportAndRulesTables`, `createCoreFinancialGraphTables`, `rebuildRateCacheMetaWithoutRowid`, and `dropForeignKeys` directly so it can run only the migrations up through v4 before exercising v5 in isolation. `@testable import Moolah` lifts `internal` visibility into the test target but does **not** lift `private`.

**Files:**
- Read: `Backends/GRDB/ProfileSchema.swift`, `Backends/GRDB/ProfileSchema+RateCaches.swift`, `Backends/GRDB/ProfileSchema+CSVImportAndRules.swift`, `Backends/GRDB/ProfileSchema+CoreFinancialGraph.swift`, `Backends/GRDB/ProfileSchema+RateCacheWithoutRowid.swift`
- Modify: any of the above whose `migrate:` body is currently `private`

- [ ] **Step 1: Survey access levels**

```
grep -n "static func createInitialTables\|static func createCSVImportAndRulesTables\|static func createCoreFinancialGraphTables\|static func rebuildRateCacheMetaWithoutRowid" Backends/GRDB/ProfileSchema*.swift
```

For each match, note the access level. The first keyword on the line tells you: a leading `private static func …` needs promotion; a bare `static func …` (= internal) is fine.

- [ ] **Step 2: Promote any `private` to `internal`**

Replace `private static func` with `static func` (delete the `private` keyword) for any matches that need it. Do not alter signatures or bodies.

- [ ] **Step 3: Build to confirm**

```
just build-mac 2>&1 | tee .agent-tmp/t0-step3.txt
grep -i 'error:' .agent-tmp/t0-step3.txt
```
Expected: no errors. `internal` is the default in Swift, so the change is a no-op for production callers (the migrator inside `ProfileSchema.swift` already calls these via `migrate:` references).

- [ ] **Step 4: Commit**

```
git -C .worktrees/sync-fk-removal add Backends/GRDB/ProfileSchema*.swift
git -C .worktrees/sync-fk-removal commit -m "chore(schema): promote v1-v4 migrator bodies to internal

Required by the v5 data-preservation test in Task 3, which runs
migrations through v4 in isolation before invoking v5. \`@testable
import\` lifts internal visibility but not private.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

If the survey in Step 1 finds every function is already `internal`, skip Steps 2-4 and note in the worktree.

---

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

(Visibility for these `static func` migrator bodies is enforced internal by Task 0; this task assumes that ran first.)

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

The existing pattern in `MoolahTests/Backends/GRDB/CSVImportRollbackTests.swift` and `CoreFinancialGraphRollbackTests.swift` is the canonical shape: open a fresh in-memory `ProfileDatabase`, construct the concrete GRDB repository against it, seed via direct row inserts, exercise, assert via `database.read { db in … }`. **Do not** introduce `session.accountRepository`, `backend.openSession`, or `session.databaseQueue` — none of those exist on the existing test surface.

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
    let database = try ProfileDatabase.openInMemory()
    let accountRepo = GRDBAccountRepository(database: database)
    let accountId = UUID()
    let legId = UUID()
    let txId = UUID()
    let ivId = UUID()

    try await database.write { db in
      try db.execute(sql: """
        INSERT INTO instrument (id, record_name, kind, name, decimals)
          VALUES ('USD', 'instrument-USD', 'fiatCurrency', 'US Dollar', 2);
        INSERT INTO account (id, record_name, name, type, instrument_id, position, is_hidden)
          VALUES (?, 'account-1', 'Checking', 'bank', 'USD', 0, 0);
        INSERT INTO "transaction" (id, record_name, date)
          VALUES (?, 'tx-1', '2026-01-01');
        INSERT INTO transaction_leg (id, record_name, transaction_id, account_id, instrument_id,
                                     quantity, type, sort_order)
          VALUES (?, 'leg-1', ?, ?, 'USD', 100, 'expense', 0);
        INSERT INTO investment_value (id, record_name, account_id, date, value, instrument_id)
          VALUES (?, 'iv-1', ?, '2026-01-01', 100000, 'USD');
        """, arguments: [accountId, txId, legId, txId, accountId, ivId, accountId])
    }

    // Hard-delete via sync path.
    try accountRepo.applyRemoteChangesSync(saved: [], deleted: [accountId])

    try await database.read { db in
      let ivCount = try Int.fetchOne(db,
        sql: "SELECT COUNT(*) FROM investment_value WHERE account_id = ?",
        arguments: [accountId]) ?? -1
      #expect(ivCount == 0)

      let nulledLegs = try Int.fetchOne(db,
        sql: "SELECT COUNT(*) FROM transaction_leg WHERE id = ? AND account_id IS NULL",
        arguments: [legId]) ?? -1
      #expect(nulledLegs == 1)
    }
  }
}
```

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

Append to `RepositorySyncCascadeTests` (mirror the Task-5 scaffold — `ProfileDatabase.openInMemory()` + direct repo construction; no `session.*`):

```swift
  @Test func transactionDomainDeleteRemovesLegs() async throws {
    let database = try ProfileDatabase.openInMemory()
    let txRepo = GRDBTransactionRepository(database: database)
    let txId = UUID()
    let leg1Id = UUID()
    let leg2Id = UUID()

    try await database.write { db in
      try db.execute(sql: """
        INSERT INTO instrument (id, record_name, kind, name, decimals)
          VALUES ('USD', 'instrument-USD', 'fiatCurrency', 'US Dollar', 2);
        INSERT INTO "transaction" (id, record_name, date)
          VALUES (?, 'tx-1', '2026-01-01');
        INSERT INTO transaction_leg (id, record_name, transaction_id, instrument_id,
                                     quantity, type, sort_order)
          VALUES (?, 'leg-1', ?, 'USD', 100, 'expense', 0);
        INSERT INTO transaction_leg (id, record_name, transaction_id, instrument_id,
                                     quantity, type, sort_order)
          VALUES (?, 'leg-2', ?, 'USD', -100, 'transfer', 1);
        """, arguments: [txId, leg1Id, txId, leg2Id, txId])
    }

    try await txRepo.delete(id: txId)

    try await database.read { db in
      let legCount = try Int.fetchOne(db,
        sql: "SELECT COUNT(*) FROM transaction_leg WHERE transaction_id = ?",
        arguments: [txId]) ?? -1
      #expect(legCount == 0)
    }
  }

  @Test func transactionSyncDeleteRemovesLegs() async throws {
    let database = try ProfileDatabase.openInMemory()
    let txRepo = GRDBTransactionRepository(database: database)
    let txId = UUID()
    let legId = UUID()

    try await database.write { db in
      try db.execute(sql: """
        INSERT INTO instrument (id, record_name, kind, name, decimals)
          VALUES ('USD', 'instrument-USD', 'fiatCurrency', 'US Dollar', 2);
        INSERT INTO "transaction" (id, record_name, date)
          VALUES (?, 'tx-1', '2026-01-01');
        INSERT INTO transaction_leg (id, record_name, transaction_id, instrument_id,
                                     quantity, type, sort_order)
          VALUES (?, 'leg-1', ?, 'USD', 100, 'expense', 0);
        """, arguments: [txId, legId, txId])
    }

    try txRepo.applyRemoteChangesSync(saved: [], deleted: [txId])

    try await database.read { db in
      let legCount = try Int.fetchOne(db,
        sql: "SELECT COUNT(*) FROM transaction_leg WHERE transaction_id = ?",
        arguments: [txId]) ?? -1
      #expect(legCount == 0)
    }
  }
```

Run; expect FAIL on both (legs are now orphaned because v5 dropped the CASCADE).

- [ ] **Step 2: Update `delete(id:)` and rewrite the stale FK comments**

Two edits to `Backends/GRDB/Repositories/GRDBTransactionRepository.swift`:

(a) Lines 175-180 — replace the `// Legs cascade via the …` doc-comment block on `delete(id:)` with:

```swift
  // Explicit delete of legs before the parent, replacing the v3-era
  // ON DELETE CASCADE on `transaction_leg.transaction_id` that v5
  // dropped (`v5_drop_foreign_keys`). The `fetchAll(...).map(\.id)`
  // for hook fan-out MUST precede `deleteAll(...)` — after the delete
  // the fetch returns empty and per-leg `onRecordDeleted` hooks
  // silently stop firing. Both deletes share the same write
  // transaction so the parent + children disappear atomically.
```

(b) Lines 14-16 (file-level header) — there is similar FK-CASCADE wording in the file's top doc-comment that becomes false after v5. Read lines 1-30 of the file and rewrite any reference to `ON DELETE CASCADE` to point at the explicit cascade in `delete(id:)` and the `applyRemoteChangesSync` site in `+Sync.swift`.

(c) The existing implementation pre-fetches `legIds`. Add an explicit `deleteAll` call for the legs **after** the fetch and **before** deleting the parent. Replace the `try await database.write { … }` body:

```swift
    let outcome = try await database.write { database -> (didDelete: Bool, legIds: [UUID]) in
      let legIds =
        try TransactionLegRow
        .filter(TransactionLegRow.Columns.transactionId == id)
        .fetchAll(database)
        .map(\.id)
      _ =
        try TransactionLegRow
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

- [ ] **Step 5: Add a paired rollback test**

`delete(id:)` is now a multi-statement write. Per `DATABASE_CODE_GUIDE.md` §5, every multi-statement write needs a paired test asserting that a thrown error inside the closure leaves the database unchanged. Mirror the existing patterns in `MoolahTests/Backends/GRDB/CoreFinancialGraphRollbackTests.swift`.

Create `MoolahTests/Backends/GRDB/TransactionDeleteRollbackTests.swift`:

```swift
import Foundation
import GRDB
import Testing
@testable import Moolah

@Suite("Transaction delete is atomic under failure")
struct TransactionDeleteRollbackTests {
  @Test func deleteRollsBackOnFailureAfterLegDelete() async throws {
    let database = try ProfileDatabase.openInMemory()
    let txRepo = GRDBTransactionRepository(database: database)
    let txId = UUID()
    let legId = UUID()

    try await database.write { db in
      // BEFORE-DELETE trigger on "transaction" raises ABORT,
      // simulating a write failure mid-transaction. SQL comments
      // inside the literal use `--`, not `//`, otherwise SQLite
      // returns a parse error before the seed completes.
      try db.execute(sql: """
        INSERT INTO instrument (id, record_name, kind, name, decimals)
          VALUES ('USD', 'instrument-USD', 'fiatCurrency', 'US Dollar', 2);
        INSERT INTO "transaction" (id, record_name, date)
          VALUES (?, 'tx-1', '2026-01-01');
        INSERT INTO transaction_leg (id, record_name, transaction_id, instrument_id,
                                     quantity, type, sort_order)
          VALUES (?, 'leg-1', ?, 'USD', 100, 'expense', 0);
        CREATE TRIGGER force_failure BEFORE DELETE ON "transaction"
        BEGIN
          SELECT RAISE(ABORT, 'forced failure for rollback test');
        END;
        """, arguments: [txId, legId, txId])
    }

    do {
      try await txRepo.delete(id: txId)
      Issue.record("Expected delete to throw")
    } catch {
      // Expected.
    }

    // Both rows must still exist — the explicit DELETE on transaction_leg
    // ran but the surrounding GRDB transaction must have rolled back.
    try await database.read { db in
      let txCount = try Int.fetchOne(db,
        sql: "SELECT COUNT(*) FROM \"transaction\" WHERE id = ?",
        arguments: [txId]) ?? -1
      #expect(txCount == 1)

      let legCount = try Int.fetchOne(db,
        sql: "SELECT COUNT(*) FROM transaction_leg WHERE id = ?",
        arguments: [legId]) ?? -1
      #expect(legCount == 1)
    }
  }
}
```

Run:
```
just test TransactionDeleteRollbackTests 2>&1 | tee .agent-tmp/t6-step5.txt
```
Expected: PASS. (`database.write { db in … }` is a single GRDB transaction — anything raised inside it rolls back the whole closure.)

- [ ] **Step 6: Commit**

```
git -C .worktrees/sync-fk-removal add MoolahTests/Backends/GRDB/RepositorySyncCascadeTests.swift MoolahTests/Backends/GRDB/TransactionDeleteRollbackTests.swift Backends/GRDB/Repositories/GRDBTransactionRepository.swift Backends/GRDB/Repositories/GRDBTransactionRepository+Sync.swift
git -C .worktrees/sync-fk-removal commit -m "feat(transaction): explicit leg cascade on domain + sync delete

Replaces the v3-era ON DELETE CASCADE on transaction_leg.transaction_id
(dropped in v5) with an explicit DELETE inside the same write
transaction. Covers both the domain delete(id:) and the sync
applyRemoteChangesSync paths. Adds the §5 paired rollback test for
the now-multi-statement delete(id:). Stale FK-CASCADE doc comments
on delete(id:) and the file header are rewritten.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 6b: Audit `ensureFKTargets` and remove FK-driven stub insertions

`Backends/GRDB/Repositories/GRDBTransactionRepository+FKEnsure.swift` defines a single helper called from `GRDBTransactionRepository.create` (line 131) and `performUpdate` (line 282). Its body has four conditional branches; only one survives v5.

The branches and their fates:

| Branch | Lines | Reason it exists | Fate after v5 |
|---|---|---|---|
| Instrument | 24-32 | Non-fiat instrument rows are required for `fetchAll` to resolve the full `Instrument` value (NOT FK-driven; `instrument_id` columns have no FK in any version of the schema) | **Keep** |
| Account | 33-43 | Stub row to satisfy the v3 FK `transaction_leg.account_id → account.id ON DELETE SET NULL` when a leg's CKRecord arrived before its account's | **Remove** |
| Category | 44-52 | Stub row to satisfy the v3 FK `transaction_leg.category_id → category.id ON DELETE SET NULL` | **Remove** |
| Earmark | 53-62 | Stub row to satisfy the v3 FK `transaction_leg.earmark_id → earmark.id ON DELETE SET NULL` | **Remove** |

Leaving the account / category / earmark stubs in place is a correctness hazard: a sync-delivered CKRecord for a leg whose parent hasn't yet arrived would insert a phantom blank-name row that could persist after the real CKRecord lands (the real one would upsert in place via the unique `id` PK, but only if it arrives — server-side deletes would leave the stub forever).

**Files:**
- Modify: `Backends/GRDB/Repositories/GRDBTransactionRepository+FKEnsure.swift`
- Modify: `MoolahTests/Backends/GRDB/RepositorySyncCascadeTests.swift` (add no-phantom-rows test)

- [ ] **Step 1: Write the failing no-phantom-rows test**

Append to `RepositorySyncCascadeTests`:

```swift
  /// After v5 + Task 6b, applying a CKRecord-equivalent leg upsert
  /// whose `account_id` / `category_id` / `earmark_id` reference rows
  /// that don't yet exist must NOT create blank-name stub rows. The
  /// FK-driven stub insertion in `ensureFKTargets` is removed; only
  /// the non-fiat instrument insertion survives.
  @Test func legUpsertWithMissingParentsDoesNotCreatePhantomRows() async throws {
    let database = try ProfileDatabase.openInMemory()
    let txRepo = GRDBTransactionRepository(database: database)
    let orphanAccountId = UUID()
    let orphanCategoryId = UUID()
    let orphanEarmarkId = UUID()

    let leg = TransactionLeg(
      /* … domain leg referencing the three orphan ids,
         instrument = USD (fiat — no instrument stub needed) … */)
    let tx = Transaction(/* … one leg … */)

    try await txRepo.create(tx)

    try await database.read { db in
      // No phantom blank-name rows.
      let accountCount = try Int.fetchOne(db,
        sql: "SELECT COUNT(*) FROM account WHERE id = ?",
        arguments: [orphanAccountId]) ?? -1
      #expect(accountCount == 0,
              "Expected no phantom account; found \(accountCount)")

      let categoryCount = try Int.fetchOne(db,
        sql: "SELECT COUNT(*) FROM category WHERE id = ?",
        arguments: [orphanCategoryId]) ?? -1
      #expect(categoryCount == 0)

      let earmarkCount = try Int.fetchOne(db,
        sql: "SELECT COUNT(*) FROM earmark WHERE id = ?",
        arguments: [orphanEarmarkId]) ?? -1
      #expect(earmarkCount == 0)
    }
  }
```

(Concrete `TransactionLeg` and `Transaction` initialiser shapes: copy from `MoolahTests/Backends/GRDB/SyncRoundTripTransactionTests.swift`.)

Run:
```
just test RepositorySyncCascadeTests/legUpsertWithMissingParentsDoesNotCreatePhantomRows 2>&1 | tee .agent-tmp/t6b-step1.txt
```
Expected: FAIL. The current `ensureFKTargets` will have inserted three stub rows.

- [ ] **Step 2: Remove the three FK-driven branches**

Replace the body of `ensureFKTargets` in `Backends/GRDB/Repositories/GRDBTransactionRepository+FKEnsure.swift` with only the instrument branch, and rename the function to make the post-v5 scope explicit:

```swift
// Backends/GRDB/Repositories/GRDBTransactionRepository+FKEnsure.swift

import Foundation
import GRDB

// Read-time instrument-resolution helper. Split out of
// `GRDBTransactionRepository` to keep the main class body under
// SwiftLint's `type_body_length` threshold.
//
// Non-fiat instrument rows must exist locally for `fetchAll` to
// resolve the full `Instrument` value when reading transactions. The
// `instrument_id` column has never had an FK and this helper has
// never been about FK enforcement for that column. Other parent
// references (`account_id`, `category_id`, `earmark_id`) had FKs in
// v3 that this helper used to dodge by inserting blank-name stubs
// when the parent CKRecord hadn't arrived yet. v5 dropped those FKs;
// the stubs are gone and a leg whose parent isn't in the local DB is
// allowed to land — see `guides/SYNC_GUIDE.md` "Per-profile schema
// does not enforce FKs" and the zombie-row trade-off documented in
// `ProfileSchema+CoreFinancialGraph.swift`.
extension GRDBTransactionRepository {
  /// Inserts a placeholder `instrument` row for any non-fiat
  /// instrument a leg references that isn't already present. Required
  /// so `fetchAll` can resolve the full `Instrument` domain value on
  /// read.
  static func ensureInstrumentReadable(
    database: Database,
    leg: TransactionLeg
  ) throws {
    guard leg.instrument.kind != .fiatCurrency else { return }
    let exists =
      try InstrumentRow
      .filter(InstrumentRow.Columns.id == leg.instrument.id)
      .fetchOne(database)
    guard exists == nil else { return }
    try InstrumentRow(domain: leg.instrument).insert(database)
  }
}
```

- [ ] **Step 3: Update the call sites**

Two call sites in `Backends/GRDB/Repositories/GRDBTransactionRepository.swift`:

(a) Line 131 (inside `create(_:)`): `try Self.ensureFKTargets(database: database, leg: leg, defaultInstrument: defaultInstrument)` becomes `try Self.ensureInstrumentReadable(database: database, leg: leg)`.

(b) Line 282 (inside `performUpdate(...)`): `try ensureFKTargets(database: database, leg: leg, defaultInstrument: defaultInstrument)` becomes `try Self.ensureInstrumentReadable(database: database, leg: leg)`.

The `defaultInstrument` parameter is no longer used by the helper; the call sites that previously passed it should drop the argument. If `defaultInstrument` was sourced from a containing call (e.g. `performUpdate`'s parameter), check whether it has any other use — if not, prune the parameter chain back to the public entry point.

- [ ] **Step 4: Re-run the test — must PASS**

```
just test RepositorySyncCascadeTests/legUpsertWithMissingParentsDoesNotCreatePhantomRows 2>&1 | tee .agent-tmp/t6b-step4.txt
```
Expected: PASS. Also re-run the existing transaction round-trip suite:
```
just test SyncRoundTripTransactionTests 2>&1 | tee .agent-tmp/t6b-step4-rt.txt
```
Expected: PASS. If any test fails because it relied on the implicit stub insertion (it shouldn't — the seeding helper `seedLegParents` already inserts real parents), update that test's seeding to be explicit.

- [ ] **Step 5: Commit**

```
git -C .worktrees/sync-fk-removal add Backends/GRDB/Repositories/GRDBTransactionRepository+FKEnsure.swift Backends/GRDB/Repositories/GRDBTransactionRepository.swift MoolahTests/Backends/GRDB/RepositorySyncCascadeTests.swift
git -C .worktrees/sync-fk-removal commit -m "refactor(transaction): drop FK-driven stub insertions; keep instrument resolution

ensureFKTargets had four branches: instrument (read-time non-fiat
resolution) and account / category / earmark (FK-driven blank-name
stubs to dodge the v3 FK ordering bug). v5 dropped those FKs; the
three FK branches are removed. Renames the helper to
ensureInstrumentReadable to make the post-v5 scope obvious. New
RepositorySyncCascadeTests case verifies that a leg insert with
unknown parent ids no longer creates phantom blank-name rows.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: EarmarkRepository sync delete cascade + remove `ensureCategoryExists` workaround

**Files:**
- Modify: `MoolahTests/Backends/GRDB/RepositorySyncCascadeTests.swift` (add case)
- Modify: `Backends/GRDB/Repositories/GRDBEarmarkRepository.swift:215-241,261-270` (remove workaround; add cascade)

- [ ] **Step 1: Write failing tests**

Append (using the same `ProfileDatabase.openInMemory()` + direct repo construction pattern as Tasks 5–6):

```swift
  @Test func earmarkSyncDeleteCascadesBudgetItemsAndNullsLegs() async throws {
    let database = try ProfileDatabase.openInMemory()
    let earmarkRepo = GRDBEarmarkRepository(database: database)
    let earmarkId = UUID()
    let categoryId = UUID()
    let budgetId = UUID()
    let txId = UUID()
    let legId = UUID()

    try await database.write { db in
      try db.execute(sql: """
        INSERT INTO instrument (id, record_name, kind, name, decimals)
          VALUES ('USD', 'instrument-USD', 'fiatCurrency', 'US Dollar', 2);
        INSERT INTO category (id, record_name, name) VALUES (?, 'cat-1', 'Food');
        INSERT INTO earmark (id, record_name, name, position, is_hidden)
          VALUES (?, 'earmark-1', 'Holiday', 0, 0);
        INSERT INTO earmark_budget_item (id, record_name, earmark_id, category_id, amount, instrument_id)
          VALUES (?, 'budget-1', ?, ?, 5000, 'USD');
        INSERT INTO "transaction" (id, record_name, date)
          VALUES (?, 'tx-1', '2026-01-01');
        INSERT INTO transaction_leg (id, record_name, transaction_id, instrument_id,
                                     quantity, type, earmark_id, sort_order)
          VALUES (?, 'leg-1', ?, 'USD', 100, 'expense', ?, 0);
        """, arguments: [categoryId, earmarkId, budgetId, earmarkId, categoryId,
                         txId, legId, txId, earmarkId])
    }

    try earmarkRepo.applyRemoteChangesSync(saved: [], deleted: [earmarkId])

    try await database.read { db in
      let budgetCount = try Int.fetchOne(db,
        sql: "SELECT COUNT(*) FROM earmark_budget_item WHERE earmark_id = ?",
        arguments: [earmarkId]) ?? -1
      #expect(budgetCount == 0)

      let nulledLeg = try Int.fetchOne(db,
        sql: "SELECT COUNT(*) FROM transaction_leg WHERE id = ? AND earmark_id IS NULL",
        arguments: [legId]) ?? -1
      #expect(nulledLeg == 1)
    }
  }

  @Test func setBudgetToleratesUnknownCategoryWithoutStubInsert() async throws {
    let database = try ProfileDatabase.openInMemory()
    let earmarkRepo = GRDBEarmarkRepository(database: database)
    let earmarkId = UUID()
    let unknownCategoryId = UUID()  // deliberately NOT inserted

    try await database.write { db in
      try db.execute(sql: """
        INSERT INTO instrument (id, record_name, kind, name, decimals)
          VALUES ('USD', 'instrument-USD', 'fiatCurrency', 'US Dollar', 2);
        INSERT INTO earmark (id, record_name, name, position, is_hidden)
          VALUES (?, 'earmark-1', 'Holiday', 0, 0);
        """, arguments: [earmarkId])
    }

    let amount = MonetaryAmount(/* … 5000 USD … */)
    try await earmarkRepo.setBudget(
      earmarkId: earmarkId, categoryId: unknownCategoryId, amount: amount)

    try await database.read { db in
      let categoryCount = try Int.fetchOne(db,
        sql: "SELECT COUNT(*) FROM category", arguments: []) ?? -1
      #expect(categoryCount == 0,
              "Expected no stub category row now that the FK is gone")

      let budgetCount = try Int.fetchOne(db,
        sql: "SELECT COUNT(*) FROM earmark_budget_item WHERE earmark_id = ?",
        arguments: [earmarkId]) ?? -1
      #expect(budgetCount == 1)
    }
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

Append (same `ProfileDatabase.openInMemory()` + direct repo construction pattern):

```swift
  @Test func categorySyncDeleteNullsLegAndBudgetReferences() async throws {
    let database = try ProfileDatabase.openInMemory()
    let categoryRepo = GRDBCategoryRepository(database: database)
    let categoryId = UUID()
    let earmarkId = UUID()
    let budgetId = UUID()
    let txId = UUID()
    let legId = UUID()

    try await database.write { db in
      try db.execute(sql: """
        INSERT INTO instrument (id, record_name, kind, name, decimals)
          VALUES ('USD', 'instrument-USD', 'fiatCurrency', 'US Dollar', 2);
        INSERT INTO category (id, record_name, name) VALUES (?, 'cat-1', 'Food');
        INSERT INTO earmark (id, record_name, name, position, is_hidden)
          VALUES (?, 'earmark-1', 'Holiday', 0, 0);
        INSERT INTO earmark_budget_item (id, record_name, earmark_id, category_id, amount, instrument_id)
          VALUES (?, 'budget-1', ?, ?, 5000, 'USD');
        INSERT INTO "transaction" (id, record_name, date)
          VALUES (?, 'tx-1', '2026-01-01');
        INSERT INTO transaction_leg (id, record_name, transaction_id, instrument_id,
                                     quantity, type, category_id, sort_order)
          VALUES (?, 'leg-1', ?, 'USD', 100, 'expense', ?, 0);
        """, arguments: [categoryId, earmarkId, budgetId, earmarkId, categoryId,
                         txId, legId, txId, categoryId])
    }

    try categoryRepo.applyRemoteChangesSync(saved: [], deleted: [categoryId])

    try await database.read { db in
      let nulledLeg = try Int.fetchOne(db,
        sql: "SELECT COUNT(*) FROM transaction_leg WHERE id = ? AND category_id IS NULL",
        arguments: [legId]) ?? -1
      #expect(nulledLeg == 1)

      let remainingBudgets = try Int.fetchOne(db,
        sql: "SELECT COUNT(*) FROM earmark_budget_item WHERE category_id = ?",
        arguments: [categoryId]) ?? -1
      #expect(remainingBudgets == 0)
    }
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

The CKRecord must be constructed via the project's existing record-mapping path (the same one CKSyncEngine uses on inbound delivery), not hand-rolled. Hand-rolling can omit required fields silently — the `id` field for `InvestmentValueRow` is one example; others may exist. Reuse the helper used by the existing `SyncRoundTrip*Tests`.

- [ ] **Step 1: Locate the existing CKRecord round-trip helper**

```
grep -rn "func toCKRecord\|CloudKitRecordConvertible\|func ckRecord" Backends/CloudKit/Sync 2>&1 | head -20
grep -rn "InvestmentValueRow\|investmentValueRecord" MoolahTests/Backends/GRDB/SyncRoundTrip*Tests.swift 2>&1 | head -20
```

The existing `SyncRoundTripTransactionTests.swift` and the `ProfileDataSyncHandlerTestSupport` (or equivalent) module shows how to build a `CKRecord` for a row type. Mirror that pattern. If a round-trip helper exists for `InvestmentValueRow` (likely via `CloudKitRecordConvertible` conformance), call it directly:

```swift
let ivRow = InvestmentValueRow(
  id: ivId,
  recordName: "InvestmentValueRecord|\(ivId.uuidString)",
  accountId: orphanAccountId,
  date: Date(),
  value: 100_000,
  instrumentId: "USD",
  encodedSystemFields: nil)
let ivRecord = ivRow.toCKRecord(in: zoneID)  // or the project's actual helper
```

If the project doesn't expose `toCKRecord` as such, find the `record(from:in:)` / `ckRecord(in:)` / equivalent mapping site under `Backends/CloudKit/Sync/` and use the same call shape the production sync handler uses. **Do not** assemble fields by name from scratch.

- [ ] **Step 2: Write the test**

`HandlerHarness` does NOT expose a `zoneID` property — only `handler`, `container`, and `database` (verified in `MoolahTests/Support/ProfileDataSyncHandlerTestSupport.swift`). Existing round-trip test suites that need a zone declare a suite-local `private static let zoneID = …` constant. Follow that pattern.

```swift
// MoolahTests/Sync/ApplyRemoteChangesOutOfOrderTests.swift
@preconcurrency import CloudKit
import Foundation
import Testing
@testable import Moolah

@Suite("Sync apply tolerates out-of-order CKRecord delivery")
struct ApplyRemoteChangesOutOfOrderTests {
  // Mirrors the suite-local zone constant used by every existing
  // round-trip test (e.g. SyncRoundTripTransactionTests). The handler
  // does not constrain which zone its records live in for apply
  // semantics; this just needs to be a valid CKRecordZone.ID.
  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  /// Reproduces the rc.12 incident as a unit test: a single CKRecord
  /// for an `InvestmentValueRow` whose parent `account` row doesn't
  /// exist locally must succeed at apply time. Failed under v4 (FK
  /// enforced); passes under v5.
  @Test func investmentValueArrivesBeforeAccount() async throws {
    // Use `ProfileDataSyncHandlerTestSupport` to obtain a handler
    // bound to a fresh in-memory ProfileDatabase. Harness exposes
    // `handler`, `container`, `database` — and nothing else; the
    // zone is declared at suite level above.
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    // No parent rows seeded — the database is fresh.

    let orphanAccountId = UUID()
    let ivId = UUID()
    let ivRow = InvestmentValueRow(
      id: ivId,
      recordName: InvestmentValueRow.recordName(for: ivId),
      accountId: orphanAccountId,
      date: Date(),
      value: 100_000,
      instrumentId: "USD",
      encodedSystemFields: nil)
    let ivRecord = ivRow.toCKRecord(in: Self.zoneID)  // or the project's actual helper

    // Apply — must NOT throw, must NOT report .saveFailed.
    let result = harness.handler.applyRemoteChanges(saved: [ivRecord], deleted: [])

    switch result {
    case .success(let changedTypes):
      #expect(changedTypes.contains(InvestmentValueRow.recordType))
    case .saveFailed(let msg):
      Issue.record("Expected success, got .saveFailed(\(msg))")
    }

    // The row landed in GRDB even though the account is missing —
    // that is the new contract.
    try await harness.database.read { db in
      let stored = try Int.fetchOne(db,
        sql: "SELECT COUNT(*) FROM investment_value WHERE id = ?",
        arguments: [ivId]) ?? -1
      #expect(stored == 1)
    }
  }
}
```

If `ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()` is named differently in the actual codebase, use the actual name. The harness exposes `handler` and `database`; the zone is declared at the suite level (above) following the established round-trip test pattern.

- [ ] **Step 3: Run; PASS**

```
just test ApplyRemoteChangesOutOfOrderTests 2>&1 | tee .agent-tmp/t9-step3.txt
```

If this fails with a SQLite-19 (FK), v5 didn't take effect — re-check Task 2. If it fails because of a missing CKRecord field, the `toCKRecord` helper isn't being used correctly — return to Step 1.

- [ ] **Step 4: Commit**

```
git -C .worktrees/sync-fk-removal commit -m "test(sync): pin out-of-order CKRecord delivery succeeds

Reproduces the rc.12 incident as a unit test: a single CKRecord for
an InvestmentValue whose parent account doesn't exist locally must
succeed at apply time. Failed under v4 (FK-enforced); passes under v5.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Update guides and stale doc-comments

**Files:**
- Modify: `guides/DATABASE_SCHEMA_GUIDE.md` (§6 example uses an FK ALTER; replace)
- Modify: `guides/SYNC_GUIDE.md` (add "Per-profile schema does not enforce FKs" subsection)
- Modify: `Backends/GRDB/ProfileSchema+CoreFinancialGraph.swift` (file-header zombie-row paragraph)
- Modify: `MoolahTests/Backends/GRDB/SyncRoundTripTransactionTests.swift` (`seedLegParents` comment)
- Modify: `MoolahTests/Support/TestBackend.swift` (`ensureLegParents` comment)

- [ ] **Step 1: Update `DATABASE_SCHEMA_GUIDE.md` §6**

The example at lines ~233-238 shows a synthetic `v2_add_earmark_fk` migration that adds an FK. Replace with a generic example that doesn't presume FK enforcement (e.g. adding a column with a CHECK). The replacement **must**:

- Use a `registerMigration("vN_<name>", …)` call with a string-literal stable ID (so §6.2 stays visible in the example).
- Show `try db.execute(sql: """ ALTER TABLE … ADD COLUMN … TEXT NOT NULL DEFAULT '…' CHECK (… IN (…)); """)` (or similar) to demonstrate a non-FK schema-evolution shape.

Suggested replacement (adjust to fit guide voice):

```swift
migrator.registerMigration("v2_add_account_archived_state") { db in
    try db.execute(sql: """
        ALTER TABLE account
            ADD COLUMN archived_state TEXT NOT NULL DEFAULT 'active'
            CHECK (archived_state IN ('active', 'archived'));
        CREATE INDEX account_by_archived_state
            ON account (archived_state) WHERE archived_state = 'archived';
        """)
}
```

Also: under §6 ("Foreign-key handling") add one paragraph noting that the per-profile schema does not enforce FKs after `v5_drop_foreign_keys` and integrity is enforced in repository code; cross-reference `SYNC_GUIDE.md`.

- [ ] **Step 2: Update `SYNC_GUIDE.md`**

Add a new subsection under §3 Core Principles titled **"Per-profile schema does not enforce FKs"**. Required content (three bullets, in order):

> - **The contract.** The per-profile `data.sqlite` schema declares no foreign keys. CKSyncEngine has no parent-before-child guarantee within a fetch session or across sessions; an FK-enforced child insert can fault the entire write transaction and trap the sync coordinator in an infinite re-fetch loop. See `Backends/GRDB/ProfileSchema+DropForeignKeys.swift` and the rc.12 incident write-up.
> - **Cascade replication.** Sync delete paths in repositories must replicate the cascade / null-out semantics that the v3 FKs used to provide:
>   - `GRDBAccountRepository.applyRemoteChangesSync` deletes `investment_value` rows for the account and nulls `transaction_leg.account_id` references.
>   - `GRDBTransactionRepository.applyRemoteChangesSync` (and the domain `delete(id:)`) deletes `transaction_leg` rows for the transaction.
>   - `GRDBEarmarkRepository.applyRemoteChangesSync` deletes `earmark_budget_item` rows and nulls `transaction_leg.earmark_id`.
>   - `GRDBCategoryRepository.applyRemoteChangesSync` (or its `+Sync.swift`) nulls `transaction_leg.category_id`, deletes `earmark_budget_item` rows referencing the deleted category, and orphans child categories (`parent_id := NULL`).
> - **Zombie rows are accepted.** A child whose parent CKRecord is deleted server-side or never delivered remains as an orphan row. This is intentional: the alternative (FK enforcement) traps the entire sync stream on a single delta. Repository read paths filter through known parents, so orphans do not surface in computed views; they occupy storage. Do not "fix" zombies by reintroducing FKs.

- [ ] **Step 3: Update `+CoreFinancialGraph.swift` file header**

Append to the FK section already rewritten in Task 4 (or fold into it): a sentence acknowledging that orphan child rows (a leg or budget item whose parent CKRecord was deleted server-side or never delivered) are an expected consequence of the FK-free design. Repository read paths filter through known parents; orphans do not surface in computed views. Do not reintroduce FKs to suppress them.

- [ ] **Step 4: Update `MoolahTests/Backends/GRDB/SyncRoundTripTransactionTests.swift:69-100` `seedLegParents` comment**

Replace any wording that implies "parents must exist before legs can be inserted under FK enforcement" with a clarifying note that under v5 the seeding is an *optional* setup detail (kept so the round-trip assertions still hold against fully-formed transactions), **not** a structural requirement of leg sync apply. New tests of leg arrival without a parent live in `MoolahTests/Sync/ApplyRemoteChangesOutOfOrderTests.swift` (Task 9).

- [ ] **Step 5: Update `MoolahTests/Support/TestBackend.swift` `ensureLegParents` comment (~lines 183-188)**

The current comment justifies placeholder seeding under "the GRDB schema's enforced FKs". Remove the FK justification. If any non-FK reason for placeholder seeding remains (e.g. enabling the test to read back a fully-resolved domain `Transaction` with non-trivial parents for assertion purposes), note that as the new justification. If no reason remains, delete the helper and update the call sites — confirm by `grep -rn "ensureLegParents" MoolahTests/`.

- [ ] **Step 6: Commit**

```
git -C .worktrees/sync-fk-removal add guides/DATABASE_SCHEMA_GUIDE.md guides/SYNC_GUIDE.md Backends/GRDB/ProfileSchema+CoreFinancialGraph.swift MoolahTests/Backends/GRDB/SyncRoundTripTransactionTests.swift MoolahTests/Support/TestBackend.swift
git -C .worktrees/sync-fk-removal commit -m "docs(guides): record FK-removal contract; clear stale FK comments

DATABASE_SCHEMA_GUIDE §6 example no longer presumes FK enforcement
and retains a stable string-ID demonstration. SYNC_GUIDE §3 documents
the no-FK contract, the cascade-replication responsibilities of each
repository's sync delete path, and the zombie-row trade-off.
+CoreFinancialGraph.swift file header acknowledges orphan rows as
intentional. SyncRoundTripTransactionTests and TestBackend comments
are updated to remove stale FK-ordering justifications.

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
- [x] `ensureFKTargets` (Task 6b) and `ensureCategoryExists` (Task 7) — both stub-row workarounds that exist *only* to dodge FK enforcement — are explicitly removed (or, for `ensureFKTargets`, the non-FK instrument-resolution branch is preserved).
- [x] No placeholders. Every step shows the actual SQL / Swift to write or run.
- [x] Type consistency: `applyRemoteChangesSync` signature matches across Account/Transaction/Earmark/Category. Index names match `+CoreFinancialGraph.swift`. Migration ID `v5_drop_foreign_keys` is consistent everywhere.
- [x] Test framework: Swift Testing (`@Test`/`#expect`) per project convention. Tests use `ProfileDatabase.openInMemory()` + direct concrete-repo construction (the project's established pattern in `MoolahTests/Backends/GRDB/CSVImportRollbackTests.swift` etc.). No `session.databaseQueue`, `backend.openSession`, or `as!` casts to the concrete repo.
- [x] Multi-statement domain delete (`GRDBTransactionRepository.delete(id:)`) is paired with a §5 rollback test (Task 6 Step 5).
- [x] Stale FK doc-comments in `GRDBTransactionRepository.swift` (lines 175-180 and the file-level header at lines 14-16) are explicitly rewritten in Task 6 Step 2.
- [x] Migrator-body visibility (Task 0) is gated as a numbered step before Task 3 needs the methods to be `internal`-visible.
- [x] CKRecord construction in Task 9 goes through the project's existing record-mapping helper, not a hand-rolled field-by-field assembly.
- [x] Zombie-child-row trade-off is documented in three places: the `+CoreFinancialGraph.swift` file header (Task 4 / Task 10 Step 3), `SYNC_GUIDE.md` (Task 10 Step 2 third bullet), and the `Background → What this plan changes` section above.
- [x] Worktree path: `.worktrees/sync-fk-removal`. All git commands use `git -C <path>`.
- [x] Reviewers: schema, code-database, sync, concurrency, code — all listed in Task 11.

### Findings applied from v1 → v2

| Source | Severity | Finding | Resolution in v2 |
|---|---|---|---|
| sync-review | Critical | `GRDBTransactionRepository.ensureFKTargets` unaddressed | New **Task 6b** removes the FK-driven stub branches; renames helper to `ensureInstrumentReadable`; new test asserts no phantom blank-name rows after a leg upsert with missing parents. |
| database-code-review | Important | Stale `// Legs cascade via the FK` comment in `delete(id:)` and file header | Explicit rewrite step in **Task 6 Step 2(a)/(b)**. |
| database-code-review | Important | Tasks 5-8 use non-existent `session.*` / `backend.openSession` / `as!` test pattern | All four tasks rewritten to use `ProfileDatabase.openInMemory()` + direct repo construction (the project's established pattern). |
| database-code-review | Important | Multi-statement `delete(id:)` lacks §5 rollback test | New `TransactionDeleteRollbackTests.swift` in **Task 6 Step 5**. |
| database-code-review | Important | Migrator-body visibility check buried in a parenthetical | New numbered **Task 0**. |
| database-code-review | Minor | `MoolahTests/Support/TestBackend.swift` `ensureLegParents` stale comment | Added to file inventory and **Task 10 Step 5**. |
| sync-review | Important | Task 9 hand-built CKRecord may omit fields | **Task 9 Step 1** locates the existing round-trip helper; Step 2 uses it instead of hand-rolled fields. |
| sync-review | Important | Zombie-row trade-off not documented | Documented in `+CoreFinancialGraph.swift` (**Task 4 / Task 10 Step 3**) and `SYNC_GUIDE.md` (**Task 10 Step 2** third bullet). |
| sync-review | Important | `seedLegParents` comment in `SyncRoundTripTransactionTests` becomes misleading | Added to file inventory and **Task 10 Step 4**. |
| sync-review | Minor | `SYNC_GUIDE.md` update lacked prescribed content | **Task 10 Step 2** mandates three required bullets. |
| schema-review | Minor | Schema-guide example replacement should retain stable string-ID | **Task 10 Step 1** mandates a `registerMigration("vN_<name>", …)` literal in the replacement. |
| concurrency-review | Minor | Tests reading `session.databaseQueue` would force a public-API exposure | Resolved by the same Tasks 5-8 rewrite (no `session.databaseQueue` reference anywhere). |
| concurrency-review | Minor | `TestBackend()` ctor pattern was wrong | Same — direct `ProfileDatabase.openInMemory()` + repo construction; `TestBackend` is no longer instantiated by the new tests. |

### Findings applied from v2 → v3

| Source | Severity | Finding | Resolution in v3 |
|---|---|---|---|
| database-code-review | Important | Task 6 Step 5 rollback test seed used `//` Swift comments inside the SQL string literal (would parse-error at runtime, aborting seed before the trigger is created). | SQL comments rewritten to `--`. The Swift comment moved outside the string literal. |
| database-code-review | Important | Task 9 Step 2 referenced `harness.zoneID`; `HandlerHarness` only exposes `handler`, `container`, `database`. | Suite-local `private static let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)` declared, mirroring the established pattern in every existing round-trip test suite. CKRecord construction now uses `Self.zoneID`. |
