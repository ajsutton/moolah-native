# Trades-Mode Historical Net-Worth Fold — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-day "valued positions over time" fold so trades-mode
investment accounts contribute correctly to the historical net-worth
chart. In the same change, tighten `applyInvestmentValues` for Rule 11
compliance and drop the vestigial `?` on its `sumInvestmentValues`
helper. Closes [#738](https://github.com/ajsutton/moolah-native/issues/738).

**Architecture:** Mirror `applyInvestmentValues`/`advanceInvestmentCursor`
exactly: pre-filter trades-mode rows in `readDailyBalancesAggregation`,
build a sorted per-(dayKey, account, instrument, quantity) cursor inside
the new fold, walk `dailyBalances.keys.sorted()` advancing the cursor
through entries on-or-before each day, valuate via
`InstrumentConversionService.convert(...)` on the day's `dayKey`, add
the result onto `DailyBalance.investmentValue` and recompute `netWorth`.
Per-day failures drop the day from `dailyBalances`; `CancellationError`
rethrows.

**Tech Stack:** Swift 6, GRDB, `swift-format`, SwiftLint, Swift Testing,
`InstrumentConversionService`, `os.Logger`. Build via `just`. Reference
spec:
[`plans/2026-05-04-trades-mode-historical-net-worth-design.md`](2026-05-04-trades-mode-historical-net-worth-design.md).

---

## File Map

**Production (modify):**

- `Backends/GRDB/Repositories/GRDBAnalysisRepository+DailyBalances.swift`
  - Extend `DailyBalancesAggregation` with `tradesModeInvestmentAccountIds`,
    `priorTradesModeAccountRows`, `tradesModeAccountRows`.
  - Extend `DailyBalancesAssemblyContext` with
    `tradesModeInvestmentAccountIds`.
  - Update `assembleDailyBalances` to pass the new field through the
    context construction and call the new fold after
    `applyInvestmentValues`.
- `Backends/GRDB/Repositories/GRDBAnalysisRepository+DailyBalancesAggregation.swift`
  - Call `fetchTradesModeInvestmentAccountIds` inside
    `readDailyBalancesAggregation`.
  - Pre-filter the existing prior/post account-row arrays into the new
    trades-mode-only fields.
- `Backends/GRDB/Repositories/GRDBAnalysisRepository+DailyBalancesInvestmentValues.swift`
  - Add `fetchTradesModeInvestmentAccountIds`.
  - Add `applyTradesModePositionValuations` and its helpers
    (`TradesModePositionEntry`, `sumTradesModePositions`).
  - Drop the vestigial `?` on `sumInvestmentValues`'s return type.
  - Update `applyInvestmentValues` to drop the day from `dailyBalances`
    on per-day conversion failure (Rule 11) and update its
    `sumInvestmentValues` call site to the non-optional return.

**Tests (create / modify):**

- `MoolahTests/Backends/GRDB/DailyBalancesPlanPinningTests.swift`
  - Add `fetchTradesModeInvestmentAccountIdsUsesAccountByType`.
- `MoolahTests/Backends/GRDB/GRDBDailyBalancesAggregateTests.swift`
  - Add tests covering the three new fields populated by
    `fetchDailyBalancesAggregation`. (If the file does not exist, create
    it; otherwise extend.)
- `MoolahTests/Backends/GRDB/GRDBDailyBalancesTradesModeTests.swift`
  - **New file.** Holds the 12 fold-contract tests from the spec
    (§9.3).
- `MoolahTests/Backends/GRDB/GRDBDailyBalancesAssembleTests.swift`
  - Add a Rule 11 test for the snapshot-fold tightening (case 5 from
    spec §9.3).
- `MoolahTests/Domain/AnalysisRule11ScopingTests.swift`
  - No-op (existing per-day-drop test stays green; the snapshot-fold
    tightening makes it consistent — verify nothing regresses).

**Docs (modify):**

- `plans/2026-05-04-trades-mode-historical-net-worth-design.md` →
  `plans/completed/...` after merge (manual step at PR landing time, not
  in this plan).

---

## Build Commands (Reference)

| When you need to | Command |
|------------------|---------|
| Run all tests on macOS | `just test-mac 2>&1 \| tee .agent-tmp/test-mac.txt` |
| Run a subset of tests | `just test-mac GRDBDailyBalancesTradesModeTests 2>&1 \| tee .agent-tmp/test.txt` |
| Format Swift files | `just format` |
| Verify formatting | `just format-check` |
| Build the macOS app | `just build-mac` |

`mkdir -p .agent-tmp` before piping output to `.agent-tmp/`.

---

## Task 1: Add `fetchTradesModeInvestmentAccountIds` SQL fetch + plan-pinning test

**Files:**
- Modify: `Backends/GRDB/Repositories/GRDBAnalysisRepository+DailyBalancesInvestmentValues.swift`
- Test: `MoolahTests/Backends/GRDB/DailyBalancesPlanPinningTests.swift`

- [ ] **Step 1: Write the failing plan-pinning test**

Open `MoolahTests/Backends/GRDB/DailyBalancesPlanPinningTests.swift`.
Find the existing `fetchInvestmentAccountIdsUsesAccountByType` test
(around line 195). Add a sibling test directly after it:

```swift
@Test("fetchTradesModeInvestmentAccountIds uses account_by_type")
func fetchTradesModeInvestmentAccountIdsUsesAccountByType() throws {
  let database = try makeDatabase()
  // Mirrors the per-account id loader driven by
  // `GRDBAnalysisRepository.fetchTradesModeInvestmentAccountIds`. The
  // production SQL filters on `type = 'investment'` AND
  // `valuation_mode = 'calculatedFromTrades'`. The `account_by_type`
  // index keys on `(type)` and serves the selective `type =
  // 'investment'` predicate; the `valuation_mode` predicate filters
  // the candidate rows post-seek. SQLite emits `SEARCH account USING
  // INDEX account_by_type` for this shape, which is *not* a full
  // table scan.
  let detail = try planDetail(
    database,
    query: """
      SELECT id FROM account
      WHERE type = 'investment' AND valuation_mode = 'calculatedFromTrades'
      """)
  #expect(detail.contains("SEARCH account USING INDEX account_by_type"))
  #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "account"))
}
```

- [ ] **Step 2: Run the test to verify it passes already (no production change yet)**

```bash
mkdir -p .agent-tmp
just test-mac DailyBalancesPlanPinningTests/fetchTradesModeInvestmentAccountIdsUsesAccountByType 2>&1 | tee .agent-tmp/test.txt
```

Expected: PASS — the SQL string is a literal and the planner emits the
same shape as the snapshot-mode predicate. The test pins the plan
shape; the production helper is added in Step 3.

- [ ] **Step 3: Add the production fetch helper**

Open `Backends/GRDB/Repositories/GRDBAnalysisRepository+DailyBalancesInvestmentValues.swift`.
Locate `fetchInvestmentAccountIds` (around line 27). Add a sibling
function directly after it:

```swift
  /// Loads every account id whose `type = 'investment'` AND whose
  /// `valuation_mode = 'calculatedFromTrades'`. The trades-mode fold
  /// (`applyTradesModePositionValuations`) walks per-day position
  /// deltas for these accounts and valuates the cumulative positions
  /// against the conversion service on the day's date. Recorded-value
  /// investment accounts are intentionally excluded — they contribute
  /// via the snapshot fold instead. Reading the column directly off
  /// the `account` table avoids carrying the full account row across
  /// the position-row boundary.
  static func fetchTradesModeInvestmentAccountIds(
    database: Database
  ) throws -> Set<UUID> {
    let rows = try Row.fetchAll(
      database,
      sql: """
        SELECT id FROM account
        WHERE type = 'investment' AND valuation_mode = 'calculatedFromTrades'
        """)
    var ids = Set<UUID>()
    ids.reserveCapacity(rows.count)
    for row in rows {
      if let id: UUID = row["id"] {
        ids.insert(id)
      }
    }
    return ids
  }
