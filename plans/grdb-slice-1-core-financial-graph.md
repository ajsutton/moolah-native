# Slice 1 — Core Financial Graph to GRDB (detailed plan)

**Status:** Not started.
**Roadmap context:** `plans/grdb-migration.md` §6 → Slice 1.
**Branch:** `feat/grdb-slice-1-core` (not yet created).
**Parent branch:** `main` (Slice 0's PR [#567](https://github.com/ajsutton/moolah-native/pull/567) is the prerequisite — must merge first; until then the Slice 1 worktree is rooted on `origin/feat/grdb-slice-0-csv-import` so the patterns Slice 0 establishes are visible to the implementer).

---

## 1. Goal

Migrate the eight record types that make up the core financial graph — `Account`, `Transaction`, `TransactionLeg`, `Category`, `Earmark`, `EarmarkBudgetItem`, `Instrument`, `InvestmentValue` — from SwiftData (`@Model` classes under `Backends/CloudKit/Models/`) to GRDB (`Sendable` structs under `Backends/GRDB/Records/`), in one coordinated PR. Slice 0 proved out the mechanics on two leaf records; Slice 1 applies them to the dense centre of the join graph and **rewrites `AnalysisRepository` to use SQL aggregates**. This is the slice that delivers the perf wins the entire migration was justified by.

The slice ships:

- Schemas + indexes for the eight tables, with FK declarations and partial / covering indexes sized for the analysis hot paths.
- Eight `*Row` structs, eight mapping extensions, eight `CloudKitRecordConvertible` extensions on the rows.
- Eight GRDB repositories that conform to the existing `Domain/Repositories/` protocols.
- A rewritten `GRDBAnalysisRepository` whose five protocol methods are SQL `GROUP BY` / window / recursive-CTE queries instead of Swift loops over fetched rows. Per-leg conversion stays in Swift (constrained by `guides/INSTRUMENT_CONVERSION_GUIDE.md`); per-instrument SUMs move to SQL.
- A `SwiftDataToGRDBMigrator` extension that copies the eight types' rows from SwiftData (preserving `encodedSystemFields` byte-for-byte and FK references) under per-type `UserDefaults` flags, in a single transaction per type and in parents-before-children order.
- CKSyncEngine glue updates: `RecordTypeRegistry.allTypes`, `applyGRDBBatchSave` / `applyGRDBBatchDeletion`, `applyGRDBSystemFields`, `+RecordLookup`, `+QueueAndDelete` — all extended to route the eight types through GRDB.
- Plan-pinning tests for every analysis hot-path SQL query (mandatory per `DATABASE_CODE_GUIDE.md` §6).
- Rollback tests for every multi-statement write.
- A benchmark delta on the `MoolahBenchmarks/AnalysisBenchmarks.swift` cases proving the analysis-pipeline win is real.

The slice does **not** ship:

- Removal of the SwiftData `@Model` classes for the eight types — the migrator needs them. Removal happens in **Slice 3 — Stragglers** after `ProfileRecord` and any remaining synced types are migrated and SwiftData is torn out wholesale.
- SQL-side conversion of `InstrumentAmount`s. Per-leg conversion stays in Swift; the SQL emits per-instrument-keyed SUMs and Swift performs the conversion before the cross-instrument cumulative add. Multi-step conversion (stock → fiat → fiat → target) remains a Swift pipeline.
- Any change to `ExchangeRateService` / `StockPriceService` / `CryptoPriceService` / `FullConversionService` / `FiatConversionService`. They are constructed once per `ProfileSession`, take a `database: any DatabaseWriter`, and don't care that more tables now share the connection.
- `ValueObservation` adoption. Stores keep reloading on explicit triggers per `DATABASE_CODE_GUIDE.md` §2. (Re-evaluation is gated by Slice 1 *shipping*, not by this PR adopting it.)

---

## 2. What's already in place from Step 2 + Slice 0 (don't change)

Per-profile GRDB infrastructure shipped on `main` via Step 2 and (will ship via) Slice 0:

| File | Provides |
|---|---|
| `Backends/GRDB/ProfileDatabase.swift` | `DatabaseQueue` factory: `open(at:)` + `openInMemory()`. WAL on disk, PRAGMA defaults from `DATABASE_SCHEMA_GUIDE.md` §5, `journal_mode = WAL` read-back assertion. |
| `Backends/GRDB/ProfileSchema.swift` | `DatabaseMigrator` with `v1_initial` (rate caches) and `v2_csv_import_and_rules` (Slice 0). New tables go under fresh `v3_*` migrations. **Migration IDs are immutable once shipped.** |
| `Backends/GRDB/Migration/SwiftDataToGRDBMigrator.swift` | `@MainActor final class`. Per-type private migrators gated by `UserDefaults` flags. `committed` `defer` flag pattern. `upsert` (idempotent re-run) instead of `insert`. Slice 1 extends this file. |
| `Backends/GRDB/Records/CSVImportProfileRow.swift` + `+Mapping.swift` | Reference shape — bare struct with named columns, per-protocol extensions (`Codable`, `Sendable`, `Identifiable`, `FetchableRecord`, `PersistableRecord`). |
| `Backends/GRDB/Sync/CSVImportProfileRow+CloudKit.swift` | Reference shape for `CloudKitRecordConvertible` on a value-type row. |
| `Backends/GRDB/Repositories/GRDBCSVImportProfileRepository.swift` | Reference shape — `final class … : @unchecked Sendable`, `let database: any DatabaseWriter`, `@Sendable` hook closures captured at `init`, async public methods, synchronous `…Sync` entry points consumed by `ProfileDataSyncHandler`. Mirror this exactly for the eight new repos. |
| `Backends/CloudKit/Sync/ProfileGRDBRepositories.swift` | The bundle struct that Slice 0 introduced. Slice 1 extends with eight more `let` properties. |
| `Backends/CloudKit/Sync/ProfileDataSyncHandler+GRDBDispatch.swift` | The `applyGRDBBatchSave` / `applyGRDBBatchDeletion` switch statements. Slice 1 adds a case per record type. Same shape, throwing on error so CKSyncEngine refetches instead of advancing past a dropped record. |
| `Backends/CloudKit/Sync/ProfileDataSyncHandler+SystemFields.swift` | The `applyGRDBSystemFields` switch. Slice 1 adds eight new cases. The legacy `systemFieldSetters` SwiftData dispatch table loses the eight migrated entries. |
| `Backends/CloudKit/Sync/ProfileDataSyncHandler+QueueAndDelete.swift` | `queueAllExistingRecords()` ordering (instruments → categories → accounts → earmarks → budget items → investment values → transactions → transaction legs → CSV → rules). Slice 1 swaps the SwiftData fetches for GRDB `allRowIdsSync()` calls but **preserves the same order**. |
| `Backends/CloudKit/Sync/ProfileDataSyncHandler+RecordLookup.swift` | `fetchAndBuild` and `batchFetchByType` switches. Slice 1 swaps eight cases over to GRDB rows. |
| `Backends/CloudKit/Sync/ProfileDataSyncHandler+ApplyRemoteChanges.swift` | The two dispatch tables (`batchUpserters`, `uuidDeleters`). Slice 1 removes the eight SwiftData entries and routes everything through `applyGRDBBatchSave` / `applyGRDBBatchDeletion`. |
| `App/ProfileSession.swift` | Owns `let database: DatabaseQueue`. `runSwiftDataToGRDBMigrationIfNeeded(profileId:containerManager:database:)` runs the migrator pre-`SyncCoordinator.start()`. |
| `MoolahTests/Backends/GRDB/SwiftDataToGRDBMigratorTests.swift` | Migrator test harness — re-run-is-no-op, byte-equality on `encodedSystemFields`, in-memory GRDB queue. Slice 1 adds eight more cases inside the existing harness. |

The slice extends, never replaces. **Do not** create a second SQLite file — one DB per profile.

---

## 3. What's left

### 3.1 GRDB schema additions

Extend `Backends/GRDB/ProfileSchema.swift` with one new migration `v3_core_financial_graph` that creates eight tables in a single transaction. Migration body order matches FK ordering: parents before children. All eight tables carry `encoded_system_fields BLOB` and `record_name TEXT NOT NULL UNIQUE` per `plans/grdb-migration.md` §4. CHECK constraints on every Bool / enum-shaped TEXT / bounded INTEGER column per `DATABASE_SCHEMA_GUIDE.md` §3.

```sql
-- 1. instrument (no FK in)
CREATE TABLE instrument (
    id                   TEXT NOT NULL PRIMARY KEY,         -- e.g. "AUD", "ASX:BHP", "1:0xa0b8…"
    record_name          TEXT NOT NULL UNIQUE,
    kind                 TEXT NOT NULL
        CHECK (kind IN ('fiatCurrency', 'stock', 'cryptoToken')),
    name                 TEXT NOT NULL,
    decimals             INTEGER NOT NULL CHECK (decimals >= 0),
    ticker               TEXT,
    exchange             TEXT,
    chain_id             INTEGER,
    contract_address     TEXT,
    coingecko_id         TEXT,
    cryptocompare_symbol TEXT,
    binance_symbol       TEXT,
    encoded_system_fields BLOB
) STRICT;

-- 2. category (self-referential)
CREATE TABLE category (
    id                    BLOB NOT NULL PRIMARY KEY,
    record_name           TEXT NOT NULL UNIQUE,
    name                  TEXT NOT NULL,
    parent_id             BLOB REFERENCES category(id) ON DELETE NO ACTION,
    encoded_system_fields BLOB
) STRICT;
CREATE INDEX category_by_parent
    ON category(parent_id) WHERE parent_id IS NOT NULL;

-- 3. account (no FK in; instrument_id is TEXT-only, no FK to instrument)
CREATE TABLE account (
    id                    BLOB NOT NULL PRIMARY KEY,
    record_name           TEXT NOT NULL UNIQUE,
    name                  TEXT NOT NULL,
    -- Raw values mirror Domain/Models/Account.swift `AccountType`. Note
    -- creditCard's raw value is `"cc"`, not `"creditCard"` — keep CHECK
    -- in lock-step with the enum if it ever changes.
    type                  TEXT NOT NULL
        CHECK (type IN ('bank', 'cc', 'asset', 'investment')),
    instrument_id         TEXT NOT NULL,
    position              INTEGER NOT NULL CHECK (position >= 0),
    is_hidden             INTEGER NOT NULL CHECK (is_hidden IN (0, 1)),
    encoded_system_fields BLOB
) STRICT;
CREATE INDEX account_by_position ON account(position);
CREATE INDEX account_by_type     ON account(type);

-- 4. earmark
CREATE TABLE earmark (
    id                              BLOB NOT NULL PRIMARY KEY,
    record_name                     TEXT NOT NULL UNIQUE,
    name                            TEXT NOT NULL,
    position                        INTEGER NOT NULL CHECK (position >= 0),
    is_hidden                       INTEGER NOT NULL CHECK (is_hidden IN (0, 1)),
    instrument_id                   TEXT,                       -- nullable: legacy rows defaulted to profile instrument
    savings_target                  INTEGER
        CHECK (savings_target IS NULL OR savings_target >= 0),  -- storage cents (Decimal × 10^8 storageValue); savings target is non-negative when set
    savings_target_instrument_id    TEXT,                       -- legacy compat; coerced to instrument_id on read
    savings_start_date              TEXT,
    savings_end_date                TEXT,
    encoded_system_fields           BLOB
) STRICT;
CREATE INDEX earmark_by_position ON earmark(position);

-- 5. earmark_budget_item (FK to earmark, FK to category)
CREATE TABLE earmark_budget_item (
    id                    BLOB NOT NULL PRIMARY KEY,
    record_name           TEXT NOT NULL UNIQUE,
    earmark_id            BLOB NOT NULL REFERENCES earmark(id)  ON DELETE CASCADE,
    category_id           BLOB NOT NULL REFERENCES category(id) ON DELETE NO ACTION,
    -- Sign preserved (see CLAUDE.md "Monetary Sign Convention"); a budget
    -- amount is the *target*, never zero. Domain code disallows 0 budgets.
    amount                INTEGER NOT NULL CHECK (amount <> 0), -- storageValue (Decimal × 10^8)
    instrument_id         TEXT NOT NULL,                    -- legacy compat; coerced to earmark's instrument_id on read
    encoded_system_fields BLOB
) STRICT;
CREATE INDEX ebi_by_earmark  ON earmark_budget_item(earmark_id);
CREATE INDEX ebi_by_category ON earmark_budget_item(category_id);

-- 6. transaction  (note: SQLite reserved word — quoted everywhere it appears)
CREATE TABLE "transaction" (
    id                                BLOB NOT NULL PRIMARY KEY,
    record_name                       TEXT NOT NULL UNIQUE,
    date                              TEXT NOT NULL,
    payee                             TEXT,
    notes                             TEXT,
    -- Raw values mirror Domain/Models/RecurPeriod.swift. Note the values
    -- are uppercase (`ONCE`, `DAY`, …) — these are the actual Swift enum
    -- raw values that round-trip through `toCKRecord` / `fieldValues`.
    -- Keep CHECK in lock-step with the enum if it ever changes.
    recur_period                      TEXT
        CHECK (recur_period IS NULL OR
               recur_period IN ('ONCE','DAY','WEEK','MONTH','YEAR')),
    recur_every                       INTEGER CHECK (recur_every IS NULL OR recur_every > 0),
    -- Denormalised ImportOrigin (nine fields). Mirrors the existing SwiftData
    -- shape (one column per struct field) so the CKRecord wire format stays
    -- byte-identical. JSON consolidation is a follow-up consideration once
    -- ImportOrigin shape settles.
    import_origin_raw_description     TEXT,
    import_origin_bank_reference      TEXT,
    import_origin_raw_amount          TEXT,    -- Decimal-as-String
    import_origin_raw_balance         TEXT,    -- Decimal-as-String
    import_origin_imported_at         TEXT,
    import_origin_import_session_id   BLOB,
    import_origin_source_filename     TEXT,
    import_origin_parser_identifier   TEXT,
    encoded_system_fields             BLOB,
    -- Pair invariant: recur_period and recur_every are both non-NULL or
    -- both NULL. Forecast extrapolation gates on `recur_period IS NOT
    -- NULL`; without this table-level constraint a half-initialised row
    -- (one set, the other null) silently misbehaves.
    CHECK ((recur_period IS NULL) = (recur_every IS NULL))
) STRICT;
CREATE INDEX transaction_by_date          ON "transaction"(date);
-- Partial index: scheduled rows are rare; non-NULL recur_period is the
-- selective predicate. Match the SwiftData index (recur_period, date).
CREATE INDEX transaction_scheduled
    ON "transaction"(recur_period, date) WHERE recur_period IS NOT NULL;
CREATE INDEX transaction_by_payee
    ON "transaction"(payee) WHERE payee IS NOT NULL;

-- 7. transaction_leg (FKs to transaction, account, category, earmark)
CREATE TABLE transaction_leg (
    id                    BLOB NOT NULL PRIMARY KEY,
    record_name           TEXT NOT NULL UNIQUE,
    transaction_id        BLOB NOT NULL REFERENCES "transaction"(id) ON DELETE CASCADE,
    account_id            BLOB         REFERENCES account(id)        ON DELETE SET NULL,
    instrument_id         TEXT NOT NULL,                  -- no FK; ambient fiat has no row
    -- Sign preserved (CLAUDE.md "Monetary Sign Convention"); zero-quantity
    -- legs serve no purpose and indicate a write bug. Domain code never
    -- emits one.
    quantity              INTEGER NOT NULL CHECK (quantity <> 0), -- storageValue (Decimal × 10^8)
    -- Raw values mirror Domain/Models/TransactionType.swift. `'trade'` is
    -- a real case used by stock / crypto buy-sell pairs — keep it in the
    -- list. Keep CHECK in lock-step with the enum if it ever changes.
    type                  TEXT NOT NULL
        CHECK (type IN ('income','expense','transfer','openingBalance','trade')),
    category_id           BLOB         REFERENCES category(id) ON DELETE SET NULL,
    earmark_id            BLOB         REFERENCES earmark(id)  ON DELETE SET NULL,
    sort_order            INTEGER NOT NULL CHECK (sort_order >= 0),
    encoded_system_fields BLOB
) STRICT;
-- FK child indexes per DATABASE_SCHEMA_GUIDE.md §4 — mandatory.
CREATE INDEX leg_by_transaction ON transaction_leg(transaction_id);
CREATE INDEX leg_by_account     ON transaction_leg(account_id)
    WHERE account_id IS NOT NULL;
CREATE INDEX leg_by_category    ON transaction_leg(category_id)
    WHERE category_id IS NOT NULL;
CREATE INDEX leg_by_earmark     ON transaction_leg(earmark_id)
    WHERE earmark_id IS NOT NULL;
-- Composite covering index for the analysis hot paths. Order: equality
-- predicates (type) first; FK group dimension (account_id, category_id,
-- earmark_id) second; instrument grouping last. Plan-pinning tests are
-- mandatory (§3.4 / §3.9).
CREATE INDEX leg_analysis_by_type_account
    ON transaction_leg(type, account_id, instrument_id, transaction_id, quantity);
CREATE INDEX leg_analysis_by_type_category
    ON transaction_leg(type, category_id, instrument_id, transaction_id, quantity)
    WHERE category_id IS NOT NULL;
CREATE INDEX leg_analysis_by_earmark_type
    ON transaction_leg(earmark_id, type, instrument_id, transaction_id, quantity)
    WHERE earmark_id IS NOT NULL;

-- 8. investment_value (FK to account)
CREATE TABLE investment_value (
    id                    BLOB NOT NULL PRIMARY KEY,
    record_name           TEXT NOT NULL UNIQUE,
    account_id            BLOB NOT NULL REFERENCES account(id) ON DELETE CASCADE,
    date                  TEXT NOT NULL,
    -- Sign preserved per CLAUDE.md. Investment positions can theoretically
    -- be negative (short positions) — no sign CHECK; domain validation
    -- is responsible for any policy decisions about non-negativity.
    value                 INTEGER NOT NULL,            -- storageValue
    instrument_id         TEXT NOT NULL,
    encoded_system_fields BLOB
) STRICT;
-- Covering index for `fetchValues(accountId:)` (§3.3.5),
-- `fetchDailyBalances` (§3.4.1) per-account joins, and the
-- composite-uniqueness SELECT in `setValue` (§3.3.5). Includes
-- `value` and `instrument_id` so plan-pinning tests can assert
-- COVERING INDEX. A second index `(account_id, date)` would be a
-- prefix-duplicate per DATABASE_SCHEMA_GUIDE.md §4 — drop it.
CREATE INDEX iv_by_account_date_value
    ON investment_value(account_id, date, value, instrument_id);
```

#### Schema notes

- **`STRICT` on every table** — non-negotiable per `DATABASE_SCHEMA_GUIDE.md` §3.
- **`WITHOUT ROWID` decision per §3 rule.** `instrument` has a TEXT PK and would benefit, but the row width (twelve columns including the encoded-system-fields blob) tips the decision back to ROWID. The other seven tables are wide UUID-PK rows — keep ROWID. **No `WITHOUT ROWID` in this slice.**
- **`UUID` columns are `BLOB`** (16 bytes, GRDB default). `Instrument.id` is the lone exception — it's an arbitrary string (e.g. `"AUD"`, `"ASX:BHP"`, `"1:0xa0b8…"`) per the existing `@Model`. Verify in `Domain/Models/Instrument.swift` before running the migration; the migrator copies the string verbatim.
- **`record_name TEXT NOT NULL UNIQUE`** — every synced table per `plans/grdb-migration.md` §4 and Slice 0 precedent. Format: `"<RecordType>|<UUID>"` for UUID-keyed types, `"<id>"` for `InstrumentRecord` (string-keyed). Mirror Slice 0's `recordName(for:)` static method on each row struct.
- **`encoded_system_fields BLOB` (nullable).** Bit-for-bit copies of CloudKit's bytes; never decoded outside `Backends/CloudKit/Sync/`.
- **CHECK constraints.** Booleans pinned to `(0, 1)`. Enum-shaped TEXT pinned to the raw values from the Swift enum (verified against `Domain/Models/AccountType.swift`, `Domain/Models/Instrument.swift`, `Domain/Models/RecurPeriod.swift`, `Domain/Models/TransactionType.swift`). Update the SQL CHECK clause and the column lists in lock-step if any enum's raw values change. (Reviewers treat a stale CHECK as Critical.)
- **Foreign keys.** Listed inline above; deletion semantics chosen to mirror the existing SwiftData repository code:
  - `transaction_leg.transaction_id` → `transaction.id`: **`ON DELETE CASCADE`.** A transaction can never have orphaned legs; the existing repo deletes legs alongside transactions.
  - `transaction_leg.account_id` → `account.id`: **`ON DELETE SET NULL`.** The Domain `TransactionLeg.accountId` is `UUID?`; account-less legs are valid (e.g. earmark-only opening balances).
  - `transaction_leg.category_id` → `category.id`: **`ON DELETE SET NULL`.** Categories support delete-with-replacement (`CategoryRepository.delete(id:withReplacement:)`); the replacement path runs an explicit UPDATE before delete, and `SET NULL` covers the no-replacement path.
  - `transaction_leg.earmark_id` → `earmark.id`: **`ON DELETE SET NULL`.** `EarmarkRepository` has no explicit cascade today — orphaning legs is the SwiftData status quo; preserve it.
  - `category.parent_id` → `category.id`: **`ON DELETE NO ACTION`.** Slice 1 doesn't change category hierarchy semantics; deletion of a parent with children is currently prevented by the repository, not the schema. Keep that boundary explicit.
  - `earmark_budget_item.earmark_id` → `earmark.id`: **`ON DELETE CASCADE`.** Budget items belong to their earmark.
  - `earmark_budget_item.category_id` → `category.id`: **`ON DELETE NO ACTION`.** Same reasoning as `transaction_leg.category_id` but stricter — losing a budget item to a category delete would silently change the user's budget. The repository must explicitly handle the deletion path.
  - `investment_value.account_id` → `account.id`: **`ON DELETE CASCADE`.** Investment values belong to the account.
- **No FK on `*.instrument_id` columns.** `Instrument` is dual-role: ambient fiat instruments (synthesised from `Locale.Currency.isoCurrencies`) have no `instrument` row; synced stocks / crypto do. An FK would reject every fiat reference. The column stays `TEXT NOT NULL`, integrity is enforced at the application boundary, and the `instrument` table is queried only for the registry-listing protocol methods.
- **`"transaction"` is a SQLite reserved word.** Quote in every SQL string. Slice 1 does not rename to `txn` because the wire `recordType` is frozen as `"TransactionRecord"` and the table name has no equivalent constraint — choose readability and accept the quoting overhead.
- **`PRAGMA foreign_keys = ON` is set per-connection by `ProfileDatabase.open`.** Verify the read-back assertion still passes on test queues; in-memory queues honour PRAGMAs from the same `Configuration.prepareDatabase` block.

#### Index design rationale

Indexes are sized for the analysis hot paths in §3.4. The decisions are recorded here so the schema reviewer (`database-schema-review`) can verify them in one pass, and the code reviewer can match queries to indexes via plan-pinning tests:

| Index | Driver query (see §3.4 for the SQL) | Type |
|---|---|---|
| `category_by_parent` | Hierarchy display in `CategoryStore`; partial because most rows are root categories | Partial |
| `account_by_position` | Sidebar ordering | B-tree |
| `account_by_type` | `JOIN account ON account.type = 'investment'` in income/expense and daily-balance queries | B-tree |
| `earmark_by_position` | Sidebar ordering | B-tree |
| `ebi_by_earmark` | `fetchBudget(earmarkId:)` | B-tree |
| `ebi_by_category` | Category-deletion side effects | B-tree |
| `transaction_by_date` | `WHERE date >= after` selection in every analysis method | B-tree |
| `transaction_scheduled` | Forecast extrapolation (`recur_period IS NOT NULL`); excludes scheduled from non-forecast queries | Partial |
| `transaction_by_payee` | Payee suggestions and `TransactionFilter.payee` | Partial |
| `leg_by_transaction` | FK child index (mandatory per §4); `JOIN leg ON leg.transaction_id = t.id` | B-tree |
| `leg_by_account`, `leg_by_category`, `leg_by_earmark` | FK child indexes; partial (skip NULL FKs) | Partial |
| `leg_analysis_by_type_account` | `fetchIncomeAndExpense`, `computePositions` (sidebar) — covering for `(type, account, instrument)` GROUP BY | Composite |
| `leg_analysis_by_type_category` | `fetchExpenseBreakdown`, `fetchCategoryBalances` — covering for `(type, category, instrument)` GROUP BY; partial because category-less legs (e.g. transfers) don't participate | Partial covering |
| `leg_analysis_by_earmark_type` | Earmark-filtered category balances; partial because earmark-less legs dominate | Partial covering |
| `iv_by_account_date_value` | `fetchValues(accountId:)` paginated reads + daily-balance latest-value-per-account-per-date — covering | Composite covering |

Storage cost: ~16 indexes across 8 tables. The transaction_leg table carries seven (one PK, four FK child partials, three composite covering — note the `leg_by_account` partial is _not_ a prefix-duplicate of `leg_analysis_by_type_account` because the latter leads with `type` and is unconditional). Write amplification is acceptable because the analysis read pattern dominates the user's experience; the upsert path is sync-batched and tolerates the cost. **No prefix-duplicate indexes.** Verify by inspection during review (one was caught during review: `iv_by_account_date` was a strict prefix of `iv_by_account_date_value` and has been removed).

### 3.2 GRDB record types

Eight new files in `Backends/GRDB/Records/`, each paired with a `+Mapping.swift` sibling. Naming follows Slice 0's `*Row` convention to avoid collision with the surviving `*Record` `@Model` classes (which the migrator still reads). Once Slice 3 deletes the SwiftData layer wholesale, the rows can keep `*Row` (the GRDB convention) — no further rename is required.

| File | Contents |
|---|---|
| `InstrumentRow.swift` | Bare struct + per-protocol extensions (`Codable`, `Sendable`, `Identifiable`, `FetchableRecord`, `PersistableRecord`). PK: `id: String`. |
| `InstrumentRow+Mapping.swift` | `init(domain: Instrument)` / `toDomain() -> Instrument`. Provider-mapping fields read directly from the row's nullable columns. |
| `CategoryRow.swift` | PK: `id: UUID`. `parentId: UUID?`. |
| `CategoryRow+Mapping.swift` | Domain ↔ row mapping. |
| `AccountRow.swift` | PK: `id: UUID`. Stores `instrumentId: String`, not `instrument: Instrument`. |
| `AccountRow+Mapping.swift` | Domain ↔ row mapping. The `Instrument` value is reconstructed by the repository, not the row, because the repo holds the `InstrumentRegistryRepository` lookup needed to disambiguate stock / crypto IDs from ambient fiat. |
| `EarmarkRow.swift` | Stores nullable `instrumentId` (matches SwiftData's optional column) and the legacy `savingsTargetInstrumentId` for migration compat. |
| `EarmarkRow+Mapping.swift` | Coerces `savingsTargetInstrumentId` to `instrumentId` on read, mirroring the SwiftData reader. |
| `EarmarkBudgetItemRow.swift` | Standard FK row. |
| `EarmarkBudgetItemRow+Mapping.swift` | Domain ↔ row mapping. |
| `TransactionRow.swift` | Mirrors `TransactionRecord` field-for-field, including the nine denormalised `import_origin_*` columns. |
| `TransactionRow+Mapping.swift` | Reconstructs `ImportOrigin?` from the nine columns iff all the required fields are present (matches the SwiftData computed property at `TransactionRecord.swift:57-90`). |
| `TransactionLegRow.swift` | Standard FK row with five FK columns. |
| `TransactionLegRow+Mapping.swift` | Domain ↔ row mapping including `Decimal` ↔ `Int64` (storageValue) conversion. |
| `InvestmentValueRow.swift` | Standard FK row. |
| `InvestmentValueRow+Mapping.swift` | Domain ↔ row mapping. |

Each row file follows Slice 0's `CSVImportProfileRow.swift` shape exactly:

```swift
struct AccountRow {
  static let databaseTableName = "account"

  enum Columns: String, ColumnExpression, CaseIterable {
    case id
    case recordName = "record_name"
    case name
    case type
    case instrumentId = "instrument_id"
    case position
    case isHidden = "is_hidden"
    case encodedSystemFields = "encoded_system_fields"
  }

  enum CodingKeys: String, CodingKey {
    case id, recordName = "record_name", name, type
    case instrumentId = "instrument_id", position
    case isHidden = "is_hidden"
    case encodedSystemFields = "encoded_system_fields"
  }

  var id: UUID
  var recordName: String
  var name: String
  var type: String                     // AccountType raw value
  var instrumentId: String
  var position: Int
  var isHidden: Bool
  var encodedSystemFields: Data?
}

extension AccountRow: Codable {}
extension AccountRow: Sendable {}
extension AccountRow: Identifiable {}
extension AccountRow: FetchableRecord {}
extension AccountRow: PersistableRecord {}
```

**One extension per protocol** per `CODE_GUIDE.md` §11. **No inline conformance lists.** Slice 0 fixed this in round-3 review; apply it from the start.

The `recordName(for:)` static helper lives on each row (Slice 0 places it in the `+Mapping.swift` file). For `InstrumentRow` the format is the bare `id` string (matching the existing `InstrumentRecord+CloudKit.swift`); for the other seven, it's `"<RecordType>|<uuid>"` per the `CKRecordIDRecordName.swift` helper.

#### Decimal ↔ Int64 conversion (storageValue)

`TransactionLeg.quantity`, `EarmarkBudgetItem.amount`, `Earmark.savingsTarget`, and `InvestmentValue.value` all store a `Decimal` as `Int64` storageValue (`Decimal × 10^8`) on the SwiftData side. The GRDB `*Row` types store `INTEGER NOT NULL` (`Int64`) directly — the conversion happens in `+Mapping.swift` at the boundary. Reuse the existing `Decimal.storageValue` / `Decimal(storageValue:)` helpers from the SwiftData layer; **do not** introduce a new conversion path, and **do not** import GRDB into `Domain/Models/`.

### 3.3 GRDB repository implementations

Eight new repositories in `Backends/GRDB/Repositories/`. Each conforms to the existing protocol in `Domain/Repositories/`. Each follows Slice 0's `GRDBCSVImportProfileRepository` shape exactly:

- `final class … : @unchecked Sendable` (not `actor` — the cascade through `ProfileDataSyncHandler`'s synchronous CKSyncEngine delegate paths still doesn't justify it).
- `let database: any DatabaseWriter` plus `@Sendable (String, UUID) -> Void` hook closures captured at `init`.
- All public protocol methods `async throws`. Inside each method, exactly one `database.read { … }` or `database.write { … }` closure.
- Synchronous `…Sync` entry points (`applyRemoteChangesSync`, `setEncodedSystemFieldsSync`, `clearAllSystemFieldsSync`, `unsyncedRowIdsSync`, `allRowIdsSync`, `fetchRowSync`, `fetchRowsSync`, `deleteAllSync`) for `ProfileDataSyncHandler` to call from CKSyncEngine's delegate executor. **Same naming, same shape.**

Per-repository specifics below. Where a method "matches the existing `CloudKit*Repository`", read the existing source as the contract — Slice 1 does not introduce new repository semantics.

#### 3.3.1 `GRDBInstrumentRegistryRepository`

Conforms to `InstrumentRegistryRepository` (`Domain/Repositories/InstrumentRegistryRepository.swift`). Replaces `CloudKitInstrumentRegistryRepository`.

| Method | Implementation sketch |
|---|---|
| `all() async throws -> [Instrument]` | `SELECT … FROM instrument` then map to `[Instrument]`. The current implementation also synthesises ambient fiat from `Locale.Currency.isoCurrencies`; that synthesis stays Swift-side, unchanged. |
| `allCryptoRegistrations() async throws -> [CryptoRegistration]` | `SELECT … FROM instrument WHERE kind = 'cryptoToken' AND coingecko_id IS NOT NULL …`. Filter mapped Swift-side once GRDB returns rows. |
| `registerCrypto(_:mapping:) async throws` | `database.write { … row.upsert(database) … }` plus `onRecordChanged` fire. |
| `registerStock(_:) async throws` | `database.write { … row.upsert(database) … }` plus `onRecordChanged` fire. |
| `remove(id:) async throws` | `database.write { … InstrumentRow.deleteOne(database, key: id) … }` plus `onRecordDeleted` fire. |
| `observeChanges() -> AsyncStream<Void>` | `@MainActor`. Stays in Swift; today it fans out from the `onInstrumentRemoteChange()` hook in `ProfileDataSyncHandler+ApplyRemoteChanges`. The hook is preserved; the registry repo subscribes to the hook same as today. **No `ValueObservation`** — see §6 of `DATABASE_CODE_GUIDE.md`. |

`InstrumentRow.databaseSelection` defaults to all columns; no override needed.

#### 3.3.2 `GRDBCategoryRepository`

Conforms to `CategoryRepository`. Methods: `fetchAll`, `create`, `update`, `delete(id:withReplacement:)`.

`delete(id:withReplacement:)` is the only non-trivial method. Capture the affected ids **before** the UPDATE inside the same transaction so the post-commit hook fan-out can emit `onRecordChanged` for each affected row under its correct record type. Use the typed `Columns` enums on each row, **not** `Column("category_id")` raw strings — a future column rename must produce a compile error, not a silent runtime miss.

```swift
func delete(id: UUID, withReplacement replacementId: UUID?) async throws {
  // Capture before mutating; the transaction's tuple is consumed below
  // for hook fan-out.
  let (legIds, budgetItemIds): ([UUID], [UUID]) = try await database.write { database in
    var changedLegIds: [UUID] = []
    var changedBudgetItemIds: [UUID] = []
    if let replacementId {
      changedLegIds =
        try TransactionLegRow
          .filter(TransactionLegRow.Columns.categoryId == id)
          .select(TransactionLegRow.Columns.id, as: UUID.self)
          .fetchAll(database)
      changedBudgetItemIds =
        try EarmarkBudgetItemRow
          .filter(EarmarkBudgetItemRow.Columns.categoryId == id)
          .select(EarmarkBudgetItemRow.Columns.id, as: UUID.self)
          .fetchAll(database)
      _ = try TransactionLegRow
        .filter(TransactionLegRow.Columns.categoryId == id)
        .updateAll(
          database,
          [TransactionLegRow.Columns.categoryId.set(to: replacementId)])
      _ = try EarmarkBudgetItemRow
        .filter(EarmarkBudgetItemRow.Columns.categoryId == id)
        .updateAll(
          database,
          [EarmarkBudgetItemRow.Columns.categoryId.set(to: replacementId)])
    }
    _ = try CategoryRow.deleteOne(database, key: id)
    return (changedLegIds, changedBudgetItemIds)
  }
  // Selective fan-out post-commit. Fire one onRecordChanged per affected
  // row under its OWN record type — TransactionLegRow.recordType for
  // legs, EarmarkBudgetItemRow.recordType for budget items — so
  // CKSyncEngine queues each correctly. (Mirrors
  // GRDBImportRuleRepository.reorder in slice 0; sync correctness > IPC
  // count.)
  for legId in legIds {
    onRecordChanged(TransactionLegRow.recordType, legId)
  }
  for budgetItemId in budgetItemIds {
    onRecordChanged(EarmarkBudgetItemRow.recordType, budgetItemId)
  }
  onRecordDeleted(CategoryRow.recordType, id)
}
```

Match the existing `CloudKitCategoryRepository.delete` semantics exactly — read the source as the contract. Mandatory regression test: pass a recording closure for `onRecordChanged` and assert the emitted `(recordType, id)` pairs match the expected legs and budget items (§3.9).

#### 3.3.3 `GRDBAccountRepository`

Conforms to `AccountRepository`. `create(_:openingBalance:)` is the multi-statement write — insert the account row, and (when `openingBalance != .zero`) insert a paired `transaction` + `transaction_leg` with type `openingBalance`. **One transaction. Rollback test mandatory.** Three sync emissions, one per inserted row — fire all three with their own `recordType` strings post-commit, otherwise the implicit transaction and leg never reach CKSyncEngine and the second device sees an account opened with no balance.

```swift
func create(
  _ account: Account,
  openingBalance: InstrumentAmount?,
  date: Date  // boundary parameter; clock read at the call site, not the repo
) async throws -> Account {
  let openingTxnId: UUID? = try await database.write { database in
    try AccountRow(domain: account).insert(database)
    guard let openingBalance, !openingBalance.isZero else { return nil }
    let txnId = UUID()
    let txn = TransactionRow(
      id: txnId,
      recordName: TransactionRow.recordName(for: txnId),
      date: date,
      recurPeriod: nil, recurEvery: nil,
      // import_origin columns all nil
      encodedSystemFields: nil)
    try txn.insert(database)
    let legId = UUID()
    let leg = TransactionLegRow(
      id: legId,
      recordName: TransactionLegRow.recordName(for: legId),
      transactionId: txnId,
      accountId: account.id,
      instrumentId: account.instrument.id,
      quantity: openingBalance.storageValue,
      type: TransactionType.openingBalance.rawValue,
      categoryId: nil, earmarkId: nil,
      sortOrder: 0,
      encodedSystemFields: nil)
    try leg.insert(database)
    return txnId
  }
  // Fan out hooks for every row written. The implicit txn + leg need
  // their own emissions under their OWN record types — without these,
  // CKSyncEngine never queues them and a second device sees an account
  // with no opening balance. Capture the leg id back from the closure
  // if needed; sketch elides for brevity.
  onRecordChanged(AccountRow.recordType, account.id)
  if let openingTxnId {
    onRecordChanged(TransactionRow.recordType, openingTxnId)
    onRecordChanged(TransactionLegRow.recordType, /* legId from closure */)
  }
  return account
}
```

**Boundary discipline (`CODE_GUIDE.md` §17):** the `date` parameter is added so the repo doesn't read `Date()` itself — the call site (an `AccountStore` action triggered from a view, or `TestBackend.seed`) supplies the clock value and tests can pin it. Verify the existing `CloudKitAccountRepository.create` API; if it already takes `date`, mirror; if not, the protocol gains the parameter in this slice and the protocol-affecting change is documented in §4. Mandatory regression test: `create(_:openingBalance:date:)` with non-zero balance emits `(AccountRow.recordType, accountId)`, `(TransactionRow.recordType, txnId)`, `(TransactionLegRow.recordType, legId)` — exactly one per row, in that order.

`update(_:)` is a straight update; `delete(id:)` cascades through the FK on `transaction_leg.account_id` and `investment_value.account_id`. Verify with the rollback test that a constraint violation in step N leaves the previous state intact.

`fetchAll() async throws -> [Account]` returns accounts ordered by `position`; positions / balances are computed via `AnalysisRepository` — see §3.4.5.

#### 3.3.4 `GRDBEarmarkRepository`

Conforms to `EarmarkRepository`. `setBudget(earmarkId:categoryId:amount:)` is the only multi-statement write — update or insert the matching budget row. The `fetchBudget(earmarkId:)` lookup uses `ebi_by_earmark`.

#### 3.3.5 `GRDBInvestmentRepository`

Conforms to `InvestmentRepository`. `fetchValues(accountId:page:pageSize:)` paginates by date. `fetchDailyBalances(accountId:)` is the bridge to the analysis layer — it calls into the `GRDBAnalysisRepository` per-account daily aggregate (§3.4.1), avoiding two implementations of the same SQL. Exact sketch: load the per-account leg sums + investment-value snapshots in one transaction, then assemble the `[AccountDailyBalance]` array Swift-side.

`setValue(accountId:date:value:)` is the only multi-statement write. **Decision pinned:** `setValue` uses **manual SELECT-then-UPDATE-or-INSERT** in one `database.write { … }` transaction — there is no `UNIQUE(account_id, date)` constraint in the §3.1 schema (composite-key duplication is a domain-layer invariant, not a storage one), so GRDB's `upsert` cannot infer the right conflict target. Sketch:

```swift
func setValue(accountId: UUID, date: Date, value: InstrumentAmount) async throws {
  try await database.write { database in
    if var existing = try InvestmentValueRow
      .filter(InvestmentValueRow.Columns.accountId == accountId)
      .filter(InvestmentValueRow.Columns.date == date)
      .fetchOne(database)
    {
      existing.value = value.storageValue
      existing.instrumentId = value.instrument.id
      try existing.update(database)
    } else {
      let row = InvestmentValueRow(
        id: UUID(),
        recordName: InvestmentValueRow.recordName(for: …),
        accountId: accountId, date: date,
        value: value.storageValue,
        instrumentId: value.instrument.id,
        encodedSystemFields: nil)
      try row.insert(database)
    }
  }
  onRecordChanged(InvestmentValueRow.recordType, /* id of the affected row */)
}
```

**Rollback test mandatory** for the multi-statement write. The lookup uses `iv_by_account_date_value` (covering composite). Verify by plan-pinning test that the SELECT finds the existing row via the index, not by SCAN.

#### 3.3.6 `GRDBTransactionRepository`

Conforms to `TransactionRepository`. The biggest of the eight by surface area.

| Method | Notes |
|---|---|
| `fetch(filter:page:pageSize:) async throws -> TransactionPage` | Filters + pagination + leg fetch in one transaction. `TransactionPage.withRunningBalances()` (currently lines 152–207 of `Domain/Models/Transaction*`) stays Swift-side because the running balance composes per-leg conversions. Slice 1 returns `[Transaction]` from SQL with legs joined; the running-balance computation runs after the SQL load. |
| `fetchAll(filter:)` | Same shape; no pagination. |
| `create(_:)` | Insert the transaction header + N legs in one transaction. Rollback test mandatory. |
| `update(_:)` | Update the transaction header; replace all legs (delete-by-`transaction_id`, then insert the new ones). One transaction. Rollback test mandatory. |
| `delete(id:)` | `DELETE FROM "transaction" WHERE id = ?` — legs cascade via FK. |
| `fetchPayeeSuggestions(prefix:)` | Use the GRDB query interface: `TransactionRow.select(Columns.payee, as: String.self).filter(Columns.payee != nil).filter(sql: "payee LIKE ? || '%'", arguments: [prefix]).order(Columns.payee).distinct().limit(limit).fetchAll(database)`. **Never** build the LIKE string with Swift `\(prefix)` interpolation — that's the §4 SQL-injection shape. Uses `transaction_by_payee` partial index; verify with a plan-pinning test. |

#### 3.3.7 `GRDBAnalysisRepository`

Conforms to `AnalysisRepository`. **The headline.** Detailed in §3.4 — every protocol method gets its own SQL design and plan-pinning test.

**Concurrency exception:** read-only. No public hooks, no synchronous CKSyncEngine entry points (it doesn't sync — it queries). Holds only `let database: any DatabaseWriter` plus any conversion-service / instrument-registry references it needs (which are themselves `Sendable`). Use **plain `Sendable`** synthesis — `final class` is enough; the `@unchecked` waiver in §3.3.8 is not required here. Doc-comment notes the read-only nature.

#### 3.3.8 `@unchecked Sendable` justification block (writable repos)

Each writable repository's class doc-comment carries the same justification block as `GRDBCSVImportProfileRepository.swift:11–34`:

> `final class` + `@unchecked Sendable` rather than `actor`. All stored properties are `let`. `database` (`any DatabaseWriter`) is itself `Sendable`. `onRecordChanged` and `onRecordDeleted` are `@Sendable` closures captured at `init`. Nothing mutates post-init. `actor` would propagate `await` through every CKSyncEngine sync dispatch site and isn't worth it.

`GRDBAnalysisRepository` (read-only, no hooks) doesn't need the `@unchecked` waiver — see §3.3.7.

#### 3.3.9 `GRDBEarmarkBudgetItemRepository` (sync-only)

Sync-only repository — no Domain protocol conformance. `EarmarkBudgetItem` CRUD is exposed publicly via `EarmarkRepository.fetchBudget(earmarkId:)` / `setBudget(earmarkId:categoryId:amount:)`; `GRDBEarmarkRepository` (§3.3.4) orchestrates the writes through this row type. This sync-only repo exists purely so the `ProfileDataSyncHandler` dispatch tables (apply remote changes, system fields, queue & delete, record lookup) can route by record type without ad-hoc dynamic dispatch.

API surface — synchronous entry points only, called from CKSyncEngine's delegate executor:

```swift
final class GRDBEarmarkBudgetItemRepository: @unchecked Sendable {
  let database: any DatabaseWriter
  let onRecordChanged: @Sendable (String, UUID) -> Void
  let onRecordDeleted: @Sendable (String, UUID) -> Void

  func applyRemoteChangesSync(saved rows: [EarmarkBudgetItemRow], deleted ids: [UUID]) throws
  @discardableResult
  func setEncodedSystemFieldsSync(id: UUID, data: Data?) throws -> Bool
  func clearAllSystemFieldsSync() throws
  func unsyncedRowIdsSync() throws -> [UUID]
  func allRowIdsSync() throws -> [UUID]
  func fetchRowSync(id: UUID) throws -> EarmarkBudgetItemRow?
  func fetchRowsSync(ids: [UUID]) throws -> [EarmarkBudgetItemRow]
  func deleteAllSync() throws
}
```

The `@unchecked Sendable` justification is identical to §3.3.8 — `let`-only properties, `Sendable` writer, `@Sendable` closures. No public protocol methods means no `async` surface.

#### 3.3.10 `GRDBTransactionLegRepository` (sync-only)

Same shape as §3.3.9, typed against `TransactionLegRow`. Same sync-only API (`applyRemoteChangesSync`, `setEncodedSystemFieldsSync`, `clearAllSystemFieldsSync`, `unsyncedRowIdsSync`, `allRowIdsSync`, `fetchRowSync`, `fetchRowsSync`, `deleteAllSync`). `TransactionLeg` CRUD is exposed publicly via `TransactionRepository`'s `create` / `update` / `fetch` (which orchestrate header + legs as one unit). Same `@unchecked Sendable` justification.

### 3.4 AnalysisRepository SQL rewrite (the headline)

This is where Slice 1 earns the migration. Every method below moves its hot loop from Swift into SQL `GROUP BY` / `JOIN` / window / recursive CTE form. **Conversion stays in Swift** — multi-instrument SUMs cannot be performed in SQL without a per-rate lookup table that the migration explicitly defers. The SQL groups by `instrument_id` so each per-instrument total is one Swift conversion call away from the target.

Constraints applied to every method below:

- **Rule 1 (no cross-instrument sum without conversion)** — preserved by always grouping `BY instrument_id` alongside the user-facing dimension.
- **Rule 5 (historic) / Rule 6 (current) / Rule 7 (future)** of `INSTRUMENT_CONVERSION_GUIDE.md` — preserved by passing the **calendar day** of the underlying legs (historic), `Date()` (sidebar / forecast), or the explicit `as-of` date to the conversion call.
- **Plan-pinning test** for every query named below — mandatory per `DATABASE_CODE_GUIDE.md` §6. Each test asserts `SEARCH … USING (COVERING) INDEX <name>` and rejects `SCAN <table>` or `USE TEMP B-TREE FOR ORDER BY`.

**Per-day grouping is the bucket size for every historic-conversion method.** The conversion service caches all rates (FX, stock, crypto) keyed by ISO-8601 date string (`Shared/ExchangeRateService.swift:36–39` formats with `[.withFullDate]`). **Two transactions on the same calendar day get the same rate.** Therefore every method that today converts per-leg at `transaction.date` produces an identical numerical result if it instead groups SQL output by `(DATE(t.date), …, instrument_id)` and converts per-row in Swift on `day`. **No approximation is introduced.** Coarser grouping (per-month, per-range) would change rates and break Rule 5; finer grouping (per-leg) just multiplies conversion calls without changing the answer.

Each method below adopts per-day grouping. The Swift assembly converts per `(day, …, instrument)` tuple, then accumulates up to the user-visible bucket (financial month, category, sidebar, etc.) — Rule 1 is satisfied because each conversion produces a target-instrument value, and the post-conversion adds only happen across rows that all already share the target instrument.

#### 3.4.1 `fetchDailyBalances(after:forecastUntil:)`

Today: a per-day Swift `PositionBook` accumulator (`+DailyBalances.swift:79–113`). After: SQL `GROUP BY (date, account_id, instrument_id)` for the historic span; Swift assembles the `[Date: DailyBalance]` map and runs forecast extrapolation from scheduled transactions (still Swift; SQL can't extrapolate recurring patterns).

```sql
-- per-account, per-instrument daily change
SELECT
    DATE(t.date)        AS day,
    leg.account_id      AS account_id,
    leg.instrument_id   AS instrument_id,
    leg.type            AS type,
    SUM(leg.quantity)   AS day_quantity
FROM transaction_leg AS leg
JOIN "transaction"   AS t ON leg.transaction_id = t.id
WHERE t.recur_period IS NULL
  AND (:after IS NULL OR t.date >= :after)
  AND leg.account_id IS NOT NULL
GROUP BY day, leg.account_id, leg.instrument_id, leg.type
ORDER BY day ASC;
```

```sql
-- per-account latest investment value as of each day
SELECT account_id, date, value, instrument_id
FROM investment_value
WHERE (:after IS NULL OR date >= :after)
ORDER BY account_id ASC, date ASC;
```

The Swift assembly:

1. Build the per-day position deltas (one row per `(day, account, instrument, type)`).
2. Walk the days in order; for each day, apply the deltas to a `PositionBook` keyed by `(account, instrument)`.
3. At each day, call `PositionBook.dailyBalance(on: day, …)` — the existing Swift method that converts each per-instrument total to the profile instrument on `transaction.date`. Per-leg conversion is replaced by per-(day, account, instrument) conversion — same correctness, fewer calls.
4. Forecast extrapolation runs after the historic span; each scheduled transaction is expanded into instances and applied to the same `PositionBook` (the forecast path stays Swift-only).
5. Best-fit linear regression stays Swift; the SQL provides the sorted balances.

**Indexes used:** `transaction_by_date` (range scan), `leg_by_transaction` (join), `leg_analysis_by_type_account` (covering — `(type, account_id, instrument_id, transaction_id, quantity)` covers the SELECT list and the GROUP BY), `iv_by_account_date_value` (covering for the second query).

**Plan-pinning test:** assert `SEARCH "transaction" USING INDEX transaction_by_date` and `SEARCH leg USING COVERING INDEX leg_analysis_by_type_account`. Reject `SCAN`.

**Conversion site:** Swift, post-SQL, on `transaction.date` for historic and `Date()` for forecast (per Rule 5/6). The `@instrument-conversion-review` agent must approve.

#### 3.4.2 `fetchExpenseBreakdown(monthEnd:after:)`

Today: nested `[financialMonth: [categoryId: InstrumentAmount]]` loops in Swift (`+IncomeExpense.swift:6–34`) with per-leg conversion at `transaction.date` (`+Conversion.swift:12–24`). After: SQL `GROUP BY (DATE(t.date), category_id, instrument_id)`; Swift converts each `(day, category, instrument)` tuple on `day`, then accumulates into `(financial_month, category)` buckets. Per-day grouping is rate-equivalent to per-leg conversion — see §3.4 intro for the rate-cache day-granularity argument.

```sql
SELECT
    DATE(t.date)        AS day,
    leg.category_id     AS category_id,
    leg.instrument_id   AS instrument_id,
    SUM(leg.quantity)   AS qty
FROM transaction_leg leg
JOIN "transaction"    t ON leg.transaction_id = t.id
WHERE t.recur_period IS NULL
  AND leg.type = 'expense'
  AND leg.category_id IS NOT NULL
  AND leg.account_id IS NOT NULL
  AND (:after IS NULL OR t.date >= :after)
GROUP BY day, category_id, instrument_id
ORDER BY day ASC, category_id ASC;
```

Swift assembly:

1. For each `(day, category, instrument, qty)` row, parse `day` (an ISO-8601 `YYYY-MM-DD` string) into a `Date` using a stable normaliser — the Gregorian calendar `startOfDay` of the parsed date — so a future timezone change in `Calendar.current` doesn't drift the conversion-date keys. (Reference: `+Conversion.swift:73–94` `financialMonth(for:monthEnd:)` already uses `Calendar.current`; if `current` is what existing code uses to bucket transactions today, mirror it for consistency. Verify during implementation.)
2. Convert the `(qty, instrument)` to `targetInstrument` on the parsed `day` using the existing `convertedAmount` helper.
3. Bucket the converted amount by `(financialMonth(day, monthEnd), category)` using the existing `financialMonth(for:monthEnd:)` helper.
4. After all rows are processed, emit one `ExpenseBreakdown { categoryId, month, totalExpenses }` per non-empty `(month, category)` bucket.

This produces the same numerical result as today's per-leg conversion because the rate cache has 1-day granularity (§3.4 intro). The result-set size is `N_distinct_(day,category,instrument)` instead of `N_legs` — for typical users with 1–5 expense legs per day per category that's a 1.5–5× reduction in conversion calls (the SQL aggregation across same-day legs is the win).

**Indexes used:** `transaction_scheduled` (partial — speeds the `recur_period IS NULL` filter inverted via `WHERE recur_period IS NULL`), `leg_analysis_by_type_category` (covering composite — `(type, category_id, instrument_id, transaction_id, quantity)`).

**Plan-pinning test:** `SEARCH leg USING COVERING INDEX leg_analysis_by_type_category`. Reject `SCAN transaction_leg`.

**Conversion site:** Swift, on each row's `day`, per Rule 5. Use `DateBasedFixedConversionService`-style fixtures in tests (per the test mandate in §3.9) to pin that the right date is passed.

#### 3.4.3 `fetchIncomeAndExpense(monthEnd:after:)`

Today: per-leg loop with per-leg conversion at `transaction.date` (`+IncomeExpense.swift:142–148`); accumulates into `MonthlyIncomeExpense` carrying `income`, `expense`, `profit`, `earmarkedIncome`, `earmarkedExpense`, `earmarkedProfit`. After: SQL query with five conditional aggregates grouped `BY (DATE(t.date), instrument_id)`; Swift converts each `(day, instrument)`'s five sums on `day` and accumulates into financial-month buckets. Same per-day rate-equivalence argument as §3.4.2.

```sql
SELECT
    DATE(t.date)         AS day,
    leg.instrument_id    AS instrument_id,
    SUM(CASE WHEN leg.type = 'income'
              AND a.type IS NOT NULL
              AND a.type <> 'investment'
             THEN leg.quantity ELSE 0 END)        AS income_qty,
    SUM(CASE WHEN leg.type = 'expense'
              AND a.type IS NOT NULL
              AND a.type <> 'investment'
             THEN leg.quantity ELSE 0 END)        AS expense_qty,
    SUM(CASE WHEN leg.earmark_id IS NOT NULL
              AND leg.type = 'income'
             THEN leg.quantity ELSE 0 END)        AS earmarked_income_qty,
    SUM(CASE WHEN leg.earmark_id IS NOT NULL
              AND leg.type = 'expense'
             THEN leg.quantity ELSE 0 END)        AS earmarked_expense_qty,
    SUM(CASE WHEN leg.type = 'transfer'
              AND a.type = 'investment'
             THEN leg.quantity ELSE 0 END)        AS investment_transfer_qty
FROM transaction_leg leg
JOIN "transaction"    t ON leg.transaction_id = t.id
LEFT JOIN account     a ON leg.account_id = a.id
WHERE t.recur_period IS NULL
  AND (:after IS NULL OR t.date >= :after)
GROUP BY day, instrument_id
ORDER BY day ASC;
```

The `'trade'` and `'openingBalance'` leg types are correctly excluded by all five CASE branches (none match either string). The `'transfer'` type only contributes to `investment_transfer_qty`, never to `income_qty`/`expense_qty` (whose CASE conditions pin `type = 'income'` / `'expense'` explicitly).

Swift assembly:

1. For each `(day, instrument)` row, parse `day` and convert each of the five sums to `targetInstrument` on `day` via `convertedAmount(...)` (skipping the conversion when `instrument == targetInstrument`).
2. Bucket the converted sums by `financialMonth(day, monthEnd)`.
3. For each non-empty month bucket, compose `MonthlyIncomeExpense` totals — the investment-transfer column folds into `earmarkedIncome` / `earmarkedExpense` per the sign rules in `+IncomeExpense.swift:142–157` (preserve the exact sign-flip pattern). `profit = income + expense` and `earmarkedProfit = earmarkedIncome + earmarkedExpense` (the rules use signed amounts; expenses are negative — see CLAUDE.md "Monetary Sign Convention").
4. Cross-instrument sums within a `(month, bucket)` happen post-conversion — both summands are already in `targetInstrument`, so Rule 1 is satisfied.

**Verification against the server.** `analysisDao.js:6–42` uses the same conditional-sum shape (note the server is single-instrument so it skips the per-instrument grouping); investment-account transfer routing matches `+IncomeExpense.swift:142–157` exactly. The day-grouping is moolah-native-only (the server backend doesn't have multi-instrument users); the conditional-sum predicates are byte-equivalent.

**Indexes used:** `transaction_by_date` (date filter), `leg_by_transaction` (join), `leg_analysis_by_type_account` (covering — type/account/instrument), `account_by_type` (LEFT JOIN equality probe).

**Plan-pinning test:** `SEARCH leg USING COVERING INDEX leg_analysis_by_type_account`, `SEARCH a USING INDEX account_by_type` (or `INTEGER PRIMARY KEY` on the FK lookup). Reject `SCAN`.

**Conversion site:** Swift, on each row's `day`, per Rule 5.

#### 3.4.4 `fetchCategoryBalances(dateRange:transactionType:filters:targetInstrument:)`

Today: per-leg loop with optional filters (account, payee, earmark, categoryIds) and per-leg conversion at `transaction.date` (`+IncomeExpense.swift:204–239`). After: GRDB query interface composing `(DATE(t.date), category_id, instrument_id)` GROUP BY with optional filter clauses; Swift converts each `(day, category, instrument)` tuple on `day` and accumulates per category. Same per-day rate-equivalence argument as §3.4.2.

**Use the GRDB query interface — not raw SQL — for the `categoryIds` predicate.** SQLite cannot bind a variable-length array to a single named parameter, so an `IN (:categoryIds)` raw-SQL form will fail at runtime for any `categoryIds.count != 1`. Compose the request with conditional `.filter(...)` calls:

```swift
// Conceptual SQL the request below produces:
//   SELECT DATE(t.date) AS day, leg.category_id, leg.instrument_id,
//          SUM(leg.quantity) AS qty
//   FROM transaction_leg leg
//   JOIN "transaction"   t ON leg.transaction_id = t.id
//   LEFT JOIN account    a ON leg.account_id = a.id
//   WHERE t.recur_period IS NULL
//     AND t.date >= :start AND t.date <= :end
//     AND leg.type = :transactionType
//     AND leg.category_id IS NOT NULL
//     AND (a.type IS NULL OR a.type <> 'investment')
//     AND (:accountId IS NULL OR leg.account_id = :accountId)
//     AND (:earmarkId IS NULL OR leg.earmark_id = :earmarkId)
//     AND (:payee IS NULL OR t.payee = :payee)
//     AND (:categoryIdsCount = 0 OR leg.category_id IN (:categoryIds))
//   GROUP BY day, leg.category_id, leg.instrument_id;
//
// Composed via the GRDB query builder so the `IN (:categoryIds)` clause
// becomes the safe `Sequence.contains(Column…)` operator.
var request = TransactionLegRow
  .including(required: TransactionLegRow.transactionAssoc)
  .filter(transactionRequest: { transaction in
    transaction.recurPeriod == nil
      && transaction.date >= dateRange.lowerBound
      && transaction.date <= dateRange.upperBound
      && (filters.payee.map { transaction.payee == $0 } ?? true)
  })
  .filter(TransactionLegRow.Columns.type == transactionType.rawValue)
  .filter(TransactionLegRow.Columns.categoryId != nil)
if let accountId = filters.accountId {
  request = request.filter(TransactionLegRow.Columns.accountId == accountId)
}
if let earmarkId = filters.earmarkId {
  request = request.filter(TransactionLegRow.Columns.earmarkId == earmarkId)
}
if let categoryIds = filters.categoryIds, !categoryIds.isEmpty {
  // Safe IN: GRDB's `contains` operator parameterises the list correctly.
  request = request.filter(categoryIds.contains(TransactionLegRow.Columns.categoryId))
}
let rows = try request
  .annotated(with:
    SQL("DATE(\(TransactionRow.Columns.date))").sqlExpression.forKey("day"))
  .group(
    SQL("DATE(\(TransactionRow.Columns.date))").sqlExpression,
    TransactionLegRow.Columns.categoryId,
    TransactionLegRow.Columns.instrumentId)
  .annotated(with: sum(TransactionLegRow.Columns.quantity).forKey("qty"))
  .asRequest(of: CategoryDayInstrumentTotalRow.self)
  .fetchAll(database)
```

(The exact GRDB association / `SQLExpression` shape varies — pseudocode shows the *parameterisation* contract: never inline `categoryIds` into SQL via `\(…)`. The `DATE(t.date)` projection is via GRDB's `SQL` interpolation type, which parameterises identifier references and is the project-approved escape hatch for SQLite functions not in the query interface.)

Swift assembly:

1. For each `(day, category, instrument, qty)` row, parse `day` and convert `(qty, instrument)` to `targetInstrument` on `day`.
2. Accumulate the converted amount into `balances[categoryId, default: .zero(instrument: targetInstrument)] += converted`.
3. Emit the resulting `[UUID: InstrumentAmount]`.

**Investment-account exclusion check:** the existing implementation **excludes legs from investment accounts** (`+IncomeExpense.swift:191–213` — `applyByType` skips when `classified.isInvestmentAccount`). The composed request includes the `LEFT JOIN account a ON leg.account_id = a.id` and `.filter(a.type == nil || a.type != "investment")` to mirror this. (The non-null branch handles the rare case of an account-less leg, which today's Swift code also includes via `accountId == nil → isInvestmentAccount = false`.) Verify the boolean precedence during implementation — the SQL must accept `a.type IS NULL` legs (orphaned or genuinely account-less).

**Indexes used:** `leg_analysis_by_type_category` (covering for the common `(type, category, instrument)` shape — partial because `category_id IS NOT NULL` is in the filter), `transaction_by_date` for the range, `account_by_type` for the LEFT JOIN, `leg_by_account` / `leg_by_earmark` partial indexes for the optional filters.

**Plan-pinning test:** `SEARCH leg USING COVERING INDEX leg_analysis_by_type_category`. With `accountId` filter set, additionally check `leg_by_account` is consulted. Reject `SCAN`.

**Conversion site:** Swift, on each row's `day`, per Rule 5.

#### 3.4.5 `fetchCategoryBalancesByType(dateRange:filters:targetInstrument:)`

Default protocol implementation runs `fetchCategoryBalances` twice in parallel via `async let` — the existing extension at `AnalysisRepository.swift:103–116`. **Slice 1 considers but does not adopt** the single-pass UNION variant. Two `async let` calls take ~2 ms per query against the indexes above; a UNION saves one transaction at the cost of harder query planning. Stay with the default; revisit if benchmarks justify.

#### 3.4.6 `loadAll(historyAfter:forecastUntil:monthEnd:)`

Default protocol implementation runs the three methods concurrently via `async let` — `AnalysisRepository.swift:118–132`. Slice 1 keeps this intact; the per-method SQL above already minimises shared-data fetches. **Override** in `GRDBAnalysisRepository` only if benchmarks show a single-fetch payoff.

#### 3.4.7 Sidebar account balances

Today: `CloudKitAccountRepository+Positions.computePositions(from:instruments:)` walks every leg and groups by `(accountId, instrumentId)`. After: SQL replacement for the `[(accountId, instrumentId, qty)]` shape:

```sql
SELECT
    leg.account_id,
    leg.instrument_id,
    SUM(leg.quantity) AS qty
FROM transaction_leg leg
JOIN "transaction"   t ON leg.transaction_id = t.id
WHERE t.recur_period IS NULL
  AND leg.account_id IS NOT NULL
GROUP BY leg.account_id, leg.instrument_id
HAVING SUM(leg.quantity) <> 0;
```

The result feeds the existing `Account.balance(in:)` Swift assembly that converts per-instrument totals to the profile instrument on `Date()` (Rule 6). **Decision: SQL-side aggregate; Swift-side conversion.** Per `INSTRUMENT_CONVERSION_GUIDE.md` Rule 6, sidebar totals are current values; the conversion uses `Date()`. **Do not** push conversion into SQL — multi-instrument accounts cannot be summed without converting first.

**Indexes used:** `leg_analysis_by_type_account` (covering — though the SELECT is `(account_id, instrument_id, SUM(quantity))`, the index ordering still serves the GROUP BY).

**Plan-pinning test:** `SEARCH leg USING COVERING INDEX leg_analysis_by_type_account`. Reject `SCAN`.

**`@instrument-conversion-review` review checklist:** historic uses `transaction.date` (per-leg or bucket); current/sidebar uses `Date()`; future/forecast uses `Date()` (clamped). The review must approve the slice — it has the contract on which dates feed which calls.

### 3.5 BackendProvider swap

`Backends/CloudKit/CloudKitBackend.swift` already wires Slice 0's GRDB repos. Slice 1 extends:

```swift
final class CloudKitBackend: BackendProvider {
  // GRDB repos for the eight Slice 1 record types:
  let grdbInstruments: GRDBInstrumentRegistryRepository
  let grdbCategories: GRDBCategoryRepository
  let grdbAccounts: GRDBAccountRepository
  let grdbEarmarks: GRDBEarmarkRepository
  let grdbInvestments: GRDBInvestmentRepository
  let grdbTransactions: GRDBTransactionRepository
  let grdbAnalysis: GRDBAnalysisRepository

  // Slice 0:
  let grdbCSVImportProfiles: GRDBCSVImportProfileRepository
  let grdbImportRules: GRDBImportRuleRepository

  init(modelContainer: ModelContainer, database: DatabaseQueue, …) {
    // Construct in dependency order so each repo's hook closures compose
    // cleanly (the same shape Slice 0 already established for the two
    // synced repos).
    self.grdbInstruments = GRDBInstrumentRegistryRepository(database: database, …)
    self.grdbCategories  = GRDBCategoryRepository(database: database, …)
    self.grdbAccounts    = GRDBAccountRepository(database: database, …)
    self.grdbEarmarks    = GRDBEarmarkRepository(database: database, …)
    self.grdbInvestments = GRDBInvestmentRepository(database: database, …)
    self.grdbTransactions = GRDBTransactionRepository(database: database, …)
    self.grdbAnalysis    = GRDBAnalysisRepository(database: database)
    // Existing Slice 0 wiring...
    // BackendProvider conformance — set the protocol-required properties
    // before init returns. CloudKitBackend is `final class` and conforms
    // to BackendProvider directly; there is no superclass and no
    // `super.init()` call. (`BackendProvider` is the project's injection
    // protocol per CLAUDE.md "Architecture & Constraints".)
    self.accounts          = grdbAccounts
    self.transactions      = grdbTransactions
    self.categories        = grdbCategories
    self.earmarks          = grdbEarmarks
    self.investments       = grdbInvestments
    self.analysis          = grdbAnalysis
    self.instrumentRegistry = grdbInstruments
  }
}
```

The current `_ = modelContainer` reference can stay in `CloudKitBackend` — `Slice 3` strips it. Slice 1 does not delete `Backends/CloudKit/Models/*Record.swift` (the `@Model` classes) because the migrator still reads them; **does** delete `Backends/CloudKit/Repositories/CloudKit*Repository.swift` for the eight migrated types (they are no longer wired and no longer needed as fallback — Slice 0 left its two unwired and the Slice 0 cleanup will delete them; Slice 1 mirrors that delete-and-leave-the-models pattern).

Files to delete in this slice:

```
Backends/CloudKit/Repositories/CloudKitAccountRepository.swift
Backends/CloudKit/Repositories/CloudKitAccountRepository+Positions.swift
Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift
Backends/CloudKit/Repositories/CloudKitCategoryRepository.swift
Backends/CloudKit/Repositories/CloudKitEarmarkRepository.swift
Backends/CloudKit/Repositories/CloudKitInvestmentRepository.swift
Backends/CloudKit/Repositories/CloudKitInstrumentRegistryRepository.swift
Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift
Backends/CloudKit/Repositories/CloudKitAnalysisRepository+Conversion.swift
Backends/CloudKit/Repositories/CloudKitAnalysisRepository+DailyBalances.swift
Backends/CloudKit/Repositories/CloudKitAnalysisRepository+Forecast.swift
Backends/CloudKit/Repositories/CloudKitAnalysisRepository+IncomeExpense.swift
```

Files to keep (the migrator reads them, Slice 3 deletes them):

```
Backends/CloudKit/Models/AccountRecord.swift
Backends/CloudKit/Models/TransactionRecord.swift
Backends/CloudKit/Models/TransactionLegRecord.swift
Backends/CloudKit/Models/CategoryRecord.swift
Backends/CloudKit/Models/EarmarkRecord.swift
Backends/CloudKit/Models/EarmarkBudgetItemRecord.swift
Backends/CloudKit/Models/InstrumentRecord.swift
Backends/CloudKit/Models/InvestmentValueRecord.swift
```

Conversion/forecast helper extensions on the analysis repo (`+Forecast.swift`, `+Conversion.swift`) are partly Swift-only logic that the GRDB version still needs. **Move** the Swift-only helpers to `Backends/GRDB/Repositories/GRDBAnalysisRepository+Forecast.swift` and `+Conversion.swift`; delete the SwiftData siblings.

**`PositionBook` moves to `Shared/PositionBook.swift`** so both the legacy CloudKit-side analysis (kept temporarily for the migrator path) and the new GRDB analysis can use it without a cross-backend dependency. Update the §4 inventory accordingly. The type stays a `Sendable` value type with the same internals; only the file location changes.

### 3.6 CKSyncEngine glue

Eight new entries in each of the dispatch tables. The slice extends — never replaces — the patterns Slice 0 established.

#### 3.6.1 `CloudKitRecordConvertible` on the GRDB rows

Eight new files in `Backends/GRDB/Sync/`, mirroring Slice 0's `CSVImportProfileRow+CloudKit.swift`:

- `Backends/GRDB/Sync/InstrumentRow+CloudKit.swift`
- `Backends/GRDB/Sync/CategoryRow+CloudKit.swift`
- `Backends/GRDB/Sync/AccountRow+CloudKit.swift`
- `Backends/GRDB/Sync/EarmarkRow+CloudKit.swift`
- `Backends/GRDB/Sync/EarmarkBudgetItemRow+CloudKit.swift`
- `Backends/GRDB/Sync/TransactionRow+CloudKit.swift`
- `Backends/GRDB/Sync/TransactionLegRow+CloudKit.swift`
- `Backends/GRDB/Sync/InvestmentValueRow+CloudKit.swift`

Each declares `static var recordType: String { … }` — **the wire string is frozen**. Mirror the existing values verbatim (`"AccountRecord"`, `"TransactionRecord"`, etc.). Use the auto-generated `*RecordCloudKitFields` struct from `Backends/CloudKit/Sync/Generated/` (regenerated by `tools/CKDBSchemaGen` as part of `just generate` — no schema-side changes needed since `CloudKit/schema.ckdb` is unchanged in this slice).

Each implements `toCKRecord(in:)` and `static func fieldValues(from ckRecord:) -> Self?`. Mirror the existing SwiftData-side implementations for the same eight types (`Backends/CloudKit/Sync/<Type>Record+CloudKit.swift`) — those files are deleted at the end of this slice once their callers (the SwiftData repos) are gone. **Every wire field listed in `CloudKit/schema.ckdb` for the record type must appear in the row's `toCKRecord`/`fieldValues(from:)` round-trip** — drop one and the field silently disappears on every upload. Verify each row's coverage against `schema.ckdb` line-by-line before opening the PR; the sync round-trip tests in §3.9 catch missed fields when seeded with a non-default value, but the schema-coverage check is the cheaper first pass.

`fieldValues(from:)` validates enum values against the declared CHECK constraints. If a `CKRecord` arrives with an unknown raw value (a remote client newer than this one, or future-server schema drift), **skip-and-log** the record rather than letting the GRDB upsert trip the CHECK and stall the entire batch on retry. Pattern:

```swift
static func fieldValues(from ckRecord: CKRecord) -> AccountRow? {
  guard let id = ckRecord.recordID.uuid else { return nil }
  let fields = AccountRecordCloudKitFields(from: ckRecord)
  // Validate enum string before constructing the row; SQLite CHECK
  // would surface as `.saveFailed` and CKSyncEngine would retry the
  // same record forever. Skip-and-log keeps the batch moving.
  let typeRaw = fields.type ?? "bank"
  guard AccountType(rawValue: typeRaw) != nil else {
    syncLogger.warning(
      "AccountRow.fieldValues: unknown type '\(typeRaw, privacy: .public)' for \(id.uuidString, privacy: .public) — skipping")
    return nil
  }
  return AccountRow(id: id, /* … */)
}
```

`InstrumentRow` is the only string-keyed row — its `toCKRecord` uses `CKRecord.ID(recordName: row.id, zoneID:)` with no UUID prefixing. Mirror `InstrumentRecord+CloudKit.swift`. **Encoded-system-fields rehydration** is automatic for all rows: the upload path calls `buildCKRecord(from: row, encodedSystemFields: row.encodedSystemFields)` (`ProfileDataSyncHandler.swift:98–113`), which restores the cached `CKRecord` and copies fresh field values from `toCKRecord(in:)` onto it. Don't add rehydration logic inside `toCKRecord` — that's the helper's job; the per-row `toCKRecord` only contributes field values.

`RecordTypeRegistry.allTypes` (in `Backends/CloudKit/Sync/CloudKitRecordConvertible.swift:82–96`) updates the value for each migrated type; the cloud-side `recordType` string is **frozen** — keep it byte-identical.

The existing declaration is `nonisolated(unsafe) static let allTypes: [String: any CloudKitRecordConvertible.Type]` — a guide-prohibited annotation per `CONCURRENCY_GUIDE.md`. Slice 1 inherits the annotation but the value is **literally constant**, write-once at module load, and never mutated. Add an inline justification comment on the existing declaration so the concurrency reviewer can recognise the carve-out:

```swift
// `nonisolated(unsafe)` is acceptable here: this dictionary is a build-
// time-constant literal that is never mutated, and its values (record
// types) are themselves immutable. The annotation is required because
// `any CloudKitRecordConvertible.Type` is not statically `Sendable`
// (Swift's existential `.Type` lacks the conformance), but the values
// are concrete metatypes that ARE thread-safe.
nonisolated(unsafe) static let allTypes: [String: any CloudKitRecordConvertible.Type] = [
  ProfileRecord.recordType:           ProfileRecord.self,            // Slice 3
  InstrumentRow.recordType:           InstrumentRow.self,            // Slice 1 (was: InstrumentRecord.self)
  AccountRow.recordType:              AccountRow.self,               // Slice 1
  TransactionRow.recordType:          TransactionRow.self,           // Slice 1
  TransactionLegRow.recordType:       TransactionLegRow.self,        // Slice 1
  CategoryRow.recordType:             CategoryRow.self,              // Slice 1
  EarmarkRow.recordType:              EarmarkRow.self,               // Slice 1
  EarmarkBudgetItemRow.recordType:    EarmarkBudgetItemRow.self,     // Slice 1
  InvestmentValueRow.recordType:      InvestmentValueRow.self,       // Slice 1
  CSVImportProfileRow.recordType:     CSVImportProfileRow.self,      // Slice 0
  ImportRuleRow.recordType:           ImportRuleRow.self,            // Slice 0
]
```

Delete the now-unused SwiftData `CloudKitRecordConvertible` extensions:

```
Backends/CloudKit/Sync/AccountRecord+CloudKit.swift
Backends/CloudKit/Sync/TransactionRecord+CloudKit.swift
Backends/CloudKit/Sync/TransactionLegRecord+CloudKit.swift
Backends/CloudKit/Sync/CategoryRecord+CloudKit.swift
Backends/CloudKit/Sync/EarmarkRecord+CloudKit.swift
Backends/CloudKit/Sync/EarmarkBudgetItemRecord+CloudKit.swift
Backends/CloudKit/Sync/InstrumentRecord+CloudKit.swift
Backends/CloudKit/Sync/InvestmentValueRecord+CloudKit.swift
```

#### 3.6.2 `ProfileGRDBRepositories` extension

Extend `Backends/CloudKit/Sync/ProfileGRDBRepositories.swift`:

```swift
struct ProfileGRDBRepositories: @unchecked Sendable {
  let instruments: GRDBInstrumentRegistryRepository
  let categories:  GRDBCategoryRepository
  let accounts:    GRDBAccountRepository
  let earmarks:    GRDBEarmarkRepository
  let earmarkBudgetItems: GRDBEarmarkBudgetItemRepository  // (or fold into `earmarks` — see below)
  let investmentValues: GRDBInvestmentRepository
  let transactions: GRDBTransactionRepository
  // (transaction legs share the transactions repo)
  let csvImportProfiles: GRDBCSVImportProfileRepository
  let importRules: GRDBImportRuleRepository
}
```

`earmark_budget_item` deserves a separate `GRDBEarmarkBudgetItemRepository` because its `applyRemoteChangesSync` / `setEncodedSystemFieldsSync` etc. are typed against `EarmarkBudgetItemRow`. Keeping it inside `GRDBEarmarkRepository` would force ad-hoc dispatch on row type and lose type safety. Same reasoning for `transaction_leg`: a separate `GRDBTransactionLegRepository` for the sync entry points, with the public `TransactionRepository` protocol still implemented by the `GRDBTransactionRepository` that orchestrates header + legs as one unit. Two decisions land in the bundle: `earmarkBudgetItems` and `transactionLegs` get their own typed sync-only repo entries.

Updated bundle. **Plain `Sendable` if synthesis succeeds; `@unchecked Sendable` only if it fails.** A struct with all `let` properties is automatically `Sendable` if every field type is `Sendable` — and every GRDB repository on this list is itself `@unchecked Sendable`, so the struct's auto-synthesis should succeed. If the compiler rejects (because Swift's `Sendable` synthesis is conservative around `@unchecked Sendable` field types), fall back to `@unchecked Sendable` on the struct **with the inline justification block below**. Default to plain `Sendable`:

```swift
struct ProfileGRDBRepositories: Sendable {
  let instruments: GRDBInstrumentRegistryRepository
  let categories:  GRDBCategoryRepository
  let accounts:    GRDBAccountRepository
  let earmarks:    GRDBEarmarkRepository
  let earmarkBudgetItems: GRDBEarmarkBudgetItemRepository
  let investmentValues:   GRDBInvestmentRepository
  let transactions:       GRDBTransactionRepository
  let transactionLegs:    GRDBTransactionLegRepository
  let csvImportProfiles:  GRDBCSVImportProfileRepository
  let importRules:        GRDBImportRuleRepository
}
```

If the compiler rejects, the fallback shape is:

```swift
// @unchecked Sendable: every field is a `final class … : @unchecked
// Sendable` repository (see GRDBCSVImportProfileRepository.swift for
// the per-repo justification). The struct holds only let-bound
// references, never mutates post-init, and is shared read-only across
// the CKSyncEngine delegate executor and main-actor surfaces.
struct ProfileGRDBRepositories: @unchecked Sendable { /* …same fields */ }
```

#### 3.6.3 `ProfileDataSyncHandler+GRDBDispatch.swift`

Extend the `applyGRDBBatchSave` and `applyGRDBBatchDeletion` switches with eight new cases each. Same shape as Slice 0's two cases — convert the `[CKRecord]` to `[Row]` via the row's `fieldValues(from:)`, stamp `encodedSystemFields` from the lookup, and call `repo.applyRemoteChangesSync(saved:deleted:)`. `Self.batchLogger.error(...)` on failure; `throw error` so `applyRemoteChanges` returns `.saveFailed(...)` and CKSyncEngine refetches. **Critical:** must propagate errors — silent `try?` swallows would advance the change token past dropped records (the issue Slice 0 round-2 review caught and fixed).

#### 3.6.4 `+ApplyRemoteChanges.swift` dispatch tables

Remove the eight SwiftData entries from `batchUpserters` and `uuidDeleters`; the GRDB dispatch table already short-circuits these record types via `applyGRDBBatchSave` / `applyGRDBBatchDeletion`. Leave only the `ProfileRecord` carve-out (handled by `ProfileIndexSyncHandler`).

#### 3.6.5 `+SystemFields.swift`

Extend `applyGRDBSystemFields(recordType:id:data:) -> Bool` with seven new UUID-keyed cases (Account, Transaction, TransactionLeg, Category, Earmark, EarmarkBudgetItem, InvestmentValue) plus the special string-keyed case for InstrumentRow (below), each calling the corresponding `repo.setEncodedSystemFieldsSync(...)`. Remove the eight SwiftData entries from the `systemFieldSetters` static dispatch table. `clearAllSystemFields()` gains eight new `try grdbRepositories.<repo>.clearAllSystemFieldsSync()` calls — order is **arbitrary** (UPDATE on every row of every table; no FK ordering needed); pick alphabetical or dependency order for readability. **Mandatory test (§3.9):** assert every GRDB-backed table has its `encoded_system_fields` column wiped.

In `applyGRDBBatchSave`'s field-stamp step, **`InstrumentRow`'s lookup key is the bare string id, not the UUID stringification.** Slice 0's pattern uses `systemFields[row.id.uuidString]` for UUID-keyed rows; for `InstrumentRow` use `systemFields[row.id]` directly. Verify against `CKRecordIDRecordName.systemFieldsKey(for:)` — the helper normalises both paths.

`InstrumentRow` is special: its system-fields key is the `id` (string), not a UUID. Replace `setInstrumentSystemFields` with a GRDB-side version that calls `grdbRepositories.instruments.setEncodedSystemFieldsSync(id: String, data: Data?)` — the repo grows a string-keyed setter alongside its UUID-keyed cousins. The dispatch in `applySystemFields(_:in:)` keeps the early-return shape:

```swift
if ckRecord.recordType == InstrumentRow.recordType {
  applyGRDBInstrumentSystemFields(id: ckRecord.recordID.systemFieldsKey, data: data)
  return
}
```

#### 3.6.6 `+QueueAndDelete.swift` ordering

Swap the eight SwiftData fetches in `queueAllExistingRecords()` and `queueUnsyncedRecords()` for `collectAllGRDBUUIDs(...)` calls (or `collectAllGRDBStringIDs(...)` for instruments). **Preserve the dependency order** documented in the comment (instruments → categories → accounts → earmarks → budget items → investment values → transactions → transaction legs → CSV → rules) — this is the order CKSyncEngine queues uploads in, and it matters for first-launch ordering. The Slice 0 helper `collectAllGRDBUUIDs(ids:recordType:into:)` covers the UUID-keyed types; add a new sibling for instruments (the only string-keyed row in Slice 1):

```swift
private func collectAllGRDBStringIDs(
  ids: () throws -> [String],
  recordType: String,
  into recordIDs: inout [CKRecord.ID]
) {
  do {
    for id in try ids() {
      // No UUID prefixing — Instrument recordIDs use the bare id
      // as the recordName (`"AUD"`, `"ASX:BHP"`, `"1:0xa0…"`).
      recordIDs.append(CKRecord.ID(recordName: id, zoneID: zoneID))
    }
  } catch {
    logger.error(
      """
      GRDB fetch failed for \(recordType, privacy: .public) on profile \
      \(self.profileId, privacy: .public): \
      \(error.localizedDescription, privacy: .public)
      """)
  }
}
```

`deleteLocalData()` gains eight new `try grdbRepositories.<repo>.deleteAllSync()` calls. **`category.parent_id ON DELETE NO ACTION` will trip a FK violation on a wipe of the category table** (a parent row whose children still reference it). Two options:

1. **Disable FK enforcement for the wipe** (preferred — simpler):

   ```swift
   try database.write { database in
     try database.execute(sql: "PRAGMA foreign_keys = OFF")
     defer { try? database.execute(sql: "PRAGMA foreign_keys = ON") }
     try CategoryRow.deleteAll(database)
     // … other deleteAll calls
   }
   ```

   The wipe is the only path that needs this; production CRUD always runs with FKs on.

2. **Delete child categories before parents** with a recursive query — more code, no real benefit since the wipe is wholesale.

**Pick option 1.** Update each repo's `deleteAllSync()` to accept this responsibility, OR keep `deleteAllSync` simple and have `deleteLocalData()` toggle the PRAGMA at the outer level. Slice 0's existing `deleteAllSync()` doesn't manage PRAGMAs; mirror that — `deleteLocalData()` is where the PRAGMA toggle lives.

Beyond the category-hierarchy issue, **respect dependency-reverse order anyway** (legs → transactions → investment values → budget items → earmarks → accounts → categories → instruments) so partial-failure best-effort semantics leave a consistent state. **Mandatory test (§3.9):** seed all eight tables, run `deleteLocalData()`, assert all tables are empty.

#### 3.6.7 `+RecordLookup.swift`

Swap the eight SwiftData fetch helpers in `fetchAndBuild(recordType:uuid:context:)` and `batchFetchByType(recordType:uuids:context:)` for GRDB row fetches via `grdbRepositories.<repo>.fetchRowSync(id:)` / `fetchRowsSync(ids:)`. Mirror Slice 0's `fetchCSVImportProfileRow(id:)` shape for the wrapper helpers. The string-keyed `fetchInstrument` → `fetchInstrumentRow(id: String)` swap.

`mapBuiltRows` (Slice 0's value-type helper) already handles the rows; reuse it for all eight new types.

#### 3.6.8 `+BatchUpsert.swift` deletion

`Backends/CloudKit/Sync/ProfileDataSyncHandler+BatchUpsert.swift` becomes substantially smaller — only `ProfileRecord` and `Profile`-index code remain. Slice 1 deletes the eight `batchUpsert<Type>` static methods and any helpers that exclusively support them (e.g. `applyByUUID<T>` if it has no remaining users). Verify by `grep` before deleting. The `Profile`-related code stays intact for Slice 3.

### 3.7 SwiftData → GRDB migrator extension

Extend `Backends/GRDB/Migration/SwiftDataToGRDBMigrator.swift` with eight per-type migrators. Reuse Slice 0's pattern: per-type private method + per-type `UserDefaults` flag + `committed` `defer` flag + `upsert` (idempotent re-run).

Flags (one per type):

```swift
static let instrumentsFlag         = "v3.instruments.grdbMigrated"
static let categoriesFlag          = "v3.categories.grdbMigrated"
static let accountsFlag            = "v3.accounts.grdbMigrated"
static let earmarksFlag            = "v3.earmarks.grdbMigrated"
static let earmarkBudgetItemsFlag  = "v3.earmarkBudgetItems.grdbMigrated"
static let investmentValuesFlag    = "v3.investmentValues.grdbMigrated"
static let transactionsFlag        = "v3.transactions.grdbMigrated"
static let transactionLegsFlag     = "v3.transactionLegs.grdbMigrated"
```

`migrateIfNeeded(...)` runs the existing two Slice 0 migrators, then the eight new ones in dependency order:

```swift
try migrateInstrumentsIfNeeded(…)
try migrateCategoriesIfNeeded(…)
try migrateAccountsIfNeeded(…)
try migrateEarmarksIfNeeded(…)
try migrateEarmarkBudgetItemsIfNeeded(…)
try migrateInvestmentValuesIfNeeded(…)
try migrateTransactionsIfNeeded(…)
try migrateTransactionLegsIfNeeded(…)
// (Slice 0's two run after the core graph; CSV imports reference accounts.)
try migrateCSVImportProfilesIfNeeded(…)
try migrateImportRulesIfNeeded(…)
```

Each migrator:

1. Early-return if its flag is set.
2. Open a `ModelContext(modelContainer)`, fetch all rows via `FetchDescriptor<…Record>()`, surface a `try`-throw on fetch failure to the caller. (Slice 0 logs and re-throws; mirror the pattern.)
3. Map each `@Model` instance to a GRDB row via a per-type `Self.map<Type>(_:)` static method. **Preserve `encodedSystemFields` byte-for-byte.** **Preserve all FK references** (`accountId`, `categoryId`, `earmarkId`, `transactionId`, `parentId`).
4. Inside one `database.write { … }`, call `row.upsert(database)` for every row. **One transaction per type** — keeps blast radius small and re-run idempotent.
5. After the transaction commits (`var committed = true`), the `defer` block flips the flag.

⚠ **Per-type flags vs single transaction.** Migrating all eight types in one transaction would be more atomic but trips two concerns: (a) the SwiftData `ModelContext` `fetch` is `@MainActor` and blocking the main thread on eight large fetches in one block hurts launch time; (b) a single transaction across all eight tables risks scaling poorly on large stores (tens of thousands of legs). Per-type with per-type flags wins on both axes; the order constraint (parents before children) is preserved by the dependency order above. **Do not** combine.

⚠ **FK insertion order.** Inside a single per-type transaction the rows are independent of their FK targets *for that table* — but the migrator runs types in parents-before-children order so `transaction_leg`'s FKs are valid when its transaction commits. `PRAGMA foreign_keys = ON` is on at all times; if a row references a parent that isn't yet migrated, the upsert will fail loudly — which is exactly what we want.

⚠ **`UNIQUE record_name` collisions.** The migrator uses `upsert`, so a re-run that hits an already-imported row is a no-op match on the PK. The `record_name UNIQUE` constraint is satisfied because `Row.recordName(for: id)` is total over `id`. Verify the conflict-target behaviour during implementation; if `upsert` doesn't infer the right conflict target (the GRDB API `record.upsert(db)` defaults to the PK), fall back to explicit `INSERT … ON CONFLICT(id) DO UPDATE …` per Slice 0's pattern.

⚠ **Investment-value composite key.** The SwiftData `InvestmentValueRecord` has a `(accountId, date)` semantic uniqueness but the actual PK is `id: UUID`. The GRDB row mirrors that — PK on `id`, no composite unique constraint. The application enforces the (account, date) uniqueness at the repository layer (existing semantics; preserve).

⚠ **`@MainActor` fetch budget — convert the migrator to `async`.** The Slice 0 migrator runs `@MainActor` synchronously and emits a `#if DEBUG` warning if it exceeds 16ms. With eight types added, `transactions` and `transaction_legs` will exceed that on any heavy user — tens of thousands of rows means hundreds of milliseconds blocking the main thread on first launch. **Slice 1 converts `migrateIfNeeded` to `async throws`** so it can run off the main actor. The shape:

- `SwiftDataToGRDBMigrator` keeps `@MainActor` only for the SwiftData `ModelContext` interactions (the `mainContext`-bound `context.fetch` calls require it). The GRDB writes happen in `database.write { … }` closures, which are queue-serialised and don't need main-actor isolation.
- `migrateIfNeeded` becomes `async throws`. The `@MainActor` annotation moves to the inner SwiftData fetch helpers; the public entry point is non-isolated.
- `ProfileSession.runSwiftDataToGRDBMigrationIfNeeded` becomes `async throws` and the call site in `ProfileSession.init` (or its sibling launch path) `await`s it.
- The `#if DEBUG` 16ms warning stays — now it's a sanity check that nothing on the migrator path accidentally reverts to synchronous main-actor work.

This is a deliberate departure from Slice 0's "synchronous and `@MainActor`" pattern. Slice 0's file header explicitly anticipated this conversion ("If profiling ever shows this blocks for >16ms (one frame) on a p99 device, convert `migrateIfNeeded` to async"). Slice 1 is the slice that does it.

### 3.8 Test seam updates

`MoolahTests/Support/TestBackend.swift` is the seed harness used by every store/contract test. Slice 1 swaps it from SwiftData inserts to GRDB writes:

- The `seed(accounts:in:)` family becomes `seed(accounts:in:database:)` — same shape, but writes to the `account` GRDB table via `AccountRow.from(account).insert(database)` inside a `database.write` block.
- Same swap for `transactions`, `earmarks`, `categories`, `investmentValues`, `seedBudget(...)`.
- The legacy SwiftData `context.insert(...)` calls go away.

`TestBackend.create()` already constructs the in-memory `database` (Slice 0 wired this). Pass it to seed; everything else compiles.

`MoolahTests/Support/CloudKitAnalysisTestBackend.swift` may have a seed path that pre-populates `PositionBook` state — verify and adapt.

`MoolahTests/Support/ProfileDataSyncHandlerTestSupport.swift` already exists; verify its construction path picks up Slice 1's `ProfileGRDBRepositories` extension.

### 3.9 Tests

**Test framework:** Slice 1 uses **Swift Testing** (`@Suite`, `@Test`, `#expect`, `#require`) — not XCTest — consistent with the existing harness on `main` (Slice 0's `SwiftDataToGRDBMigratorTests.swift`, `CSVImportRollbackTests.swift`, `SyncRoundTripCSVImportTests.swift` all use Swift Testing). Pseudocode shown below uses descriptive naming; translate every `XCTest` shape from external references into the Swift Testing equivalent.

Mandatory:

- **Contract tests** for all eight repositories (or seven, if the EarmarkBudgetItem CRUD lives inside `GRDBEarmarkRepository.setBudget`/`fetchBudget`). Each contract test in `MoolahTests/Domain/<Type>RepositoryContractTests.swift` already exists (verify) and runs against `TestBackend`. **They must pass unchanged** once `TestBackend` is rewired to GRDB.
- **Plan-pinning tests** for every analysis hot-path query (§3.4.1–.7). One test per query in `MoolahTests/Backends/GRDB/AnalysisPlanPinningTests.swift`. Each asserts `SEARCH … USING (COVERING) INDEX …` against the table list above; rejects `SCAN <table>` and `USE TEMP B-TREE FOR ORDER BY`. Pattern: `DATABASE_CODE_GUIDE.md` §6 sample.
- **Plan-pinning tests** for the non-analysis hot-path queries: `TransactionRepository.fetch(filter:page:pageSize:)` (the paginated read), `TransactionRepository.fetchPayeeSuggestions(prefix:)`, `EarmarkRepository.fetchBudget(earmarkId:)`, `InvestmentRepository.fetchValues(accountId:page:)`. One file: `MoolahTests/Backends/GRDB/CoreFinancialGraphPlanPinningTests.swift`.
- **Rollback tests** for every multi-statement write:
  - `GRDBAccountRepository.create(_:openingBalance:date:)` — opening-balance txn + leg + account row.
  - `GRDBTransactionRepository.create(_:)` — header + legs.
  - `GRDBTransactionRepository.update(_:)` — replace-legs path.
  - `GRDBCategoryRepository.delete(id:withReplacement:)` — UPDATE legs + UPDATE budget items + DELETE category.
  - `GRDBEarmarkRepository.setBudget(...)` — upsert budget item + (selective) delete.
  - `GRDBInvestmentRepository.setValue(...)` — SELECT-then-UPDATE-or-INSERT (§3.3.5).
  Each test seeds prior state, forces a constraint violation mid-transaction (e.g. write a row with an oversized value to trip a CHECK, or pass an invalid FK to trip the FK enforcement), asserts the prior state survives. Pattern reference: `MoolahTests/Backends/SQLiteCoinGeckoCatalogStorageTests.swift:77–104` and Slice 0's `MoolahTests/Backends/GRDB/CSVImportRollbackTests.swift`.

- **Hook fan-out regression tests** for the multi-type emit paths:
  - `GRDBAccountRepository.create(_:openingBalance:date:)` with non-zero balance: pass a recording closure for `onRecordChanged`; assert the emitted `(recordType, id)` pairs are exactly `(AccountRow.recordType, accountId)`, `(TransactionRow.recordType, txnId)`, `(TransactionLegRow.recordType, legId)`. With zero / nil balance: only the account emission fires. (Prevents the silent-data-loss class of bug where the implicit txn/leg never reach CKSyncEngine.)
  - `GRDBCategoryRepository.delete(id:withReplacement:)` with N affected legs and M affected budget items: assert exactly N `TransactionLegRow.recordType` emissions and M `EarmarkBudgetItemRow.recordType` emissions plus one `CategoryRow.recordType` deletion — no unknown-record-type emissions, no off-by-one.
  These tests don't need the database; they test the repo's hook discipline against a recording closure. One file: `MoolahTests/Backends/GRDB/CoreFinancialGraphHookTests.swift`.

- **`clearAllSystemFields()` coverage test** in `MoolahTests/Backends/CloudKit/Sync/ClearAllSystemFieldsTests.swift`: seed every GRDB-backed table with a non-nil `encoded_system_fields` blob; call `ProfileDataSyncHandler.clearAllSystemFields()`; assert every table's column is now nil. Catches the regression class where a new GRDB table is added but `clearAllSystemFields` isn't extended to wipe it.

- **`deleteLocalData()` coverage test:** seed every GRDB-backed table; call `deleteLocalData()`; assert all tables are empty (including parent categories with children — verifying the FK-OFF wipe path works). One file: `MoolahTests/Backends/CloudKit/Sync/DeleteLocalDataTests.swift`.
- **Sync round-trip tests** for the eight types. Add one file per type (or one omnibus file `MoolahTests/Backends/GRDB/CoreFinancialGraphSyncRoundTripTests.swift`). Pattern: build two `TestBackend` instances representing two devices; create on A; manually drive `CKSyncEngine.applyRemoteChanges` on B with the recorded outbound batch; assert the GRDB row on B matches the source bit-for-bit including `encodedSystemFields`. Reuse Slice 0's `SyncRoundTripCSVImportTests.swift` as the template.
- **Migrator tests.** Extend `MoolahTests/Backends/GRDB/SwiftDataToGRDBMigratorTests.swift` with eight new test methods, one per type. For each: seed a SwiftData container with N rows + non-nil `encodedSystemFields`, open an in-memory GRDB queue, run `migrateIfNeeded`, assert all rows present in GRDB, `encodedSystemFields` byte-equal to source, flag set. **Re-run is no-op.** Add a cross-FK migrator test that seeds all eight types in dependency order and asserts the FK-bearing rows preserve their parent IDs.
- **Conversion tests.** `MoolahTests/Backends/GRDB/GRDBAnalysisConversionTests.swift` — for each of the five `AnalysisRepository` methods, seed a multi-instrument fixture (mix of fiat A, fiat B, stock C) and assert the post-SQL Swift conversion produces the same `InstrumentAmount` totals as the existing SwiftData implementation on the same fixture. (The fixture and assertion library should already exist in `MoolahTests/Domain/AnalysisRepositoryContractTests.swift` — verify and extend.)
- **Date-sensitive conversion tests.** Per `INSTRUMENT_CONVERSION_GUIDE.md` and the §3.4 per-day grouping decision, every historic-conversion method needs at least one test that uses a `DateBasedFixedConversionService` fixture (a `InstrumentConversionService` stub that returns a *different* rate for each calendar day). Construct fixtures with legs spanning at least two calendar days with rates that differ between days; assert that the per-day-grouped SQL + Swift assembly produces the correct day-keyed conversion. Without this, a regression where the SQL drops the `DATE(t.date)` projection (collapsing to per-month or per-range) would silently pass against constant-rate fixtures. Apply to: `fetchExpenseBreakdown`, `fetchIncomeAndExpense`, `fetchCategoryBalances`, and `fetchDailyBalances` (the latter is already per-day; the test pins that property).
- **Benchmark deltas.** Run `MoolahBenchmarks/AnalysisBenchmarks.swift` (`testLoadAll_12months`, `testLoadAll_allHistory`, `testFetchCategoryBalances`, `testFetchCategoryBalancesByType`) on `main` and on the slice branch. **Target:** 5–10× speedup on `testLoadAll_allHistory` (the Swift loop today is ~O(n×m) for n txns × m days; SQL with covering index is ~O(n) with the index alone). At minimum:
  - `testLoadAll_12months` ≥ 3× speedup (smaller dataset, less SQL gain headroom).
  - `testLoadAll_allHistory` ≥ 5× speedup.
  - `testFetchCategoryBalances` ≥ 5× speedup.
  - `testFetchCategoryBalancesByType` ≥ 5× speedup.
  - Memory regression acceptable: 0–10% increase (GRDB query buffers vs SwiftData fetch — they're roughly equivalent).
  Acceptance treats a < 3× speedup on the 12-month case as a slice-blocking regression — reverify the index plan-pinning tests; the SQL is missing an index it needs.
- **Pre/post benchmark numbers** are committed to the PR description, not to a baselines file (see open question §8). The numbers go into `.agent-tmp/benchmark-pre.txt` and `.agent-tmp/benchmark-post.txt` for the implementer's reference; they're paraphrased into the PR body and not committed. (Slice 0 followed this convention.)

Mandatory plan-pinning queries to add to `AnalysisPlanPinningTests.swift`:

| Method | Index expected | Rejection |
|---|---|---|
| `fetchDailyBalances` per-day SUM (whole-DB) | `leg_analysis_by_type_account` (COVERING) | `SCAN transaction_leg` |
| `fetchDailyBalances` investment-value lookup | `iv_by_account_date_value` (COVERING) | `SCAN investment_value` |
| `InvestmentRepository.fetchDailyBalances(accountId:)` per-account variant | `iv_by_account_date_value` (COVERING) + `leg_analysis_by_type_account` filtered to the account | `SCAN` of either |
| `GRDBInvestmentRepository.setValue` SELECT-then-UPDATE | `iv_by_account_date_value` (COVERING) | `SCAN investment_value` |
| `fetchExpenseBreakdown` GROUP BY | `leg_analysis_by_type_category` (COVERING) | `SCAN transaction_leg` |
| `fetchIncomeAndExpense` GROUP BY | `leg_analysis_by_type_account` (COVERING) | `SCAN transaction_leg` |
| `fetchCategoryBalances` GROUP BY | `leg_analysis_by_type_category` (COVERING) | `SCAN transaction_leg` |
| `fetchCategoryBalances` w/ accountId filter | `leg_by_account` (partial) | `SCAN transaction_leg` |
| `fetchCategoryBalances` w/ earmarkId filter | `leg_by_earmark` (partial) | `SCAN transaction_leg` |
| Sidebar `computePositions` | `leg_analysis_by_type_account` (COVERING) | `SCAN transaction_leg` |
| `fetchPayeeSuggestions` | `transaction_by_payee` (partial) | `SCAN "transaction"` |
| Forecast scheduled lookup | `transaction_scheduled` (partial) | `SCAN "transaction"` |

---

## 4. File-level inventory of edits

| File | Action |
|---|---|
| `Backends/GRDB/ProfileSchema.swift` | Add `v3_core_financial_graph` migration — eight tables in dependency order |
| `Backends/GRDB/Records/InstrumentRow.swift` | NEW |
| `Backends/GRDB/Records/InstrumentRow+Mapping.swift` | NEW |
| `Backends/GRDB/Records/CategoryRow.swift` | NEW |
| `Backends/GRDB/Records/CategoryRow+Mapping.swift` | NEW |
| `Backends/GRDB/Records/AccountRow.swift` | NEW |
| `Backends/GRDB/Records/AccountRow+Mapping.swift` | NEW |
| `Backends/GRDB/Records/EarmarkRow.swift` | NEW |
| `Backends/GRDB/Records/EarmarkRow+Mapping.swift` | NEW |
| `Backends/GRDB/Records/EarmarkBudgetItemRow.swift` | NEW |
| `Backends/GRDB/Records/EarmarkBudgetItemRow+Mapping.swift` | NEW |
| `Backends/GRDB/Records/TransactionRow.swift` | NEW |
| `Backends/GRDB/Records/TransactionRow+Mapping.swift` | NEW |
| `Backends/GRDB/Records/TransactionLegRow.swift` | NEW |
| `Backends/GRDB/Records/TransactionLegRow+Mapping.swift` | NEW |
| `Backends/GRDB/Records/InvestmentValueRow.swift` | NEW |
| `Backends/GRDB/Records/InvestmentValueRow+Mapping.swift` | NEW |
| `Backends/GRDB/Sync/InstrumentRow+CloudKit.swift` | NEW |
| `Backends/GRDB/Sync/CategoryRow+CloudKit.swift` | NEW |
| `Backends/GRDB/Sync/AccountRow+CloudKit.swift` | NEW |
| `Backends/GRDB/Sync/EarmarkRow+CloudKit.swift` | NEW |
| `Backends/GRDB/Sync/EarmarkBudgetItemRow+CloudKit.swift` | NEW |
| `Backends/GRDB/Sync/TransactionRow+CloudKit.swift` | NEW |
| `Backends/GRDB/Sync/TransactionLegRow+CloudKit.swift` | NEW |
| `Backends/GRDB/Sync/InvestmentValueRow+CloudKit.swift` | NEW |
| `Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository.swift` | NEW |
| `Backends/GRDB/Repositories/GRDBCategoryRepository.swift` | NEW |
| `Backends/GRDB/Repositories/GRDBAccountRepository.swift` | NEW |
| `Backends/GRDB/Repositories/GRDBEarmarkRepository.swift` | NEW |
| `Backends/GRDB/Repositories/GRDBEarmarkBudgetItemRepository.swift` | NEW (sync-only entry points) |
| `Backends/GRDB/Repositories/GRDBInvestmentRepository.swift` | NEW |
| `Backends/GRDB/Repositories/GRDBTransactionRepository.swift` | NEW |
| `Backends/GRDB/Repositories/GRDBTransactionLegRepository.swift` | NEW (sync-only entry points) |
| `Backends/GRDB/Repositories/GRDBAnalysisRepository.swift` | NEW |
| `Backends/GRDB/Repositories/GRDBAnalysisRepository+Conversion.swift` | NEW (Swift conversion helpers; ported from CloudKit-side) |
| `Backends/GRDB/Repositories/GRDBAnalysisRepository+DailyBalances.swift` | NEW (Swift assembly post-SQL) |
| `Backends/GRDB/Repositories/GRDBAnalysisRepository+Forecast.swift` | NEW (forecast extrapolation; ported) |
| `Backends/GRDB/Repositories/GRDBAnalysisRepository+IncomeExpense.swift` | NEW (per-method query bodies) |
| `Backends/GRDB/Migration/SwiftDataToGRDBMigrator.swift` | Extend with eight per-type migrators + flags |
| `Backends/CloudKit/Sync/ProfileGRDBRepositories.swift` | Extend bundle with 8 new fields |
| `Backends/CloudKit/Sync/ProfileDataSyncHandler+GRDBDispatch.swift` | Add 8 cases each to `applyGRDBBatchSave` / `applyGRDBBatchDeletion` |
| `Backends/CloudKit/Sync/ProfileDataSyncHandler+ApplyRemoteChanges.swift` | Remove 8 SwiftData entries from `batchUpserters` and `uuidDeleters` |
| `Backends/CloudKit/Sync/ProfileDataSyncHandler+SystemFields.swift` | Extend `applyGRDBSystemFields` w/ 8 cases; remove 8 SwiftData entries from `systemFieldSetters`; rewrite `applyInstrumentSystemFields` for GRDB |
| `Backends/CloudKit/Sync/ProfileDataSyncHandler+QueueAndDelete.swift` | Swap 8 `collectAllUUIDs(...)` calls for `collectAllGRDBUUIDs(...)` (preserve order); add `collectAllGRDBStringIDs` for instruments; extend `deleteLocalData` with 8 GRDB `deleteAllSync()` calls |
| `Backends/CloudKit/Sync/ProfileDataSyncHandler+RecordLookup.swift` | Swap 8 SwiftData fetches for GRDB row fetches |
| `Backends/CloudKit/Sync/ProfileDataSyncHandler+BatchUpsert.swift` | Delete 8 `batchUpsert<Type>` static methods |
| `Backends/CloudKit/Sync/CloudKitRecordConvertible.swift` | Update `RecordTypeRegistry.allTypes` to point at `*Row` types |
| `Backends/CloudKit/Sync/AccountRecord+CloudKit.swift` | DELETE — superseded |
| `Backends/CloudKit/Sync/TransactionRecord+CloudKit.swift` | DELETE — superseded |
| `Backends/CloudKit/Sync/TransactionLegRecord+CloudKit.swift` | DELETE — superseded |
| `Backends/CloudKit/Sync/CategoryRecord+CloudKit.swift` | DELETE — superseded |
| `Backends/CloudKit/Sync/EarmarkRecord+CloudKit.swift` | DELETE — superseded |
| `Backends/CloudKit/Sync/EarmarkBudgetItemRecord+CloudKit.swift` | DELETE — superseded |
| `Backends/CloudKit/Sync/InstrumentRecord+CloudKit.swift` | DELETE — superseded |
| `Backends/CloudKit/Sync/InvestmentValueRecord+CloudKit.swift` | DELETE — superseded |
| `Backends/CloudKit/Repositories/CloudKitAccountRepository.swift` | DELETE |
| `Backends/CloudKit/Repositories/CloudKitAccountRepository+Positions.swift` | DELETE |
| `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift` | DELETE |
| `Backends/CloudKit/Repositories/CloudKitCategoryRepository.swift` | DELETE |
| `Backends/CloudKit/Repositories/CloudKitEarmarkRepository.swift` | DELETE |
| `Backends/CloudKit/Repositories/CloudKitInvestmentRepository.swift` | DELETE |
| `Backends/CloudKit/Repositories/CloudKitInstrumentRegistryRepository.swift` | DELETE |
| `Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift` | DELETE |
| `Backends/CloudKit/Repositories/CloudKitAnalysisRepository+Conversion.swift` | DELETE |
| `Backends/CloudKit/Repositories/CloudKitAnalysisRepository+DailyBalances.swift` | DELETE |
| `Backends/CloudKit/Repositories/CloudKitAnalysisRepository+Forecast.swift` | DELETE |
| `Backends/CloudKit/Repositories/CloudKitAnalysisRepository+IncomeExpense.swift` | DELETE |
| `Backends/CloudKit/Models/AccountRecord.swift` | UNCHANGED — kept for migrator until Slice 3 |
| `Backends/CloudKit/Models/TransactionRecord.swift` | UNCHANGED — same |
| `Backends/CloudKit/Models/TransactionLegRecord.swift` | UNCHANGED — same |
| `Backends/CloudKit/Models/CategoryRecord.swift` | UNCHANGED — same |
| `Backends/CloudKit/Models/EarmarkRecord.swift` | UNCHANGED — same |
| `Backends/CloudKit/Models/EarmarkBudgetItemRecord.swift` | UNCHANGED — same |
| `Backends/CloudKit/Models/InstrumentRecord.swift` | UNCHANGED — same |
| `Backends/CloudKit/Models/InvestmentValueRecord.swift` | UNCHANGED — same |
| `Backends/CloudKit/CloudKitBackend.swift` | Wire eight new GRDB repos; remove SwiftData repo construction; pass `database` everywhere |
| `Shared/PositionBook.swift` | MOVE from `Backends/CloudKit/...` (or wherever it currently lives) — see §3.5 |
| `Domain/Repositories/AccountRepository.swift` | EDIT — `create(_:openingBalance:)` gains a `date: Date` parameter (boundary discipline per CODE_GUIDE.md §17). Update every call site. |
| `Shared/PreviewBackend.swift` | Construct GRDB repos with the existing in-memory `database` |
| `MoolahTests/Support/TestBackend.swift` | Rewrite eight `seed(...)` family methods to write GRDB rows instead of SwiftData |
| `MoolahTests/Support/CloudKitAnalysisTestBackend.swift` | Adapt to GRDB seed shape (verify usage) |
| `MoolahTests/Support/ProfileDataSyncHandlerTestSupport.swift` | Verify it picks up the extended `ProfileGRDBRepositories` |
| `App/ProfileSession+SyncWiring.swift` | Pass eight new `let grdb<Type>` references through to the bundle |
| `App/ProfileSession.swift` | No structural change (the migrator hook is already in place from Slice 0) |
| `MoolahTests/Domain/AccountRepositoryContractTests.swift` | Should pass unchanged; if not, fix the repo to honour the protocol |
| `MoolahTests/Domain/TransactionRepositoryContractTests.swift` | Same |
| `MoolahTests/Domain/CategoryRepositoryContractTests.swift` | Same |
| `MoolahTests/Domain/EarmarkRepositoryContractTests.swift` | Same |
| `MoolahTests/Domain/InvestmentRepositoryContractTests.swift` | Same |
| `MoolahTests/Domain/InstrumentRegistryRepositoryContractTests.swift` | Same |
| `MoolahTests/Domain/AnalysisRepositoryContractTests.swift` | Same |
| `MoolahTests/Backends/GRDB/AnalysisPlanPinningTests.swift` | NEW — every analysis hot-path query (Swift Testing) |
| `MoolahTests/Backends/GRDB/CoreFinancialGraphPlanPinningTests.swift` | NEW — non-analysis hot-path queries (Swift Testing) |
| `MoolahTests/Backends/GRDB/CoreFinancialGraphRollbackTests.swift` | NEW — multi-statement write rollback per repo (Swift Testing) |
| `MoolahTests/Backends/GRDB/CoreFinancialGraphSyncRoundTripTests.swift` | NEW — per-type sync round-trip (Swift Testing) |
| `MoolahTests/Backends/GRDB/CoreFinancialGraphHookTests.swift` | NEW — hook fan-out regression (account create, category delete) (Swift Testing) |
| `MoolahTests/Backends/GRDB/SwiftDataToGRDBMigratorTests.swift` | EXTEND — add 8 per-type tests + 1 cross-FK test (Swift Testing) |
| `MoolahTests/Backends/GRDB/GRDBAnalysisConversionTests.swift` | NEW — multi-instrument conversion correctness vs SwiftData baseline (Swift Testing) |
| `MoolahTests/Backends/CloudKit/Sync/ClearAllSystemFieldsTests.swift` | NEW — coverage test for every GRDB-backed table |
| `MoolahTests/Backends/CloudKit/Sync/DeleteLocalDataTests.swift` | NEW — coverage test including FK-OFF wipe of category hierarchy |
| `project.yml` | No change expected — `just generate` after adding files. Review for newly-orphaned Swift files |

---

## 5. Acceptance criteria

- `just build-mac` ✅ and `just build-ios` ✅ on the branch.
- `just format-check` clean. (`.swiftlint-baseline.yml` **not** modified.)
- `just test` passes — including the existing repository contract tests against the new GRDB repos.
- New tests added per §3.9 all pass.
- Plan-pinning tests reject `SCAN <table>` and `USE TEMP B-TREE FOR ORDER BY` for every analysis hot-path query.
- Rollback tests pass for every multi-statement write.
- Two-device sync round-trip tests pass for each of the eight types; `encodedSystemFields` preserved bit-for-bit.
- One-shot migrator tests pass; second-run is a no-op for each type.
- Cross-FK migrator test passes — the migration order (parents-before-children) preserves every FK reference.
- After upgrade on a real profile (verified via `run-mac-app-with-logs` skill):
  - SwiftData store still contains the old rows (Slice 3 cleans up).
  - GRDB tables `instrument`, `category`, `account`, `earmark`, `earmark_budget_item`, `investment_value`, `transaction`, `transaction_leg` populated; row counts match.
  - CKSyncEngine produces no `.serverRecordChanged` errors on the next sync session (verified via os_log pattern in `automate-app` skill).
  - All UI surfaces backed by `BackendProvider` work end-to-end: sidebar, transaction list, reports, earmark budget, investments.
- Benchmark deltas meet the targets in §3.9 ("Benchmark deltas") — pre/post numbers in the PR description.
- All five reviewer agents (`database-schema-review`, `database-code-review`, `concurrency-review`, `sync-review`, `code-review`) plus `instrument-conversion-review` report clean, or any findings are addressed before the PR is queued.

---

## 6. Workflow constraints

- **Branch.** `feat/grdb-slice-1-core` off `main` (Slice 0's PR [#567](https://github.com/ajsutton/moolah-native/pull/567) must merge first; otherwise rebase Slice 1 onto Slice 0's branch).
- **Schema generator.** No change to `CloudKit/schema.ckdb` in this slice — wire format is frozen for the eight types. **No `tools/CKDBSchemaGen` work required.** `just generate` for the Xcode project is required for the new files.
- **Reviewers run pre-PR** against the working tree only. Plan-pinning evidence sits inside the test assertions, not the PR description. Benchmark numbers are paraphrased into the PR body.
- **PR convention:** `gh pr create --base main --head feat/grdb-slice-1-core`; queue via `~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add <PR>`.
- **Slice 0 lessons applied from the start** (avoid round-1 / round-2 / round-3 rework):
  - **Records: bare struct + per-protocol extensions; never inline conformance lists.** Slice 0 round-3 fixed this. Apply from the start in all sixteen new record files.
  - **GRDB closure parameter: `database`, never `db`.** Slice 0 convention.
  - **No silent `try?`. `do/catch` + `Logger`.** Round-1 finding; mandatory.
  - **Synced tables: `encoded_system_fields BLOB` + `record_name TEXT NOT NULL UNIQUE`.** Plus CHECK constraints on Bool (`x IN (0, 1)`), enum-shaped TEXT (`x IN ('a', 'b', …)`), bounded INTEGER (`x >= 0`).
  - **Migrator runs from `ProfileSession` (already wired in Slice 0); preserves `encodedSystemFields` byte-for-byte; `upsert` not `insert`; flag-set under `defer` after commit.** Reuse `committed` `defer` flag pattern.
  - **Sync glue propagates errors so CKSyncEngine refetches on GRDB write failure.** Slice 0 round-2 fixed the silent-data-loss path; do **not** swallow into `.success`.
  - **`RecordTypeRegistry.allTypes` updates the value for each migrated type; the cloud-side `recordType` string is frozen — keep it byte-identical to the SwiftData `@Model`'s class name.**
  - **JSON encoders for any blob columns** (denormalised `import_origin_*` are string columns in this slice, not JSON, so no encoder consistency issue applies). When it does apply (future slices), match the existing SwiftData encoder byte-for-byte (defaults — no `outputFormatting`, no `keyEncodingStrategy`, no `dateEncodingStrategy` overrides).
  - **Naming collision: GRDB structs are `*Row`; the existing `@Model` class is `*Record`. Stays in place during this slice for the migrator; deleted in Slice 3 cleanup.**
  - **Repo style: `final class` + `@unchecked Sendable` with explicit member-by-member justification** (everything `let`; `DatabaseWriter` is `Sendable`; closures are `@Sendable`). `actor` would propagate `async` through every CKSyncEngine sync dispatch site and isn't worth it.
  - **Plan-pinning tests for every hot-path SQL query** (mandatory per `DATABASE_CODE_GUIDE.md` §6).
  - **Rollback tests for every multi-statement write** that drives the production method.
  - **Mapping files** at `Backends/GRDB/Records/<Type>+Mapping.swift` per project precedent (Slice 0 ships `CSVImportProfileRow+Mapping.swift` here). The `DATABASE_CODE_GUIDE.md` §3 example showing `Backends/GRDB/Mapping/<Type>+Domain.swift` is **superseded by project precedent** — do not introduce a `Mapping/` subdirectory.
  - **Tests use Swift Testing** (`@Suite`, `@Test`, `#expect`, `#require`), not XCTest. The existing harness on `main` is Swift Testing across the GRDB and CSVImport test files. Translate every external XCTest example before applying.
  - **No `Column("…")` raw-string usage in repository code** — every column reference goes through the row's typed `Columns` enum (`AccountRow.Columns.id`, `TransactionLegRow.Columns.categoryId`, etc.). A future column rename must produce a compile error. Catches the regression class where a string typo silently misses a row.
  - **`databaseSelection` (if ever declared) is `static var`, never `static let`.** `static let databaseSelection: [any SQLSelectable]` is a Swift 6 hard error per `DATABASE_CODE_GUIDE.md` §3 — `[any SQLSelectable]` is non-Sendable.
  - **No raw `IN (:list)` SQL.** SQLite cannot bind a variable-length array to a single named parameter. Use GRDB's `Sequence.contains(Column…)` operator.
  - **`Date()` only at boundaries.** Repos take a `date: Date` parameter rather than reading the system clock internally — see `GRDBAccountRepository.create(_:openingBalance:date:)` (§3.3.3) for the canonical shape.
- **All git/just commands use absolute paths:** `git -C <path>` and `just --justfile <path>/justfile --working-directory <path>`. Never `cd <path> && cmd`.
- **`.agent-tmp/` for any temp files** in the worktree. Delete when done.
- **`.swiftlint-baseline.yml` MUST NOT be modified.** If `just format-check` reports a violation, fix the underlying code: split file/type/function, replace force-unwrap with `#require`, etc. Never re-key, never bump.
- **No cosmetic compensating shrinks.** Don't collapse blank lines or join multi-line calls to fit a baseline count.
- **No abs() on monetary amounts.** Trade legs and refunds preserve sign per CLAUDE.md and feedback.

---

## 7. Reference reading

### Slice plans
- `plans/grdb-migration.md` — overall roadmap and decisions.
- `plans/grdb-step-2-rate-storage.md` — Step 2's detailed plan (format template).
- `plans/grdb-slice-0-csv-import.md` — Slice 0's plan (closer template).

### Guides (non-optional)
- `guides/DATABASE_SCHEMA_GUIDE.md` — schema rules.
- `guides/DATABASE_CODE_GUIDE.md` — Swift / GRDB rules.
- `guides/SYNC_GUIDE.md` — CKSyncEngine architecture.
- `guides/CONCURRENCY_GUIDE.md` — actor isolation rules.
- `guides/INSTRUMENT_CONVERSION_GUIDE.md` — Rules 1–11; especially historic vs current vs future conversion dates (Rules 5–7).
- `guides/BENCHMARKING_GUIDE.md` — pre/post measurement protocol.
- `guides/CODE_GUIDE.md` — naming, type choice, optional discipline, extension organization, thin views.
- `guides/TEST_GUIDE.md` — test structure.

### Slice 0 reference files
- `Backends/GRDB/ProfileSchema.swift` — Slice 0's `v2_csv_import_and_rules` migration; the precedent for `v3_core_financial_graph` registration.
- `Backends/GRDB/Records/CSVImportProfileRow.swift` + `+Mapping.swift` — record-type pattern.
- `Backends/GRDB/Sync/CSVImportProfileRow+CloudKit.swift` — `CloudKitRecordConvertible` pattern.
- `Backends/GRDB/Repositories/GRDBCSVImportProfileRepository.swift` — repo pattern + sync entry points.
- `Backends/GRDB/Migration/SwiftDataToGRDBMigrator.swift` — per-type migrator pattern + `committed` `defer` flag.
- `Backends/CloudKit/Sync/ProfileGRDBRepositories.swift` — bundle struct.
- `Backends/CloudKit/Sync/ProfileDataSyncHandler+GRDBDispatch.swift` — sync dispatch pattern.

### Existing analysis path (read all of these to understand the SQL rewrite)
- `Domain/Repositories/AnalysisRepository.swift` — the protocol.
- `Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift` — orchestration + `loadAll`.
- `Backends/CloudKit/Repositories/CloudKitAnalysisRepository+Conversion.swift` — financial-month bucketing + per-leg conversion helper.
- `Backends/CloudKit/Repositories/CloudKitAnalysisRepository+DailyBalances.swift` — Swift accumulator that becomes the recursive-CTE replacement.
- `Backends/CloudKit/Repositories/CloudKitAnalysisRepository+IncomeExpense.swift` — nested-dict groupBy that becomes SQL `GROUP BY`.
- `Backends/CloudKit/Repositories/CloudKitAnalysisRepository+Forecast.swift` — forecast extrapolation; stays Swift-side.
- `Backends/CloudKit/Repositories/CloudKitAccountRepository+Positions.swift` — sidebar Swift loop.
- `Domain/Models/PositionBook.swift` (or wherever it lives) — preserves the in-memory aggregation primitive used post-SQL.

### Server verification
- `../moolah-server/src/db/analysisDao.js` — the legacy server's SQL for `incomeAndExpense`, `expenseBreakdown`, `dailyProfitAndLoss`. Treat as the lower-bound contract for filter logic — match the WHERE / CASE conditions exactly.

### Existing benchmark scaffolding
- `MoolahBenchmarks/AnalysisBenchmarks.swift` — four cases used for pre/post numbers.
- `MoolahBenchmarks/Support/BenchmarkFixtures.swift` (or wherever the seed lives) — 37k transactions, 62 accounts, 5k investment values at `.twoX` scale.
- `MoolahBenchmarks/TransactionFetchBenchmarks.swift` — relevant to `GRDBTransactionRepository.fetch` perf.
- `MoolahBenchmarks/BalanceDeltaBenchmarks.swift`, `PriorBalanceBenchmarks.swift` — relevant to balance / position computation perf.
- `MoolahBenchmarks/SyncBatchBenchmarks.swift`, `SyncDownloadBenchmarks.swift`, `SyncUploadBenchmarks.swift` — verify no regression on the sync path.

### Slice 0 patterns to copy

| Concern | Slice 0 file:line |
|---|---|
| `committed` defer flag for migrator | `SwiftDataToGRDBMigrator.swift:109–144` |
| `applyRemoteChangesSync` upsert pattern | `GRDBCSVImportProfileRepository.swift:119–132` |
| `setEncodedSystemFieldsSync` UPDATE shape | `GRDBCSVImportProfileRepository.swift:137–144` |
| `unsyncedRowIdsSync` SELECT pattern | `GRDBCSVImportProfileRepository.swift:159–166` |
| GRDB sync dispatch with throw-on-failure | `ProfileDataSyncHandler+GRDBDispatch.swift:16–69` |
| String-keyed system-fields for instruments | `ProfileDataSyncHandler+SystemFields.swift:84–92`; replace with GRDB version |
| `mapBuiltRows` value-type sync helper | `ProfileDataSyncHandler+RecordLookup.swift:133–142` |
| `collectAllGRDBUUIDs` queue helper | `ProfileDataSyncHandler+QueueAndDelete.swift:194–212` |

---

## 8. Open questions

| Q | Resolution before code |
|---|---|
| Can the SwiftData `@Model` classes for the eight types be deleted in Slice 1, or must they wait for Slice 3? | **Wait.** The migrator reads them on first launch after upgrade; deleting them now means no rollback path if the migration fails. Slice 3 deletes them after `ProfileRecord` migration lands. |
| Should `AnalysisRepository`'s sub-files (`+IncomeExpense`, `+DailyBalances`, `+Forecast`, `+Conversion`) split or collapse on the GRDB side? | **Mirror.** The five-file split (main file `GRDBAnalysisRepository.swift` + four extensions: `+Conversion`, `+DailyBalances`, `+Forecast`, `+IncomeExpense`) keeps each method's surface tight. The bodies are different (SQL queries vs Swift loops) but the per-method file ownership pattern is unchanged and reads better. |
| Where do benchmark numbers go — PR description, or committed under `MoolahBenchmarks/baselines/`? | **PR description**, paraphrased. Slice 0's convention. A future PR introduces the baselines/ pattern if numerical regression-on-CI is wanted; Slice 1 doesn't establish it. |
| Do `FullConversionService` / `FiatConversionService` need any change? | **No.** They are constructed once per `ProfileSession` and take a `database: any DatabaseWriter`; they don't care which tables share the connection. The conversion call sites in `GRDBAnalysisRepository` use the same async API as today. Verified by reading both services and their constructors in Step 2's plan. |
| Is the `recordName` format `"<RecordType>|<UUID>"` byte-identical to the existing SwiftData CKRecord IDs? | **Yes**, mediated by `Backends/CloudKit/Sync/CKRecordIDRecordName.swift`. Slice 0 uses the helper. Slice 1 uses the same helper for all eight new row types. Verify during implementation that the format matches `CKRecord.ID(recordType:uuid:zoneID:)` — Slice 0's reference. |
| What if the GRDB-side enum-CHECK constraint rejects a value the SwiftData store contained (e.g. a stale enum case)? | **Migration aborts on the offending row** because `INSERT … VALUES … STRICT` raises `SQLITE_CONSTRAINT_CHECK`. The transaction rolls back, the flag isn't set, and the next launch retries. **Live ingest** (`fieldValues(from:)` for incoming CKRecords) is different — see §3.6.1; remote enum-mismatch is **skip-and-log**, not abort. Migration aborts because local data should never violate the contract; live ingest soft-fails because it's a forward-compat seam. |
| `transaction_leg.account_id` SET NULL means a leg orphaned from its account. Does any caller blow up? | Verified: the Domain model has `accountId: UUID?` and downstream code handles `nil`. The SwiftData status quo also produces orphan legs (no FK enforcement). Same behaviour, now schema-enforced. |
| Should `EarmarkBudgetItem` and `TransactionLeg` get their own `Domain/Repositories/` protocols, or stay scoped to their parents? | **Stay scoped.** `EarmarkBudgetItem` is read/written via `EarmarkRepository.fetchBudget` / `setBudget`. `TransactionLeg` is read/written via `TransactionRepository.fetch` / `create` / `update`. The sync-only GRDB repos (`GRDBEarmarkBudgetItemRepository`, `GRDBTransactionLegRepository`, see §3.3.9 / §3.3.10) exist purely to satisfy the per-record-type sync dispatch tables and don't grow Domain protocols. |
| Plan-pinning tests need `DatabaseQueue` in a state with the migrator applied. Is there a shared seam? | Slice 0 added `try ProfileDatabase.openInMemory()` (which runs the migrator); Slice 1 reuses it. A `MigratedTestQueue.profileDB()` helper as recommended in `DATABASE_CODE_GUIDE.md` §6 sample is the natural extension if the boilerplate hurts; verify during implementation. |
| Does `SwiftDataToGRDBMigrator` need any kind of cancellation hook (e.g. user signs out mid-migration)? | **Yes — light.** Slice 1 makes the migrator `async throws` (§3.7); the calling `Task` can be cancelled, and GRDB 7's `database.write { … }` honours task cancellation by rolling the transaction back. The migrator's per-type flags are not set on cancellation, so the next launch retries from the cancelled type. SwiftData-side `context.fetch` doesn't honour `Task` cancellation natively; if cancellation latency matters in QA, add an explicit `Task.checkCancellation()` before each per-type migrator step. Default: rely on the implicit GRDB-side cancellation. |
| `observeChanges() -> AsyncStream<Void>` continuation safety on `GRDBInstrumentRegistryRepository` (§3.3.1) — how does the hook closure publish into the `MainActor`-isolated stream from a non-main executor? | `AsyncStream.Continuation` is `Sendable` and supports `yield()` from any executor. The hook closure (registered via `onInstrumentRemoteChange`, fired from the CKSyncEngine delegate executor) calls `continuation.yield()` directly. Subscribers iterate the stream from `MainActor` (e.g., picker UIs); the SwiftUI bridge handles the hop. Document this in the repo doc-comment: "continuation is published from any executor; subscribers run on `MainActor`." |
| Per-method conversion-date semantics for SQL-aggregated buckets — what date is passed to the conversion service when a bucket spans multiple days of differently-dated legs? | **Resolved: per-day grouping.** Every historic-conversion method (`fetchExpenseBreakdown`, `fetchIncomeAndExpense`, `fetchCategoryBalances`, plus `fetchDailyBalances` which already groups per-day) projects `DATE(t.date) AS day` in its SELECT and groups by `(day, …, instrument_id)`. Swift converts each `(day, instrument, …)` tuple on `day`, then accumulates up to the user-visible bucket. Rationale: the conversion service caches all rates keyed by ISO-8601 date string (`Shared/ExchangeRateService.swift:36–39` formats with `[.withFullDate]`), so two transactions on the same calendar day get the same rate — per-day grouping produces an identical numerical result to today's per-leg conversion at `transaction.date`. Coarser grouping (per-month) would change rates and break Rule 5; finer grouping (per-leg) just multiplies conversion calls without changing the answer. See §3.4 intro for the full argument and §3.4.2/3/4 for the per-method shape. |

---

*End of plan. Implementer: re-read §3.4 and §3.6 before writing the first GRDB query — those are the two areas Slice 1's success rests on.*
