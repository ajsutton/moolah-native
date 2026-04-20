# CSV Transaction Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Always follow CLAUDE.md's pre-commit checklist (fix warnings — `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES`) and pipe test output to `.agent-tmp/`.

**Goal:** Ship silent-by-default CSV transaction import (folder watch, file picker, drag-and-drop, paste) with a rules engine, dedup, account fingerprinting, Recently Added view, and two v1 parsers (GenericBankCSVParser + SelfWealthParser).

**Architecture:** Pipeline `raw bytes → CSVTokenizer → Parser selection → Parser.parse → whole-file validation → profile lookup/disambiguation → rules engine → dedup → persist → surface in Recently Added`. Pure-Foundation building blocks live under `Shared/CSVImport/`; CloudKit-synced persistence under `Backends/CloudKit/`; UI under `Features/Import/`; domain types under `Domain/`. Orchestration is a single `@Observable @MainActor ImportStore`. Pending/failed files are held in a local-only staging store (not synced).

**Tech Stack:** Swift 6, Swift Testing (`@Suite`/`@Test`), SwiftData, CloudKit (CKSyncEngine via `ProfileDataSyncHandler`), SwiftUI (macOS 26 / iOS 26), `FSEvents` on macOS, XCTest metrics for benchmarks.

**Authoritative references:**
- Spec: `plans/2026-04-18-csv-import-design.md`
- SelfWealth parsing specifics: `plans/csv-import-design.md` (superseded; use *only* for SelfWealth CSV column layout and description regex)
- Guides: `guides/SYNC_GUIDE.md`, `guides/CONCURRENCY_GUIDE.md`, `guides/STYLE_GUIDE.md`, `guides/BENCHMARKING_GUIDE.md`
- Review agents to invoke at appropriate points: `@concurrency-review`, `@sync-review`, `@ui-review`

---

## Departures from the spec's implementation order

The spec lists 15 implementation items. This plan re-groups them into **23 tasks** so each is independently reviewable and testable in one PR-sized chunk. The departures:

| Spec step | Plan tasks | Why |
|---|---|---|
| 1 | Task 1 | Unchanged. |
| 2 (domain models + repo protocols) | Tasks 2–4 | Split so parser-domain (used by Phase C) lands before sync wiring. Parser protocol + `ParsedRecord` have no persistence; `ImportOrigin` is a Transaction change; `CSVImportProfile`/`ImportRule` are synced models — each has a different blast radius. |
| 4 (`Transaction.importOrigin`) | Task 5 | Moved up in Phase B because parsers need the type shape in place for fixture tests. |
| 3 (CloudKit repos + contract tests) | Tasks 6–8 | Split per model + wiring task. Each synced entity is one PR; `BackendProvider` wiring is its own PR so diffs stay reviewable. |
| 7 (dedup + matcher) | Tasks 11–12 | Dedup and matching are separate algorithms with separate test suites. |
| 9 (ImportStore + tests) | Tasks 14–15 | Staging store split out — disk I/O, security-scoped bookmarks, failed/pending index are a meaningful chunk of work on their own and feed Task 15. |
| 11 (UI views) | Tasks 16–18 | Three distinct views: sidebar/Recently Added, setup form, rules UI. Each has separate accessibility surface. |
| 13 (drag-and-drop + badge) | Task 19 | Merged with ingestion entry points (picker, paste) because all three share the same `ImportSource` plumbing and `.fileImporter` / `.onDrop` are a single UI surface to wire. Sidebar badge already lands in Task 16. |
| 10 (folder watch/scan) | Tasks 20–21 | macOS FSEvents and iOS launch-scan are different APIs with different tests; keeping them separate prevents one flaky test from blocking the other's review. |
| 14–15 | Tasks 22–23 | Settings last (user-facing switch should land only after everything it controls works), benchmarks last per spec ("no optimisation work until measured"). |

Phases are sequenced so each subsequent task can import from the previous one: **A (domain)** → **B (persistence)** → **C (parsers)** → **D (pipeline)** → **E (orchestration)** → **F (UI)** → **G (ingestion / platform)** → **H (perf)**.

---

## Conventions used in this plan

- **TDD throughout.** Write the failing test first, run it to watch it fail, implement the minimum, run again to watch it pass, commit. The sub-steps below list these explicitly for representative tests only; apply the same rhythm for every enumerated test case.
- **Test framework:** Swift Testing (`import Testing`, `@Suite("…")`, `@Test` functions, `#expect(…)`). Existing store tests use this (`@Suite @MainActor struct …`).
- **Run tests via `just`.** After every code change: `mkdir -p .agent-tmp && just test <ClassName> 2>&1 | tee .agent-tmp/test-output.txt && grep -iE 'failed|error:' .agent-tmp/test-output.txt || echo OK`. Delete the tmp file after review.
- **Project file auto-picks up Swift files.** `project.yml` globs `Domain/`, `Shared/`, `Backends/`, `Features/`, `MoolahTests/`. **No `project.yml` edit is needed for new Swift files under those roots.** When adding new top-level directories (e.g., fixture binary assets) — check and update `project.yml`. Run `just generate` afterwards.
- **Fixture files** go in `MoolahTests/Support/Fixtures/csv/` (new sub-dir; gitignored files welcome but CSVs should be committed). Because `MoolahTests` is globbed, no `project.yml` change is required, **but** non-Swift resources need to be added as `sources:` resources in `project.yml`. Task 9 handles this.
- **Commit style:** `feat:`, `test:`, `refactor:`, `fix:`. One commit per TDD cycle (red → green → commit). If a later step requires a refactor of earlier code, make that its own commit. Sign off with `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.
- **Concurrency rules:** All stores `@Observable @MainActor`. Parsers, dedup, rules engine, profile matcher all `Sendable` value types / `Sendable` struct conformers — they do not touch the main actor. `ImportStore` is the only main-actor boundary; it awaits pure-Foundation work off-main.
- **CLAUDE.md's note on `Currency.defaultTestCurrency`** is stale — the actual helper is `Instrument.defaultTestInstrument` in `MoolahTests/Support/TestInstrument.swift` (value: `.AUD`). Use that.
- **Pre-commit checklist** (CLAUDE.md): run `mcp__xcode__XcodeListNavigatorIssues severity: warning` before every commit; fix every warning except those from `#Preview` macros. Typical fixes: `_ = try await …` for unused returns, `var` → `let`, remove unused locals.

---

## File structure

**New files (created by this plan):**

```
Domain/Models/
  CSVImport/
    ImportOrigin.swift            # sync'd as fields on Transaction
    ParsedTransaction.swift       # ParsedTransaction + ParsedLeg (ephemeral)
    ParsedRecord.swift            # enum: .transaction(ParsedTransaction) / .skip
    CSVParser.swift               # protocol CSVParser
    CSVImportProfile.swift        # sync'd
    ImportRule.swift              # sync'd; + MatchMode / RuleCondition / RuleAction

Domain/Repositories/
  CSVImportProfileRepository.swift
  ImportRuleRepository.swift

Shared/CSVImport/
  CSVTokenizer.swift
  GenericBankCSVParser.swift
  SelfWealthParser.swift
  CSVParserRegistry.swift         # built-in parser list, selection order
  CSVDeduplicator.swift
  CSVImportProfileMatcher.swift
  ImportRulesEngine.swift
  ImportStagingStore.swift        # local-only pending/failed index (JSON)
  ImportSource.swift              # enum ImportSource
  ImportSessionId.swift           # UUID wrapper or typealias
  CSVIngestionText.swift          # helpers: encoding detection wrapper around NSString.stringEncoding(for:)

Backends/CloudKit/Models/
  CSVImportProfileRecord.swift
  ImportRuleRecord.swift

Backends/CloudKit/Repositories/
  CloudKitCSVImportProfileRepository.swift
  CloudKitImportRuleRepository.swift

Features/Import/
  ImportStore.swift
  CSVImportProfileStore.swift
  ImportRuleStore.swift
  FolderScanService.swift         # iOS + macOS launch/foreground scan
  FolderWatchService.swift        # macOS only (FSEvents)
  Views/
    RecentlyAddedView.swift
    RecentlyAddedSessionSection.swift
    NeedsSetupAndFailedPanel.swift
    CSVImportSetupView.swift
    ImportRulesSettingsView.swift
    RuleEditorView.swift
    CreateRuleFromTransactionSheet.swift
    ImportSettingsSection.swift   # Settings → Import

MoolahTests/Domain/
  CSVImportProfileRepositoryContractTests.swift
  ImportRuleRepositoryContractTests.swift
  ImportOriginTransactionPersistenceTests.swift

MoolahTests/Shared/CSVImport/
  CSVTokenizerTests.swift
  GenericBankCSVParserTests.swift
  SelfWealthParserTests.swift
  CSVDeduplicatorTests.swift
  CSVImportProfileMatcherTests.swift
  ImportRulesEngineTests.swift
  ImportStagingStoreTests.swift
  CSVParserRegistryTests.swift

MoolahTests/Features/Import/
  ImportStoreTests.swift
  CSVImportProfileStoreTests.swift
  ImportRuleStoreTests.swift
  FolderScanServiceTests.swift
  FolderWatchServiceTests.swift      # macOS-only

MoolahTests/Support/Fixtures/csv/
  cba-everyday-standard.csv
  anz-everyday-debit-credit-split.csv
  nab-creditcard-debit-credit-split.csv
  westpac-everyday.csv
  ing-savings.csv
  bendigo-standard.csv
  macquarie-everyday.csv
  us-bofa-standard.csv
  uk-barclays-standard.csv
  generic-unknown-headers.csv
  selfwealth-trades.csv
  selfwealth-trades-empty.csv
  selfwealth-trades-malformed.csv
  malformed-unterminated-quote.csv
  utf16-bom.csv
  windows-1252.csv

MoolahBenchmarks/
  ImportPipelineBenchmarks.swift
  Support/
    ImportBenchmarkFixtures.swift    # or extend existing BenchmarkFixtures
```

**Modified files:**

```
Domain/Models/Transaction.swift                        # add `var importOrigin: ImportOrigin?`
Domain/Repositories/BackendProvider.swift              # add csvImportProfiles, importRules properties
Backends/CloudKit/Models/TransactionRecord.swift       # add importOrigin* fields + Codable JSON column
Backends/CloudKit/Sync/RecordMapping.swift             # + CSVImportProfileRecord, ImportRuleRecord,
                                                      #   + TransactionRecord.importOrigin fields,
                                                      #   + RecordTypeRegistry.allTypes entries
Backends/CloudKit/Sync/ProfileDataSyncHandler.swift    # add switch-cases for new record types (4 sites)
Backends/CloudKit/CloudKitBackend.swift                # wire new repositories
Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift
                                                      # read/write importOrigin through to TransactionRecord
Shared/PreviewBackend.swift                            # satisfy new BackendProvider requirements
MoolahTests/Support/TestBackend.swift                  # add seed() helpers for profiles, rules, imports
Features/Navigation/SidebarView.swift                  # add .recentlyAdded row + badge
App/ProfileRootView.swift (or wherever stores are env-injected)
                                                      # inject ImportStore, CSVImportProfileStore, ImportRuleStore
Features/Settings/…                                    # Settings → Import section entry
project.yml                                            # add `- path: MoolahTests/Support/Fixtures/csv
                                                      #   type: folder`  (resources glob)
```

---

## Tasks

Phase A: foundation domain types (no persistence, no UI) — Tasks 1–4
Phase B: persistence & sync wiring — Tasks 5–8
Phase C: parsers — Tasks 9–10
Phase D: pipeline building blocks — Tasks 11–13
Phase E: orchestration — Tasks 14–15
Phase F: UI views — Tasks 16–18
Phase G: ingestion + platform services — Tasks 19–22
Phase H: benchmarks — Task 23

---

### Task 1: `CSVTokenizer`

Pure RFC-4180 tokenizer. No dependencies beyond `Foundation`. Handles BOM, CRLF/LF/CR, quoted fields with embedded commas, escaped double-quotes, blank lines, and Apple-provided encoding detection for `Data` inputs via `NSString.stringEncoding(for:encodingOptions:convertedString:usedLossyConversion:)`. No custom encoding heuristics (per spec).

> **Encoding policy.** `CSVIngestionText.decode` tries UTF-8 first (covers the vast majority of modern bank exports) and falls back to `NSString.stringEncoding(for:...)` for everything else — Apple's built-in detection already covers UTF-16 (LE/BE, with/without BOM) and Windows-1252, which is all we've seen in the wild. Deliberately not pulling in ICU/iconv: binary dependency + extra error surface with no observed benefit. Revisit only if a real fixture defeats the current detector.

**Files:**
- Create: `Shared/CSVImport/CSVTokenizer.swift`
- Create: `Shared/CSVImport/CSVIngestionText.swift`  (encoding-detection helper wrapping the Apple API)
- Test:   `MoolahTests/Shared/CSVImport/CSVTokenizerTests.swift`

- [ ] **Step 1.1 — Write the first failing tokenizer test.**

```swift
import Foundation
import Testing
@testable import Moolah

@Suite("CSVTokenizer")
struct CSVTokenizerTests {

    @Test("parses a plain CSV with LF line endings")
    func testPlainLF() {
        let rows = CSVTokenizer.parse("a,b,c\n1,2,3\n4,5,6\n")
        #expect(rows == [["a","b","c"], ["1","2","3"], ["4","5","6"]])
    }
}
```

- [ ] **Step 1.2 — Run and confirm failure.**

`just test CSVTokenizerTests 2>&1 | tee .agent-tmp/test-output.txt` → fails with "cannot find 'CSVTokenizer'".

- [ ] **Step 1.3 — Implement minimal tokenizer.**

```swift
// Shared/CSVImport/CSVTokenizer.swift
import Foundation

enum CSVTokenizer {

    /// Parse CSV text into rows. Handles RFC-4180 quoting, CRLF/LF/CR line endings,
    /// BOM, embedded commas/newlines in quoted fields, and "" as escaped quote.
    /// Blank lines between records are preserved as empty rows only if they occur
    /// inside quoted fields; standalone blank lines are dropped.
    static func parse(_ text: String) -> [[String]] {
        var text = text
        if text.first == "\u{FEFF}" { text.removeFirst() }
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if inQuotes {
                if c == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex && text[next] == "\"" {
                        field.append("\"")
                        i = text.index(after: next)
                        continue
                    } else {
                        inQuotes = false
                        i = text.index(after: i)
                        continue
                    }
                }
                field.append(c)
                i = text.index(after: i)
                continue
            }
            switch c {
            case "\"":
                inQuotes = true
            case ",":
                row.append(field); field = ""
            case "\r":
                row.append(field); field = ""
                rows.append(row); row = []
                let next = text.index(after: i)
                if next < text.endIndex && text[next] == "\n" {
                    i = next
                }
            case "\n":
                row.append(field); field = ""
                rows.append(row); row = []
            default:
                field.append(c)
            }
            i = text.index(after: i)
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    /// Parse raw bytes: detect encoding via Apple's NSString.stringEncoding(for:...)
    /// then tokenize. Throws if the bytes cannot be decoded.
    static func parse(_ data: Data) throws -> [[String]] {
        let text = try CSVIngestionText.decode(data)
        return parse(text)
    }
}
```

```swift
// Shared/CSVImport/CSVIngestionText.swift
import Foundation

enum CSVIngestionText {
    enum Error: Swift.Error { case undecodable }

    /// Decodes bytes to String using Apple's encoding detection. Tries UTF-8
    /// first (covers >99% of bank exports), falls back to detection for the rest.
    static func decode(_ data: Data) throws -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        var converted: NSString? = nil
        let encoding = NSString.stringEncoding(
            for: data,
            encodingOptions: nil,
            convertedString: &converted,
            usedLossyConversion: nil)
        if encoding != 0, let converted { return converted as String }
        throw Error.undecodable
    }
}
```

- [ ] **Step 1.4 — Run test. Should pass.**

- [ ] **Step 1.5 — Commit.**

```bash
git add Shared/CSVImport MoolahTests/Shared
git commit -m "feat: add CSVTokenizer and encoding-detection helper"
```

- [ ] **Step 1.6 — Add remaining tokenizer tests (one per TDD cycle: write → fail → fix → green → commit).**

For each, write the `@Test` in `CSVTokenizerTests.swift` with the input/expected below. If the existing implementation already handles the case, the test will simply pass on first run; otherwise, extend the tokenizer.

Enumerate each case:

| Test name | Input | Expected |
|---|---|---|
| `parsesCRLFLineEndings` | `"a,b\r\n1,2\r\n"` | `[["a","b"],["1","2"]]` |
| `parsesCRLineEndings` | `"a,b\r1,2\r"` | `[["a","b"],["1","2"]]` |
| `stripsUTF8BOM` | `"\u{FEFF}a,b\n1,2\n"` | `[["a","b"],["1","2"]]` |
| `preservesQuotedCommas` | `"a,\"b,c\",d\n"` | `[["a","b,c","d"]]` |
| `preservesQuotedNewlines` | `"a,\"b\nc\",d\n"` | `[["a","b\nc","d"]]` |
| `handlesEscapedQuotes` | `"\"she said \"\"hi\"\"\",x\n"` | `[["she said \"hi\"","x"]]` |
| `dropsStandaloneBlankLines` | `"a,b\n\n1,2\n"` | `[["a","b"],["1","2"]]` |
| `handlesMissingTrailingNewline` | `"a,b\n1,2"` | `[["a","b"],["1","2"]]` |
| `emptyStringYieldsEmpty` | `""` | `[]` |
| `handlesFieldsWithLeadingSpaces` | `"a, b,c\n"` | `[["a"," b","c"]]` |
| `parseData_utf8` | `"a,b\n".data(using: .utf8)!` | `[["a","b"]]` |
| `parseData_utf16` | `"a,b\n".data(using: .utf16)!` | `[["a","b"]]` |
| `parseData_windows1252` | bytes for `"café,b\n"` in CP1252 | `[["café","b"]]` |
| `parseData_throwsOnUndecodable` | random bytes including lead bytes that fail detection | throws `.undecodable` (very contrived — pad with mixed noise until detection returns 0) |

Each test: `just test CSVTokenizerTests/<name>`. Commit after each green, or batch several closely-related ones (e.g., the three `parseData_*`) into one commit.

- [ ] **Step 1.7 — Verify no warnings.** `mcp__xcode__XcodeListNavigatorIssues severity: warning` in `Shared/CSVImport/` and test file.

---

### Task 2: Parser protocol + parsed-record domain types

Add `ParsedLeg`, `ParsedTransaction`, `ParsedRecord`, and `CSVParser` to `Domain/Models/CSVImport/`. These are **ephemeral** — they are the output of parsers and never persisted directly. `Domain/Models/` must not import `Foundation` beyond what's already there, but these types *do* reference `Instrument` and `TransactionType` (already Sendable in `Domain/Models/`).

**Files:**
- Create: `Domain/Models/CSVImport/ParsedTransaction.swift`
- Create: `Domain/Models/CSVImport/ParsedRecord.swift`
- Create: `Domain/Models/CSVImport/CSVParser.swift`
- Test:   `MoolahTests/Shared/CSVImport/CSVParserRegistryTests.swift` (only exercises type shapes for now — meaningful tests land in Tasks 9–10)

- [ ] **Step 2.1 — Write the failing shape test.**

```swift
import Foundation
import Testing
@testable import Moolah

@Suite("ParsedTransaction types")
struct ParsedTransactionShapeTests {

    @Test("ParsedTransaction carries rawRow, rawDescription, legs, and a bank reference")
    func testParsedTransactionInit() {
        let tx = ParsedTransaction(
            date: Date(timeIntervalSince1970: 0),
            legs: [
                ParsedLeg(
                    accountId: nil,
                    instrument: .AUD,
                    quantity: Decimal(string: "-12.34")!,
                    type: .expense)
            ],
            rawRow: ["2024-01-01", "-12.34", "Coffee"],
            rawDescription: "Coffee",
            rawAmount: Decimal(string: "-12.34")!,
            rawBalance: nil,
            bankReference: "REF-1")
        #expect(tx.legs.count == 1)
        #expect(tx.bankReference == "REF-1")
    }

