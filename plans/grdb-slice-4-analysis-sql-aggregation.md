# Slice 4 — `AnalysisRepository` SQL Aggregation Rewrite (detailed plan)

**Status:** Not started.
**Roadmap context:** `plans/grdb-migration.md` §6 → Slice 4 (deferred
from Slice 1).
**Branch:** `perf/grdb-analysis-sql-aggregates` (not yet created).
**Parent branch:** `main`. Independent of Slice 3 — can ship before,
after, or in parallel.

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan task-by-task.

---

## 1. Goal

Push the per-instrument `GROUP BY` aggregation into SQL for the four
hot `AnalysisRepository` methods that today still walk every leg in
Swift. Slice 1 shipped the GRDB-backed analysis repo but **did not**
rewrite these methods — it reused the SwiftData-era static compute
helpers verbatim. This slice cashes in the headline speedup that the
covering indexes laid down in Slice 1's `v3_core_financial_graph`
schema were sized for.

The slice ships:

- A SQL-aggregating rewrite for each of the four hot
  `AnalysisRepository` protocol methods:
  - `fetchDailyBalances(after:forecastUntil:)`
  - `fetchExpenseBreakdown(monthEnd:after:)`
  - `fetchIncomeAndExpense(monthEnd:after:)`
  - `fetchCategoryBalances(dateRange:transactionType:filters:targetInstrument:)`
- Per-day grouping (`DATE(t.date) AS day`) so per-leg conversion
  semantics under `INSTRUMENT_CONVERSION_GUIDE.md` Rule 5 are
  preserved exactly. (See `plans/grdb-slice-1-core-financial-graph.md`
  §3.4 introduction for the rate-cache day-granularity argument; the
  argument and its conclusion carry over verbatim.)
- Plan-pinning tests asserting `SEARCH … USING (COVERING) INDEX …`
  against the `leg_analysis_*` covering indexes that already exist in
  the v3 schema.
- Benchmark deltas in the PR description meeting the original Slice 1
  §3.9 targets:
  - `testFetchCategoryBalances` ≥ 5× speedup
  - `testFetchCategoryBalancesByType` ≥ 5× speedup
  - `testLoadAll_12months` ≥ 3× speedup
  - `testLoadAll_allHistory` ≥ 5× speedup
- Date-sensitive conversion regression tests using a
  `DateBasedFixedConversionService` fixture so the per-day grouping
  invariant is pinned.

The slice does **not** ship:

- Schema or index changes — the covering indexes
  (`leg_analysis_by_type_account`, `leg_analysis_by_type_category`,
  `leg_analysis_by_earmark_type`, `iv_by_account_date_value`) were
  laid down by `v3_core_financial_graph`. Slice 4 only changes
  Swift code.
- SQL-side currency conversion. Multi-step conversion (stock → fiat →
  fiat → target) stays a Swift pipeline. The SQL emits per-instrument
  SUMs; Swift converts each `(day, instrument)` tuple via the existing
  `convertedAmount` helper.
- Forecast extrapolation — stays Swift-side. SQL can't extrapolate
  recurring patterns from `recur_period IS NOT NULL` rows; the
  scheduled-transaction loop continues unchanged. Only the
  *historic* span moves to SQL.
- Removal of the `CloudKitAnalysisCompute` namespace. After Slice 4 it
  will be substantially smaller (the four methods no longer call into
  it for the GROUP BY path), but `+Forecast.swift` and
  `+Conversion.swift` keep their bodies; `+IncomeExpense.swift` and
  `+DailyBalances.swift` shrink to the post-SQL Swift assembly. Slice
  3 Phase B handles the file relocation; Slice 4 lives wherever Slice
  3 left it.

---

## 2. What's already in place from Slice 1 (don't change)