```

- [ ] **Step 4: Run `just format` and verify the build**

```bash
just format
just build-mac 2>&1 | tee .agent-tmp/build.txt
grep -i "error:\|warning:" .agent-tmp/build.txt | grep -v "Preview"
```

Expected: empty (no errors / warnings).

- [ ] **Step 5: Run the plan-pinning test again — confirms the new helper hasn't regressed**

```bash
just test-mac DailyBalancesPlanPinningTests 2>&1 | tee .agent-tmp/test.txt
grep -i "failed\|error:" .agent-tmp/test.txt
```

Expected: no failures.

- [ ] **Step 6: Commit**

```bash
git -C . add Backends/GRDB/Repositories/GRDBAnalysisRepository+DailyBalancesInvestmentValues.swift MoolahTests/Backends/GRDB/DailyBalancesPlanPinningTests.swift
git -C . commit -m "feat(grdb): add fetchTradesModeInvestmentAccountIds + plan-pin"
```

---

## Task 2: Extend `DailyBalancesAggregation` and `DailyBalancesAssemblyContext`

**Files:**
- Modify: `Backends/GRDB/Repositories/GRDBAnalysisRepository+DailyBalances.swift`

This task only adds fields and updates the construction site; the
fields are wired by Task 3 and consumed by Task 5. Builds cleanly on
its own because the fields default to empty values everywhere they're
read until Task 5 lands.

- [ ] **Step 1: Add new fields to `DailyBalancesAggregation`**

Open `+DailyBalances.swift`. Locate `struct DailyBalancesAggregation:
Sendable` (around line 85). Add the new fields after the existing
`investmentAccountIds`:

```swift
  struct DailyBalancesAggregation: Sendable {
    let priorAccountRows: [DailyBalanceAccountRow]
    let priorEarmarkRows: [DailyBalanceEarmarkRow]
    let accountRows: [DailyBalanceAccountRow]
    let earmarkRows: [DailyBalanceEarmarkRow]
    let investmentValues: [InvestmentValueSnapshot]
    let investmentAccountIds: Set<UUID>
    /// Account ids of trades-mode investment accounts. Drives the new
    /// per-day position-valuation fold; recorded-value accounts are
    /// carried in `investmentAccountIds` and drive the snapshot fold.
    let tradesModeInvestmentAccountIds: Set<UUID>
    /// Pre-cutoff `transaction_leg` SUM rows filtered to trades-mode
    /// investment accounts only. Pre-fold seed for the new fold's
    /// cumulative position dict.
    let priorTradesModeAccountRows: [DailyBalanceAccountRow]
    /// Post-cutoff `transaction_leg` SUM rows filtered to trades-mode
    /// investment accounts only.
    let tradesModeAccountRows: [DailyBalanceAccountRow]
    let scheduled: [Transaction]
    let instrumentMap: [String: Instrument]
    let forecastUntil: Date?
  }
```

- [ ] **Step 2: Add the new field to `DailyBalancesAssemblyContext`**

Locate `struct DailyBalancesAssemblyContext: Sendable` (around line
125). Add `tradesModeInvestmentAccountIds`:

```swift
  struct DailyBalancesAssemblyContext: Sendable {
    let investmentAccountIds: Set<UUID>
    /// Account ids of trades-mode investment accounts — read by
    /// `applyTradesModePositionValuations` to early-exit when the
    /// profile has none. None of the seed/walk helpers consult this
    /// field; trades-mode accounts contribute through the new fold,
    /// not through `accountsFromTransfers`.
    let tradesModeInvestmentAccountIds: Set<UUID>
    let instrumentMap: [String: Instrument]
    let profileInstrument: Instrument
    let conversionService: any InstrumentConversionService
  }
```

- [ ] **Step 3: Update `assembleDailyBalances` context construction**

Locate `assembleDailyBalances` (around line 162). Update the
`DailyBalancesAssemblyContext` construction to forward the new field:

```swift
    let context = DailyBalancesAssemblyContext(
      investmentAccountIds: aggregation.investmentAccountIds,
      tradesModeInvestmentAccountIds: aggregation.tradesModeInvestmentAccountIds,
      instrumentMap: aggregation.instrumentMap,
      profileInstrument: profileInstrument,
      conversionService: conversionService)
```

- [ ] **Step 4: Build to make sure existing call sites still compile**

`DailyBalancesAggregation` has only one constructing call site
(`readDailyBalancesAggregation` in `+DailyBalancesAggregation.swift`).
The build will fail until that call site is updated; Task 3 fixes it.
Skip the build step here and continue to Task 3.

- [ ] **Step 5: Commit**

```bash
git -C . add Backends/GRDB/Repositories/GRDBAnalysisRepository+DailyBalances.swift
git -C . commit -m "feat(grdb): add trades-mode fields to DailyBalancesAggregation"
```

---

## Task 3: Wire `fetchTradesModeInvestmentAccountIds` and pre-filter rows in `readDailyBalancesAggregation`

**Files:**
- Modify: `Backends/GRDB/Repositories/GRDBAnalysisRepository+DailyBalancesAggregation.swift`

- [ ] **Step 1: Update `readDailyBalancesAggregation` to populate the new fields**

Open `+DailyBalancesAggregation.swift`. Locate `readDailyBalancesAggregation`
(around line 47). Update it to call the new fetch and pre-filter the
existing row arrays:

```swift
  private static func readDailyBalancesAggregation(
    database: Database, after: Date?, forecastUntil: Date?
  ) throws -> DailyBalancesAggregation {
    let accountRows = try Self.fetchAccountDeltaRowsPostCutoff(
      database: database, after: after)
    let earmarkRows = try Self.fetchEarmarkDeltaRowsPostCutoff(
      database: database, after: after)
    let (priorAccountRows, priorEarmarkRows) = try Self.fetchPriorDeltaRows(
      database: database, after: after)
    let investmentAccountIds = try Self.fetchInvestmentAccountIds(
      database: database)
    let tradesModeInvestmentAccountIds =
      try Self.fetchTradesModeInvestmentAccountIds(database: database)
    // Fetch `instrumentMap` before the investment-value snapshots so
    // `fetchInvestmentValueSnapshots` can resolve each row's instrument
    // to its registered `Instrument` (with the right `kind` for stock /
    // crypto investments) instead of falling back to fiat-by-id.
    let instrumentMap = try InstrumentRow.fetchInstrumentMap(database: database)
    let investmentValues = try Self.fetchInvestmentValueSnapshots(
      database: database,
      investmentAccountIds: investmentAccountIds,
      instrumentMap: instrumentMap)
    let scheduled =
      forecastUntil != nil
      ? try Self.fetchScheduledTransactions(database: database) : []
    // Pre-filter trades-mode rows out of the already-fetched arrays.
    // Doing the filter inside the read closure (not later) keeps every
    // input the assembly walk needs inside one MVCC snapshot and saves
    // re-checking membership inside the per-day fold.
    let priorTradesModeAccountRows = priorAccountRows.filter {
      tradesModeInvestmentAccountIds.contains($0.accountId)
    }
    let tradesModeAccountRows = accountRows.filter {
      tradesModeInvestmentAccountIds.contains($0.accountId)
    }
    return DailyBalancesAggregation(
      priorAccountRows: priorAccountRows,
      priorEarmarkRows: priorEarmarkRows,
      accountRows: accountRows,
      earmarkRows: earmarkRows,
      investmentValues: investmentValues,
      investmentAccountIds: investmentAccountIds,
      tradesModeInvestmentAccountIds: tradesModeInvestmentAccountIds,
      priorTradesModeAccountRows: priorTradesModeAccountRows,
      tradesModeAccountRows: tradesModeAccountRows,
      scheduled: scheduled,
      instrumentMap: instrumentMap,
      forecastUntil: forecastUntil)
  }
```

- [ ] **Step 2: Update the docstring on `fetchDailyBalancesAggregation`**

Same file, around line 12. Add a bullet for the new fetch in the
existing list ("Loads every input the assembly walk needs in a single
`database.read` snapshot:"):

```swift
  /// Loads every input the assembly walk needs in a single
  /// `database.read` snapshot:
  /// - per-`(day, account, instrument, type)` SUMs split on the
  ///   `:after` cutoff (the post-cutoff rows drive the day-by-day
  ///   walk; the pre-cutoff rows seed the `PositionBook`);
  /// - per-`(day, earmark, instrument, type)` SUMs split the same
  ///   way;
  /// - the scheduled `[Transaction]` for forecast extrapolation;
  /// - the accounts table (so we know which accounts are
  ///   investments — split into recorded-value and trades-mode);
  /// - every `investment_value` row (the cursor walk needs the
  ///   pre-window snapshots so it can carry the most-recent value
  ///   forward into the first in-window day);
  /// - the instrument map.
  ///
  /// One snapshot keeps the four leg-side reads and the scheduled
  /// transactions consistent — three independent reads under WAL
  /// could surface a leg referencing a transaction that hasn't yet
  /// appeared in the transaction list.
```

- [ ] **Step 3: Format and build**

```bash
just format
just build-mac 2>&1 | tee .agent-tmp/build.txt
grep -i "error:\|warning:" .agent-tmp/build.txt | grep -v "Preview"
```

Expected: clean.

- [ ] **Step 4: Run all daily-balance tests to confirm zero regression**

```bash
just test-mac GRDBDailyBalancesAssembleTests GRDBDailyBalancesConversionTests DailyBalancesPlanPinningTests AnalysisRule11ScopingTests 2>&1 | tee .agent-tmp/test.txt
grep -i "failed\|error:" .agent-tmp/test.txt
```

Expected: no failures.

- [ ] **Step 5: Commit**

```bash
git -C . add Backends/GRDB/Repositories/GRDBAnalysisRepository+DailyBalancesAggregation.swift
git -C . commit -m "feat(grdb): wire fetchTradesModeInvestmentAccountIds into aggregation read"
```

---

## Task 4: Aggregation-layer integration tests for the new fields

**Files:**
- Test: `MoolahTests/Backends/GRDB/GRDBDailyBalancesAggregateTests.swift` (or closest sibling — see Step 1)

These pin that `fetchDailyBalancesAggregation` populates the new
fields correctly, so a future bug in `readDailyBalancesAggregation`
that returns empty sets is caught by the aggregation contract tests
(not only by the fold-contract tests in Task 7).

- [ ] **Step 1: Find or create the aggregation-layer test file**

Run:

```bash
ls MoolahTests/Backends/GRDB/ | grep -i "Aggreg\|DailyBalancesAssemble"
```

If `GRDBDailyBalancesAggregateTests.swift` exists, extend it. If it
doesn't, the closest sibling is `GRDBDailyBalancesAssembleTests.swift`
— add the new tests in a fresh `@Suite` block at the bottom of that
file. The tests below assume the new file
`MoolahTests/Backends/GRDB/GRDBDailyBalancesAggregateTests.swift`. If
you place them in `GRDBDailyBalancesAssembleTests.swift`, copy the
file's existing imports and helper-creation patterns rather than the
self-contained fixture below.

- [ ] **Step 2: Write the three failing tests**

Create / edit
`MoolahTests/Backends/GRDB/GRDBDailyBalancesAggregateTests.swift`:

```swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Aggregation-layer integration tests pinning that
/// `fetchDailyBalancesAggregation` populates the trades-mode fields
/// from `readDailyBalancesAggregation`. The fold-contract tests in
/// `GRDBDailyBalancesTradesModeTests` exercise the new fold by
/// constructing `DailyBalancesAggregation` directly; these tests
/// pin the SQL-to-struct wiring so a regression in the aggregation
/// builder doesn't ship past every fold-contract assertion.
@Suite("GRDBAnalysisRepository fetchDailyBalancesAggregation — trades-mode fields")
struct GRDBDailyBalancesAggregateTradesModeTests {

