# Per-Account Valuation Mode — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the implicit "snapshots present? render legacy view + use snapshot as balance, otherwise render trades view + sum positions" auto-detect with an explicit, per-account, reversible `valuationMode` toggle that drives every balance read site and the account-detail view layout.

**Architecture:** Add a new `ValuationMode` enum (`recordedValue` | `calculatedFromTrades`) as a field on `Account`. Round-trip the field through:
- the GRDB cache (`AccountRow` + `AccountRow+Mapping.swift` for domain conversion + `AccountRow+CloudKit.swift` for the wire layer + a v6 schema migration), and
- the legacy SwiftData mirror (`AccountRecord`), still needed by `CloudKitDataImporter.swift` and `SwiftDataToGRDBMigrator+CoreFinancialGraph.swift`.

A one-shot per-profile migration on first launch derives each existing investment account's initial mode from snapshot presence. Five read sites (`AccountBalanceCalculator.displayBalance`, `AccountBalanceCalculator.totalConverted`, `InvestmentAccountView`, `InvestmentStore.loadAllData` / `reloadPositionsIfNeeded`, `GRDBAnalysisRepository.fetchInvestmentAccountIds`) replace data-presence checks with explicit mode reads. Settings UI adds a Picker in `EditAccountView`.

**Tech Stack:** Swift 6 with strict concurrency, SwiftUI, SwiftData (legacy AccountRecord mirror), GRDB (per-profile cache), CloudKit (CKSyncEngine), Swift Testing (`@Suite` / `@Test`), XCUITest for UI tests.

**References:**
- Spec — `plans/2026-05-04-per-account-valuation-mode-design.md`
- Project policy — `CLAUDE.md`, `guides/CODE_GUIDE.md`, `guides/TEST_GUIDE.md`, `guides/CONCURRENCY_GUIDE.md`, `guides/DATABASE_SCHEMA_GUIDE.md`, `guides/SYNC_GUIDE.md`, `guides/UI_GUIDE.md`
- Test infrastructure — `MoolahTests/Support/TestBackend.swift` (`TestBackend.create()` returns `(backend: CloudKitBackend, database: DatabaseQueue)`; seed data via `TestBackend.seed(...)` helpers)

**Rollout:** Six PRs in sequence. Each PR runs the relevant review agent(s) before opening and goes through the `merge-queue` skill. Each phase below = one PR. Tasks within a phase are TDD: failing test → implementation → passing test → commit. Each phase's last commit precedes a `just test` full-suite run + `just format-check` + a Xcode-warnings sweep before the PR opens.

**Worktree convention (per project CLAUDE.md):**
```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add --no-track \
    .worktrees/<phase-branch> -b <phase-branch> origin/main
```
Pushes use the explicit `<src>:<dst>` form to avoid accidental upstream re-tracking onto the parent branch. **All `git`, `just`, and shell commands inside a worktree should use `git -C <full-path>` and `just -d <full-path>`** (per the user-feedback memory `feedback_no_cd_for_any_tool.md`).

For brevity below, `<W>` denotes the worktree's absolute path, e.g. `/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/valuation-mode-1-schema`.

---

## Phase 1 — Schema, domain model, mappings (PR 1)

**Branch:** `valuation-mode/1-schema`
**Worktree:** `.worktrees/valuation-mode-1-schema`
**Reviewers:** `code-review`, `database-schema-review`, `database-code-review`, `sync-review` (justified: this PR introduces a new CloudKit field and changes the `CloudKitRecordConvertible` mapping)

Adds the `ValuationMode` enum, `Account.valuationMode` field, the v6 GRDB migration, the GRDB↔CloudKit field-mapping update, and the SwiftData mirror's stored property. **No call site reads the field yet.** Behaviour is unchanged because today's auto-detect still drives every read site.

### Task 1.1 — Add `ValuationMode` enum

**Files:**
- Create: `Domain/Models/ValuationMode.swift`
- Test: `MoolahTests/Domain/ValuationModeTests.swift`

- [ ] **Step 1 — Write the failing test**

```swift
// MoolahTests/Domain/ValuationModeTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("ValuationMode")
struct ValuationModeTests {
  @Test("raw values are stable wire identifiers")
  func rawValues() {
    #expect(ValuationMode.recordedValue.rawValue == "recordedValue")
    #expect(ValuationMode.calculatedFromTrades.rawValue == "calculatedFromTrades")
  }

  @Test("decodes from raw value")
  func decode() {
    #expect(ValuationMode(rawValue: "recordedValue") == .recordedValue)
    #expect(ValuationMode(rawValue: "calculatedFromTrades") == .calculatedFromTrades)
    #expect(ValuationMode(rawValue: "unknown") == nil)
  }

  @Test("CaseIterable lists both cases")
  func caseIterable() {
    #expect(Set(ValuationMode.allCases) == [.recordedValue, .calculatedFromTrades])
  }
}
```

- [ ] **Step 2 — Run test to verify it fails**

```bash
mkdir -p <W>/.agent-tmp
just -d <W> test ValuationModeTests 2>&1 | tee <W>/.agent-tmp/test-1.1-fail.txt
```

Expected: compile error "cannot find 'ValuationMode' in scope".

- [ ] **Step 3 — Implement the enum**

```swift
// Domain/Models/ValuationMode.swift
import Foundation

/// Selects how an investment account's "current value" is computed for
/// balance display, totals, and reports.
///
/// - `recordedValue`: the latest user-entered `InvestmentValue` snapshot
///   drives the displayed value. Snapshots are edited via the legacy
///   investment-account view.
/// - `calculatedFromTrades`: the value is computed by summing positions
///   (derived from trade transactions) at current instrument prices.
///
/// The mode is a per-`Account` setting; switching is reversible.
/// See `plans/2026-05-04-per-account-valuation-mode-design.md`.
enum ValuationMode: String, Codable, Sendable, CaseIterable {
  case recordedValue
  case calculatedFromTrades
}
```

- [ ] **Step 4 — Run test to verify it passes**

```bash
just -d <W> test ValuationModeTests 2>&1 | tee <W>/.agent-tmp/test-1.1-pass.txt
grep -i 'failed\|error:' <W>/.agent-tmp/test-1.1-pass.txt && exit 1 || echo OK
rm <W>/.agent-tmp/test-1.1-*.txt
```

- [ ] **Step 5 — Commit**

```bash
git -C <W> add Domain/Models/ValuationMode.swift \
              MoolahTests/Domain/ValuationModeTests.swift
git -C <W> commit -m "$(cat <<'EOF'
feat(domain): add ValuationMode enum

New enum modelling the per-account choice between snapshot-driven and
trade-computed valuation. Field added to Account in a follow-up.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 1.2 — Add `valuationMode` to `Account`

**Files:**
- Modify: `Domain/Models/Account.swift`
- Test: `MoolahTests/Domain/AccountValuationModeTests.swift` (create)

- [ ] **Step 1 — Write the failing test**

```swift
// MoolahTests/Domain/AccountValuationModeTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("Account.valuationMode")
struct AccountValuationModeTests {
  @Test("default is recordedValue")
  func defaultIsRecordedValue() {
    let a = Account(name: "Brokerage", type: .investment, instrument: .AUD)
    #expect(a.valuationMode == .recordedValue)
  }

  @Test("explicit init sets the field")
  func explicitInit() {
    let a = Account(
      name: "Brokerage", type: .investment, instrument: .AUD,
      valuationMode: .calculatedFromTrades)
    #expect(a.valuationMode == .calculatedFromTrades)
  }

  @Test("Codable round-trips both cases")
  func codableRoundTrip() throws {
    for mode in ValuationMode.allCases {
      let original = Account(
        name: "X", type: .investment, instrument: .AUD, valuationMode: mode)
      let data = try JSONEncoder().encode(original)
      let decoded = try JSONDecoder().decode(Account.self, from: data)
      #expect(decoded.valuationMode == mode)
    }
  }

  @Test("Codable decodes missing key as recordedValue")
  func codableMissingKey() throws {
    let json = """
      {
        "id": "00000000-0000-0000-0000-000000000001",
        "name": "Old",
        "type": "investment",
        "instrument": { "id": "AUD", "kind": "fiatCurrency",
                        "name": "AUD", "decimals": 2 },
        "position": 0,
        "hidden": false
      }
      """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(Account.self, from: json)
    #expect(decoded.valuationMode == .recordedValue)
  }

  @Test("Equality includes valuationMode")
  func equalityIncludesMode() {
    let a = Account(name: "A", type: .investment, instrument: .AUD,
                    valuationMode: .recordedValue)
    var b = a
    b.valuationMode = .calculatedFromTrades
    #expect(a != b)
  }
}
```

> The exact `Instrument` JSON shape may differ — verify by encoding an existing `Account` once with `JSONEncoder` if the test fails to decode. The shape above matches the manual `Codable` block currently in `Domain/Models/Account.swift`.

- [ ] **Step 2 — Run test to verify it fails**

```bash
just -d <W> test AccountValuationModeTests 2>&1 | tee <W>/.agent-tmp/test-1.2-fail.txt
```

Expected: compile error referencing `valuationMode`.

- [ ] **Step 3 — Implement on `Account`**

Modify `Domain/Models/Account.swift`:

1. Add `var valuationMode: ValuationMode` to the struct **after** `isHidden` (matches the order other code expects).
2. Add `valuationMode: ValuationMode = .recordedValue` parameter to `init(...)` (default last so existing call sites compile unchanged). Assign `self.valuationMode = valuationMode`.
3. Add `case valuationMode` to `CodingKeys`.
4. In `init(from:)`:
   ```swift
   valuationMode = try container.decodeIfPresent(
     ValuationMode.self, forKey: .valuationMode) ?? .recordedValue
   ```
5. In `encode(to:)`:
   ```swift
   try container.encode(valuationMode, forKey: .valuationMode)
   ```
6. In `==`: append `&& lhs.valuationMode == rhs.valuationMode`.
7. In `hash(into:)`: append `hasher.combine(valuationMode)`.
8. **Do not** include `valuationMode` in `Comparable.<` (sort order is still by `position`).

- [ ] **Step 4 — Run test to verify it passes**

```bash
just -d <W> test AccountValuationModeTests 2>&1 | tee <W>/.agent-tmp/test-1.2-pass.txt
grep -i 'failed\|error:' <W>/.agent-tmp/test-1.2-pass.txt && exit 1 || echo OK
```

- [ ] **Step 5 — Verify no other test broke**

```bash
just -d <W> test 2>&1 | tee <W>/.agent-tmp/test-1.2-full.txt
grep -i 'failed\|error:' <W>/.agent-tmp/test-1.2-full.txt && exit 1 || echo OK
rm <W>/.agent-tmp/test-1.2-*.txt
```

- [ ] **Step 6 — Commit**

```bash
git -C <W> add Domain/Models/Account.swift \
              MoolahTests/Domain/AccountValuationModeTests.swift
git -C <W> commit -m "$(cat <<'EOF'
feat(domain): add valuationMode field to Account

Default .recordedValue preserves today's behaviour for existing accounts
on first decode. decodeIfPresent guards against records arriving from
older clients that don't yet write the field.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 1.3 — Add `valuationMode` to GRDB `AccountRow` (storage + domain mapping)

**Files:**
- Modify: `Backends/GRDB/Records/AccountRow.swift`
- Modify: `Backends/GRDB/Records/AccountRow+Mapping.swift`
- Test: `MoolahTests/Backends/GRDB/AccountRowValuationModeTests.swift` (create)

> **Where the mapping lives.** `AccountRow` is the GRDB cache row AND the type that conforms to `CloudKitRecordConvertible` (via `Backends/GRDB/Sync/AccountRow+CloudKit.swift`). The legacy SwiftData `AccountRecord` is now used only by `CloudKitDataImporter.swift` and `SwiftDataToGRDBMigrator+CoreFinancialGraph.swift` — handled by Task 1.4.