| Asset | File / Identifier | Notes |
|---|---|---|
| Covering indexes for the four hot paths | `Backends/GRDB/ProfileSchema+CoreFinancialGraph.swift` | `leg_analysis_by_type_account`, `leg_analysis_by_type_category`, `leg_analysis_by_earmark_type`, `iv_by_account_date_value` already exist. **Don't add new indexes.** |
| `GRDBAnalysisRepository` skeleton | `Backends/GRDB/Repositories/GRDBAnalysisRepository.swift` | The four protocol methods currently delegate to `CloudKitAnalysisRepository.compute<X>` static helpers. Slice 4 replaces those delegations with SQL queries inline. |
| Domain types | `Domain/Repositories/AnalysisRepository.swift`, `Domain/Models/{ExpenseBreakdown,DailyBalance,MonthlyIncomeExpense}.swift` | Public types unchanged. |
| Plan-pinning test harness | `MoolahTests/Backends/GRDB/AnalysisPlanPinningTests.swift` | Existing tests cover `computePositions`. Slice 4 adds tests for the four analysis-method shapes. |
| Conversion test fixtures | `MoolahTests/Backends/GRDB/GRDBAnalysisConversionTests.swift` (or wherever Slice 1 placed them) | Verify presence; if absent, add them as part of Slice 4. |
| Benchmark cases | `MoolahBenchmarks/AnalysisBenchmarks.swift` | `testFetchCategoryBalances`, `testFetchCategoryBalancesByType`, `testLoadAll_12months`, `testLoadAll_allHistory`. Already wired; Slice 4 just runs them pre/post and pastes the deltas into the PR body. |

---

## 3. What's left

### 3.1 `fetchExpenseBreakdown(monthEnd:after:)`

Today `GRDBAnalysisRepository.fetchExpenseBreakdown` calls
`CloudKitAnalysisCompute.computeExpenseBreakdown(nonScheduled:monthEnd:after:context:)`,
which loops every leg, converts per-leg via `convertedAmount`, and
buckets into `[financialMonth: [categoryId: InstrumentAmount]]`. After:

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
GROUP BY day, leg.category_id, leg.instrument_id
ORDER BY day ASC, leg.category_id ASC;
```

Bind `after` as `Date?` via GRDB's `StatementArguments`; for the
`NULL` case use `NSNull()`-equivalent through GRDB's `:after`
parameterisation (verify the project's existing pattern — see
`GRDBTransactionRepository+Fetch.swift` for the date-range filter
shape).

Swift assembly:

```swift
struct CategoryDayInstrumentRow: Decodable, FetchableRecord {
  let day: Date         // ISO-8601 day; GRDB decodes via DateAdapter
  let categoryId: UUID
  let instrumentId: String
  let qty: Int64
}

func fetchExpenseBreakdown(
  monthEnd: Int, after: Date?
) async throws -> [ExpenseBreakdown] {
  let rows = try await database.read { database in
    try CategoryDayInstrumentRow.fetchAll(
      database,
      sql: expenseBreakdownSQL,
      arguments: [after])
  }
  // Bucket into [financialMonth: [categoryId: InstrumentAmount]],
  // converting each (day, instrument) tuple on `day`.
  var buckets: [Date: [UUID: InstrumentAmount]] = [:]
  let instruments = try await fetchInstruments()
  for row in rows {
    let day = row.day  // already a Date
    let instrument = instruments[row.instrumentId]
      ?? Instrument.fiat(code: row.instrumentId)
    let dayAmount = InstrumentAmount(storageValue: row.qty, instrument: instrument)
    let converted = try await conversionService.convertedAmount(
      dayAmount, to: self.instrument, on: day)
    let month = financialMonth(for: day, monthEnd: monthEnd)
    buckets[month, default: [:]][row.categoryId, default: .zero(instrument: self.instrument)] += converted
  }
  return buckets.flatMap { (month, byCategory) in
    byCategory.map { (categoryId, total) in
      ExpenseBreakdown(categoryId: categoryId, month: month, totalExpenses: total)
    }
  }.sorted { ($0.month, $0.categoryId.uuidString) < ($1.month, $1.categoryId.uuidString) }
}
```

Reuse the existing `financialMonth(for:monthEnd:)` helper (lives in
`+Conversion.swift` after Slice 3 Phase B; before that, it's in the
CloudKit-side file). **Do not duplicate** it.

**Indexes used:** `leg_analysis_by_type_category` (covering — partial
WHERE `category_id IS NOT NULL` matches the predicate).
`transaction_by_date` for the optional `after` range bound.

**Plan-pinning test:** `SEARCH leg USING COVERING INDEX
leg_analysis_by_type_category`. Reject `SCAN transaction_leg`.

**Conversion site:** Swift, on each row's `day` (Rule 5).
**`@instrument-conversion-review` agent must approve.**

### 3.2 `fetchIncomeAndExpense(monthEnd:after:)`

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
GROUP BY day, leg.instrument_id
ORDER BY day ASC;
```

