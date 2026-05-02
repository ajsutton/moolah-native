# Slice 0 — CSVImportProfile + ImportRule to GRDB (detailed plan)

**Status:** Not started.
**Roadmap context:** `plans/grdb-migration.md` §6 → Slice 0.
**Branch:** `feat/grdb-slice-0-csv-import` (not yet created).
**Parent branch:** `main` (Step 2's `refactor/rate-storage-grdb` is the prerequisite — must merge first).

---

## 1. Goal

Migrate two synced record types — `CSVImportProfile` and `ImportRule` — from SwiftData (`@Model` classes under `Backends/CloudKit/Models/`) to GRDB (`Sendable` structs under `Backends/GRDB/Records/`), while preserving CKSyncEngine round-trip exactly. This is the **first slice that exercises CKSyncEngine ↔ GRDB**, on two isolated leaf records that have no FK dependencies on other domain types and a small contract surface (4 + 5 methods).

The slice proves out, in a low-blast-radius package:

- The GRDB schema pattern for synced tables (`encoded_system_fields BLOB` + `record_name TEXT UNIQUE`).
- `CloudKitRecordConvertible` conformance on a GRDB struct (vs the existing pattern on a `@Model` class).
- Extension of `ProfileDataSyncHandler`'s `batchUpserters` / `uuidDeleters` dispatch tables to route specific record types to GRDB.
- The one-shot SwiftData → GRDB migrator that copies rows + `encodedSystemFields` bit-for-bit, gated by a `UserDefaults` flag.
- Repository hook fan-out (`onRecordChanged` / `onRecordDeleted`) from a GRDB repository back into `SyncCoordinator`.

Slice 1 (the big core-graph cut) reuses every pattern this slice establishes, so getting them right here is the point.

---

## 2. What's already in place from Step 2 (don't change)

Per-profile GRDB infrastructure shipped on `main`:

| File | Provides |
|---|---|
| `Backends/GRDB/ProfileDatabase.swift` | `DatabaseQueue` factory: `open(at:)` + `openInMemory()`. WAL on disk, PRAGMAs, journal-mode read-back assertion. |
| `Backends/GRDB/ProfileSchema.swift` | `DatabaseMigrator` with `v1_initial` (rate-cache tables only). New tables go under a fresh `v2_*` migration. |
| `App/ProfileSession.swift` | Owns `private let database: DatabaseQueue`. Already throws on open. `cleanupSync(coordinator:)` cancels all per-session tasks. |

The slice extends `ProfileSchema` with new migrations and threads the existing `database` through to the new GRDB repositories. **Do not** create a second SQLite file — one DB per profile.

---

## 3. What's left

### 3.1 GRDB schema additions

Extend `Backends/GRDB/ProfileSchema.swift` with one new migration `v2_csv_import_and_rules` that creates two tables. Both **must** carry `encoded_system_fields BLOB` and `record_name TEXT NOT NULL UNIQUE` per `plans/grdb-migration.md` §4.

```sql
CREATE TABLE csv_import_profile (
    id                              BLOB    NOT NULL PRIMARY KEY,
    record_name                     TEXT    NOT NULL UNIQUE,
    account_id                      BLOB    NOT NULL,
    parser_identifier               TEXT    NOT NULL,
    header_signature                TEXT    NOT NULL,        -- unit-separator-joined
    filename_pattern                TEXT,
    delete_after_import             INTEGER NOT NULL,        -- 0 / 1
    created_at                      TEXT    NOT NULL,        -- ISO-8601
    last_used_at                    TEXT,
    date_format_raw_value           TEXT,
    column_role_raw_values_encoded  TEXT,                    -- unit-separator-joined; NULL when empty
    encoded_system_fields           BLOB
) STRICT;

CREATE INDEX csv_import_profile_account ON csv_import_profile(account_id);
CREATE INDEX csv_import_profile_created ON csv_import_profile(created_at);

CREATE TABLE import_rule (
    id                     BLOB    NOT NULL PRIMARY KEY,
    record_name            TEXT    NOT NULL UNIQUE,
    name                   TEXT    NOT NULL,
    enabled                INTEGER NOT NULL,                 -- 0 / 1
    position               INTEGER NOT NULL,
    match_mode             TEXT    NOT NULL,                 -- raw value of MatchMode
    conditions_json        BLOB    NOT NULL,                 -- JSON-encoded [RuleCondition]
    actions_json           BLOB    NOT NULL,                 -- JSON-encoded [RuleAction]
    account_scope          BLOB,                             -- nil = global rule
    encoded_system_fields  BLOB
) STRICT;

CREATE INDEX import_rule_position ON import_rule(position);
CREATE INDEX import_rule_account_scope ON import_rule(account_scope) WHERE account_scope IS NOT NULL;
```

Schema notes:
- **`STRICT`** mandatory per `DATABASE_SCHEMA_GUIDE.md` §3.
- **`WITHOUT ROWID`** is **not** justified here (single-column UUID PK; rows are wide). Per §3 the rule is "WITHOUT ROWID is per-table, not blanket" — keep ROWID.
- **UUIDs as 16-byte BLOB** (GRDB default). The `record_name` column is the canonical CloudKit record-name string (verify the format by reading `CSVImportProfileRecord+CloudKit.swift` — it's whatever `CKRecord.ID.recordName` resolves to today; mirror it bit-for-bit so the migrator can preserve sync identity).
- **`WHERE account_scope IS NOT NULL`** partial index — global rules have NULL scope and don't need indexing on it.
- **`conditions_json` / `actions_json`** mirror the existing SwiftData blob shape exactly. `JSONEncoder` / `JSONDecoder` settings stay the same as the `@Model` layer (`.iso8601` dates if relevant — read the existing code to confirm; the current implementation uses defaults).
- **Retention:** these tables hold user data, not cache. **Do not** add a "kept forever" comment — that's only for cache tables (§9).

### 3.2 GRDB record types

Two new files:

- `Backends/GRDB/Records/CSVImportProfileRecord.swift`
- `Backends/GRDB/Records/ImportRuleRecord.swift`

⚠ **Naming collision.** The SwiftData `@Model` class is also called `CSVImportProfileRecord` (and `ImportRuleRecord`). We cannot have two types with the same fully-qualified name in the same module. **Decision:** rename the GRDB structs to `CSVImportProfileRow` and `ImportRuleRow` (consistent with the GRDB convention of "row" structs, distinct from the SwiftData "record" classes). When the SwiftData `@Model` class is removed in a follow-up, we can re-rename if desired. Until then, `*Row` is the GRDB type and `*Record` is the SwiftData type — **the diff must not be ambiguous**.

Each follows the pattern from Step 2's rate-cache records:

```swift
struct CSVImportProfileRow {
    var id: UUID
    var recordName: String
    var accountId: UUID
    var parserIdentifier: String
    var headerSignature: String              // unit-separator-joined
    var filenamePattern: String?
    var deleteAfterImport: Bool
    var createdAt: Date
    var lastUsedAt: Date?
    var dateFormatRawValue: String?
    var columnRoleRawValuesEncoded: String?
    var encodedSystemFields: Data?

    static let databaseTableName = "csv_import_profile"

    enum Columns: String, ColumnExpression, CaseIterable {
        case id, recordName = "record_name", accountId = "account_id"
        case parserIdentifier = "parser_identifier"
        case headerSignature = "header_signature"
        case filenamePattern = "filename_pattern"
        case deleteAfterImport = "delete_after_import"
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
        case dateFormatRawValue = "date_format_raw_value"
        case columnRoleRawValuesEncoded = "column_role_raw_values_encoded"
        case encodedSystemFields = "encoded_system_fields"
    }

    enum CodingKeys: String, CodingKey {
        case id, recordName = "record_name", accountId = "account_id"
        // … (mirror of Columns)
    }
}

extension CSVImportProfileRow: Codable {}
extension CSVImportProfileRow: Sendable {}
extension CSVImportProfileRow: FetchableRecord {}
extension CSVImportProfileRow: PersistableRecord {}
```

(One-extension-per-protocol per `CODE_GUIDE.md` §11; no inline multi-conformance lists. This is what round-3 of Step 2 fixed for the rate-cache records — apply it from the start here.)

Mapping helpers (separate file `Backends/GRDB/Records/CSVImportProfileRow+Mapping.swift`):

- `init(domain: CSVImportProfile)` — builds the row from a domain object.
- `func toDomain() -> CSVImportProfile` — splits unit-separator-joined fields back into arrays.
- `recordName(from id: UUID) -> String` — central place for the `<recordType>:<uuid>` formatter (or whatever the existing CKRecord.ID format resolves to). Used for migration + initial creates.

Same shape for `ImportRuleRow`. Conditions/actions JSON mapping uses `JSONEncoder` / `JSONDecoder` that **match the existing `ImportRuleRecord+CloudKit.swift` format byte-for-byte** so the migrator's bit-for-bit copy semantics aren't compromised. If the existing code uses the default `JSONEncoder().encode(...)`, the new path uses the same — explicitly do not set `outputFormatting = .sortedKeys` and do not change date/key encoding strategies, or migrated rows will produce different blobs and trip CKSyncEngine `.serverRecordChanged`.

### 3.3 GRDB repository implementations

Two new files:

- `Backends/GRDB/Repositories/GRDBCSVImportProfileRepository.swift`
- `Backends/GRDB/Repositories/GRDBImportRuleRepository.swift`

Each conforms to the existing protocol in `Domain/Repositories/`. Each takes a `database: any DatabaseWriter` plus the `onRecordChanged` / `onRecordDeleted` hook closures (matching the existing CloudKit repos' interface). Actor isolation: **same as the current CloudKit implementations** (`final class … : @unchecked Sendable` with `@MainActor` accessor pattern, OR convert to `actor` — see the open question in §3.7 below; pick one for the slice). All public methods are `async throws`.

`GRDBCSVImportProfileRepository`:

```swift
func fetchAll() async throws -> [CSVImportProfile] {
    try await database.read { db in
        try CSVImportProfileRow
            .order(Column("created_at").asc)
            .fetchAll(db)
    }
    .map { $0.toDomain() }
}
```

`create` / `update` / `delete` follow the obvious shape:
- One `database.write { db in … }` per call.
- After commit, fire `onRecordChanged(recordType:, id:)` (or `onRecordDeleted`) so the existing `SyncCoordinator` queue path runs unchanged.

`GRDBImportRuleRepository.reorder(_:)` is the only non-trivial method. It must:
1. Open one `database.write` transaction.
2. Fetch all `ImportRuleRow.id`s into a `Set`; compare to `Set(orderedIds)`. Throw `BackendError.serverError(409)` on mismatch (no insert, no rollback needed because nothing changed yet).
3. Update `position` for every row (or only changed rows — match the existing CloudKit repo's "selective" semantics; only fire `onRecordChanged` for rows whose position actually changed).
4. Inside the same transaction, batch the position updates with `UPDATE import_rule SET position = ? WHERE id = ?` per id, OR use `Row.update(...)`/`record.update(db, columns: [.position])` for type-safety.
5. After commit, fire `onRecordChanged(recordType: "ImportRuleRecord", id:)` for each changed row.

⚠ **Queue ordering subtlety.** If `reorder` swaps positions atomically (e.g. row A goes from 1→2, row B from 2→1), CloudKit must see both updates. The existing CloudKit implementation iterates `id`s and queues each individually; mirror that. Don't get clever — sync correctness > minor IPC count.

### 3.4 BackendProvider swap

`BackendProvider` already exposes `var csvImportProfiles: any CSVImportProfileRepository` and `var importRules: any ImportRuleRepository`. Find the concrete implementations (`Backends/CloudKit/CloudKitBackend.swift`, `Backends/Remote/RemoteBackend.swift`, `Shared/PreviewBackend.swift`, `MoolahTests/Support/TestBackend.swift`) and swap their construction:

```swift
// CloudKitBackend.init
self.csvImportProfiles = GRDBCSVImportProfileRepository(database: database, …)
self.importRules = GRDBImportRuleRepository(database: database, …)
```

Pass through the `database: DatabaseQueue` already opened by `ProfileSession`. The `@MainActor` `_ = modelContainer` reference can stay for the slice — Slice 1 strips SwiftData entirely. **Do not** delete `Backends/CloudKit/Models/CSVImportProfileRecord.swift` or `Backends/CloudKit/Models/ImportRuleRecord.swift` in this slice; the migrator needs them to read existing rows. Removal happens in Slice 1's cleanup.

The `Remote*Repository` types (in `Backends/Remote/`) — verify they exist for these record types. If they don't (these may be CloudKit-only), no change needed in `RemoteBackend.swift`.

### 3.5 CKSyncEngine glue

This is the slice's single highest-risk area. The existing `Backends/CloudKit/Sync/` layer is **storage-agnostic by design** — it operates on `CloudKitRecordConvertible` types. The slice extends it minimally.

#### 3.5.1 `CloudKitRecordConvertible` on the GRDB rows

Two new files (matching the SwiftData precedent in `Backends/CloudKit/Sync/CSVImportProfileRecord+CloudKit.swift`):

- `Backends/GRDB/Sync/CSVImportProfileRow+CloudKit.swift`
- `Backends/GRDB/Sync/ImportRuleRow+CloudKit.swift`

Each:
- Declares `static var recordType: String { "CSVImportProfileRecord" }` (keep the wire record type **unchanged** — CloudKit doesn't know our types renamed; the recordType string in the cloud is a frozen contract).
- Implements `func toCKRecord(in zoneID:)` using the auto-generated `CSVImportProfileRecordCloudKitFields` struct (which Step 2 didn't change — it's emitted by `tools/CKDBSchemaGen` from `CloudKit/schema.ckdb`).
- Implements `static func fieldValues(from ckRecord:) -> Self?` — extracts the wire fields into a fresh `Row` struct.
- Conforms to `SystemFieldsCacheable` (read/write `encodedSystemFields: Data?`).

`RecordTypeRegistry.allTypes` (in `Backends/CloudKit/Sync/CloudKitRecordConvertible.swift`) currently maps to the SwiftData `@Model` classes. **Conditional:** during the slice, map to the GRDB rows. The map is a `[String: any CloudKitRecordConvertible.Type]`, so swap the value for the two record-type keys.

#### 3.5.2 `ProfileDataSyncHandler` dispatch tables

Three closure-table call sites need new entries that route to GRDB:

- `ProfileDataSyncHandler+ApplyRemoteChanges.swift` — `batchUpserters` / `uuidDeleters` lookup tables. Add entries that call `GRDBCSVImportProfileRepository.applyRemoteChanges(saved:deleted:)` and the equivalent for rules. The repo exposes a method (new — `func applyRemoteChanges(saved: [CSVImportProfileRow], deleted: [UUID]) async throws`) that performs the upsert/delete inside one `database.write`. **The repo is the source of truth; the sync handler is a switchboard.**
- `ProfileDataSyncHandler+QueueAndDelete.queueAllExistingRecords()` — currently scans SwiftData. For these two types it must scan GRDB (`SELECT id FROM csv_import_profile`, etc.) and emit `CKRecord.ID`s.
- `ProfileDataSyncHandler+QueueAndDelete.queueUnsyncedRecords()` — same scan plus `WHERE encoded_system_fields IS NULL`.

#### 3.5.3 `applyBatchSaves` row-merge logic

The current SwiftData implementation does field-by-field merge (fetch existing by id, mutate fields, save). For GRDB:

```swift
func applyRemoteChanges(saved rows: [CSVImportProfileRow], deleted ids: [UUID]) async throws {
    try await database.write { db in
        for row in rows {
            try row.upsert(db)             // ON CONFLICT (id) DO UPDATE — see GRDB
        }
        for id in ids {
            _ = try CSVImportProfileRow.deleteOne(db, id: id)
        }
    }
}
```

GRDB's `.upsert(db)` on a `PersistableRecord` does an `INSERT ... ON CONFLICT(id) DO UPDATE SET ...` against the row's `databaseTableName`. **Verify** by reading GRDB's docs that `upsert` works on a record with a composite-unique `record_name` — if the conflict target is ambiguous, fall back to explicit `INSERT INTO csv_import_profile(...) VALUES (...) ON CONFLICT(id) DO UPDATE SET ...` SQL with bound parameters (no Swift String injection — only column-list / values are bound).

#### 3.5.4 Hook from repository back to `SyncCoordinator`

Identical pattern to today. The repository keeps the closure-property shape:

```swift
var onRecordChanged: (String, UUID) -> Void = { _, _ in }
var onRecordDeleted: (String, UUID) -> Void = { _, _ in }
```

Set by whoever wires the backend (current site: `CloudKitBackend.init`). After every successful local mutation, call `onRecordChanged(Self.cloudKitRecordType, row.id)`. The closure signature **does not change**, so the `SyncCoordinator`-side wiring needs no edits.

### 3.6 SwiftData → GRDB migrator

New file: `Backends/GRDB/Migration/SwiftDataToGRDBMigrator.swift`.

Single entry point invoked at app launch, after `ProfileSession.init` has opened the GRDB queue:

```swift
@MainActor
final class SwiftDataToGRDBMigrator {
    static let csvImportProfilesFlag = "v2.csvImportProfiles.grdbMigrated"
    static let importRulesFlag       = "v2.importRules.grdbMigrated"

    func migrateIfNeeded(modelContainer: ModelContainer,
                        database: DatabaseQueue,
                        defaults: UserDefaults = .standard) async throws { … }
}
```

Behaviour per record type:

1. Check `defaults.bool(forKey: ...Flag)` — early return if already migrated.
2. Fetch all rows from SwiftData (`FetchDescriptor<CSVImportProfileRecord>` etc.) via `modelContainer.mainContext`.
3. Map each `@Model` instance to a GRDB row, **preserving `encodedSystemFields` byte-for-byte**. Verify with `Data.elementsEqual(_:)` against the source if you're paranoid; the test suite enforces it.
4. Write all rows in **one** `database.write` transaction. Use `row.insert(db)` (not `upsert`) — the migrator should never run twice; if it sees an existing row with the same id, that's a bug.
5. On commit, set `defaults.set(true, forKey: ...Flag)`.
6. **Do not delete the SwiftData rows.** Slice 1 will tear out the `@Model` classes; until then, the SwiftData store stays as a fallback / forensic record.

⚠ **Idempotency / re-runs.** If the migrator crashes mid-write, GRDB's transaction rolls back — no partial state. The flag isn't set. Next launch re-runs from scratch. Match this behaviour: **don't** set the flag in any path other than after the transaction commits.

⚠ **Migration ordering vs CKSyncEngine.** The migrator must run *before* CKSyncEngine reads from GRDB on first launch. Hook point: `MoolahApp+Setup.swift` post-`ProfileSession` open, pre-`SyncCoordinator.start()`. Verify the existing call order; if `SyncCoordinator.start()` runs synchronously in init it may need a small refactor.

⚠ **What if GRDB has a row from CKSyncEngine that hasn't merged into SwiftData yet?** Theoretically impossible on first migration (GRDB is empty). On re-run after the flag is unset (e.g. dev wipes UserDefaults): treat it as a programmer error; the migrator's `insert(db)` will trip the PK uniqueness constraint and surface a clear failure.

### 3.7 Tests

Mandatory:

- **Contract tests for both repositories.** `MoolahTests/Domain/CSVImportProfileRepositoryContractTests.swift` and `ImportRuleRepositoryContractTests.swift` already exist and run against `TestBackend`. They must pass unchanged once `TestBackend` is rewired to construct GRDB repositories. If not, the repo behaviour diverges from the protocol contract — that's the bug.
- **Sync round-trip test.** Add `MoolahTests/Backends/GRDB/SyncRoundTripCSVImportTests.swift`. The test:
  1. Builds two `TestBackend` instances (representing two devices).
  2. Creates a profile / rule on device A.
  3. Manually drives `CKSyncEngine` apply-remote-changes on device B with the recorded outbound batch.
  4. Asserts the GRDB row on device B matches the source bit-for-bit, including `encodedSystemFields`.
  Pattern reference: search for existing CKSyncEngine round-trip tests on the SwiftData-backed types in `MoolahTests/Backends/CloudKit/Sync/` — there's likely one for accounts or transactions.
- **Migrator tests.** `MoolahTests/Backends/GRDB/SwiftDataToGRDBMigratorTests.swift`. For each record type:
  1. Seed a SwiftData container with N rows + non-nil `encodedSystemFields`.
  2. Open an in-memory GRDB queue.
  3. Run `migrateIfNeeded`.
  4. Assert all rows present in GRDB, `encodedSystemFields` byte-equal to source, flag set in `UserDefaults`.
  5. Re-run; assert no-op (no errors, count unchanged).
- **Plan-pinning tests** for the hot lookup queries. Mandatory per `DATABASE_CODE_GUIDE.md` §6. The two non-trivial queries are `ImportRuleRow.order(Column("position"))` (must hit `import_rule_position`) and `CSVImportProfileRow.filter(Column("account_id") == ?)` (must hit `csv_import_profile_account` if any caller filters by account — verify; if no caller, skip the partial test).

Open question: **actor or `@unchecked Sendable` class?**
- The current `CloudKitCSVImportProfileRepository` is `@unchecked Sendable` because of the `ModelContainer` / `ModelContext` `@MainActor` quirks.
- A GRDB-backed repo could be a clean `actor`: all writes run inside `database.write { … }` which itself serialises; the repo is storing nothing mutable.
- **Recommendation:** `actor`. The hook closures (`onRecordChanged`, etc.) can be set during `init` (as `let` properties) rather than `var` properties mutated by the backend. Document that hook reassignment after `init` isn't supported (or use an `actor`-isolated setter — see what reads cleanest).
- If `actor` introduces an `await` cascade that `@unchecked Sendable` avoided, fall back to the existing pattern. Decide during implementation; document the choice.

---

## 4. File-level inventory of edits

| File | Action |
|---|---|
| `Backends/GRDB/ProfileSchema.swift` | Add `v2_csv_import_and_rules` migration |
| `Backends/GRDB/Records/CSVImportProfileRow.swift` | NEW — bare struct + per-protocol extensions |
| `Backends/GRDB/Records/CSVImportProfileRow+Mapping.swift` | NEW — domain ↔ row mapping |
| `Backends/GRDB/Records/ImportRuleRow.swift` | NEW |
| `Backends/GRDB/Records/ImportRuleRow+Mapping.swift` | NEW |
| `Backends/GRDB/Sync/CSVImportProfileRow+CloudKit.swift` | NEW — `CloudKitRecordConvertible` + `SystemFieldsCacheable` |
| `Backends/GRDB/Sync/ImportRuleRow+CloudKit.swift` | NEW |
| `Backends/GRDB/Repositories/GRDBCSVImportProfileRepository.swift` | NEW |
| `Backends/GRDB/Repositories/GRDBImportRuleRepository.swift` | NEW |
| `Backends/GRDB/Migration/SwiftDataToGRDBMigrator.swift` | NEW — one-shot migrator |
| `Backends/CloudKit/Sync/CloudKitRecordConvertible.swift` | Update `RecordTypeRegistry.allTypes` to point at `*Row` types |
| `Backends/CloudKit/Sync/ProfileDataSyncHandler+ApplyRemoteChanges.swift` | Route the two record types through GRDB repo `applyRemoteChanges` instead of SwiftData batch upserts |
| `Backends/CloudKit/Sync/ProfileDataSyncHandler+QueueAndDelete.swift` | Scan GRDB for the two record types in `queueAllExistingRecords()` and `queueUnsyncedRecords()` |
| `Backends/CloudKit/Sync/CSVImportProfileRecord+CloudKit.swift` | DELETE — superseded by GRDB sibling |
| `Backends/CloudKit/Sync/ImportRuleRecord+CloudKit.swift` | DELETE — superseded |
| `Backends/CloudKit/CloudKitBackend.swift` | Construct `GRDB*Repository` instead of `CloudKit*Repository`; pass `database` |
| `Backends/Remote/RemoteBackend.swift` | If a non-CloudKit implementation exists for these types, construct GRDB repo here too |
| `Shared/PreviewBackend.swift` | Construct GRDB repo with the existing in-memory `database` |
| `MoolahTests/Support/TestBackend.swift` | Same |
| `App/MoolahApp+Setup.swift` | Invoke `SwiftDataToGRDBMigrator.migrateIfNeeded(...)` post-session-open, pre-sync-start |
| `MoolahTests/Domain/CSVImportProfileRepositoryContractTests.swift` | Should pass unchanged; if not, fix the repo to honour the protocol |
| `MoolahTests/Domain/ImportRuleRepositoryContractTests.swift` | Same |
| `MoolahTests/Backends/GRDB/SyncRoundTripCSVImportTests.swift` | NEW |
| `MoolahTests/Backends/GRDB/SwiftDataToGRDBMigratorTests.swift` | NEW |
| `MoolahTests/Backends/GRDB/CSVImportPlanPinningTests.swift` | NEW (only if there's a queryable hot path; otherwise skip) |
| `Backends/CloudKit/Models/CSVImportProfileRecord.swift` | UNCHANGED — kept for migrator until Slice 1 |
| `Backends/CloudKit/Models/ImportRuleRecord.swift` | UNCHANGED — same |
| `Backends/CloudKit/Repositories/CloudKitCSVImportProfileRepository.swift` | UNCHANGED — kept around but unwired; deleted in Slice 1 cleanup |
| `Backends/CloudKit/Repositories/CloudKitImportRuleRepository.swift` | UNCHANGED — same |

---

## 5. Acceptance criteria

- `just build-mac` ✅ and `just build-ios` ✅ on the branch.
- `just format-check` clean.
- `just test` passes — including the existing contract tests against the new GRDB repos.
- New tests added per §3.7 all pass.
- Two-device sync round-trip test (§3.7) passes; `encodedSystemFields` preserved bit-for-bit.
- One-shot migrator test (§3.7) passes; second-run is a no-op.
- After upgrade on a real profile:
  - SwiftData store still contains the old rows (slice 1 cleans up).
  - GRDB `csv_import_profile` and `import_rule` tables populated; row counts match.
  - CKSyncEngine produces no `.serverRecordChanged` errors on the next sync.
- All four reviewer agents (`database-schema-review`, `database-code-review`, `concurrency-review`, `code-review`) plus `sync-review` report clean, or any findings are addressed before the PR is queued.

---

## 6. Workflow constraints

- **Branch.** `feat/grdb-slice-0-csv-import` off `main` (Step 2's PR #561 must merge first; otherwise the slice rebases onto Step 2's branch, not main).
- **Schema generator.** New record types in the wire format don't change — `CloudKit/schema.ckdb` is unchanged. No `just generate` for schema bits is required. (`just generate` for xcodegen is required for the new files, as always.)
- **Reviewers run pre-PR** against the working tree only. No PR-description evidence; no plan-pinning evidence beyond the in-test assertions.
- **PR convention:** `gh pr create --base main --head feat/grdb-slice-0-csv-import`; queue via `~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add <PR>`.
- **Step 2 lessons applied from the start** (avoid round-1 rework):
  - Records use bare struct + per-protocol extensions (no inline conformance lists).
  - `// MARK: - Cross-extension internals` block in the primary file if a sibling extension needs same-module access.
  - All `try?` replaced with `do/catch` + `Logger`.
  - `database` closure parameter, never `db`.
  - Cache vs user-data: these tables are user data; do **not** add a "kept forever" comment.
  - `journal_mode = WAL` is already set in `ProfileDatabase.open(at:)`; no additional PRAGMA work for the slice.

---

## 7. Reference reading

- `plans/grdb-migration.md` — overall roadmap.
- `plans/grdb-step-2-rate-storage.md` — Step 2's detailed plan (mirror its structure for completeness; reuse format conventions).
- `guides/DATABASE_SCHEMA_GUIDE.md` — schema rules.
- `guides/DATABASE_CODE_GUIDE.md` — Swift / GRDB rules.
- `guides/SYNC_GUIDE.md` — CKSyncEngine architecture.
- `guides/CONCURRENCY_GUIDE.md` — actor isolation rules.
- `Backends/GRDB/ProfileSchema.swift` — Step 2's `v1_initial` migration as the precedent for new migration registration.
- `Backends/GRDB/Records/ExchangeRateRecord.swift` and `+Mapping`-style siblings — Step 2's record-type pattern.
- `Backends/CloudKit/Sync/CSVImportProfileRecord+CloudKit.swift`, `Backends/CloudKit/Sync/ImportRuleRecord+CloudKit.swift` — the existing `CloudKitRecordConvertible` conformances; mirror byte-for-byte.
- `Backends/CloudKit/Sync/ProfileDataSyncHandler+ApplyRemoteChanges.swift` and `+QueueAndDelete.swift` — sync dispatch tables to extend.
- `Backends/CloudKit/Models/{CSVImportProfileRecord,ImportRuleRecord}.swift` — the SwiftData `@Model` shape the migrator reads.

---

## 8. Open questions

| Q | Resolution before code |
|---|---|
| Repo: `actor` vs `@unchecked Sendable` class? | Recommend `actor`; verify during implementation that hook-closure assignment doesn't require post-init mutation (see §3.7). |
| GRDB `.upsert(db)` with composite UNIQUE? | Verify against GRDB docs; fall back to explicit ON CONFLICT SQL if ambiguous (§3.5.3). |
| `record_name` format — exactly what string? | Read `CSVImportProfileRecord+CloudKit.swift` to confirm the canonical `CKRecord.ID.recordName` literal; mirror in `Row.recordName(from:)`. Adjust the schema column type / index if the format changes. |
| Migrator hook point in `MoolahApp+Setup.swift` — pre or post `SyncCoordinator.start()`? | **Pre.** Confirm by tracing the call order; refactor the start point if needed. |
| `RemoteBackend` has dummy / no-op repos for these record types? | Confirm during implementation; if so, add GRDB repos there too. |