- [ ] **Step 1 — Write the failing test**

```swift
// MoolahTests/Backends/GRDB/AccountRowValuationModeTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("AccountRow.valuationMode")
struct AccountRowValuationModeTests {
  @Test("init(domain:) writes valuationMode")
  func initFromDomain() {
    let account = Account(
      name: "Brokerage", type: .investment, instrument: .AUD,
      valuationMode: .calculatedFromTrades)
    let row = AccountRow(domain: account)
    #expect(row.valuationMode == "calculatedFromTrades")
  }

  @Test("toDomain carries the column back")
  func toDomain() throws {
    let row = AccountRow(
      id: UUID(), recordName: "AccountRecord|x", name: "B",
      type: "investment", instrumentId: "AUD", position: 0,
      isHidden: false, encodedSystemFields: nil,
      valuationMode: "calculatedFromTrades")
    let account = try row.toDomain()
    #expect(account.valuationMode == .calculatedFromTrades)
  }

  @Test("toDomain falls back to recordedValue on unknown raw value")
  func toDomainUnknownValue() throws {
    let row = AccountRow(
      id: UUID(), recordName: "AccountRecord|x", name: "B",
      type: "investment", instrumentId: "AUD", position: 0,
      isHidden: false, encodedSystemFields: nil,
      valuationMode: "garbage")
    let account = try row.toDomain()
    #expect(account.valuationMode == .recordedValue)
  }
}
```

- [ ] **Step 2 — Run test to verify it fails**

```bash
just -d <W> test AccountRowValuationModeTests 2>&1 | tee <W>/.agent-tmp/test-1.3-fail.txt
```

Expected: synthesised memberwise initialiser doesn't accept `valuationMode:`.

- [ ] **Step 3 — Update `AccountRow`**

In `Backends/GRDB/Records/AccountRow.swift`:

1. Add `case valuationMode = "valuation_mode"` to `Columns` (last entry) and `CodingKeys` (last entry).
2. Add stored property **at the end of the property list** (after `encodedSystemFields`) so the synthesised memberwise initialiser places it last:
   ```swift
   var valuationMode: String
   ```
   No default — every call site that constructs an `AccountRow` provides it.

In `Backends/GRDB/Records/AccountRow+Mapping.swift`:

3. In `init(domain:)`, append `self.valuationMode = domain.valuationMode.rawValue`.
4. In `toDomain(...)`, pass the new field to `Account(...)`:
   ```swift
   return Account(
     id: id, name: name, type: try AccountType.decoded(rawValue: type),
     instrument: instrument, positions: positions,
     position: position, isHidden: isHidden,
     valuationMode: ValuationMode(rawValue: valuationMode) ?? .recordedValue)
   ```

- [ ] **Step 4 — Run test to verify it passes**

```bash
just -d <W> test AccountRowValuationModeTests 2>&1 | tee <W>/.agent-tmp/test-1.3-pass.txt
grep -i 'failed\|error:' <W>/.agent-tmp/test-1.3-pass.txt && exit 1 || echo OK
rm <W>/.agent-tmp/test-1.3-*.txt
```

- [ ] **Step 5 — Commit**

```bash
git -C <W> add Backends/GRDB/Records/AccountRow.swift \
              Backends/GRDB/Records/AccountRow+Mapping.swift \
              MoolahTests/Backends/GRDB/AccountRowValuationModeTests.swift
git -C <W> commit -m "$(cat <<'EOF'
feat(grdb): round-trip valuationMode through AccountRow

Column case + property added; init(domain:) and toDomain wire the new
field into both directions.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 1.4 — Add `valuationMode` to legacy SwiftData `AccountRecord`

**Files:**
- Modify: `Backends/CloudKit/Models/AccountRecord.swift`

> **Why this exists.** The SwiftData `AccountRecord` `@Model` is only consumed today by `CloudKitDataImporter.swift` (legacy data import) and `SwiftDataToGRDBMigrator+CoreFinancialGraph.swift` (one-shot migration of users still on the old SwiftData backend). It does not participate in CloudKit sync. Without the field, the SwiftData → GRDB migration would lose the value for any user mid-migration. Plumb the field through both directions.

- [ ] **Step 1 — Write the failing test**

```swift
// MoolahTests/Backends/CloudKit/AccountRecordValuationModeTests.swift  (create)
import Foundation
import Testing

@testable import Moolah

@Suite("AccountRecord (SwiftData mirror) valuationMode")
struct AccountRecordValuationModeTests {
  @Test("from(_:) writes valuationMode")
  func fromAccountWritesField() {
    let account = Account(
      name: "Brokerage", type: .investment, instrument: .AUD,
      valuationMode: .calculatedFromTrades)
    let record = AccountRecord.from(account)
    #expect(record.valuationMode == "calculatedFromTrades")
  }

  @Test("toDomain carries valuationMode through")
  func toDomainCarriesField() throws {
    let record = AccountRecord(
      name: "Brokerage", type: "investment",
      instrumentId: "AUD", position: 0, isHidden: false)
    record.valuationMode = "calculatedFromTrades"
    let account = try record.toDomain()
    #expect(account.valuationMode == .calculatedFromTrades)
  }

  @Test("missing column defaults to recordedValue")
  func legacyRowDecodesAsRecordedValue() throws {
    let record = AccountRecord(
      name: "Old", type: "investment",
      instrumentId: "AUD", position: 0, isHidden: false)
    // Property uses the SwiftData default — never assigned by the test.
    let account = try record.toDomain()
    #expect(account.valuationMode == .recordedValue)
  }
}
```

- [ ] **Step 2 — Run test to verify it fails**

```bash
just -d <W> test AccountRecordValuationModeTests 2>&1 | tee <W>/.agent-tmp/test-1.4-fail.txt
```

- [ ] **Step 3 — Update `AccountRecord`**

In `Backends/CloudKit/Models/AccountRecord.swift`:

1. Add stored property: `var valuationMode: String = "recordedValue"`. (SwiftData default-value form covers existing rows in the legacy store.)
2. In `toDomain(...)`, pass:
   ```swift
   valuationMode: ValuationMode(rawValue: valuationMode) ?? .recordedValue
   ```
3. In `from(_:)`, set the field on the new record before returning:
   ```swift
   let record = AccountRecord(
     id: account.id, name: account.name, type: account.type.rawValue,
     instrumentId: account.instrument.id, position: account.position,
     isHidden: account.isHidden)
   record.valuationMode = account.valuationMode.rawValue
   return record
   ```
   (Keep the existing init signature unchanged so other callers don't break.)

- [ ] **Step 4 — Run test to verify it passes**

```bash
just -d <W> test AccountRecordValuationModeTests 2>&1 | tee <W>/.agent-tmp/test-1.4-pass.txt
grep -i 'failed\|error:' <W>/.agent-tmp/test-1.4-pass.txt && exit 1 || echo OK
rm <W>/.agent-tmp/test-1.4-*.txt
```

- [ ] **Step 5 — Commit**

```bash
git -C <W> add Backends/CloudKit/Models/AccountRecord.swift \
              MoolahTests/Backends/CloudKit/AccountRecordValuationModeTests.swift
git -C <W> commit -m "$(cat <<'EOF'
feat(swiftdata): plumb valuationMode through legacy AccountRecord

The @Model is only used by CloudKitDataImporter and the SwiftData → GRDB
migrator now. Without this, users mid-migration would lose the field.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 1.5 — v6 GRDB schema migration

**Files:**
- Create: `Backends/GRDB/ProfileSchema+AccountValuationMode.swift`
- Modify: `Backends/GRDB/ProfileSchema.swift`
- Test: `MoolahTests/Backends/GRDB/AccountValuationModeMigrationTests.swift` (create)

- [ ] **Step 1 — Write the failing test**

```swift
// MoolahTests/Backends/GRDB/AccountValuationModeMigrationTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("v6_account_valuation_mode migration")
struct AccountValuationModeMigrationTests {
  @Test("column exists on the account table after migration")
  func columnExists() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)
    try queue.read { db in
      let columns = try db.columns(in: "account")
      #expect(columns.contains { $0.name == "valuation_mode" })
    }
  }

  @Test("CHECK constraint rejects unknown raw values")
  func checkConstraintRejectsBadValues() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)
    try queue.write { db in
      do {
        try db.execute(
          sql: """
            INSERT INTO account
              (id, record_name, name, type, instrument_id, position,
               is_hidden, valuation_mode)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [Data(repeating: 1, count: 16), "AccountRecord|y", "B",
                      "investment", "AUD", 0, 0, "garbage"])
        Issue.record("Expected CHECK constraint failure")
      } catch let error as DatabaseError {
        #expect(error.resultCode == .SQLITE_CONSTRAINT)
      }
    }
  }

  @Test("default value backfills legacy rows when ALTER runs")
  func defaultBackfills() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)  // creates column with default
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO account
            (id, record_name, name, type, instrument_id, position, is_hidden)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [Data(repeating: 0, count: 16), "AccountRecord|x", "B",
                    "investment", "AUD", 0, 0])
    }
    let mode: String? = try queue.read { db in
      try String.fetchOne(db, sql: "SELECT valuation_mode FROM account")
    }
    #expect(mode == "recordedValue")
  }
}
```

- [ ] **Step 2 — Run test to verify it fails**

```bash
just -d <W> test AccountValuationModeMigrationTests 2>&1 | tee <W>/.agent-tmp/test-1.5-fail.txt
```

Expected: column does not exist.

- [ ] **Step 3 — Implement the migration**

Create `Backends/GRDB/ProfileSchema+AccountValuationMode.swift`:

```swift
// Backends/GRDB/ProfileSchema+AccountValuationMode.swift

import Foundation
import GRDB

extension ProfileSchema {
  /// v6 migration body. Adds `valuation_mode` to the `account` table.
  /// Default `'recordedValue'` backfills every existing row so the
  /// CHECK constraint stays satisfied; per
  /// `guides/DATABASE_SCHEMA_GUIDE.md` enum-shaped TEXT columns must
  /// pin the raw values from the matching Swift enum (`ValuationMode`).
  static func addAccountValuationMode(_ database: Database) throws {
    try database.execute(
      sql: """
        ALTER TABLE account
          ADD COLUMN valuation_mode TEXT NOT NULL DEFAULT 'recordedValue'
            CHECK (valuation_mode IN ('recordedValue', 'calculatedFromTrades'));
        """)
  }
}
```

In `Backends/GRDB/ProfileSchema.swift`:

1. Bump `static let version = 6`.
2. Add a `v6_account_valuation_mode` line to the doc comment header.
3. After the `v5_drop_foreign_keys` registration, add:
   ```swift
   migrator.registerMigration(
     "v6_account_valuation_mode", migrate: addAccountValuationMode)
   ```

- [ ] **Step 4 — Run test to verify it passes**

```bash
just -d <W> test AccountValuationModeMigrationTests 2>&1 | tee <W>/.agent-tmp/test-1.5-pass.txt
grep -i 'failed\|error:' <W>/.agent-tmp/test-1.5-pass.txt && exit 1 || echo OK
just -d <W> test 2>&1 | tee <W>/.agent-tmp/test-1.5-full.txt
grep -i 'failed\|error:' <W>/.agent-tmp/test-1.5-full.txt && exit 1 || echo OK
rm <W>/.agent-tmp/test-1.5-*.txt
```

- [ ] **Step 5 — Commit**