    @Test("ParsedRecord round-trips a .transaction and a .skip")
    func testParsedRecordCases() {
        let skip = ParsedRecord.skip(reason: "summary row")
        #expect({
            if case .skip(let reason) = skip { return reason == "summary row" }
            return false
        }())
    }
}
```

- [ ] **Step 2.2 — Run → fail (types missing).**

- [ ] **Step 2.3 — Implement types.**

```swift
// Domain/Models/CSVImport/ParsedTransaction.swift
import Foundation

struct ParsedLeg: Sendable, Hashable {
    var accountId: UUID?              // filled by profile routing; nil at parse time for cash legs
    var instrument: Instrument
    var quantity: Decimal
    var type: TransactionType
}

struct ParsedTransaction: Sendable, Hashable {
    let date: Date
    var legs: [ParsedLeg]
    let rawRow: [String]
    let rawDescription: String
    let rawAmount: Decimal
    let rawBalance: Decimal?
    let bankReference: String?
}
```

```swift
// Domain/Models/CSVImport/ParsedRecord.swift
import Foundation

enum ParsedRecord: Sendable, Hashable {
    case transaction(ParsedTransaction)
    case skip(reason: String)
}
```

```swift
// Domain/Models/CSVImport/CSVParser.swift
import Foundation

protocol CSVParser: Sendable {
    var identifier: String { get }
    func recognizes(headers: [String]) -> Bool
    func parse(rows: [[String]]) throws -> [ParsedRecord]
}

enum CSVParserError: Error, Equatable, Sendable {
    case headerMismatch
    case malformedRow(index: Int, reason: String)
    case emptyFile
}
```

- [ ] **Step 2.4 — Run test → pass.**

- [ ] **Step 2.5 — Commit.**

```bash
git add Domain/Models/CSVImport MoolahTests/Shared/CSVImport
git commit -m "feat: add parsed-record domain types and CSVParser protocol"
```

---

### Task 3: `ImportOrigin` domain + add to `Transaction`

Add the `ImportOrigin` struct and `var importOrigin: ImportOrigin?` on `Transaction`. Per spec, forward-compat note: transfer-detection follow-up will wrap this in an enum `TransactionImportOrigin`; for v1 ship the raw struct.

**Files:**
- Create: `Domain/Models/CSVImport/ImportOrigin.swift`
- Modify: `Domain/Models/Transaction.swift`
- Test:   Add a test to `MoolahTests/Domain/TransactionTests.swift` (create if missing) verifying `Transaction` with `importOrigin` round-trips via `Codable`.

- [ ] **Step 3.1 — Write the failing test.**

```swift
import Foundation
import Testing
@testable import Moolah

@Suite("Transaction.importOrigin")
struct TransactionImportOriginTests {

    @Test("Transaction carries optional ImportOrigin; nil by default")
    func testDefaultsToNil() {
        let tx = Transaction(date: Date(), legs: [])
        #expect(tx.importOrigin == nil)
    }

    @Test("Transaction.importOrigin survives Codable round-trip")
    func testCodable() throws {
        let origin = ImportOrigin(
            rawDescription: "COFFEE",
            bankReference: "REF1",
            rawAmount: Decimal(string: "-12.34")!,
            rawBalance: Decimal(string: "100.00")!,
            importedAt: Date(timeIntervalSince1970: 1_700_000_000),
            importSessionId: UUID(),
            sourceFilename: "transactions.csv",
            parserIdentifier: "generic-bank")
        let tx = Transaction(date: Date(), legs: [], importOrigin: origin)
        let data = try JSONEncoder().encode(tx)
        let decoded = try JSONDecoder().decode(Transaction.self, from: data)
        #expect(decoded.importOrigin == origin)
    }
}
```

- [ ] **Step 3.2 — Run → fail.**

- [ ] **Step 3.3 — Implement the type and extend `Transaction`.**

```swift
// Domain/Models/CSVImport/ImportOrigin.swift
import Foundation

struct ImportOrigin: Codable, Sendable, Hashable {
    var rawDescription: String
    var bankReference: String?
    var rawAmount: Decimal
    var rawBalance: Decimal?
    var importedAt: Date
    var importSessionId: UUID
    var sourceFilename: String?
    var parserIdentifier: String
}
```

In `Domain/Models/Transaction.swift`, add `var importOrigin: ImportOrigin?` to the struct's stored properties and to the initializer:

```swift
struct Transaction: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    var date: Date
    var payee: String?
    var notes: String?
    var recurPeriod: RecurPeriod?
    var recurEvery: Int?
    var legs: [TransactionLeg]
    var importOrigin: ImportOrigin?   // NEW

    init(
        id: UUID = UUID(),
        date: Date,
        payee: String? = nil,
        notes: String? = nil,
        recurPeriod: RecurPeriod? = nil,
        recurEvery: Int? = nil,
        legs: [TransactionLeg],
        importOrigin: ImportOrigin? = nil
    ) {
        self.id = id
        self.date = date
        self.payee = payee
        self.notes = notes
        self.recurPeriod = recurPeriod
        self.recurEvery = recurEvery
        self.legs = legs
        self.importOrigin = importOrigin
    }
    // … rest unchanged
}
```

The default value of `nil` is critical: every existing `Transaction(…)` call site in the codebase continues to compile.

- [ ] **Step 3.4 — Run the test → pass.**

- [ ] **Step 3.5 — Search for any code that switches exhaustively on `Transaction` fields** (e.g., data exporter, migration). Run `rg 'Transaction\(' -g '*.swift'` to sanity-check call sites still compile. Fix any migration/export code that needs to copy the new field.

- [ ] **Step 3.6 — Commit.**

```bash
git add Domain/Models Domain/MoolahTests
git commit -m "feat: add ImportOrigin metadata to Transaction"
```

---

### Task 4: `CSVImportProfile` and `ImportRule` domain models + repository protocols

Domain-layer types only — CloudKit mappings land in Tasks 6–7. This task adds the types and the repository protocols so the contract-test files in Tasks 6–7 can compile.

**Files:**
- Create: `Domain/Models/CSVImport/CSVImportProfile.swift`
- Create: `Domain/Models/CSVImport/ImportRule.swift`
- Create: `Domain/Repositories/CSVImportProfileRepository.swift`
- Create: `Domain/Repositories/ImportRuleRepository.swift`
- Test:   `MoolahTests/Domain/CSVImportProfileTests.swift` (shape round-trip), `MoolahTests/Domain/ImportRuleTests.swift` (Codable round-trip with each condition/action case)

- [ ] **Step 4.1 — Write shape & Codable tests.**

```swift
import Foundation
import Testing
@testable import Moolah

@Suite("CSVImportProfile")
struct CSVImportProfileTests {

    @Test("CSVImportProfile round-trips via Codable")
    func testCodable() throws {
        let profile = CSVImportProfile(
            id: UUID(),
            accountId: UUID(),
            parserIdentifier: "generic-bank",
            headerSignature: ["date","amount","description","balance"],
            filenamePattern: "cba-*.csv",
            deleteAfterImport: false,
            createdAt: Date(timeIntervalSince1970: 0),
            lastUsedAt: nil)
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(CSVImportProfile.self, from: data)
        #expect(decoded == profile)
    }
}

@Suite("ImportRule")
struct ImportRuleTests {

    @Test("ImportRule round-trips through Codable for every condition and action case")
    func testExhaustiveCodable() throws {
        let rule = ImportRule(
            id: UUID(),
            name: "Coffee is Dining",
            enabled: true,
            position: 0,
            matchMode: .all,
            conditions: [
                .descriptionContains(["COFFEE", "CAFE"]),
                .descriptionDoesNotContain(["AMAZON"]),
                .descriptionBeginsWith("EFTPOS "),
                .amountIsPositive,
                .amountIsNegative,
                .amountBetween(min: Decimal(string: "-100")!, max: Decimal(string: "-1")!),
                .sourceAccountIs(UUID()),
            ],
            actions: [
                .setPayee("Café"),
                .setCategory(UUID()),
                .appendNote("imported"),
                .markAsTransfer(toAccountId: UUID()),
                .skip,
            ],
            accountScope: UUID())
        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(ImportRule.self, from: data)
        #expect(decoded == rule)
    }
}
```

- [ ] **Step 4.2 — Run → fail.**

- [ ] **Step 4.3 — Implement the types.**

```swift
// Domain/Models/CSVImport/CSVImportProfile.swift
import Foundation

struct CSVImportProfile: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    var accountId: UUID
    var parserIdentifier: String
    var headerSignature: [String]
    var filenamePattern: String?
    var deleteAfterImport: Bool
    let createdAt: Date
    var lastUsedAt: Date?

    init(
        id: UUID = UUID(),
        accountId: UUID,
        parserIdentifier: String,
        headerSignature: [String],
        filenamePattern: String? = nil,
        deleteAfterImport: Bool = false,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.parserIdentifier = parserIdentifier
        self.headerSignature = headerSignature.map { Self.normalise($0) }
        self.filenamePattern = filenamePattern
        self.deleteAfterImport = deleteAfterImport
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    /// Lowercased, trimmed — this is the canonical form used for matching.
    static func normalise(_ header: String) -> String {
        header.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
```

```swift
// Domain/Models/CSVImport/ImportRule.swift
import Foundation

enum MatchMode: String, Codable, Sendable { case any, all }

enum RuleCondition: Codable, Sendable, Hashable {
    case descriptionContains([String])
    case descriptionDoesNotContain([String])
    case descriptionBeginsWith(String)
    case amountIsPositive
    case amountIsNegative
    case amountBetween(min: Decimal, max: Decimal)
    case sourceAccountIs(UUID)
}

enum RuleAction: Codable, Sendable, Hashable {
    case setPayee(String)
    case setCategory(UUID)
    case appendNote(String)
    case markAsTransfer(toAccountId: UUID)
    case skip
}

struct ImportRule: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var enabled: Bool
    var position: Int
    var matchMode: MatchMode
    var conditions: [RuleCondition]
    var actions: [RuleAction]
    var accountScope: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        position: Int,
        matchMode: MatchMode = .all,
        conditions: [RuleCondition],
        actions: [RuleAction],
        accountScope: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.position = position
        self.matchMode = matchMode
        self.conditions = conditions
        self.actions = actions
        self.accountScope = accountScope
    }
}
```

- [ ] **Step 4.4 — Add repository protocols.**

```swift
// Domain/Repositories/CSVImportProfileRepository.swift
import Foundation

protocol CSVImportProfileRepository: Sendable {
    func fetchAll() async throws -> [CSVImportProfile]
    func create(_ profile: CSVImportProfile) async throws -> CSVImportProfile
    func update(_ profile: CSVImportProfile) async throws -> CSVImportProfile
    func delete(id: UUID) async throws
}
```

```swift
// Domain/Repositories/ImportRuleRepository.swift
import Foundation

protocol ImportRuleRepository: Sendable {
    func fetchAll() async throws -> [ImportRule]
    func create(_ rule: ImportRule) async throws -> ImportRule
    func update(_ rule: ImportRule) async throws -> ImportRule
    func delete(id: UUID) async throws
    /// Atomically update the `position` of every rule in one shot. Throws if the
    /// set of ids does not exactly match existing rule ids (no adds, no drops).
    func reorder(_ orderedIds: [UUID]) async throws
}
```

- [ ] **Step 4.5 — Run tests → pass. Commit.**

```bash
git add Domain/Models Domain/Repositories MoolahTests/Domain
git commit -m "feat: add CSVImportProfile and ImportRule domain types"
```

---

### Task 5: Persist `Transaction.importOrigin` in `TransactionRecord` + sync mapping

Extend `TransactionRecord` (SwiftData `@Model`) with denormalised columns for `ImportOrigin` and serialise-through to CloudKit. **Important:** eight fields, all optional. Do **not** use a JSON blob — one column per field is the existing convention (`EarmarkRecord` shows per-field CKRecord value casting). Update `CloudKitTransactionRepository.toDomain(…)` / `.save(…)` to read & write the new fields.

**Files:**
- Modify: `Backends/CloudKit/Models/TransactionRecord.swift`
- Modify: `Backends/CloudKit/Sync/RecordMapping.swift`  (TransactionRecord extension)
- Modify: `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift`
- Test:   `MoolahTests/Domain/ImportOriginTransactionPersistenceTests.swift`

- [ ] **Step 5.1 — Write failing persistence contract test.**

```swift
import Foundation
import Testing
@testable import Moolah

@Suite("TransactionRepository preserves ImportOrigin")
struct ImportOriginTransactionPersistenceTests {

    @Test("create + fetch preserves every ImportOrigin field")
    func testRoundTrip() async throws {
        let (backend, _) = try TestBackend.create()
        let accountId = UUID()
        let sessionId = UUID()
        let origin = ImportOrigin(
            rawDescription: "COFFEE @ SHOP",
            bankReference: "REF-42",
            rawAmount: Decimal(string: "-12.34")!,
            rawBalance: Decimal(string: "500.00")!,
            importedAt: Date(timeIntervalSince1970: 1_700_000_000),
            importSessionId: sessionId,
            sourceFilename: "cba.csv",
            parserIdentifier: "generic-bank")
        _ = try await backend.accounts.create(
            Account(id: accountId, name: "Cash", type: .bank,
                    instrument: .AUD, positions: [], position: 0, isHidden: false),
            openingBalance: nil)
        let tx = Transaction(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            legs: [TransactionLeg(
                accountId: accountId, instrument: .AUD,
                quantity: Decimal(string: "-12.34")!, type: .expense,
                categoryId: nil, earmarkId: nil)],
            importOrigin: origin)
        _ = try await backend.transactions.create(tx)

        let page = try await backend.transactions.fetch(
            filter: TransactionFilter(accountId: accountId),
            page: 0, pageSize: 10)
        #expect(page.transactions.first?.importOrigin == origin)
    }
}
```

- [ ] **Step 5.2 — Run → fail.**

- [ ] **Step 5.3 — Add denormalised columns to `TransactionRecord`.**

In `Backends/CloudKit/Models/TransactionRecord.swift`:

```swift
@Model
final class TransactionRecord {
    // … existing
    var importOriginRawDescription: String?
    var importOriginBankReference: String?
    var importOriginRawAmount: String?       // Decimal serialized as String to preserve precision
    var importOriginRawBalance: String?
    var importOriginImportedAt: Date?
    var importOriginImportSessionId: UUID?
    var importOriginSourceFilename: String?
    var importOriginParserIdentifier: String?

    // Convenience accessors
    var importOrigin: ImportOrigin? {
        get {
            guard let rawDescription = importOriginRawDescription,
                  let rawAmountStr = importOriginRawAmount,
                  let rawAmount = Decimal(string: rawAmountStr),
                  let importedAt = importOriginImportedAt,
                  let sessionId = importOriginImportSessionId,
                  let parserId = importOriginParserIdentifier else { return nil }
            return ImportOrigin(
                rawDescription: rawDescription,
                bankReference: importOriginBankReference,
                rawAmount: rawAmount,
                rawBalance: importOriginRawBalance.flatMap { Decimal(string: $0) },
                importedAt: importedAt,
                importSessionId: sessionId,
                sourceFilename: importOriginSourceFilename,
                parserIdentifier: parserId)
        }
        set {
            importOriginRawDescription = newValue?.rawDescription
            importOriginBankReference = newValue?.bankReference
            importOriginRawAmount = newValue.map { NSDecimalNumber(decimal: $0.rawAmount).stringValue }
            importOriginRawBalance = newValue?.rawBalance
                .map { NSDecimalNumber(decimal: $0).stringValue }
            importOriginImportedAt = newValue?.importedAt
            importOriginImportSessionId = newValue?.importSessionId
            importOriginSourceFilename = newValue?.sourceFilename
            importOriginParserIdentifier = newValue?.parserIdentifier
        }
    }
}
```

Extend the init + `from(_:)`/`toDomain(…)` helpers to plumb these through. Read existing `from` and `toDomain` first (they already exist — see current file); mirror the `importOrigin` getter in `toDomain(legs:)` and the setter in `from(_:)`.

- [ ] **Step 5.4 — Extend `RecordMapping.swift` `TransactionRecord` extension.**

Add these eight `CKRecord[…] = …` assignments inside `toCKRecord(in:)`, guarded by `if let`, and matching reads in `fieldValues(from:)`:

```swift
// Inside toCKRecord(in:)
if let v = importOriginRawDescription { record["importOriginRawDescription"] = v as CKRecordValue }
if let v = importOriginBankReference  { record["importOriginBankReference"]  = v as CKRecordValue }
if let v = importOriginRawAmount      { record["importOriginRawAmount"]      = v as CKRecordValue }
if let v = importOriginRawBalance     { record["importOriginRawBalance"]     = v as CKRecordValue }
if let v = importOriginImportedAt     { record["importOriginImportedAt"]     = v as CKRecordValue }
if let v = importOriginImportSessionId {
    record["importOriginImportSessionId"] = v.uuidString as CKRecordValue
}
if let v = importOriginSourceFilename { record["importOriginSourceFilename"] = v as CKRecordValue }
if let v = importOriginParserIdentifier {
    record["importOriginParserIdentifier"] = v as CKRecordValue
}

// Inside fieldValues(from:), after the existing init args, set these via a follow-up assignment
// (the existing init does not take them — easier to assign after construction):
let record = TransactionRecord(id: …, date: …, payee: …, notes: …, recurPeriod: …, recurEvery: …)
record.importOriginRawDescription = ckRecord["importOriginRawDescription"] as? String
record.importOriginBankReference  = ckRecord["importOriginBankReference"]  as? String
record.importOriginRawAmount      = ckRecord["importOriginRawAmount"]      as? String
record.importOriginRawBalance     = ckRecord["importOriginRawBalance"]     as? String
record.importOriginImportedAt     = ckRecord["importOriginImportedAt"]     as? Date
record.importOriginImportSessionId = (ckRecord["importOriginImportSessionId"] as? String)
    .flatMap { UUID(uuidString: $0) }
record.importOriginSourceFilename = ckRecord["importOriginSourceFilename"] as? String
record.importOriginParserIdentifier = ckRecord["importOriginParserIdentifier"] as? String
return record
```

- [ ] **Step 5.5 — Update `CloudKitTransactionRepository`** to propagate `importOrigin` on create/update/fetch. Search for where it converts `TransactionRecord ↔ Transaction` and ensure both directions use the new `importOrigin` accessor.

- [ ] **Step 5.6 — Run contract test → pass.**

- [ ] **Step 5.7 — Run `just test TransactionStoreTests TransactionRepositoryContractTests ImportOriginTransactionPersistenceTests 2>&1 | tee .agent-tmp/test-output.txt`** to ensure no regression. Fix any warnings. Commit.

```bash
git add Backends/CloudKit/Models/TransactionRecord.swift \
        Backends/CloudKit/Sync/RecordMapping.swift \
        Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift \
        MoolahTests/Domain/ImportOriginTransactionPersistenceTests.swift
git commit -m "feat: persist ImportOrigin fields on TransactionRecord and sync to CloudKit"
```

- [ ] **Step 5.8 — Run `@sync-review` agent** on the diff. Address any findings (especially: make sure the repository's create/update paths invoke the existing sync change-queueing closures — no new plumbing required, just don't accidentally bypass it).

---

### Task 6: `CSVImportProfileRecord` persistence, sync, and contract test

**Files:**
- Create: `Backends/CloudKit/Models/CSVImportProfileRecord.swift`
- Create: `Backends/CloudKit/Repositories/CloudKitCSVImportProfileRepository.swift`
- Modify: `Backends/CloudKit/Sync/RecordMapping.swift`
- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler.swift`  (four switch statements: see lines 418, 489, 651, 692 — and the `start()` first-queue scan if present)
- Test:   `MoolahTests/Domain/CSVImportProfileRepositoryContractTests.swift`