  @Test("populates tradesModeInvestmentAccountIds for trades-mode accounts")
  func populatesTradesModeAccountIds() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let tradesAccount = Account(
      id: UUID(), name: "Trades Account", type: .investment,
      instrument: .defaultTestInstrument,
      valuationMode: .calculatedFromTrades)
    _ = try await backend.accounts.create(tradesAccount)
    let snapshotAccount = Account(
      id: UUID(), name: "Snapshot Account", type: .investment,
      instrument: .defaultTestInstrument,
      valuationMode: .recordedValue)
    _ = try await backend.accounts.create(snapshotAccount)

    let aggregation = try await backend.analysis.testFetchAggregation(
      after: nil, forecastUntil: nil)

    #expect(aggregation.tradesModeInvestmentAccountIds.contains(tradesAccount.id))
    #expect(!aggregation.tradesModeInvestmentAccountIds.contains(snapshotAccount.id))
    #expect(aggregation.investmentAccountIds.contains(snapshotAccount.id))
    #expect(!aggregation.investmentAccountIds.contains(tradesAccount.id))
  }

  @Test("priorTradesModeAccountRows / tradesModeAccountRows hold only trades-mode account rows")
  func filtersAccountRowsByMode() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let tradesAccount = Account(
      id: UUID(), name: "Trades Account", type: .investment,
      instrument: .defaultTestInstrument,
      valuationMode: .calculatedFromTrades)
    _ = try await backend.accounts.create(tradesAccount)
    let snapshotAccount = Account(
      id: UUID(), name: "Snapshot Account", type: .investment,
      instrument: .defaultTestInstrument,
      valuationMode: .recordedValue)
    _ = try await backend.accounts.create(snapshotAccount)
    let bankAccount = Account(
      id: UUID(), name: "Cash", type: .bank,
      instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(bankAccount)

    let cutoff = try AnalysisTestHelpers.date(year: 2025, month: 6, day: 1)
    let priorDate = try AnalysisTestHelpers.date(year: 2025, month: 5, day: 15)
    let postDate = try AnalysisTestHelpers.date(year: 2025, month: 6, day: 15)

    // One transaction on each side of the cutoff for each account.
    for (account, date) in [
      (tradesAccount, priorDate), (tradesAccount, postDate),
      (snapshotAccount, priorDate), (snapshotAccount, postDate),
      (bankAccount, priorDate), (bankAccount, postDate),
    ] {
      _ = try await backend.transactions.create(
        Transaction(
          date: date, payee: "Tick",
          legs: [
            TransactionLeg(
              accountId: account.id, instrument: .defaultTestInstrument,
              quantity: 10, type: .income)
          ]))
    }

    let aggregation = try await backend.analysis.testFetchAggregation(
      after: cutoff, forecastUntil: nil)

    let priorIds = Set(aggregation.priorTradesModeAccountRows.map(\.accountId))
    let postIds = Set(aggregation.tradesModeAccountRows.map(\.accountId))
    #expect(priorIds == [tradesAccount.id])
    #expect(postIds == [tradesAccount.id])
  }

  @Test("empty trades-mode profile produces empty arrays")
  func emptyTradesModeProfileEmptyArrays() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let snapshotAccount = Account(
      id: UUID(), name: "Snapshot Account", type: .investment,
      instrument: .defaultTestInstrument,
      valuationMode: .recordedValue)
    _ = try await backend.accounts.create(snapshotAccount)

    let aggregation = try await backend.analysis.testFetchAggregation(
      after: nil, forecastUntil: nil)

    #expect(aggregation.tradesModeInvestmentAccountIds.isEmpty)
    #expect(aggregation.priorTradesModeAccountRows.isEmpty)
    #expect(aggregation.tradesModeAccountRows.isEmpty)
  }
}
```

- [ ] **Step 3: Add a `testFetchAggregation` shim to `CloudKitAnalysisTestBackend` if it doesn't exist**

Run:

```bash
grep -n "testFetchAggregation\|fetchDailyBalancesAggregation" MoolahTests/Support/CloudKitAnalysisTestBackend.swift
```

If `testFetchAggregation` is not defined, add it. Open the file, find
the `analysis` accessor, and add a new method:

```swift
extension CloudKitAnalysisTestBackend {
  /// Test-only entry point that exposes `fetchDailyBalancesAggregation`
  /// for aggregation-layer integration tests. Production callers go
  /// through `analysis.fetchDailyBalances(...)`; this shim lets tests
  /// pin the aggregation contract without re-running the full
  /// per-day walk.
  func testFetchAggregation(
    after: Date?, forecastUntil: Date?
  ) async throws -> GRDBAnalysisRepository.DailyBalancesAggregation {
    let analysis = self.analysis as! GRDBAnalysisRepository
    return try await GRDBAnalysisRepository.fetchDailyBalancesAggregation(
      database: analysis.databaseReader,
      after: after,
      forecastUntil: forecastUntil)
  }
}
```

The `as!` cast is acceptable in test support code because the test
backend is constructed against `GRDBAnalysisRepository` specifically.

If the `databaseReader` property is `private`, expose an internal
`testDatabaseReader: any DatabaseReader { databaseReader }` on
`GRDBAnalysisRepository` and use that instead. Check by running:

```bash
grep -n "databaseReader\|database:.*DatabaseReader" Backends/GRDB/Repositories/GRDBAnalysisRepository.swift
```

Use whichever access path is already exposed.

- [ ] **Step 4: Run the new tests — they should pass**

```bash
just format
just test-mac GRDBDailyBalancesAggregateTradesModeTests 2>&1 | tee .agent-tmp/test.txt
grep -i "failed\|error:" .agent-tmp/test.txt
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git -C . add MoolahTests/Backends/GRDB/GRDBDailyBalancesAggregateTests.swift MoolahTests/Support/CloudKitAnalysisTestBackend.swift
git -C . commit -m "test(grdb): aggregation-layer pins for trades-mode fields"
```

---

## Task 5: Drop vestigial `?` on `sumInvestmentValues` and tighten Rule 11 in `applyInvestmentValues`

**Files:**
- Modify: `Backends/GRDB/Repositories/GRDBAnalysisRepository+DailyBalancesInvestmentValues.swift`

This task fixes the existing snapshot fold:
1. Drop the `?` on `sumInvestmentValues`'s return type — never returns
   `nil` on success, `?` is dead.
2. Update its caller in `applyInvestmentValues` to the non-optional
   shape.
3. Add `dailyBalances.removeValue(forKey: date)` to the catch branch
   so per-day failures drop the day (Rule 11) — matches `walkDays`.

- [ ] **Step 1: Write the failing Rule 11 test for the snapshot fold**

Open `MoolahTests/Backends/GRDB/GRDBDailyBalancesAssembleTests.swift`.
Add a new test at the bottom of the existing suite:

```swift
  @Test("snapshot fold drops the day from dailyBalances on per-day conversion failure")
  func snapshotFoldDropsDayOnFailure() async throws {
    // Build an aggregation with one investment-value snapshot on day D.
    let day = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let dayKey = AnalysisTestHelpers.calendar.startOfDay(for: day)
    let usd = Instrument.fiat(code: "USD")
    let accountId = UUID()
    let aggregation = GRDBAnalysisRepository.DailyBalancesAggregation(
      priorAccountRows: [],
      priorEarmarkRows: [],
      accountRows: [],
      earmarkRows: [],
      investmentValues: [
        InvestmentValueSnapshot(
          accountId: accountId, date: day,
          value: InstrumentAmount(quantity: 100, instrument: usd))
      ],
      investmentAccountIds: [accountId],
      tradesModeInvestmentAccountIds: [],
      priorTradesModeAccountRows: [],
      tradesModeAccountRows: [],
      scheduled: [],
      instrumentMap: ["USD": usd],
      forecastUntil: nil)
    // Seed the dailyBalances dict directly so we test the fold in
    // isolation. Insert a placeholder DailyBalance for `dayKey` so the
    // fold has a key to drop.
    var dailyBalances: [Date: DailyBalance] = [
      dayKey: DailyBalance(
        date: dayKey,
        balance: .zero(instrument: .defaultTestInstrument),
        earmarked: .zero(instrument: .defaultTestInstrument),
        availableFunds: .zero(instrument: .defaultTestInstrument),
        investments: .zero(instrument: .defaultTestInstrument),
        investmentValue: nil,
        netWorth: .zero(instrument: .defaultTestInstrument),
        bestFit: nil,
        isForecast: false)
    ]
    let conversionService = DateFailingConversionService(
      rates: [:], failingDates: [dayKey])
    var capturedFailures: [(Error, Date)] = []
    let handlers = GRDBAnalysisRepository.DailyBalancesHandlers(
      handleUnparseableDay: { _ in },
      handleConversionFailure: { _, _ in },
      handleInvestmentValueFailure: { error, date in
        capturedFailures.append((error, date))
      })
    let context = GRDBAnalysisRepository.DailyBalancesAssemblyContext(
      investmentAccountIds: aggregation.investmentAccountIds,
      tradesModeInvestmentAccountIds: aggregation.tradesModeInvestmentAccountIds,
      instrumentMap: aggregation.instrumentMap,
      profileInstrument: .defaultTestInstrument,
      conversionService: conversionService)

    try await GRDBAnalysisRepository.applyInvestmentValues(
      aggregation.investmentValues,
      to: &dailyBalances,
      context: context,
      handlers: handlers)

    // Rule 11: a snapshot conversion failure on day D must drop day D
    // from dailyBalances. Sibling days (none here) are unaffected.
    #expect(dailyBalances[dayKey] == nil)
    #expect(capturedFailures.count == 1)
    #expect(capturedFailures.first?.1 == dayKey)
  }
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
just test-mac GRDBDailyBalancesAssembleTests/snapshotFoldDropsDayOnFailure 2>&1 | tee .agent-tmp/test.txt
grep -i "failed\|error:" .agent-tmp/test.txt
```

Expected: FAIL — current `applyInvestmentValues` `continue`s without
removing the day, so `dailyBalances[dayKey]` is still present.

- [ ] **Step 3: Drop `?` from `sumInvestmentValues`**

Open `+DailyBalancesInvestmentValues.swift`. Locate
`sumInvestmentValues` (around line 178). Change:

```swift
  private static func sumInvestmentValues(
    latestByAccount: [UUID: InstrumentAmount],
    on date: Date,
    profileInstrument: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> InstrumentAmount? {
```

to:

```swift
  /// Sum the per-account investment values, converting foreign
  /// instruments to the profile instrument on `date`. Throws on any
  /// conversion failure so the caller can drop the day from the
  /// `dailyBalances` dict per Rule 11. The return is non-optional —
  /// the function either throws or returns the converted total.
  private static func sumInvestmentValues(
    latestByAccount: [UUID: InstrumentAmount],
    on date: Date,
    profileInstrument: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> InstrumentAmount {
```

The function body's `return InstrumentAmount(quantity: total,
instrument: profileInstrument)` already returns a non-optional — no
body change required.

- [ ] **Step 4: Update `applyInvestmentValues`'s call to the non-optional shape and tighten the catch branch**

Same file. Locate `applyInvestmentValues` (around line 107). Replace
the body from `let totalValue: InstrumentAmount?` through the
`dailyBalances[date] = DailyBalance(...)` block with:

```swift
    for date in dailyBalances.keys.sorted() {
      valueIndex = advanceInvestmentCursor(
        values: investmentValues,
        latestByAccount: &latestByAccount,
        from: valueIndex,
        upTo: date)
      if latestByAccount.isEmpty { continue }
      let totalValue: InstrumentAmount
      do {
        totalValue = try await sumInvestmentValues(
          latestByAccount: latestByAccount,
          on: date,
          profileInstrument: context.profileInstrument,
          conversionService: context.conversionService)
      } catch let cancel as CancellationError {
        throw cancel
      } catch {
        // Rule 11: drop the day from dailyBalances so the chart shows
        // a gap rather than rendering a partial total. Matches the
        // walkDays per-day error contract.
        handlers.handleInvestmentValueFailure(error, date)
        dailyBalances.removeValue(forKey: date)
        continue
      }
      guard let balance = dailyBalances[date] else { continue }
      dailyBalances[date] = DailyBalance(
        date: balance.date,
        balance: balance.balance,
        earmarked: balance.earmarked,
        availableFunds: balance.availableFunds,
        investments: balance.investments,
        investmentValue: totalValue,
        netWorth: balance.balance + totalValue,
        bestFit: balance.bestFit,
        isForecast: balance.isForecast)
    }
```

(Diffs from the original: `let totalValue: InstrumentAmount?` →
`let totalValue: InstrumentAmount`; new
`dailyBalances.removeValue(forKey: date)` line in the catch branch;
`guard let totalValue, let balance = dailyBalances[date] else { continue }`
collapses to `guard let balance = dailyBalances[date] else { continue }`.)

- [ ] **Step 5: Format and run the new test**

```bash
just format
just test-mac GRDBDailyBalancesAssembleTests/snapshotFoldDropsDayOnFailure 2>&1 | tee .agent-tmp/test.txt
```

Expected: PASS.

- [ ] **Step 6: Run the full daily-balance suite to confirm nothing else regresses**

```bash
just test-mac GRDBDailyBalancesAssembleTests GRDBDailyBalancesConversionTests AnalysisRule11ScopingTests DailyBalancesPlanPinningTests 2>&1 | tee .agent-tmp/test.txt
grep -i "failed\|error:" .agent-tmp/test.txt
```

Expected: no failures.

- [ ] **Step 7: Commit**

```bash
git -C . add Backends/GRDB/Repositories/GRDBAnalysisRepository+DailyBalancesInvestmentValues.swift MoolahTests/Backends/GRDB/GRDBDailyBalancesAssembleTests.swift
git -C . commit -m "fix(grdb): drop snapshot day on conversion failure (Rule 11) + cleanup"
```

---

## Task 6: Add the new fold — `applyTradesModePositionValuations`

**Files:**
- Modify: `Backends/GRDB/Repositories/GRDBAnalysisRepository+DailyBalancesInvestmentValues.swift`
- Modify: `Backends/GRDB/Repositories/GRDBAnalysisRepository+DailyBalances.swift`

This task introduces the production fold. Tests come in Task 7.

- [ ] **Step 1: Add the file-private `TradesModePositionEntry` struct + the new fold + helper**

Open `+DailyBalancesInvestmentValues.swift`. Append the following at
the bottom of the existing `extension GRDBAnalysisRepository` block,
after `sumInvestmentValues`:

```swift
  // MARK: - Trades-mode per-day fold

  /// One decoded entry in the trades-mode cursor walk — a per-day,
  /// per-account, per-instrument quantity ready to apply to the
  /// cumulative `positions` dict. Four fields exceeds SwiftLint's
  /// `large_tuple` error threshold, so a named struct is required.
  private struct TradesModePositionEntry {
    let dayKey: Date
    let accountId: UUID
    let instrument: Instrument
    let quantity: Decimal
  }

  /// Per-day position-valuation fold for trades-mode investment
  /// accounts. Sister of `applyInvestmentValues` — same per-day error
  /// contract: `CancellationError` rethrows immediately; any other
  /// thrown error drops the day from `dailyBalances` and logs through
  /// `handleInvestmentValueFailure`.
  ///
  /// The fold builds a sorted cursor over trades-mode rows
  /// (`(dayKey, accountId, instrument, quantity)` entries), then
  /// walks `dailyBalances.keys.sorted()`. For each output `dayKey`,
  /// the cursor advances through every entry with `entry.dayKey <=
  /// dayKey` — including entries for days absent from
  /// `dailyBalances` (e.g. dropped by an earlier snapshot-fold
  /// failure) — so cumulative position state stays correct on every
  /// following day.
  ///
  /// `priorRows` and `postRows` carry only rows whose `accountId`
  /// belongs to a trades-mode investment account — pre-filtered in
  /// `readDailyBalancesAggregation` so this fold neither re-checks
  /// membership nor walks rows for accounts it doesn't own.
  static func applyTradesModePositionValuations(
    priorRows: [DailyBalanceAccountRow],
    postRows: [DailyBalanceAccountRow],
    to dailyBalances: inout [Date: DailyBalance],
    context: DailyBalancesAssemblyContext,
    handlers: DailyBalancesHandlers
  ) async throws {
    guard !context.tradesModeInvestmentAccountIds.isEmpty,
      !dailyBalances.isEmpty
    else { return }

    // Pre-fold priors into a per-account, per-instrument cumulative
    // dict. Decoding mirrors `applyDailyDeltas`: resolve the
    // instrument via the registry, then convert the row's storage
    // value into a Decimal quantity.
    var positions: [UUID: [Instrument: Decimal]] = [:]
    for row in priorRows {
      let instrument = resolveInstrument(row.instrumentId, in: context.instrumentMap)
      let quantity = InstrumentAmount(
        storageValue: row.qty, instrument: instrument
      ).quantity
      positions[row.accountId, default: [:]][instrument, default: 0] += quantity
    }

    // Build a sorted cursor over post rows. Grouping by SQL `\.day`
    // (UTC string) is intentionally avoided — the outer walk is over
    // local-startOfDay `Date` keys, so we key the cursor at `dayKey`
    // granularity directly to avoid Rule 10 timezone mismatch.
    var entries: [TradesModePositionEntry] = []
    entries.reserveCapacity(postRows.count)
    for row in postRows {
      let instrument = resolveInstrument(row.instrumentId, in: context.instrumentMap)
      let quantity = InstrumentAmount(
        storageValue: row.qty, instrument: instrument
      ).quantity
      entries.append(
        TradesModePositionEntry(
          dayKey: Calendar.current.startOfDay(for: row.sampleDate),
          accountId: row.accountId,
          instrument: instrument,
          quantity: quantity))
    }
    entries.sort { $0.dayKey < $1.dayKey }

    var valueIndex = 0
    for dayKey in dailyBalances.keys.sorted() {
      // Advance the cursor: apply every entry on-or-before dayKey,
      // including those for days absent from dailyBalances.
      while valueIndex < entries.count, entries[valueIndex].dayKey <= dayKey {
        let entry = entries[valueIndex]
        positions[entry.accountId, default: [:]][entry.instrument, default: 0] +=
          entry.quantity
        valueIndex += 1
      }
      if positions.isEmpty { continue }
      do {
        // dayKey is `Calendar.current.startOfDay(for: row.sampleDate)`
        // — same normalization as walkDays and the conversion-service
        // lookup.
        let total = try await sumTradesModePositions(
          positions: positions,
          on: dayKey,
          profileInstrument: context.profileInstrument,
          conversionService: context.conversionService)
        if let existing = dailyBalances[dayKey] {
          let combined =
            (existing.investmentValue ?? .zero(instrument: context.profileInstrument))
            + total
          dailyBalances[dayKey] = DailyBalance(
            date: existing.date,
            balance: existing.balance,
            earmarked: existing.earmarked,
            availableFunds: existing.availableFunds,
            investments: existing.investments,
            investmentValue: combined,
            netWorth: existing.balance + combined,
            bestFit: existing.bestFit,
            isForecast: existing.isForecast)
        }
      } catch let cancel as CancellationError {
        throw cancel
      } catch {
        // Rule 11: drop the day from dailyBalances so the chart shows
        // a gap. Matches the walkDays / applyInvestmentValues
        // per-day error contract.
        handlers.handleInvestmentValueFailure(error, dayKey)
        dailyBalances.removeValue(forKey: dayKey)
        continue
      }
    }
  }

  /// Sum per-account, per-instrument trades-mode positions on `date`,
  /// converting foreign instruments to the profile instrument via the
  /// conversion service. Rule 8 fast path applies at the leaf level
  /// so an account holding both profile-instrument and foreign-
  /// instrument positions still routes only the foreign positions
  /// through the service. Cancellation propagates via the service's
  /// own `await` — no manual `Task.isCancelled` check needed (matches
  /// `sumInvestmentValues`).
  private static func sumTradesModePositions(
    positions: [UUID: [Instrument: Decimal]],
    on date: Date,
    profileInstrument: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> InstrumentAmount {
    var total: Decimal = 0
    for (_, perInstrument) in positions {
      for (instrument, quantity) in perInstrument {
        if instrument.id == profileInstrument.id {
          total += quantity
          continue
        }
        total += try await conversionService.convert(
          quantity, from: instrument, to: profileInstrument, on: date)
      }
    }
    return InstrumentAmount(quantity: total, instrument: profileInstrument)
  }
```

- [ ] **Step 2: Wire the fold into `assembleDailyBalances`**

Open `+DailyBalances.swift`. Locate `assembleDailyBalances` (around
line 162). After the existing `try await applyInvestmentValues(...)`
call, add the new fold call:

```swift
    try await applyInvestmentValues(
      aggregation.investmentValues,
      to: &dailyBalances,
      context: context,
      handlers: handlers)

    try await applyTradesModePositionValuations(
      priorRows: aggregation.priorTradesModeAccountRows,
      postRows: aggregation.tradesModeAccountRows,
      to: &dailyBalances,
      context: context,
      handlers: handlers)
```

(Place the new call before the `var actualBalances = ...` line and
the subsequent `applyBestFit` / forecast steps.)

- [ ] **Step 3: Format and build**

```bash
just format
just build-mac 2>&1 | tee .agent-tmp/build.txt
grep -i "error:\|warning:" .agent-tmp/build.txt | grep -v "Preview"
```

Expected: clean.

- [ ] **Step 4: Run the existing daily-balance suite — no behaviour change for
  profiles without trades-mode accounts**

```bash
just test-mac GRDBDailyBalancesAssembleTests GRDBDailyBalancesConversionTests AnalysisRule11ScopingTests DailyBalancesPlanPinningTests GRDBDailyBalancesAggregateTradesModeTests 2>&1 | tee .agent-tmp/test.txt
grep -i "failed\|error:" .agent-tmp/test.txt
```

Expected: no failures.

- [ ] **Step 5: Commit**

```bash
git -C . add Backends/GRDB/Repositories/GRDBAnalysisRepository+DailyBalancesInvestmentValues.swift Backends/GRDB/Repositories/GRDBAnalysisRepository+DailyBalances.swift
git -C . commit -m "feat(grdb): per-day trades-mode position-valuation fold"
```

---

## Task 7: Fold-contract tests for `applyTradesModePositionValuations`

**Files:**
- Test: `MoolahTests/Backends/GRDB/GRDBDailyBalancesTradesModeTests.swift` (new file)

Twelve tests from spec §9.3 covering happy path, mixed mode, Rule 11
failure scoping, Rule 10 normalization, no-op early return,
CSV-imported trade interaction, same-day BUY+SELL, and the
carry-forward-across-dropped-day correctness pin.

- [ ] **Step 1: Create the test file with the suite header and two helpers**

Create `MoolahTests/Backends/GRDB/GRDBDailyBalancesTradesModeTests.swift`:

```swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Fold-contract tests for
/// `GRDBAnalysisRepository.applyTradesModePositionValuations`.
/// Tests construct `DailyBalancesAggregation` directly and seed
/// `dailyBalances` with placeholder entries so the fold can be
/// exercised in isolation, mirroring the
/// `GRDBDailyBalancesAssembleTests` style.
@Suite("GRDBAnalysisRepository applyTradesModePositionValuations")
struct GRDBDailyBalancesTradesModeTests {

  /// Closure-captured failure log shared across cases that need to
  /// assert per-day callback shape. Same pattern as
  /// `GRDBDailyBalancesAssembleTests`'s `FailureLog`.
  static func makeHandlers(
    failures: @escaping @Sendable (Error, Date) -> Void
  ) -> GRDBAnalysisRepository.DailyBalancesHandlers {
    GRDBAnalysisRepository.DailyBalancesHandlers(
      handleUnparseableDay: { _ in },
      handleConversionFailure: { _, _ in },
      handleInvestmentValueFailure: failures)
  }

  static func placeholderBalance(at dayKey: Date) -> DailyBalance {
    DailyBalance(
      date: dayKey,
      balance: .zero(instrument: .defaultTestInstrument),
      earmarked: .zero(instrument: .defaultTestInstrument),
      availableFunds: .zero(instrument: .defaultTestInstrument),
      investments: .zero(instrument: .defaultTestInstrument),
      investmentValue: nil,
      netWorth: .zero(instrument: .defaultTestInstrument),
      bestFit: nil,
      isForecast: false)
  }

  static func makeContext(
    tradesIds: Set<UUID>,
    instrumentMap: [String: Instrument],
    conversionService: any InstrumentConversionService
  ) -> GRDBAnalysisRepository.DailyBalancesAssemblyContext {
    GRDBAnalysisRepository.DailyBalancesAssemblyContext(
      investmentAccountIds: [],
      tradesModeInvestmentAccountIds: tradesIds,
      instrumentMap: instrumentMap,
      profileInstrument: .defaultTestInstrument,
      conversionService: conversionService)
  }
}
```

- [ ] **Step 2: Add cases 1, 8, 9 (single buy, no trades-mode accounts, empty dailyBalances)**

Inside the same `struct GRDBDailyBalancesTradesModeTests` body, append:

```swift
  @Test("case 1: single buy on day D values at day D's price")
  func singleBuyOnDay() async throws {
    let day = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let dayKey = AnalysisTestHelpers.calendar.startOfDay(for: day)
    let usd = Instrument.fiat(code: "USD")
    let accountId = UUID()
    let row = GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: "2025-06-10", sampleDate: day,
      accountId: accountId, instrumentId: "USD", type: "trade", qty: 1000)
    let conversion = DateBasedFixedConversionService(
      rates: [
        try AnalysisTestHelpers.utcDate(year: 2025, month: 1, day: 1, hour: 0): [
          "USD": try AnalysisTestHelpers.decimal("1.5")
        ]
      ])
    var balances: [Date: DailyBalance] = [
      dayKey: GRDBDailyBalancesTradesModeTests.placeholderBalance(at: dayKey)
    ]
    let context = Self.makeContext(
      tradesIds: [accountId],
      instrumentMap: ["USD": usd],
      conversionService: conversion)
    let handlers = Self.makeHandlers { _, _ in }

    try await GRDBAnalysisRepository.applyTradesModePositionValuations(
      priorRows: [], postRows: [row],
      to: &balances, context: context, handlers: handlers)

    let dayBalance = try #require(balances[dayKey])
    // qty 1000 storage units = 10.00 quantity for USD; * 1.5 rate = 15.00 AUD.
    let expected = try AnalysisTestHelpers.decimal("15")
    let value = try #require(dayBalance.investmentValue)
    #expect(value.quantity == expected)
    #expect(value.instrument == .defaultTestInstrument)
    #expect(dayBalance.netWorth.quantity == expected)
  }

  @Test("case 8: no trades-mode accounts — fold is a no-op")
  func noTradesModeAccounts() async throws {
    let day = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let dayKey = AnalysisTestHelpers.calendar.startOfDay(for: day)
    var balances: [Date: DailyBalance] = [
      dayKey: GRDBDailyBalancesTradesModeTests.placeholderBalance(at: dayKey)
    ]
    let originalBalance = balances[dayKey]
    let conversion = DateBasedFixedConversionService(rates: [:])
    let context = Self.makeContext(
      tradesIds: [], instrumentMap: [:], conversionService: conversion)
    let handlers = Self.makeHandlers { _, _ in }

    try await GRDBAnalysisRepository.applyTradesModePositionValuations(
      priorRows: [], postRows: [],
      to: &balances, context: context, handlers: handlers)

    #expect(balances[dayKey] == originalBalance)
  }

  @Test("case 9: empty dailyBalances — no callback fires")
  func emptyDailyBalances() async throws {
    let accountId = UUID()
    var balances: [Date: DailyBalance] = [:]
    let usd = Instrument.fiat(code: "USD")
    let conversion = DateBasedFixedConversionService(rates: [:])
    let context = Self.makeContext(
      tradesIds: [accountId],
      instrumentMap: ["USD": usd],
      conversionService: conversion)
    var failures: [(Error, Date)] = []
    let handlers = Self.makeHandlers { error, date in
      failures.append((error, date))
    }

    try await GRDBAnalysisRepository.applyTradesModePositionValuations(
      priorRows: [], postRows: [],
      to: &balances, context: context, handlers: handlers)

    #expect(balances.isEmpty)
    #expect(failures.isEmpty)
  }
```

- [ ] **Step 3: Add case 2 (two trades-mode accounts on same day)**

Append:

```swift
  @Test("case 2: two trades-mode accounts both contribute on day D")
  func twoTradesModeAccountsSameDay() async throws {
    let day = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let dayKey = AnalysisTestHelpers.calendar.startOfDay(for: day)
    let usd = Instrument.fiat(code: "USD")
    let aId = UUID()
    let bId = UUID()
    let rowA = GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: "2025-06-10", sampleDate: day,
      accountId: aId, instrumentId: "USD", type: "trade", qty: 1000)
    let rowB = GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: "2025-06-10", sampleDate: day,
      accountId: bId, instrumentId: "USD", type: "trade", qty: 2000)
    let conversion = DateBasedFixedConversionService(
      rates: [
        try AnalysisTestHelpers.utcDate(year: 2025, month: 1, day: 1, hour: 0): [
          "USD": try AnalysisTestHelpers.decimal("1.5")
        ]
      ])
    var balances: [Date: DailyBalance] = [
      dayKey: GRDBDailyBalancesTradesModeTests.placeholderBalance(at: dayKey)
    ]
    let context = Self.makeContext(
      tradesIds: [aId, bId],
      instrumentMap: ["USD": usd],
      conversionService: conversion)
    let handlers = Self.makeHandlers { _, _ in }

    try await GRDBAnalysisRepository.applyTradesModePositionValuations(
      priorRows: [], postRows: [rowA, rowB],
      to: &balances, context: context, handlers: handlers)

    // (10 + 20) * 1.5 = 45.
    let value = try #require(balances[dayKey]?.investmentValue)
    #expect(value.quantity == try AnalysisTestHelpers.decimal("45"))
  }
```

- [ ] **Step 4: Add case 3 (trades-mode + recorded-value sum)**

Append:

```swift
  @Test("case 3: trades-mode + recorded-value account totals add into one investmentValue")
  func tradesModePlusRecordedValueSum() async throws {
    let day = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let dayKey = AnalysisTestHelpers.calendar.startOfDay(for: day)
    let usd = Instrument.fiat(code: "USD")
    let tradesId = UUID()
    let row = GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: "2025-06-10", sampleDate: day,
      accountId: tradesId, instrumentId: "USD", type: "trade", qty: 1000)
    let conversion = DateBasedFixedConversionService(
      rates: [
        try AnalysisTestHelpers.utcDate(year: 2025, month: 1, day: 1, hour: 0): [
          "USD": try AnalysisTestHelpers.decimal("1.5")
        ]
      ])
    // Pre-seed the day with a snapshot-fold contribution so the new
    // fold's add-not-overwrite contract is visible.
    var balances: [Date: DailyBalance] = [
      dayKey: DailyBalance(
        date: dayKey,
        balance: InstrumentAmount(
          quantity: 10, instrument: .defaultTestInstrument),
        earmarked: .zero(instrument: .defaultTestInstrument),
        availableFunds: InstrumentAmount(
          quantity: 10, instrument: .defaultTestInstrument),
        investments: .zero(instrument: .defaultTestInstrument),
        investmentValue: InstrumentAmount(
          quantity: 100, instrument: .defaultTestInstrument),
        netWorth: InstrumentAmount(
          quantity: 110, instrument: .defaultTestInstrument),
        bestFit: nil,
        isForecast: false)
    ]
    let context = Self.makeContext(
      tradesIds: [tradesId],
      instrumentMap: ["USD": usd],
      conversionService: conversion)
    let handlers = Self.makeHandlers { _, _ in }

    try await GRDBAnalysisRepository.applyTradesModePositionValuations(
      priorRows: [], postRows: [row],
      to: &balances, context: context, handlers: handlers)

    // Snapshot 100 + trades (10 USD * 1.5) = 115.
    let dayBalance = try #require(balances[dayKey])
    let value = try #require(dayBalance.investmentValue)
    #expect(value.quantity == try AnalysisTestHelpers.decimal("115"))
    // netWorth = balance (10) + investmentValue (115) = 125.
    #expect(dayBalance.netWorth.quantity == try AnalysisTestHelpers.decimal("125"))
  }
```

- [ ] **Step 5: Add case 4 (Rule 11 per-day failure scoping for the new fold)**

Append:

```swift
  @Test("case 4: per-day conversion failure drops day from dailyBalances")
  func ruleEleven_perDayFailureScopedToDay() async throws {
    let dayOne = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let dayTwo = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 11, hour: 12)
    let keyOne = AnalysisTestHelpers.calendar.startOfDay(for: dayOne)
    let keyTwo = AnalysisTestHelpers.calendar.startOfDay(for: dayTwo)
    let usd = Instrument.fiat(code: "USD")
    let accountId = UUID()
    let rowOne = GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: "2025-06-10", sampleDate: dayOne,
      accountId: accountId, instrumentId: "USD", type: "trade", qty: 1000)
    // Rate available on day two only; day one fails.
    let conversion = DateFailingConversionService(
      rates: [
        try AnalysisTestHelpers.utcDate(year: 2025, month: 1, day: 1, hour: 0): [
          "USD": try AnalysisTestHelpers.decimal("1.5")
        ]
      ],
      failingDates: [keyOne])
    var balances: [Date: DailyBalance] = [
      keyOne: GRDBDailyBalancesTradesModeTests.placeholderBalance(at: keyOne),
      keyTwo: GRDBDailyBalancesTradesModeTests.placeholderBalance(at: keyTwo),
    ]
    let context = Self.makeContext(
      tradesIds: [accountId],
      instrumentMap: ["USD": usd],
      conversionService: conversion)
    var failures: [(Error, Date)] = []
    let handlers = Self.makeHandlers { error, date in
      failures.append((error, date))
    }

    try await GRDBAnalysisRepository.applyTradesModePositionValuations(
      priorRows: [], postRows: [rowOne],
      to: &balances, context: context, handlers: handlers)

    // Day one dropped (failed conversion); day two retained
    // (cumulative position 10 USD * 1.5 = 15).
    #expect(balances[keyOne] == nil)
    let value = try #require(balances[keyTwo]?.investmentValue)
    #expect(value.quantity == try AnalysisTestHelpers.decimal("15"))
    #expect(failures.count == 1)
    #expect(failures.first?.1 == keyOne)
  }