```bash
git -C <W> add Backends/GRDB/ProfileSchema+AccountValuationMode.swift \
              Backends/GRDB/ProfileSchema.swift \
              MoolahTests/Backends/GRDB/AccountValuationModeMigrationTests.swift
git -C <W> commit -m "$(cat <<'EOF'
feat(grdb): v6 migration adds account.valuation_mode column

NOT NULL DEFAULT 'recordedValue' backfills existing rows. CHECK
constraint pins the column to the raw values of the ValuationMode enum.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 1.6 — CloudKit schema field + wire mapping

**Files:**
- Modify: `CloudKit/schema.ckdb`
- Run: `just generate` (regenerates `Backends/CloudKit/Sync/Generated/AccountRecordCloudKitFields.swift` via the `tools/CKDBSchemaGen` build step)
- Modify: `Backends/GRDB/Sync/AccountRow+CloudKit.swift` (encode/decode)
- Test: `MoolahTests/Backends/GRDB/AccountRowCloudKitFieldsTests.swift` (create or extend)

> **Procedure reference:** the `modifying-cloudkit-schema` skill in `.claude/skills/`.

- [ ] **Step 1 — Edit `CloudKit/schema.ckdb`**

In the `RECORD TYPE AccountRecord (...)` block, add a new field row alongside `name`, `type`, etc.:

```
valuationMode   STRING QUERYABLE SORTABLE,
```

Place it alphabetically — between `type` and the trailing `GRANT` clauses, matching the column ordering used by other record types.

- [ ] **Step 2 — Regenerate the wire layer**

```bash
just -d <W> generate
```

Inspect `Backends/CloudKit/Sync/Generated/AccountRecordCloudKitFields.swift` — confirm a new `valuationMode: String?` field appears in the generated struct, and that both `init(from: CKRecord)` and `write(to: CKRecord)` handle it.

- [ ] **Step 3 — Update `AccountRow+CloudKit.swift` to wire the new field**

In `Backends/GRDB/Sync/AccountRow+CloudKit.swift`:

```swift
extension AccountRow: CloudKitRecordConvertible {
  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    AccountRecordCloudKitFields(
      instrumentId: instrumentId,
      isHidden: isHidden ? 1 : 0,
      name: name,
      position: Int64(position),
      type: type,
      valuationMode: valuationMode      // <-- new
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> AccountRow? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = AccountRecordCloudKitFields(from: ckRecord)
    return AccountRow(
      id: id,
      recordName: ckRecord.recordID.recordName,
      name: fields.name ?? "",
      type: fields.type ?? "bank",
      instrumentId: fields.instrumentId ?? "AUD",
      position: Int(fields.position ?? 0),
      isHidden: (fields.isHidden ?? 0) != 0,
      encodedSystemFields: nil,
      valuationMode: fields.valuationMode ?? "recordedValue"   // <-- new
    )
  }
}
```

- [ ] **Step 4 — Add a CloudKit-mapping round-trip test**

```swift
// MoolahTests/Backends/GRDB/AccountRowCloudKitFieldsTests.swift  (create)
import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("AccountRow ↔ CKRecord round-trip (valuationMode)")
struct AccountRowCloudKitFieldsTests {
  @Test("explicit valuationMode round-trips")
  func roundTrip() throws {
    for raw in ["recordedValue", "calculatedFromTrades"] {
      let row = AccountRow(
        id: UUID(), recordName: "AccountRecord|x", name: "B",
        type: "investment", instrumentId: "AUD", position: 0,
        isHidden: false, encodedSystemFields: nil, valuationMode: raw)
      let zoneID = CKRecordZone.ID(zoneName: "z", ownerName: CKCurrentUserDefaultName)
      let record = row.toCKRecord(in: zoneID)
      let decoded = try #require(AccountRow.fieldValues(from: record))
      #expect(decoded.valuationMode == raw)
    }
  }

  @Test("missing CKRecord field decodes as recordedValue")
  func missingFieldFallsBack() throws {
    let zoneID = CKRecordZone.ID(zoneName: "z", ownerName: CKCurrentUserDefaultName)
    let recordID = CKRecord.ID(
      recordType: AccountRow.recordType, uuid: UUID(), zoneID: zoneID)
    let record = CKRecord(recordType: AccountRow.recordType, recordID: recordID)
    record["name"] = "B"
    record["type"] = "investment"
    record["instrumentId"] = "AUD"
    record["position"] = Int64(0)
    record["isHidden"] = Int64(0)
    // valuationMode intentionally not set
    let decoded = try #require(AccountRow.fieldValues(from: record))
    #expect(decoded.valuationMode == "recordedValue")
  }
}
```

- [ ] **Step 5 — Run tests + format-check**

```bash
just -d <W> test 2>&1 | tee <W>/.agent-tmp/test-1.6-full.txt
grep -i 'failed\|error:' <W>/.agent-tmp/test-1.6-full.txt && exit 1 || echo OK
just -d <W> format-check 2>&1 | tee <W>/.agent-tmp/format-1.6.txt
grep -iE 'would format|warning' <W>/.agent-tmp/format-1.6.txt && exit 1 || echo OK
rm <W>/.agent-tmp/test-1.6-*.txt <W>/.agent-tmp/format-1.6.txt
```

- [ ] **Step 6 — Commit**

```bash
git -C <W> add CloudKit/schema.ckdb \
              Backends/CloudKit/Sync/Generated/AccountRecordCloudKitFields.swift \
              Backends/GRDB/Sync/AccountRow+CloudKit.swift \
              MoolahTests/Backends/GRDB/AccountRowCloudKitFieldsTests.swift
git -C <W> commit -m "$(cat <<'EOF'
feat(cloudkit): add valuationMode field to AccountRecord schema + wire mapping

Wire field is non-required; missing field decodes as recordedValue so a
not-yet-upgraded client's records remain decodable.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 1.7 — Extend the AccountRepository contract test

**Files:**
- Modify: `MoolahTests/Domain/AccountRepositoryContractTests.swift`

The spec calls for `valuationMode` to round-trip through `create`/`fetchAll`/`update`/`delete`. Existing contract tests run against `CloudKitBackend` with in-memory GRDB.

- [ ] **Step 1 — Read existing patterns**

```bash
grep -n "@Test\|fetchAll\|create\|update" \
  /Users/aj/Documents/code/moolah-project/moolah-native/MoolahTests/Domain/AccountRepositoryContractTests.swift | head -30
```

Note the existing test pattern (likely `let (backend, _) = try TestBackend.create()` followed by a series of `await` calls).

- [ ] **Step 2 — Add the failing test**

Append to `AccountRepositoryContractTests`:

```swift
@Test("valuationMode round-trips through create + fetchAll + update")
@MainActor
func valuationModeRoundTrip() async throws {
  let (backend, _) = try TestBackend.create()
  let saved = try await backend.accounts.create(
    Account(name: "B", type: .investment, instrument: .AUD,
            valuationMode: .calculatedFromTrades))
  #expect(saved.valuationMode == .calculatedFromTrades)

  let after = try await backend.accounts.fetchAll()
  let fetched = try #require(after.first { $0.id == saved.id })
  #expect(fetched.valuationMode == .calculatedFromTrades)

  var updated = fetched
  updated.valuationMode = .recordedValue
  let resaved = try await backend.accounts.update(updated)
  #expect(resaved.valuationMode == .recordedValue)

  let final = try await backend.accounts.fetchAll()
  let refetched = try #require(final.first { $0.id == saved.id })
  #expect(refetched.valuationMode == .recordedValue)
}
```

> If `AccountRepositoryContractTests` is parameterised over multiple backends, add the test inside the same `@Suite` so it runs against every backend the contract tests already cover.

- [ ] **Step 3 — Run test to verify it passes**

The implementation already handles round-trip (Tasks 1.3–1.6) so this is a regression guard rather than a TDD step. If it fails, an earlier task missed a wire-up.

```bash
just -d <W> test AccountRepositoryContractTests 2>&1 | tee <W>/.agent-tmp/test-1.7.txt
grep -i 'failed\|error:' <W>/.agent-tmp/test-1.7.txt && exit 1 || echo OK
rm <W>/.agent-tmp/test-1.7.txt
```

- [ ] **Step 4 — Commit**

```bash
git -C <W> add MoolahTests/Domain/AccountRepositoryContractTests.swift
git -C <W> commit -m "$(cat <<'EOF'
test(domain): contract test for AccountRepository valuationMode round-trip

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 1.8 — Phase 1 review-fix loop and PR

- [ ] **Step 1 — `just format`**

```bash
just -d <W> format
```

- [ ] **Step 2 — Xcode warnings**

Use `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"`. Fix every warning in user code (preview-macro warnings ignored). Common fixes from CLAUDE.md:
- `_ = try await ...` for unused throwing results
- `var` → `let` for non-mutated vars
- Remove unused initialisations

- [ ] **Step 3 — Run review agents**

```text
@code-review
@database-schema-review
@database-code-review
@sync-review
```

Address every Critical, Important, and Minor finding. Per `feedback_apply_all_review_findings.md`, none are skipped — pre-existing-in-another-file is not a reason. Per `feedback_swiftlint_fix_not_baseline.md`, do not modify `.swiftlint-baseline.yml`.

- [ ] **Step 4 — Push and open PR**

```bash
git -C <W> push origin valuation-mode/1-schema:valuation-mode/1-schema
gh pr create --title "feat: add per-account valuationMode field (no behaviour change)" --body "$(cat <<'EOF'
## Summary
- New `ValuationMode` enum (`recordedValue` | `calculatedFromTrades`) and `Account.valuationMode` field with default `.recordedValue`.
- Round-trip the field through `AccountRow` (GRDB), `AccountRow+CloudKit` (wire), and the legacy SwiftData `AccountRecord` (used by importer + SwiftData→GRDB migrator).
- v6 GRDB migration adds the `valuation_mode` column with `NOT NULL DEFAULT 'recordedValue'` and a CHECK constraint.
- CloudKit schema gains the field; wire mapping handles missing-field decode.
- Contract test pins the round-trip through `AccountRepository`.

No call site reads the new field yet — this PR is observably a no-op for users.

Spec: [`plans/2026-05-04-per-account-valuation-mode-design.md`](https://github.com/ajsutton/moolah-native/blob/main/plans/2026-05-04-per-account-valuation-mode-design.md) (Phase 1)
Plan: `plans/2026-05-04-per-account-valuation-mode-plan.md` (Phase 1)

## Test plan
- [x] `just test` green
- [x] `just format-check` clean
- [x] No new warnings

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 5 — Add to merge queue**

```bash
~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add <PR-NUMBER>
```

Wait for merge before starting Phase 2.

---

## Phase 2 — One-shot migration on profile bootstrap (PR 2)

**Branch:** `valuation-mode/2-migration`
**Worktree:** `.worktrees/valuation-mode-2-migration`
**Reviewers:** `code-review`, `concurrency-review`, `database-code-review`

Adds the `ValuationModeMigration` that runs once per profile, deriving each investment account's initial mode from snapshot presence. **Does not change observable behaviour** — read sites are still on auto-detect; the migration just sets the field so subsequent PRs can switch read sites to it without a per-PR migration.

### Task 2.1 — Create the migration

**Files:**
- Create: `App/ValuationModeMigration.swift`
- Test: `MoolahTests/App/ValuationModeMigrationTests.swift` (create)

- [ ] **Step 1 — Write the failing test**

```swift
// MoolahTests/App/ValuationModeMigrationTests.swift
import Foundation
import Testing

@testable import Moolah

@MainActor
@Suite("ValuationModeMigration")
struct ValuationModeMigrationTests {
  // Helper: builds a fresh in-memory backend and migration with a unique
  // UserDefaults suite per test (so gate flags don't bleed between tests).
  private func makeFixture(
    profileId: UUID = UUID()
  ) throws -> (
    backend: CloudKitBackend, defaults: UserDefaults,
    migration: ValuationModeMigration
  ) {
    let suite = "test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let (backend, _) = try TestBackend.create()
    let migration = ValuationModeMigration(
      profileId: profileId,
      accountRepository: backend.accounts,
      investmentRepository: backend.investments,
      userDefaults: defaults)
    return (backend, defaults, migration)
  }