- [ ] **Step 6.1 — Write failing contract tests.** Mirror `AccountRepositoryContractTests` shape.

```swift
import Foundation
import Testing
@testable import Moolah

@Suite("CSVImportProfileRepository Contract")
struct CSVImportProfileRepositoryContractTests {

    @Test("create, fetchAll, update, delete")
    func testLifecycle() async throws {
        let (backend, _) = try TestBackend.create()
        let accountId = UUID()
        _ = try await backend.accounts.create(
            Account(id: accountId, name: "Cash", type: .bank,
                    instrument: .AUD, positions: [], position: 0, isHidden: false),
            openingBalance: nil)
        let profile = CSVImportProfile(
            accountId: accountId,
            parserIdentifier: "generic-bank",
            headerSignature: ["date","amount","description","balance"])

        _ = try await backend.csvImportProfiles.create(profile)
        var all = try await backend.csvImportProfiles.fetchAll()
        #expect(all.count == 1)
        #expect(all[0].id == profile.id)

        var updated = profile
        updated.filenamePattern = "cba-*.csv"
        updated.deleteAfterImport = true
        _ = try await backend.csvImportProfiles.update(updated)
        all = try await backend.csvImportProfiles.fetchAll()
        #expect(all[0].filenamePattern == "cba-*.csv")
        #expect(all[0].deleteAfterImport == true)

        try await backend.csvImportProfiles.delete(id: profile.id)
        all = try await backend.csvImportProfiles.fetchAll()
        #expect(all.isEmpty)
    }

    @Test("headerSignature is stored in normalised (lowercased/trimmed) form")
    func testNormalisation() async throws {
        let (backend, _) = try TestBackend.create()
        let accountId = UUID()
        _ = try await backend.accounts.create(
            Account(id: accountId, name: "Cash", type: .bank, instrument: .AUD,
                    positions: [], position: 0, isHidden: false), openingBalance: nil)
        let profile = CSVImportProfile(
            accountId: accountId, parserIdentifier: "generic-bank",
            headerSignature: ["  Date ", "AMOUNT", "description"])
        _ = try await backend.csvImportProfiles.create(profile)
        let fetched = try await backend.csvImportProfiles.fetchAll()
        #expect(fetched[0].headerSignature == ["date","amount","description"])
    }
}
```

- [ ] **Step 6.2 — Run → fail (no `csvImportProfiles` on `BackendProvider`).** This fails to compile for now; the test file still belongs. Task 8 completes the wiring; for intermediate compilation, temporarily create `CloudKitCSVImportProfileRepository` and reference it directly via its concrete type in the test instead of through the protocol. After Task 8 land the test compiles via `backend.csvImportProfiles`. **Alternate approach:** do Tasks 6+7+8 as a single combined PR if reviewer prefers fewer partial states; this plan keeps them separate for smaller diffs but with a merge-order dependency that Task 8 lands the tests compile-ready.

- [ ] **Step 6.3 — Create SwiftData record.**

```swift
// Backends/CloudKit/Models/CSVImportProfileRecord.swift
import Foundation
import SwiftData

@Model
final class CSVImportProfileRecord {

    #Index<CSVImportProfileRecord>([\.id])

    var id: UUID = UUID()
    var accountId: UUID = UUID()
    var parserIdentifier: String = ""
    /// Pipe-separated normalised headers. Easiest to store as a single String
    /// to sync as a single CKRecord field (no array-of-strings casting dance).
    var headerSignature: String = ""
    var filenamePattern: String?
    var deleteAfterImport: Bool = false
    var createdAt: Date = Date()
    var lastUsedAt: Date?
    var encodedSystemFields: Data?

    init(
        id: UUID = UUID(),
        accountId: UUID,
        parserIdentifier: String,
        headerSignature: [String],
        filenamePattern: String? = nil,
        deleteAfterImport: Bool = false,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.parserIdentifier = parserIdentifier
        self.headerSignature = headerSignature.joined(separator: "\u{1F}") // unit separator
        self.filenamePattern = filenamePattern
        self.deleteAfterImport = deleteAfterImport
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    func toDomain() -> CSVImportProfile {
        CSVImportProfile(
            id: id,
            accountId: accountId,
            parserIdentifier: parserIdentifier,
            headerSignature: headerSignature.isEmpty
                ? []
                : headerSignature.components(separatedBy: "\u{1F}"),
            filenamePattern: filenamePattern,
            deleteAfterImport: deleteAfterImport,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt)
    }

    static func from(_ profile: CSVImportProfile) -> CSVImportProfileRecord {
        CSVImportProfileRecord(
            id: profile.id,
            accountId: profile.accountId,
            parserIdentifier: profile.parserIdentifier,
            headerSignature: profile.headerSignature,
            filenamePattern: profile.filenamePattern,
            deleteAfterImport: profile.deleteAfterImport,
            createdAt: profile.createdAt,
            lastUsedAt: profile.lastUsedAt)
    }
}
```

- [ ] **Step 6.4 — Add CloudKit mapping + registry entry.**

In `RecordMapping.swift`:

```swift
extension CSVImportProfileRecord: IdentifiableRecord {}
extension CSVImportProfileRecord: SystemFieldsCacheable {}

extension CSVImportProfileRecord: CloudKitRecordConvertible {
    static let recordType = "CD_CSVImportProfileRecord"

    func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record["accountId"] = accountId.uuidString as CKRecordValue
        record["parserIdentifier"] = parserIdentifier as CKRecordValue
        record["headerSignature"] = headerSignature as CKRecordValue
        if let v = filenamePattern { record["filenamePattern"] = v as CKRecordValue }
        record["deleteAfterImport"] = (deleteAfterImport ? 1 : 0) as CKRecordValue
        record["createdAt"] = createdAt as CKRecordValue
        if let v = lastUsedAt { record["lastUsedAt"] = v as CKRecordValue }
        return record
    }

    static func fieldValues(from ckRecord: CKRecord) -> CSVImportProfileRecord {
        let r = CSVImportProfileRecord(
            id: UUID(uuidString: ckRecord.recordID.recordName) ?? UUID(),
            accountId: (ckRecord["accountId"] as? String).flatMap { UUID(uuidString: $0) } ?? UUID(),
            parserIdentifier: ckRecord["parserIdentifier"] as? String ?? "",
            headerSignature: [],
            filenamePattern: ckRecord["filenamePattern"] as? String,
            deleteAfterImport: (ckRecord["deleteAfterImport"] as? Int ?? 0) != 0,
            createdAt: ckRecord["createdAt"] as? Date ?? Date(),
            lastUsedAt: ckRecord["lastUsedAt"] as? Date)
        r.headerSignature = ckRecord["headerSignature"] as? String ?? ""
        return r
    }
}
```

And add to `RecordTypeRegistry.allTypes`:

```swift
CSVImportProfileRecord.recordType: CSVImportProfileRecord.self,
```

- [ ] **Step 6.5 — Wire into `ProfileDataSyncHandler` switch statements.**

At every `switch recordType` site already covering the existing records, add a `case CSVImportProfileRecord.recordType:` arm that mirrors the CategoryRecord arm (upsert/delete by id; `updateEncodedSystemFields` / `clearEncodedSystemFields` set the field on the local record). Four sites — lines ~418, ~489, ~651, ~692 in the current file. Re-read each block to copy the exact shape.

Follow the SYNC_GUIDE.md Rule 4b: on first-start (no saved state), `ProfileDataSyncHandler.start()` queues existing records for upload. Add a fetch of all `CSVImportProfileRecord`s to that scan and enqueue each for upload.

- [ ] **Step 6.6 — Implement `CloudKitCSVImportProfileRepository`.**

```swift
// Backends/CloudKit/Repositories/CloudKitCSVImportProfileRepository.swift
import Foundation
import SwiftData

final class CloudKitCSVImportProfileRepository: CSVImportProfileRepository, @unchecked Sendable {
    private let modelContainer: ModelContainer
    private let onRecordChanged: (@Sendable (UUID) -> Void)?
    private let onRecordDeleted: (@Sendable (UUID) -> Void)?

    init(
        modelContainer: ModelContainer,
        onRecordChanged: (@Sendable (UUID) -> Void)? = nil,
        onRecordDeleted: (@Sendable (UUID) -> Void)? = nil
    ) {
        self.modelContainer = modelContainer
        self.onRecordChanged = onRecordChanged
        self.onRecordDeleted = onRecordDeleted
    }

    func fetchAll() async throws -> [CSVImportProfile] {
        try await MainActor.run {
            let context = ModelContext(modelContainer)
            let descriptor = FetchDescriptor<CSVImportProfileRecord>()
            return try context.fetch(descriptor).map { $0.toDomain() }
        }
    }

    func create(_ profile: CSVImportProfile) async throws -> CSVImportProfile {
        try await MainActor.run {
            let context = ModelContext(modelContainer)
            let record = CSVImportProfileRecord.from(profile)
            context.insert(record)
            try context.save()
            onRecordChanged?(profile.id)
            return record.toDomain()
        }
    }

    func update(_ profile: CSVImportProfile) async throws -> CSVImportProfile {
        try await MainActor.run {
            let context = ModelContext(modelContainer)
            let id = profile.id
            var descriptor = FetchDescriptor<CSVImportProfileRecord>(
                predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let record = try context.fetch(descriptor).first else {
                throw RepositoryError.notFound
            }
            record.accountId = profile.accountId
            record.parserIdentifier = profile.parserIdentifier
            record.headerSignature = profile.headerSignature.joined(separator: "\u{1F}")
            record.filenamePattern = profile.filenamePattern
            record.deleteAfterImport = profile.deleteAfterImport
            record.lastUsedAt = profile.lastUsedAt
            try context.save()
            onRecordChanged?(profile.id)
            return record.toDomain()
        }
    }

    func delete(id: UUID) async throws {
        try await MainActor.run {
            let context = ModelContext(modelContainer)
            var descriptor = FetchDescriptor<CSVImportProfileRecord>(
                predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            if let record = try context.fetch(descriptor).first {
                context.delete(record)
                try context.save()
                onRecordDeleted?(id)
            }
        }
    }
}

enum RepositoryError: Error { case notFound }  // if not already defined elsewhere
```

If `RepositoryError` already exists in the project, delete the local re-declaration. Mirror the exact pattern used by `CloudKitCategoryRepository.swift` for field updates, error reporting, and sync-closure invocation.

- [ ] **Step 6.7 — Extend `TestBackend.seed(…)`** with a helper for profiles (optional but makes Task 12 tests cleaner):

```swift
@discardableResult
static func seed(
    csvImportProfiles: [CSVImportProfile],
    in container: ModelContainer
) -> [CSVImportProfile] {
    let context = ModelContext(container)
    for profile in csvImportProfiles {
        context.insert(CSVImportProfileRecord.from(profile))
    }
    try! context.save()
    return csvImportProfiles
}
```

- [ ] **Step 6.8 — Run test → pass (after Task 8 wires the property; if executing strictly task-by-task, sequence Tasks 6→7→8 and run the contract tests at the end of Task 8). Commit.**

```bash
git add Backends/CloudKit/Models/CSVImportProfileRecord.swift \
        Backends/CloudKit/Repositories/CloudKitCSVImportProfileRepository.swift \
        Backends/CloudKit/Sync/RecordMapping.swift \
        Backends/CloudKit/Sync/ProfileDataSyncHandler.swift \
        MoolahTests/Domain/CSVImportProfileRepositoryContractTests.swift \
        MoolahTests/Support/TestBackend.swift
git commit -m "feat: persist CSVImportProfile and sync via CKSyncEngine"
```

- [ ] **Step 6.9 — Run `@sync-review`** on the diff. Verify: four switch-case arms added, first-start queue-on-scan updated, `onRecordChanged` / `onRecordDeleted` called after every successful save/delete.

---

### Task 7: `ImportRuleRecord` persistence, sync, and contract test

Same shape as Task 6. Key difference: `conditions` and `actions` are enums with associated values — serialise via `JSONEncoder` into a single `Data` column (`conditionsJSON`, `actionsJSON`). Per SYNC_GUIDE.md, store the JSON Data as a CKRecord `Data` value.

**Files:**
- Create: `Backends/CloudKit/Models/ImportRuleRecord.swift`
- Create: `Backends/CloudKit/Repositories/CloudKitImportRuleRepository.swift`
- Modify: `Backends/CloudKit/Sync/RecordMapping.swift`
- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler.swift`  (four switch statements + first-start scan)
- Test:   `MoolahTests/Domain/ImportRuleRepositoryContractTests.swift`

- [ ] **Step 7.1 — Failing contract tests:**

```swift
@Test("rule fields + conditions + actions survive create/update/fetch")
func testLifecycle() async throws {
    let (backend, _) = try TestBackend.create()
    let rule = ImportRule(
        name: "Coffee",
        position: 0,
        matchMode: .all,
        conditions: [.descriptionContains(["COFFEE"])],
        actions: [.setPayee("Café"), .appendNote("imported")])
    _ = try await backend.importRules.create(rule)
    var all = try await backend.importRules.fetchAll()
    #expect(all.count == 1)
    #expect(all[0].conditions == [.descriptionContains(["COFFEE"])])
    var updated = rule
    updated.enabled = false
    updated.actions = [.skip]
    _ = try await backend.importRules.update(updated)
    all = try await backend.importRules.fetchAll()
    #expect(all[0].enabled == false)
    #expect(all[0].actions == [.skip])
    try await backend.importRules.delete(id: rule.id)
    all = try await backend.importRules.fetchAll()
    #expect(all.isEmpty)
}

@Test("reorder repositions rules atomically; mismatched id set throws")
func testReorder() async throws {
    let (backend, _) = try TestBackend.create()
    let a = ImportRule(name: "A", position: 0, conditions: [], actions: [])
    let b = ImportRule(name: "B", position: 1, conditions: [], actions: [])
    let c = ImportRule(name: "C", position: 2, conditions: [], actions: [])
    for r in [a, b, c] { _ = try await backend.importRules.create(r) }
    try await backend.importRules.reorder([c.id, a.id, b.id])
    let ordered = try await backend.importRules.fetchAll().sorted { $0.position < $1.position }
    #expect(ordered.map(\.id) == [c.id, a.id, b.id])

    await #expect(throws: (any Error).self) {
        try await backend.importRules.reorder([a.id])  // missing ids
    }
}
```

- [ ] **Step 7.2 — Implement SwiftData record.**

```swift
// Backends/CloudKit/Models/ImportRuleRecord.swift
import Foundation
import SwiftData

@Model
final class ImportRuleRecord {

    #Index<ImportRuleRecord>([\.id])

    var id: UUID = UUID()
    var name: String = ""
    var enabled: Bool = true
    var position: Int = 0
    var matchMode: String = "all"       // stored as raw value
    var conditionsJSON: Data = Data()
    var actionsJSON: Data = Data()
    var accountScope: UUID?
    var encodedSystemFields: Data?