```

- [ ] **Step 6: Add cases 5 and 6 (snapshot-fold-then-trades-fold interactions)**

Case 5 was added in Task 5. Case 6 follows the §9.3 spec: when the
trades fold fails on day D after the snapshot fold succeeded, day D
is dropped.

Append:

```swift
  @Test("case 6: trades-fold failure on day D after snapshot-fold success drops day")
  func mixedFoldFailureDropsDay() async throws {
    let day = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let dayKey = AnalysisTestHelpers.calendar.startOfDay(for: day)
    let usd = Instrument.fiat(code: "USD")
    let accountId = UUID()
    let row = GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: "2025-06-10", sampleDate: day,
      accountId: accountId, instrumentId: "USD", type: "trade", qty: 1000)
    let conversion = DateFailingConversionService(
      rates: [:], failingDates: [dayKey])
    // Pre-seed the day as if applyInvestmentValues had succeeded with
    // a recorded-value snapshot total of 100.
    var balances: [Date: DailyBalance] = [
      dayKey: DailyBalance(
        date: dayKey,
        balance: InstrumentAmount(
          quantity: 10, instrument: .defaultTestInstrument),
        earmarked: .zero(instrument: .defaultTestInstrument),
        availableFunds: InstrumentAmount(
          quantity: 10, instrument: .defaultTestInstrument),
        investments: .zero(instrument: .defaultTestInstrument),
        investmentValue: InstrumentAmount(
          quantity: 100, instrument: .defaultTestInstrument),
        netWorth: InstrumentAmount(
          quantity: 110, instrument: .defaultTestInstrument),
        bestFit: nil,
        isForecast: false)
    ]
    let context = Self.makeContext(
      tradesIds: [accountId],
      instrumentMap: ["USD": usd],
      conversionService: conversion)
    var failures: [(Error, Date)] = []
    let handlers = Self.makeHandlers { error, date in
      failures.append((error, date))
    }

    try await GRDBAnalysisRepository.applyTradesModePositionValuations(
      priorRows: [], postRows: [row],
      to: &balances, context: context, handlers: handlers)

    #expect(balances[dayKey] == nil)
    #expect(failures.count == 1)
  }