  @Test("investment account with snapshot stays at recordedValue")
  func snapshotAccountUntouched() async throws {
    let (backend, _, migration) = try makeFixture()
    let saved = try await backend.accounts.create(
      Account(name: "Brokerage", type: .investment, instrument: .AUD))
    try await backend.investments.setValue(
      accountId: saved.id, date: Date(),
      value: InstrumentAmount(quantity: 100, instrument: .AUD))

    try await migration.run()

    let all = try await backend.accounts.fetchAll()
    let after = try #require(all.first { $0.id == saved.id })
    #expect(after.valuationMode == .recordedValue)
  }

  @Test("investment account without snapshot flips to calculatedFromTrades")
  func emptyAccountFlips() async throws {
    let (backend, _, migration) = try makeFixture()
    let saved = try await backend.accounts.create(
      Account(name: "Crypto", type: .investment, instrument: .AUD))

    try await migration.run()

    let all = try await backend.accounts.fetchAll()
    let after = try #require(all.first { $0.id == saved.id })
    #expect(after.valuationMode == .calculatedFromTrades)
  }

  @Test("non-investment account is left alone")
  func nonInvestmentSkipped() async throws {
    let (backend, _, migration) = try makeFixture()
    let saved = try await backend.accounts.create(
      Account(name: "Checking", type: .bank, instrument: .AUD))

    try await migration.run()

    let all = try await backend.accounts.fetchAll()
    let after = try #require(all.first { $0.id == saved.id })
    #expect(after.valuationMode == .recordedValue)
  }

  @Test("re-running with the gate flag set is a no-op")
  func gateFlagShortCircuits() async throws {
    let (backend, defaults, migration) = try makeFixture()
    _ = try await backend.accounts.create(
      Account(name: "X", type: .investment, instrument: .AUD))
    try await migration.run()
    #expect(defaults.bool(
      forKey: "didMigrateValuationMode_\(migration.profileId)"))

    // Pre-flip an account to recordedValue; re-running must not flip it back.
    let all = try await backend.accounts.fetchAll()
    var account = all[0]
    account.valuationMode = .recordedValue
    _ = try await backend.accounts.update(account)

    try await migration.run()
    let after = (try await backend.accounts.fetchAll())[0]
    #expect(after.valuationMode == .recordedValue)
  }

  @Test("per-profile gate flags are independent")
  func perProfileGateIsolation() async throws {
    let (_, defaults, migrationA) = try makeFixture()
    let migrationB = ValuationModeMigration(
      profileId: UUID(),
      accountRepository: migrationA.accountRepository,
      investmentRepository: migrationA.investmentRepository,
      userDefaults: defaults)

    try await migrationA.run()
    #expect(defaults.bool(forKey: "didMigrateValuationMode_\(migrationA.profileId)"))
    #expect(!defaults.bool(forKey: "didMigrateValuationMode_\(migrationB.profileId)"))
  }
}
```

- [ ] **Step 2 — Run test to verify it fails**

```bash
mkdir -p <W>/.agent-tmp
just -d <W> test ValuationModeMigrationTests 2>&1 | tee <W>/.agent-tmp/test-2.1-fail.txt
```

Expected: `ValuationModeMigration` does not exist.

- [ ] **Step 3 — Implement the migration**

Create `App/ValuationModeMigration.swift`:

```swift
// App/ValuationModeMigration.swift

import Foundation
import OSLog

/// One-shot per-profile migration that derives each investment
/// account's initial `valuationMode` from snapshot presence.
///
/// Runs on first launch after upgrade, gated by a per-profile
/// `UserDefaults` flag. Re-running with the flag already set is a
/// no-op. See `plans/2026-05-04-per-account-valuation-mode-design.md`
/// §4 for the algorithm and §Migration & Rollout for ordering.
@MainActor
struct ValuationModeMigration {
  let profileId: UUID
  let accountRepository: any AccountRepository
  let investmentRepository: any InvestmentRepository
  let userDefaults: UserDefaults

  private var gateKey: String { "didMigrateValuationMode_\(profileId)" }

  private var logger: Logger {
    Logger(subsystem: "com.moolah.app", category: "ValuationModeMigration")
  }

  func run() async throws {
    if userDefaults.bool(forKey: gateKey) { return }

    let accounts = try await accountRepository.fetchAll()
    for account in accounts where account.type == .investment {
      let page = try await investmentRepository.fetchValues(
        accountId: account.id, page: 0, pageSize: 1)
      if page.values.isEmpty {
        var updated = account
        updated.valuationMode = .calculatedFromTrades
        _ = try await accountRepository.update(updated)
        logger.info(
          "Migrated account \(account.name, privacy: .public) → calculatedFromTrades")
      }
      // else: snapshot exists → leave at .recordedValue (no-op write).
    }
    userDefaults.set(true, forKey: gateKey)
  }
}
```

- [ ] **Step 4 — Run tests to verify pass**

```bash
just -d <W> test ValuationModeMigrationTests 2>&1 | tee <W>/.agent-tmp/test-2.1-pass.txt
grep -i 'failed\|error:' <W>/.agent-tmp/test-2.1-pass.txt && exit 1 || echo OK
rm <W>/.agent-tmp/test-2.1-*.txt
```

- [ ] **Step 5 — Commit**

```bash
git -C <W> add App/ValuationModeMigration.swift \
              MoolahTests/App/ValuationModeMigrationTests.swift
git -C <W> commit -m "$(cat <<'EOF'
feat(app): add ValuationModeMigration

One-shot per-profile migration that derives each investment account's
initial valuationMode from snapshot presence. Gated by a per-profile
UserDefaults flag; re-runs are no-ops.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 2.2 — Wire migration into profile bootstrap

**Files:**
- Modify: one of the `App/ProfileSession*.swift` files (identified in Step 1)

- [ ] **Step 1 — Find the bootstrap call site**

```bash
grep -n "AccountStore(\|refreshBalances\|investmentRepository" \
  /Users/aj/Documents/code/moolah-project/moolah-native/App/ProfileSession*.swift | head -40
```

Identify the function that builds the `AccountStore` and triggers the first load. The migration must run *after* the GRDB cache is hydrated and `accountRepository` + `investmentRepository` are reachable, but *before* `AccountStore.refreshBalances()`.

- [ ] **Step 2 — Add a call to the migration**

In the identified bootstrap function, insert:

```swift
let migration = ValuationModeMigration(
  profileId: profile.id,
  accountRepository: accountRepository,
  investmentRepository: investmentRepository,
  userDefaults: .standard)
do {
  try await migration.run()
} catch {
  Logger(subsystem: "com.moolah.app", category: "ProfileSession")
    .error(
      "ValuationModeMigration failed: \(error.localizedDescription, privacy: .public)")
  // Non-fatal: app continues; auto-detect read sites still work in this PR.
}
```

The migration is non-fatal — if it throws, the app still works because read sites are still on auto-detect at this point in the rollout.

- [ ] **Step 3 — Run the full test suite**

```bash
just -d <W> test 2>&1 | tee <W>/.agent-tmp/test-2.2-full.txt
grep -i 'failed\|error:' <W>/.agent-tmp/test-2.2-full.txt && exit 1 || echo OK
rm <W>/.agent-tmp/test-2.2-full.txt
```

- [ ] **Step 4 — Manual smoke test via the `run-mac-app-with-logs` skill**

Use the project's `run-mac-app-with-logs` skill (preferred over manually opening Console.app). Open an existing investment account that has at least one snapshot. Open another investment account that has no snapshot. Quit. Re-open. Verify in the captured logs that the migration ran exactly once and that one of the two accounts was flipped to `calculatedFromTrades`.

- [ ] **Step 5 — Commit**

```bash
git -C <W> add App/ProfileSession.swift  # or whichever file you modified in Step 2
git -C <W> commit -m "$(cat <<'EOF'
feat(app): run ValuationModeMigration on profile bootstrap

Non-fatal: if the migration fails, the app continues with auto-detect
read sites (which are still in place at this rollout stage).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 2.3 — Phase 2 review-fix loop and PR

- [ ] **Step 1 — `just format` + Xcode warnings**

- [ ] **Step 2 — Run review agents**

```text
@code-review
@concurrency-review
@database-code-review
```

- [ ] **Step 3 — Push and open PR**

```bash
git -C <W> push origin valuation-mode/2-migration:valuation-mode/2-migration
gh pr create --title "feat: derive Account.valuationMode on profile bootstrap" --body "$(cat <<'EOF'
## Summary
- One-shot per-profile migration sets `Account.valuationMode` for existing investment accounts based on snapshot presence.
- Gated by per-profile UserDefaults; idempotent.
- Wired into profile bootstrap before `AccountStore.refreshBalances()`.

No observable behaviour change — read sites still auto-detect. The migration just stages the field for subsequent PRs.

Spec: Phase 2 of design doc.

## Test plan
- [x] `just test` green
- [x] Manual: launch app twice via `run-mac-app-with-logs`; verify migration runs once
- [x] `just format-check` clean

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4 — Add to merge queue and wait**

---

## Phase 3 — Wire `AccountBalanceCalculator` and `InvestmentValueCache.preload` filter (PR 3)

**Branch:** `valuation-mode/3-balance-calc`
**Worktree:** `.worktrees/valuation-mode-3-balance-calc`
**Reviewers:** `code-review`, `concurrency-review`, `instrument-conversion-review`

Replaces the data-presence checks in `displayBalance` and `totalConverted` with explicit `account.valuationMode` checks. After this PR, sidebar / net worth / intents read the migrated field. **For every existing account this matches the prior behaviour exactly** (the migration set the mode to match the data shape). Also filters the sidebar's `InvestmentValueCache.preload` to skip trades-mode accounts (saves fetches).

### Task 3.1 — Switch `displayBalance` to read mode

**Files:**
- Modify: `Features/Accounts/AccountBalanceCalculator.swift`
- Modify: `MoolahTests/Features/AccountBalanceCalculatorTests.swift` (extend existing)

- [ ] **Step 1 — Read the existing test file to find a reusable conversion stub**

```bash
grep -n "ConversionService\|FixedConversion\|StubConversion" \
  /Users/aj/Documents/code/moolah-project/moolah-native/MoolahTests/Features/AccountBalanceCalculatorTests.swift
```

Reuse whatever stub the existing tests use (likely `FixedConversionService` from `MoolahTests/Support/`). **Do not** roll a new minimal stub — `InstrumentConversionService` may have additional protocol requirements.

- [ ] **Step 2 — Write the failing tests**

Append to `MoolahTests/Features/AccountBalanceCalculatorTests.swift`:

```swift
@Suite("AccountBalanceCalculator + ValuationMode")
struct AccountBalanceCalculatorValuationModeTests {
  @Test("recordedValue + snapshot → balance = snapshot")
  @MainActor
  func recordedWithSnapshot() async throws {
    let calc = AccountBalanceCalculator(
      conversionService: FixedConversionService(), targetInstrument: .AUD)
    let account = Account(
      name: "B", type: .investment, instrument: .AUD,
      valuationMode: .recordedValue)
    let snapshot = InstrumentAmount(quantity: 1234, instrument: .AUD)
    let balance = try await calc.displayBalance(
      for: account, investmentValue: snapshot)
    #expect(balance == snapshot)
  }

  @Test("recordedValue + missing snapshot → balance = zero (NOT positions sum)")
  @MainActor
  func recordedWithoutSnapshotIsZero() async throws {
    let calc = AccountBalanceCalculator(
      conversionService: FixedConversionService(), targetInstrument: .AUD)
    var account = Account(
      name: "B", type: .investment, instrument: .AUD,
      valuationMode: .recordedValue)
    account.positions = [Position(instrument: .AUD, quantity: 999)]
    let balance = try await calc.displayBalance(
      for: account, investmentValue: nil)
    #expect(balance == .zero(instrument: .AUD))
  }

  @Test("calculatedFromTrades → positions sum (snapshot ignored)")
  @MainActor
  func calculatedSumsPositionsIgnoringSnapshot() async throws {
    let calc = AccountBalanceCalculator(
      conversionService: FixedConversionService(), targetInstrument: .AUD)
    var account = Account(
      name: "B", type: .investment, instrument: .AUD,
      valuationMode: .calculatedFromTrades)
    account.positions = [Position(instrument: .AUD, quantity: 500)]
    let snapshot = InstrumentAmount(quantity: 9999, instrument: .AUD)
    let balance = try await calc.displayBalance(
      for: account, investmentValue: snapshot)
    #expect(balance == InstrumentAmount(quantity: 500, instrument: .AUD))
  }

  @Test("non-investment account ignores valuationMode")
  @MainActor
  func nonInvestmentIgnoresMode() async throws {
    let calc = AccountBalanceCalculator(
      conversionService: FixedConversionService(), targetInstrument: .AUD)
    var account = Account(
      name: "Checking", type: .bank, instrument: .AUD,
      valuationMode: .recordedValue)  // would normally take snapshot, but type=.bank
    account.positions = [Position(instrument: .AUD, quantity: 42)]
    let snapshot = InstrumentAmount(quantity: 9999, instrument: .AUD)
    let balance = try await calc.displayBalance(
      for: account, investmentValue: snapshot)
    #expect(balance == InstrumentAmount(quantity: 42, instrument: .AUD))
  }
}
```

> **Verify the `Position` initialiser shape** before writing. If `Position(instrument:quantity:)` is the wrong call (`Position` may take an `amount: InstrumentAmount`), check `Domain/Models/Position.swift`. The test must compile.

- [ ] **Step 3 — Run test to verify it fails**

```bash
just -d <W> test AccountBalanceCalculatorValuationModeTests 2>&1 \
  | tee <W>/.agent-tmp/test-3.1-fail.txt
```

Expected: `recordedWithoutSnapshotIsZero` and `calculatedSumsPositionsIgnoringSnapshot` fail.

- [ ] **Step 4 — Update `displayBalance`**

Replace the body of `displayBalance(for:investmentValue:)` in `Features/Accounts/AccountBalanceCalculator.swift`:

```swift
func displayBalance(
  for account: Account, investmentValue: InstrumentAmount?
) async throws -> InstrumentAmount {
  if account.type == .investment, account.valuationMode == .recordedValue {
    return investmentValue ?? .zero(instrument: account.instrument)
  }
  var total = InstrumentAmount.zero(instrument: account.instrument)
  let date = Date()
  for position in account.positions {
    if position.amount.instrument == account.instrument {
      total += position.amount
    } else {
      total += try await conversionService.convertAmount(
        position.amount, to: account.instrument, on: date)
    }
  }
  return total
}
```

- [ ] **Step 5 — Run new tests + audit existing tests**

```bash
just -d <W> test AccountBalanceCalculatorValuationModeTests 2>&1 \
  | tee <W>/.agent-tmp/test-3.1-pass.txt
grep -i 'failed\|error:' <W>/.agent-tmp/test-3.1-pass.txt && exit 1 || echo OK
just -d <W> test AccountBalanceCalculatorTests 2>&1 \
  | tee <W>/.agent-tmp/test-3.1-existing.txt
grep -i 'failed\|error:' <W>/.agent-tmp/test-3.1-existing.txt && exit 1 || echo OK
```

If existing tests in `AccountBalanceCalculatorTests` (or sibling stores: `AccountStoreInvestmentValuesTests`, `AccountStoreConversionTests`, `AccountStoreLoadingTests`, `AccountStoreApplyDeltaTests`, `AccountStoreMutationsTests`) fail because they relied on auto-detect, fix them by **explicitly** setting `account.valuationMode`:
- Tests that assert "snapshot drives balance" → set `valuationMode = .recordedValue` (default).
- Tests that assert "positions drive balance for an investment account" → set `valuationMode = .calculatedFromTrades`.

Do an upfront sweep to find candidates:

```bash
grep -rln "type: .investment" \
  /Users/aj/Documents/code/moolah-project/moolah-native/MoolahTests/Features/AccountStore*Tests.swift
```

For each file: read it, identify investment-account fixtures, set the mode explicitly to make the test's intent clear.

- [ ] **Step 6 — Commit**

```bash
git -C <W> add Features/Accounts/AccountBalanceCalculator.swift \
              MoolahTests/Features/AccountBalanceCalculatorTests.swift \
              MoolahTests/Features/AccountStore*Tests.swift   # any updated
git -C <W> commit -m "$(cat <<'EOF'
feat(accounts): displayBalance reads Account.valuationMode

Recorded mode + missing snapshot → zero (no fallback to positions). This
removes the auto-detect at the read site so downstream UI can no longer
infer a mode from data presence. Existing tests updated to set the mode
explicitly where investment accounts are involved.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 3.2 — Switch `totalConverted` to read mode

**Files:**
- Modify: `Features/Accounts/AccountBalanceCalculator.swift`

- [ ] **Step 1 — Inspect `InvestmentValueCache` and choose the test seed approach**

```bash
sed -n '1,80p' \
  /Users/aj/Documents/code/moolah-project/moolah-native/Features/Accounts/InvestmentValueCache.swift
```

`InvestmentValueCache` is `@MainActor final class` with `init(repository:)` and a `set(_:for:)` mutator. **Construct a real cache with `InvestmentValueCache(repository: nil)` and seed via `cache.set(amount, for: id)`** — there is no protocol to stub.

- [ ] **Step 2 — Write the failing tests**

Append to `AccountBalanceCalculatorValuationModeTests`:

```swift
@Test("totalConverted: recordedValue investment uses cache value")
@MainActor
func totalConvertedRecordedMode() async throws {
  let calc = AccountBalanceCalculator(
    conversionService: FixedConversionService(), targetInstrument: .AUD)
  var withSnapshot = Account(
    name: "A", type: .investment, instrument: .AUD,
    valuationMode: .recordedValue)
  withSnapshot.positions = [Position(instrument: .AUD, quantity: 999)]
  var withoutSnapshot = Account(
    name: "B", type: .investment, instrument: .AUD,
    valuationMode: .recordedValue)
  withoutSnapshot.positions = [Position(instrument: .AUD, quantity: 999)]

  let cache = InvestmentValueCache(repository: nil)
  cache.set(InstrumentAmount(quantity: 100, instrument: .AUD), for: withSnapshot.id)
  // withoutSnapshot has no cache entry.

  let total = try await calc.totalConverted(
    for: [withSnapshot, withoutSnapshot], to: .AUD, using: cache)
  #expect(total == InstrumentAmount(quantity: 100, instrument: .AUD))
}

@Test("totalConverted: calculatedFromTrades sums positions, ignores cache")
@MainActor
func totalConvertedTradesMode() async throws {
  let calc = AccountBalanceCalculator(
    conversionService: FixedConversionService(), targetInstrument: .AUD)
  var account = Account(
    name: "A", type: .investment, instrument: .AUD,
    valuationMode: .calculatedFromTrades)
  account.positions = [Position(instrument: .AUD, quantity: 500)]
  let cache = InvestmentValueCache(repository: nil)
  cache.set(InstrumentAmount(quantity: 99, instrument: .AUD), for: account.id)
  let total = try await calc.totalConverted(
    for: [account], to: .AUD, using: cache)
  #expect(total == InstrumentAmount(quantity: 500, instrument: .AUD))
}
```

> Check `InvestmentValueCache.init` parameter; if `repository:` requires non-nil, pass a no-op repo or use whatever pattern the existing tests use.

- [ ] **Step 3 — Run test to verify it fails**

```bash
just -d <W> test AccountBalanceCalculatorValuationModeTests 2>&1 \
  | tee <W>/.agent-tmp/test-3.2-fail.txt
```

- [ ] **Step 4 — Update `totalConverted`**

Replace the body of `totalConverted(for:to:using:)`:

```swift
func totalConverted(
  for accounts: [Account],
  to target: Instrument,
  using investmentValues: InvestmentValueCache? = nil
) async throws -> InstrumentAmount {
  var total = InstrumentAmount.zero(instrument: target)
  let date = Date()
  for account in accounts {
    if account.type == .investment, account.valuationMode == .recordedValue {
      let snapshot = investmentValues?.value(for: account.id)
        ?? .zero(instrument: account.instrument)
      if snapshot.instrument == target {
        total += snapshot
      } else {
        total += try await conversionService.convertAmount(
          snapshot, to: target, on: date)
      }
      continue
    }
    for position in account.positions {
      if position.amount.instrument == target {
        total += position.amount
      } else {
        total += try await conversionService.convertAmount(
          position.amount, to: target, on: date)
      }
    }
  }
  return total
}
```

- [ ] **Step 5 — Run tests + full suite**

```bash
just -d <W> test 2>&1 | tee <W>/.agent-tmp/test-3.2-full.txt
grep -i 'failed\|error:' <W>/.agent-tmp/test-3.2-full.txt && exit 1 || echo OK
rm <W>/.agent-tmp/test-3.2-*.txt
```

- [ ] **Step 6 — Commit**

```bash
git -C <W> add Features/Accounts/AccountBalanceCalculator.swift \
              MoolahTests/Features/AccountBalanceCalculatorTests.swift
git -C <W> commit -m "$(cat <<'EOF'
feat(accounts): totalConverted reads Account.valuationMode

Mirrors displayBalance: recordedValue investment accounts contribute
their snapshot (or zero); other accounts contribute the position sum.
Predicate is type==.investment AND mode==.recordedValue so non-investment
accounts always position-sum regardless of the field.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 3.3 — Filter `InvestmentValueCache.preload` to recorded-mode accounts

**Files:**
- Modify: `Features/Accounts/AccountStore.swift` (specifically `preloadInvestmentValues`)

- [ ] **Step 1 — Read the call site**

```bash
sed -n '95,115p' \
  /Users/aj/Documents/code/moolah-project/moolah-native/Features/Accounts/AccountStore.swift
```

`preloadInvestmentValues()` collects investment account ids and calls `investmentValueCache.preload(for:)`. With explicit modes, only `.recordedValue` accounts need a snapshot preload.

- [ ] **Step 2 — Write the failing test**

```swift
// MoolahTests/Features/AccountStorePreloadFilterTests.swift  (create)
import Foundation
import Testing

@testable import Moolah

@MainActor
@Suite("AccountStore preloads only recordedValue accounts")
struct AccountStorePreloadFilterTests {
  @Test("only recordedValue investment accounts get a preload")
  func preloadFiltersByMode() async throws {
    let (backend, _) = try TestBackend.create()
    let recorded = try await backend.accounts.create(
      Account(name: "R", type: .investment, instrument: .AUD,
              valuationMode: .recordedValue))
    let trades = try await backend.accounts.create(
      Account(name: "T", type: .investment, instrument: .AUD,
              valuationMode: .calculatedFromTrades))
    try await backend.investments.setValue(
      accountId: recorded.id, date: Date(),
      value: InstrumentAmount(quantity: 100, instrument: .AUD))
    try await backend.investments.setValue(
      accountId: trades.id, date: Date(),
      value: InstrumentAmount(quantity: 999, instrument: .AUD))

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: FixedConversionService(),
      targetInstrument: .AUD,
      investmentRepository: backend.investments)
    await store.load()

    #expect(store.investmentValues[recorded.id] != nil)
    #expect(store.investmentValues[trades.id] == nil)
  }
}
```

- [ ] **Step 3 — Run test to verify it fails**