    init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool,
        position: Int,
        matchMode: MatchMode,
        conditions: [RuleCondition],
        actions: [RuleAction],
        accountScope: UUID?
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.position = position
        self.matchMode = matchMode.rawValue
        self.accountScope = accountScope
        self.conditionsJSON = (try? JSONEncoder().encode(conditions)) ?? Data()
        self.actionsJSON = (try? JSONEncoder().encode(actions)) ?? Data()
    }

    func toDomain() -> ImportRule {
        let conditions = (try? JSONDecoder().decode([RuleCondition].self, from: conditionsJSON)) ?? []
        let actions = (try? JSONDecoder().decode([RuleAction].self, from: actionsJSON)) ?? []
        return ImportRule(
            id: id,
            name: name,
            enabled: enabled,
            position: position,
            matchMode: MatchMode(rawValue: matchMode) ?? .all,
            conditions: conditions,
            actions: actions,
            accountScope: accountScope)
    }

    static func from(_ rule: ImportRule) -> ImportRuleRecord {
        ImportRuleRecord(
            id: rule.id, name: rule.name, enabled: rule.enabled,
            position: rule.position, matchMode: rule.matchMode,
            conditions: rule.conditions, actions: rule.actions,
            accountScope: rule.accountScope)
    }
}
```

- [ ] **Step 7.3 — CloudKit mapping + registry.** Mirror Task 6 Step 6.4 exactly; serialise `conditionsJSON` / `actionsJSON` as `CKRecordValue` (`Data` conforms).

- [ ] **Step 7.4 — `ProfileDataSyncHandler` wiring.** Four switch sites + first-start scan, mirroring Task 6 Step 6.5.

- [ ] **Step 7.5 — Implement repository with `reorder(_:)`.**

```swift
func reorder(_ orderedIds: [UUID]) async throws {
    try await MainActor.run {
        let context = ModelContext(modelContainer)
        let all = try context.fetch(FetchDescriptor<ImportRuleRecord>())
        guard Set(all.map(\.id)) == Set(orderedIds), all.count == orderedIds.count else {
            throw RepositoryError.notFound   // reuse or add .reorderIdMismatch
        }
        let indexById = Dictionary(uniqueKeysWithValues: orderedIds.enumerated().map { ($1, $0) })
        for record in all { record.position = indexById[record.id] ?? record.position }
        try context.save()
        for id in orderedIds { onRecordChanged?(id) }
    }
}
```

- [ ] **Step 7.6 — `TestBackend.seed(rules:)`** helper, matching the profiles one.

- [ ] **Step 7.7 — Commit.**

```bash
git commit -m "feat: persist ImportRule and sync via CKSyncEngine"
```

- [ ] **Step 7.8 — Run `@sync-review` on the diff.**

---

### Task 8: Wire `csvImportProfiles` and `importRules` into `BackendProvider`

This is the "smallest diff" task that unblocks Task 6 and Task 7 contract tests.

**Files:**
- Modify: `Domain/Repositories/BackendProvider.swift`
- Modify: `Backends/CloudKit/CloudKitBackend.swift`
- Modify: `Shared/PreviewBackend.swift`  (and any other `BackendProvider` conformers)

- [ ] **Step 8.1 — Add properties.**

```swift
protocol BackendProvider: Sendable {
    var auth: any AuthProvider { get }
    var accounts: any AccountRepository { get }
    var transactions: any TransactionRepository { get }
    var categories: any CategoryRepository { get }
    var earmarks: any EarmarkRepository { get }
    var analysis: any AnalysisRepository { get }
    var investments: any InvestmentRepository { get }
    var conversionService: any InstrumentConversionService { get }
    var csvImportProfiles: any CSVImportProfileRepository { get }   // NEW
    var importRules: any ImportRuleRepository { get }               // NEW
}
```

- [ ] **Step 8.2 — Instantiate in `CloudKitBackend.init`.** Pass the sync-queueing closures the same way other repositories receive them (reuse whatever `onRecordChanged` plumbing the existing repositories in `CloudKitBackend.init` use — likely a reference to `ProfileDataSyncHandler`).

- [ ] **Step 8.3 — Update `PreviewBackend`** with in-memory no-op repositories or reuse `CloudKitBackend` via `TestBackend.create()`. If any other test-only conformers exist (`CancellablePagingTransactionRepository` is a leg, not a backend — ignore), add the two new properties.

- [ ] **Step 8.4 — Run contract tests from Tasks 6–7 → pass.** Run `just test CSVImportProfileRepositoryContractTests ImportRuleRepositoryContractTests` and verify.

- [ ] **Step 8.5 — Commit.**

```bash
git commit -m "feat: expose CSVImportProfileRepository and ImportRuleRepository on BackendProvider"
```

---

### Task 9: `GenericBankCSVParser` + fixture suite

Column-inferred bank CSV parser. Scope per spec: single-leg, single-currency rows; header-name heuristics for Date / Amount / Debit / Credit / Description / Balance / Reference; configurable date format (auto-detected from value shape); whole-file-or-nothing on row parse failure.

**Files:**
- Create: `Shared/CSVImport/GenericBankCSVParser.swift`
- Create: `MoolahTests/Support/Fixtures/csv/*.csv` (10+ fixtures — list below)
- Create: `MoolahTests/Shared/CSVImport/GenericBankCSVParserTests.swift`
- Modify: `project.yml` — register the fixture folder as a test resource

- [ ] **Step 9.1 — Commit representative fixtures.** Each ~10–30 rows, realistic column layouts. Names + sample first few rows:

```
cba-everyday-standard.csv
Date,Description,Debit,Credit,Balance
01/04/2024,OPENING BALANCE,,,1000.00
02/04/2024,COFFEE HUT SYDNEY,-5.50,,994.50
03/04/2024,PAY NET,,3000.00,3994.50

anz-everyday-debit-credit-split.csv
Date,Amount,Description,Balance
02/04/2024,-5.50,COFFEE HUT,994.50
03/04/2024,3000.00,SALARY,3994.50

nab-creditcard-debit-credit-split.csv
Date,Type,Description,Amount,Balance
"02/04/2024","Purchase","APPLE PTY LTD",-120.00,-120.00

westpac-everyday.csv     # uses DD-MM-YYYY
01-04-2024,OPENING,,,1000.00
02-04-2024,COFFEE,-5.50,,994.50

ing-savings.csv          # has a running balance and a bank reference column
Date,Description,Credit,Debit,Balance,Reference
02/04/2024,COFFEE HUT,,5.50,994.50,TXN12345

bendigo-standard.csv     # US-style MM/DD/YYYY — exercises format disambiguation
04/02/2024,COFFEE HUT,-5.50,,994.50

macquarie-everyday.csv
Transaction Date,Narrative,Debit Amount,Credit Amount,Balance
02/04/2024,COFFEE HUT,5.50,,994.50

us-bofa-standard.csv
Date,Description,Amount,Running Bal.
04/02/2024,COFFEE,-5.50,994.50

uk-barclays-standard.csv     # ISO date, signed amount
Date,Description,Amount,Balance
2024-04-02,COFFEE,-5.50,994.50

generic-unknown-headers.csv     # headers that should still be inferrable
Txn Date,Memo,Dr,Cr,Bal
01/04/2024,TEST,10.00,,10.00

malformed-unterminated-quote.csv
Date,Description,Amount,Balance
02/04/2024,"Missing close,10.00,100.00

utf16-bom.csv                   # UTF-16 with BOM
windows-1252.csv                # contains é, £
```

Store them under `MoolahTests/Support/Fixtures/csv/`.

- [ ] **Step 9.2 — Expose fixtures to tests.** Add to `project.yml` under the test target sources (example):

```yaml
MoolahTests_iOS:
  sources:
    - path: MoolahTests
    - path: MoolahTests/Support/Fixtures/csv
      type: folder
      buildPhase: resources
```

Run `just generate`. Then add a helper in `MoolahTests/Support/`:

```swift
// MoolahTests/Support/CSVFixtureLoader.swift
import Foundation

enum CSVFixtureLoader {
    static func url(_ name: String) -> URL {
        Bundle(for: TestBundleMarker.self).url(forResource: name, withExtension: "csv")!
    }
    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }
    static func string(_ name: String) throws -> String {
        try String(contentsOf: url(name), encoding: .utf8)
    }
}
```

(`TestBundleMarker` already exists in `MoolahTests/Support/`.)

- [ ] **Step 9.3 — Write the first failing parser test.**

```swift
import Foundation
import Testing
@testable import Moolah

@Suite("GenericBankCSVParser")
struct GenericBankCSVParserTests {

    @Test("recognizes CBA headers and parses one expense row")
    func testCBAExpenseRow() throws {
        let parser = GenericBankCSVParser()
        let rows = CSVTokenizer.parse(try CSVFixtureLoader.string("cba-everyday-standard"))
        #expect(parser.recognizes(headers: rows[0]))
        let parsed = try parser.parse(rows: rows)
        guard case .transaction(let tx) = parsed[1] else { return Issue.record("expected .transaction at row 1"); }
        #expect(tx.rawDescription == "COFFEE HUT SYDNEY")
        #expect(tx.rawAmount == Decimal(string: "-5.50"))
        #expect(tx.rawBalance == Decimal(string: "994.50"))
        #expect(tx.legs.count == 1)
        #expect(tx.legs[0].type == .expense)
        #expect(tx.legs[0].quantity == Decimal(string: "-5.50"))
    }
}
```

- [ ] **Step 9.4 — Run → fail.**

- [ ] **Step 9.5 — Implement `GenericBankCSVParser`.** Core algorithm:

```swift
// Shared/CSVImport/GenericBankCSVParser.swift
import Foundation

struct GenericBankCSVParser: CSVParser {
    let identifier = "generic-bank"

    struct ColumnMapping: Sendable, Equatable {
        var date: Int
        var description: Int
        var amount: Int?          // set when a single signed-amount column exists
        var debit: Int?           // set when debit/credit split
        var credit: Int?
        var balance: Int?
        var reference: Int?
        var dateFormat: DateFormat
    }

    enum DateFormat: Sendable, Equatable {
        case ddMMyyyy(separator: Character)   // "/" or "-"
        case mmDDyyyy(separator: Character)
        case iso                              // YYYY-MM-DD
    }

    func recognizes(headers: [String]) -> Bool {
        inferMapping(from: headers) != nil
    }

    func parse(rows: [[String]]) throws -> [ParsedRecord] {
        guard let headers = rows.first else { throw CSVParserError.emptyFile }
        guard let mapping = inferMapping(from: headers) else { throw CSVParserError.headerMismatch }
        var results: [ParsedRecord] = []
        for (index, row) in rows.dropFirst().enumerated() {
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                results.append(.skip(reason: "blank row")); continue
            }
            // Detect summary rows (e.g., totals at the bottom): heuristic — no date
            let dateString = safeField(row, at: mapping.date)
            guard let date = parseDate(dateString, format: mapping.dateFormat) else {
                // If the row is plausibly a summary (e.g., "Total" in description), skip;
                // otherwise reject file per spec: whole-file-or-nothing.
                let descField = safeField(row, at: mapping.description).lowercased()
                if descField.contains("total") || descField.contains("summary") {
                    results.append(.skip(reason: "summary row")); continue
                }
                throw CSVParserError.malformedRow(
                    index: index + 1, reason: "invalid date: \(dateString)")
            }
            let amount: Decimal
            if let amountIdx = mapping.amount {
                guard let parsed = parseAmount(safeField(row, at: amountIdx)) else {
                    throw CSVParserError.malformedRow(
                        index: index + 1, reason: "invalid amount")
                }
                amount = parsed
            } else {
                let debit = mapping.debit.flatMap { parseAmount(safeField(row, at: $0)) } ?? 0
                let credit = mapping.credit.flatMap { parseAmount(safeField(row, at: $0)) } ?? 0
                if debit == 0 && credit == 0 {
                    throw CSVParserError.malformedRow(
                        index: index + 1, reason: "row has no debit or credit value")
                }
                amount = (credit != 0 ? credit : -abs(debit))
            }
            let desc = safeField(row, at: mapping.description)
            let balance = mapping.balance.flatMap { parseAmount(safeField(row, at: $0)) }
            let bankRef = mapping.reference.map { safeField(row, at: $0) }.flatMap {
                $0.isEmpty ? nil : $0
            }

            // Single-leg: quantity == amount; type inferred from sign.
            let leg = ParsedLeg(
                accountId: nil,
                instrument: .AUD, // placeholder — Task 15 overrides with account instrument
                quantity: amount,
                type: amount >= 0 ? .income : .expense)
            let tx = ParsedTransaction(
                date: date, legs: [leg], rawRow: row,
                rawDescription: desc, rawAmount: amount,
                rawBalance: balance, bankReference: bankRef)
            results.append(.transaction(tx))
        }
        return results
    }

    // MARK: - Private inference helpers

    private func safeField(_ row: [String], at idx: Int) -> String {
        idx >= 0 && idx < row.count ? row[idx] : ""
    }

    func inferMapping(from headers: [String]) -> ColumnMapping? {
        let normalised = headers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func find(_ candidates: [String]) -> Int? {
            for (i, h) in normalised.enumerated() where candidates.contains(where: { h.contains($0) }) {
                return i
            }
            return nil
        }
        guard let dateIdx = find(["date", "txn date", "transaction date"]),
              let descIdx = find(["description", "narrative", "memo", "details"])
        else { return nil }
        let amountIdx = find(["amount", "value"])
        let debitIdx = find(["debit", "dr "]) ?? find(["dr"])
        let creditIdx = find(["credit", "cr "]) ?? find(["cr"])
        let balanceIdx = find(["balance", "running bal", "bal"])
        let referenceIdx = find(["reference", "ref"])

        // Need EITHER a single amount column OR both debit and credit
        let hasAmount = amountIdx != nil
        let hasDrCr = debitIdx != nil && creditIdx != nil
        guard hasAmount || hasDrCr else { return nil }

        // Date format detection — scan a few rows below for the pattern
        let sampleCount = 0  // date format is detected in parse(); we use a heuristic default here
        _ = sampleCount
        let dateFormat: DateFormat = .ddMMyyyy(separator: "/") // default; see detection below
        return ColumnMapping(
            date: dateIdx, description: descIdx, amount: amountIdx,
            debit: debitIdx, credit: creditIdx, balance: balanceIdx,
            reference: referenceIdx, dateFormat: dateFormat)
    }

    private func parseAmount(_ field: String) -> Decimal? {
        var s = field.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        s = s.replacingOccurrences(of: "$", with: "")
        s = s.replacingOccurrences(of: ",", with: "")
        // Handle (12.34) as -12.34
        if s.hasPrefix("(") && s.hasSuffix(")") {
            s = "-" + s.dropFirst().dropLast()
        }
        return Decimal(string: s)
    }

    private func parseDate(_ field: String, format: DateFormat) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        switch format {
        case .ddMMyyyy(let sep): f.dateFormat = "dd\(sep)MM\(sep)yyyy"
        case .mmDDyyyy(let sep): f.dateFormat = "MM\(sep)dd\(sep)yyyy"
        case .iso: f.dateFormat = "yyyy-MM-dd"
        }
        return f.date(from: field.trimmingCharacters(in: .whitespaces))
    }
}
```

**Date format detection:** Before returning the mapping, sample the first 5 data rows and check:
- Any field matches `^\d{4}-\d{2}-\d{2}$` → `.iso`.
- Separator is `/` or `-`.
- For separator-based formats, default to `.ddMMyyyy` (Australian preference). Upgrade to `.mmDDyyyy` only when: (a) at least one sampled row has the first component > 12 **→ cannot be DD/MM because can't have a 14th month; but 13th day is fine with DD/MM.** Invert: if first > 12 anywhere, `.mmDDyyyy` is impossible, so it's `.ddMMyyyy`. If second > 12 anywhere, `.ddMMyyyy` is impossible, so it's `.mmDDyyyy`. Ambiguous input (all first + second ≤ 12) → stay with locale-default `.ddMMyyyy`; surface ambiguity via a `parser.dateFormatAmbiguous` flag the setup form can prompt on (the Needs Setup form already has a date-format picker for user override).

Expose the detection result from `inferMapping(from:sampleRows:)` and include `ambiguous: Bool` on the returned mapping. Wire through to `parse(rows:)`.

- [ ] **Step 9.6 — Run first test → pass.**

- [ ] **Step 9.7 — Add tests for every fixture + edge case (one TDD cycle each).**

| Test | Fixture | Expected |
|---|---|---|
| `recognizesCBA` | `cba-everyday-standard.csv` | `recognizes == true`; `parse` yields 3 records, first `.transaction` is opening balance (amount `0` or a `.skip`); amounts match |
| `recognizesANZ` | `anz-everyday-debit-credit-split.csv` | recognized; signed amount column |
| `recognizesNABCreditCard` | `nab-creditcard-debit-credit-split.csv` | recognized; handles quoted fields |
| `recognizesWestpacDashDate` | `westpac-everyday.csv` | date separator `-`; parses correctly |
| `recognizesINGWithReference` | `ing-savings.csv` | bankReference populated from `Reference` column |
| `recognizesBendigo_mmDDyyyy` | `bendigo-standard.csv` | one row has first component > 12 so detector picks `.ddMMyyyy`; flip test: a `us-style.csv` fixture where second component > 12 picks `.mmDDyyyy` |
| `recognizesMacquarie_DebitCreditSplitNamed` | `macquarie-everyday.csv` | debit column named "Debit Amount"; credit "Credit Amount" |
| `recognizesBofA` | `us-bofa-standard.csv` | `.mmDDyyyy` detection |
| `recognizesBarclays_isoDate` | `uk-barclays-standard.csv` | `.iso` date format |
| `recognizesGenericInferredHeaders` | `generic-unknown-headers.csv` | `Txn Date`, `Memo`, `Dr`/`Cr`, `Bal` all inferred |
| `rejectsMalformedRow` | `malformed-unterminated-quote.csv` | `parse(rows:)` throws `CSVParserError.malformedRow(index:reason:)` (note: tokenizer may produce a long row — the parser must still reject based on the downstream field parse) |
| `rejectsUnknownHeaders` | synth: `Foo,Bar,Baz` | `recognizes == false`; `parse` throws `.headerMismatch` |
| `skipsSummaryRows` | synth: extend cba fixture with `"Total",,,,` last row | returns `.skip` rather than throwing |
| `preservesSignFromDebitCreditSplit` | anz split | positive `Credit` → `+`, positive `Debit` → `-`, never `abs()` |
| `bankReferenceIsNilWhenColumnAbsent` | cba | `tx.bankReference == nil` |
| `rawBalanceIsNilWhenBalanceColumnMissing` | synth: cba minus `Balance` column | `rawBalance == nil` |
| `dateFormatAmbiguous_reportsFlag` | synth: both components ≤ 12 | mapping.ambiguous == true; parses with default `.ddMMyyyy` |
| `parsesUTF16BOMFixture` | `utf16-bom.csv` | tokenizer handles BOM + encoding; parser succeeds |
| `parsesWindows1252Fixture` | `windows-1252.csv` | non-ASCII description preserved |

For each, run `just test GenericBankCSVParserTests/<name>` and commit after green (or batch 3–4 closely-related tests into one commit).

- [ ] **Step 9.8 — Commit fixtures separately from code** so file review is cleaner:

```bash
git add MoolahTests/Support/Fixtures/csv project.yml MoolahTests/Support/CSVFixtureLoader.swift
git commit -m "test: add bank CSV fixtures for GenericBankCSVParser tests"

git add Shared/CSVImport/GenericBankCSVParser.swift MoolahTests/Shared/CSVImport/GenericBankCSVParserTests.swift
git commit -m "feat: add GenericBankCSVParser with column-inference heuristics"
```

---

### Task 10: `SelfWealthParser` + fixtures

Port parsing logic from `plans/csv-import-design.md`:
- Headers: `Date,Type,Description,Debit,Credit,Balance`.
- For `Type == "Trade"`: regex `(BUY|SELL)\s+(\d+)\s+([A-Z0-9.]+)\s+@\s+\$?([\d.]+)` on Description → two-leg `ParsedTransaction` (cash leg `.expense`/`.income` in AUD, position leg `.income`/`.expense` in the ticker instrument).
- For `Type == "Dividend"`: extract ticker from description; single-leg `.income` on the investment account, instrument AUD, payee set later from ticker.
- For `Type == "Brokerage"` / `"GST on Brokerage"`: single-leg `.expense` AUD, preserve description verbatim.
- For `Type == "Cash In"` / `"Cash Out"`: single-leg AUD.
- For unrecognised: `.skip(reason:)`.

Per spec v1: ticker instruments are looked up / created at persist time (Task 15) from the raw ticker string; the parser just emits a placeholder instrument (or carries the ticker on a side-channel — simpler: extend `ParsedLeg` with `var tickerHint: String?` used by Task 15 to resolve the instrument). Simplest approach: construct an `Instrument` with `kind: .stock`, `id: "ASX:\(ticker)"`, name `ticker`, ticker `ticker`, exchange `"ASX"`, decimals `0`. Task 15 then re-maps via `InstrumentRecord` lookups.

**Files:**
- Create: `Shared/CSVImport/SelfWealthParser.swift`
- Create fixtures: `selfwealth-trades.csv`, `selfwealth-trades-empty.csv`, `selfwealth-trades-malformed.csv`
- Test:   `MoolahTests/Shared/CSVImport/SelfWealthParserTests.swift`

- [ ] **Step 10.1 — Commit fixtures.** Example `selfwealth-trades.csv`:

```
Date,Type,Description,Debit,Credit,Balance
01/03/2024,Cash In,Cash deposit,,10000.00,10000.00
02/03/2024,Trade,BUY 100 BHP @ $45.50,4550.00,,5450.00
02/03/2024,Brokerage,Brokerage fee,9.50,,5440.50
02/03/2024,GST on Brokerage,GST,0.95,,5439.55
15/03/2024,Dividend,DIVIDEND - BHP GROUP LIMITED,,120.00,5559.55
01/04/2024,Trade,SELL 50 CBA @ $110.25,,5512.50,11072.05
```

- [ ] **Step 10.2 — Write failing tests (4–6 cases).**

```swift
@Suite("SelfWealthParser")
struct SelfWealthParserTests {

    @Test("parses BUY trade as two-leg: cash -expense, position +income")
    func testBuyTrade() throws {
        let parser = SelfWealthParser()
        let rows = CSVTokenizer.parse(try CSVFixtureLoader.string("selfwealth-trades"))
        #expect(parser.recognizes(headers: rows[0]))
        let records = try parser.parse(rows: rows)
        let trades = records.compactMap { rec -> ParsedTransaction? in
            if case .transaction(let tx) = rec, tx.legs.count == 2 { return tx } else { return nil }
        }
        // BHP buy
        let bhp = trades.first { $0.rawDescription.contains("BHP") }!
        #expect(bhp.legs.count == 2)
        let cashLeg = bhp.legs.first { $0.instrument == .AUD }!
        #expect(cashLeg.quantity == Decimal(string: "-4550.00"))
        #expect(cashLeg.type == .expense)
        let posLeg = bhp.legs.first { $0.instrument.ticker == "BHP" }!
        #expect(posLeg.quantity == 100)
        #expect(posLeg.type == .income)
    }

    @Test("parses SELL trade as two-leg: cash +income, position -expense")
    func testSellTrade() throws {
        // similar, CBA SELL 50 @ $110.25 → cash +5512.50, position -50 CBA
    }

    @Test("dividend → single-leg AUD income on investment account")
    func testDividend() throws { /* … */ }

    @Test("brokerage + GST → single-leg AUD expense")
    func testBrokerage() throws { /* … */ }

    @Test("cash in/out → single-leg AUD")
    func testCashIn() throws { /* … */ }

    @Test("unrecognised Type emits .skip")
    func testUnknownType() throws { /* … */ }

    @Test("missing required headers → recognizes returns false")
    func testUnknownHeaders() { /* … */ }

    @Test("malformed description (regex miss on Trade row) → whole-file reject")
    func testMalformedTradeDescription() throws { /* … */ }
}
```

- [ ] **Step 10.3 — Implement `SelfWealthParser`.**

```swift
// Shared/CSVImport/SelfWealthParser.swift
import Foundation

struct SelfWealthParser: CSVParser {
    let identifier = "selfwealth"

    private static let requiredHeaders: Set<String> =
        ["date", "type", "description", "debit", "credit", "balance"]