```

- [ ] **Step 7: Add case 7 (Rule 10 startOfDay normalization)**

The fold uses `Calendar.current.startOfDay(for: row.sampleDate)` for
the cursor key. Two trades whose `sampleDate` straddles a local-day
boundary must apply on their respective `startOfDay` keys.

Append:

```swift
  @Test("case 7: startOfDay normalization keys days correctly across local boundary")
  func rule10StartOfDayNormalization() async throws {
    let cal = AnalysisTestHelpers.calendar
    // Create two timestamps in the same local day; both must
    // produce the same dayKey.
    let dayMorning = try AnalysisTestHelpers.date(year: 2025, month: 6, day: 10, hour: 9)
    let dayEvening = try AnalysisTestHelpers.date(year: 2025, month: 6, day: 10, hour: 23)
    let dayKey = cal.startOfDay(for: dayMorning)
    #expect(cal.startOfDay(for: dayEvening) == dayKey)

    let usd = Instrument.fiat(code: "USD")
    let accountId = UUID()
    let rowMorning = GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: "2025-06-10", sampleDate: dayMorning,
      accountId: accountId, instrumentId: "USD", type: "trade", qty: 500)
    let rowEvening = GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: "2025-06-10", sampleDate: dayEvening,
      accountId: accountId, instrumentId: "USD", type: "trade", qty: 500)
    let conversion = DateBasedFixedConversionService(
      rates: [
        try AnalysisTestHelpers.utcDate(year: 2025, month: 1, day: 1, hour: 0): [
          "USD": try AnalysisTestHelpers.decimal("1.5")
        ]
      ])
    var balances: [Date: DailyBalance] = [
      dayKey: GRDBDailyBalancesTradesModeTests.placeholderBalance(at: dayKey)
    ]
    let context = Self.makeContext(
      tradesIds: [accountId],
      instrumentMap: ["USD": usd],
      conversionService: conversion)
    let handlers = Self.makeHandlers { _, _ in }

    try await GRDBAnalysisRepository.applyTradesModePositionValuations(
      priorRows: [], postRows: [rowMorning, rowEvening],
      to: &balances, context: context, handlers: handlers)

    // Both rows applied on the same dayKey; total = 10 USD * 1.5 = 15.
    let value = try #require(balances[dayKey]?.investmentValue)
    #expect(value.quantity == try AnalysisTestHelpers.decimal("15"))
  }
