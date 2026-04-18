# CSV Transaction Import — Design Spec

**Status:** Draft · 2026-04-18
**Supersedes:** `plans/csv-import-design.md` (SelfWealth-only plan) — SelfWealth becomes one parser among many under this unified design.
**Related:** `plans/2026-04-18-transfer-detection-design.md` (follow-up feature; out of scope here).

---

## Goal

Let the user import transactions from CSV files — exported from online banking, brokerages, or crypto exchanges — with a "download it and forget it" feel. For recurring use (potentially daily), imports should be silent and ambient; for a first-time migration, the same pipeline handles large one-off exports without ceremony.

The north-star UX: the user downloads a CSV from their bank, opens Moolah (or leaves it open), and the new transactions are already in place with sensible payees and categories, awaiting their glance at a "Recently Added" inbox.

## Success criteria

- A user with folder-watch enabled can download a bank CSV, open Moolah, and see imported transactions without any prompt, column mapping, or confirmation — **after** the first-time setup for that account.
- First-time setup for a new bank CSV format takes under 30 seconds and is non-blocking (it lands in a "Needs setup" panel, not a modal).
- Duplicates from overlapping CSV downloads are silently skipped with no false positives or false negatives on real bank exports in the fixture set.
- The user can build a library of rules organically by editing imported transactions ("Create a rule from this…") rather than by writing them upfront.
- The pipeline is extensible to new CSV sources (banks, brokers, exchanges) via a single parser implementation plus registration — no changes to the store, UI, or data model.

## Scope

**In scope (v1):**
- CSV ingestion from: folder watch (opt-in), manual file picker, drag-and-drop (macOS, iPadOS), paste.
- Generic column-inferred bank CSV parser.
- Source-specific CSV parser framework; SelfWealth parser shipping as the reference implementation (carries over existing `plans/csv-import-design.md` scope).
- Account fingerprinting and multi-match disambiguation via duplicate overlap.
- Rules engine (Mail.app-shaped UI; no regex).
- Dedup with date + amount + raw description + bank reference + balance alignment (bank rows only).
- "Recently Added" sidebar entry and view, driven by `ImportOrigin` data on each transaction.
- Whole-file-or-nothing parse validation; failed files surface in a dedicated panel.
- Optional delete-CSV-after-import.
- Benchmarks for the end-to-end pipeline (no optimisation work until data warrants).

**Out of scope (deferred, own design docs):**
- Transfer auto-detection, manual merge-as-transfer, unmerge. Captured in `plans/2026-04-18-transfer-detection-design.md`. A single rule action — `markAsTransfer(toAccountId:)` — is included in this spec because it simply produces a two-leg transfer at parse time and does not require merge/detection machinery.
- CSV import of investment valuations / holdings snapshots. Valuations come from API sources; no need for a CSV path here.
- Share-sheet ingestion of bank-website selected text. Promising in theory, too per-bank fragile to commit to in v1.
- OFX / QFX / QIF support. Same pipeline shape would apply; explicitly out of scope until CSV is solid.
- Additional source-specific parsers for other brokers and crypto exchanges. Framework is ready; parsers ship as individual follow-ups.
- Undo / batch rollback / per-import history. User relies on the Recently Added view to delete unwanted transactions. Auto-import is opt-in so users can enable it when confident.

## User experience

### Silent-by-default philosophy

An imported transaction that matches a fingerprint and at least one rule lands silently. No banner, no toast, no sheet. The sidebar's "Recently Added" entry carries a badge showing how many recently imported transactions still need review (v1: rows that no rule matched). Users glance at the badge to know whether there's work, open it when they want, and otherwise get on with their day.

### Ingestion entry points

All ingestion paths land at the same pipeline entrypoint: `ImportStore.ingest(data: Data, source: ImportSource)`. `ImportSource` captures origin metadata (security-scoped URL for folder-watched files, user-picked URL, paste-text, drop target) needed for later cleanup, routing, and audit.

1. **Folder watch (opt-in, per-platform).**
   - **macOS:** user picks a folder (typically `~/Downloads`) via file picker → security-scoped bookmark persists. `FSEvents` / `DispatchSource` notifies on new/changed `.csv` files while the app is running. On launch, a catch-up scan handles files whose modification date is newer than the last-seen timestamp.
   - **iOS / iPadOS:** no live background watch. User picks a folder via `UIDocumentPickerViewController` → security-scoped bookmark. Scan runs on app launch and on scene-foreground transition.
   - Setting UI under Settings → Import. Per-folder options: enabled / disabled, target (folder URL), delete CSV after successful import (default off). Can be toggled or disabled at any time.