The five conditional sums are the exact predicates from the existing
Swift implementation (`+IncomeExpense.swift:142–157`). The
`'trade'` and `'openingBalance'` types are correctly excluded by all
five branches — none of the CASE conditions match either string.

Swift assembly:

1. Convert each `(day, instrument)` row's five sums to
   `targetInstrument` on `day`.
2. Bucket by `financialMonth(day, monthEnd)`.
3. For each non-empty month, compose the `MonthlyIncomeExpense`. The
   investment-transfer column folds into `earmarkedIncome` /
   `earmarkedExpense` per the sign rules in the existing helper —
   **preserve the exact sign-flip pattern**.
4. `profit = income + expense`, `earmarkedProfit = earmarkedIncome +
   earmarkedExpense` (signed amounts; expenses are negative).

**Indexes used:** `leg_analysis_by_type_account` (covering),
`account_by_type` (LEFT JOIN equality probe), `transaction_by_date`
(filter).

**Plan-pinning test:** `SEARCH leg USING COVERING INDEX
leg_analysis_by_type_account`, `SEARCH a USING INDEX account_by_type`
(or INTEGER PRIMARY KEY on the FK lookup). Reject `SCAN`.

**Conversion site:** Swift, on each row's `day`.

### 3.3 `fetchDailyBalances(after:forecastUntil:)`

Two-query approach (Slice 1 plan §3.4.1):

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

Swift assembly (mirrors Slice 1 plan §3.4.1):

1. Build per-day position deltas (one row per
   `(day, account, instrument, type)`).
2. Walk days in order; apply deltas to a `PositionBook` keyed by
   `(account, instrument)`.
3. At each day, call `PositionBook.dailyBalance(on: day, …)` — the
   existing helper that converts each per-instrument total to the
   profile instrument on `transaction.date`.
4. Forecast extrapolation runs after the historic span; each
   scheduled transaction is expanded into instances and applied to
   the same `PositionBook`. **Forecast stays Swift-only.**
5. Best-fit linear regression stays Swift; SQL provides the sorted
   balances.

**Indexes used:** `transaction_by_date` (range scan),
`leg_by_transaction` (join), `leg_analysis_by_type_account` (covering),
`iv_by_account_date_value` (covering).

**Plan-pinning tests:** one per query. Assert `SEARCH "transaction"
USING INDEX transaction_by_date`, `SEARCH leg USING COVERING INDEX
leg_analysis_by_type_account`, `SEARCH iv USING COVERING INDEX
iv_by_account_date_value`. Reject `SCAN`.

**Conversion site:** Swift, post-SQL, on `transaction.date` for
historic and `Date()` for forecast (Rule 5 / Rule 6).

### 3.4 `fetchCategoryBalances(dateRange:transactionType:filters:targetInstrument:)`

The largest of the four — composes optional `(accountId, payee,
earmarkId, categoryIds)` filters. **Use the GRDB query interface, not
raw SQL, for the `categoryIds` predicate** because SQLite cannot bind
a variable-length array to a single named parameter. See Slice 1 plan
§3.4.4 for the composition pattern; copy it verbatim.

Swift assembly:

1. For each `(day, category, instrument, qty)` row, convert
   `(qty, instrument)` to `targetInstrument` on `day`.
2. Accumulate the converted amount into `balances[categoryId,
   default: .zero(instrument: targetInstrument)] += converted`.
3. Emit the resulting `[UUID: InstrumentAmount]`.