```

- [ ] **Step 8: Add cases 10 and 11 (CSV transfer+trade, same-day BUY+SELL)**

Append:

```swift
  @Test("case 10: CSV-imported transfer cash leg + trade position leg both contribute")
  func csvImportedTransferPlusTrade() async throws {
    let day = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let dayKey = AnalysisTestHelpers.calendar.startOfDay(for: day)
    let usd = Instrument.fiat(code: "USD")
    let aud = Instrument.defaultTestInstrument
    let accountId = UUID()
    // .transfer cash leg in profile instrument (AUD) — Rule 8 fast path.
    let cashRow = GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: "2025-06-10", sampleDate: day,
      accountId: accountId, instrumentId: aud.id, type: "transfer", qty: 5000)
    // .trade position leg in USD.
    let tradeRow = GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: "2025-06-10", sampleDate: day,
      accountId: accountId, instrumentId: "USD", type: "trade", qty: 1000)
    let conversion = DateBasedFixedConversionService(
      rates: [
        try AnalysisTestHelpers.utcDate(year: 2025, month: 1, day: 1, hour: 0): [
          "USD": try AnalysisTestHelpers.decimal("1.5")
        ]
      ])
    var balances: [Date: DailyBalance] = [
      dayKey: GRDBDailyBalancesTradesModeTests.placeholderBalance(at: dayKey)
    ]
    let context = Self.makeContext(
      tradesIds: [accountId],
      instrumentMap: [aud.id: aud, "USD": usd],
      conversionService: conversion)
    let handlers = Self.makeHandlers { _, _ in }

    try await GRDBAnalysisRepository.applyTradesModePositionValuations(
      priorRows: [], postRows: [cashRow, tradeRow],
      to: &balances, context: context, handlers: handlers)

    // Cash 50 (AUD identity) + position 10 USD * 1.5 = 65.
    let value = try #require(balances[dayKey]?.investmentValue)
    #expect(value.quantity == try AnalysisTestHelpers.decimal("65"))
  }

  @Test("case 11: same-day BUY + SELL netting produces zero contribution")
  func sameDayBuyAndSellNetZero() async throws {
    let day = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let dayKey = AnalysisTestHelpers.calendar.startOfDay(for: day)
    let usd = Instrument.fiat(code: "USD")
    let accountId = UUID()
    let buy = GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: "2025-06-10", sampleDate: day,
      accountId: accountId, instrumentId: "USD", type: "trade", qty: 1000)
    let sell = GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: "2025-06-10", sampleDate: day,
      accountId: accountId, instrumentId: "USD", type: "trade", qty: -1000)
    let conversion = DateBasedFixedConversionService(
      rates: [
        try AnalysisTestHelpers.utcDate(year: 2025, month: 1, day: 1, hour: 0): [
          "USD": try AnalysisTestHelpers.decimal("1.5")
        ]
      ])
    var balances: [Date: DailyBalance] = [
      dayKey: GRDBDailyBalancesTradesModeTests.placeholderBalance(at: dayKey)
    ]
    let context = Self.makeContext(
      tradesIds: [accountId],
      instrumentMap: ["USD": usd],
      conversionService: conversion)
    let handlers = Self.makeHandlers { _, _ in }

    try await GRDBAnalysisRepository.applyTradesModePositionValuations(
      priorRows: [], postRows: [buy, sell],
      to: &balances, context: context, handlers: handlers)

    // Net position is 0; investmentValue ends up at 0 (zero added to
    // existing nil → .zero(instrument: AUD)).
    let value = try #require(balances[dayKey]?.investmentValue)
    #expect(value.quantity == 0)
  }