2. **Manual file picker.** Standard `.fileImporter` filtered to `.commaSeparatedText` and `.plainText`. Works on both platforms. Primary path for first-time migrations and ad-hoc archive imports.

3. **Drag-and-drop (macOS; iPadOS with external drag).**
   - Drop on the app Dock icon → `NSApplication.open(urls:)` → auto-routing.
   - Drop on the main window / non-account-specific view → auto-routing.
   - Drop on an account's transaction list view → **force target** to that account (bypasses fingerprint disambiguation; still runs rules and dedup).
   - Drop on an account row in the sidebar → same as transaction list: forces target.
   - iPadOS: `.onDrop(of: [.commaSeparatedText], ...)` on the same three contexts. iPhone: no drag surface; use picker / paste.
   - An explicit drop is the fast path for the "sibling accounts, same bank, same CSV format" case: no setup sheet needed, the drop itself disambiguates, and a profile is created or updated on successful import.

4. **Paste.** User copies tabular text (from a bank webpage, a spreadsheet, another app) and pastes via menu item / keyboard shortcut. Synthetic in-memory buffer flows through the same pipeline. No source-file bookkeeping, no delete-after-import.

### "Recently Added" sidebar entry

New top-level sidebar row labelled **"Recently Added"**, positioned directly above **"All Transactions"**. Badge count = transactions imported within the current view window that have no category (v1 proxy for "needs review"). Badge decrements as the user categorises them.

### "Recently Added" view