Today's preload populates `investmentValues` for both accounts (it doesn't read mode). The trades-account assertion will fail.

```bash
just -d <W> test AccountStorePreloadFilterTests 2>&1 | tee <W>/.agent-tmp/test-3.3-fail.txt
```

- [ ] **Step 4 — Update `preloadInvestmentValues`**

In `Features/Accounts/AccountStore.swift`, change the id-collection in `preloadInvestmentValues()`:

```swift
let investmentAccountIds = accounts
  .filter { $0.type == .investment && $0.valuationMode == .recordedValue }
  .map(\.id)
await investmentValueCache.preload(for: investmentAccountIds)
```

- [ ] **Step 5 — Run tests to verify pass**

```bash
just -d <W> test AccountStorePreloadFilterTests 2>&1 | tee <W>/.agent-tmp/test-3.3-pass.txt
grep -i 'failed\|error:' <W>/.agent-tmp/test-3.3-pass.txt && exit 1 || echo OK
just -d <W> test AccountStoreInvestmentValuesTests 2>&1 \
  | tee <W>/.agent-tmp/test-3.3-existing.txt
grep -i 'failed\|error:' <W>/.agent-tmp/test-3.3-existing.txt && exit 1 || echo OK
rm <W>/.agent-tmp/test-3.3-*.txt
```

If `AccountStoreInvestmentValuesTests` fail, set `valuationMode = .recordedValue` on each investment account fixture (default already, but make explicit).

- [ ] **Step 6 — Commit**

```bash
git -C <W> add Features/Accounts/AccountStore.swift \
              MoolahTests/Features/AccountStorePreloadFilterTests.swift
git -C <W> commit -m "$(cat <<'EOF'
feat(accounts): preload investment values only for recordedValue accounts

Saves a per-account fetch for trades-mode accounts whose snapshot is
unused.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 3.4 — Phase 3 review-fix loop and PR

- [ ] **Step 1 — `just format` + Xcode warnings**

- [ ] **Step 2 — Run review agents**

```text
@code-review
@concurrency-review
@instrument-conversion-review
```

- [ ] **Step 3 — Push and open PR**

```bash
git -C <W> push origin valuation-mode/3-balance-calc:valuation-mode/3-balance-calc
gh pr create --title "feat: AccountBalanceCalculator + preload filter read Account.valuationMode" --body "$(cat <<'EOF'
## Summary
- `displayBalance` and `totalConverted` branch on `account.valuationMode` instead of presence-of-snapshot.
- `AccountStore.preloadInvestmentValues` skips trades-mode investment accounts (saves fetches).
- For accounts migrated by PR 2, behaviour is unchanged.
- Recorded-mode investment accounts with no snapshot now report a zero balance (was: silently summed positions).

Spec: Phase 3.

## Test plan
- [x] New tests cover both modes, recorded-empty case, non-investment case, preload filter
- [x] Existing balance/store tests updated to set mode explicitly
- [x] `just test` green; `just format-check` clean

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4 — Add to merge queue and wait**

---

## Phase 4 — Wire `InvestmentAccountView` + `InvestmentStore` (PR 4)

**Branch:** `valuation-mode/4-view-store`
**Worktree:** `.worktrees/valuation-mode-4-view-store`
**Reviewers:** `code-review`, `ui-review`, `concurrency-review`

Switches the account-detail layout selection and the `InvestmentStore` data load to read `account.valuationMode`. Removes `hasLegacyValuations`. Preserves the toolbar-stability invariant that prevented a Release-only AppKit crash. **Note:** the user-facing Picker that lets a user actually flip the mode arrives in PR 6, so this PR's mode-flip path can only be exercised manually via a debug-only menu item or via direct repository writes; defer the Release-build crash smoke test to Phase 6.

### Task 4.1 — Change `InvestmentStore.loadAllData` signature

**Files:**
- Modify: `Features/Investments/InvestmentStore.swift`
- Modify: every call site of `loadAllData` and `reloadPositionsIfNeeded`
- Test: `MoolahTests/Features/InvestmentStoreValuationModeTests.swift` (create)

- [ ] **Step 1 — Find call sites**

```bash
grep -rn "loadAllData\|reloadPositionsIfNeeded" \
  /Users/aj/Documents/code/moolah-project/moolah-native --include="*.swift" \
  | grep -v ".worktrees"
```

Expected: `InvestmentAccountView` and possibly preview/test helpers.

- [ ] **Step 2 — Write the failing test**

```swift
// MoolahTests/Features/InvestmentStoreValuationModeTests.swift  (create)
import Foundation
import Testing

@testable import Moolah

@MainActor
@Suite("InvestmentStore branches on Account.valuationMode")
struct InvestmentStoreValuationModeTests {
  @Test("loadAllData(account:) calls legacy path when mode is recordedValue")
  func recordedTakesLegacyPath() async throws {
    let (backend, _) = try TestBackend.create()
    let account = try await backend.accounts.create(
      Account(name: "B", type: .investment, instrument: .AUD,
              valuationMode: .recordedValue))
    try await backend.investments.setValue(
      accountId: account.id, date: Date(),
      value: InstrumentAmount(quantity: 100, instrument: .AUD))

    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService)
    await store.loadAllData(account: account, profileCurrency: .AUD)

    #expect(!store.values.isEmpty)
    #expect(store.positions.isEmpty)  // legacy path doesn't load positions
  }

  @Test("loadAllData(account:) calls trades path when mode is calculatedFromTrades")
  func tradesTakesPositionsPath() async throws {
    let (backend, _) = try TestBackend.create()
    let account = try await backend.accounts.create(
      Account(name: "T", type: .investment, instrument: .AUD,
              valuationMode: .calculatedFromTrades))
    // Even with snapshots present, mode forces the trades path.
    try await backend.investments.setValue(
      accountId: account.id, date: Date(),
      value: InstrumentAmount(quantity: 9999, instrument: .AUD))

    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService)
    await store.loadAllData(account: account, profileCurrency: .AUD)

    #expect(store.values.isEmpty)  // trades path does not call loadValues
  }
}
```

> Check `CloudKitBackend` has a `transactions` accessor (it does — see `AccountStoreInvestmentValuesTests.swift` for the pattern). If your `InvestmentStore.init` requires `transactionRepository: TransactionRepository?` (optional), the line above is correct — confirm with the source.

- [ ] **Step 3 — Run test to verify it fails**

```bash
just -d <W> test InvestmentStoreValuationModeTests 2>&1 \
  | tee <W>/.agent-tmp/test-4.1-fail.txt
```

Expected: signature mismatch.

- [ ] **Step 4 — Update `InvestmentStore`**

In `Features/Investments/InvestmentStore.swift`:

1. Change signature:
   ```swift
   func loadAllData(account: Account, profileCurrency: Instrument) async {
     loadedHostCurrency = profileCurrency
     accountPerformance = nil
     switch account.valuationMode {
     case .recordedValue:
       await loadValues(accountId: account.id)
       await loadDailyBalances(accountId: account.id, hostCurrency: profileCurrency)
       guard !Task.isCancelled else { return }
       accountPerformance = AccountPerformanceCalculator.computeLegacy(
         dailyBalances: dailyBalances, values: values, instrument: profileCurrency)
     case .calculatedFromTrades:
       await loadPositions(accountId: account.id)
       await valuatePositions(profileCurrency: profileCurrency, on: Date())
       await refreshPositionTrackedPerformance(
         accountId: account.id, profileCurrency: profileCurrency)
     }
   }
   ```
2. Change `reloadPositionsIfNeeded(accountId:profileCurrency:)` → `reloadPositionsIfNeeded(account:profileCurrency:)` and gate on `account.valuationMode == .calculatedFromTrades`.
3. **Remove** the `hasLegacyValuations` computed property (current line 232) — it's no longer the source of truth.

- [ ] **Step 5 — Update call sites**

In every file found in Step 1, change `loadAllData(accountId: account.id, profileCurrency: ...)` → `loadAllData(account: account, profileCurrency: ...)` and similarly for `reloadPositionsIfNeeded`.

- [ ] **Step 6 — Run tests + full suite**

```bash
just -d <W> test 2>&1 | tee <W>/.agent-tmp/test-4.1-full.txt
grep -i 'failed\|error:' <W>/.agent-tmp/test-4.1-full.txt && exit 1 || echo OK
rm <W>/.agent-tmp/test-4.1-*.txt
```

- [ ] **Step 7 — Commit**

```bash
git -C <W> add Features/Investments/InvestmentStore.swift \
              Features/Investments/Views/InvestmentAccountView.swift \
              MoolahTests/Features/InvestmentStoreValuationModeTests.swift
git -C <W> commit -m "$(cat <<'EOF'
feat(investments): InvestmentStore branches on Account.valuationMode

loadAllData and reloadPositionsIfNeeded take an Account and pivot on
its valuationMode. hasLegacyValuations removed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 4.2 — Change `InvestmentAccountView` layout selection (with toolbar guard)

**Files:**
- Modify: `Features/Investments/Views/InvestmentAccountView.swift`

- [ ] **Step 1 — Read the current layout decision and the gate's purpose**

```bash
sed -n '20,140p' \
  /Users/aj/Documents/code/moolah-project/moolah-native/Features/Investments/Views/InvestmentAccountView.swift
```

Identify the `if !initialLoadComplete` two-frame gate and the layout switch (~line 130). The gate's docstring (lines 21–28) explains the AppKit toolbar crash it prevents.

- [ ] **Step 2 — Update the layout selector**

Replace the body's switch (~line 130):

```swift
switch account.valuationMode {
case .recordedValue:    legacyValuationsLayout
case .calculatedFromTrades: positionTrackedLayout
}
```

The summary tile at line 83 currently reads `investmentStore.values.isEmpty`. Re-read its surrounding code and decide:
- If the tile is "show snapshots-related summary when there are snapshots", keep the data-presence predicate (it's checking content, not layout).
- If the tile is choosing between two layouts of summary, switch to `account.valuationMode`.

The empty-state predicates at `InvestmentAccountView.swift:225` and `InvestmentValuesView.swift:11` (`investmentStore.values.isEmpty`) **stay as-is** — they check whether snapshots have been recorded yet *within the legacy layout*, not which layout to render.

- [ ] **Step 3 — Preserve toolbar stability**

The existing two-frame gate is keyed on `initialLoadComplete` (set after the first `loadAllData`). With explicit mode the layout decision no longer requires waiting for the load. However, **mid-session mode flips can still tear down `TransactionListView`'s toolbar within one render pass** if the layout changes from one branch to the other. Two options:

**Option A — Keep the existing gate keyed on a transition flag.** Add a `@State` that flips to `true` on `account.valuationMode` change, then back to `false` after a `Task.yield()`:

```swift
@State private var pendingLayoutSwitch = false

// In body:
Group {
  if !initialLoadComplete || pendingLayoutSwitch {
    ProgressView()
  } else {
    switch account.valuationMode {
    case .recordedValue:    legacyValuationsLayout
    case .calculatedFromTrades: positionTrackedLayout
    }
  }
}
.onChange(of: account.valuationMode) { _, _ in
  pendingLayoutSwitch = true
  Task {
    await Task.yield()
    pendingLayoutSwitch = false
  }
}
```

**Option B — Identity-stable wrapping.** Wrap both layouts in a parent that owns a stable `TransactionListView` identity. This is more invasive and likely doesn't cleanly work because the legacy layout doesn't have a `TransactionListView` at all.

**Pick Option A.** It mirrors the existing gate's mechanism (a `ProgressView()` frame in the same render position) so AppKit teardown happens cleanly.

- [ ] **Step 4 — Smoke-test build only**

The user-facing Picker that lets a user actually flip the mode arrives in Phase 6. In this PR, the mode-flip path is unreachable from the UI. Defer the **Release-build mode-flip smoke test** to Phase 6 (Task 6.1 Step 4 will exercise it). Just confirm the Debug build compiles and the layout picks the right initial branch:

```bash
just -d <W> build-mac
```

- [ ] **Step 5 — Commit**

```bash
git -C <W> add Features/Investments/Views/InvestmentAccountView.swift
git -C <W> commit -m "$(cat <<'EOF'
feat(investments): InvestmentAccountView layout reads Account.valuationMode