```

- [ ] **Step 9: Add case 12 (carry-forward across a dropped day)**

Append:

```swift
  @Test("case 12: carry-forward across a dropped day stays correct")
  func carryForwardAcrossDroppedDay() async throws {
    let dayOne = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let dayTwo = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 11, hour: 12)
    let keyOne = AnalysisTestHelpers.calendar.startOfDay(for: dayOne)
    let keyTwo = AnalysisTestHelpers.calendar.startOfDay(for: dayTwo)
    let usd = Instrument.fiat(code: "USD")
    let accountId = UUID()
    let rowOne = GRDBAnalysisRepository.DailyBalanceAccountRow(
      day: "2025-06-10", sampleDate: dayOne,
      accountId: accountId, instrumentId: "USD", type: "trade", qty: 1000)
    let conversion = DateBasedFixedConversionService(
      rates: [
        try AnalysisTestHelpers.utcDate(year: 2025, month: 1, day: 1, hour: 0): [
          "USD": try AnalysisTestHelpers.decimal("1.5")
        ]
      ])
    // Simulate a snapshot-fold dropout on day 1: dailyBalances has
    // entries only for day 2 (day 1 was removed by an earlier fold).
    var balances: [Date: DailyBalance] = [
      keyTwo: GRDBDailyBalancesTradesModeTests.placeholderBalance(at: keyTwo)
    ]
    let context = Self.makeContext(
      tradesIds: [accountId],
      instrumentMap: ["USD": usd],
      conversionService: conversion)
    let handlers = Self.makeHandlers { _, _ in }

    try await GRDBAnalysisRepository.applyTradesModePositionValuations(
      priorRows: [], postRows: [rowOne],
      to: &balances, context: context, handlers: handlers)

    // Day 2 must valuate the cumulative position from day 1's buy
    // even though day 1 itself isn't in dailyBalances.
    let value = try #require(balances[keyTwo]?.investmentValue)
    #expect(value.quantity == try AnalysisTestHelpers.decimal("15"))
  }