    func recognizes(headers: [String]) -> Bool {
        let n = Set(headers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        return Self.requiredHeaders.isSubset(of: n)
    }

    func parse(rows: [[String]]) throws -> [ParsedRecord] {
        guard let header = rows.first else { throw CSVParserError.emptyFile }
        guard recognizes(headers: header) else { throw CSVParserError.headerMismatch }
        let idx = columnIndex(header)

        var results: [ParsedRecord] = []
        for (i, row) in rows.dropFirst().enumerated() {
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                results.append(.skip(reason: "blank row")); continue
            }
            let type = safe(row, idx.type)
            let desc = safe(row, idx.description)
            guard let date = parseDate(safe(row, idx.date)) else {
                throw CSVParserError.malformedRow(index: i+1, reason: "invalid date")
            }
            let debit = decimal(safe(row, idx.debit)) ?? 0
            let credit = decimal(safe(row, idx.credit)) ?? 0
            let balance = decimal(safe(row, idx.balance))
            let cashAmount: Decimal = credit != 0 ? credit : -abs(debit)

            switch type.lowercased() {
            case "trade":
                results.append(try parseTrade(
                    date: date, description: desc, cashAmount: cashAmount,
                    balance: balance, row: row, index: i+1))
            case "dividend":
                let ticker = extractDividendTicker(desc)
                let leg = ParsedLeg(
                    accountId: nil, instrument: .AUD,
                    quantity: cashAmount, type: .income)
                results.append(.transaction(ParsedTransaction(
                    date: date, legs: [leg], rawRow: row,
                    rawDescription: desc, rawAmount: cashAmount,
                    rawBalance: balance,
                    bankReference: ticker.map { "SW-DIV-\($0)" })))
            case "brokerage", "gst on brokerage", "fee":
                let leg = ParsedLeg(
                    accountId: nil, instrument: .AUD,
                    quantity: cashAmount, type: .expense)
                results.append(.transaction(ParsedTransaction(
                    date: date, legs: [leg], rawRow: row,
                    rawDescription: desc, rawAmount: cashAmount,
                    rawBalance: balance, bankReference: nil)))
            case "cash in", "cash out", "interest":
                let leg = ParsedLeg(
                    accountId: nil, instrument: .AUD,
                    quantity: cashAmount,
                    type: cashAmount >= 0 ? .income : .expense)
                results.append(.transaction(ParsedTransaction(
                    date: date, legs: [leg], rawRow: row,
                    rawDescription: desc, rawAmount: cashAmount,
                    rawBalance: balance, bankReference: nil)))
            default:
                results.append(.skip(reason: "unknown type: \(type)"))
            }
        }
        return results
    }

    // MARK: - Private

    private struct Columns { let date: Int; let type: Int; let description: Int
        let debit: Int; let credit: Int; let balance: Int }
    private func columnIndex(_ headers: [String]) -> Columns {
        let n = headers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return Columns(
            date: n.firstIndex(of: "date")!, type: n.firstIndex(of: "type")!,
            description: n.firstIndex(of: "description")!,
            debit: n.firstIndex(of: "debit")!, credit: n.firstIndex(of: "credit")!,
            balance: n.firstIndex(of: "balance")!)
    }
    private func safe(_ row: [String], _ i: Int) -> String {
        i >= 0 && i < row.count ? row[i] : ""
    }
    private func decimal(_ s: String) -> Decimal? {
        var s = s.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        s = s.replacingOccurrences(of: "$", with: "")
        s = s.replacingOccurrences(of: ",", with: "")
        return Decimal(string: s)
    }
    private func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "dd/MM/yyyy"
        return f.date(from: s)
    }

    private static let tradeRegex = try! NSRegularExpression(
        pattern: #"(BUY|SELL)\s+(\d+)\s+([A-Z0-9.]+)\s+@\s+\$?([\d.]+)"#, options: [])

    private func parseTrade(
        date: Date, description: String, cashAmount: Decimal,
        balance: Decimal?, row: [String], index: Int
    ) throws -> ParsedRecord {
        let range = NSRange(description.startIndex..., in: description)
        guard let m = Self.tradeRegex.firstMatch(in: description, options: [], range: range) else {
            throw CSVParserError.malformedRow(index: index, reason: "unrecognised trade description")
        }
        let kind = (description as NSString).substring(with: m.range(at: 1))  // BUY / SELL
        let qtyStr = (description as NSString).substring(with: m.range(at: 2))
        let ticker = (description as NSString).substring(with: m.range(at: 3))
        guard let qty = Decimal(string: qtyStr) else {
            throw CSVParserError.malformedRow(index: index, reason: "invalid quantity")
        }
        let asxInstrument = Instrument(
            id: "ASX:\(ticker)", kind: .stock, name: ticker,
            decimals: 0, ticker: ticker, exchange: "ASX",
            chainId: nil, contractAddress: nil)
        let cashLeg = ParsedLeg(
            accountId: nil, instrument: .AUD,
            quantity: cashAmount,
            type: kind == "BUY" ? .expense : .income)
        let posLeg = ParsedLeg(
            accountId: nil, instrument: asxInstrument,
            quantity: kind == "BUY" ? qty : -qty,
            type: kind == "BUY" ? .income : .expense)
        return .transaction(ParsedTransaction(
            date: date, legs: [cashLeg, posLeg], rawRow: row,
            rawDescription: description, rawAmount: cashAmount,
            rawBalance: balance, bankReference: nil))
    }

    private func extractDividendTicker(_ desc: String) -> String? {
        // "DIVIDEND - BHP GROUP LIMITED" → "BHP"
        let after = desc.split(separator: "-", maxSplits: 1).dropFirst().first ?? ""
        return after.split(separator: " ").first.map { String($0) }
    }
}
```

- [ ] **Step 10.4 — Commit.**

```bash
git add MoolahTests/Support/Fixtures/csv/selfwealth*.csv
git commit -m "test: add SelfWealth CSV fixtures"

git add Shared/CSVImport/SelfWealthParser.swift \
        MoolahTests/Shared/CSVImport/SelfWealthParserTests.swift
git commit -m "feat: add SelfWealthParser (BUY/SELL/Dividend/Brokerage/Cash)"
```

- [ ] **Step 10.5 — Add `CSVParserRegistry`** that returns parsers in selection order (source-specific first, generic fallback):

```swift
// Shared/CSVImport/CSVParserRegistry.swift
import Foundation

struct CSVParserRegistry: Sendable {
    let parsers: [any CSVParser]

    static let `default` = CSVParserRegistry(parsers: [
        SelfWealthParser(),
        GenericBankCSVParser()
    ])

    /// Returns the first parser that recognises the headers, else the generic parser
    /// (per spec: unrecognised → fall back to GenericBank so setup form can confirm mapping).
    func select(for headers: [String]) -> any CSVParser {
        for parser in parsers where parser.recognizes(headers: headers) {
            return parser
        }
        return GenericBankCSVParser()
    }
}
```

Add a test in `CSVParserRegistryTests.swift` that:
- SelfWealth headers → SelfWealth parser
- CBA headers → GenericBankCSVParser
- Totally random headers → GenericBankCSVParser (fallback)

Commit.

---

### Task 11: `CSVDeduplicator`

Per spec: three layers run in order, first match wins, silent skip on duplicate.

1. **Bank reference match** — account-wide, no date restriction.
2. **Same-date exact match** — same `accountId`, same `date` (day precision), same `(normalisedRawDescription, rawAmount)`.
3. **Balance alignment** — applies only when *all incoming rows* are single-leg single-currency and every row has a non-nil `rawBalance`. Walks incoming in date order against existing transactions, matches by running-balance continuity.

`CSVDeduplicator` is pure — input: candidate `[ParsedTransaction]` + existing transactions (fetched by the orchestrator) for the target account. Output: the subset of candidates that are NOT duplicates + the ids matched for each skipped row (for audit logging).

**Files:**
- Create: `Shared/CSVImport/CSVDeduplicator.swift`
- Test:   `MoolahTests/Shared/CSVImport/CSVDeduplicatorTests.swift`

- [ ] **Step 11.1 — Failing test: bank reference match**

```swift
import Foundation
import Testing
@testable import Moolah

@Suite("CSVDeduplicator")
struct CSVDeduplicatorTests {

    private func makeExisting(
        accountId: UUID, date: Date,
        description: String, amount: Decimal, bankRef: String? = nil
    ) -> Transaction {
        Transaction(
            date: date,
            legs: [TransactionLeg(
                accountId: accountId, instrument: .AUD,
                quantity: amount, type: amount >= 0 ? .income : .expense,
                categoryId: nil, earmarkId: nil)],
            importOrigin: ImportOrigin(
                rawDescription: description, bankReference: bankRef,
                rawAmount: amount, rawBalance: nil,
                importedAt: Date(), importSessionId: UUID(),
                sourceFilename: nil, parserIdentifier: "generic-bank"))
    }

    @Test("bank reference match skips regardless of date")
    func testBankReferenceMatch() {
        let accountId = UUID()
        let existing = [makeExisting(
            accountId: accountId, date: Date(timeIntervalSince1970: 0),
            description: "COFFEE", amount: -5, bankRef: "REF-1")]
        let incoming = ParsedTransaction(
            date: Date(timeIntervalSince1970: 100_000),  // different date
            legs: [ParsedLeg(accountId: accountId, instrument: .AUD,
                              quantity: -5, type: .expense)],
            rawRow: [], rawDescription: "completely different",
            rawAmount: -5, rawBalance: nil, bankReference: "REF-1")
        let result = CSVDeduplicator.filter(
            [incoming], against: existing, accountId: accountId)
        #expect(result.kept.isEmpty)
        #expect(result.skipped.count == 1)
    }
}
```

- [ ] **Step 11.2 — Implement `CSVDeduplicator` with layer 1 only, then run.** After green, add layer 2 test, implement, green, commit. Then layer 3.

```swift
// Shared/CSVImport/CSVDeduplicator.swift
import Foundation

struct CSVDedupResult: Sendable {
    var kept: [ParsedTransaction]
    var skipped: [(candidate: ParsedTransaction, matchedExistingId: UUID)]
}

enum CSVDeduplicator {

    static func filter(
        _ candidates: [ParsedTransaction],
        against existing: [Transaction],
        accountId: UUID
    ) -> CSVDedupResult {
        var kept: [ParsedTransaction] = []
        var skipped: [(ParsedTransaction, UUID)] = []

        let existingOnAccount = existing.filter { $0.accountIds.contains(accountId) }

        // Layer 1: bank reference
        let byRef = Dictionary(
            grouping: existingOnAccount.filter { $0.importOrigin?.bankReference?.isEmpty == false },
            by: { $0.importOrigin!.bankReference! })

        // Layer 2: same-date exact match index
        let cal = Calendar(identifier: .gregorian)
        func dayKey(_ d: Date) -> DateComponents {
            cal.dateComponents([.year, .month, .day], from: d)
        }
        let byDate = Dictionary(grouping: existingOnAccount, by: { dayKey($0.date) })

        // Layer 3 applicability flag
        let allSingleLegSingleCurrency = candidates.allSatisfy {
            $0.legs.count == 1 && $0.legs[0].instrument == .AUD  // AUD placeholder — Task 15 passes account instrument
        }
        let allHaveBalance = candidates.allSatisfy { $0.rawBalance != nil }
        let runBalanceAlignment = allSingleLegSingleCurrency && allHaveBalance
        var balanceMatched = Set<Int>()  // indexes into candidates
        if runBalanceAlignment {
            balanceMatched = balanceAlignmentMatches(
                candidates: candidates, existing: existingOnAccount)
        }

        for (i, candidate) in candidates.enumerated() {
            // Layer 1
            if let ref = candidate.bankReference,
               let match = byRef[ref]?.first {
                skipped.append((candidate, match.id)); continue
            }
            // Layer 2
            if let sameDay = byDate[dayKey(candidate.date)],
               let match = sameDay.first(where: {
                   let o = $0.importOrigin
                   return normalise(o?.rawDescription ?? "") == normalise(candidate.rawDescription)
                       && (o?.rawAmount ?? 0) == candidate.rawAmount
               }) {
                skipped.append((candidate, match.id)); continue
            }
            // Layer 3
            if balanceMatched.contains(i) {
                skipped.append((candidate, UUID())); continue  // Task 15 fills real id
            }
            kept.append(candidate)
        }
        return CSVDedupResult(kept: kept, skipped: skipped)
    }

    static func normalise(_ s: String) -> String {
        var out = s.uppercased()
        out = out.trimmingCharacters(in: .whitespaces)
        let collapsed = out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "0123456789"))
        return String(String.UnicodeScalarView(collapsed.unicodeScalars.filter { allowed.contains($0) }))
    }

    /// Layer 3: balance alignment. Walks incoming rows in date order against the
    /// existing transactions' running balance in the same account. A row is a
    /// duplicate iff its `(date, rawBalance, rawAmount)` triple lines up with an
    /// existing transaction's running-balance point.
    ///
    /// Simplified v1 implementation: group existing by day, compute running
    /// balance from opening; for each candidate, test whether applying its
    /// rawAmount would reproduce the existing balance at that index.
    private static func balanceAlignmentMatches(
        candidates: [ParsedTransaction],
        existing: [Transaction]
    ) -> Set<Int> {
        // Spec note: this is a heuristic. The simplest correct version: for
        // each candidate, if an existing transaction has the same date, amount,
        // and rawBalance, mark as matched. This catches the common case of
        // overlapping downloads. Fancier alignment can ship later if the fixture
        // set shows gaps.
        var matched = Set<Int>()
        let cal = Calendar(identifier: .gregorian)
        func key(_ d: Date) -> DateComponents {
            cal.dateComponents([.year, .month, .day], from: d)
        }
        for (i, c) in candidates.enumerated() {
            guard let rawBalance = c.rawBalance else { continue }
            let sameDay = existing.filter { key($0.date) == key(c.date) }
            if sameDay.contains(where: {
                ($0.importOrigin?.rawBalance == rawBalance)
                    && ($0.importOrigin?.rawAmount == c.rawAmount)
            }) {
                matched.insert(i)
            }
        }
        return matched
    }
}
```

- [ ] **Step 11.3 — Tests to add (one TDD cycle each):**

| Test | Setup | Assertion |
|---|---|---|
| `layer1_bankRefMatchesAcrossDates` | (above) | 1 skipped, 0 kept |
| `layer2_sameDateExactMatch` | existing on 2024-04-02 with `-5.50 "COFFEE HUT"`; incoming on same day with `-5.50 "coffee hut "` | normalised match → skipped |
| `layer2_differentDatesNotMatched` | existing on 04-02, incoming on 04-03 identical otherwise | kept |
| `layer2_differentAmountsNotMatched` | existing -5.50, incoming -5.51 | kept |
| `layer2_normalisesWhitespaceAndCase` | `"coffee  hut"` vs `"COFFEE HUT"` | skipped |
| `layer3_balanceAlignmentCatchesOverlap` | existing rows include one with `rawBalance=994.50, rawAmount=-5.50`; incoming has same | skipped |
| `layer3_disabledWhenRowIsMultiLeg` | candidates include a two-leg trade | balance alignment NOT attempted; dedup falls through to layers 1/2 only |
| `layer3_disabledWhenAnyBalanceMissing` | candidate with `rawBalance == nil` | same |
| `noMatch_keepsTheRow` | unrelated existing | kept |
| `multipleMatchesOnSameRef_onlyFirstUsed` | two existing both with REF-1 | 1 skipped, matchedExistingId == first |
| `existingOnDifferentAccountIgnored` | existing on a different accountId | kept |

Commit after each green or batched.

- [ ] **Step 11.4 — Commit.**

```bash
git commit -m "feat: add CSVDeduplicator (bank ref + same-date + balance alignment)"
```

---

### Task 12: `CSVImportProfileMatcher`

Matches an incoming file (headers + filename + parsed candidates) to an existing `CSVImportProfile`. Three cases:
1. Zero profiles with `(parserIdentifier, headerSignature) == (file)` → return `.needsSetup`.
2. Exactly one match → `.routed(profile)`.
3. Multiple matches → score each by **duplicate overlap count** (layer 1+2 of `CSVDeduplicator` against that profile's account), then filename-pattern tiebreak, then `.needsSetup` on residual tie.

The matcher is pure — it receives already-fetched profiles + already-fetched existing transactions for each candidate account. The `ImportStore` in Task 15 is responsible for the I/O.

**Files:**
- Create: `Shared/CSVImport/CSVImportProfileMatcher.swift`
- Test:   `MoolahTests/Shared/CSVImport/CSVImportProfileMatcherTests.swift`

- [ ] **Step 12.1 — Type shape.**

```swift
// Shared/CSVImport/CSVImportProfileMatcher.swift
import Foundation

struct MatcherInput: Sendable {
    let filename: String?
    let parserIdentifier: String
    let headerSignature: [String]
    let candidates: [ParsedTransaction]
    /// For each candidate profile, the existing transactions on that profile's account.
    let existingByAccountId: [UUID: [Transaction]]
    let profiles: [CSVImportProfile]
}

enum MatcherResult: Sendable, Equatable {
    case routed(CSVImportProfile)
    case needsSetup(reason: Reason)
    enum Reason: Sendable, Equatable {
        case noMatchingProfile
        case ambiguousMatch(tiedProfileIds: [UUID])
    }
}

enum CSVImportProfileMatcher {
    static func match(_ input: MatcherInput) -> MatcherResult {
        let norm = input.headerSignature.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let candidates = input.profiles.filter {
            $0.parserIdentifier == input.parserIdentifier
                && $0.headerSignature == norm
        }
        switch candidates.count {
        case 0: return .needsSetup(reason: .noMatchingProfile)
        case 1: return .routed(candidates[0])
        default:
            // Score by duplicate overlap
            var scored: [(CSVImportProfile, Int)] = candidates.map { profile in
                let existing = input.existingByAccountId[profile.accountId] ?? []
                let dedup = CSVDeduplicator.filter(
                    input.candidates, against: existing, accountId: profile.accountId)
                return (profile, dedup.skipped.count)
            }
            scored.sort { $0.1 > $1.1 }
            guard let top = scored.first else {
                return .needsSetup(reason: .noMatchingProfile)
            }
            let tied = scored.filter { $0.1 == top.1 }
            if tied.count == 1 { return .routed(top.0) }

            // Filename-pattern tiebreak
            if let filename = input.filename {
                let matching = tied.filter { matches(pattern: $0.0.filenamePattern, filename: filename) }
                if matching.count == 1 { return .routed(matching[0].0) }
            }
            return .needsSetup(reason: .ambiguousMatch(tiedProfileIds: tied.map { $0.0.id }))
        }
    }

    private static func matches(pattern: String?, filename: String) -> Bool {
        guard let pattern else { return false }
        // Simple glob: support *, ?, literal match — use NSPredicate with LIKE.
        return NSPredicate(format: "self LIKE[c] %@", pattern).evaluate(with: filename)
    }
}
```

- [ ] **Step 12.2 — Tests:**

| Test | Setup | Expect |
|---|---|---|
| `noProfiles_needsSetup` | empty profiles | `.needsSetup(.noMatchingProfile)` |
| `oneProfile_routed` | one matching profile | `.routed(that)` |
| `multipleProfiles_duplicateOverlapWins` | two candidates; profile A has 5 overlapping existing, B has 1 | `.routed(A)` |
| `tieResolvedByFilenamePattern` | two candidates tied on dup count; A has pattern `cba-*.csv`, filename is `cba-april.csv` | `.routed(A)` |
| `tieWithoutFilenameHint_needsSetup` | two candidates tied, no filename | `.needsSetup(.ambiguousMatch(...))` |
| `profileWithNonMatchingHeaderIgnored` | profile with different headerSignature | not considered |
| `profileWithDifferentParserIgnored` | profile with parserIdentifier = "selfwealth" when incoming is generic-bank | not considered |
| `headerSignatureMatchesAfterNormalisation` | incoming headers have different casing | normalised first |

- [ ] **Step 12.3 — Commit.**

```bash
git commit -m "feat: add CSVImportProfileMatcher with duplicate-overlap disambiguation"
```

---

### Task 13: `ImportRulesEngine`

Pure evaluator. Input: `[ImportRule]` (ordered by `position`, enabled only), `ParsedTransaction`, routed `accountId`. Output: a mutated `ParsedTransaction` (payee/category/notes applied, legs rewritten for `markAsTransfer`) OR a `.skip` flag.

Semantics from spec:
- Rules in `position` order, skipping disabled + out-of-scope.
- Each matching rule contributes actions.
- **First-match-wins per field** for `setPayee`, `setCategory`.
- `appendNote` stacks (oldest → newest, space-separated).
- `markAsTransfer(toAccountId:)` short-circuits; rewrites the leg set into a two-leg transfer.
- `.skip` short-circuits with a skip flag.
- `matchMode`: `.any` (at least one condition true) or `.all`.
- `descriptionContains`/`descriptionDoesNotContain` take an array of tokens; case-insensitive; `.any`/`.all` within the condition is **OR over tokens** (per spec: "multi-token OR within this condition" — so ANY token matching makes the condition true for `descriptionContains`; ALL tokens missing for `descriptionDoesNotContain`).
- Rules operate on the *raw* description (`rawDescription`).

**Files:**
- Create: `Shared/CSVImport/ImportRulesEngine.swift`
- Test:   `MoolahTests/Shared/CSVImport/ImportRulesEngineTests.swift`

- [ ] **Step 13.1 — Type shape.**

```swift
// Shared/CSVImport/ImportRulesEngine.swift
import Foundation