**Investment-account exclusion check:** the existing implementation
**excludes legs from investment accounts** via
`applyByType(...).skip(when: classified.isInvestmentAccount)`. The
SQL must mirror this with a `LEFT JOIN account a` and
`(a.type IS NULL OR a.type <> 'investment')` filter. The boolean
precedence accepts genuinely account-less legs (which today's Swift
code also includes via `accountId == nil → isInvestmentAccount =
false`).

**Indexes used:** `leg_analysis_by_type_category` (covering),
`transaction_by_date`, `account_by_type`, `leg_by_account` /
`leg_by_earmark` partials for optional filters.

**Plan-pinning test:** `SEARCH leg USING COVERING INDEX
leg_analysis_by_type_category`. With `accountId` filter set,
additionally check `leg_by_account` is consulted. Reject `SCAN`.

### 3.5 `fetchCategoryBalancesByType(dateRange:filters:targetInstrument:)`

Default protocol implementation runs `fetchCategoryBalances` twice in
parallel via `async let`. Slice 4 keeps the default — no override
needed; the per-call SQL is now <2 ms against the covering index, so
the two-call default is acceptable. (Slice 1 plan §3.4.5 reached the
same conclusion.)

### 3.6 `loadAll(historyAfter:forecastUntil:monthEnd:)`

Default protocol implementation runs the three methods concurrently
via `async let`. Slice 4 keeps this intact; the per-method SQL above
already minimises shared-data fetches. **Override** in
`GRDBAnalysisRepository` only if benchmarks show a single-fetch payoff
(unlikely given the now-fast SQL).

### 3.7 Sidebar account balances

Already SQL-aggregating in
`GRDBAccountRepository+Positions.computePositions(database:instruments:)`
(Slice 1 §3.4.7). **No change** in Slice 4.

### 3.8 Tests

Mandatory:

- **Plan-pinning tests** — extend
  `MoolahTests/Backends/GRDB/AnalysisPlanPinningTests.swift` with the
  four shapes above. Each test opens a fresh in-memory
  `ProfileDatabase`, runs `EXPLAIN QUERY PLAN` over the SQL, asserts
  the expected `USING (COVERING) INDEX <name>` line and rejects
  `SCAN <table>` and `USE TEMP B-TREE FOR ORDER BY`.
- **Date-sensitive conversion tests** — extend
  `MoolahTests/Backends/GRDB/GRDBAnalysisConversionTests.swift` with
  fixtures using a `DateBasedFixedConversionService` (a stub that
  returns a *different* rate per calendar day). Construct fixtures
  with legs spanning at least two calendar days with rates that
  differ; assert the per-day-grouped SQL + Swift assembly produces
  the correct day-keyed conversion. Without this, a regression
  collapsing the SQL grouping to per-month or per-range would silently
  pass against constant-rate fixtures. Apply to all four methods.
- **Numerical-equivalence tests** — for each of the four methods,
  seed a multi-instrument fixture (mix of fiat A, fiat B, stock C)
  and assert the SQL-aggregating path produces the same
  `InstrumentAmount` totals as the pre-Slice-4 Swift loop on the same
  fixture. Run the pre-Slice-4 path by checking out main / tagging
  the fixture's expected output as a constant in the test file.
  Pattern: snapshot-style. (The contract test in
  `MoolahTests/Domain/AnalysisRepositoryContractTests.swift` already
  exercises the analysis API; Slice 4's job is to keep those tests
  green with no expected-value updates.)
- **Benchmark deltas** — run
  `MoolahBenchmarks/AnalysisBenchmarks.swift` on `main` and on the
  branch. Capture in `.agent-tmp/benchmark-pre.txt` and
  `.agent-tmp/benchmark-post.txt`; paraphrase into the PR description.
  - Targets per §1: 5×/5×/3×/5× for the four cases.
  - Acceptance: a < 3× speedup on the 12-month case is a
    slice-blocking regression — re-verify the plan-pinning tests; the
    SQL is missing an index it needs.

### 3.9 Notes on `CloudKitAnalysisCompute` after Slice 4

Slice 4 collapses the four methods' delegation to
`CloudKitAnalysisCompute.compute<X>(...)` static helpers. The static
helpers shrink:

- `+IncomeExpense.swift` — `computeExpenseBreakdown` and
  `computeIncomeAndExpense` lose their per-leg loop bodies and become
  thin Swift assembly post-SQL helpers (the
  `financialMonth(...)` bucketer + the conversion call). Some of the
  infrastructure types (`MonthData`-shaped accumulator) may be
  inlined; verify which still have callers.
- `+DailyBalances.swift` — `computeDailyBalances` similarly shrinks.
  `PositionBook` walking stays, scheduled-transaction extrapolation
  stays.
- `+Conversion.swift` — `convertedAmount(_:to:on:conversionService:)`
  helper stays unchanged; the Swift assembly post-SQL calls it
  per `(day, instrument)` row.
- `+Forecast.swift` — unchanged. Forecast is purely Swift.
- `CloudKitAnalysisCompute` (or whatever name Slice 3 Phase B picked
  for the namespace) — stays in the codebase. Slice 4 doesn't delete
  it.

The `CategoryBalancesQuery` nested struct in `GRDBAnalysisRepository`
(today a Swift filter+accumulate) becomes redundant — the SQL handles
the filtering. Delete it as part of Slice 4. Any tests that exercise
the nested struct directly (none expected) move to exercise the
public protocol method.

---

## 4. File-level inventory of edits