```

- [ ] **Step 10: Format and run the new suite**

```bash
just format
just test-mac GRDBDailyBalancesTradesModeTests 2>&1 | tee .agent-tmp/test.txt
grep -i "failed\|error:" .agent-tmp/test.txt
```

Expected: 12 tests pass.

- [ ] **Step 11: Run the entire daily-balance test surface to confirm nothing else regresses**

```bash
just test-mac GRDBDailyBalancesAssembleTests GRDBDailyBalancesConversionTests AnalysisRule11ScopingTests DailyBalancesPlanPinningTests GRDBDailyBalancesAggregateTradesModeTests GRDBDailyBalancesTradesModeTests 2>&1 | tee .agent-tmp/test.txt
grep -i "failed\|error:" .agent-tmp/test.txt
```

Expected: no failures.

- [ ] **Step 12: Commit**

```bash
git -C . add MoolahTests/Backends/GRDB/GRDBDailyBalancesTradesModeTests.swift
git -C . commit -m "test(grdb): trades-mode position-valuation fold contract tests"
```

---

## Task 8: Cross-cutting verification — build everything, run full mac suite, format-check

**Files:**
- None (verification only)

- [ ] **Step 1: Run `just format` to apply final formatting**

```bash
just format
```

- [ ] **Step 2: Run `just format-check` to confirm CI will pass**

```bash
just format-check 2>&1 | tee .agent-tmp/format-check.txt
echo "exit: $?"
```

Expected: exit code 0. If non-zero, inspect the file flagged by the
output and fix the formatting / SwiftLint issue without modifying
`.swiftlint-baseline.yml`.

- [ ] **Step 3: Run the full macOS test suite**

```bash
just test-mac 2>&1 | tee .agent-tmp/test-mac.txt
grep -i "failed\|error:" .agent-tmp/test-mac.txt
```

Expected: no failures. Investigate any failures by re-running the
specific class:

```bash
just test-mac <FailingClass> 2>&1 | tee .agent-tmp/test-fail.txt
```

- [ ] **Step 4: Run a build of the macOS app to surface any warnings-as-errors**

```bash
just build-mac 2>&1 | tee .agent-tmp/build.txt
grep -E "error:|warning:" .agent-tmp/build.txt | grep -v "Preview"
```

Expected: clean (Preview macro warnings are acceptable per CLAUDE.md;
all other warnings are errors per `SWIFT_TREAT_WARNINGS_AS_ERRORS:
YES`).

- [ ] **Step 5: Clean up `.agent-tmp/`**

```bash
rm -f .agent-tmp/build.txt .agent-tmp/test*.txt .agent-tmp/format-check.txt
```

---

## Task 9: Run review agents and apply findings

**Files:**
- None initially (review-driven; files modified per agent findings)

- [ ] **Step 1: Run the four relevant review agents in parallel**

Spawn `code-review`, `database-code-review`,
`instrument-conversion-review`, `concurrency-review` agents on the
working tree. Brief each on the task: "review the trades-mode
historical fold change against your guide; the design spec is
`plans/2026-05-04-trades-mode-historical-net-worth-design.md`."

- [ ] **Step 2: For each finding, apply the fix in the appropriate file**

Apply Critical and Important findings always. Apply Minor findings
unless deferred with explicit user authorisation. Each fix is a
separate commit, named for what it does (not "review feedback").

- [ ] **Step 3: Re-run reviewers after every batch of fixes**

Iterate until all four agents return clean.

- [ ] **Step 4: Re-run `just format-check` and `just test-mac` after the final
  fix batch**

```bash
just format-check
just test-mac 2>&1 | tee .agent-tmp/test-mac.txt
grep -i "failed\|error:" .agent-tmp/test-mac.txt
```

Expected: clean.

- [ ] **Step 5: Commit anything outstanding from the review pass**

(Each review fix should already be committed; this step is a
last-pass safety net.)

---

## Task 10: Open PR and queue

**Files:**
- None (PR-only)

- [ ] **Step 1: Push the branch with explicit `<src>:<dst>` form**

```bash
git -C . push origin trades-mode/historical-chart:trades-mode/historical-chart
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create \
  --base main \
  --head trades-mode/historical-chart \
  --title "feat(grdb): trades-mode historical net-worth fold + Rule 11 tighten" \
  --body "$(cat <<'EOF'
## Summary

- Adds a per-day "valued positions over time" fold for trades-mode
  investment accounts (`applyTradesModePositionValuations` in
  `Backends/GRDB/Repositories/GRDBAnalysisRepository+DailyBalancesInvestmentValues.swift`).
- Pre-filters trades-mode rows in `readDailyBalancesAggregation` so
  the fold takes purpose-built input.
- Tightens `applyInvestmentValues` to drop the day from
  `dailyBalances` on per-day conversion failure (Rule 11 alignment
  with `walkDays`); drops the vestigial `?` on `sumInvestmentValues`'s
  return type.

Fixes #738.

Design spec:
[plans/2026-05-04-trades-mode-historical-net-worth-design.md](https://github.com/ajsutton/moolah-native/blob/trades-mode/historical-chart/plans/2026-05-04-trades-mode-historical-net-worth-design.md).
Implementation plan:
[plans/2026-05-04-trades-mode-historical-net-worth-plan.md](https://github.com/ajsutton/moolah-native/blob/trades-mode/historical-chart/plans/2026-05-04-trades-mode-historical-net-worth-plan.md).

## Test plan

- [x] `just test-mac GRDBDailyBalancesTradesModeTests` — 12 fold-contract tests pass
- [x] `just test-mac GRDBDailyBalancesAggregateTradesModeTests` — 3 aggregation pins pass
- [x] `just test-mac GRDBDailyBalancesAssembleTests/snapshotFoldDropsDayOnFailure` — Rule 11 tightening pinned
- [x] `just test-mac DailyBalancesPlanPinningTests` — `account_by_type` plan pinned for the new fetch
- [x] `just test-mac` (full mac suite) — no regressions
- [x] `just format-check` — clean
- [x] `just build-mac` — clean

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 2: Add the PR to the merge queue**

Use the `merge-queue` skill to queue the PR:

```
/skill merge-queue add <PR_NUMBER>
```

(The PR number is in the `gh pr create` output; substitute it.)

- [ ] **Step 3: Verify the PR is in the queue**

```bash
~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh status
```

Expected: the PR appears in the queue.

---

## Self-Review

**Spec coverage:**

| Spec section | Implementing task |
|--------------|-------------------|
| §1 New SQL fetch | Task 1 |
| §2 Aggregation type with new fields | Task 2 + Task 3 |
| §3 Assembly context with trades-mode set | Task 2 |
| §4 New fold algorithm | Task 6 |
| §5 `sumTradesModePositions` helper | Task 6 |
| §5 `sumInvestmentValues` `?` cleanup | Task 5 |
| §6 Wire into `assembleDailyBalances` | Task 6 (step 2) |
| §6 `applyInvestmentValues` Rule 11 tighten | Task 5 |
| §7 Edge cases | Tasks 7 cases 1, 2, 3, 4, 6, 7, 10, 11, 12 |
| §8 Plan-pinning | Task 1 |
| §9.1 Plan-pinning | Task 1 |
| §9.2 Aggregation-layer | Task 4 |
| §9.3 Fold-contract cases 1–12 | Task 7 (cases 1, 2, 3, 4, 6, 7, 8, 9, 10, 11, 12) and Task 5 (case 5) |
| §10 Two-catch shape | Task 6 (literal sketch in fold body) + Task 5 (literal sketch in `applyInvestmentValues`) |
| §11 Logging / `Calendar.current` | Task 6 (no new logger; reuses handler) |
| §12 Performance | Implicitly verified via `just test-mac` (no regressions) |
| §13 File-size budget | Task 8 (`just format-check`) |

No spec section is unimplemented.

**Type / signature consistency:**

- `TradesModePositionEntry` is defined once in Task 6 step 1 and used
  there only.
- `applyTradesModePositionValuations(priorRows:postRows:to:context:handlers:)`
  signature is identical at the definition (Task 6 step 1) and at the
  call site (Task 6 step 2).
- `sumTradesModePositions(positions:on:profileInstrument:conversionService:)`
  signature is identical at definition and call site (Task 6 step 1).
- `fetchTradesModeInvestmentAccountIds(database:)` is identical at
  definition (Task 1 step 3) and call site (Task 3 step 1).
- `tradesModeInvestmentAccountIds: Set<UUID>` is the field name on
  both `DailyBalancesAggregation` (Task 2 step 1) and
  `DailyBalancesAssemblyContext` (Task 2 step 2), and is referenced
  by that exact name in Task 3 step 1, Task 6 step 2, and the test
  helpers in Task 7 step 1.
- `priorTradesModeAccountRows` / `tradesModeAccountRows` field names
  are stable across Task 2, Task 3, Task 4, and Task 6.

No signature drift.

**Placeholder scan:**

No "TBD", "TODO", "implement later", "fill in details", or "Similar
to Task N" without inline code. Every step shows the exact code or
exact command. Caveat: Task 9 (review-driven) describes the iteration
loop without prescribing specific findings — that's appropriate
because the findings depend on what the reviewers say. Task 10
prescribes the PR body verbatim.