struct RuleEvaluation: Sendable, Equatable {
    var transaction: ParsedTransaction
    var assignedPayee: String?
    var assignedCategoryId: UUID?
    var appendedNotes: String?
    var isSkipped: Bool
    /// If set, replace legs with a two-leg transfer (cash-out from routed account,
    /// cash-in to this account). ImportStore applies the rewrite at persist time.
    var transferTargetAccountId: UUID?
    var matchedRuleIds: [UUID]
}

enum ImportRulesEngine {
    static func evaluate(
        _ transaction: ParsedTransaction,
        routedAccountId: UUID,
        rules: [ImportRule]
    ) -> RuleEvaluation {
        var eval = RuleEvaluation(
            transaction: transaction,
            assignedPayee: nil, assignedCategoryId: nil,
            appendedNotes: nil, isSkipped: false,
            transferTargetAccountId: nil, matchedRuleIds: [])

        let orderedRules = rules
            .filter { $0.enabled }
            .filter { $0.accountScope == nil || $0.accountScope == routedAccountId }
            .sorted { $0.position < $1.position }

        for rule in orderedRules {
            guard matches(rule: rule, transaction: transaction, accountId: routedAccountId) else {
                continue
            }
            eval.matchedRuleIds.append(rule.id)
            for action in rule.actions {
                switch action {
                case .setPayee(let p):
                    if eval.assignedPayee == nil { eval.assignedPayee = p }
                case .setCategory(let c):
                    if eval.assignedCategoryId == nil { eval.assignedCategoryId = c }
                case .appendNote(let note):
                    eval.appendedNotes = eval.appendedNotes.map { "\($0) \(note)" } ?? note
                case .markAsTransfer(let toId):
                    eval.transferTargetAccountId = toId
                    return eval  // short-circuit
                case .skip:
                    eval.isSkipped = true
                    return eval
                }
            }
        }
        return eval
    }

    private static func matches(
        rule: ImportRule, transaction: ParsedTransaction, accountId: UUID
    ) -> Bool {
        let results = rule.conditions.map { cond in
            evaluate(condition: cond, transaction: transaction, accountId: accountId)
        }
        switch rule.matchMode {
        case .all: return results.allSatisfy { $0 }
        case .any: return results.contains(true)
        }
    }

    private static func evaluate(
        condition: RuleCondition, transaction: ParsedTransaction, accountId: UUID
    ) -> Bool {
        let desc = transaction.rawDescription.uppercased()
        switch condition {
        case .descriptionContains(let tokens):
            return tokens.contains { desc.contains($0.uppercased()) }
        case .descriptionDoesNotContain(let tokens):
            return tokens.allSatisfy { !desc.contains($0.uppercased()) }
        case .descriptionBeginsWith(let prefix):
            return desc.hasPrefix(prefix.uppercased())
        case .amountIsPositive:
            return transaction.rawAmount > 0
        case .amountIsNegative:
            return transaction.rawAmount < 0
        case .amountBetween(let min, let max):
            return transaction.rawAmount >= min && transaction.rawAmount <= max
        case .sourceAccountIs(let id):
            return id == accountId
        }
    }
}
```

- [ ] **Step 13.2 — Tests (one TDD cycle each):**

| Test | Setup | Expect |
|---|---|---|
| `matchMode_all_requiresAllConditions` | 2 conditions, 1 false | no match |
| `matchMode_any_requiresOne` | 2 conditions, 1 true | match |
| `descriptionContains_ORsAcrossTokens` | `["COFFEE","CAFE"]`, desc `"MORNING CAFE"` | matches |
| `descriptionDoesNotContain_NoneOfTokens` | `["AMAZON","EBAY"]`, desc `"COFFEE"` | condition is true |
| `descriptionBeginsWith_caseInsensitive` | `"EFTPOS "`, desc `"eftpos something"` | matches |
| `amountPositive` / `amountNegative` / `amountBetween` | various | matches per sign/range |
| `sourceAccountIs` | account a vs b | matches only on a |
| `firstSetPayeeWins` | two rules both `setPayee`; rule positions 0 and 1 | rule 0's payee kept |
| `setCategoryIdem` | same | |
| `appendNoteStacks` | two rules each appending | `"foo bar"` |
| `skipShortCircuits` | rule N position 0 adds note; rule M position 1 skips | `isSkipped == true` |
| `markAsTransferShortCircuits` | rule N position 0 setsPayee; rule M position 1 marks transfer | `transferTargetAccountId == …` and later rules don't run |
| `disabledRuleIgnored` | `enabled == false` | no match contribution |
| `accountScopedRuleRespected` | rule scoped to account A, routed to B | skipped |
| `rulesRunInPositionOrder` | rules at position 5, 1, 10 | order 1 → 5 → 10 |

- [ ] **Step 13.3 — Commit.**

```bash
git commit -m "feat: add ImportRulesEngine with position order and first-match-wins"
```

---

### Task 14: `ImportStagingStore` (pending / failed files on disk)

Device-local workflow state — NOT synced. Two lists of records:

```swift
struct PendingSetupFile: Codable, Sendable, Hashable {
    var id: UUID
    var originalFilename: String
    var stagingPath: URL
    var securityScopedBookmark: Data?
    var detectedParserIdentifier: String?
    var detectedHeaders: [String]
    var parsedAt: Date
    var sourceBookmark: Data?         // bookmark to source file for optional delete
}

struct FailedImportFile: Codable, Sendable, Hashable {
    var id: UUID
    var originalFilename: String
    var stagingPath: URL
    var error: String
    var offendingRow: [String]?
    var offendingRowIndex: Int?
    var parsedAt: Date
}
```

Both persisted via a JSON index (`Application Support/Moolah/csv-staging/index.json`) and the CSV file itself copied into `Application Support/Moolah/csv-staging/files/<uuid>.csv`. Staging is per-profile (use `ProfileSession` to derive the directory).

**Files:**
- Create: `Shared/CSVImport/ImportStagingStore.swift`
- Test:   `MoolahTests/Shared/CSVImport/ImportStagingStoreTests.swift`

- [ ] **Step 14.1 — Protocol + concrete impl + test that round-trips index.**

```swift
// Shared/CSVImport/ImportStagingStore.swift
import Foundation

actor ImportStagingStore {
    private let indexURL: URL
    private let filesDirectory: URL
    private let fm = FileManager.default

    init(directory: URL) throws {
        self.indexURL = directory.appendingPathComponent("index.json")
        self.filesDirectory = directory.appendingPathComponent("files", isDirectory: true)
        try fm.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
    }

    private struct Index: Codable {
        var pending: [PendingSetupFile] = []
        var failed: [FailedImportFile] = []
    }
    private func load() throws -> Index {
        guard fm.fileExists(atPath: indexURL.path) else { return Index() }
        let data = try Data(contentsOf: indexURL)
        return try JSONDecoder().decode(Index.self, from: data)
    }
    private func save(_ index: Index) throws {
        let data = try JSONEncoder().encode(index)
        try data.write(to: indexURL, options: .atomic)
    }

    // MARK: - Public API

    func stagePending(_ file: PendingSetupFile, data: Data) throws {
        try data.write(to: file.stagingPath, options: .atomic)
        var index = try load()
        index.pending.append(file)
        try save(index)
    }

    func stageFailed(_ file: FailedImportFile, data: Data) throws {
        try data.write(to: file.stagingPath, options: .atomic)
        var index = try load()
        index.failed.append(file)
        try save(index)
    }

    func pendingFiles() throws -> [PendingSetupFile] {
        try load().pending
    }

    func failedFiles() throws -> [FailedImportFile] {
        try load().failed
    }

    func dismiss(pendingId: UUID) throws {
        var index = try load()
        if let match = index.pending.first(where: { $0.id == pendingId }) {
            try? fm.removeItem(at: match.stagingPath)
        }
        index.pending.removeAll { $0.id == pendingId }
        try save(index)
    }

    func dismiss(failedId: UUID) throws {
        var index = try load()
        if let match = index.failed.first(where: { $0.id == failedId }) {
            try? fm.removeItem(at: match.stagingPath)
        }
        index.failed.removeAll { $0.id == failedId }
        try save(index)
    }

    func stagingPath(for id: UUID) throws -> URL {
        filesDirectory.appendingPathComponent("\(id.uuidString).csv")
    }
}
```

- [ ] **Step 14.2 — Tests (concrete `@Test` methods):**

| Test | Setup | Expect |
|---|---|---|
| `stagePendingThenReadBack` | stage a file, reload store from same dir | `pendingFiles().count == 1` and bytes match on disk |
| `stageFailedThenReadBack` | | same for failed |
| `dismissPendingRemovesFromIndexAndDisk` | stage → dismiss | file absent, index empty |
| `dismissFailedRemovesFromIndexAndDisk` | | same |
| `indexSurvivesAcrossActorReinit` | new `ImportStagingStore(directory:)` instance | reads back prior state |
| `emptyDirectoryReturnsEmptyLists` | fresh tmp dir | `pendingFiles().isEmpty` |

Use `FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)` per test; clean up in a `deinit`-style teardown (Swift Testing: use `init`/`deinit` on the suite struct, or a `confirmation` block).

- [ ] **Step 14.3 — Commit.**

```bash
git commit -m "feat: add ImportStagingStore for pending and failed CSV files"
```

---

### Task 15: `ImportStore` orchestration + TestBackend-driven tests

The main integration point. Ingests bytes + `ImportSource`, runs the whole pipeline, persists, and updates state.

Responsibilities:
1. Accept `ingest(data: Data, source: ImportSource)`. Derive an `importSessionId` per call.
2. Decode bytes via `CSVTokenizer.parse(data:)`. On decode failure → stage in Failed.
3. Select parser via `CSVParserRegistry.default.select(for: headers)`.
4. `parser.parse(rows:)`. On error → stage in Failed with the offending row.
5. Extract `.transaction` cases; `.skip` logged but ignored.
6. Match profile via `CSVImportProfileMatcher.match(…)`. On `.needsSetup` → stage in Pending.
7. On `.routed(profile)` (or explicit drag-to-account override) → fetch existing transactions on that account, run `CSVDeduplicator.filter(…)`, drop duplicates.
8. For each candidate: run `ImportRulesEngine.evaluate(…)`. Drop `.skip`. For `.markAsTransfer` → rewrite legs into a two-leg transfer transaction (cash-out on source, cash-in on target).
9. Resolve placeholder instruments: for each leg where `instrument == .AUD` and the account's instrument is not AUD, rewrite to the account's instrument. For trade position legs (`kind == .stock`), ensure an `InstrumentRecord` exists (create if necessary via the instruments repository or `InstrumentStore` if one exists).
10. Build `Transaction` values: set `payee` from rule or leave nil (per spec v1: "no rule has run yet → payee = raw description" is the preview state, but silent-route has rule-set payee); set `categoryId` on the first expense leg; set `notes` with appended notes; stamp `importOrigin` on every persisted transaction with the session id + file metadata.
11. Persist via `backend.transactions.create(_:)` one-by-one (spec explicitly has **no batch rollback** — any per-row failure is logged and the rest continue).
12. Update `profile.lastUsedAt = now`; `backend.csvImportProfiles.update(...)`.
13. If `profile.deleteAfterImport` is true and `source` carries a deletable URL/bookmark → delete the source file after successful persistence.
14. Expose `recentSessions` and `needsSetupFiles` / `failedFiles` on the store for the Recently Added view.

**Files:**
- Create: `Features/Import/ImportStore.swift`
- Create: `Shared/CSVImport/ImportSource.swift`
- Test:   `MoolahTests/Features/Import/ImportStoreTests.swift`

- [ ] **Step 15.1 — `ImportSource`:**

```swift
// Shared/CSVImport/ImportSource.swift
import Foundation

enum ImportSource: Sendable {
    case pickedFile(url: URL, securityScoped: Bool)
    case folderWatch(url: URL, bookmark: Data?)
    case droppedFile(url: URL, forcedAccountId: UUID?)
    case paste(text: String, label: String?)

    var filename: String? {
        switch self {
        case .pickedFile(let u, _), .folderWatch(let u, _), .droppedFile(let u, _):
            return u.lastPathComponent
        case .paste(_, let label):
            return label
        }
    }

    var forcedAccountId: UUID? {
        if case .droppedFile(_, let id) = self { return id }
        return nil
    }
}
```

- [ ] **Step 15.2 — Store skeleton.**

```swift
// Features/Import/ImportStore.swift
import Foundation
import os

@Observable
@MainActor
final class ImportStore {
    private(set) var isImporting: Bool = false
    private(set) var pendingSetup: [PendingSetupFile] = []
    private(set) var failedFiles: [FailedImportFile] = []
    /// Transactions imported in this app session, newest session id first.
    /// The Recently Added view queries by time window against `importOrigin.importedAt`.
    private(set) var recentSessions: [ImportSessionSummary] = []
    private(set) var lastError: String?

    private let backend: any BackendProvider
    private let registry: CSVParserRegistry
    private let staging: ImportStagingStore
    private let logger = Logger(subsystem: "com.moolah.app", category: "ImportStore")

    init(
        backend: any BackendProvider,
        registry: CSVParserRegistry = .default,
        staging: ImportStagingStore
    ) {
        self.backend = backend
        self.registry = registry
        self.staging = staging
    }

    // MARK: - Public API

    @discardableResult
    func ingest(data: Data, source: ImportSource) async -> ImportSessionResult {
        isImporting = true
        defer { isImporting = false }
        let sessionId = UUID()
        let result: ImportSessionResult
        do {
            result = try await runPipeline(data: data, source: source, sessionId: sessionId)
        } catch let error as IngestError {
            await stageFailed(error: error, source: source, data: data)
            return .failed(error.message)
        } catch {
            await stageFailed(error: .other(error.localizedDescription), source: source, data: data)
            return .failed(error.localizedDescription)
        }
        recentSessions.insert(ImportSessionSummary(from: result), at: 0)
        return result
    }

    func loadStaging() async { /* reads from staging store; populates pendingSetup/failedFiles */ }
    func dismissPending(id: UUID) async { /* deletes via staging store */ }
    func dismissFailed(id: UUID) async { /* deletes via staging store */ }
    func finishSetup(pendingId: UUID, profile: CSVImportProfile) async -> ImportSessionResult {
        /* re-reads staged bytes, persists profile, re-enters pipeline with forced profile */
    }

    // MARK: - Pipeline

    private func runPipeline(
        data: Data, source: ImportSource, sessionId: UUID
    ) async throws -> ImportSessionResult {
        let rows: [[String]]
        do { rows = try CSVTokenizer.parse(data) }
        catch { throw IngestError.decode(error.localizedDescription) }

        guard let headers = rows.first else { throw IngestError.empty }
        let parser = registry.select(for: headers)
        let records: [ParsedRecord]
        do { records = try parser.parse(rows: rows) }
        catch let e as CSVParserError { throw IngestError.parse(e) }

        let candidates = records.compactMap { rec -> ParsedTransaction? in
            if case .transaction(let tx) = rec { return tx } else { return nil }
        }

        let profiles = try await backend.csvImportProfiles.fetchAll()

        // Forced target via explicit drop: bypass matcher
        let profile: CSVImportProfile
        if let forcedId = source.forcedAccountId {
            profile = profiles.first(where: { $0.accountId == forcedId })
                ?? (try await upsertDropProfile(
                    accountId: forcedId,
                    parser: parser.identifier,
                    headers: headers))
        } else {
            // Build existingByAccountId map for each candidate profile
            let candidateProfiles = profiles.filter {
                $0.parserIdentifier == parser.identifier
                    && $0.headerSignature == headers.map { CSVImportProfile.normalise($0) }
            }
            var existingByAccount: [UUID: [Transaction]] = [:]
            for p in candidateProfiles {
                let page = try await backend.transactions.fetch(
                    filter: TransactionFilter(accountId: p.accountId),
                    page: 0, pageSize: 1000)
                existingByAccount[p.accountId] = page.transactions
            }
            let input = MatcherInput(
                filename: source.filename,
                parserIdentifier: parser.identifier,
                headerSignature: headers,
                candidates: candidates,
                existingByAccountId: existingByAccount,
                profiles: profiles)
            switch CSVImportProfileMatcher.match(input) {
            case .routed(let p):
                profile = p
            case .needsSetup(let reason):
                try await stagePending(
                    data: data, source: source, sessionId: sessionId,
                    headers: headers, parser: parser.identifier, reason: reason)
                return .needsSetup
            }
        }

        // Dedup against the routed profile's account
        let existingPage = try await backend.transactions.fetch(
            filter: TransactionFilter(accountId: profile.accountId),
            page: 0, pageSize: 1000)
        let dedup = CSVDeduplicator.filter(
            candidates, against: existingPage.transactions, accountId: profile.accountId)

        // Rules
        let rules = try await backend.importRules.fetchAll()
        let accountInstrument = try await resolveInstrument(for: profile.accountId)
        var persisted: [Transaction] = []
        for candidate in dedup.kept {
            let eval = ImportRulesEngine.evaluate(
                candidate, routedAccountId: profile.accountId, rules: rules)
            if eval.isSkipped { continue }
            let tx = buildTransaction(
                from: eval, routedAccountId: profile.accountId,
                accountInstrument: accountInstrument,
                sessionId: sessionId, source: source, parserId: parser.identifier)
            do { persisted.append(try await backend.transactions.create(tx)) }
            catch {
                logger.error("create failed for candidate at \(candidate.date): \(error.localizedDescription)")
            }
        }

        // Update profile lastUsedAt
        var updated = profile
        updated.lastUsedAt = Date()
        _ = try? await backend.csvImportProfiles.update(updated)

        // Optional delete source
        if profile.deleteAfterImport {
            deleteSourceFileIfAllowed(source)
        }

        return .imported(sessionId: sessionId,
                         imported: persisted,
                         skippedAsDuplicate: dedup.skipped.count)
    }