Two-frame ProgressView gate on mode change preserves the toolbar-
stability invariant. Mode-flip-in-Release smoke test deferred to PR 6
when the user-facing Picker exists.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 4.3 — Phase 4 review-fix loop and PR

- [ ] **Step 1 — `just format` + Xcode warnings**

- [ ] **Step 2 — Run review agents**

```text
@code-review
@ui-review
@concurrency-review
```

- [ ] **Step 3 — Push and open PR**

```bash
git -C <W> push origin valuation-mode/4-view-store:valuation-mode/4-view-store
gh pr create --title "feat: investment view + store read Account.valuationMode" --body "$(cat <<'EOF'
## Summary
- `InvestmentStore.loadAllData` and `reloadPositionsIfNeeded` switch on `account.valuationMode`.
- `InvestmentAccountView` selects layout from the same field.
- Two-frame ProgressView gate added to preserve the toolbar-stability invariant.
- Removed `InvestmentStore.hasLegacyValuations`.
- Mode-flip-in-Release smoke test deferred to PR 6 (user-facing toggle ships there).

Spec: Phase 4.

## Test plan
- [x] InvestmentStore mode-branching tests
- [x] Existing investment tests pass with explicit mode set on fixtures
- [x] `just build-mac` clean
- [x] `just format-check` clean

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4 — Add to merge queue and wait**

---

## Phase 5 — Wire daily-balance fold (PR 5)

**Branch:** `valuation-mode/5-daily-balance`
**Worktree:** `.worktrees/valuation-mode-5-daily-balance`
**Reviewers:** `code-review`, `database-code-review`

Filters the snapshot fold by `valuation_mode = 'recordedValue'`. Trades-mode accounts no longer leak snapshots into per-day balances. Re-pin the index test for the new SELECT.

### Task 5.1 — Filter `fetchInvestmentAccountIds` SQL

**Files:**
- Modify: `Backends/GRDB/Repositories/GRDBAnalysisRepository+DailyBalancesInvestmentValues.swift`
- Test: `MoolahTests/Backends/GRDB/InvestmentAccountIdsModeFilterTests.swift` (create)
- Modify: `MoolahTests/Backends/GRDB/DailyBalancesPlanPinningTests.swift` (re-pin)

- [ ] **Step 1 — Write the failing test**

```swift
// MoolahTests/Backends/GRDB/InvestmentAccountIdsModeFilterTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("fetchInvestmentAccountIds filters by mode")
struct InvestmentAccountIdsModeFilterTests {
  @Test("only recordedValue investment accounts are returned")
  func filtersByMode() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)
    let recordedId = UUID()
    let tradesId = UUID()
    let bankId = UUID()
    try queue.write { db in
      for (id, type, mode) in [
        (recordedId, "investment", "recordedValue"),
        (tradesId,   "investment", "calculatedFromTrades"),
        (bankId,     "bank",       "recordedValue"),
      ] {
        try db.execute(
          sql: """
            INSERT INTO account
              (id, record_name, name, type, instrument_id, position,
               is_hidden, valuation_mode)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [id.uuidData, "AccountRecord|\(id)", "n",
                      type, "AUD", 0, 0, mode])
      }
    }
    let ids = try queue.read { db in
      try GRDBAnalysisRepository.fetchInvestmentAccountIds(database: db)
    }
    #expect(ids == [recordedId])
  }
}

private extension UUID {
  var uuidData: Data {
    withUnsafeBytes(of: self.uuid) { Data($0) }
  }
}
```

> If the test infrastructure already exposes a `UUID.databaseValue` helper for BLOB columns, prefer that. Otherwise the local extension above produces the same 16-byte representation.

- [ ] **Step 2 — Run test to verify it fails**

```bash
just -d <W> test InvestmentAccountIdsModeFilterTests 2>&1 \
  | tee <W>/.agent-tmp/test-5.1-fail.txt
```

Expected: `ids` contains both investment account ids.

- [ ] **Step 3 — Update the SQL**

In `Backends/GRDB/Repositories/GRDBAnalysisRepository+DailyBalancesInvestmentValues.swift`, change the `fetchInvestmentAccountIds` SQL:

```swift
let rows = try Row.fetchAll(
  database,
  sql: """
    SELECT id FROM account
    WHERE type = 'investment' AND valuation_mode = 'recordedValue'
    """)
```

- [ ] **Step 4 — Run tests to verify pass**

```bash
just -d <W> test InvestmentAccountIdsModeFilterTests 2>&1 \
  | tee <W>/.agent-tmp/test-5.1-pass.txt
grep -i 'failed\|error:' <W>/.agent-tmp/test-5.1-pass.txt && exit 1 || echo OK
```

- [ ] **Step 5 — Re-pin the daily-balance plan-pinning test**

Find the existing pinning test:

```bash
grep -rln "fetchInvestmentAccountIds\|DailyBalancesPlanPinning" \
  /Users/aj/Documents/code/moolah-project/moolah-native/MoolahTests
```

Run it to capture the new EXPLAIN QUERY PLAN string:

```bash
just -d <W> test DailyBalancesPlanPinningTests 2>&1 \
  | tee <W>/.agent-tmp/test-5.1-pin.txt
```

If the test fails, the plan changed (expected). Read the assertion's expected EXPLAIN string, compare with what GRDB emitted, and update the pinned string in the test to match the new plan.

**Acceptance criteria:**
- The new plan must use an *index* on the `account` lookup (covering `account_by_type` is acceptable; a SCAN of `account` is **not**). If the new plan shows `SCAN account`, add a partial index in a new migration step (`v7_account_recorded_index`) before merging this PR:

  ```sql
  CREATE INDEX account_recorded_investments
    ON account(id) WHERE type = 'investment' AND valuation_mode = 'recordedValue';
  ```

  Add the migration via the same pattern as Task 1.5 (new sibling file + new `migrator.registerMigration("v7_..."...)` line + bump `static let version = 7`). Add a column-existence test for the new index.

- The covering index `iv_by_account_date_value` must still serve the snapshot-loop SELECT. Confirm that hasn't changed.

```bash
just -d <W> test DailyBalancesPlanPinningTests 2>&1 \
  | tee <W>/.agent-tmp/test-5.1-pin-final.txt
grep -i 'failed\|error:' <W>/.agent-tmp/test-5.1-pin-final.txt && exit 1 || echo OK
rm <W>/.agent-tmp/test-5.1-*.txt
```

- [ ] **Step 6 — Commit**

```bash
git -C <W> add Backends/GRDB/Repositories/GRDBAnalysisRepository+DailyBalancesInvestmentValues.swift \
              MoolahTests/Backends/GRDB/InvestmentAccountIdsModeFilterTests.swift \
              MoolahTests/Backends/GRDB/DailyBalancesPlanPinningTests.swift \
              # plus the new v7 index migration files if added in Step 5
git -C <W> commit -m "$(cat <<'EOF'
feat(grdb): daily-balance snapshot fold filters by Account.valuationMode

Trades-mode investment accounts no longer leak snapshot folds into
per-day balances. Plan-pinning re-pinned for the new predicate. Per the
design, trades-mode historical chart values remain a known limitation
tracked separately.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 5.2 — Phase 5 review-fix loop and PR

- [ ] **Step 1 — `just format` + Xcode warnings**

- [ ] **Step 2 — Run review agents**

```text
@code-review
@database-code-review
```

- [ ] **Step 3 — Push and open PR**

```bash
git -C <W> push origin valuation-mode/5-daily-balance:valuation-mode/5-daily-balance
gh pr create --title "feat: daily-balance fold filters by valuationMode" --body "$(cat <<'EOF'
## Summary
- `fetchInvestmentAccountIds` filters by `valuation_mode = 'recordedValue'`.
- Re-pinned the daily-balance plan-pinning test for the new predicate.
- (If needed) v7 partial index added for the new SELECT.

Spec: Phase 5. Trades-mode chart accuracy remains a tracked follow-up.

## Test plan
- [x] New filter test passes
- [x] Plan-pinning test re-recorded; index covering verified
- [x] `just test` green

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4 — Add to merge queue and wait**

---

## Phase 6 — Settings UI + new-account default + final smoke test (PR 6)

**Branch:** `valuation-mode/6-ui-default`
**Worktree:** `.worktrees/valuation-mode-6-ui-default`
**Reviewers:** `code-review`, `ui-review`

Adds the picker to `EditAccountView`, flips the new-investment-account default to `.calculatedFromTrades`, lands the user-observable behaviour change, and runs the deferred Release-build mode-flip smoke test.

### Task 6.1 — Add the Picker to `EditAccountView`

**Files:**
- Modify: `Features/Accounts/Views/EditAccountView.swift`
- Test: `MoolahUITests_macOS/EditAccountValuationModeTests.swift` (create — XCUITest macOS-only)

- [ ] **Step 1 — Update `EditAccountView`**

In `Features/Accounts/Views/EditAccountView.swift`:

1. Add a stored `@State` for the mode:
   ```swift
   @State private var valuationMode: ValuationMode
   ```
2. Initialise in `init`:
   ```swift
   _valuationMode = State(initialValue: account.valuationMode)
   ```
3. Add a new computed view, `valuationSection`, conditional on `type == .investment`:
   ```swift
   @ViewBuilder
   private var valuationSection: some View {
     if type == .investment {
       Section {
         Picker("Valuation", selection: $valuationMode) {
           Text("Recorded value").tag(ValuationMode.recordedValue)
           Text("Calculated from trades").tag(ValuationMode.calculatedFromTrades)
         }
         .accessibilityIdentifier("editAccount.valuationMode")
       } footer: {
         Text(valuationMode == .recordedValue
              ? "The account's current value comes from the latest valuation snapshot you entered."
              : "The account's current value is computed from your trade history and current instrument prices.")
       }
     }
   }
   ```
4. Insert `valuationSection` in `form` between `detailsSection` and the error section:
   ```swift
   private var form: some View {
     Form {
       detailsSection
       valuationSection
       if let errorMessage { ... }
     }
     ...
   }
   ```
5. In `save()`, persist the mode:
   ```swift
   var updated = account
   updated.name = name.trimmingCharacters(in: .whitespaces)
   updated.type = type
   updated.instrument = currency
   updated.isHidden = isHidden
   updated.valuationMode = valuationMode  // <-- new
   ```

- [ ] **Step 2 — Add a UI test (macOS-only XCUITest)**

```swift
// MoolahUITests_macOS/EditAccountValuationModeTests.swift  (create)
import XCTest

final class EditAccountValuationModeTests: XCTestCase {
  func testValuationModePickerVisibleForInvestmentAccounts() throws {
    let app = XCUIApplication()
    app.launchArguments += ["--ui-test", "--seed=editAccountValuationMode"]
    app.launch()

    // Drive the existing screen-driver helpers; see UITestSupport/.
    let driver = SidebarDriver(app: app)
    driver.openAccount(named: "Test Investment")
    let editor = AccountEditDriver(app: app).open()
    XCTAssertTrue(editor.valuationModePicker.exists)
    editor.setValuationMode(.calculatedFromTrades)
    editor.save()

    // Re-open and verify persistence.
    let editor2 = AccountEditDriver(app: app).open()
    XCTAssertEqual(editor2.currentValuationMode, .calculatedFromTrades)
  }
}
```

> The exact driver names (`SidebarDriver`, `AccountEditDriver`) and seed identifiers must match the existing `UITestSupport/` and `UITestSeeds.swift` patterns. Per `feedback_xcuitest.md` (XCUITest is set up and reliable), use the existing screen-driver pattern from `MoolahUITests_macOS/`. If `AccountEditDriver` doesn't yet have a `valuationModePicker` accessor, add it (driver-only file under `MoolahUITests_macOS/Drivers/`); this is the test driver, not a production change.
>
> If a new test seed is needed, add it to `UITestSeeds.swift` per the `writing-ui-tests` skill.

- [ ] **Step 3 — Manual smoke test (Debug build)**

```bash
just -d <W> run-mac
```

Open an investment account → Edit → confirm the "Valuation" section appears with the correct selection. Switch type to "Bank Account" → section disappears. Switch back to "Investment" → section reappears. Toggle the picker; confirm the footer text updates live. Save with a changed mode; reopen the editor; confirm the new mode is loaded.

- [ ] **Step 4 — Release-build mode-flip smoke test (deferred from Phase 4)**

Build the macOS app in Release configuration and verify that flipping the mode via the editor does **not** crash:

```bash
xcodebuild -workspace Moolah.xcworkspace -scheme Moolah_macOS \
  -configuration Release build -destination 'platform=macOS'
```

Open the built `Moolah.app`, switch a test investment account between modes via the picker, repeatedly. The two-frame ProgressView gate added in Phase 4 must absorb the layout teardown without an AppKit toolbar crash. If it crashes, **stop** — file an issue, drop back to Option B in Phase 4 Task 4.2 Step 3 (identity-stable wrapping), or escalate.

- [ ] **Step 5 — Commit**

```bash
git -C <W> add Features/Accounts/Views/EditAccountView.swift \
              MoolahUITests_macOS/EditAccountValuationModeTests.swift \
              MoolahUITests_macOS/Drivers/ \
              UITestSupport/   # if seeds were added
git -C <W> commit -m "$(cat <<'EOF'
feat(accounts): EditAccountView picker for ValuationMode + UI test

Conditional Section visible only for investment accounts. Footer text
explains the active mode. XCUITest pins picker visibility, persistence,
and the macOS Release mode-flip stability invariant.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 6.2 — Default new investment accounts to calculatedFromTrades

**Files:**
- Modify: `Features/Accounts/AccountStore.swift` (specifically `create(...)`)

- [ ] **Step 1 — Find the create site**

```bash
grep -n "func create" \
  /Users/aj/Documents/code/moolah-project/moolah-native/Features/Accounts/AccountStore.swift
```

- [ ] **Step 2 — Write the failing test**

```swift
// MoolahTests/Features/AccountStoreNewAccountDefaultTests.swift  (create)
import Foundation
import Testing

@testable import Moolah

@MainActor
@Suite("AccountStore.create defaults investment accounts to calculatedFromTrades")
struct AccountStoreNewAccountDefaultTests {
  private func makeStore() throws -> (AccountStore, CloudKitBackend) {
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: FixedConversionService(),
      targetInstrument: .AUD,
      investmentRepository: backend.investments)
    return (store, backend)
  }

  @Test("new investment account whose mode is the struct default → trades")
  func newInvestmentDefaultsToTrades() async throws {
    let (store, backend) = try makeStore()
    let saved = try await store.create(
      Account(name: "Brokerage", type: .investment, instrument: .AUD))
    let all = try await backend.accounts.fetchAll()
    let after = try #require(all.first { $0.id == saved.id })
    #expect(after.valuationMode == .calculatedFromTrades)
  }

  @Test("new bank account stays at recordedValue (the unread default)")
  func newBankUnchanged() async throws {
    let (store, backend) = try makeStore()
    let saved = try await store.create(
      Account(name: "Checking", type: .bank, instrument: .AUD))
    let all = try await backend.accounts.fetchAll()
    let after = try #require(all.first { $0.id == saved.id })
    #expect(after.valuationMode == .recordedValue)
  }

  @Test("explicit calculatedFromTrades on the input is preserved")
  func explicitTradesModeRespected() async throws {
    let (store, backend) = try makeStore()
    let saved = try await store.create(
      Account(name: "B", type: .investment, instrument: .AUD,
              valuationMode: .calculatedFromTrades))
    let all = try await backend.accounts.fetchAll()
    let after = try #require(all.first { $0.id == saved.id })
    #expect(after.valuationMode == .calculatedFromTrades)
  }
}
```

> **Limitation acknowledged:** "explicit recorded vs default recorded" cannot be distinguished by `create`. The migration writes via `update`, the editor writes via `update` — neither hits this code path. The only way for a user to land at recorded mode on a brand-new account is via the editor after creation. The third test deliberately exercises the inverse direction (explicit *trades*) to prove the override only fires when the input is already at the struct default.

- [ ] **Step 3 — Run test to verify it fails**

```bash
just -d <W> test AccountStoreNewAccountDefaultTests 2>&1 \
  | tee <W>/.agent-tmp/test-6.2-fail.txt
```

- [ ] **Step 4 — Update `AccountStore.create`**

In `Features/Accounts/AccountStore.swift`, modify `create(_:)` (the no-`openingBalance` extension is the one most callers hit; if both arities exist, modify both) to override `valuationMode` only when the type is `.investment` AND the input is at the struct default:

```swift
func create(_ account: Account, openingBalance: InstrumentAmount? = nil) async throws -> Account {
  var toSave = account
  if toSave.type == .investment && toSave.valuationMode == .recordedValue {
    toSave.valuationMode = .calculatedFromTrades
  }
  return try await accountRepository.create(toSave, openingBalance: openingBalance)
}
```

> If `AccountStore.create` already does other work (e.g., notifies stores), fold the override into the existing wrapper. If the store doesn't currently wrap `create` and just exposes the repository directly, add a thin wrapper.

- [ ] **Step 5 — Run tests + audit existing tests**

```bash
just -d <W> test AccountStoreNewAccountDefaultTests 2>&1 \
  | tee <W>/.agent-tmp/test-6.2-pass.txt
grep -i 'failed\|error:' <W>/.agent-tmp/test-6.2-pass.txt && exit 1 || echo OK
just -d <W> test 2>&1 | tee <W>/.agent-tmp/test-6.2-full.txt
grep -i 'failed\|error:' <W>/.agent-tmp/test-6.2-full.txt && exit 1 || echo OK
rm <W>/.agent-tmp/test-6.2-*.txt
```

If any existing test creates an investment account via `AccountStore.create` and then expects recorded-mode behaviour, choose one:
- Pass `valuationMode = .recordedValue` explicitly via `accountRepository.create` directly (bypassing the store's override), OR
- Update the test to expect the new default.

- [ ] **Step 6 — Commit**

```bash
git -C <W> add Features/Accounts/AccountStore.swift \
              MoolahTests/Features/AccountStoreNewAccountDefaultTests.swift
git -C <W> commit -m "$(cat <<'EOF'
feat(accounts): default new investment accounts to calculatedFromTrades

User-driven account creation lands in trades mode by default. Existing
accounts and migration-driven writes are unaffected (update(), not
create()).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 6.3 — `AddInvestmentValueIntent` regression-guard test

**Files:**
- Test: `MoolahTests/Automation/AddInvestmentValueIntentTests.swift` (create or extend)

- [ ] **Step 1 — Find the existing test pattern for `AutomationService`**

```bash
ls /Users/aj/Documents/code/moolah-project/moolah-native/MoolahTests/Automation/
grep -n "AutomationService\b" \
  /Users/aj/Documents/code/moolah-project/moolah-native/MoolahTests/Automation/*.swift | head
```

Match the existing init / setup pattern (likely creates a `TestBackend`, wraps in some service container, exposes `setInvestmentValue`).

- [ ] **Step 2 — Write the regression test**

```swift
// MoolahTests/Automation/AddInvestmentValueIntentTests.swift  (create or append)
import Foundation
import Testing

@testable import Moolah

@MainActor
@Suite("AddInvestmentValueIntent (policy)")
struct AddInvestmentValueIntentPolicyTests {
  @Test("writes a snapshot even when account is in calculatedFromTrades mode")
  func writesInTradesMode() async throws {
    let (backend, _) = try TestBackend.create()
    let saved = try await backend.accounts.create(
      Account(name: "Brokerage", type: .investment, instrument: .AUD,
              valuationMode: .calculatedFromTrades))

    // Build the AutomationService using the existing pattern from sibling
    // tests in MoolahTests/Automation/ — exact init shape varies.
    let service = try makeAutomationServiceForTests(backend: backend)
    try await service.setInvestmentValue(
      profileIdentifier: backend.profileIdentifier,  // adapt to actual prop
      accountName: "Brokerage",
      date: Date(),
      value: 100)

    let page = try await backend.investments.fetchValues(
      accountId: saved.id, page: 0, pageSize: 10)
    #expect(page.values.count == 1)
  }
}
```

> If `makeAutomationServiceForTests` and `backend.profileIdentifier` aren't real symbols, copy the pattern from the closest sibling test (e.g., `AutomationServiceAccountTests.swift`).

- [ ] **Step 3 — Run test to verify it passes**

The current implementation already writes regardless of mode (no mode check). The test exists as a regression guard.

```bash
just -d <W> test AddInvestmentValueIntentPolicyTests 2>&1 | tee <W>/.agent-tmp/test-6.3.txt
grep -i 'failed\|error:' <W>/.agent-tmp/test-6.3.txt && exit 1 || echo OK
rm <W>/.agent-tmp/test-6.3.txt
```

- [ ] **Step 4 — Commit**

```bash
git -C <W> add MoolahTests/Automation/AddInvestmentValueIntentTests.swift
git -C <W> commit -m "$(cat <<'EOF'
test(automation): AddInvestmentValueIntent writes snapshots in trades mode

Regression guard for the documented policy: intent-driven snapshot
writes succeed regardless of the account's current valuation mode.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 6.4 — Phase 6 review-fix loop and PR

- [ ] **Step 1 — `just format` + Xcode warnings**

- [ ] **Step 2 — Run review agents**

```text
@code-review
@ui-review
@ui-test-review
```

- [ ] **Step 3 — Push and open PR**

```bash
git -C <W> push origin valuation-mode/6-ui-default:valuation-mode/6-ui-default
gh pr create --title "feat: settings picker + trades-as-default for new investment accounts" --body "$(cat <<'EOF'
## Summary
- `EditAccountView` gains a "Valuation" picker (visible only for investment accounts).
- `AccountStore.create` defaults new investment accounts to `.calculatedFromTrades`.
- Release-build mode-flip smoke test (deferred from Phase 4) executed.
- `AddInvestmentValueIntent` regression test pins "writes regardless of mode" policy.

This is the first PR that lets users observably change behaviour. Existing accounts retain whichever mode the migration set.

Spec: Phase 6.

## Test plan
- [x] EditAccountView XCUITest covers picker visibility + persistence
- [x] AccountStore.create default tests
- [x] AddInvestmentValueIntent policy test
- [x] Release smoke: layout flip via picker doesn't crash
- [x] `just test` green; `just format-check` clean

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4 — Add to merge queue and wait**

---

## Post-rollout verification

After PR 6 merges:

- [ ] Update the design doc status from "Draft, pending review (round 2)" to "Implemented" (one-line edit, separate small PR).
- [ ] Move the design + plan to `plans/completed/` (one-line `git mv` PR; coordinate via merge queue).
- [ ] File a follow-up GitHub issue tracking the "valued positions over time" daily-balance series for trades-mode accounts (see spec's "Pre-Existing Limitation: Historical Chart"). Reference the spec.
- [ ] Verify on a real-data profile via `automate-app` skill: existing recorded-mode accounts unchanged; existing empty-investment accounts now show "Calculated from trades" in the editor; new investment accounts default to trades mode.
