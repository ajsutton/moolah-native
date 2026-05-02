# CloudKit Schema as Source of Truth — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the design in `plans/2026-04-25-cloudkit-schema-as-source-of-truth-design.md`. `CloudKit/schema.ckdb` becomes the canonical source of truth; a new `tools/CKDBSchemaGen/` SPM executable parses it and emits one Swift wire struct per record type. Hand-written `*Record+CloudKit.swift` adapters become thin (recordID strategy + domain-type mapping). A committed `CloudKit/schema-prod-baseline.ckdb` tracks current Production. PR-time CI runs a static additivity check; release-tag CI promotes and refreshes the baseline.

**Architecture:** Schema → wire struct → adapter → CKRecord. The `.ckdb` is the only file a developer hand-edits when fields change. Generated wire structs (gitignored) appear in `Backends/CloudKit/Sync/Generated/` after `just generate`. Hand-written adapters under `Backends/CloudKit/Sync/*Record+CloudKit.swift` use them. PR-time CI never touches CloudKit.

**Tech Stack:** Swift `Testing` (project's existing test framework), Swift Package Manager (for the generator), `xcrun cktool` (Xcode CLI), bash scripts under `scripts/`, `just` targets, GitHub Actions.

**Critical context:**
- v2 Production has never been promoted. The first `promote-schema` after merge is the first-ever Production publish for v2.
- v2 Development is dirty (legacy CD\_-prefixed fields from a SwiftData migration plus unprefixed fields from the running app). Not used by this plan in any automation; it stays available as a personal scratch container.
- The branch ships as one PR. New `.ckdb`, baseline, generator, refactored adapters, scripts, Justfile, CI, skill, docs — all together — to avoid leaving `main` half-migrated.
- Per project memory, every PR opened goes through the merge-queue skill. The post-promote baseline-refresh PR is mechanical and queues like any other.

**File structure (created/modified, in order):**

| Path | Action | Owner |
|---|---|---|
| `.gitignore` | modify | this PR |
| `CloudKit/schema.ckdb` | full rewrite | this PR |
| `CloudKit/schema-prod-baseline.ckdb` | new (committed) | this PR |
| `tools/CKDBSchemaGen/Package.swift` | new | this PR |
| `tools/CKDBSchemaGen/Sources/CKDBSchemaGen/Schema.swift` | new | this PR |
| `tools/CKDBSchemaGen/Sources/CKDBSchemaGen/Parser.swift` | new | this PR |
| `tools/CKDBSchemaGen/Sources/CKDBSchemaGen/Generator.swift` | new | this PR |
| `tools/CKDBSchemaGen/Sources/CKDBSchemaGen/Additivity.swift` | new | this PR |
| `tools/CKDBSchemaGen/Sources/CKDBSchemaGen/main.swift` | new | this PR |
| `tools/CKDBSchemaGen/Tests/CKDBSchemaGenTests/ParserTests.swift` | new | this PR |
| `tools/CKDBSchemaGen/Tests/CKDBSchemaGenTests/GeneratorTests.swift` | new | this PR |
| `tools/CKDBSchemaGen/Tests/CKDBSchemaGenTests/AdditivityTests.swift` | new | this PR |
| `Backends/CloudKit/Sync/Generated/*` | new (gitignored — emitted by generator) | runtime |
| `Backends/CloudKit/Sync/AccountRecord+CloudKit.swift` | refactor | this PR |
| `Backends/CloudKit/Sync/CategoryRecord+CloudKit.swift` | refactor | this PR |
| `Backends/CloudKit/Sync/CSVImportProfileRecord+CloudKit.swift` | refactor | this PR |
| `Backends/CloudKit/Sync/EarmarkBudgetItemRecord+CloudKit.swift` | refactor | this PR |
| `Backends/CloudKit/Sync/EarmarkRecord+CloudKit.swift` | refactor | this PR |
| `Backends/CloudKit/Sync/ImportRuleRecord+CloudKit.swift` | refactor | this PR |
| `Backends/CloudKit/Sync/InstrumentRecord+CloudKit.swift` | refactor | this PR |
| `Backends/CloudKit/Sync/InvestmentValueRecord+CloudKit.swift` | refactor | this PR |
| `Backends/CloudKit/Sync/ProfileRecord+CloudKit.swift` | refactor | this PR |
| `Backends/CloudKit/Sync/TransactionLegRecord+CloudKit.swift` | refactor | this PR |
| `Backends/CloudKit/Sync/TransactionRecord+CloudKit.swift` | refactor | this PR |
| `MoolahTests/Backends/CloudKit/RoundTripTests.swift` | new | this PR |
| `scripts/verify-schema.sh` | repurpose | this PR |
| `scripts/dryrun-promote-schema.sh` | new | this PR |
| `scripts/verify-prod-matches-baseline.sh` | new | this PR |
| `scripts/check-schema-additive.sh` | new | this PR |
| `scripts/promote-schema.sh` | extend | this PR |
| `Justfile` | modify | this PR |
| `.github/workflows/ci.yml` | modify (re-enable schema job, point at additive check) | this PR |
| `.github/workflows/testflight.yml` | modify (add baseline verify + post-promote PR) | this PR |
| `.claude/skills/modifying-cloudkit-schema/SKILL.md` | new | this PR |
| `guides/SYNC_GUIDE.md` | replace §11 | this PR |
| `CLAUDE.md` | small update | this PR |

---

## Task 1: Ignore the Generated/ directory

Establish the convention before anything else writes there. Tiny first commit so the gitignore change has a clear history entry.

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Add Generated/ entry to `.gitignore`**

Append the following block to `.gitignore` immediately after the `# Worktrees` block (so generated artefacts cluster together):

```
# CloudKit wire structs generated by tools/CKDBSchemaGen from CloudKit/schema.ckdb.
# Regenerated by `just generate`. Never edit by hand.
Backends/CloudKit/Sync/Generated/
```

- [ ] **Step 2: Verify**

Run:

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 check-ignore -v Backends/CloudKit/Sync/Generated/foo.swift
```

Expected: `.gitignore:<line> Backends/CloudKit/Sync/Generated/`. Any other output (or empty output) means the entry is wrong; fix and re-run.

- [ ] **Step 3: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 add .gitignore
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 commit -m "chore(cloudkit): ignore generated wire-struct directory"
```

---

## Task 2: Rewrite `CloudKit/schema.ckdb` with the complete manifest

Replace the file contents with the full inventory: all 11 `CloudKitRecordConvertible` types plus `Users`, bare record-type names (no CD\_ prefix), `___recordID REFERENCE QUERYABLE` on every type, and the standard grants. Field set derived from the existing `Backends/CloudKit/Sync/*Record+CloudKit.swift` files.

**Files:**
- Modify: `CloudKit/schema.ckdb` (full rewrite)

- [ ] **Step 1: Replace `CloudKit/schema.ckdb`**

Overwrite the file with:

```
DEFINE SCHEMA

    RECORD TYPE AccountRecord (
        "___createTime" TIMESTAMP,
        "___createdBy"  REFERENCE,
        "___etag"       STRING,
        "___modTime"    TIMESTAMP,
        "___modifiedBy" REFERENCE,
        "___recordID"   REFERENCE QUERYABLE,
        instrumentId    STRING QUERYABLE SEARCHABLE SORTABLE,
        isHidden        INT64 QUERYABLE SORTABLE,
        name            STRING QUERYABLE SEARCHABLE SORTABLE,
        position        INT64 QUERYABLE SORTABLE,
        type            STRING QUERYABLE SEARCHABLE SORTABLE,
        GRANT WRITE TO "_creator",
        GRANT CREATE TO "_icloud",
        GRANT READ TO "_world"
    );

    RECORD TYPE CategoryRecord (
        "___createTime" TIMESTAMP,
        "___createdBy"  REFERENCE,
        "___etag"       STRING,
        "___modTime"    TIMESTAMP,
        "___modifiedBy" REFERENCE,
        "___recordID"   REFERENCE QUERYABLE,
        name            STRING QUERYABLE SEARCHABLE SORTABLE,
        parentId        STRING QUERYABLE SEARCHABLE SORTABLE,
        GRANT WRITE TO "_creator",
        GRANT CREATE TO "_icloud",
        GRANT READ TO "_world"
    );

    RECORD TYPE CSVImportProfileRecord (
        "___createTime"            TIMESTAMP,
        "___createdBy"             REFERENCE,
        "___etag"                  STRING,
        "___modTime"               TIMESTAMP,
        "___modifiedBy"            REFERENCE,
        "___recordID"              REFERENCE QUERYABLE,
        accountId                  STRING QUERYABLE SEARCHABLE SORTABLE,
        columnRoleRawValuesEncoded STRING QUERYABLE SEARCHABLE SORTABLE,
        createdAt                  TIMESTAMP QUERYABLE SORTABLE,
        dateFormatRawValue         STRING QUERYABLE SEARCHABLE SORTABLE,
        deleteAfterImport          INT64 QUERYABLE SORTABLE,
        filenamePattern            STRING QUERYABLE SEARCHABLE SORTABLE,
        headerSignature            STRING QUERYABLE SEARCHABLE SORTABLE,
        lastUsedAt                 TIMESTAMP QUERYABLE SORTABLE,
        parserIdentifier           STRING QUERYABLE SEARCHABLE SORTABLE,
        GRANT WRITE TO "_creator",
        GRANT CREATE TO "_icloud",
        GRANT READ TO "_world"
    );

    RECORD TYPE EarmarkBudgetItemRecord (
        "___createTime" TIMESTAMP,
        "___createdBy"  REFERENCE,
        "___etag"       STRING,
        "___modTime"    TIMESTAMP,
        "___modifiedBy" REFERENCE,
        "___recordID"   REFERENCE QUERYABLE,
        amount          INT64 QUERYABLE SORTABLE,
        categoryId      STRING QUERYABLE SEARCHABLE SORTABLE,
        earmarkId       STRING QUERYABLE SEARCHABLE SORTABLE,
        instrumentId    STRING QUERYABLE SEARCHABLE SORTABLE,
        GRANT WRITE TO "_creator",
        GRANT CREATE TO "_icloud",
        GRANT READ TO "_world"
    );

    RECORD TYPE EarmarkRecord (
        "___createTime"           TIMESTAMP,
        "___createdBy"            REFERENCE,
        "___etag"                 STRING,
        "___modTime"              TIMESTAMP,
        "___modifiedBy"           REFERENCE,
        "___recordID"             REFERENCE QUERYABLE,
        instrumentId              STRING QUERYABLE SEARCHABLE SORTABLE,
        isHidden                  INT64 QUERYABLE SORTABLE,
        name                      STRING QUERYABLE SEARCHABLE SORTABLE,
        position                  INT64 QUERYABLE SORTABLE,
        savingsEndDate            TIMESTAMP QUERYABLE SORTABLE,
        savingsStartDate          TIMESTAMP QUERYABLE SORTABLE,
        savingsTarget             INT64 QUERYABLE SORTABLE,
        savingsTargetInstrumentId STRING QUERYABLE SEARCHABLE SORTABLE,
        GRANT WRITE TO "_creator",
        GRANT CREATE TO "_icloud",
        GRANT READ TO "_world"
    );

    RECORD TYPE ImportRuleRecord (
        "___createTime" TIMESTAMP,
        "___createdBy"  REFERENCE,
        "___etag"       STRING,
        "___modTime"    TIMESTAMP,
        "___modifiedBy" REFERENCE,
        "___recordID"   REFERENCE QUERYABLE,
        accountScope   STRING QUERYABLE SEARCHABLE SORTABLE,
        actionsJSON     BYTES,
        conditionsJSON  BYTES,
        enabled         INT64 QUERYABLE SORTABLE,
        matchMode       STRING QUERYABLE SEARCHABLE SORTABLE,
        name            STRING QUERYABLE SEARCHABLE SORTABLE,
        position        INT64 QUERYABLE SORTABLE,
        GRANT WRITE TO "_creator",
        GRANT CREATE TO "_icloud",
        GRANT READ TO "_world"
    );

    RECORD TYPE InstrumentRecord (
        "___createTime"     TIMESTAMP,
        "___createdBy"      REFERENCE,
        "___etag"           STRING,
        "___modTime"        TIMESTAMP,
        "___modifiedBy"     REFERENCE,
        "___recordID"       REFERENCE QUERYABLE,
        binanceSymbol       STRING QUERYABLE SEARCHABLE SORTABLE,
        chainId             INT64 QUERYABLE SORTABLE,
        coingeckoId         STRING QUERYABLE SEARCHABLE SORTABLE,
        contractAddress     STRING QUERYABLE SEARCHABLE SORTABLE,
        cryptocompareSymbol STRING QUERYABLE SEARCHABLE SORTABLE,
        decimals            INT64 QUERYABLE SORTABLE,
        exchange            STRING QUERYABLE SEARCHABLE SORTABLE,
        kind                STRING QUERYABLE SEARCHABLE SORTABLE,
        name                STRING QUERYABLE SEARCHABLE SORTABLE,
        ticker              STRING QUERYABLE SEARCHABLE SORTABLE,
        GRANT WRITE TO "_creator",
        GRANT CREATE TO "_icloud",
        GRANT READ TO "_world"
    );

    RECORD TYPE InvestmentValueRecord (
        "___createTime" TIMESTAMP,
        "___createdBy"  REFERENCE,
        "___etag"       STRING,
        "___modTime"    TIMESTAMP,
        "___modifiedBy" REFERENCE,
        "___recordID"   REFERENCE QUERYABLE,
        accountId       STRING QUERYABLE SEARCHABLE SORTABLE,
        date            TIMESTAMP QUERYABLE SORTABLE,
        instrumentId    STRING QUERYABLE SEARCHABLE SORTABLE,
        value           INT64 QUERYABLE SORTABLE,
        GRANT WRITE TO "_creator",
        GRANT CREATE TO "_icloud",
        GRANT READ TO "_world"
    );

    RECORD TYPE ProfileRecord (
        "___createTime"         TIMESTAMP,
        "___createdBy"          REFERENCE,
        "___etag"               STRING,
        "___modTime"            TIMESTAMP,
        "___modifiedBy"         REFERENCE,
        "___recordID"           REFERENCE QUERYABLE,
        createdAt               TIMESTAMP QUERYABLE SORTABLE,
        currencyCode            STRING QUERYABLE SEARCHABLE SORTABLE,
        financialYearStartMonth INT64 QUERYABLE SORTABLE,
        label                   STRING QUERYABLE SEARCHABLE SORTABLE,
        GRANT WRITE TO "_creator",
        GRANT CREATE TO "_icloud",
        GRANT READ TO "_world"
    );

    RECORD TYPE TransactionLegRecord (
        "___createTime" TIMESTAMP,
        "___createdBy"  REFERENCE,
        "___etag"       STRING,
        "___modTime"    TIMESTAMP,
        "___modifiedBy" REFERENCE,
        "___recordID"   REFERENCE QUERYABLE,
        accountId       STRING QUERYABLE SEARCHABLE SORTABLE,
        categoryId      STRING QUERYABLE SEARCHABLE SORTABLE,
        earmarkId       STRING QUERYABLE SEARCHABLE SORTABLE,
        instrumentId    STRING QUERYABLE SEARCHABLE SORTABLE,
        quantity        INT64 QUERYABLE SORTABLE,
        sortOrder       INT64 QUERYABLE SORTABLE,
        transactionId   STRING QUERYABLE SEARCHABLE SORTABLE,
        type            STRING QUERYABLE SEARCHABLE SORTABLE,
        GRANT WRITE TO "_creator",
        GRANT CREATE TO "_icloud",
        GRANT READ TO "_world"
    );

    RECORD TYPE TransactionRecord (
        "___createTime"               TIMESTAMP,
        "___createdBy"                REFERENCE,
        "___etag"                     STRING,
        "___modTime"                  TIMESTAMP,
        "___modifiedBy"               REFERENCE,
        "___recordID"                 REFERENCE QUERYABLE,
        date                          TIMESTAMP QUERYABLE SORTABLE,
        importOriginBankReference     STRING QUERYABLE SEARCHABLE SORTABLE,
        importOriginImportSessionId   STRING QUERYABLE SEARCHABLE SORTABLE,
        importOriginImportedAt        TIMESTAMP QUERYABLE SORTABLE,
        importOriginParserIdentifier  STRING QUERYABLE SEARCHABLE SORTABLE,
        importOriginRawAmount         STRING QUERYABLE SEARCHABLE SORTABLE,
        importOriginRawBalance        STRING QUERYABLE SEARCHABLE SORTABLE,
        importOriginRawDescription    STRING QUERYABLE SEARCHABLE SORTABLE,
        importOriginSourceFilename    STRING QUERYABLE SEARCHABLE SORTABLE,
        notes                         STRING QUERYABLE SEARCHABLE SORTABLE,
        payee                         STRING QUERYABLE SEARCHABLE SORTABLE,
        recurEvery                    INT64 QUERYABLE SORTABLE,
        recurPeriod                   STRING QUERYABLE SEARCHABLE SORTABLE,
        GRANT WRITE TO "_creator",
        GRANT CREATE TO "_icloud",
        GRANT READ TO "_world"
    );

    RECORD TYPE Users (
        "___createTime" TIMESTAMP,
        "___createdBy"  REFERENCE,
        "___etag"       STRING,
        "___modTime"    TIMESTAMP,
        "___modifiedBy" REFERENCE,
        "___recordID"   REFERENCE QUERYABLE,
        roles           LIST<INT64>,
        GRANT WRITE TO "_creator",
        GRANT READ TO "_world"
    );
```

- [ ] **Step 2: Verify field inventory matches Swift code**

For each `Backends/CloudKit/Sync/<RecordType>+CloudKit.swift`, count the `record["..."] = ...` assignments in `toCKRecord` (including any helper methods like `encodeImportOriginFields`) and confirm the same field names appear in the `RECORD TYPE` block above. The expected counts are: AccountRecord 5, CategoryRecord 2, CSVImportProfileRecord 9, EarmarkBudgetItemRecord 4, EarmarkRecord 8, ImportRuleRecord 7, InstrumentRecord 10, InvestmentValueRecord 4, ProfileRecord 4, TransactionLegRecord 8, TransactionRecord 13.

If a field is missing or extra, fix the manifest, not the Swift code.

- [ ] **Step 3: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 add CloudKit/schema.ckdb
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 commit -m "$(cat <<'EOF'
chore(cloudkit): rewrite schema.ckdb with full record-type inventory

Replaces the stale, partial manifest (4 of 11 record types declared
with CD_-prefixed names from a SwiftData migration export) with the
complete inventory derived from current Backends/CloudKit/Sync/*Record+
CloudKit.swift mappings. All 11 CloudKitRecordConvertible types now
appear with bare names (no CD_ prefix), every type declares
___recordID REFERENCE QUERYABLE so it can be looked up in the iCloud
Console, and the index policy is uniform: STRING gets QUERYABLE
SEARCHABLE SORTABLE, INT64/TIMESTAMP get QUERYABLE SORTABLE, BYTES
get no indexes.

v2 Production has never been promoted, so this manifest will become
the entire Production schema on the first promotion after merge.
EOF
)"
```

---

## Task 3: Capture the initial Production baseline

Snapshot what is currently in v2 Production (effectively empty / Users-only) into `CloudKit/schema-prod-baseline.ckdb`. Subsequent PRs run `just check-schema-additive` against this committed file.

**Files:**
- Create: `CloudKit/schema-prod-baseline.ckdb`

- [ ] **Step 1: Verify cktool credentials**

```bash
test -n "${DEVELOPMENT_TEAM:-}" || echo "DEVELOPMENT_TEAM not set — source .env or export it"
xcrun cktool save-token --type management --help >/dev/null && echo "cktool save-token available — re-run interactively if no token in keychain"
```

Expected: `DEVELOPMENT_TEAM` is set; `save-token` help prints. If the management token is not in the keychain, run `xcrun cktool save-token --type management` interactively before continuing.

- [ ] **Step 2: Export the current Production schema**

```bash
mkdir -p .agent-tmp
source scripts/cloudkit-config.sh
cloudkit_cktool export-schema --environment production --output-file CloudKit/schema-prod-baseline.ckdb
```

Expected: file written, exit 0. Inspect:

```bash
cat CloudKit/schema-prod-baseline.ckdb
```

It should be empty / minimal (no user-defined record types, possibly only the auto-created `Users` system type). v2 Production has never been promoted.

If the file contains user-defined record types, stop and investigate before continuing — that contradicts the design assumption.

- [ ] **Step 3: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 add CloudKit/schema-prod-baseline.ckdb
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 commit -m "$(cat <<'EOF'
chore(cloudkit): commit initial Production schema baseline

Captures `cktool export-schema --environment production` against v2
today, which has never been promoted. The first promote-schema after
merge replaces this with the export of the freshly-imported manifest;
subsequent PRs run check-schema-additive against this baseline.
EOF
)"
```

---

## Task 4: Scaffold the `tools/CKDBSchemaGen/` SPM package

Create the package skeleton with empty source files and stub tests. Verify `swift build` and `swift test` work end-to-end before adding content. This isolates plumbing problems from logic problems.

**Files:**
- Create: `tools/CKDBSchemaGen/Package.swift`
- Create: `tools/CKDBSchemaGen/Sources/CKDBSchemaGen/Schema.swift`
- Create: `tools/CKDBSchemaGen/Sources/CKDBSchemaGen/Parser.swift`
- Create: `tools/CKDBSchemaGen/Sources/CKDBSchemaGen/Generator.swift`
- Create: `tools/CKDBSchemaGen/Sources/CKDBSchemaGen/Additivity.swift`
- Create: `tools/CKDBSchemaGen/Sources/CKDBSchemaGen/main.swift`
- Create: `tools/CKDBSchemaGen/Tests/CKDBSchemaGenTests/ParserTests.swift`
- Create: `tools/CKDBSchemaGen/Tests/CKDBSchemaGenTests/GeneratorTests.swift`
- Create: `tools/CKDBSchemaGen/Tests/CKDBSchemaGenTests/AdditivityTests.swift`

- [ ] **Step 1: Create `tools/CKDBSchemaGen/Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "CKDBSchemaGen",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "ckdb-schema-gen", targets: ["CKDBSchemaGen"]),
  ],
  targets: [
    .executableTarget(name: "CKDBSchemaGen"),
    .testTarget(name: "CKDBSchemaGenTests", dependencies: ["CKDBSchemaGen"]),
  ]
)
```

- [ ] **Step 2: Create empty source files**

`tools/CKDBSchemaGen/Sources/CKDBSchemaGen/Schema.swift`:

```swift
import Foundation

// Filled in by Task 5.
```

`tools/CKDBSchemaGen/Sources/CKDBSchemaGen/Parser.swift`:

```swift
import Foundation

// Filled in by Task 6.
```

`tools/CKDBSchemaGen/Sources/CKDBSchemaGen/Generator.swift`:

```swift
import Foundation

// Filled in by Task 7.
```

`tools/CKDBSchemaGen/Sources/CKDBSchemaGen/Additivity.swift`:

```swift
import Foundation

// Filled in by Task 8.
```

`tools/CKDBSchemaGen/Sources/CKDBSchemaGen/main.swift`:

```swift
import Foundation

@main
enum CKDBSchemaGenCLI {
  static func main() {
    fputs("ckdb-schema-gen: not yet implemented\n", stderr)
    exit(1)
  }
}
```

`tools/CKDBSchemaGen/Tests/CKDBSchemaGenTests/ParserTests.swift`:

```swift
import Testing

@testable import CKDBSchemaGen

@Suite("Parser (skeleton)")
struct ParserSkeletonTests {
  @Test("package builds")
  func packageBuilds() {
    #expect(true)
  }
}
```

`tools/CKDBSchemaGen/Tests/CKDBSchemaGenTests/GeneratorTests.swift`:

```swift
import Testing

@testable import CKDBSchemaGen

@Suite("Generator (skeleton)")
struct GeneratorSkeletonTests {
  @Test("package builds")
  func packageBuilds() {
    #expect(true)
  }
}
```

`tools/CKDBSchemaGen/Tests/CKDBSchemaGenTests/AdditivityTests.swift`:

```swift
import Testing

@testable import CKDBSchemaGen

@Suite("Additivity (skeleton)")
struct AdditivitySkeletonTests {
  @Test("package builds")
  func packageBuilds() {
    #expect(true)
  }
}
```

- [ ] **Step 3: Build and test the skeleton**

```bash
mkdir -p .agent-tmp
swift build --package-path tools/CKDBSchemaGen 2>&1 | tee .agent-tmp/skg-build.txt
swift test --package-path tools/CKDBSchemaGen 2>&1 | tee .agent-tmp/skg-test.txt
```

Expected: both exit 0. The CLI binary exists at `tools/CKDBSchemaGen/.build/debug/ckdb-schema-gen`.

- [ ] **Step 4: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 add tools/CKDBSchemaGen
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 commit -m "feat(cloudkit): scaffold tools/CKDBSchemaGen SPM package"
```

---

## Task 5: Implement the `Schema` data model

The in-memory representation that the parser produces and the generator/additivity-checker consume. Pure value types, no I/O.

**Files:**
- Modify: `tools/CKDBSchemaGen/Sources/CKDBSchemaGen/Schema.swift`

- [ ] **Step 1: Replace `Schema.swift` contents**

```swift
import Foundation

/// In-memory representation of a parsed `.ckdb` schema. Used as the
/// intermediate form between the parser, the code generator, and the
/// additivity checker.
struct Schema: Equatable {
  var recordTypes: [RecordType]

  /// Returns the record type with the given name, or nil if absent.
  func recordType(named name: String) -> RecordType? {
    recordTypes.first { $0.name == name }
  }
}

/// A single `RECORD TYPE` block.
struct RecordType: Equatable {
  var name: String
  var fields: [Field]
  var isDeprecated: Bool

  /// Returns the field with the given name, or nil if absent.
  func field(named name: String) -> Field? {
    fields.first { $0.name == name }
  }
}

/// A single field declaration inside a `RECORD TYPE` block. Excludes
/// system fields (those whose names begin with `___`) and `GRANT` lines —
/// the parser filters those out.
struct Field: Equatable {
  var name: String
  var type: FieldType
  var indexes: Set<FieldIndex>
  var isDeprecated: Bool
}

/// CloudKit field types we currently use.
enum FieldType: String, Equatable {
  case string = "STRING"
  case int64 = "INT64"
  case double = "DOUBLE"
  case timestamp = "TIMESTAMP"
  case bytes = "BYTES"
  case reference = "REFERENCE"
  case listInt64 = "LIST<INT64>"
}

/// Index attributes that may appear after a field's type.
enum FieldIndex: String, Equatable, Hashable, CaseIterable {
  case queryable = "QUERYABLE"
  case searchable = "SEARCHABLE"
  case sortable = "SORTABLE"
}

/// Names of system types that are auto-created by CloudKit. The generator
/// skips these because there is no Swift adapter to refactor.
enum SystemRecordType {
  static let names: Set<String> = ["Users"]
}
```

- [ ] **Step 2: Build**

```bash
swift build --package-path tools/CKDBSchemaGen 2>&1 | tee .agent-tmp/skg-build.txt
```

Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 add tools/CKDBSchemaGen/Sources/CKDBSchemaGen/Schema.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 commit -m "feat(cloudkit): add Schema data model for ckdb-schema-gen"
```

---

## Task 6: Implement the `Parser`

Parses a `.ckdb` file into a `Schema`. Handles `DEFINE SCHEMA`, `RECORD TYPE Name (...)` blocks, field declarations with type and zero-or-more index attributes, system fields (filtered out), `GRANT` lines (filtered out), `// DEPRECATED` markers on the line directly above a field or record-type declaration, and `LIST<INT64>` (currently only used by `Users.roles`). Test-driven.

**Files:**
- Modify: `tools/CKDBSchemaGen/Sources/CKDBSchemaGen/Parser.swift`
- Modify: `tools/CKDBSchemaGen/Tests/CKDBSchemaGenTests/ParserTests.swift`

- [ ] **Step 1: Replace `ParserTests.swift` with the failing test suite**

```swift
import Testing

@testable import CKDBSchemaGen

@Suite("Parser")
struct ParserTests {

  @Test("parses a single record type with one field")
  func singleRecordOneField() throws {
    let source = """
      DEFINE SCHEMA

          RECORD TYPE AccountRecord (
              "___createTime" TIMESTAMP,
              "___recordID"   REFERENCE QUERYABLE,
              name            STRING QUERYABLE SEARCHABLE SORTABLE,
              GRANT WRITE TO "_creator"
          );
      """
    let schema = try Parser.parse(source)
    #expect(schema.recordTypes.count == 1)
    let account = try #require(schema.recordType(named: "AccountRecord"))
    #expect(account.fields.count == 1)
    let name = try #require(account.field(named: "name"))
    #expect(name.type == .string)
    #expect(name.indexes == [.queryable, .searchable, .sortable])
    #expect(name.isDeprecated == false)
  }

  @Test("parses every supported field type")
  func allFieldTypes() throws {
    let source = """
      DEFINE SCHEMA
          RECORD TYPE T (
              "___recordID" REFERENCE QUERYABLE,
              s             STRING QUERYABLE SEARCHABLE SORTABLE,
              i             INT64 QUERYABLE SORTABLE,
              d             DOUBLE QUERYABLE SORTABLE,
              t             TIMESTAMP QUERYABLE SORTABLE,
              b             BYTES,
              roles         LIST<INT64>
          );
      """
    let schema = try Parser.parse(source)
    let t = try #require(schema.recordType(named: "T"))
    #expect(t.field(named: "s")?.type == .string)
    #expect(t.field(named: "i")?.type == .int64)
    #expect(t.field(named: "d")?.type == .double)
    #expect(t.field(named: "t")?.type == .timestamp)
    #expect(t.field(named: "b")?.type == .bytes)
    #expect(t.field(named: "roles")?.type == .listInt64)
    #expect(t.field(named: "b")?.indexes.isEmpty == true)
  }

  @Test("filters system fields and GRANT lines")
  func filtersSystemAndGrants() throws {
    let source = """
      DEFINE SCHEMA
          RECORD TYPE T (
              "___createTime" TIMESTAMP,
              "___createdBy"  REFERENCE,
              "___etag"       STRING,
              "___modTime"    TIMESTAMP,
              "___modifiedBy" REFERENCE,
              "___recordID"   REFERENCE QUERYABLE,
              foo             STRING QUERYABLE SEARCHABLE SORTABLE,
              GRANT WRITE TO "_creator",
              GRANT CREATE TO "_icloud",
              GRANT READ TO "_world"
          );
      """
    let schema = try Parser.parse(source)
    let t = try #require(schema.recordType(named: "T"))
    #expect(t.fields.map(\.name) == ["foo"])
  }

  @Test("flags fields preceded by // DEPRECATED")
  func deprecatedField() throws {
    let source = """
      DEFINE SCHEMA
          RECORD TYPE T (
              "___recordID" REFERENCE QUERYABLE,
              foo           STRING QUERYABLE SEARCHABLE SORTABLE,
              // DEPRECATED: replaced by foo
              bar           STRING QUERYABLE SEARCHABLE SORTABLE
          );
      """
    let schema = try Parser.parse(source)
    let t = try #require(schema.recordType(named: "T"))
    #expect(t.field(named: "foo")?.isDeprecated == false)
    #expect(t.field(named: "bar")?.isDeprecated == true)
  }

  @Test("flags record types preceded by // DEPRECATED")
  func deprecatedRecordType() throws {
    let source = """
      DEFINE SCHEMA
          // DEPRECATED: replaced by NewRecord
          RECORD TYPE Old (
              "___recordID" REFERENCE QUERYABLE,
              foo           STRING QUERYABLE SEARCHABLE SORTABLE
          );
          RECORD TYPE NewRecord (
              "___recordID" REFERENCE QUERYABLE,
              foo           STRING QUERYABLE SEARCHABLE SORTABLE
          );
      """
    let schema = try Parser.parse(source)
    #expect(schema.recordType(named: "Old")?.isDeprecated == true)
    #expect(schema.recordType(named: "NewRecord")?.isDeprecated == false)
  }

  @Test("ignores ordinary // comments that are not DEPRECATED")
  func ignoresPlainComments() throws {
    let source = """
      DEFINE SCHEMA
          // a normal comment
          RECORD TYPE T (
              "___recordID" REFERENCE QUERYABLE,
              // a field comment
              foo           STRING QUERYABLE SEARCHABLE SORTABLE
          );
      """
    let schema = try Parser.parse(source)
    let t = try #require(schema.recordType(named: "T"))
    #expect(t.isDeprecated == false)
    #expect(t.field(named: "foo")?.isDeprecated == false)
  }

  @Test("rejects unknown field types")
  func rejectsUnknownType() {
    let source = """
      DEFINE SCHEMA
          RECORD TYPE T (
              "___recordID" REFERENCE QUERYABLE,
              foo           UNICORN QUERYABLE
          );
      """
    #expect(throws: Parser.Error.self) {
      try Parser.parse(source)
    }
  }

  @Test("rejects malformed input")
  func rejectsMalformed() {
    #expect(throws: Parser.Error.self) {
      try Parser.parse("garbage")
    }
  }
}
```

- [ ] **Step 2: Run tests; expect failures**

```bash
swift test --package-path tools/CKDBSchemaGen 2>&1 | tee .agent-tmp/skg-test.txt
grep -i 'failed\|error:' .agent-tmp/skg-test.txt | head -20
```

Expected: build fails with "Cannot find 'Parser' in scope" or similar.

- [ ] **Step 3: Replace `Parser.swift` with the implementation**

```swift
import Foundation

/// Parses a `.ckdb` file into a `Schema`. Handles only the subset of the
/// CloudKit schema language used by this project: `DEFINE SCHEMA`,
/// `RECORD TYPE Name (...)` blocks with fields, `GRANT` lines (ignored),
/// system fields starting with `___` (ignored except `___recordID`'s
/// indexes, which the parser drops because they are part of the standard
/// system-field block), `// DEPRECATED` markers on the line immediately
/// above a field or record-type declaration, and `LIST<INT64>`.
enum Parser {

  enum Error: Swift.Error, CustomStringConvertible {
    case malformed(String)
    case unknownFieldType(String, line: Int)

    var description: String {
      switch self {
      case .malformed(let message):
        return "malformed schema: \(message)"
      case .unknownFieldType(let raw, let line):
        return "unknown field type '\(raw)' at line \(line)"
      }
    }
  }

  /// Parses `.ckdb` source into a `Schema`. Throws `Error` on syntactic
  /// problems or unknown constructs.
  static func parse(_ source: String) throws -> Schema {
    let blockPattern = /RECORD\s+TYPE\s+(\w+)\s*\(([\s\S]*?)\)\s*;/.dotMatchesNewlines()
    var recordTypes: [RecordType] = []
    var any = false
    for match in source.matches(of: blockPattern) {
      any = true
      let name = String(match.output.1)
      let body = String(match.output.2)
      let typeIsDeprecated = isPrecededByDeprecated(
        index: match.range.lowerBound, in: source)
      let fields = try parseFields(body: body, source: source)
      recordTypes.append(RecordType(name: name, fields: fields, isDeprecated: typeIsDeprecated))
    }
    guard any else {
      throw Error.malformed("no RECORD TYPE blocks found")
    }
    return Schema(recordTypes: recordTypes)
  }

  // MARK: - Internals

  private static func parseFields(body: String, source: String) throws -> [Field] {
    var fields: [Field] = []
    var pendingDeprecated = false
    for rawLine in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty { continue }
      if line.hasPrefix("//") {
        if line.contains("DEPRECATED") { pendingDeprecated = true }
        continue
      }
      if line.hasPrefix("GRANT") { continue }
      if line.hasPrefix("\"___") { continue }
      let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: ","))
      guard let field = try parseFieldLine(trimmed, isDeprecated: pendingDeprecated) else {
        pendingDeprecated = false
        continue
      }
      fields.append(field)
      pendingDeprecated = false
    }
    return fields
  }

  /// A field line looks like `name TYPE [INDEX [INDEX ...]]`. `LIST<INT64>`
  /// counts as a single token even though it contains angle brackets.
  private static func parseFieldLine(_ line: String, isDeprecated: Bool) throws -> Field? {
    var tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard tokens.count >= 2 else { return nil }
    let name = tokens.removeFirst()
    let rawType = tokens.removeFirst()
    let normalisedType = rawType.uppercased()
    guard let type = FieldType(rawValue: normalisedType) else {
      throw Error.unknownFieldType(rawType, line: 0)
    }
    var indexes: Set<FieldIndex> = []
    for token in tokens {
      let upper = token.uppercased()
      if let index = FieldIndex(rawValue: upper) {
        indexes.insert(index)
      } else {
        throw Error.malformed("unknown index attribute '\(token)' on field '\(name)'")
      }
    }
    return Field(name: name, type: type, indexes: indexes, isDeprecated: isDeprecated)
  }

  /// Returns true if the source has a `// DEPRECATED` line immediately
  /// before the given index (skipping blank lines).
  private static func isPrecededByDeprecated(
    index: String.Index, in source: String
  ) -> Bool {
    let prefix = source[..<index]
    let lines = prefix.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    var i = lines.count - 1
    while i >= 0 {
      let line = lines[i].trimmingCharacters(in: .whitespaces)
      if line.isEmpty { i -= 1; continue }
      return line.hasPrefix("//") && line.contains("DEPRECATED")
    }
    return false
  }
}
```

- [ ] **Step 4: Run tests; expect green**

```bash
swift test --package-path tools/CKDBSchemaGen 2>&1 | tee .agent-tmp/skg-test.txt
grep -iE 'failed|error:' .agent-tmp/skg-test.txt | head -20
```

Expected: all parser tests pass. Skeleton tests for Generator/Additivity still pass (they're trivial). Zero failures.

If anything fails, fix the parser implementation, not the tests. The tests describe the contract; if a test is genuinely wrong, raise that as a question rather than weakening it.

- [ ] **Step 5: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 add tools/CKDBSchemaGen
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 commit -m "feat(cloudkit): implement ckdb-schema-gen Parser"
```

---

## Task 7: Implement the `Generator`

Walks the `Schema` and emits one Swift wire struct per non-system, non-deprecated record type. Handles each field type's mapping to `String?` / `Int64?` / `Double?` / `Date?` / `Data?`. Skips deprecated fields (they remain in `.ckdb` for additive-only Production but should not appear in Swift). Skips deprecated record types entirely. Test-driven.

**Files:**
- Modify: `tools/CKDBSchemaGen/Sources/CKDBSchemaGen/Generator.swift`
- Modify: `tools/CKDBSchemaGen/Tests/CKDBSchemaGenTests/GeneratorTests.swift`

- [ ] **Step 1: Replace `GeneratorTests.swift` with the failing test suite**

```swift
import Testing

@testable import CKDBSchemaGen

@Suite("Generator")
struct GeneratorTests {

  private func makeSchema() -> Schema {
    Schema(recordTypes: [
      RecordType(
        name: "AccountRecord",
        fields: [
          Field(name: "name", type: .string, indexes: [.queryable, .searchable, .sortable], isDeprecated: false),
          Field(name: "position", type: .int64, indexes: [.queryable, .sortable], isDeprecated: false),
          Field(name: "isHidden", type: .int64, indexes: [.queryable, .sortable], isDeprecated: false),
          Field(name: "ratio", type: .double, indexes: [.queryable, .sortable], isDeprecated: false),
          Field(name: "lastUsedAt", type: .timestamp, indexes: [.queryable, .sortable], isDeprecated: false),
          Field(name: "blob", type: .bytes, indexes: [], isDeprecated: false),
        ],
        isDeprecated: false
      ),
      RecordType(
        name: "Users",
        fields: [
          Field(name: "roles", type: .listInt64, indexes: [], isDeprecated: false),
        ],
        isDeprecated: false
      ),
      RecordType(
        name: "OldRecord",
        fields: [
          Field(name: "x", type: .string, indexes: [.queryable], isDeprecated: false),
        ],
        isDeprecated: true
      ),
    ])
  }

  @Test("emits one file per non-system, non-deprecated record type")
  func emitsOneFilePerType() {
    let files = Generator.generate(makeSchema())
    let fileNames = files.map(\.path).sorted()
    #expect(fileNames == ["AccountRecordCloudKitFields.swift"])
  }

  @Test("file header marks the file as auto-generated")
  func fileHeader() {
    let file = Generator.generate(makeSchema()).first { $0.path == "AccountRecordCloudKitFields.swift" }!
    #expect(file.contents.contains("// THIS FILE IS GENERATED. Do not edit by hand."))
    #expect(file.contents.contains("// Source: CloudKit/schema.ckdb. Regenerate with: just generate."))
    #expect(file.contents.contains("import CloudKit"))
    #expect(file.contents.contains("import Foundation"))
  }

  @Test("declares one optional property per non-deprecated field, with the right type")
  func properties() {
    let contents = Generator.generate(makeSchema()).first { $0.path == "AccountRecordCloudKitFields.swift" }!.contents
    #expect(contents.contains("var name: String?"))
    #expect(contents.contains("var position: Int64?"))
    #expect(contents.contains("var isHidden: Int64?"))
    #expect(contents.contains("var ratio: Double?"))
    #expect(contents.contains("var lastUsedAt: Date?"))
    #expect(contents.contains("var blob: Data?"))
  }

  @Test("emits allFieldNames in declaration order")
  func allFieldNames() {
    let contents = Generator.generate(makeSchema()).first { $0.path == "AccountRecordCloudKitFields.swift" }!.contents
    #expect(contents.contains(#"static let allFieldNames: [String] = ["name", "position", "isHidden", "ratio", "lastUsedAt", "blob"]"#))
  }

  @Test("init(from: CKRecord) reads each field by name")
  func initFromRecord() {
    let contents = Generator.generate(makeSchema()).first { $0.path == "AccountRecordCloudKitFields.swift" }!.contents
    #expect(contents.contains(#"self.name = record["name"] as? String"#))
    #expect(contents.contains(#"self.position = record["position"] as? Int64"#))
    #expect(contents.contains(#"self.lastUsedAt = record["lastUsedAt"] as? Date"#))
    #expect(contents.contains(#"self.blob = record["blob"] as? Data"#))
  }

  @Test("write(to:) writes only non-nil fields as CKRecordValue")
  func writeToRecord() {
    let contents = Generator.generate(makeSchema()).first { $0.path == "AccountRecordCloudKitFields.swift" }!.contents
    #expect(contents.contains(#"if let name { record["name"] = name as CKRecordValue }"#))
    #expect(contents.contains(#"if let blob { record["blob"] = blob as CKRecordValue }"#))
  }

  @Test("skips deprecated fields entirely")
  func skipsDeprecatedFields() {
    let schema = Schema(recordTypes: [
      RecordType(
        name: "T",
        fields: [
          Field(name: "live", type: .string, indexes: [.queryable], isDeprecated: false),
          Field(name: "old", type: .string, indexes: [.queryable], isDeprecated: true),
        ],
        isDeprecated: false
      )
    ])
    let contents = Generator.generate(schema).first { $0.path == "TCloudKitFields.swift" }!.contents
    #expect(contents.contains("var live: String?"))
    #expect(contents.contains("var old: String?") == false)
    #expect(contents.contains(#""old""#) == false)
  }
}
```

- [ ] **Step 2: Run tests; expect failures**

```bash
swift test --package-path tools/CKDBSchemaGen 2>&1 | tee .agent-tmp/skg-test.txt
grep -iE 'failed|error:' .agent-tmp/skg-test.txt | head -20
```

Expected: tests fail because `Generator` is empty.

- [ ] **Step 3: Replace `Generator.swift` with the implementation**

```swift
import Foundation

/// Emits Swift source for the generated wire layer from a parsed `Schema`.
enum Generator {

  /// One generated Swift file: relative path under the output directory and
  /// its contents. The CLI is responsible for writing these to disk.
  struct File: Equatable {
    let path: String
    let contents: String
  }

  /// Produces one wire-struct file per non-system, non-deprecated record
  /// type. Deprecated *fields* on a non-deprecated record type are skipped
  /// entirely — their declarations remain in `.ckdb` for additive-only
  /// Production but the Swift wire layer pretends they do not exist.
  static func generate(_ schema: Schema) -> [File] {
    schema.recordTypes
      .filter { !SystemRecordType.names.contains($0.name) }
      .filter { !$0.isDeprecated }
      .map { type in
        File(
          path: "\(type.name)CloudKitFields.swift",
          contents: render(type)
        )
      }
  }

  // MARK: - Internals

  private static func render(_ type: RecordType) -> String {
    let liveFields = type.fields.filter { !$0.isDeprecated }
    let lines: [String] = [
      "// THIS FILE IS GENERATED. Do not edit by hand.",
      "// Source: CloudKit/schema.ckdb. Regenerate with: just generate.",
      "",
      "import CloudKit",
      "import Foundation",
      "",
      "struct \(type.name)CloudKitFields {",
      properties(of: liveFields),
      "",
      allFieldNamesDecl(liveFields),
      "",
      memberwiseInit(liveFields),
      "",
      ckRecordInit(liveFields),
      "",
      writeMethod(liveFields),
      "}",
      "",
    ]
    return lines.joined(separator: "\n")
  }

  private static func properties(of fields: [Field]) -> String {
    fields.map { "  var \($0.name): \(swiftType(of: $0.type))?" }.joined(separator: "\n")
  }

  private static func allFieldNamesDecl(_ fields: [Field]) -> String {
    let names = fields.map { "\"\($0.name)\"" }.joined(separator: ", ")
    return "  static let allFieldNames: [String] = [\(names)]"
  }

  private static func memberwiseInit(_ fields: [Field]) -> String {
    let params = fields.map { "    \($0.name): \(swiftType(of: $0.type))? = nil" }
      .joined(separator: ",\n")
    let assigns = fields.map { "    self.\($0.name) = \($0.name)" }.joined(separator: "\n")
    return """
        init(
      \(params)
        ) {
      \(assigns)
        }
      """
  }

  private static func ckRecordInit(_ fields: [Field]) -> String {
    let lines = fields.map {
      "    self.\($0.name) = record[\"\($0.name)\"] as? \(swiftType(of: $0.type))"
    }.joined(separator: "\n")
    return """
        init(from record: CKRecord) {
      \(lines)
        }
      """
  }

  private static func writeMethod(_ fields: [Field]) -> String {
    let lines = fields.map {
      "    if let \($0.name) { record[\"\($0.name)\"] = \($0.name) as CKRecordValue }"
    }.joined(separator: "\n")
    return """
        func write(to record: CKRecord) {
      \(lines)
        }
      """
  }

  private static func swiftType(of fieldType: FieldType) -> String {
    switch fieldType {
    case .string: return "String"
    case .int64: return "Int64"
    case .double: return "Double"
    case .timestamp: return "Date"
    case .bytes: return "Data"
    case .reference: return "CKRecord.Reference"  // not currently used by user fields
    case .listInt64: return "[Int64]"
    }
  }
}
```

- [ ] **Step 4: Run tests; expect green**

```bash
swift test --package-path tools/CKDBSchemaGen 2>&1 | tee .agent-tmp/skg-test.txt
grep -iE 'failed|error:' .agent-tmp/skg-test.txt | head -20
```

Expected: all generator tests pass. Parser tests still pass.

- [ ] **Step 5: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 add tools/CKDBSchemaGen
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 commit -m "feat(cloudkit): implement ckdb-schema-gen Generator"
```

---

## Task 8: Implement the `Additivity` checker

Compares a proposed `Schema` against a baseline `Schema`. Returns a list of violations or empty if additive. Test-driven.

**Files:**
- Modify: `tools/CKDBSchemaGen/Sources/CKDBSchemaGen/Additivity.swift`
- Modify: `tools/CKDBSchemaGen/Tests/CKDBSchemaGenTests/AdditivityTests.swift`

- [ ] **Step 1: Replace `AdditivityTests.swift` with the failing test suite**

```swift
import Testing

@testable import CKDBSchemaGen

@Suite("Additivity")
struct AdditivityTests {

  private let baseline = Schema(recordTypes: [
    RecordType(
      name: "AccountRecord",
      fields: [
        Field(name: "name", type: .string, indexes: [.queryable, .searchable, .sortable], isDeprecated: false),
        Field(name: "position", type: .int64, indexes: [.queryable, .sortable], isDeprecated: false),
      ],
      isDeprecated: false
    ),
    RecordType(
      name: "ProfileRecord",
      fields: [
        Field(name: "label", type: .string, indexes: [.queryable, .searchable, .sortable], isDeprecated: false),
      ],
      isDeprecated: false
    ),
  ])

  @Test("identical schemas are additive")
  func identicalIsAdditive() {
    let result = Additivity.check(proposed: baseline, baseline: baseline)
    #expect(result.violations.isEmpty)
  }

  @Test("adding a field is additive")
  func addingFieldIsAdditive() {
    var proposed = baseline
    proposed.recordTypes[0].fields.append(
      Field(name: "isHidden", type: .int64, indexes: [.queryable, .sortable], isDeprecated: false))
    let result = Additivity.check(proposed: proposed, baseline: baseline)
    #expect(result.violations.isEmpty)
  }

  @Test("adding a record type is additive")
  func addingRecordTypeIsAdditive() {
    var proposed = baseline
    proposed.recordTypes.append(
      RecordType(
        name: "NewRecord",
        fields: [Field(name: "x", type: .string, indexes: [.queryable], isDeprecated: false)],
        isDeprecated: false))
    let result = Additivity.check(proposed: proposed, baseline: baseline)
    #expect(result.violations.isEmpty)
  }

  @Test("removing a field is a violation")
  func removingFieldFails() {
    var proposed = baseline
    proposed.recordTypes[0].fields.removeLast()  // drop position
    let result = Additivity.check(proposed: proposed, baseline: baseline)
    #expect(result.violations.contains { $0.contains("position") && $0.contains("AccountRecord") })
  }

  @Test("marking a field deprecated is additive")
  func deprecatingFieldIsAdditive() {
    var proposed = baseline
    proposed.recordTypes[0].fields[1].isDeprecated = true
    let result = Additivity.check(proposed: proposed, baseline: baseline)
    #expect(result.violations.isEmpty)
  }

  @Test("removing a record type is a violation")
  func removingRecordTypeFails() {
    var proposed = baseline
    proposed.recordTypes.removeLast()  // drop ProfileRecord
    let result = Additivity.check(proposed: proposed, baseline: baseline)
    #expect(result.violations.contains { $0.contains("ProfileRecord") })
  }

  @Test("changing a field's type is a violation")
  func changingTypeFails() {
    var proposed = baseline
    proposed.recordTypes[0].fields[0].type = .int64
    let result = Additivity.check(proposed: proposed, baseline: baseline)
    #expect(result.violations.contains { $0.contains("name") && $0.contains("STRING") && $0.contains("INT64") })
  }

  @Test("removing an index from a field is a violation")
  func removingIndexFails() {
    var proposed = baseline
    proposed.recordTypes[0].fields[0].indexes.remove(.searchable)
    let result = Additivity.check(proposed: proposed, baseline: baseline)
    #expect(result.violations.contains { $0.contains("name") && $0.contains("SEARCHABLE") })
  }

  @Test("adding an index is additive")
  func addingIndexIsAdditive() {
    var proposed = baseline
    proposed.recordTypes[1].fields[0].indexes.insert(.sortable)
    let result = Additivity.check(proposed: proposed, baseline: baseline)
    #expect(result.violations.isEmpty)
  }
}
```

- [ ] **Step 2: Run tests; expect failures**

```bash
swift test --package-path tools/CKDBSchemaGen 2>&1 | tee .agent-tmp/skg-test.txt
grep -iE 'failed|error:' .agent-tmp/skg-test.txt | head -20
```

Expected: tests fail because `Additivity` is empty.

- [ ] **Step 3: Replace `Additivity.swift` with the implementation**

```swift
import Foundation

/// Checks whether a proposed `Schema` is additive over a baseline `Schema`.
/// Additive means: no record types removed, no fields removed, no field type
/// changes, no indexes removed. Adding types, fields, indexes, or marking
/// existing fields `// DEPRECATED` (which is not removal — the field stays in
/// the manifest) are all permitted.
enum Additivity {

  struct Result: Equatable {
    var violations: [String]
  }

  static func check(proposed: Schema, baseline: Schema) -> Result {
    var violations: [String] = []
    for baselineType in baseline.recordTypes {
      guard let proposedType = proposed.recordType(named: baselineType.name) else {
        violations.append("record type '\(baselineType.name)' is in baseline but missing from proposed")
        continue
      }
      for baselineField in baselineType.fields {
        guard let proposedField = proposedType.field(named: baselineField.name) else {
          violations.append(
            "field '\(baselineField.name)' on '\(baselineType.name)' is in baseline but missing from proposed")
          continue
        }
        if proposedField.type != baselineField.type {
          violations.append(
            "field '\(baselineField.name)' on '\(baselineType.name)' changed type "
              + "(\(baselineField.type.rawValue) -> \(proposedField.type.rawValue))")
        }
        for index in baselineField.indexes where !proposedField.indexes.contains(index) {
          violations.append(
            "field '\(baselineField.name)' on '\(baselineType.name)' lost index "
              + "\(index.rawValue) (was \(baselineField.indexes.map(\.rawValue).sorted().joined(separator: ", ")))")
        }
      }
    }
    return Result(violations: violations)
  }
}
```

- [ ] **Step 4: Run tests; expect green**

```bash
swift test --package-path tools/CKDBSchemaGen 2>&1 | tee .agent-tmp/skg-test.txt
grep -iE 'failed|error:' .agent-tmp/skg-test.txt | head -20
```

Expected: all additivity tests pass. Parser and Generator tests still pass.

- [ ] **Step 5: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 add tools/CKDBSchemaGen
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 commit -m "feat(cloudkit): implement ckdb-schema-gen Additivity check"
```

---

## Task 9: Wire the CLI in `main.swift`

Two subcommands: `generate --input <file> --output <dir>` and `check-additive --proposed <file> --baseline <file>`. No third-party arg-parsing dependency — the surface is small enough to handle by hand.

**Files:**
- Modify: `tools/CKDBSchemaGen/Sources/CKDBSchemaGen/main.swift`

- [ ] **Step 1: Replace `main.swift` with the CLI dispatcher**

```swift
import Foundation

@main
enum CKDBSchemaGenCLI {

  static func main() {
    let args = Array(CommandLine.arguments.dropFirst())
    do {
      switch args.first {
      case "generate":
        try runGenerate(args: Array(args.dropFirst()))
      case "check-additive":
        try runCheckAdditive(args: Array(args.dropFirst()))
      default:
        printUsage()
        exit(2)
      }
    } catch {
      fputs("ckdb-schema-gen: \(error)\n", stderr)
      exit(1)
    }
  }

  // MARK: - generate

  private static func runGenerate(args: [String]) throws {
    let opts = parseOptions(args, allowed: ["--input", "--output"])
    guard let input = opts["--input"], let output = opts["--output"] else {
      fputs("ckdb-schema-gen generate: --input <ckdb> --output <dir> required\n", stderr)
      exit(2)
    }
    let source = try String(contentsOfFile: input, encoding: .utf8)
    let schema = try Parser.parse(source)
    let files = Generator.generate(schema)
    try createDirectory(at: output)
    let existing = try existingGeneratedFiles(in: output)
    let written = try writeFiles(files, to: output)
    let stale = existing.subtracting(written)
    for path in stale {
      try FileManager.default.removeItem(atPath: path)
    }
    print("ckdb-schema-gen: wrote \(files.count) wire struct(s) to \(output)")
  }

  private static func createDirectory(at path: String) throws {
    try FileManager.default.createDirectory(
      atPath: path, withIntermediateDirectories: true)
  }

  private static func existingGeneratedFiles(in directory: String) throws -> Set<String> {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
    return Set(
      entries
        .filter { $0.hasSuffix("CloudKitFields.swift") }
        .map { (directory as NSString).appendingPathComponent($0) }
    )
  }

  private static func writeFiles(_ files: [Generator.File], to directory: String) throws
    -> Set<String>
  {
    var written: Set<String> = []
    for file in files {
      let path = (directory as NSString).appendingPathComponent(file.path)
      try file.contents.write(toFile: path, atomically: true, encoding: .utf8)
      written.insert(path)
    }
    return written
  }

  // MARK: - check-additive

  private static func runCheckAdditive(args: [String]) throws {
    let opts = parseOptions(args, allowed: ["--proposed", "--baseline"])
    guard let proposed = opts["--proposed"], let baseline = opts["--baseline"] else {
      fputs("ckdb-schema-gen check-additive: --proposed <ckdb> --baseline <ckdb> required\n", stderr)
      exit(2)
    }
    let proposedSource = try String(contentsOfFile: proposed, encoding: .utf8)
    let baselineSource = try String(contentsOfFile: baseline, encoding: .utf8)
    let proposedSchema = try Parser.parse(proposedSource)
    let baselineSchema = try Parser.parse(baselineSource).addingSystemTypesIfMissing()
    let result = Additivity.check(proposed: proposedSchema, baseline: baselineSchema)
    if result.violations.isEmpty {
      print("ckdb-schema-gen: \(proposed) is additive over \(baseline)")
      return
    }
    fputs("ckdb-schema-gen: schema is not additive over baseline:\n", stderr)
    for violation in result.violations {
      fputs("  - \(violation)\n", stderr)
    }
    exit(1)
  }

  // MARK: - shared

  private static func parseOptions(_ args: [String], allowed: Set<String>) -> [String: String] {
    var i = 0
    var out: [String: String] = [:]
    while i < args.count {
      let key = args[i]
      guard allowed.contains(key), i + 1 < args.count else { i += 1; continue }
      out[key] = args[i + 1]
      i += 2
    }
    return out
  }

  private static func printUsage() {
    fputs(
      """
      Usage:
        ckdb-schema-gen generate --input <schema.ckdb> --output <dir>
        ckdb-schema-gen check-additive --proposed <schema.ckdb> --baseline <baseline.ckdb>
      """,
      stderr)
    fputs("\n", stderr)
  }
}

extension Schema {
  /// An empty baseline (e.g. the very first run before Production has been
  /// promoted) may contain only `DEFINE SCHEMA`. The Parser rejects that
  /// outright, so the baseline file is always at least a `Users` block. This
  /// hook is reserved for any future normalisation needed when comparing
  /// against an absent baseline; today it's the identity function.
  func addingSystemTypesIfMissing() -> Schema {
    self
  }
}
```

- [ ] **Step 2: Build and smoke-test**

```bash
swift build --package-path tools/CKDBSchemaGen 2>&1 | tee .agent-tmp/skg-build.txt
swift run --package-path tools/CKDBSchemaGen ckdb-schema-gen generate \
    --input CloudKit/schema.ckdb \
    --output Backends/CloudKit/Sync/Generated 2>&1 | tee .agent-tmp/skg-gen.txt
ls Backends/CloudKit/Sync/Generated/
```

Expected: build succeeds, generator runs without error, `Backends/CloudKit/Sync/Generated/` contains 11 files (one per non-system, non-deprecated record type).

```bash
swift run --package-path tools/CKDBSchemaGen ckdb-schema-gen check-additive \
    --proposed CloudKit/schema.ckdb \
    --baseline CloudKit/schema-prod-baseline.ckdb 2>&1 | tee .agent-tmp/skg-check.txt
echo "exit=$?"
```

Expected: prints "is additive over" and exits 0 (the baseline is empty / Users-only, so anything is additive).

- [ ] **Step 3: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 add tools/CKDBSchemaGen
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 commit -m "feat(cloudkit): wire CLI for ckdb-schema-gen"
```

---

## Task 10: Hook the generator into `just generate`

`just generate` must run `ckdb-schema-gen generate` *before* `xcodegen`, so the generated wire structs exist by the time Xcode builds the project. Also add `just check-schema-additive`.

**Files:**
- Modify: `Justfile`

- [ ] **Step 1: Locate the existing `generate` target**

`Justfile` line ~146 currently has:

```
# Regenerate Moolah.xcodeproj from project.yml (run after editing project.yml)
generate:
    ...
```

- [ ] **Step 2: Edit `Justfile` so `generate` invokes the CKDB generator first**

Replace the `generate` recipe with:

```
# Regenerate the CloudKit wire-struct layer from CloudKit/schema.ckdb,
# then regenerate Moolah.xcodeproj from project.yml.
generate:
    #!/usr/bin/env bash
    set -euo pipefail
    swift run --package-path tools/CKDBSchemaGen ckdb-schema-gen generate \
        --input CloudKit/schema.ckdb \
        --output Backends/CloudKit/Sync/Generated
    SPEC="${MOOLAH_PROJECT_SPEC:-project.yml}"
    if [ "$SPEC" != "project.yml" ]; then
        xcodegen generate --spec "$SPEC"
    else
        xcodegen generate
    fi
```

(If the existing recipe has a different shape — e.g. uses `ENABLE_ENTITLEMENTS` — preserve that logic; only insert the `swift run` invocation as the first command in the recipe.)

- [ ] **Step 3: Add the `check-schema-additive` target**

Add the following recipe below the `generate` recipe:

```
# Verify CloudKit/schema.ckdb is additive over the committed Production
# baseline. Pure-text check: no CloudKit calls. Run in CI on every PR.
check-schema-additive:
    swift run --package-path tools/CKDBSchemaGen ckdb-schema-gen check-additive \
        --proposed CloudKit/schema.ckdb \
        --baseline CloudKit/schema-prod-baseline.ckdb
```

- [ ] **Step 4: Verify both targets**

```bash
just generate 2>&1 | tee .agent-tmp/just-gen.txt
ls Backends/CloudKit/Sync/Generated/ | wc -l
just check-schema-additive 2>&1 | tee .agent-tmp/just-check.txt
echo "exit=$?"
```

Expected: `just generate` succeeds; `Backends/CloudKit/Sync/Generated/` has 11 entries (one per non-system, non-deprecated record type); `just check-schema-additive` prints "is additive over" and exits 0.

- [ ] **Step 5: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 add Justfile
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 commit -m "build(cloudkit): wire ckdb-schema-gen into just generate + add check-schema-additive"
```

---

## Task 11: Add `RoundTripTests.swift` and refactor `AccountRecord+CloudKit.swift`

This is the proof-of-concept refactor. AccountRecord is the simplest: 5 user fields, all required, UUID-keyed. Establishes the round-trip-test harness and the adapter pattern that Tasks 12–17 replicate.

**Files:**
- Create: `MoolahTests/Backends/CloudKit/RoundTripTests.swift`
- Modify: `Backends/CloudKit/Sync/AccountRecord+CloudKit.swift`

- [ ] **Step 1: Add the round-trip test for AccountRecord (RED)**

Create `MoolahTests/Backends/CloudKit/RoundTripTests.swift` with:

```swift
import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("CloudKit record round trip")
struct RoundTripTests {

  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  @Test("AccountRecord round-trips through toCKRecord + fieldValues")
  func accountRoundTrip() throws {
    let original = AccountRecord(
      id: UUID(),
      name: "Sample",
      type: "bank",
      instrumentId: "AUD",
      position: 7,
      isHidden: true
    )
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(AccountRecord.fieldValues(from: record))
    #expect(decoded.id == original.id)
    #expect(decoded.name == original.name)
    #expect(decoded.type == original.type)
    #expect(decoded.instrumentId == original.instrumentId)
    #expect(decoded.position == original.position)
    #expect(decoded.isHidden == original.isHidden)
  }
}
```

- [ ] **Step 2: Run the test to confirm it currently passes against the existing adapter**

```bash
mkdir -p .agent-tmp
just test-mac RoundTripTests 2>&1 | tee .agent-tmp/round-trip.txt
grep -iE 'failed|error:' .agent-tmp/round-trip.txt | head -5
```

Expected: passes. The current hand-written adapter already round-trips correctly; this test is here to prove it still does after we refactor.

- [ ] **Step 3: Refactor `AccountRecord+CloudKit.swift` to use the wire struct**

Replace the file contents with:

```swift
import CloudKit
import Foundation

// MARK: - AccountRecord + CloudKitRecordConvertible

extension AccountRecord: CloudKitRecordConvertible {
  static let recordType = "AccountRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    AccountRecordCloudKitFields(
      name: name,
      type: type,
      instrumentId: instrumentId,
      position: Int64(position),
      isHidden: isHidden ? 1 : 0
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> AccountRecord? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = AccountRecordCloudKitFields(from: ckRecord)
    return AccountRecord(
      id: id,
      name: fields.name ?? "",
      type: fields.type ?? "bank",
      instrumentId: fields.instrumentId ?? "AUD",
      position: Int(fields.position ?? 0),
      isHidden: (fields.isHidden ?? 0) != 0
    )
  }
}
```

- [ ] **Step 4: Run the test again; expect pass**

```bash
just test-mac RoundTripTests 2>&1 | tee .agent-tmp/round-trip.txt
grep -iE 'failed|error:' .agent-tmp/round-trip.txt | head -5
```

Expected: passes. If not, the wire-struct construction (Step 3) is wrong — fix it; do not weaken the test.

- [ ] **Step 5: Commit**

```bash
just format
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 add MoolahTests/Backends/CloudKit/RoundTripTests.swift Backends/CloudKit/Sync/AccountRecord+CloudKit.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 commit -m "refactor(cloudkit): use generated wire struct in AccountRecord adapter"
```

---

## Task 12: Refactor the simple UUID-keyed adapters (Profile, Category, EarmarkBudgetItem)

Three adapters with the same structural shape as AccountRecord: UUID-keyed, all-required fields (or one optional), no helper methods, no special encoding. Refactor and add round-trip tests for each.

**Files:**
- Modify: `MoolahTests/Backends/CloudKit/RoundTripTests.swift`
- Modify: `Backends/CloudKit/Sync/ProfileRecord+CloudKit.swift`
- Modify: `Backends/CloudKit/Sync/CategoryRecord+CloudKit.swift`
- Modify: `Backends/CloudKit/Sync/EarmarkBudgetItemRecord+CloudKit.swift`

- [ ] **Step 1: Append round-trip tests to `RoundTripTests.swift`**

Add three new test methods inside the `RoundTripTests` suite:

```swift
  @Test("ProfileRecord round-trips through toCKRecord + fieldValues")
  func profileRoundTrip() throws {
    let original = ProfileRecord(
      id: UUID(),
      label: "Personal",
      currencyCode: "AUD",
      financialYearStartMonth: 7,
      createdAt: Date()
    )
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(ProfileRecord.fieldValues(from: record))
    #expect(decoded.id == original.id)
    #expect(decoded.label == original.label)
    #expect(decoded.currencyCode == original.currencyCode)
    #expect(decoded.financialYearStartMonth == original.financialYearStartMonth)
    #expect(abs(decoded.createdAt.timeIntervalSince(original.createdAt)) < 1)
  }

  @Test("CategoryRecord round-trips with parentId set")
  func categoryRoundTripWithParent() throws {
    let original = CategoryRecord(
      id: UUID(),
      name: "Groceries",
      parentId: UUID()
    )
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(CategoryRecord.fieldValues(from: record))
    #expect(decoded.id == original.id)
    #expect(decoded.name == original.name)
    #expect(decoded.parentId == original.parentId)
  }

  @Test("CategoryRecord round-trips with parentId nil")
  func categoryRoundTripNoParent() throws {
    let original = CategoryRecord(id: UUID(), name: "Top", parentId: nil)
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(CategoryRecord.fieldValues(from: record))
    #expect(decoded.id == original.id)
    #expect(decoded.name == original.name)
    #expect(decoded.parentId == nil)
  }

  @Test("EarmarkBudgetItemRecord round-trips")
  func earmarkBudgetItemRoundTrip() throws {
    let original = EarmarkBudgetItemRecord(
      id: UUID(),
      earmarkId: UUID(),
      categoryId: UUID(),
      amount: 1234,
      instrumentId: "AUD"
    )
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(EarmarkBudgetItemRecord.fieldValues(from: record))
    #expect(decoded.id == original.id)
    #expect(decoded.earmarkId == original.earmarkId)
    #expect(decoded.categoryId == original.categoryId)
    #expect(decoded.amount == original.amount)
    #expect(decoded.instrumentId == original.instrumentId)
  }
```

- [ ] **Step 2: Run the tests; they should all pass against the existing adapters**

```bash
just test-mac RoundTripTests 2>&1 | tee .agent-tmp/round-trip.txt
grep -iE 'failed|error:' .agent-tmp/round-trip.txt | head -10
```

Expected: all 5 tests pass. If `ProfileRecord`/`CategoryRecord`/`EarmarkBudgetItemRecord` have init signatures different from those above, adjust the test sites and the adapter steps below to match the actual init.

- [ ] **Step 3: Refactor `ProfileRecord+CloudKit.swift`**

Replace the file contents with:

```swift
import CloudKit
import Foundation

// MARK: - ProfileRecord + CloudKitRecordConvertible

extension ProfileRecord: CloudKitRecordConvertible {
  static let recordType = "ProfileRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    ProfileRecordCloudKitFields(
      label: label,
      currencyCode: currencyCode,
      financialYearStartMonth: Int64(financialYearStartMonth),
      createdAt: createdAt
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> ProfileRecord? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = ProfileRecordCloudKitFields(from: ckRecord)
    return ProfileRecord(
      id: id,
      label: fields.label ?? "",
      currencyCode: fields.currencyCode ?? "AUD",
      financialYearStartMonth: Int(fields.financialYearStartMonth ?? 1),
      createdAt: fields.createdAt ?? Date()
    )
  }
}
```

- [ ] **Step 4: Refactor `CategoryRecord+CloudKit.swift`**

Replace the file contents with:

```swift
import CloudKit
import Foundation

// MARK: - CategoryRecord + CloudKitRecordConvertible

extension CategoryRecord: CloudKitRecordConvertible {
  static let recordType = "CategoryRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    CategoryRecordCloudKitFields(
      name: name,
      parentId: parentId?.uuidString
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> CategoryRecord? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = CategoryRecordCloudKitFields(from: ckRecord)
    return CategoryRecord(
      id: id,
      name: fields.name ?? "",
      parentId: fields.parentId.flatMap(UUID.init(uuidString:))
    )
  }
}
```

- [ ] **Step 5: Refactor `EarmarkBudgetItemRecord+CloudKit.swift`**

Replace the file contents with:

```swift
import CloudKit
import Foundation

// MARK: - EarmarkBudgetItemRecord + CloudKitRecordConvertible

extension EarmarkBudgetItemRecord: CloudKitRecordConvertible {
  static let recordType = "EarmarkBudgetItemRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    EarmarkBudgetItemRecordCloudKitFields(
      earmarkId: earmarkId.uuidString,
      categoryId: categoryId.uuidString,
      amount: Int64(amount),
      instrumentId: instrumentId
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> EarmarkBudgetItemRecord? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = EarmarkBudgetItemRecordCloudKitFields(from: ckRecord)
    return EarmarkBudgetItemRecord(
      id: id,
      earmarkId: fields.earmarkId.flatMap(UUID.init(uuidString:)) ?? UUID(),
      categoryId: fields.categoryId.flatMap(UUID.init(uuidString:)) ?? UUID(),
      amount: Int(fields.amount ?? 0),
      instrumentId: fields.instrumentId ?? "AUD"
    )
  }
}
```

If the actual init signatures of `ProfileRecord`, `CategoryRecord`, or `EarmarkBudgetItemRecord` differ from the above, adapt the field mapping. Open the corresponding `Domain/Models/` or SwiftData `@Model` file to verify property names and types before changing them. Do not change the public init shape.

- [ ] **Step 6: Run round-trip tests**

```bash
just test-mac RoundTripTests 2>&1 | tee .agent-tmp/round-trip.txt
grep -iE 'failed|error:' .agent-tmp/round-trip.txt | head -10
```

Expected: all 5 tests pass.

- [ ] **Step 7: Commit**

```bash
just format
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 add MoolahTests/Backends/CloudKit/RoundTripTests.swift Backends/CloudKit/Sync/ProfileRecord+CloudKit.swift Backends/CloudKit/Sync/CategoryRecord+CloudKit.swift Backends/CloudKit/Sync/EarmarkBudgetItemRecord+CloudKit.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 commit -m "refactor(cloudkit): use generated wire structs in Profile/Category/EarmarkBudgetItem adapters"
```

---

## Task 13: Refactor the medium UUID-keyed adapters (Earmark, TransactionLeg, InvestmentValue)

Three adapters with optional fields and slightly more complexity than Task 12 but no helper methods.

**Files:**
- Modify: `MoolahTests/Backends/CloudKit/RoundTripTests.swift`
- Modify: `Backends/CloudKit/Sync/EarmarkRecord+CloudKit.swift`
- Modify: `Backends/CloudKit/Sync/TransactionLegRecord+CloudKit.swift`
- Modify: `Backends/CloudKit/Sync/InvestmentValueRecord+CloudKit.swift`

- [ ] **Step 1: Append round-trip tests**

Inside the `RoundTripTests` suite, append:

```swift
  @Test("EarmarkRecord round-trips with all optionals set")
  func earmarkRoundTripFull() throws {
    let original = EarmarkRecord(
      id: UUID(),
      name: "Holiday",
      position: 0,
      isHidden: false,
      instrumentId: "AUD",
      savingsTarget: 5_000_00,
      savingsTargetInstrumentId: "AUD",
      savingsStartDate: Date(),
      savingsEndDate: Date()
    )
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(EarmarkRecord.fieldValues(from: record))
    #expect(decoded.name == original.name)
    #expect(decoded.position == original.position)
    #expect(decoded.isHidden == original.isHidden)
    #expect(decoded.instrumentId == original.instrumentId)
    #expect(decoded.savingsTarget == original.savingsTarget)
    #expect(decoded.savingsTargetInstrumentId == original.savingsTargetInstrumentId)
  }

  @Test("EarmarkRecord round-trips with all optionals nil")
  func earmarkRoundTripMinimal() throws {
    let original = EarmarkRecord(
      id: UUID(),
      name: "Empty",
      position: 0,
      isHidden: false,
      instrumentId: nil,
      savingsTarget: nil,
      savingsTargetInstrumentId: nil,
      savingsStartDate: nil,
      savingsEndDate: nil
    )
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(EarmarkRecord.fieldValues(from: record))
    #expect(decoded.savingsTarget == nil)
    #expect(decoded.instrumentId == nil)
  }

  @Test("TransactionLegRecord round-trips")
  func transactionLegRoundTrip() throws {
    let original = TransactionLegRecord(
      id: UUID(),
      transactionId: UUID(),
      accountId: UUID(),
      instrumentId: "AUD",
      quantity: -100,
      type: "expense",
      categoryId: UUID(),
      earmarkId: UUID(),
      sortOrder: 0
    )
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(TransactionLegRecord.fieldValues(from: record))
    #expect(decoded.id == original.id)
    #expect(decoded.transactionId == original.transactionId)
    #expect(decoded.accountId == original.accountId)
    #expect(decoded.quantity == original.quantity)
    #expect(decoded.type == original.type)
    #expect(decoded.categoryId == original.categoryId)
    #expect(decoded.earmarkId == original.earmarkId)
  }

  @Test("InvestmentValueRecord round-trips")
  func investmentValueRoundTrip() throws {
    let original = InvestmentValueRecord(
      id: UUID(),
      accountId: UUID(),
      date: Date(),
      value: 12345,
      instrumentId: "ASX:BHP"
    )
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(InvestmentValueRecord.fieldValues(from: record))
    #expect(decoded.id == original.id)
    #expect(decoded.accountId == original.accountId)
    #expect(decoded.value == original.value)
    #expect(decoded.instrumentId == original.instrumentId)
  }
```

- [ ] **Step 2: Refactor `EarmarkRecord+CloudKit.swift`**

```swift
import CloudKit
import Foundation

// MARK: - EarmarkRecord + CloudKitRecordConvertible

extension EarmarkRecord: CloudKitRecordConvertible {
  static let recordType = "EarmarkRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    EarmarkRecordCloudKitFields(
      name: name,
      instrumentId: instrumentId,
      position: Int64(position),
      isHidden: isHidden ? 1 : 0,
      savingsTarget: savingsTarget,
      savingsTargetInstrumentId: savingsTargetInstrumentId,
      savingsStartDate: savingsStartDate,
      savingsEndDate: savingsEndDate
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> EarmarkRecord? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = EarmarkRecordCloudKitFields(from: ckRecord)
    return EarmarkRecord(
      id: id,
      name: fields.name ?? "",
      position: Int(fields.position ?? 0),
      isHidden: (fields.isHidden ?? 0) != 0,
      instrumentId: fields.instrumentId,
      savingsTarget: fields.savingsTarget,
      savingsTargetInstrumentId: fields.savingsTargetInstrumentId,
      savingsStartDate: fields.savingsStartDate,
      savingsEndDate: fields.savingsEndDate
    )
  }
}
```

- [ ] **Step 3: Refactor `TransactionLegRecord+CloudKit.swift`**

```swift
import CloudKit
import Foundation

// MARK: - TransactionLegRecord + CloudKitRecordConvertible

extension TransactionLegRecord: CloudKitRecordConvertible {
  static let recordType = "TransactionLegRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    TransactionLegRecordCloudKitFields(
      transactionId: transactionId.uuidString,
      accountId: accountId.uuidString,
      instrumentId: instrumentId,
      quantity: Int64(quantity),
      type: type,
      categoryId: categoryId?.uuidString,
      earmarkId: earmarkId?.uuidString,
      sortOrder: Int64(sortOrder)
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> TransactionLegRecord? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = TransactionLegRecordCloudKitFields(from: ckRecord)
    return TransactionLegRecord(
      id: id,
      transactionId: fields.transactionId.flatMap(UUID.init(uuidString:)) ?? UUID(),
      accountId: fields.accountId.flatMap(UUID.init(uuidString:)) ?? UUID(),
      instrumentId: fields.instrumentId ?? "AUD",
      quantity: Int(fields.quantity ?? 0),
      type: fields.type ?? "expense",
      categoryId: fields.categoryId.flatMap(UUID.init(uuidString:)),
      earmarkId: fields.earmarkId.flatMap(UUID.init(uuidString:)),
      sortOrder: Int(fields.sortOrder ?? 0)
    )
  }
}
```

- [ ] **Step 4: Refactor `InvestmentValueRecord+CloudKit.swift`**

```swift
import CloudKit
import Foundation

// MARK: - InvestmentValueRecord + CloudKitRecordConvertible

extension InvestmentValueRecord: CloudKitRecordConvertible {
  static let recordType = "InvestmentValueRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    InvestmentValueRecordCloudKitFields(
      accountId: accountId.uuidString,
      date: date,
      value: Int64(value),
      instrumentId: instrumentId
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> InvestmentValueRecord? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = InvestmentValueRecordCloudKitFields(from: ckRecord)
    return InvestmentValueRecord(
      id: id,
      accountId: fields.accountId.flatMap(UUID.init(uuidString:)) ?? UUID(),
      date: fields.date ?? Date(),
      value: Int(fields.value ?? 0),
      instrumentId: fields.instrumentId ?? "AUD"
    )
  }
}
```

- [ ] **Step 5: Run round-trip tests**

```bash
just test-mac RoundTripTests 2>&1 | tee .agent-tmp/round-trip.txt
grep -iE 'failed|error:' .agent-tmp/round-trip.txt | head -10
```

Expected: all round-trip tests pass.

- [ ] **Step 6: Commit**

```bash
just format
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 add MoolahTests/Backends/CloudKit/RoundTripTests.swift Backends/CloudKit/Sync/EarmarkRecord+CloudKit.swift Backends/CloudKit/Sync/TransactionLegRecord+CloudKit.swift Backends/CloudKit/Sync/InvestmentValueRecord+CloudKit.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 commit -m "refactor(cloudkit): use generated wire structs in Earmark/TransactionLeg/InvestmentValue adapters"
```

---

## Task 14: Refactor `TransactionRecord+CloudKit.swift`

The most complex of the UUID-keyed adapters: 13 user fields, most optional, including the `importOrigin*` family that previously lived in a helper method `encodeImportOriginFields`. Collapse the helper — the wire struct's single `write(to:)` call replaces it.

**Files:**
- Modify: `MoolahTests/Backends/CloudKit/RoundTripTests.swift`
- Modify: `Backends/CloudKit/Sync/TransactionRecord+CloudKit.swift`

- [ ] **Step 1: Append round-trip test**

Append to `RoundTripTests`:

```swift
  @Test("TransactionRecord round-trips with all import-origin fields populated")
  func transactionRoundTripFull() throws {
    let original = TransactionRecord(
      id: UUID(),
      date: Date(),
      payee: "Coles",
      notes: "weekly shop",
      recurPeriod: "month",
      recurEvery: 1
    )
    original.importOriginRawDescription = "COLES 1234"
    original.importOriginBankReference = "REF-1"
    original.importOriginRawAmount = "-100.00"
    original.importOriginRawBalance = "1000.00"
    original.importOriginImportedAt = Date()
    original.importOriginImportSessionId = UUID()
    original.importOriginSourceFilename = "statement.csv"
    original.importOriginParserIdentifier = "generic"

    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(TransactionRecord.fieldValues(from: record))
    #expect(decoded.id == original.id)
    #expect(decoded.payee == original.payee)
    #expect(decoded.notes == original.notes)
    #expect(decoded.recurPeriod == original.recurPeriod)
    #expect(decoded.recurEvery == original.recurEvery)
    #expect(decoded.importOriginRawDescription == original.importOriginRawDescription)
    #expect(decoded.importOriginBankReference == original.importOriginBankReference)
    #expect(decoded.importOriginImportSessionId == original.importOriginImportSessionId)
    #expect(decoded.importOriginParserIdentifier == original.importOriginParserIdentifier)
  }

  @Test("TransactionRecord round-trips with no import-origin fields")
  func transactionRoundTripMinimal() throws {
    let original = TransactionRecord(
      id: UUID(),
      date: Date(),
      payee: nil,
      notes: nil,
      recurPeriod: nil,
      recurEvery: nil
    )
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(TransactionRecord.fieldValues(from: record))
    #expect(decoded.payee == nil)
    #expect(decoded.importOriginRawDescription == nil)
  }
```

- [ ] **Step 2: Refactor `TransactionRecord+CloudKit.swift`**

```swift
import CloudKit
import Foundation

// MARK: - TransactionRecord + CloudKitRecordConvertible

extension TransactionRecord: CloudKitRecordConvertible {
  static let recordType = "TransactionRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    TransactionRecordCloudKitFields(
      date: date,
      payee: payee,
      notes: notes,
      recurPeriod: recurPeriod,
      recurEvery: recurEvery.map(Int64.init),
      importOriginRawDescription: importOriginRawDescription,
      importOriginBankReference: importOriginBankReference,
      importOriginRawAmount: importOriginRawAmount,
      importOriginRawBalance: importOriginRawBalance,
      importOriginImportedAt: importOriginImportedAt,
      importOriginImportSessionId: importOriginImportSessionId?.uuidString,
      importOriginSourceFilename: importOriginSourceFilename,
      importOriginParserIdentifier: importOriginParserIdentifier
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> TransactionRecord? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = TransactionRecordCloudKitFields(from: ckRecord)
    let record = TransactionRecord(
      id: id,
      date: fields.date ?? Date(),
      payee: fields.payee,
      notes: fields.notes,
      recurPeriod: fields.recurPeriod,
      recurEvery: fields.recurEvery.map(Int.init)
    )
    record.importOriginRawDescription = fields.importOriginRawDescription
    record.importOriginBankReference = fields.importOriginBankReference
    record.importOriginRawAmount = fields.importOriginRawAmount
    record.importOriginRawBalance = fields.importOriginRawBalance
    record.importOriginImportedAt = fields.importOriginImportedAt
    record.importOriginImportSessionId =
      fields.importOriginImportSessionId.flatMap(UUID.init(uuidString:))
    record.importOriginSourceFilename = fields.importOriginSourceFilename
    record.importOriginParserIdentifier = fields.importOriginParserIdentifier
    return record
  }
}
```

The previous `encodeImportOriginFields` helper goes away — the wire struct's single `write(to:)` call covers everything. SwiftLint `cyclomatic_complexity` on the new `toCKRecord` is well below the threshold.

- [ ] **Step 3: Run round-trip tests**

```bash
just test-mac RoundTripTests 2>&1 | tee .agent-tmp/round-trip.txt
grep -iE 'failed|error:' .agent-tmp/round-trip.txt | head -10
```

Expected: all round-trip tests pass.

- [ ] **Step 4: Commit**

```bash
just format
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 add MoolahTests/Backends/CloudKit/RoundTripTests.swift Backends/CloudKit/Sync/TransactionRecord+CloudKit.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 commit -m "refactor(cloudkit): use generated wire struct in TransactionRecord adapter"
```

---

## Task 15: Refactor `ImportRuleRecord` and `CSVImportProfileRecord`

ImportRule has the only BYTES fields (`conditionsJSON`, `actionsJSON`) and a UUID stored as String (`accountScope`). CSVImportProfile is ordinary.

**Files:**
- Modify: `MoolahTests/Backends/CloudKit/RoundTripTests.swift`
- Modify: `Backends/CloudKit/Sync/ImportRuleRecord+CloudKit.swift`
- Modify: `Backends/CloudKit/Sync/CSVImportProfileRecord+CloudKit.swift`

- [ ] **Step 1: Append round-trip tests**

```swift
  @Test("ImportRuleRecord round-trips with BYTES and UUID-string fields")
  func importRuleRoundTrip() throws {
    let conditionsJSON = Data(#"[{"field":"payee"}]"#.utf8)
    let actionsJSON = Data(#"[{"set":"category"}]"#.utf8)
    let original = ImportRuleRecord(
      id: UUID(),
      name: "Rent",
      enabled: true,
      position: 0,
      matchMode: .all,
      conditions: [],
      actions: [],
      accountScope: UUID()
    )
    original.conditionsJSON = conditionsJSON
    original.actionsJSON = actionsJSON

    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(ImportRuleRecord.fieldValues(from: record))
    #expect(decoded.id == original.id)
    #expect(decoded.name == original.name)
    #expect(decoded.enabled == original.enabled)
    #expect(decoded.position == original.position)
    #expect(decoded.matchMode == original.matchMode)
    #expect(decoded.accountScope == original.accountScope)
    #expect(decoded.conditionsJSON == conditionsJSON)
    #expect(decoded.actionsJSON == actionsJSON)
  }

  @Test("CSVImportProfileRecord round-trips")
  func csvImportProfileRoundTrip() throws {
    let original = CSVImportProfileRecord(
      id: UUID(),
      accountId: UUID(),
      parserIdentifier: "generic",
      headerSignature: "a,b,c",
      filenamePattern: "statement-*.csv",
      deleteAfterImport: true,
      createdAt: Date(),
      lastUsedAt: Date(),
      dateFormatRawValue: "yyyy-MM-dd",
      columnRoleRawValuesEncoded: "amount,date,description"
    )
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(CSVImportProfileRecord.fieldValues(from: record))
    #expect(decoded.id == original.id)
    #expect(decoded.accountId == original.accountId)
    #expect(decoded.parserIdentifier == original.parserIdentifier)
    #expect(decoded.headerSignature == original.headerSignature)
    #expect(decoded.filenamePattern == original.filenamePattern)
    #expect(decoded.deleteAfterImport == original.deleteAfterImport)
    #expect(decoded.dateFormatRawValue == original.dateFormatRawValue)
    #expect(decoded.columnRoleRawValuesEncoded == original.columnRoleRawValuesEncoded)
  }
```

If the actual init signatures of `ImportRuleRecord` or `CSVImportProfileRecord` differ, adjust the test sites first.

- [ ] **Step 2: Refactor `ImportRuleRecord+CloudKit.swift`**

```swift
import CloudKit
import Foundation

// MARK: - ImportRuleRecord + CloudKitRecordConvertible

extension ImportRuleRecord: CloudKitRecordConvertible {
  static let recordType = "ImportRuleRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    ImportRuleRecordCloudKitFields(
      name: name,
      enabled: enabled ? 1 : 0,
      position: Int64(position),
      matchMode: matchMode.rawValue,
      conditionsJSON: conditionsJSON,
      actionsJSON: actionsJSON,
      accountScope: accountScope?.uuidString
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> ImportRuleRecord? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = ImportRuleRecordCloudKitFields(from: ckRecord)
    let record = ImportRuleRecord(
      id: id,
      name: fields.name ?? "",
      enabled: (fields.enabled ?? 0) != 0,
      position: Int(fields.position ?? 0),
      matchMode: MatchMode(rawValue: fields.matchMode ?? "all") ?? .all,
      conditions: [],
      actions: [],
      accountScope: fields.accountScope.flatMap(UUID.init(uuidString:))
    )
    record.conditionsJSON = fields.conditionsJSON ?? Data()
    record.actionsJSON = fields.actionsJSON ?? Data()
    return record
  }
}
```

- [ ] **Step 3: Refactor `CSVImportProfileRecord+CloudKit.swift`**

```swift
import CloudKit
import Foundation

// MARK: - CSVImportProfileRecord + CloudKitRecordConvertible

extension CSVImportProfileRecord: CloudKitRecordConvertible {
  static let recordType = "CSVImportProfileRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    CSVImportProfileRecordCloudKitFields(
      accountId: accountId.uuidString,
      parserIdentifier: parserIdentifier,
      headerSignature: headerSignature,
      filenamePattern: filenamePattern,
      deleteAfterImport: deleteAfterImport ? 1 : 0,
      createdAt: createdAt,
      lastUsedAt: lastUsedAt,
      dateFormatRawValue: dateFormatRawValue,
      columnRoleRawValuesEncoded: columnRoleRawValuesEncoded
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> CSVImportProfileRecord? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = CSVImportProfileRecordCloudKitFields(from: ckRecord)
    return CSVImportProfileRecord(
      id: id,
      accountId: fields.accountId.flatMap(UUID.init(uuidString:)) ?? UUID(),
      parserIdentifier: fields.parserIdentifier ?? "generic",
      headerSignature: fields.headerSignature ?? "",
      filenamePattern: fields.filenamePattern ?? "",
      deleteAfterImport: (fields.deleteAfterImport ?? 0) != 0,
      createdAt: fields.createdAt ?? Date(),
      lastUsedAt: fields.lastUsedAt ?? Date(),
      dateFormatRawValue: fields.dateFormatRawValue ?? "",
      columnRoleRawValuesEncoded: fields.columnRoleRawValuesEncoded ?? ""
    )
  }
}
```

- [ ] **Step 4: Run round-trip tests**

```bash
just test-mac RoundTripTests 2>&1 | tee .agent-tmp/round-trip.txt
grep -iE 'failed|error:' .agent-tmp/round-trip.txt | head -10
```

Expected: all round-trip tests pass.

- [ ] **Step 5: Commit**

```bash
just format
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 add MoolahTests/Backends/CloudKit/RoundTripTests.swift Backends/CloudKit/Sync/ImportRuleRecord+CloudKit.swift Backends/CloudKit/Sync/CSVImportProfileRecord+CloudKit.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 commit -m "refactor(cloudkit): use generated wire structs in ImportRule/CSVImportProfile adapters"
```

---

## Task 16: Refactor `InstrumentRecord+CloudKit.swift`

`InstrumentRecord` is the only adapter keyed by `recordName` (e.g. `"AUD"`, `"ASX:BHP"`) instead of UUID. The wire struct still handles fields uniformly; the adapter owns the recordID strategy.

**Files:**
- Modify: `MoolahTests/Backends/CloudKit/RoundTripTests.swift`
- Modify: `Backends/CloudKit/Sync/InstrumentRecord+CloudKit.swift`

- [ ] **Step 1: Append round-trip test**

```swift
  @Test("InstrumentRecord round-trips with all optional fields populated")
  func instrumentRoundTripFull() throws {
    let original = InstrumentRecord(
      id: "ASX:BHP",
      kind: "stock",
      name: "BHP",
      decimals: 4,
      ticker: "BHP",
      exchange: "ASX",
      chainId: 1,
      contractAddress: "0xabc",
      coingeckoId: "bhp",
      cryptocompareSymbol: "BHP",
      binanceSymbol: "BHPUSDT"
    )
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(InstrumentRecord.fieldValues(from: record))
    #expect(decoded.id == original.id)
    #expect(decoded.kind == original.kind)
    #expect(decoded.name == original.name)
    #expect(decoded.decimals == original.decimals)
    #expect(decoded.ticker == original.ticker)
    #expect(decoded.exchange == original.exchange)
    #expect(decoded.chainId == original.chainId)
    #expect(decoded.contractAddress == original.contractAddress)
  }

  @Test("InstrumentRecord round-trips with optional fields nil")
  func instrumentRoundTripMinimal() throws {
    let original = InstrumentRecord(
      id: "AUD",
      kind: "fiatCurrency",
      name: "Australian Dollar",
      decimals: 2,
      ticker: nil,
      exchange: nil,
      chainId: nil,
      contractAddress: nil,
      coingeckoId: nil,
      cryptocompareSymbol: nil,
      binanceSymbol: nil
    )
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(InstrumentRecord.fieldValues(from: record))
    #expect(decoded.id == original.id)
    #expect(decoded.ticker == nil)
    #expect(decoded.chainId == nil)
  }
```

- [ ] **Step 2: Refactor `InstrumentRecord+CloudKit.swift`**

```swift
import CloudKit
import Foundation

// MARK: - InstrumentRecord + CloudKitRecordConvertible

extension InstrumentRecord: CloudKitRecordConvertible {
  static let recordType = "InstrumentRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    InstrumentRecordCloudKitFields(
      kind: kind,
      name: name,
      decimals: Int64(decimals),
      ticker: ticker,
      exchange: exchange,
      chainId: chainId.map(Int64.init),
      contractAddress: contractAddress,
      coingeckoId: coingeckoId,
      cryptocompareSymbol: cryptocompareSymbol,
      binanceSymbol: binanceSymbol
    ).write(to: record)
    return record
  }

  /// `InstrumentRecord` is keyed by `recordName` (e.g. `"AUD"`, `"ASX:BHP"`)
  /// rather than a UUID. `recordName` is always non-nil on a valid
  /// `CKRecord.ID`, so this never returns `nil`; the Optional return type
  /// exists to keep the protocol signature uniform with UUID-keyed conformers.
  static func fieldValues(from ckRecord: CKRecord) -> InstrumentRecord? {
    let fields = InstrumentRecordCloudKitFields(from: ckRecord)
    return InstrumentRecord(
      id: ckRecord.recordID.recordName,
      kind: fields.kind ?? "fiatCurrency",
      name: fields.name ?? "",
      decimals: Int(fields.decimals ?? 2),
      ticker: fields.ticker,
      exchange: fields.exchange,
      chainId: fields.chainId.map(Int.init),
      contractAddress: fields.contractAddress,
      coingeckoId: fields.coingeckoId,
      cryptocompareSymbol: fields.cryptocompareSymbol,
      binanceSymbol: fields.binanceSymbol
    )
  }
}
```

- [ ] **Step 3: Run the full test suite**

The test suite must be green at this point — every adapter is refactored, the wire structs are in place, the round-trip tests cover all 11 record types.

```bash
just test 2>&1 | tee .agent-tmp/full-test.txt
grep -iE 'failed|error:' .agent-tmp/full-test.txt | head -20
```

Expected: zero failures.

- [ ] **Step 4: Commit**

```bash
just format
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 add MoolahTests/Backends/CloudKit/RoundTripTests.swift Backends/CloudKit/Sync/InstrumentRecord+CloudKit.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 commit -m "refactor(cloudkit): use generated wire struct in InstrumentRecord adapter (recordName-keyed)"
```

---

## Task 17: Repurpose schema scripts under `scripts/`

Update the existing scripts and add the new ones for the inverted pipeline:

- `verify-schema.sh` becomes a *manual local convenience*: import `.ckdb` to Dev with `--validate`. Not in CI any more.
- `dryrun-promote-schema.sh` (new): Apple's recommended Production-equivalent dry-run, manual local only.
- `verify-prod-matches-baseline.sh` (new): release-tag CI gate that compares live Production against the committed baseline.
- `check-schema-additive.sh` (new wrapper): exists as a script so CI invokes a single binary, but it just calls `swift run`.
- `promote-schema.sh` extended: after a successful import, exports Prod into the baseline file and opens a follow-up PR.

**Files:**
- Modify: `scripts/verify-schema.sh` (rewrite)
- Create: `scripts/dryrun-promote-schema.sh`
- Create: `scripts/verify-prod-matches-baseline.sh`
- Create: `scripts/check-schema-additive.sh`
- Modify: `scripts/promote-schema.sh` (extend)

- [ ] **Step 1: Rewrite `scripts/verify-schema.sh`**

Replace the contents of `scripts/verify-schema.sh` with:

```bash
#!/usr/bin/env bash
#
# Manual local convenience: imports CloudKit/schema.ckdb to the developer's
# personal Development container with --validate. Not run in CI.
#
# Use this when you want belt-and-braces verification before opening a PR
# that touches the schema. It will surface any cktool import-side issues
# (syntax, conflicts with what your Dev currently has) that the static
# additivity check cannot catch.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/cloudkit-config.sh
source "$HERE/cloudkit-config.sh"

cloudkit_require_env

[ -f "$CLOUDKIT_SCHEMA_FILE" ] \
    || cloudkit_fail "$CLOUDKIT_SCHEMA_FILE is missing."

cloudkit_cktool import-schema \
    --environment development \
    --validate \
    --file "$CLOUDKIT_SCHEMA_FILE"

echo "$CLOUDKIT_SCHEMA_FILE imported into your CloudKit Development container."
```

- [ ] **Step 2: Create `scripts/dryrun-promote-schema.sh`**

```bash
#!/usr/bin/env bash
#
# Manual local convenience: Apple's recommended Production-equivalent dry-run.
# Resets your personal Development container to match Production, then
# imports the proposed schema with --validate. If this fails, the same
# import would fail on Production.
#
# DESTRUCTIVE: cktool reset-schema wipes any data in your personal Dev.
# Set CKTOOL_ALLOW_DEV_RESET=1 to confirm.
#
# Not run in CI.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/cloudkit-config.sh
source "$HERE/cloudkit-config.sh"

cloudkit_require_env

[ -f "$CLOUDKIT_SCHEMA_FILE" ] \
    || cloudkit_fail "$CLOUDKIT_SCHEMA_FILE is missing."

if [ "${CKTOOL_ALLOW_DEV_RESET:-}" != "1" ]; then
    cat >&2 <<EOF
error: dryrun-promote-schema resets your CloudKit Development environment,
       which wipes any data and schema changes you've made there.

       Set CKTOOL_ALLOW_DEV_RESET=1 to confirm.
EOF
    exit 1
fi

cloudkit_cktool reset-schema --environment development
cloudkit_cktool import-schema \
    --environment development \
    --validate \
    --file "$CLOUDKIT_SCHEMA_FILE"

echo "Dry-run promotion succeeded — $CLOUDKIT_SCHEMA_FILE is promotable to Production."
```

```bash
chmod +x scripts/dryrun-promote-schema.sh
```

- [ ] **Step 3: Create `scripts/verify-prod-matches-baseline.sh`**

```bash
#!/usr/bin/env bash
#
# Release-tag CI gate: exports the live CloudKit Production schema and
# compares it byte-for-byte against the committed
# CloudKit/schema-prod-baseline.ckdb. Halts the release on mismatch
# (manual dashboard edit, partial prior promote, etc.) so a human can
# investigate before promote-schema runs.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/cloudkit-config.sh
source "$HERE/cloudkit-config.sh"

cloudkit_require_env

baseline="CloudKit/schema-prod-baseline.ckdb"
[ -f "$baseline" ] || cloudkit_fail "$baseline is missing."

tmp="$(mktemp -t cloudkit-prod-schema)"
trap 'rm -f "$tmp"' EXIT

cloudkit_cktool export-schema \
    --environment production \
    --output-file "$tmp"

if diff -u "$baseline" "$tmp"; then
    echo "Production schema matches $baseline."
    exit 0
fi

cat >&2 <<EOF

error: live Production schema does not match $baseline.

The release pipeline halts here. Investigate the divergence (manual
dashboard edit, partial prior promote, etc.) and update the baseline
via a follow-up PR before retrying the release.
EOF
exit 1
```

```bash
chmod +x scripts/verify-prod-matches-baseline.sh
```

- [ ] **Step 4: Create `scripts/check-schema-additive.sh`**

```bash
#!/usr/bin/env bash
#
# Static additivity gate: compares CloudKit/schema.ckdb against the
# committed CloudKit/schema-prod-baseline.ckdb. Pure text — no CloudKit
# calls. Run by CI on every PR.
set -euo pipefail

swift run --package-path tools/CKDBSchemaGen ckdb-schema-gen check-additive \
    --proposed CloudKit/schema.ckdb \
    --baseline CloudKit/schema-prod-baseline.ckdb
```

```bash
chmod +x scripts/check-schema-additive.sh
```

- [ ] **Step 5: Extend `scripts/promote-schema.sh`**

Replace the file contents with:

```bash
#!/usr/bin/env bash
#
# Release-tag CI: imports CloudKit/schema.ckdb to Production with --validate,
# exports the resulting Production schema into the baseline file, and opens
# a follow-up PR that commits the refreshed baseline.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/cloudkit-config.sh
source "$HERE/cloudkit-config.sh"

cloudkit_require_env

[ -f "$CLOUDKIT_SCHEMA_FILE" ] \
    || cloudkit_fail "$CLOUDKIT_SCHEMA_FILE is missing."

baseline="CloudKit/schema-prod-baseline.ckdb"

cloudkit_cktool import-schema \
    --environment production \
    --validate \
    --file "$CLOUDKIT_SCHEMA_FILE"
echo "Promoted $CLOUDKIT_SCHEMA_FILE to CloudKit Production."

cloudkit_cktool export-schema \
    --environment production \
    --output-file "$baseline"
echo "Refreshed $baseline from live Production."

# If the export changed the baseline, open a follow-up PR. The baseline
# only needs to be updated when the schema actually changed.
if git -C "$(pwd)" diff --quiet -- "$baseline"; then
    echo "$baseline unchanged; nothing to commit."
    exit 0
fi

# Configure git for the bot commit (CI context — no global identity).
git -C "$(pwd)" config user.name "github-actions[bot]"
git -C "$(pwd)" config user.email "41898282+github-actions[bot]@users.noreply.github.com"

branch="cloudkit-baseline-refresh-$(date -u +%Y%m%d-%H%M%S)"
git -C "$(pwd)" checkout -b "$branch"
git -C "$(pwd)" add "$baseline"
git -C "$(pwd)" commit -m "chore(cloudkit): refresh schema-prod-baseline after promote"
git -C "$(pwd)" push -u origin "$branch"

gh pr create \
    --title "chore(cloudkit): refresh schema-prod-baseline after promote" \
    --body "$(cat <<EOF
Auto-generated after a successful CloudKit Production schema promote.
Refreshes \`CloudKit/schema-prod-baseline.ckdb\` to match the new live
Production schema. Subsequent PRs run \`just check-schema-additive\`
against this updated baseline.
EOF
)"
```

This script depends on `gh` being authenticated in CI with permission to push branches and open PRs. The existing TestFlight workflow already has equivalent permissions.

- [ ] **Step 6: Lint the scripts**

```bash
bash -n scripts/verify-schema.sh
bash -n scripts/dryrun-promote-schema.sh
bash -n scripts/verify-prod-matches-baseline.sh
bash -n scripts/check-schema-additive.sh
bash -n scripts/promote-schema.sh
echo "all syntax ok"
```

Expected: prints "all syntax ok" with no errors.

- [ ] **Step 7: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 add scripts/verify-schema.sh scripts/dryrun-promote-schema.sh scripts/verify-prod-matches-baseline.sh scripts/check-schema-additive.sh scripts/promote-schema.sh
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 commit -m "refactor(cloudkit): repurpose schema scripts for inverted pipeline"
```

---

## Task 18: Update `Justfile` targets for the new scripts

Wire the new and repurposed scripts into Justfile targets.

**Files:**
- Modify: `Justfile`

- [ ] **Step 1: Replace the existing `verify-schema` recipe and add new targets**

In `Justfile`, find the current `verify-schema` recipe (around line 211):

```
verify-schema:
    bash scripts/verify-schema.sh
```

Replace and extend with:

```
# Manual local convenience: import CloudKit/schema.ckdb to the developer's
# personal Development container with --validate. Not used by CI.
verify-schema:
    bash scripts/verify-schema.sh

# Manual local convenience: Apple's recommended Production-equivalent
# dry-run. Resets your personal Dev container to match Prod, then imports
# the proposed schema with --validate. DESTRUCTIVE — set
# CKTOOL_ALLOW_DEV_RESET=1 to confirm. Not used by CI.
dryrun-promote-schema:
    bash scripts/dryrun-promote-schema.sh

# Release-tag CI: verifies the live Production schema matches
# CloudKit/schema-prod-baseline.ckdb before promote-schema runs.
verify-prod-matches-baseline:
    bash scripts/verify-prod-matches-baseline.sh
```

Also update the `promote-schema` recipe's leading comment to mention the baseline refresh side effect:

```
# Release-tag CI: imports CloudKit/schema.ckdb to Production with --validate,
# refreshes CloudKit/schema-prod-baseline.ckdb from live Production, and
# opens a follow-up PR with the new baseline. Run via the testflight workflow.
promote-schema:
    ...  (existing recipe body unchanged)
```

- [ ] **Step 2: Verify `just --list` shows the new targets**

```bash
just --list 2>&1 | grep -E 'verify-schema|dryrun-promote-schema|verify-prod-matches-baseline|check-schema-additive|promote-schema'
```

Expected: all five targets listed.

- [ ] **Step 3: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 add Justfile
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 commit -m "build(cloudkit): wire new schema scripts into Justfile"
```

---

## Task 19: Update CI workflows

Re-enable the schema CI job (currently disabled with `if: false`) and point it at the new static additivity check. Add a `verify-prod-matches-baseline` step before `promote-schema` in the TestFlight workflow.

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/testflight.yml`

- [ ] **Step 1: Re-enable the schema-drift CI job and rename to `schema-check`**

In `.github/workflows/ci.yml`, find the current `schema-drift` job (around line 75):

```yaml
  schema-drift:
    name: CloudKit schema drift
    runs-on: macos-26
    # Disabled while CloudKit schema management is being reworked. The
    # committed `CloudKit/schema.ckdb` is being inverted from "exported
    # from Dev" to "hand-authored manifest" (see
    # plans/2026-04-25-cloudkit-schema-as-source-of-truth.md). Until
    # that lands, Dev contents are unstable while sync fixes land and
    # this diff would fail spuriously on every PR. Re-enable once the
    # new pipeline is in place.
    if: false
    timeout-minutes: 10
    env:
      DEVELOPMENT_TEAM: ${{ secrets.DEVELOPMENT_TEAM }}
      CKTOOL_MANAGEMENT_TOKEN: ${{ secrets.CKTOOL_MANAGEMENT_TOKEN }}
    steps:
      - uses: actions/checkout@v6

      - name: Install tools
        run: brew install just

      - name: Verify CloudKit schema
        run: just verify-schema
```

Replace with:

```yaml
  schema-check:
    name: CloudKit schema additivity
    runs-on: macos-26
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v6

      - name: Install tools
        run: brew install just

      - name: Check schema is additive over Production baseline
        run: just check-schema-additive
```

No CloudKit credentials needed — the check is pure text.

- [ ] **Step 2: Add `verify-prod-matches-baseline` to `testflight.yml`**

In `.github/workflows/testflight.yml`, find the existing "Promote CloudKit schema to Production" step (around line 58):

```yaml
      - name: Promote CloudKit schema to Production
        env:
          DEVELOPMENT_TEAM: ${{ secrets.DEVELOPMENT_TEAM }}
          CKTOOL_MANAGEMENT_TOKEN: ${{ secrets.CKTOOL_MANAGEMENT_TOKEN }}
        run: just promote-schema
```

Insert a new step *before* it that verifies live Production matches the committed baseline, and grant the promote-schema step the additional permissions it needs to push the baseline-refresh branch and open a PR:

```yaml
      - name: Verify Production schema matches committed baseline
        env:
          DEVELOPMENT_TEAM: ${{ secrets.DEVELOPMENT_TEAM }}
          CKTOOL_MANAGEMENT_TOKEN: ${{ secrets.CKTOOL_MANAGEMENT_TOKEN }}
        run: just verify-prod-matches-baseline

      - name: Promote CloudKit schema to Production
        env:
          DEVELOPMENT_TEAM: ${{ secrets.DEVELOPMENT_TEAM }}
          CKTOOL_MANAGEMENT_TOKEN: ${{ secrets.CKTOOL_MANAGEMENT_TOKEN }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: just promote-schema
```

Update the `permissions:` block at the top of the workflow file (currently `contents: read`) to add what `promote-schema` needs:

```yaml
permissions:
  contents: write
  pull-requests: write
```

Without `contents: write` and `pull-requests: write` the bot cannot push the baseline-refresh branch or open the follow-up PR.

- [ ] **Step 3: Validate workflow YAML**

```bash
# yamllint isn't part of the project tooling, but a basic parse via python
# catches obvious syntax errors.
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml'))"
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/testflight.yml'))"
echo "yaml ok"
```

Expected: prints "yaml ok".

- [ ] **Step 4: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 add .github/workflows/ci.yml .github/workflows/testflight.yml
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 commit -m "ci(cloudkit): swap schema-drift for schema additivity; add baseline pre-check"
```

---

## Task 20: Add the `modifying-cloudkit-schema` skill

Project-local skill loaded by future Claude Code agents whenever the conversation touches CloudKit fields, record types, wire-struct compile errors, or `.ckdb`/`cktool`/`schema-prod-baseline`. The frontmatter description is the trigger; the body is the runbook.

**Files:**
- Create: `.claude/skills/modifying-cloudkit-schema/SKILL.md`

- [ ] **Step 1: Create the skill file**

```bash
mkdir -p .claude/skills/modifying-cloudkit-schema
```

Create `.claude/skills/modifying-cloudkit-schema/SKILL.md` with:

````markdown
---
name: modifying-cloudkit-schema
description: Use when adding, removing, renaming, or retyping a CloudKit field; when adding or removing a CloudKitRecordConvertible record type; when hitting a Swift compile error against a generated wire struct (e.g. "value of type 'AccountRecordCloudKitFields' has no member 'foo'", "extra argument 'foo' in call"); or when anything mentions `CloudKit/schema.ckdb`, `cktool`, `schema-prod-baseline.ckdb`, or `Backends/CloudKit/Sync/Generated/`.
---

# Modifying the CloudKit schema

Load this skill **every time** you touch any of these:

- `CloudKit/schema.ckdb` (the canonical hand-edited manifest).
- `Backends/CloudKit/Sync/Generated/*` (auto-generated wire structs — never edit by hand; regenerated by `just generate`).
- `Backends/CloudKit/Sync/<RecordType>+CloudKit.swift` (hand-written adapters).
- `tools/CKDBSchemaGen/` (the SPM tool that emits the wire layer).
- `CloudKit/schema-prod-baseline.ckdb` (committed snapshot of live Production — never edit by hand).
- `Domain/Models/<RecordType>.swift` if the change implies a CloudKit field add/remove.

The CloudKit schema is shaped by additive-only Production semantics, and shortcuts here are easy to introduce and very hard to undo. Follow this skill, not "I'll just".

## The pipeline (read first)

```
hand-edited                      gitignored                 hand-written
CloudKit/schema.ckdb  ──►  ckdb-schema-gen  ──►  Generated/  ──►  *Record+CloudKit.swift  ──►  CKRecord
                       │                          (wire struct)     (adapter, thin)
                       │
                       │ cktool import-schema
                       ▼
                  CloudKit Production
                       │
                       │ cktool export-schema (after promote)
                       ▼
                  CloudKit/schema-prod-baseline.ckdb (committed)
```

`schema.ckdb` is the only file you hand-edit. The wire struct is generated. The adapter is the bridge between the wire struct and the rich domain model (UUID, Bool, enum raw values, defaults, recordID strategy).

## Adding a field

1. Edit `CloudKit/schema.ckdb`. Find the right `RECORD TYPE` block. Add the field with the standard index policy:
   - `STRING` → `QUERYABLE SEARCHABLE SORTABLE`
   - `INT64` / `TIMESTAMP` → `QUERYABLE SORTABLE`
   - `BYTES` → no indexes
2. `just generate`. The wire struct in `Backends/CloudKit/Sync/Generated/<RecordType>CloudKitFields.swift` now has the new property.
3. Edit `Backends/CloudKit/Sync/<RecordType>+CloudKit.swift`:
   - In `toCKRecord`, populate the new wire-struct field from the domain model.
   - In `fieldValues(from:)`, read it back and populate the domain model.
4. Add a round-trip case in `MoolahTests/Backends/CloudKit/RoundTripTests.swift`.
5. `just format`, `just test`, commit. Generated files are gitignored — only `schema.ckdb` and the adapter (and the test) are in the diff.

## Removing a field

**Production schema is additive-only forever.** You cannot delete a field. The deprecation path is:

1. In `CloudKit/schema.ckdb`, add a `// DEPRECATED: <reason>` line *immediately above* the field's declaration. Leave the field's own line in place.
2. `just generate`. The wire struct no longer exposes the field (the generator skips deprecated fields).
3. The build now fails on every reference to the field in the adapter. Remove the references — the adapter no longer reads or writes it.
4. `just format`, `just test`, commit.

`cktool import-schema` still uploads the deprecated field on every promote, so Production keeps it forever (additive-only invariant satisfied). The Swift wire layer simply forgets about it.

## Renaming a field

Renaming is deprecation + addition + migration:

1. Add the new field in `schema.ckdb`.
2. `just generate`. Update the adapter to write the new field.
3. In `fieldValues(from:)`, read both old and new — prefer new, fall back to old. Migrate data on read.
4. Once you are sure all relevant records have been migrated (multi-release rollout), mark the old field `// DEPRECATED` and stop reading it.
5. **Never** rename the old field's line in place. That would be a "remove + add" and break the additive invariant.

## Changing a field's type

Not allowed. Same as rename: add a new field with the new type, deprecate the old, migrate.

## Adding a record type

1. Declare the type in `schema.ckdb` with the standard system-field block, `___recordID REFERENCE QUERYABLE`, and the standard grants.
2. `just generate`. New wire struct exists.
3. Add the domain type in `Domain/Models/` (and the SwiftData `@Model` in `Backends/CloudKit/Models/` if applicable).
4. Create `Backends/CloudKit/Sync/<RecordType>+CloudKit.swift` with `CloudKitRecordConvertible` conformance using the wire struct.
5. Register the type in `RecordTypeRegistry.allTypes` (in `Backends/CloudKit/Sync/CloudKitRecordConvertible.swift`).
6. Add a round-trip test in `MoolahTests/Backends/CloudKit/RoundTripTests.swift`.
7. `just format`, `just test`, commit.

## Errors and what they mean

- **"value of type 'XCloudKitFields' has no member 'foo'"** or **"extra argument 'foo' in call"** against a wire struct's memberwise init → `schema.ckdb` does not declare the field. Either add it (if it should exist) or remove the reference from the adapter. Run `just generate` after editing `schema.ckdb`.
- **`just check-schema-additive` failure** → the proposed manifest removes a record type, removes a field, changes a field's type, or removes an index that exists in Production. Fix by using `// DEPRECATED` instead of deletion, or by reverting the change. Never edit `schema-prod-baseline.ckdb` by hand to make this pass.
- **`cktool import-schema` failure** → the manifest is syntactically invalid or conflicts with the destination's schema in a non-additive way. Read the cktool message; do not silence with `--force`.
- **`just generate` failure** → parser error in `schema.ckdb`. The error message names the line. Common causes: missing comma between fields, unknown index attribute, type token misspelled.

## Always go through `just`

- `just generate` — regenerates wire structs and the Xcode project.
- `just check-schema-additive` — static check used by CI; safe to run locally.
- `just verify-schema` — manual local: import `schema.ckdb` to your personal Dev with `--validate`.
- `just dryrun-promote-schema` — manual local: Apple's Prod-equivalent dry-run (DESTRUCTIVE to your personal Dev).
- `just promote-schema` — release-tag CI only; do not run locally.

Never:
- Invoke `cktool`, `xcodegen`, `swift-format`, or `ckdb-schema-gen` directly for routine work.
- Edit files in `Backends/CloudKit/Sync/Generated/` (gitignored, regenerated).
- Edit `CloudKit/schema-prod-baseline.ckdb` by hand.
- Edit `Moolah.xcodeproj` (gitignored, regenerated).

## The additive-only invariant

Once a field is in Production, it is in Production forever. The wire-layer-deletion path is `// DEPRECATED`, not a line removal. This is enforced by `just check-schema-additive` against the committed Production baseline; CI fails any PR that violates it.

When in doubt, reach for `// DEPRECATED`.
````

- [ ] **Step 2: Verify the file is readable as a skill**

```bash
head -1 .claude/skills/modifying-cloudkit-schema/SKILL.md
test -d .claude/skills/modifying-cloudkit-schema && echo "skill dir ok"
```

Expected: prints `---` (the YAML frontmatter delimiter) and "skill dir ok".

- [ ] **Step 3: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 add .claude/skills/modifying-cloudkit-schema/SKILL.md
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 commit -m "docs(cloudkit): add modifying-cloudkit-schema skill"
```

---

## Task 21: Update `guides/SYNC_GUIDE.md` and `CLAUDE.md`

`guides/SYNC_GUIDE.md` is the architectural reference; replace its "Schema Evolution" section. `CLAUDE.md` gets a short pointer in the Build & Test section.

**Files:**
- Modify: `guides/SYNC_GUIDE.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Replace the existing "Schema Evolution" section in `guides/SYNC_GUIDE.md`**

Find the section heading (likely `## 11. Schema Evolution` or similar — search for "Schema Evolution"). Replace its body with:

```markdown
## 11. Schema Management

`CloudKit/schema.ckdb` is the canonical source of truth for the CloudKit
schema. It is hand-authored, reviewed in PRs as plain text, and is the only
file a developer hand-edits when CloudKit fields change. The Swift wire
layer (`Backends/CloudKit/Sync/Generated/<RecordType>CloudKitFields.swift`)
is generated from it by `tools/CKDBSchemaGen` as part of `just generate`,
and CloudKit Development and Production are populated from it by `cktool`.
**Never** treat a live CloudKit environment, an exported file, or a
generated Swift file as the source of truth.

For procedural detail (how to add/remove/rename a field, what to do about
specific compile errors), see the `modifying-cloudkit-schema` skill in
`.claude/skills/`.

### Pipeline

```
schema.ckdb ──► ckdb-schema-gen ──► Generated/  ──► *Record+CloudKit.swift  ──► CKRecord
            │                       (wire struct)    (adapter, thin)
            │
            │ cktool import-schema
            ▼
       CloudKit Production
            │
            │ cktool export-schema (after promote)
            ▼
       schema-prod-baseline.ckdb (committed)
```

### Production additive-only

Production schema only grows. Once a field or record type is in
Production, it is in Production forever. The Swift wire layer can forget
about a field via `// DEPRECATED` (the generator skips deprecated lines),
but the `.ckdb` line stays so `cktool import-schema` keeps re-declaring
the field on Production. Type changes are not allowed; rename = add new
+ deprecate old.

### CI gates

- **PR-time:** `just check-schema-additive` is a pure-text comparison of
  `CloudKit/schema.ckdb` against `CloudKit/schema-prod-baseline.ckdb`.
  Fails on any non-additive change. No CloudKit calls.
- **Release-tag:** `just verify-prod-matches-baseline` exports the live
  Production schema and diffs it against the committed baseline (catches
  manual dashboard edits or partial prior promotes); `just promote-schema`
  imports the new manifest to Production with `--validate`, exports the
  result back into the baseline file, and opens a follow-up PR with the
  refreshed baseline.

### `dryrun-promote-schema` and `verify-schema`

Both are manual local affordances, not CI gates. `verify-schema` imports
`.ckdb` to the developer's personal Dev container with `--validate`.
`dryrun-promote-schema` is Apple's Prod-equivalent dry-run
(`reset-schema && import-schema --validate`) and is destructive to the
developer's personal Dev — set `CKTOOL_ALLOW_DEV_RESET=1` to confirm.

### Constraints summary

- Production additive-only forever.
- No type changes.
- Indexes are one-way too: `QUERYABLE SEARCHABLE SORTABLE` on STRING is
  the safe default; narrowing in Production is brittle.
- The wire layer uses CloudKit-native types only (`String?`, `Int64?`,
  `Date?`, `Data?`). Domain richness lives in adapters.
```

- [ ] **Step 2: Update `CLAUDE.md`**

In `CLAUDE.md`, in the "Architecture & Constraints" section after the existing "Backend:" bullet (or another suitable place — match the surrounding style), add:

```markdown
- **CloudKit Schema:** `CloudKit/schema.ckdb` is the canonical CloudKit
  schema, hand-edited and reviewed in PRs. The Swift wire layer under
  `Backends/CloudKit/Sync/Generated/` is auto-generated by
  `tools/CKDBSchemaGen` as part of `just generate` and gitignored. See
  `guides/SYNC_GUIDE.md` §Schema Management for the architecture and the
  `modifying-cloudkit-schema` skill in `.claude/skills/` for the runbook.
```

- [ ] **Step 3: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 add guides/SYNC_GUIDE.md CLAUDE.md
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 commit -m "docs(cloudkit): document inverted schema pipeline in SYNC_GUIDE and CLAUDE.md"
```

---

## Task 22: Final verification, agent reviews, PR, and merge queue

Final gate before opening the PR. Runs every check, sweeps for warnings, invokes the relevant review agents, opens the PR, and queues it.

- [ ] **Step 1: Full clean rebuild from scratch**

```bash
rm -rf Backends/CloudKit/Sync/Generated/
just generate 2>&1 | tee .agent-tmp/final-generate.txt
ls Backends/CloudKit/Sync/Generated/ | wc -l
```

Expected: regeneration succeeds, 11 files in Generated/.

- [ ] **Step 2: Format-check + full test suite**

```bash
just format-check 2>&1 | tee .agent-tmp/final-format.txt
just test 2>&1 | tee .agent-tmp/final-test.txt
swift test --package-path tools/CKDBSchemaGen 2>&1 | tee .agent-tmp/final-skg-test.txt
just check-schema-additive 2>&1 | tee .agent-tmp/final-additive.txt
grep -iE 'failed|error:' .agent-tmp/final-test.txt .agent-tmp/final-skg-test.txt | head -20
```

Expected: every command exits 0; grep produces nothing.

- [ ] **Step 3: Warning sweep**

```bash
just build-mac 2>&1 | tee .agent-tmp/final-build.txt
grep -i warning .agent-tmp/final-build.txt | grep -v "Preview" | head
```

Expected: empty (or only Preview macro warnings, which are ignored per CLAUDE.md).

- [ ] **Step 4: Run the review agents**

Dispatch `code-review`, `concurrency-review`, and `sync-review` in parallel against the diff. Each agent returns a list of findings.

If any agent reports a Critical or High finding, fix it before opening the PR.

- [ ] **Step 5: Open the PR**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/cloudkit-schema-as-source-v2 push -u origin feat/cloudkit-schema-as-source-v2
gh pr create --title "feat(cloudkit): invert schema pipeline (.ckdb canonical, generate Swift wire layer)" --body "$(cat <<'EOF'
## Summary

`CloudKit/schema.ckdb` is now the canonical source of truth for the CloudKit schema. A new `tools/CKDBSchemaGen/` SPM executable parses it and emits one Swift wire struct per record type into `Backends/CloudKit/Sync/Generated/` (gitignored). Hand-written `*Record+CloudKit.swift` adapters become thin: recordID strategy + domain-type mapping only. A committed `CloudKit/schema-prod-baseline.ckdb` tracks current Production. PR-time CI runs a static additivity check (no CloudKit calls); release-tag CI promotes and refreshes the baseline via a follow-up PR.

Adds the `modifying-cloudkit-schema` skill so future agents (and humans) get an unambiguous runbook for adding/removing fields, decoding wire-struct compile errors, and the additive-only invariant.

## Why

Today's `CloudKit/schema.ckdb` declares only 4 of 11 record types in `RecordTypeRegistry.allTypes`, three of which are missing fields the running code already writes. Only `AccountRecord` declares `___recordID REFERENCE QUERYABLE`, so other types cannot be looked up by `recordName` in the iCloud Console. The pipeline today treats CloudKit Development as the de facto source of truth (lazy field creation through Debug builds), with `schema.ckdb` lagging behind as a stale export — exactly the wrong direction. This PR inverts it.

Implements the design in `plans/2026-04-25-cloudkit-schema-as-source-of-truth-design.md` ([#471](https://github.com/ajsutton/moolah-native/pull/471)).

## What changes

- **New SPM tool** at `tools/CKDBSchemaGen/` — parser, wire-struct generator, additivity checker, CLI.
- **Rewritten** `CloudKit/schema.ckdb` — all 11 record types with bare names (no CD_), complete fields, `___recordID REFERENCE QUERYABLE` everywhere.
- **New** `CloudKit/schema-prod-baseline.ckdb` — committed snapshot of current Production (empty / Users-only since v2 has never been promoted).
- **Refactored** all 11 hand-written `*Record+CloudKit.swift` adapters to use the generated wire structs.
- **Justfile**: `just generate` now runs `ckdb-schema-gen` before `xcodegen`; new `just check-schema-additive`, `just dryrun-promote-schema`, `just verify-prod-matches-baseline`. `just verify-schema` repurposed as a manual local convenience.
- **CI**: re-enabled the schema CI job, pointed at the new static additivity check (no CloudKit credentials needed). Added a `verify-prod-matches-baseline` step before `promote-schema` in the TestFlight workflow. `promote-schema` now exports Prod after promote and opens a follow-up PR refreshing the baseline.
- **Skill** `.claude/skills/modifying-cloudkit-schema/` — runbook for future schema changes.
- **Docs**: `guides/SYNC_GUIDE.md` §11 rewritten as "Schema Management"; `CLAUDE.md` gets a short pointer.

## Manual steps after merge

The first release tag after this PR merges runs `just promote-schema` automatically (TestFlight workflow). That promotion publishes the new manifest as the entire v2 Production schema (v2 has never been promoted) and the post-promote export becomes the first non-trivial baseline, refreshed via a follow-up PR.

## Test plan

- [ ] CI's `schema-check` job passes (static additivity over the committed empty baseline).
- [ ] `MoolahTests/Backends/CloudKit/RoundTripTests` passes for all 11 record types.
- [ ] `tools/CKDBSchemaGen/Tests/` parser/generator/additivity tests pass.
- [ ] `just format-check` passes.
- [ ] `just test` passes.
- [ ] No new compiler warnings (per CLAUDE.md pre-commit checklist).
- [ ] Code-review, concurrency-review, sync-review agents return no Critical/High findings.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Note the PR URL printed by `gh pr create`.

- [ ] **Step 6: Add to merge queue**

Per project convention every PR opened goes through the merge-queue skill. Hand off to the merge-queue skill / `merge-queue-manager` agent with the PR number from Step 5.

```bash
~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add <PR-NUMBER>
~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh status
```

Expected: `added #<PR>` and the daemon shows the PR in the queue.

---

## Self-review

**Spec coverage check** (each §2 deliverable maps to at least one task):

- ✅ Rewrite `CloudKit/schema.ckdb`: Task 2.
- ✅ New `CloudKit/schema-prod-baseline.ckdb`: Task 3.
- ✅ New SPM package `tools/CKDBSchemaGen/`: Tasks 4–9.
- ✅ Generated `Backends/CloudKit/Sync/Generated/` directory: Task 1 (gitignore) + Task 10 (regen wired into `just generate`).
- ✅ Refactored 11 `*Record+CloudKit.swift` files: Tasks 11–16.
- ✅ Updated `Justfile`: Tasks 10 + 18.
- ✅ New skill `.claude/skills/modifying-cloudkit-schema/SKILL.md`: Task 20.
- ✅ Updated `guides/SYNC_GUIDE.md`: Task 21.
- ✅ Updated `CLAUDE.md`: Task 21.
- ✅ Updated CI workflow: Task 19.
- ✅ Single PR: Task 22.

**Type / signature consistency:**

- `CloudKitRecordConvertible.toCKRecord(in:)` and `static var recordType` used consistently across all adapter refactors.
- `RecordTypeRegistry.allTypes` referenced only when adding a new record type (Task 20 skill instructions); not modified in this PR.
- Wire-struct names always `<RecordType>CloudKitFields`. Memberwise init parameter ordering matches `.ckdb` declaration order; round-trip tests use the same shapes.
- `Generator.File` type from Task 7 is consumed by Task 9's CLI; both use the same path/contents pair.

**Placeholders:** none.

**Open questions surfaced for the implementer:**

1. The exact init signatures of `ProfileRecord`, `CategoryRecord`, `EarmarkBudgetItemRecord`, `EarmarkRecord`, `TransactionLegRecord`, `InvestmentValueRecord`, `ImportRuleRecord`, `CSVImportProfileRecord`, and `InstrumentRecord` are best-effort based on the `Domain/Models/` shape inferred from current `*Record+CloudKit.swift` files. When implementing Tasks 12–16, open each domain model file first; if the constructor differs, adjust the test sites and the adapter's read path to match the actual init shape — do not change the public init.
2. The cktool export format for an empty container (Task 3 step 2). If `cktool export-schema` against an empty container errors instead of emitting a minimal schema, capture the error in `.agent-tmp/` and either commit a hand-authored placeholder (just `DEFINE SCHEMA` plus the `Users` system type) or treat the absence as acceptable for the first run.
3. The TestFlight workflow may already have `permissions: contents: write` somewhere; if so, do not duplicate it in Task 19 step 2 — just ensure the resulting permissions set is `contents: write` and `pull-requests: write`.