- **Time window control** (top-right, matches the Analysis view's history range dropdown): *Last 24 hours · Last 3 days · Last week · Last 2 weeks · Last month · All*. Default: Last 24 hours. Filter is on `importedAt`, not transaction date.
- **Top panel** (hidden when both lists are empty, expanded otherwise): **Needs Setup** and **Failed Files**. Each file on one row: filename, reason (needs setup / parse error including offending row), action buttons (Open setup form / Retry / Dismiss).
- **Session-grouped list.** Each group is a set of transactions sharing an `importSessionId` (a drop/scan event). Group header renders: local date-time of the session, distinct source filenames, total rows, visual summary (e.g., "47 imported · 14 need review").
- **Rows** render in the same format as the main Transactions view. Rows that need review get a visual marker (left-edge accent colour + inline "Needs review" label). Inline edit of payee / category works just like the Transactions view.
- **Row context actions:** Open transaction detail (existing view), Create a rule from this…, Delete transaction.
- **Search bar** within the view: searches the raw description (`ImportOrigin.rawDescription`) and the display payee. A "Create a rule matching this search" affordance appears when the query is non-empty (GMail filter-from-search pattern).

Sessions whose transactions all fall outside the active window simply disappear from the list. No retention policy on the session grouping — it's a pure query.

### First-time / unknown-fingerprint setup

When a file lands in the "Needs Setup" pile (no profile matched, or multi-match fell through), the user engages on their own schedule. Tapping the file opens a **one-screen form**:

1. **File header** — filename, detected parser (or "Unknown format"), row count.
2. **Target account** — dropdown of existing accounts, with *Create new account…* at the bottom.
3. **Column mapping** — shown only when `GenericBankCSVParser` matches. A table with one row per detected CSV column, each with a dropdown: *Date · Amount · Debit · Credit · Description · Balance · Reference · Ignore*. Pre-filled by header-name heuristics; user can override. **Date format picker** (auto-detected, editable: `DD/MM/YYYY`, `MM/DD/YYYY`, `YYYY-MM-DD`, ISO 8601…). Source-specific parsers hide this section — they already know their columns.
4. **Preview** — first 5 rows with the mapping applied, rendered as they would appear in Moolah (payee = raw description for now; no rule has run yet).
5. **Options** — filename pattern (optional, auto-suggested from the current filename; used as a tiebreaker when multiple profiles match); Delete CSV after import toggle.
6. **Save & Import** button. Saves the profile, then imports this file immediately through the rest of the pipeline. If Delete CSV is on, the source file is removed after persistence succeeds.

Cancel leaves the file in the Needs Setup pile. The user can dismiss a pending file to remove it without importing.

### Error surfaces

| Condition | Surface |
|---|---|
| File cannot be read (encoding, permissions) | Failed Files panel; error message + filename; Retry button (picker path only) |
| No parser recognises the headers | Sent to Needs Setup with `GenericBankCSVParser` applied as fallback |
| Any row fails to parse | **Whole file rejected**; Failed Files panel with offending row content |
| Date format ambiguous (user's locale says one thing, values suggest another) | Needs Setup, surfaced in the form with date-format picker |

## Architecture

### Pipeline

```
raw bytes
  → CSVTokenizer                  (encoding detection, BOM, quoting, line endings)
  → Parser selection              (first parser whose header fingerprint matches)
  → Parser.parse(rows) → [ParsedRecord]
  → Whole-file validation         (any row fails → entire file rejected)
  → Profile lookup                (known profile → route silently; unknown → Needs Setup)
     └── disambiguation           (header match ambiguous → score by duplicate overlap → filename pattern → else Needs Setup)
  → Rules engine                  (per record: payee, category, notes, transfer target, skip)
  → Dedup                         (account + date + rawAmount + rawDescription + bankReference + balance alignment)
  → Persist                       (TransactionRepository)
  → Surface in Recently Added     (via ImportOrigin.importSessionId on each transaction)
```

### Record model

All imports produce `ParsedTransaction` values. Holdings / valuations are not CSV-sourced in v1.

```swift
struct ParsedTransaction: Sendable {
    let date: Date
    let legs: [ParsedLeg]
    let rawRow: [String]
    let rawDescription: String
    let rawAmount: Decimal
    let rawBalance: Decimal?
    let bankReference: String?
}

struct ParsedLeg: Sendable {
    let accountId: UUID?               // filled in after profile routing
    let instrument: Instrument
    let quantity: Decimal
    let type: TransactionType          // .income / .expense / .transfer
}
```

- **Bank row** → single-leg (cash account + category).
- **Brokerage / crypto trade** → two-leg (cash leg + position leg, different instruments).
- **Dividend** → single-leg income on the investment account.
- **Transfer** (from `markAsTransfer` rule action) → single transaction with two cash legs across Moolah accounts.

At parse time `accountId` on the cash leg is nil; profile lookup fills it in. The position leg's `accountId` equals the target account (for trades, the brokerage/investment account).

### Parser protocol

```swift
protocol CSVParser: Sendable {
    var identifier: String { get }                     // "generic-bank" | "selfwealth" | ...
    func recognizes(headers: [String]) -> Bool
    func parse(rows: [[String]]) throws -> [ParsedRecord]
}

enum ParsedRecord: Sendable {
    case transaction(ParsedTransaction)
    case skip(reason: String)                          // recognised but deliberately ignored (e.g. header sub-rows, summary totals)
}
```

**Selection order:** source-specific parsers first (they know their format precisely), `GenericBankCSVParser` as fallback. If no parser matches, fall back to `GenericBankCSVParser` with the expectation that the Needs Setup form will let the user confirm the mapping.

**Source-specific parsers (v1): `SelfWealthParser`**. Follows the parsing logic from the previous SelfWealth plan (regex on the description field for BUY/SELL rows, fees, dividends) but emits `ParsedTransaction` values rather than the now-discarded `StockTrade` intermediate. Each trade becomes a two-leg transaction (cash leg in AUD, position leg in the ASX ticker instrument).

**Framework posture for crypto / other brokers:** the spec does not ship additional parsers. The architecture is designed so each new source is a single `CSVParser` conformer + one registration line. Parsers that emit two-leg transactions reuse the same pipeline as `SelfWealthParser`.

### Account fingerprinting & disambiguation

Each known import source is stored as a `CSVImportProfile`:

```swift
struct CSVImportProfile: Sendable, Identifiable {
    let id: UUID
    var accountId: UUID
    var parserIdentifier: String         // must match a registered parser
    var headerSignature: [String]        // normalized CSV headers (lowercased, trimmed)
    var filenamePattern: String?         // glob; optional tiebreaker
    var deleteAfterImport: Bool
    let createdAt: Date
    var lastUsedAt: Date?
}
```

**Matching on a new file:**
1. Identify the parser via header fingerprint.
2. Collect all profiles with `(parserIdentifier, headerSignature)` matching the file.
3. If zero profiles → file lands in Needs Setup.
4. If one profile → route silently.
5. If multiple profiles → disambiguate:
   - For each candidate profile, run the dedup check against the parsed rows and **count duplicates** in that profile's account. The account with the most duplicate matches wins.
   - Tiebreaker: filename-pattern match (glob).
   - Still tied → Needs Setup.

**Rationale:** users commonly have multiple accounts at the same bank. A fresh CSV download is almost certain to overlap with prior imports for its true home account, even by just a few rows, giving near-certainty from a cheap signal.

**Explicit drag bypasses fingerprinting.** A drop onto a specific account view or sidebar row skips profile lookup entirely and routes to that account, creating or updating a profile on success.

## Data model changes

1. **`Transaction.importOrigin: ImportOrigin?`** — persistent, synced via the existing transaction sync path. Nil for manually-created transactions, populated for imports. **Forward-compat note:** the transfer-detection follow-up (`plans/2026-04-18-transfer-detection-design.md`) upgrades this field to a sum type `TransactionImportOrigin` with `.single(ImportOrigin)` / `.merged(MergedImportOrigin)` cases. This spec stores only `.single` values; the upgrade is a straightforward enum-wrap migration.

    ```swift
    struct ImportOrigin: Codable, Sendable, Hashable {
        let rawDescription: String        // bank's original description, untouched
        let bankReference: String?        // bank's reference/txn-id column if present — strongest dedup signal
        let rawAmount: Decimal            // original signed decimal from CSV
        let rawBalance: Decimal?          // running balance if CSV had one (for alignment dedup)
        let importedAt: Date
        let importSessionId: UUID         // groups transactions from one drop/scan event
        let sourceFilename: String?       // nil for paste
        let parserIdentifier: String      // audit: which parser produced this
    }
    ```

2. **New model: `CSVImportProfile`** with repository + CRUD. Synced so profiles and fingerprints follow the user across devices.

3. **New model: `ImportRule`** with repository + CRUD. Synced. See Rules engine below.

4. **No `ImportSession` entity.** Session metadata is derived at view time by grouping transactions on `importOrigin.importSessionId`. Session headers compute start / end / file count / row count from the grouped set.

5. **Local staging state** (not synced, not persisted in SwiftData — a small app-support JSON index + a staging directory for copies of pending files):
    - Pending setup files: `{ filename, stagingPath, securityScopedBookmark?, detectedParser, parsedAt }`.
    - Failed files: `{ filename, stagingPath, error, offendingRow?, parsedAt }`.
    - This is device-local workflow state; no value in syncing it, and security-scoped bookmarks are per-device anyway.

## Dedup

**Scope** (per-row):

1. **Bank reference match** — account-wide, no date constraint. If the incoming row has a `bankReference` and any existing transaction on the same account has `importOrigin.bankReference` equal to it → duplicate. Skip.
2. **Same-date exact match** — search existing transactions on the same `accountId` on the same `date`. If any has matching `(rawAmount, normalised rawDescription)` → duplicate. Skip.
3. **Balance alignment** — applies only when the CSV has a running balance column **and** all rows in the file are single-leg single-currency (bank rows). Walk the incoming rows in date order against existing transactions in the same account, matching against the running-balance sequence; rows that slot cleanly into a balance gap are duplicates.
4. Else: new row. Import.

**Normalisation for comparison:** uppercase, trim, collapse internal whitespace, strip ASCII punctuation other than reference-like digits.

**Behaviour on match:** silently skip. Not tracked, not surfaced. If the user disagrees, they re-import manually (matching the rows they want re-created) or enter transactions by hand.

**Scope of balance alignment:** bank rows only (single-leg, single-currency). Multi-leg transactions (trades) rely on `bankReference` + `rawDescription`.

## Rules engine

### Model

```swift
struct ImportRule: Codable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var enabled: Bool
    var position: Int
    var matchMode: MatchMode                // .any | .all
    var conditions: [RuleCondition]
    var actions: [RuleAction]
    var accountScope: UUID?                 // nil = global (all accounts)
}

enum MatchMode: String, Codable, Sendable {
    case any, all
}

enum RuleCondition: Codable, Sendable {
    case descriptionContains([String])       // case-insensitive, multi-token OR within this condition
    case descriptionDoesNotContain([String])
    case descriptionBeginsWith(String)
    case amountIsPositive
    case amountIsNegative
    case amountBetween(min: Decimal, max: Decimal)
    case sourceAccountIs(UUID)
}

enum RuleAction: Codable, Sendable {
    case setPayee(String)
    case setCategory(UUID)                   // must reference an existing category; rule editor enforces
    case appendNote(String)
    case markAsTransfer(toAccountId: UUID)   // transforms into a two-leg transfer transaction
    case skip                                // drop the row entirely (useful for CSV garbage rows)
}
```

### Evaluation

- Rules run in `position` order, skipping disabled ones and those with `accountScope` not matching the routed account.
- Each rule whose conditions match contributes its actions. **First rule with `setPayee` wins** for the payee field; same for `setCategory`. Append-note stacks (prepends oldest first). `markAsTransfer` and `skip` short-circuit further evaluation.
- Rules operate on the *raw* description from the CSV (`ImportOrigin.rawDescription`), not the Moolah-facing payee. This guarantees rules remain stable even after payee cleanup.

### UI (Mail.app shape + GMail create-from-search)

- **Rules list** under Settings → Import Rules. Ordered, drag to reorder, enable toggle per row, "matched N times · last matched <date>" hint.
- **Rule editor:** two sections — Conditions ("If [any/all] of these are true") and Actions ("Perform these"). Each is a list of rows; Add/Remove row buttons; each row has field · operator · value dropdowns.
- **Category selection** uses the existing category picker; only existing categories may be selected.
- **Live preview** at the bottom of the editor: "This rule would affect N past transactions" computed on demand (debounced on edit, not per keystroke) by running the current rule's conditions against existing imported transactions' `ImportOrigin.rawDescription`. Prevents surprise.
- **Creation paths:**
  1. **Explicit:** Settings → Import Rules → Add Rule.
  2. **From-edit:** any transaction detail / Recently Added row. Edit payee or category → a "Create a rule from this…" affordance opens the rule editor pre-filled with *distinguishing tokens* from the raw description (tokens are terms that appear least frequently in the user's corpus of raw descriptions — high signal, low noise) plus the payee/category the user just set.
  3. **From-search:** Recently Added's search bar shows "Create a rule matching this search" when the query is non-empty. Opens the editor pre-filled with `descriptionContains([query tokens])`.

## Testing

TDD throughout. `TestBackend` (CloudKitBackend + in-memory SwiftData) for store tests; pure unit tests for parsers and rules.

**Layers:**

1. **`CSVTokenizer` tests** — pure string/bytes processing. Quoting, escaped quotes, BOM handling, CRLF / LF / CR line endings, blank lines, UTF-8 / UTF-16 / Windows-1252 via `NSString.stringEncoding(for:...)`.
2. **`GenericBankCSVParser` tests** — column inference across 10+ fixture files from different banks (CBA, ANZ, NAB, Westpac, ING, Bendigo, Macquarie, plus US/UK samples). Covers amount sign conventions, debit/credit column splits, date format auto-detection, balance-column presence, whole-file rejection on malformed rows.
3. **`SelfWealthParser` tests** — carried over from the superseded plan, updated to emit `ParsedTransaction` with two legs rather than `StockTrade`.
4. **Rules engine tests** — conditions, match modes, actions, rule ordering, first-match-wins per field, `markAsTransfer` producing a two-leg transaction, `skip` short-circuiting, account scope.
5. **Fingerprint matching tests** — unambiguous match, multi-match disambiguation by duplicate overlap, filename-pattern tiebreak, no-match → Needs Setup, explicit drag target bypass.
6. **Dedup tests** — exact match, bank reference match, balance alignment (bank rows only), no match, normalisation edge cases.
7. **`ImportStore` tests** (against `TestBackend`) — end-to-end ingest → parse → match profile → apply rules → dedup → persist; pending-setup flow; failed-file flow; paste flow; drag-to-account override; multi-file session grouping.
8. **Folder-watch integration tests** — macOS: file appears in watched folder → ingestion fires and produces expected persisted transactions. iOS: scan-on-foreground picks up new files. Uses a tmp directory scoped to the test run.

Fixture files live in `MoolahTests/Support/Fixtures/csv/` with a naming convention that encodes bank / account type / edge case (e.g., `cba-everyday-standard.csv`, `nab-creditcard-debit-credit-split.csv`, `westpac-utf16.csv`, `selfwealth-trades.csv`, `malformed-unterminated-quote.csv`).

## Benchmarks

Per `guides/BENCHMARKING_GUIDE.md`. One `MoolahBenchmarks` entry per pipeline stage:

- `importPipeline_parse_1000rows`
- `importPipeline_dedup_1000rows_against_10000existing`
- `importPipeline_rules_1000rows_20rules`
- `importPipeline_end_to_end_10files_1000rowsEach`

Signpost boundaries at each pipeline stage so Instruments traces attribute time accurately. No optimisation work until a benchmark or user report shows a real problem.

## Integration with existing architecture

| Layer | Files | Purpose |
|---|---|---|
| Domain/Models | `ImportOrigin.swift`, `CSVImportProfile.swift`, `ImportRule.swift`, `ParsedTransaction.swift`, `ParsedRecord.swift` | Intermediate + persistent import types |
| Domain/Repositories | `CSVImportProfileRepository.swift`, `ImportRuleRepository.swift` | Profile and rule CRUD protocols |
| Shared/CSVImport | `CSVTokenizer.swift` | Raw text → rows |
| Shared/CSVImport | `CSVParser.swift` | Parser protocol |
| Shared/CSVImport | `GenericBankCSVParser.swift`, `SelfWealthParser.swift` | v1 parsers |
| Shared/CSVImport | `ImportRulesEngine.swift` | Rule evaluation |
| Shared/CSVImport | `CSVDeduplicator.swift` | Dedup pass |
| Shared/CSVImport | `CSVImportProfileMatcher.swift` | Fingerprint + disambiguation |
| Shared/CSVImport | `ImportStagingStore.swift` | Pending / failed files on disk |
| Features/Import | `ImportStore.swift` | Orchestration (ingest → parse → dedup → persist) |
| Features/Import | `FolderWatchService.swift` (macOS) / `FolderScanService.swift` (iOS) | Ingestion triggers |
| Features/Import/Views | `RecentlyAddedView.swift` | Sidebar destination |
| Features/Import/Views | `CSVImportSetupView.swift` | One-screen first-import form |
| Features/Import/Views | `ImportRulesSettingsView.swift`, `RuleEditorView.swift` | Rule management |
| Backends/CloudKit | `CKCSVImportProfileRecord.swift`, `CKImportRuleRecord.swift` + sync mappings | Persistence |

Domain/Models stay clean (no SwiftUI, no SwiftData, no backends). Shared/CSVImport imports only Foundation. Features imports SwiftUI and talks to repositories via `BackendProvider`, matching the existing architecture.

## Implementation order

1. `CSVTokenizer` + tests.
2. Domain models: `ImportOrigin`, `ParsedTransaction`, `ParsedRecord`, `CSVImportProfile`, `ImportRule`. Repository protocols.
3. `CSVImportProfileRepository` and `ImportRuleRepository` (CloudKit + contract tests).
4. `Transaction.importOrigin` storage + sync wiring.
5. `GenericBankCSVParser` + fixture suite.
6. `SelfWealthParser` + fixtures.
7. `CSVDeduplicator` + `CSVImportProfileMatcher`.
8. `ImportRulesEngine`.
9. `ImportStore` (orchestration) + TestBackend-driven tests.
10. `FolderScanService` / `FolderWatchService`.
11. `RecentlyAddedView` + `CSVImportSetupView`.
12. `ImportRulesSettingsView` + `RuleEditorView`.
13. Drag-and-drop wiring (macOS + iPadOS) + sidebar badge.
14. Benchmarks.
15. Settings panel integration (folder watch config, delete-after-import, profile management).

Each step is independently testable; steps 1–9 require no UI work.

## Open questions (resolved)

All open questions from brainstorming are resolved or explicitly deferred:

- **Additional source-specific parsers** — deferred. Framework-only in v1; specific parsers ship as follow-ups.
- **Category creation from rules** — not supported. Rule editor only references existing categories; category management remains a general Moolah concern.
- **Multi-leg balance-column alignment** — not attempted. Balance alignment runs only for single-leg single-currency (bank) rows.
- **Encoding detection** — use Apple-provided encoding detection (`String.Encoding` + `NSString.stringEncoding(for:...)`). No custom detection until a real fixture demands it.
- **Performance with large files** — benchmarks added; optimisation deferred until measured.
- **Transfer detection** — moved entirely to `plans/2026-04-18-transfer-detection-design.md`, except for the inline `markAsTransfer` rule action, which produces a two-leg transfer at parse time using Moolah's existing transfer primitives.