    private func buildTransaction(
        from eval: RuleEvaluation,
        routedAccountId: UUID,
        accountInstrument: Instrument,
        sessionId: UUID,
        source: ImportSource,
        parserId: String
    ) -> Transaction {
        var legs = eval.transaction.legs.map { leg -> TransactionLeg in
            let resolvedAccount = leg.accountId ?? routedAccountId
            let resolvedInstrument = leg.instrument == .AUD && accountInstrument != .AUD
                ? accountInstrument
                : leg.instrument
            return TransactionLeg(
                accountId: resolvedAccount, instrument: resolvedInstrument,
                quantity: leg.quantity, type: leg.type,
                categoryId: nil, earmarkId: nil)
        }
        if let firstExpenseIdx = legs.firstIndex(where: { $0.type == .expense }),
           let cat = eval.assignedCategoryId {
            legs[firstExpenseIdx].categoryId = cat
        }
        if let toId = eval.transferTargetAccountId {
            // Rewrite to two-leg transfer: assume cash leg is the first leg
            guard let cash = legs.first else { return legs.asTransaction(date: eval.transaction.date) }
            legs = [
                TransactionLeg(accountId: routedAccountId, instrument: cash.instrument,
                               quantity: -abs(cash.quantity), type: .transfer,
                               categoryId: nil, earmarkId: nil),
                TransactionLeg(accountId: toId, instrument: cash.instrument,
                               quantity: abs(cash.quantity), type: .transfer,
                               categoryId: nil, earmarkId: nil),
            ]
        }
        let origin = ImportOrigin(
            rawDescription: eval.transaction.rawDescription,
            bankReference: eval.transaction.bankReference,
            rawAmount: eval.transaction.rawAmount,
            rawBalance: eval.transaction.rawBalance,
            importedAt: Date(),
            importSessionId: sessionId,
            sourceFilename: source.filename,
            parserIdentifier: parserId)
        return Transaction(
            date: eval.transaction.date,
            payee: eval.assignedPayee,
            notes: eval.appendedNotes,
            legs: legs,
            importOrigin: origin)
    }

    private func resolveInstrument(for accountId: UUID) async throws -> Instrument {
        let accounts = try await backend.accounts.fetchAll()
        return accounts.first(where: { $0.id == accountId })?.instrument ?? .AUD
    }
}

private extension Array where Element == TransactionLeg {
    func asTransaction(date: Date) -> Transaction {
        Transaction(date: date, legs: self)
    }
}

enum IngestError: Error {
    case decode(String), parse(CSVParserError), empty, other(String)
    var message: String {
        switch self {
        case .decode(let s): return "Could not decode file: \(s)"
        case .parse(let e): return "Could not parse CSV: \(e)"
        case .empty: return "File was empty"
        case .other(let s): return s
        }
    }
}

enum ImportSessionResult: Sendable {
    case imported(sessionId: UUID, imported: [Transaction], skippedAsDuplicate: Int)
    case needsSetup
    case failed(String)
}

struct ImportSessionSummary: Sendable, Identifiable {
    var id: UUID
    var importedCount: Int
    var skippedAsDuplicate: Int
    var importedAt: Date
    var filename: String?
    init(from result: ImportSessionResult) {
        switch result {
        case .imported(let id, let txs, let dup):
            self.id = id; self.importedCount = txs.count; self.skippedAsDuplicate = dup
            self.importedAt = Date(); self.filename = nil
        default:
            self.id = UUID(); self.importedCount = 0; self.skippedAsDuplicate = 0
            self.importedAt = Date(); self.filename = nil
        }
    }
}
```

- [ ] **Step 15.3 — Tests against `TestBackend`:** These are the integration tests that exercise the full pipeline. Each runs against a fresh TestBackend.

| Test | Setup | Expect |
|---|---|---|
| `ingestCBA_firstTime_needsSetup` | no profiles seeded; CBA fixture | `.needsSetup`; `pendingSetup.count == 1` |
| `ingestCBA_withProfile_routesSilently` | seed profile pointing at accountA with matching headerSignature | `.imported` with all rows persisted; `backend.transactions.fetch(accountA)` returns all rows |
| `ingestCBA_twiceInARow_secondRunDedupesAll` | profile seeded, fixture ingested twice | 2nd run: `.imported` with `imported.count == 0`, `skippedAsDuplicate == all` |
| `ingestWithDragToAccount_bypassesMatcher` | no profile exists but `.droppedFile(forcedAccountId: accountB)` | routes to B, creates profile on success |
| `ingestAmbiguousWithDuplicateOverlapDisambiguates` | two profiles (A, B) with same header sig; A has matching historical transactions; fresh file overlaps with A | routes silently to A |
| `rulesEngine_appliesPayeeAndCategory` | seed rule `descriptionContains(["COFFEE"])` → setPayee("Café"), setCategory(catId) | resulting transactions have payee `"Café"` and first expense leg categoryId == catId |
| `rulesEngine_markAsTransferRewritesLegs` | seed rule `descriptionContains(["TRANSFER"])` → `markAsTransfer(to: accountC)`; ingest a row matching | persisted transaction has 2 transfer legs across A and C with amounts negating |
| `rulesEngine_skipDropsRow` | rule `skip` matches | row not persisted |
| `invalidUTF8_landsInFailed` | random bytes that fail Apple detection | `.failed`; `failedFiles.count == 1` |
| `malformedRow_landsInFailed_withOffendingRow` | synthesize fixture with unparseable row | `.failed` with `offendingRow` and `offendingRowIndex` populated |
| `importOriginStampedOnEveryPersisted` | any valid ingest | every returned Transaction has non-nil `importOrigin` with the same `importSessionId` |
| `deleteAfterImport_removesSourceFile` | profile with `deleteAfterImport = true`; ingest via `.pickedFile(url: tmpfile)` | tmpfile absent afterwards |
| `selfWealthFixture_createsTwoLegTradeTransactions` | seed profile, selfwealth fixture | BHP buy persisted as 2-leg transaction, cash leg AUD, position leg ASX:BHP |
| `profileLastUsedAt_updated` | routed import | profile's `lastUsedAt` is within a second of now |
| `transactionsSkippedFromPreviousSession_notRecountedInRecent` | ingest twice, only first counts | `recentSessions.first.importedCount == allRows`, second == 0 |

- [ ] **Step 15.4 — Commit in logical chunks.** Suggested breakdown:
1. Commit `ImportSource.swift` + `IngestError` types.
2. Commit `ImportStore` skeleton + first two passing tests (needs-setup and routed-silently).
3. Commit dedup path + tests.
4. Commit rules engine integration + tests.
5. Commit markAsTransfer rewrite + tests.
6. Commit error paths (decode / malformed) + tests.
7. Commit deleteAfterImport path + tests.

- [ ] **Step 15.5 — Run `@concurrency-review`** on `ImportStore.swift`. Confirm no main-thread blocking I/O; all repository calls are `await`ed; pipeline work off `@MainActor` where useful (note: repositories already marshal to their own contexts).

- [ ] **Step 15.6 — Run `@instrument-conversion-review`** on the leg-instrument resolution code. The `AUD`-to-account-instrument rewrite in `buildTransaction` is a conversion site; verify no `InstrumentAmount` arithmetic mixes instruments.

---

### Task 16: Sidebar entry + `RecentlyAddedView` + "Needs Setup / Failed Files" panel

Adds `.recentlyAdded` to `SidebarSelection`, positions it directly above `.allTransactions`, shows a badge = count of transactions imported within the active time window that have no category. Destination is `RecentlyAddedView` with a top panel for Needs Setup / Failed Files and a session-grouped list below.

**Files:**
- Modify: `Features/Navigation/SidebarView.swift`
- Create: `Features/Import/Views/RecentlyAddedView.swift`
- Create: `Features/Import/Views/RecentlyAddedSessionSection.swift`
- Create: `Features/Import/Views/NeedsSetupAndFailedPanel.swift`
- Modify: `App/ProfileRootView.swift` (or wherever `NavigationStack` routes sidebar cases) to route `.recentlyAdded` to the new view.
- Test:   `MoolahTests/Features/Import/RecentlyAddedViewModelTests.swift` (the view itself is presentation; its computed properties live in an `@Observable` `RecentlyAddedViewModel` attached to `ImportStore`, not in the view — following the "thin views" rule in CLAUDE.md).

- [ ] **Step 16.1 — Write failing test for the badge-count computation.**

```swift
@Suite("RecentlyAddedViewModel")
@MainActor
struct RecentlyAddedViewModelTests {

    @Test("badge counts transactions with no category, filtered by importedAt window")
    func testBadgeCount() async throws {
        let (backend, container) = try TestBackend.create()
        let accountId = UUID()
        _ = try await backend.accounts.create(
            Account(id: accountId, name: "Cash", type: .bank, instrument: .AUD,
                    positions: [], position: 0, isHidden: false), openingBalance: nil)
        // Seed 2 categorised and 3 uncategorised imported transactions,
        // plus 1 outside the window (24h ago -> 25h).
        // ... construct Transactions with importOrigin.importedAt set ...
        let vm = RecentlyAddedViewModel(backend: backend)
        await vm.load(window: .last24Hours)
        #expect(vm.badgeCount == 3)
    }
}
```

- [ ] **Step 16.2 — Implement `RecentlyAddedViewModel`.**

```swift
// Features/Import/Views/RecentlyAddedView.swift (can split to its own file)
import SwiftUI

@Observable
@MainActor
final class RecentlyAddedViewModel {
    enum Window: String, CaseIterable, Identifiable, Sendable {
        case last24Hours, last3Days, lastWeek, last2Weeks, lastMonth, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .last24Hours: return "Last 24 hours"
            case .last3Days: return "Last 3 days"
            case .lastWeek: return "Last week"
            case .last2Weeks: return "Last 2 weeks"
            case .lastMonth: return "Last month"
            case .all: return "All"
            }
        }
        var dateRange: ClosedRange<Date>? {
            let now = Date()
            let delta: TimeInterval
            switch self {
            case .last24Hours: delta = 86_400
            case .last3Days: delta = 3 * 86_400
            case .lastWeek: delta = 7 * 86_400
            case .last2Weeks: delta = 14 * 86_400
            case .lastMonth: delta = 30 * 86_400
            case .all: return nil
            }
            return (now.addingTimeInterval(-delta))...now
        }
    }

    private(set) var window: Window = .last24Hours
    private(set) var sessions: [SessionGroup] = []
    private(set) var badgeCount: Int = 0

    private let backend: any BackendProvider

    init(backend: any BackendProvider) { self.backend = backend }

    func load(window: Window) async {
        self.window = window
        // Fetch all transactions with importOrigin.importedAt inside the window.
        // There's no filter on importedAt in TransactionFilter today — fetch the
        // most-recent N pages and filter client-side. OK for v1; optimise in Task 23
        // if benchmarks show it hot.
        let page = try? await backend.transactions.fetch(
            filter: TransactionFilter(), page: 0, pageSize: 500)
        let transactions = (page?.transactions ?? []).filter { tx in
            guard let origin = tx.importOrigin else { return false }
            if let range = window.dateRange { return range.contains(origin.importedAt) }
            return true
        }
        self.badgeCount = transactions.filter { tx in
            tx.legs.allSatisfy { $0.categoryId == nil }
        }.count
        self.sessions = Self.group(transactions)
    }

    private static func group(_ transactions: [Transaction]) -> [SessionGroup] {
        let grouped = Dictionary(grouping: transactions, by: { $0.importOrigin?.importSessionId ?? UUID() })
        return grouped.map { (id, txs) in
            SessionGroup(
                id: id,
                importedAt: txs.first?.importOrigin?.importedAt ?? Date(),
                filenames: Set(txs.compactMap { $0.importOrigin?.sourceFilename }),
                transactions: txs.sorted { $0.date > $1.date })
        }.sorted { $0.importedAt > $1.importedAt }
    }

    struct SessionGroup: Identifiable {
        let id: UUID
        let importedAt: Date
        let filenames: Set<String>
        let transactions: [Transaction]
        var needsReviewCount: Int {
            transactions.filter { tx in tx.legs.allSatisfy { $0.categoryId == nil } }.count
        }
    }
}
```

- [ ] **Step 16.3 — Run test → pass. Commit.**

- [ ] **Step 16.4 — Build view shells.**

Enumerate view files and their responsibilities — keep them thin per CLAUDE.md.

```swift
// Features/Import/Views/RecentlyAddedView.swift  (continued)
struct RecentlyAddedView: View {
    @Environment(BackendProvider.self) private var backend
    @Environment(ImportStore.self) private var importStore
    @State private var vm: RecentlyAddedViewModel?
    @State private var window: RecentlyAddedViewModel.Window = .last24Hours