| File | Action |
|---|---|
| `Backends/GRDB/Repositories/GRDBAnalysisRepository.swift` | EDIT — replace four method bodies with SQL queries; drop `CategoryBalancesQuery` nested struct |
| `Backends/GRDB/Repositories/GRDBAnalysisRepository+Conversion.swift` | EDIT — `financialMonth(for:monthEnd:)` becomes a free function or static helper, accessible from the new SQL-driven Swift assembly. (After Slice 3 Phase B this file lives under `Backends/GRDB/`; before Phase B it's `Backends/CloudKit/`.) |
| `Backends/GRDB/Repositories/GRDBAnalysisRepository+IncomeExpense.swift` (or the CloudKit-side equivalent if Slice 3 hasn't landed) | EDIT — shrink `computeExpenseBreakdown` / `computeIncomeAndExpense` bodies; the SQL caller drives the post-SQL Swift assembly |
| `Backends/GRDB/Repositories/GRDBAnalysisRepository+DailyBalances.swift` | EDIT — shrink `computeDailyBalances` body |
| `MoolahTests/Backends/GRDB/AnalysisPlanPinningTests.swift` | EDIT — add 4 plan-pinning tests for the four method shapes |
| `MoolahTests/Backends/GRDB/GRDBAnalysisConversionTests.swift` (NEW or EDIT) | EDIT or NEW — date-sensitive conversion fixtures |
| `MoolahBenchmarks/AnalysisBenchmarks.swift` | NO EDIT — bodies unchanged; just run pre/post |

No schema edits. No new files.

---

## 5. Acceptance criteria

- `just build-mac` ✅ and `just build-ios` ✅.
- `just format-check` clean.
- `just test` passes.
- Plan-pinning tests reject `SCAN <table>` and `USE TEMP B-TREE FOR
  ORDER BY` for the four method shapes.
- Date-sensitive conversion tests pass — per-day grouping is preserved.
- Numerical-equivalence tests pass — SQL-aggregating output matches
  the pre-Slice-4 Swift output bit-for-bit on multi-instrument
  fixtures.
- Benchmark deltas meet targets (5×/5×/3×/5× per §1).
- Pre/post benchmark numbers in PR description.
- All five reviewer agents (`database-schema-review`,
  `database-code-review`, `concurrency-review`, `code-review`,
  `instrument-conversion-review`) report clean, or any findings
  addressed before queueing.

---

## 6. Workflow constraints

Same as Slices 1 / 3:

- **Branch.** `perf/grdb-analysis-sql-aggregates` off `main`.
- **No `.swiftlint-baseline.yml` modification.**
- **No cosmetic compensating shrinks** to fit baseline counts.
- **Plan-pinning evidence** in test assertions, not the PR body.
- **All git/just commands use absolute paths.**
- **`.agent-tmp/` for any temp files.**
- **Patterns from Slice 0 / 1 apply** (no `Column("…")` raw strings;
  Swift Testing not XCTest; `final class` + `@unchecked Sendable`).
- **`Date()` only at boundaries** — the conversion calls take an
  explicit `on:` date parameter; no `Date()` constructed inside the
  repo.

---

## 7. Reference reading

### Slice plans
- `plans/grdb-migration.md` — overall roadmap.
- `plans/grdb-slice-1-core-financial-graph.md` §3.4 — the original
  SQL design for the four methods. **Read this section carefully**; it
  contains the per-method SQL, Swift assembly, conversion-date
  argument, and index decisions that Slice 4 implements.

### Guides (non-optional)
- `guides/DATABASE_CODE_GUIDE.md` §6 — plan-pinning test pattern.
- `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rules 1, 5, 6, 7 — when
  which date is passed to the conversion call.
- `guides/BENCHMARKING_GUIDE.md` — pre/post measurement protocol.

### Implementation reference
- `Backends/GRDB/Repositories/GRDBAccountRepository+Positions.swift` —
  reference for SQL `GROUP BY` aggregation against the
  `transaction_leg` table. The shape Slice 4 reproduces for each
  method.
- `Backends/GRDB/Repositories/GRDBAnalysisRepository.swift` (current)
  — the call sites Slice 4 is rewriting.
- `Backends/CloudKit/Repositories/CloudKitAnalysisRepository*.swift`
  (or Slice-3-Phase-B's renamed equivalents) — the Swift compute
  helpers Slice 4 thins out.

---

## 8. Open questions

| Q | Resolution before code |
|---|---|
| Should Slice 4 ship before or after Slice 3 Phase B? | **Either order.** Slice 4 doesn't depend on the SwiftData teardown. Recommended order: Slice 3 Phase A → Slice 4 → Slice 3 Phase B (so Slice 4's SQL rewrite lands when the helper files still live in the CloudKit folder, then Phase B moves them to GRDB). Pragmatically interchangeable. |
| Will the SQL `DATE(t.date)` projection round to UTC or local? | SQLite's `DATE(...)` strips the time component using the stored ISO-8601 string. Project's `transaction.date` is stored in UTC ISO-8601; `DATE()` returns the UTC calendar day. The conversion service caches by ISO-8601 day string formatted with `[.withFullDate]`, also UTC. **Match.** Verify during implementation that the existing Swift `transaction.date` writers don't apply local-calendar conversion — if they do, Slice 4 must mirror it (e.g. via `strftime('%Y-%m-%d', t.date, 'localtime')`). |
| Can `fetchCategoryBalances`'s `categoryIds` filter use raw SQL with bound array? | **No** — SQLite cannot bind a list to a single named parameter. Use the GRDB query interface's `Sequence.contains(Column…)` operator (Slice 1 plan §3.4.4 has the working shape). |
| Should the SQL emit per-leg or per-day rows? | **Per-day grouping.** See Slice 1 plan §3.4 introduction for the rate-cache day-granularity argument. Per-leg multiplies conversion calls without changing the answer; per-month would change rates and break Rule 5. |
| What if the Swift assembly post-SQL ends up as expensive as the loop it replaces? | Profile during implementation. The expected win comes from two places: (a) SQL aggregation is O(N) with a covering index where Swift was O(N) loading-then-aggregating, and (b) per-day conversion calls are reduced ~5× (typical 1–5 same-day same-category legs). If the post-SQL Swift assembly walks the rows naively it will still be a loop — but a smaller one. Benchmarks will tell. |
| Is there a path to push currency conversion into SQL? | **Deferred indefinitely** per `plans/grdb-migration.md` §2 ("Conversion service shape … Multi-step conversion paths stay in Swift; SQL conversion is deferred indefinitely"). Slice 4 does not change this. Single-step SQL conversion via a per-rate join is technically feasible but blocked by multi-step paths (stock → fiat → fiat → target) that the per-instrument conversion service handles in Swift. |

---

*End of plan. Implementer: read Slice 1 plan §3.4 line by line before
writing the first SQL query — that section is the spec; Slice 4 just
implements it.*