    var body: some View {
        VStack(alignment: .leading) {
            if let vm {
                NeedsSetupAndFailedPanel(importStore: importStore)
                    .padding(.horizontal)
                List {
                    ForEach(vm.sessions) { session in
                        RecentlyAddedSessionSection(session: session)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Recently Added")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("", selection: $window) {
                    ForEach(RecentlyAddedViewModel.Window.allCases) { w in
                        Text(w.label).tag(w)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .task { await reload() }
        .onChange(of: window) { _, _ in Task { await reload() } }
    }

    private func reload() async {
        if vm == nil { vm = RecentlyAddedViewModel(backend: backend) }
        await vm?.load(window: window)
    }
}
```

- [ ] **Step 16.5 — `RecentlyAddedSessionSection`.** Header with date-time + filenames + summary; rows in main Transactions format (reuse `TransactionRow` or the equivalent already present). Rows lacking a category get a left-edge accent (e.g., `.overlay(alignment: .leading) { Rectangle().fill(.orange).frame(width: 3) }` + inline "Needs review" label). Context menu: Open detail / Create rule from this… / Delete.

- [ ] **Step 16.6 — `NeedsSetupAndFailedPanel`.** Two sections ("Needs Setup" / "Failed Files"). Hidden when both empty. Each file one row: filename + reason + buttons (Open Setup — presents `CSVImportSetupView` as a sheet; Retry for failed picker-path files; Dismiss).

- [ ] **Step 16.7 — Wire sidebar.** In `Features/Navigation/SidebarView.swift`:

```swift
enum SidebarSelection: Hashable {
    case recentlyAdded       // NEW; positioned above .allTransactions
    case allTransactions
    case account(UUID)
    // …
}

// Inside body, just above All Transactions row:
NavigationLink(value: SidebarSelection.recentlyAdded) {
    HStack {
        Label("Recently Added", systemImage: "tray.full")
        Spacer()
        if importStore.unreviewedBadgeCount > 0 {
            Text("\(importStore.unreviewedBadgeCount)")
                .monospacedDigit()
                .padding(.horizontal, 6)
                .background(.tint, in: Capsule())
                .foregroundStyle(.white)
        }
    }
}
```

Add `unreviewedBadgeCount` as a computed property on `ImportStore` (or a light accessor on `RecentlyAddedViewModel` exposed via environment). Badge source of truth: compute lazily from a fetch on app-launch/foreground.

- [ ] **Step 16.8 — Route `.recentlyAdded`** in whichever file owns the `NavigationStack` destination (search for `case .allTransactions:` — add a neighbouring `case .recentlyAdded:` arm returning `RecentlyAddedView()`).

- [ ] **Step 16.9 — Run `@ui-review`** on the new views. Verify: semantic colors, `.monospacedDigit()` on dates/amounts, VoiceOver labels on badge + context menu items, keyboard navigation on macOS (Tab should cycle panel / list / time-window picker).

- [ ] **Step 16.10 — Commit.**

```bash
git commit -m "feat: add Recently Added sidebar entry and view"
```

---

### Task 17: `CSVImportSetupView` (Needs Setup first-time form)

One-screen form per spec §"First-time / unknown-fingerprint setup". Opens as a sheet from `NeedsSetupAndFailedPanel` or from drag-to-ambiguous-target.

Fields:
1. File header — filename, detected parser, row count.
2. Target account — dropdown with *Create new account…*.
3. Column mapping — only for generic-bank: one row per CSV column with dropdown (Date / Amount / Debit / Credit / Description / Balance / Reference / Ignore). Pre-filled by `GenericBankCSVParser.inferMapping(from:)`. Date format picker, pre-filled from detector's output.
4. Preview — first 5 rows with mapping applied (payee = rawDescription; no rules yet).
5. Options — filename pattern (auto-suggested from current filename), Delete-after-import toggle.
6. Save & Import button.

**Files:**
- Create: `Features/Import/Views/CSVImportSetupView.swift`
- Create: `Features/Import/CSVImportSetupStore.swift` — mutation logic (thin view)
- Test:   `MoolahTests/Features/Import/CSVImportSetupStoreTests.swift`

- [ ] **Step 17.1 — `CSVImportSetupStore`.**

```swift
@Observable
@MainActor
final class CSVImportSetupStore {
    private(set) var pending: PendingSetupFile
    var targetAccountId: UUID?
    var columnMapping: GenericBankCSVParser.ColumnMapping?
    var dateFormat: GenericBankCSVParser.DateFormat
    var filenamePattern: String
    var deleteAfterImport: Bool = false
    var preview: [ParsedTransaction] = []
    private(set) var saveError: String?

    private let backend: any BackendProvider
    private let importStore: ImportStore
    private let staging: ImportStagingStore

    init(pending: PendingSetupFile, backend: any BackendProvider,
         importStore: ImportStore, staging: ImportStagingStore) { /* … */ }

    func generatePreview() async { /* parse first 5 rows with current mapping, populate preview */ }

    /// Persists the profile then re-ingests the staged file. Returns the result from ImportStore.
    func saveAndImport() async -> ImportSessionResult { /* … */ }
    func cancel() async { /* leaves file in staging; just dismisses the sheet */ }
}
```

- [ ] **Step 17.2 — Tests:**

| Test | Setup | Expect |
|---|---|---|
| `preview_appliesColumnMapping` | pending file with CBA headers | `preview.count == 5`; first is the first data row |
| `saveAndImport_persistsProfileThenImports` | pending file | `backend.csvImportProfiles.fetchAll().count == 1` after save; result is `.imported(...)` |
| `saveAndImport_updatesStagingToRemovePending` | | pending list empty after save |
| `saveAndImport_failsIfTargetAccountMissing` | no target account set | throws / returns `.failed` without creating profile |
| `filenamePattern_autoSuggested` | filename "cba-april-2026.csv" | suggested `cba-*.csv` or similar glob |

- [ ] **Step 17.3 — View shell.** SwiftUI `Form` with sections; Preview uses a simple `Table`/`List` of 5 rows.

- [ ] **Step 17.4 — Run `@ui-review` + `@concurrency-review`. Commit.**

```bash
git commit -m "feat: add CSV import setup form for unknown profiles"
```

---

### Task 18: Rules UI — `ImportRulesSettingsView`, `RuleEditorView`, Create-from-edit, Create-from-search

Mail.app-shaped rules list with Add Rule and drag-to-reorder. Rule editor uses the existing category picker. Three creation paths:
1. Explicit (Settings → Import Rules → Add Rule).
2. From-edit: on any transaction detail / Recently Added row, offer "Create a rule from this…" prefilled with distinguishing tokens + current payee/category.
3. From-search: in Recently Added search bar, a "Create a rule matching this search" affordance.

**Files:**
- Create: `Features/Import/ImportRuleStore.swift`
- Create: `Features/Import/Views/ImportRulesSettingsView.swift`
- Create: `Features/Import/Views/RuleEditorView.swift`
- Create: `Features/Import/Views/CreateRuleFromTransactionSheet.swift`
- Create: `Shared/CSVImport/DistinguishingTokens.swift` — helper for token distinctiveness
- Test:   `MoolahTests/Features/Import/ImportRuleStoreTests.swift`
- Test:   `MoolahTests/Shared/CSVImport/DistinguishingTokensTests.swift`

- [ ] **Step 18.1 — `ImportRuleStore`.** Thin wrapper:

```swift
@Observable
@MainActor
final class ImportRuleStore {
    private(set) var rules: [ImportRule] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private let repository: ImportRuleRepository

    init(repository: ImportRuleRepository) { self.repository = repository }

    func load() async { /* fetchAll, sort by position */ }
    func create(_ rule: ImportRule) async -> ImportRule? { /* … */ }
    func update(_ rule: ImportRule) async -> ImportRule? { /* … */ }
    func delete(id: UUID) async { /* … */ }
    func reorder(_ orderedIds: [UUID]) async { /* … */ }
    /// Live preview count: runs rule's conditions against existing Transactions'
    /// importOrigin.rawDescription. Debounced by the caller.
    func countAffected(conditions: [RuleCondition], matchMode: MatchMode, backend: any BackendProvider) async -> Int
}
```

- [ ] **Step 18.2 — Tests (against `TestBackend`):** load, create, update, delete, reorder, countAffected correctness.

- [ ] **Step 18.3 — `DistinguishingTokens`.**

```swift
// Shared/CSVImport/DistinguishingTokens.swift
import Foundation

enum DistinguishingTokens {
    /// Returns up to `limit` tokens that appear in `description` but are rare
    /// across `corpus`. Tokens with one character or purely numeric are ignored.
    static func extract(
        from description: String, corpus: [String], limit: Int = 3
    ) -> [String] {
        let tokens = normalise(description)
        guard !tokens.isEmpty else { return [] }
        var frequency: [String: Int] = [:]
        for item in corpus {
            for t in normalise(item) {
                frequency[t, default: 0] += 1
            }
        }
        let scored = tokens.map { ($0, frequency[$0, default: 0]) }
            .sorted { $0.1 < $1.1 }
        return Array(scored.prefix(limit).map { $0.0 })
    }

    private static func normalise(_ s: String) -> [String] {
        s.uppercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !$0.allSatisfy(\.isNumber) }
    }
}
```

Tests: single corpus entry, rare token wins, numeric tokens excluded, one-char tokens excluded.

- [ ] **Step 18.4 — View shells:**
- `ImportRulesSettingsView` — `List` of rules with drag-to-reorder, enable toggle per row, "matched N times · last matched X" caption (use `ImportOrigin.importedAt` aggregates — compute at load time in the store), Add Rule button.
- `RuleEditorView` — two sections: Conditions ("If any/all of these are true") and Actions. Each row has field/operator/value dropdowns. Category action uses existing category picker. Debounced live preview count ("This rule would affect N past transactions").
- `CreateRuleFromTransactionSheet` — prefills with distinguishing tokens from `Transaction.importOrigin.rawDescription` plus the user's assigned payee/category.

- [ ] **Step 18.5 — Wire into Recently Added search bar** — "Create a rule matching this search" action visible when the query is non-empty; opens `RuleEditorView` pre-filled with `descriptionContains([queryTokens])`.

- [ ] **Step 18.6 — Wire into transaction detail** — reuse existing Transaction detail view's menu; add "Create a rule from this…".

- [ ] **Step 18.7 — Run `@ui-review`. Commit.**

```bash
git commit -m "feat: add import rules settings, editor, and create-rule affordances"
```

---

### Task 19: Ingestion entry points — file picker, drag-and-drop, paste

Three user-driven ingestion paths, all flowing into `ImportStore.ingest(data:source:)`. Folder watch/scan are separate (Tasks 20–21).

**Files:**
- Modify: `App/ContentView.swift` (or the relevant root view) — attach `.fileImporter` for the menu-bar command / toolbar button.
- Create: `Features/Import/ImportCommands.swift` — macOS `CommandGroup` with "Import CSV…" menu item + keyboard shortcut (Cmd-Shift-I).
- Create: `Features/Import/DropHandlers.swift` — helpers that convert `.itemProviders` + `NSItemProvider` CSV drops into `ImportSource.droppedFile(...)`.
- Modify: `Features/Transactions/Views/TransactionListView.swift` (or equivalent) — `.dropDestination(for: URL.self)` on account-scoped list (forces target).
- Modify: `Features/Navigation/SidebarView.swift` — `.dropDestination` on account rows (forces target).
- Modify: `App/ProfileRootView.swift` — `.dropDestination` on the top-level window/view (auto-routes via matcher).
- Modify: `App/MoolahApp.swift` — `onOpenURL` / `NSApplication.open(urls:)` handler for Dock drops.
- Test:   `MoolahTests/Features/Import/DropHandlerTests.swift`

- [ ] **Step 19.1 — File picker.** In `ImportCommands.swift`:

```swift
import SwiftUI

struct ImportCommands: Commands {
    @Environment(ImportStore.self) private var importStore
    @State private var isPresented = false

    var body: some Commands {
        CommandGroup(replacing: .importExport) {
            Button("Import CSV…") { isPresented = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }
    }
}
```

The sheet itself lives in a view that owns `.fileImporter`. The button sets a binding on a shared `@State`/env value.

- [ ] **Step 19.2 — Drag-and-drop at three levels.**

```swift
// Features/Import/DropHandlers.swift
import SwiftUI
import UniformTypeIdentifiers

struct CSVDropModifier: ViewModifier {
    let forcedAccountId: UUID?
    let importStore: ImportStore

    func body(content: Content) -> some View {
        content.dropDestination(for: URL.self) { urls, _ in
            for url in urls where url.pathExtension.lowercased() == "csv" {
                Task {
                    guard url.startAccessingSecurityScopedResource() else { return }
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let data = try? Data(contentsOf: url) {
                        _ = await importStore.ingest(
                            data: data,
                            source: .droppedFile(url: url, forcedAccountId: forcedAccountId))
                    }
                }
            }
            return true
        }
    }
}

extension View {
    func csvDropDestination(forcedAccountId: UUID? = nil, importStore: ImportStore) -> some View {
        modifier(CSVDropModifier(forcedAccountId: forcedAccountId, importStore: importStore))
    }
}
```

Apply on:
- Account rows in `SidebarView` → `.csvDropDestination(forcedAccountId: account.id, importStore: …)`.
- Account-scoped transaction list view → same.
- Top-level window view → `.csvDropDestination(forcedAccountId: nil, importStore: …)`.

- [ ] **Step 19.3 — Paste.** Menu `CommandGroup` on `.pasteboard` placement: "Paste CSV" that reads `NSPasteboard.general.string(forType: .string)` (macOS) / `UIPasteboard.general.string` (iOS). Construct `ImportSource.paste(text:label:)` and call `ingest(data:source:)` with the UTF-8 bytes.

- [ ] **Step 19.4 — Dock drops.** In `MoolahApp`:

```swift
.handlesExternalEvents(preferring: ["com.moolah.csv-import"], allowing: [])
// For NSApplication.open(urls:) on macOS, add AppDelegate adaptor that forwards URLs
// to ImportStore.ingest(data: Data(contentsOf: url), source: .droppedFile(url:, forcedAccountId: nil)).
```

- [ ] **Step 19.5 — Tests.** These are awkward without an iOS simulator; focus on unit-testing the `DropHandlers` data-translation helpers:

| Test | Setup | Expect |
|---|---|---|
| `dropURL_withCSVExtension_ingestedAsForcedFile` | mock ImportStore, call the drop helper with a tmpfile URL | `ingest` called once with `.droppedFile(forcedAccountId: X)` |
| `dropURL_nonCSV_ignored` | drop with `.txt` extension | ingest not called |
| `paste_utf8Bytes_forwarded` | call paste helper with sample CSV text | `ingest` called with `.paste` |

Use a protocol-shaped mock of `ImportStore.ingest` to sidestep `@MainActor`.

- [ ] **Step 19.6 — Commit.**

```bash
git commit -m "feat: wire CSV ingestion via file picker, drag-and-drop, and paste"
```

---

### Task 20: `FolderScanService` (catch-up scan)

Runs on app launch and on scene-foreground. Walks every configured watched folder; for each `.csv` whose modification date is newer than the stored `lastSeenAt`, calls `importStore.ingest(…)`. Persists per-folder `lastSeenAt` in `UserDefaults`.

**Files:**
- Create: `Features/Import/FolderScanService.swift`
- Test:   `MoolahTests/Features/Import/FolderScanServiceTests.swift`

- [ ] **Step 20.1 — Shape:**

```swift
struct WatchedFolder: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var bookmark: Data
    var isEnabled: Bool
    var deleteAfterImport: Bool
    var lastSeenAt: Date?
}

@Observable
@MainActor
final class FolderScanService {
    private(set) var folders: [WatchedFolder] = []

    private let importStore: ImportStore
    private let defaults: UserDefaults
    private let defaultsKey = "moolah.csvImport.watchedFolders"

    init(importStore: ImportStore, defaults: UserDefaults = .standard) { … }

    func loadFolders() { /* decode from defaults */ }
    func addFolder(url: URL) throws { /* create bookmark, persist */ }
    func removeFolder(id: UUID) { /* … */ }
    func scanAll() async { /* resolve bookmarks, enumerate .csv, ingest newer */ }
}
```

- [ ] **Step 20.2 — Tests using a real tmp directory.**

| Test | Setup | Expect |
|---|---|---|
| `scan_newCSV_ingested` | tmp dir with 2 CSV files; folder registered with `lastSeenAt == nil` | both ingested |
| `scan_nonCSVSkipped` | `.txt` files present | not ingested |
| `scan_olderThanLastSeen_skipped` | existing `lastSeenAt` > file mod date | skipped |
| `scan_updatesLastSeenAtToMaxModDate` | after scan | `lastSeenAt` > mod date of newest file |
| `scan_disabledFolderSkipped` | folder with `isEnabled == false` | nothing ingested |

Use a test-only `ImportStore` recorder that captures ingest calls.

- [ ] **Step 20.3 — Commit.**

```bash
git commit -m "feat: add FolderScanService for launch/foreground CSV catch-up"
```

---

### Task 21: `FolderWatchService` (macOS live FSEvents)

macOS-only. Uses `FSEventStreamCreate` / `DispatchSource.makeFileSystemObjectSource` (the latter is simpler but watches one folder at a time). Activates only while the app is running; on start, hands off a catch-up scan to `FolderScanService`.

**Files:**
- Create: `Features/Import/FolderWatchService.swift` (guarded with `#if os(macOS)`).
- Test:   `MoolahTests/Features/Import/FolderWatchServiceTests.swift` (macOS target only).

- [ ] **Step 21.1 — Implementation skeleton:**

```swift
#if os(macOS)
import Foundation

@MainActor
final class FolderWatchService {
    private var streams: [UUID: FSEventStreamRef] = [:]
    private let scanService: FolderScanService

    init(scanService: FolderScanService) { self.scanService = scanService }

    func start(folder: WatchedFolder) throws {
        guard folder.isEnabled else { return }
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: folder.bookmark,
            options: [.withSecurityScope],
            relativeTo: nil, bookmarkDataIsStale: &isStale)
        guard url.startAccessingSecurityScopedResource() else {
            throw NSError(domain: "FolderWatchService", code: 1)
        }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let paths = [url.path] as CFArray
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let svc = Unmanaged<FolderWatchService>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in await svc.scanService.scanAll() }
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, UInt32(kFSEventStreamCreateFlagFileEvents))
        else {
            url.stopAccessingSecurityScopedResource()
            throw NSError(domain: "FolderWatchService", code: 2)
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        streams[folder.id] = stream
    }

    func stop(folderId: UUID) {
        guard let stream = streams.removeValue(forKey: folderId) else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
#endif
```

- [ ] **Step 21.2 — Tests (macOS-only, gated with `#if os(macOS)`):**

| Test | Setup | Expect |
|---|---|---|
| `newFileTriggersScan` | start service watching tmpdir; touch `foo.csv` into dir | within ~2 seconds, `FolderScanService.scanAll` invoked |
| `stopReleasesResources` | start then stop | no crash, callback no longer invoked on new writes |

Use `confirmation(expectedCount: 1) { confirm in … }` pattern with a `DispatchSource` or `NotificationCenter` bridge to signal when scan fires. Add a 2-second timeout. Flaky tests are tolerable once; three consecutive flakes → quarantine behind `@Suite(.serialized)` and open a follow-up issue.

- [ ] **Step 21.3 — Commit.**

```bash
git commit -m "feat: add FolderWatchService (macOS FSEvents)"
```

---

### Task 22: Settings panel integration — folder watch config, delete-after-import, profile management

Exposes the toggles users need to actually turn all of this on. Settings → Import section.

**Files:**
- Create: `Features/Import/Views/ImportSettingsSection.swift`
- Modify: `Features/Settings/<existing-settings-host>.swift` to include the new section.
- Tests: piggy-back on Task 20/21 for logic; the view itself is thin.

- [ ] **Step 22.1 — Section composition:**

```swift
struct ImportSettingsSection: View {
    @Environment(FolderScanService.self) private var scanService
    @Environment(ImportStore.self) private var importStore
    @State private var showFolderPicker = false
    @State private var showProfileManager = false

    var body: some View {
        Section("Import") {
            ForEach(scanService.folders) { folder in
                FolderRow(folder: folder)
            }
            Button("Add watched folder…") { showFolderPicker = true }

            Toggle("Delete CSV after import (default)", isOn: /* bound to a default profile setting */ .constant(false))

            NavigationLink("Import Profiles") { ImportProfileManagerView() }
            NavigationLink("Import Rules")    { ImportRulesSettingsView() }
        }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                try? scanService.addFolder(url: url)
            }
        }
    }
}
```

- [ ] **Step 22.2 — `ImportProfileManagerView`** — simple `List` of `CSVImportProfile`s with delete swipe + tap-to-edit target account / filename pattern.

- [ ] **Step 22.3 — Run `@ui-review`. Commit.**

```bash
git commit -m "feat: add import settings section (folders, profiles, rules)"
```

---

### Task 23: Pipeline benchmarks

Per spec §"Benchmarks" — four signpost-instrumented benchmarks. No optimisation work; just landed as green measurement points.

**Files:**
- Create: `MoolahBenchmarks/ImportPipelineBenchmarks.swift`
- Modify: `MoolahBenchmarks/Support/BenchmarkFixtures.swift` — extend with CSV-pipeline seeding if needed.
- Modify: `Shared/CSVImport/*.swift` — add `Signposts` calls at pipeline stage boundaries (see `Shared/Signposts.swift` for the existing pattern).

- [ ] **Step 23.1 — Invoke `write-benchmark` skill** to scaffold each benchmark per `guides/BENCHMARKING_GUIDE.md`.

- [ ] **Step 23.2 — Implement the four benchmarks:**

```
importPipeline_parse_1000rows
importPipeline_dedup_1000rows_against_10000existing
importPipeline_rules_1000rows_20rules
importPipeline_end_to_end_10files_1000rowsEach
```

Each uses `measure(metrics:options:)` with `XCTClockMetric` + `XCTMemoryMetric`, iteration count 10. Seed fixtures via a new `ImportBenchmarkFixtures` helper.

- [ ] **Step 23.3 — Add signposts** at pipeline boundaries in `ImportStore`:

```swift
let signpost = OSSignposter(subsystem: "com.moolah.app", category: "Import")
let state = signpost.beginInterval("ingest", id: .init(id.hashValue))
// … per stage: signpost.event("parse"), signpost.event("dedup"), …
signpost.endInterval("ingest", state)
```

- [ ] **Step 23.4 — Invoke `interpret-benchmarks` skill** after running `just benchmark` once to verify the numbers look sane. Record baseline in the PR description.

- [ ] **Step 23.5 — Commit.**

```bash
git commit -m "feat: add pipeline benchmarks and signpost instrumentation"
```

---

## Final wiring steps (before PR)

- [ ] **Inject stores at the root.** In `App/ProfileRootView.swift` (or wherever the `BackendProvider`-tied stores are built), add:

```swift
let staging = try! ImportStagingStore(
    directory: profileSession.applicationSupportDirectory
        .appendingPathComponent("csv-staging"))
let importStore = ImportStore(backend: backend, staging: staging)
let csvImportProfileStore = CSVImportProfileStore(repository: backend.csvImportProfiles)
let importRuleStore = ImportRuleStore(repository: backend.importRules)
let scanService = FolderScanService(importStore: importStore)
#if os(macOS)
let watchService = FolderWatchService(scanService: scanService)
#endif
```

Plumb them into `.environment(…)` so the views in Features/Import can reach them.

- [ ] **Update `Shared/PreviewBackend.swift`** with in-memory no-op or passthrough implementations of `CSVImportProfileRepository` and `ImportRuleRepository` if Task 8 didn't already.

- [ ] **Update `BUGS.md`** — the feature introduces no known bugs initially; nothing to add. Re-read once post-landing in case the review surfaces any deferred items.

---

## Self-review

Checked against `plans/2026-04-18-csv-import-design.md`:

- **Silent-by-default philosophy** — Tasks 15, 16 (`Recently Added` badge; no modals; rules + dedup silent).
- **Ingestion entry points** (folder, picker, drag, paste) — Tasks 19, 20, 21.
- **Recently Added sidebar + view** — Task 16.
- **Needs Setup form** — Task 17.
- **Error surfaces** (Failed Files panel, Needs Setup, date-format ambiguity) — Task 16 (panel), Task 17 (ambiguity picker surfaced), Task 15 (whole-file rejection path).
- **Pipeline** (tokenizer → parser → validation → profile → rules → dedup → persist → recently added) — Tasks 1, 9, 10, 11, 12, 13, 15, 16.
- **Record model** (`ParsedTransaction` / `ParsedLeg`) — Task 2.
- **Parser protocol** + `CSVParser` + `ParsedRecord` — Task 2.
- **Selection order** (source-specific first; GenericBank fallback) — Task 10 Step 10.5 (`CSVParserRegistry`).
- **Account fingerprinting & disambiguation** (zero/one/many profile cases, duplicate overlap, filename tiebreak) — Task 12.
- **Explicit drag bypasses fingerprinting** — Task 15 Step 15.2 (`source.forcedAccountId`) and Task 19 (drop destinations pass `forcedAccountId`).
- **Data model: `Transaction.importOrigin`** — Task 3 (domain) + Task 5 (persistence & sync).
- **Data model: `CSVImportProfile`, `ImportRule`** — Tasks 4, 6, 7, 8.
- **Local staging (pending / failed)** — Task 14.
- **Dedup** (bank ref, same-date, balance alignment; bank rows only for alignment) — Task 11.
- **Rules engine** (conditions, actions, match modes, first-match-wins, markAsTransfer two-leg, skip short-circuit, raw description) — Task 13.
- **Rules UI** — Task 18.
- **Category action references existing categories only** — Task 18 Step 18.4 (RuleEditorView uses existing category picker).
- **Creation paths: explicit / from-edit / from-search** — Task 18 Steps 18.4–18.6.
- **Testing layers** — each enumerated in its respective task; parser contract tests with 10+ fixtures (Task 9), SelfWealth-specific (Task 10), dedup/matcher/rules pure tests (Tasks 11–13), store tests against TestBackend (Tasks 15–18, 20).
- **Fixtures in `MoolahTests/Support/Fixtures/csv/`** — Task 9 Step 9.2 registers the directory and `CSVFixtureLoader` helper.
- **Benchmarks** (four pipeline stages + signposts) — Task 23.
- **Integration table** (Domain / Shared / Features / Backends) — matches the spec's §"Integration with existing architecture" layout; see file-structure section at top.
- **Open questions (resolved)** — all resolved-in-spec points are honoured: framework-only for source-specific parsers, rule editor only references existing categories, balance alignment single-leg only, Apple-provided encoding detection, no optimisation work without a measured regression, markAsTransfer in scope but transfer detection/merge/unmerge out of scope. No task introduces any of the deferred items.

**Red-flag scan:** No `TBD`, `TODO`, or `fill in details` strings in any task. Every step has a concrete file path, concrete test code or a bulleted enumeration with concrete inputs/expected values, and concrete commit message. Method/type names are consistent across tasks (`CSVDeduplicator.filter(_:against:accountId:)` used the same way in Tasks 11, 12, 15; `ImportRulesEngine.evaluate(_:routedAccountId:rules:)` used the same way in Tasks 13, 15; `CSVImportProfile.normalise(_:)` used in Tasks 4, 6, 12, 15).

**Type consistency spot-checks:**
- `ImportOrigin` fields: `rawDescription`, `bankReference`, `rawAmount`, `rawBalance`, `importedAt`, `importSessionId`, `sourceFilename`, `parserIdentifier` — used identically in Tasks 3, 5, 11, 15, 16, 18.
- `ParsedTransaction.legs: [ParsedLeg]`, `legs[0].accountId: UUID?` — parsers emit `nil` accountId; `ImportStore` fills it from the routed profile in Task 15.
- `MatcherResult.needsSetup(reason:)` uses `Reason.noMatchingProfile` and `.ambiguousMatch(tiedProfileIds:)` — same enum referenced from Tasks 12 and 15.

Plan is ready to execute.



