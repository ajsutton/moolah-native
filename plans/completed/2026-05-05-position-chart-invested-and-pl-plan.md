# Position-Tracked Chart: Invested Amount and Profit/Loss — Implementation Plan

> **Status:** Round 2 (post-review revisions to round-1 reviewer findings).
>
> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a cumulative-contributions baseline + green/red gain/loss
shading to the per-account position-tracked investment chart, and an
"Invested $X" subtitle on the Current Value tile. Per-instrument view
gains the same gain/loss shading using cost basis as the baseline.

**Architecture:** Extract a shared `AccountCashFlows.flowAmounts(for:)`
namespace function so the existing `AccountPerformanceCalculator` and
the new contribution-tracking inside `PositionsHistoryBuilder` share one
source of truth for the boundary-crossing flow predicate (same on-date
conversion via `InstrumentConversionService`). Extend
`HistoricalValueSeries.Point` with a `contributions: Decimal?` field
populated only on aggregate points; per-instrument points leave it
`nil`. `PositionsChart` switches both modes to a unified render path
(value line + baseline step line + stacked green/red `AreaMark` pair
between them) parameterised by the baseline keypath. `Account
PerformanceTiles.currentValueTile` gains an `Invested $X` subtitle
sourced from `AccountPerformance.totalContributions` with explicit
unavailable / no-flows branches.

**Tech Stack:** Swift 6.2 (`@concurrent`, `nonisolated`), Swift Charts
(`AreaMark` / `LineMark`), Swift Testing (`@Test` / `#expect`),
`os.Logger`, `swift-format`, SwiftLint, `xcodegen`. Build / test via
`just`. Reference spec: [`plans/2026-05-05-position-chart-invested-and-pl-design.md`](2026-05-05-position-chart-invested-and-pl-design.md).

---

## File Map

**Production (create / modify):**

- `Shared/AccountCashFlows.swift` — **new file.** Caseless `enum`
  with one `nonisolated static func flowAmounts(for:accountId:host
  Currency:service:)` that returns `[Decimal]` (one entry per
  qualifying leg in `transaction.legs` order). Contains the
  boundary-crossing predicate used by both calculator and builder.
- `Shared/AccountPerformanceCalculator.swift` — **modify.** Replace
  the body of `extractFlows` so it iterates transactions, calls
  `AccountCashFlows.flowAmounts(for:)` once per transaction, and
  flat-maps the returned `[Decimal]` into `[CashFlow]` records using
  `transaction.date`. Behaviour-preserving refactor.
- `Domain/Models/HistoricalValueSeries.swift` — **modify.** Extend
  `Point` with `let contributions: Decimal?`. Update
  `Point` initialiser callers' source of truth (only one — the
  builder).
- `Shared/PositionsHistoryBuilder.swift` — **modify.** Add
  `contributions: Decimal?` to `BuildState`. Add the contribution
  fold to `apply(transaction:…)` (calling
  `AccountCashFlows.flowAmounts(for:)`). Pre-fold path inherits via
  the shared `apply` call. Per-instrument emission passes
  `contributions: nil`. Aggregate emission passes
  `state.contributions`.
- `Shared/Views/Positions/PositionsChart.swift` — **modify.** Drop
  the solid blue area fill. Replace the cost-basis-only render
  branch with a unified renderer that takes a per-point baseline
  (`contributions` for aggregate, `cost` for per-instrument) and
  emits stacked `AreaMark` (gain / loss) plus the dashed step line.
  Update legend to a three-entry list with a two-tone Profit/Loss
  swatch and accessibility labels per the spec §3.
- `Shared/Views/Positions/AccountPerformanceTiles.swift` —
  **modify.** Switch `currentValueTile` to the subtitle-bearing
  `Tile` init. Add `investedSubtitle` view-builder. Extend
  `currentValueAccessibilityLabel(_:)` to speak both fields per
  the spec §4. Logic lives in a new view-layer
  `AccountPerformanceTileLabels` namespace (NOT on the domain
  type — see Task 6).

**Tests (create / modify):**

- `MoolahTests/Shared/AccountCashFlowsTests.swift` — **new file.**
  TDD entry point for the helper. Covers the seven contract cases
  enumerated in spec §Tests.
- `MoolahTests/Shared/AccountPerformanceCalculatorTests.swift` —
  **modify.** Add one regression test asserting the per-leg
  `CashFlow` order is preserved across the refactor.
- `MoolahTests/Domain/HistoricalValueSeriesTests.swift` —
  **modify.** Add a single round-trip case verifying
  `contributions` is reachable on a `Point` and participates in
  `Hashable` / `Sendable` conformances.
- `MoolahTests/Shared/PositionsHistoryBuilderTests.swift` —
  **modify.** Add the eight contribution-tracking cases listed in
  spec §Tests. Reuse the existing fixture infrastructure
  (`accountId`, `aud`, `bhp`, `date(daysAfterEpoch:)`,
  `FixedConversionService`, `DateBasedFixedConversionService`).
- `MoolahTests/Shared/PositionsChartDataTests.swift` —
  **new file.** Data-shape assertions per spec §Tests "Chart"
  bullets — baseline selection, nil-transition, most-recent-point
  legend signal. The test target is the data-extraction helper that
  Task 5 introduces (no SwiftUI snapshots).
- `MoolahTests/Shared/AccountPerformanceTileLabelsTests.swift` —
  **new file.** Covers the four optionality combinations + the
  four accessibility-label combinations enumerated in spec
  §Tests.

**Docs (modify after merge — not in this plan):**

- `plans/2026-05-05-position-chart-invested-and-pl-design.md` →
  `plans/completed/...` after PR lands.
- `plans/2026-05-05-position-chart-invested-and-pl-plan.md` →
  `plans/completed/...` after PR lands.

---

## Build Commands (Reference)

| When you need to | Command |
|---|---|
| Run all tests on macOS | `just test-mac 2>&1 \| tee .agent-tmp/test.txt` |
| Run a subset (one suite) | `just test-mac AccountCashFlowsTests 2>&1 \| tee .agent-tmp/test.txt` |
| Run all tests both platforms | `just test` |
| Format Swift files | `just format` |
| Verify formatting (CI parity) | `just format-check` |
| Build the macOS app | `just build-mac` |
| Build the iOS app | `just build-ios` |
| Regenerate `Moolah.xcodeproj` | `just generate` (only if `project.yml` changes) |

`mkdir -p .agent-tmp` before piping output.

---

## Task 1: Extract `AccountCashFlows.flowAmounts(for:)`

**Files:**
- Create: `Shared/AccountCashFlows.swift`
- Create: `MoolahTests/Shared/AccountCashFlowsTests.swift`
- Modify: `project.yml` (only if a new top-level Sources subfolder is needed — it is not; `Shared/` is already a tracked Sources path).

- [ ] **Step 1.1: Create the test file with the seven contract cases as `@Test` stubs that fail to compile (helper does not exist yet).**

Create `MoolahTests/Shared/AccountCashFlowsTests.swift` with:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("AccountCashFlows.flowAmounts(for:)")
struct AccountCashFlowsTests {
  let aud = Instrument.AUD
  let usd = Instrument.USD
  let accountId = UUID()
  let otherAccountId = UUID()

  /// Day 0 = 2026-03-15.
  private func date(daysAfterEpoch days: Int, hour: Int = 0) -> Date {
    var components = DateComponents()
    components.year = 2026
    components.month = 3
    components.day = 15 + days
    components.hour = hour
    return Calendar(identifier: .gregorian).date(from: components)!
  }

  // MARK: - Opening balance leg counts as a flow

  @Test("openingBalance leg in host currency returns one amount equal to the leg quantity")
  func openingBalanceHostCurrencyLeg() async throws {
    let txn = Transaction(
      date: date(daysAfterEpoch: 0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 1_000, type: .openingBalance
        )
      ]
    )
    let service = FixedConversionService(rates: [:])
    let amounts = try await AccountCashFlows.flowAmounts(
      for: txn, accountId: accountId, hostCurrency: aud, service: service
    )
    #expect(amounts == [1_000])
  }

  @Test("openingBalance leg in foreign currency converts on transaction.date")
  func openingBalanceForeignCurrencyLegUsesTxnDate() async throws {
    // Two distinct rates on different days — locks in the date choice.
    let day0 = date(daysAfterEpoch: 0)
    let day10 = date(daysAfterEpoch: 10)
    let service = DateBasedFixedConversionService(rates: [
      day0: [usd.id: Decimal(string: "1.50")!],
      day10: [usd.id: Decimal(string: "1.40")!],
    ])
    let txn = Transaction(
      date: date(daysAfterEpoch: 0, hour: 14),  // non-zero clock time
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: usd, quantity: 100, type: .openingBalance
        )
      ]
    )
    let amounts = try await AccountCashFlows.flowAmounts(
      for: txn, accountId: accountId, hostCurrency: aud, service: service
    )
    #expect(amounts == [Decimal(150)])  // 100 × 1.50, the day-0 rate
  }

  // MARK: - Boundary-crossing transactions

  @Test("boundary-crossing host-currency leg returns the leg quantity (Rule 8 fast path)")
  func boundaryCrossingHostCurrencyLegFastPath() async throws {
    // ThrowingCountingConversionService.calls counts every convert(...) call;
    // the helper hits the fast path for host-currency legs and never calls
    // through, so .calls must remain zero. The outcome closure returning
    // .success(0) is intentionally wrong-shaped — if the fast path regresses
    // and convert(...) is invoked, the assertion `amounts == [250]` will
    // fail (amounts would be `[0]`), pinpointing the regression.
    let counter = ThrowingCountingConversionService(
      outcome: { _ in .success(0) }
    )
    let txn = Transaction(
      date: date(daysAfterEpoch: 1),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 250, type: .income
        ),
        TransactionLeg(
          accountId: otherAccountId, instrument: aud, quantity: -250, type: .expense
        ),
      ]
    )
    let amounts = try await AccountCashFlows.flowAmounts(
      for: txn, accountId: accountId, hostCurrency: aud, service: counter
    )
    #expect(amounts == [250])
    #expect(counter.calls == 0)
  }

  @Test("boundary-crossing foreign-currency leg converts on transaction.date")
  func boundaryCrossingForeignCurrencyLeg() async throws {
    let day0 = date(daysAfterEpoch: 0)
    let day5 = date(daysAfterEpoch: 5)
    let service = DateBasedFixedConversionService(rates: [
      day0: [usd.id: Decimal(string: "1.50")!],
      day5: [usd.id: Decimal(string: "1.40")!],
    ])
    let txn = Transaction(
      date: date(daysAfterEpoch: 0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: usd, quantity: 100, type: .income
        ),
        TransactionLeg(
          accountId: otherAccountId, instrument: usd, quantity: -100, type: .expense
        ),
      ]
    )
    let amounts = try await AccountCashFlows.flowAmounts(
      for: txn, accountId: accountId, hostCurrency: aud, service: service
    )
    #expect(amounts == [Decimal(150)])  // 100 × 1.50, day-0 rate
  }

  // MARK: - Intra-account transactions skip flow extraction

  @Test("intra-account-only transaction returns []")
  func intraAccountTransactionReturnsEmpty() async throws {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let txn = Transaction(
      date: date(daysAfterEpoch: 1),
      legs: [
        TransactionLeg(accountId: accountId, instrument: bhp, quantity: 100, type: .trade),
        TransactionLeg(accountId: accountId, instrument: aud, quantity: -4_000, type: .trade),
      ]
    )
    let service = FixedConversionService(rates: [:])
    let amounts = try await AccountCashFlows.flowAmounts(
      for: txn, accountId: accountId, hostCurrency: aud, service: service
    )
    #expect(amounts.isEmpty)
  }

  // MARK: - Multi-leg transactions return one entry per qualifying leg

  @Test("multi-leg transaction with two qualifying account legs returns two amounts in leg order")
  func multiLegOrderPreserved() async throws {
    // Two opening-balance legs in the account (atypical but legal).
    let txn = Transaction(
      date: date(daysAfterEpoch: 0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 100, type: .openingBalance
        ),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 200, type: .openingBalance
        ),
      ]
    )
    let service = FixedConversionService(rates: [:])
    let amounts = try await AccountCashFlows.flowAmounts(
      for: txn, accountId: accountId, hostCurrency: aud, service: service
    )
    #expect(amounts == [100, 200])
  }

  // MARK: - Conversion failure throws and stops further conversions

  @Test("conversion failure on first qualifying leg rethrows; later legs are not converted")
  func conversionFailureStopsOnFirstError() async throws {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    // ThrowingCountingConversionService: outcome closure receives the
    // 0-based call index so we can fail the first call and verify
    // subsequent calls never happen (calls counter is checked below).
    let counter = ThrowingCountingConversionService(
      outcome: { _ in .failure(ConversionTestError.unavailable) }
    )
    let txn = Transaction(
      date: date(daysAfterEpoch: 0),
      legs: [
        TransactionLeg(accountId: accountId, instrument: usd, quantity: 100, type: .income),
        TransactionLeg(accountId: accountId, instrument: bhp, quantity: 50, type: .income),
        TransactionLeg(accountId: otherAccountId, instrument: aud, quantity: -100, type: .expense),
      ]
    )
    do {
      _ = try await AccountCashFlows.flowAmounts(
        for: txn, accountId: accountId, hostCurrency: aud, service: counter
      )
      Issue.record("Expected throw")
    } catch is ConversionTestError {
      // expected
    }
    #expect(counter.calls == 1)  // first call threw; helper bailed
  }

  // MARK: - Cancellation propagates

  @Test("CancellationError propagates unwrapped")
  func cancellationPropagates() async throws {
    let txn = Transaction(
      date: date(daysAfterEpoch: 0),
      legs: [
        TransactionLeg(accountId: accountId, instrument: usd, quantity: 100, type: .income),
        TransactionLeg(accountId: otherAccountId, instrument: aud, quantity: -100, type: .expense),
      ]
    )
    let service = ThrowingCountingConversionService(
      outcome: { _ in .failure(CancellationError()) }
    )
    do {
      _ = try await AccountCashFlows.flowAmounts(
        for: txn, accountId: accountId, hostCurrency: aud, service: service
      )
      Issue.record("Expected throw")
    } catch is CancellationError {
      // expected — propagated unwrapped, not wrapped in another error.
    }
  }
}

// Local error used only in this suite.
private enum ConversionTestError: Error {
  case unavailable
}
```

The fixtures used here (`ThrowingCountingConversionService`,
`DateBasedFixedConversionService`) all exist in
`MoolahTests/Support/` with the API shapes used above (verified by
file inspection at plan-write time): `init(outcome: @escaping
@Sendable (Int) -> Result<Decimal, any Error>)`,
`.calls: Int`. `CountingConversionService` is
**not** used here because its `convertAmountCallCount` only counts
`convertAmount(...)` calls, not the `convert(...)` calls that
`AccountCashFlows.flowAmounts` makes — `ThrowingCountingConversion
Service.calls` is the right counter.

- [ ] **Step 1.2: Run the test file expecting compile failure**

```bash
mkdir -p .agent-tmp
just test-mac AccountCashFlowsTests 2>&1 | tee .agent-tmp/test.txt
```

Expected: build failure with errors like
`cannot find 'AccountCashFlows' in scope`. This confirms the tests
genuinely depend on the helper that does not exist.

- [ ] **Step 1.3: Create the helper with the minimal implementation that makes the tests pass**

Create `Shared/AccountCashFlows.swift`:

```swift
import Foundation

/// Shared per-leg cash-flow classifier used by both
/// `AccountPerformanceCalculator` (the tile pass) and
/// `PositionsHistoryBuilder` (the chart pass). Centralising the
/// boundary-crossing predicate here means both consumers cannot
/// silently diverge on edge cases such as opening-balance legs or
/// cross-currency conversion dates.
///
/// Caseless `enum` (CODE_GUIDE.md §5 — pure namespace).
enum AccountCashFlows {
  /// Returns the host-currency contribution amount for every leg in
  /// `transaction` that belongs to `accountId` and counts as a flow.
  ///
  /// A leg counts iff `leg.type == .openingBalance` OR `transaction`
  /// touches at least one other non-nil `accountId`. The
  /// boundary-crossing predicate is evaluated once per transaction
  /// inside this helper so callers cannot duplicate or diverge from
  /// the rule.
  ///
  /// Returns one `Decimal` per qualifying leg (in `hostCurrency`) in
  /// the order legs appear on `transaction`. Empty when no leg
  /// qualifies.
  ///
  /// Throws on the *first* conversion failure rather than returning
  /// a partial list. Throwing puts the policy choice at the call
  /// site (calculator throws the whole `compute(...)`,
  /// `PositionsHistoryBuilder` sets `state.contributions = nil` for
  /// the rest of the build), which is clearer than a sentinel
  /// return shape with two failure modes.
  ///
  /// `nonisolated` so `@concurrent` callers
  /// (`PositionsHistoryBuilder.build`) do not hop to the main actor
  /// per transaction; default-isolation callers
  /// (`AccountPerformanceCalculator.extractFlows`) are unaffected
  /// because `nonisolated` is callable from any context.
  nonisolated static func flowAmounts(
    for transaction: Transaction,
    accountId: UUID,
    hostCurrency: Instrument,
    service: any InstrumentConversionService
  ) async throws -> [Decimal] {
    let crossesBoundary = !Set(transaction.legs.compactMap(\.accountId))
      .subtracting([accountId])
      .isEmpty

    var amounts: [Decimal] = []
    for leg in transaction.legs where leg.accountId == accountId {
      guard leg.type == .openingBalance || crossesBoundary else { continue }

      let amount: Decimal
      if leg.instrument == hostCurrency {
        amount = leg.quantity
      } else {
        amount = try await service.convert(
          leg.quantity,
          from: leg.instrument,
          to: hostCurrency,
          on: transaction.date
        )
      }
      try Task.checkCancellation()
      amounts.append(amount)
    }
    return amounts
  }
}
```

- [ ] **Step 1.4: Run the tests, expecting all to pass**

```bash
just test-mac AccountCashFlowsTests 2>&1 | tee .agent-tmp/test.txt
grep -i 'failed\|error:' .agent-tmp/test.txt || echo "all passed"
```

Expected: all seven tests pass. Inspect the file if anything fails;
do not advance until green.

- [ ] **Step 1.5: Run formatter and the focused suite to confirm both clean**

```bash
just format
just format-check
just test-mac AccountCashFlowsTests
```

- [ ] **Step 1.6: Commit**

```bash
git -C "$(pwd)" add Shared/AccountCashFlows.swift MoolahTests/Shared/AccountCashFlowsTests.swift
git -C "$(pwd)" commit -m "$(cat <<'EOF'
feat(shared): add AccountCashFlows.flowAmounts shared helper

Single-source-of-truth boundary-crossing flow extractor used by both
AccountPerformanceCalculator (next commit) and PositionsHistoryBuilder
(later commit). nonisolated so @concurrent callers don't hop main.

Refs plans/2026-05-05-position-chart-invested-and-pl-design.md §2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

If the test file does not appear in `git status` because it is in a
new directory not yet tracked: `git -C "$(pwd)" add MoolahTests/Shared/`
to add the directory contents. Verify with `git -C "$(pwd)" diff --cached --stat`
before committing.

---

## Task 2: Migrate `AccountPerformanceCalculator.extractFlows` to use the new helper

**Files:**
- Modify: `Shared/AccountPerformanceCalculator.swift`
  (`extractFlows` body only — no signature change.)
- Modify: `MoolahTests/Shared/AccountPerformanceCalculatorTests.swift`
  (one new regression test for `[CashFlow]` order.)

- [ ] **Step 2.1: Add a regression test asserting per-leg `CashFlow` order is preserved**

Add to `MoolahTests/Shared/AccountPerformanceCalculatorTests.swift`
(append at the end of the existing `@Suite`):

```swift
@Test("extractFlows preserves per-leg ordering inside a multi-leg transaction")
func extractFlowsPreservesLegOrder() async throws {
  // Two opening-balance legs (legal, atypical) — order must survive.
  let accountId = UUID()
  let aud = Instrument.AUD
  let txn = Transaction(
    date: Date(timeIntervalSince1970: 1_700_000_000),
    legs: [
      TransactionLeg(accountId: accountId, instrument: aud, quantity: 100, type: .openingBalance),
      TransactionLeg(accountId: accountId, instrument: aud, quantity: 200, type: .openingBalance),
    ]
  )
  let service = FixedConversionService(rates: [:])
  let performance = try await AccountPerformanceCalculator.compute(
    accountId: accountId,
    transactions: [txn],
    valuedPositions: [],
    profileCurrency: aud,
    conversionService: service
  )
  #expect(
    performance.totalContributions
      == InstrumentAmount(quantity: 300, instrument: aud)
  )
  #expect(performance.firstFlowDate == txn.date)
}
```

If `compute` requires a non-empty `valuedPositions` to return a
non-`unavailable` performance, inspect the existing tests in this
file for how they construct `[ValuedPosition]` fixtures and adapt
the test to that shape; do not change `compute`.

- [ ] **Step 2.2: Run the new test, expecting it to pass against the un-refactored implementation**

```bash
just test-mac AccountPerformanceCalculatorTests/extractFlowsPreservesLegOrder
```

Expected: pass. The current implementation already preserves
order; this test is a regression guard for Task 2.3.

- [ ] **Step 2.3: Refactor `extractFlows` to use the helper**

In `Shared/AccountPerformanceCalculator.swift`, replace the existing
`extractFlows` body with the helper-based version. The full method
becomes:

```swift
private static func extractFlows(
  from transactions: [Transaction],
  accountId: UUID,
  profileCurrency: Instrument,
  conversionService: any InstrumentConversionService
) async throws -> [CashFlow] {
  var flows: [CashFlow] = []
  let sorted = transactions.sorted { $0.date < $1.date }
  for transaction in sorted {
    let amounts = try await AccountCashFlows.flowAmounts(
      for: transaction,
      accountId: accountId,
      hostCurrency: profileCurrency,
      service: conversionService
    )
    for amount in amounts {
      flows.append(CashFlow(date: transaction.date, amount: amount))
    }
  }
  return flows
}
```

The local `for leg in ...` loop and the `crossesBoundary`
computation that previously lived here are deleted — both moved
into the helper.

- [ ] **Step 2.4: Run the full calculator test suite and confirm green**

```bash
just test-mac AccountPerformanceCalculatorTests 2>&1 | tee .agent-tmp/test.txt
grep -i 'failed\|error:' .agent-tmp/test.txt || echo "all passed"
```

Expected: all existing tests pass + the new
`extractFlowsPreservesLegOrder` test passes. If any case fails,
the refactor changed semantics — re-read the helper carefully
against the original `extractFlows` body and reconcile.

- [ ] **Step 2.5: Run format-check, then commit**

```bash
just format
just format-check
git -C "$(pwd)" add Shared/AccountPerformanceCalculator.swift \
  MoolahTests/Shared/AccountPerformanceCalculatorTests.swift
git -C "$(pwd)" commit -m "$(cat <<'EOF'
refactor(shared): use AccountCashFlows in AccountPerformanceCalculator

Behaviour-preserving extraction; helper now owns the boundary-crossing
predicate. Adds a leg-order regression test.

Refs plans/2026-05-05-position-chart-invested-and-pl-design.md §2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add `contributions: Decimal?` to `HistoricalValueSeries.Point`

**Files:**
- Modify: `Domain/Models/HistoricalValueSeries.swift`
- Modify: `MoolahTests/Domain/HistoricalValueSeriesTests.swift`

- [ ] **Step 3.1: Add the round-trip test for the new field**

Add to `MoolahTests/Domain/HistoricalValueSeriesTests.swift`:

```swift
@Test("Point.contributions round-trips and participates in Hashable")
func pointContributionsRoundTrip() {
  let date = Date(timeIntervalSince1970: 1_700_000_000)
  let populated = HistoricalValueSeries.Point(
    date: date, value: 100, cost: 80, contributions: 50
  )
  let unavailable = HistoricalValueSeries.Point(
    date: date, value: 100, cost: 80, contributions: nil
  )
  #expect(populated.contributions == 50)
  #expect(unavailable.contributions == nil)
  #expect(populated != unavailable)
  #expect(Set([populated, unavailable]).count == 2)
}
```

- [ ] **Step 3.2: Run the test, expecting compile failure**

```bash
just test-mac HistoricalValueSeriesTests 2>&1 | tee .agent-tmp/test.txt
```

Expected: build failure (`extra argument 'contributions'`).

- [ ] **Step 3.3: Add the field to the production type**

In `Domain/Models/HistoricalValueSeries.swift`, modify the `Point`
struct so the diff yields:

```swift
struct HistoricalValueSeries: Sendable, Hashable {
  struct Point: Sendable, Hashable {
    let date: Date
    /// Market value in `hostCurrency` on this date.
    let value: Decimal
    /// Remaining cost basis in `hostCurrency` of currently-held lots.
    /// Meaningful for both aggregate and per-instrument series.
    let cost: Decimal
    /// Cumulative net external contributions to the account in
    /// `hostCurrency`, evaluated at this date. Populated only for
    /// the aggregate (account-level) series; per-instrument series
    /// leave this `nil`. `nil` does not mean zero — it means
    /// "not applicable at this granularity" (per-instrument) or
    /// "conversion failure for some flow on or before this date"
    /// (Rule 11 — see PositionsHistoryBuilder).
    let contributions: Decimal?
  }

  // ... rest of the type unchanged
}
```

- [ ] **Step 3.4: Update existing `Point(...)` initializer call sites**

Build will fail at the existing initializer call sites in
`Shared/PositionsHistoryBuilder.swift` (currently passing only
`date`, `value`, `cost`). Open that file and at every
`HistoricalValueSeries.Point(date: ..., value: ..., cost: ...)`
call, append `, contributions: nil` (Task 4 will replace this for
the aggregate path; for now keep the build green with `nil`):

```bash
just build-mac 2>&1 | tee .agent-tmp/build.txt
grep -n 'extra argument\|missing argument\|cannot find' .agent-tmp/build.txt
```

Edit each reported line to include `contributions: nil`.

- [ ] **Step 3.5: Re-run the test and the build**

```bash
just test-mac HistoricalValueSeriesTests
just build-mac
```

Expected: both green. If `PositionsHistoryBuilderTests` fails
because their existing fixtures construct `Point` directly, add
`contributions: nil` to those fixtures too (they will be updated
in Task 4).

- [ ] **Step 3.6: Commit**

```bash
just format
just format-check
git -C "$(pwd)" add Domain/Models/HistoricalValueSeries.swift \
  Shared/PositionsHistoryBuilder.swift \
  MoolahTests/Domain/HistoricalValueSeriesTests.swift
git -C "$(pwd)" commit -m "$(cat <<'EOF'
feat(domain): add HistoricalValueSeries.Point.contributions field

Aggregate emission populates it (next commit); per-instrument leaves
nil. Existing call sites updated to pass nil to keep the build green.

Refs plans/2026-05-05-position-chart-invested-and-pl-design.md §1.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

If `MoolahTests/Shared/PositionsHistoryBuilderTests.swift` was
edited to add `contributions: nil` to fixture initialisers, include
it in the staged paths.

---

## Task 4: Add contribution tracking to `PositionsHistoryBuilder`

**Files:**
- Modify: `Shared/PositionsHistoryBuilder.swift`
- Modify: `MoolahTests/Shared/PositionsHistoryBuilderTests.swift`

- [ ] **Step 4.1: Add the eight contribution-tracking tests**

Append to the existing `@Suite("PositionsHistoryBuilder")` in
`MoolahTests/Shared/PositionsHistoryBuilderTests.swift`. Each test
uses the existing `accountId`, `aud`, `bhp`, `date(daysAfterEpoch:)`
helpers already in the file. The cross-currency case needs a
non-midnight time component to verify Rule 5 — add a sibling
helper at the top of the suite (next to the existing
`date(daysAfterEpoch:)` definition) rather than retrofitting the
existing helper:

```swift
/// Day 0 = 2026-01-01, with a non-midnight clock time so tests
/// asserting Rule 5 / Rule 8 / Rule 10 normalisation can verify
/// the conversion-service receives the original `transaction.date`
/// (not a `startOfDay`-truncated copy).
private func date(daysAfterEpoch days: Int, hour: Int) -> Date {
  var components = DateComponents()
  components.year = 2026
  components.month = 1
  components.day = 1 + days
  components.hour = hour
  return Calendar(identifier: .gregorian).date(from: components)!
}
```

Note on `DateBasedFixedConversionService` lookup: the fixture's
`ratesAsOf(_:)` does a "most recent date ≤ requested" sweep. Rate
keys constructed via `date(daysAfterEpoch:)` (no hour) are at
00:00; transaction dates at `hour: 14` resolve to a later
timestamp on the same calendar day, so the sweep correctly picks
the same-day rate. This was verified by reading
`MoolahTests/Support/DateBasedFixedConversionService.swift` — no
`startOfDay` normalisation is needed inside the test because the
fixture is naturally tolerant of intra-day clock drift on the
lookup side.

```swift
// MARK: - Contributions tracking (cumulative net external cash flows)

private func openingBalance(
  in instrument: Instrument, qty: Decimal, daysAfterEpoch days: Int
) -> Transaction {
  Transaction(
    date: date(daysAfterEpoch: days),
    legs: [
      TransactionLeg(
        accountId: accountId, instrument: instrument, quantity: qty,
        type: .openingBalance
      )
    ]
  )
}

private func transferIn(
  qty: Decimal, daysAfterEpoch days: Int, fromOther: UUID = UUID()
) -> Transaction {
  Transaction(
    date: date(daysAfterEpoch: days),
    legs: [
      TransactionLeg(accountId: accountId, instrument: aud, quantity: qty, type: .income),
      TransactionLeg(accountId: fromOther, instrument: aud, quantity: -qty, type: .expense),
    ]
  )
}

private func transferOut(
  qty: Decimal, daysAfterEpoch days: Int, toOther: UUID = UUID()
) -> Transaction {
  Transaction(
    date: date(daysAfterEpoch: days),
    legs: [
      TransactionLeg(accountId: accountId, instrument: aud, quantity: -qty, type: .expense),
      TransactionLeg(accountId: toOther, instrument: aud, quantity: qty, type: .income),
    ]
  )
}

@Test("opening balance establishes contributions baseline")
func contributionsOpeningBalance() async throws {
  let txns = [openingBalance(in: aud, qty: 1_000, daysAfterEpoch: 0)]
  let service = FixedConversionService(rates: [bhp.id: Decimal(50)])
  let builder = PositionsHistoryBuilder(conversionService: service)
  let series = await builder.build(
    transactions: txns, accountId: accountId,
    hostCurrency: aud, range: .threeMonths,
    now: date(daysAfterEpoch: 5)
  )
  // `total` only includes days where positions exist; opening balance
  // alone with no holdings yields no aggregate points. Add a buy to
  // produce a point and assert contributions includes the opening balance.
  let withBuy = txns + [buy(instrument: bhp, qty: 10, fiat: 500, daysAfterEpoch: 1)]
  let series2 = await builder.build(
    transactions: withBuy, accountId: accountId,
    hostCurrency: aud, range: .threeMonths,
    now: date(daysAfterEpoch: 5)
  )
  let firstAggregate = try #require(series2.totalSeries.first)
  // Opening balance is a flow ($1000) — buy is intra-account, not a flow.
  #expect(firstAggregate.contributions == 1_000)
  // Series with no aggregate points still finishes cleanly.
  #expect(series.totalSeries.isEmpty)
}

@Test("external transfer in steps contributions up")
func contributionsTransferInStep() async throws {
  let txns = [
    openingBalance(in: aud, qty: 1_000, daysAfterEpoch: 0),
    buy(instrument: bhp, qty: 10, fiat: 500, daysAfterEpoch: 1),
    transferIn(qty: 500, daysAfterEpoch: 3),
  ]
  let service = FixedConversionService(rates: [bhp.id: Decimal(50)])
  let builder = PositionsHistoryBuilder(conversionService: service)
  let series = await builder.build(
    transactions: txns, accountId: accountId,
    hostCurrency: aud, range: .threeMonths,
    now: date(daysAfterEpoch: 5)
  )
  let aggregate = series.totalSeries
  // Days 1–2: contributions == 1_000. Days 3–5: contributions == 1_500.
  let day1 = try #require(aggregate.first { $0.date == date(daysAfterEpoch: 1) })
  let day3 = try #require(aggregate.first { $0.date == date(daysAfterEpoch: 3) })
  #expect(day1.contributions == 1_000)
  #expect(day3.contributions == 1_500)
}

@Test("external transfer out steps contributions down")
func contributionsTransferOutStep() async throws {
  let txns = [
    openingBalance(in: aud, qty: 2_000, daysAfterEpoch: 0),
    buy(instrument: bhp, qty: 10, fiat: 500, daysAfterEpoch: 1),
    transferOut(qty: 800, daysAfterEpoch: 3),
  ]
  let service = FixedConversionService(rates: [bhp.id: Decimal(50)])
  let builder = PositionsHistoryBuilder(conversionService: service)
  let series = await builder.build(
    transactions: txns, accountId: accountId,
    hostCurrency: aud, range: .threeMonths,
    now: date(daysAfterEpoch: 5)
  )
  let day3 = try #require(
    series.totalSeries.first { $0.date == date(daysAfterEpoch: 3) }
  )
  #expect(day3.contributions == 1_200)
}

@Test("intra-account trade leaves contributions unchanged")
func contributionsIntraAccountTrade() async throws {
  let txns = [
    openingBalance(in: aud, qty: 1_000, daysAfterEpoch: 0),
    buy(instrument: bhp, qty: 10, fiat: 500, daysAfterEpoch: 1),
    buy(instrument: bhp, qty: 5, fiat: 250, daysAfterEpoch: 3),
  ]
  let service = FixedConversionService(rates: [bhp.id: Decimal(50)])
  let builder = PositionsHistoryBuilder(conversionService: service)
  let series = await builder.build(
    transactions: txns, accountId: accountId,
    hostCurrency: aud, range: .threeMonths,
    now: date(daysAfterEpoch: 5)
  )
  for point in series.totalSeries {
    #expect(point.contributions == 1_000)
  }
}

@Test("cross-currency contribution converts on transaction.date")
func contributionsCrossCurrencyOnTxnDate() async throws {
  let usd = Instrument.USD
  let day0 = date(daysAfterEpoch: 0)
  let day10 = date(daysAfterEpoch: 10)
  // Two distinct rates: passing the wrong date would yield 1_400, not 1_500.
  let service = DateBasedFixedConversionService(rates: [
    day0: [usd.id: Decimal(string: "1.50")!, bhp.id: Decimal(50)],
    day10: [usd.id: Decimal(string: "1.40")!, bhp.id: Decimal(50)],
  ])
  let txns = [
    Transaction(
      date: date(daysAfterEpoch: 0, hour: 14),  // non-zero clock time
      legs: [
        TransactionLeg(accountId: accountId, instrument: usd, quantity: 1_000, type: .openingBalance)
      ]
    ),
    buy(instrument: bhp, qty: 10, fiat: 500, daysAfterEpoch: 1),
  ]
  let builder = PositionsHistoryBuilder(conversionService: service)
  let series = await builder.build(
    transactions: txns, accountId: accountId,
    hostCurrency: aud, range: .threeMonths,
    now: date(daysAfterEpoch: 12)
  )
  let day1 = try #require(
    series.totalSeries.first { $0.date == date(daysAfterEpoch: 1) }
  )
  #expect(day1.contributions == Decimal(1_500))  // 1_000 USD × 1.50 day-0 rate
}

@Test("pre-fold contributes prior-window flows to day-1 of visible window")
func contributionsPreFold() async throws {
  let txns = [
    openingBalance(in: aud, qty: 5_000, daysAfterEpoch: 0),
    buy(instrument: bhp, qty: 10, fiat: 500, daysAfterEpoch: 1),
    transferIn(qty: 1_000, daysAfterEpoch: 5),
  ]
  let service = FixedConversionService(rates: [bhp.id: Decimal(50)])
  let builder = PositionsHistoryBuilder(conversionService: service)
  // Window starts at day 10 — pre-fold should swallow days 0/1/5.
  let series = await builder.build(
    transactions: txns, accountId: accountId,
    hostCurrency: aud, range: .oneMonth,
    now: date(daysAfterEpoch: 12)
  )
  // Visible aggregate points: days 10, 11, 12 (range cutoff).
  // First visible point already reflects 5_000 + 1_000 = 6_000.
  let firstVisible = try #require(series.totalSeries.first)
  #expect(firstVisible.contributions == 6_000)
}

@Test("conversion failure makes whole forward contributions series unavailable")
func contributionsStickyLatchOnFailure() async throws {
  let usd = Instrument.USD
  // FailingConversionService throws .unavailable for any conversion
  // involving an id in `failingInstrumentIds`; same-instrument
  // conversions short-circuit (Rule 8 fast path) and never throw.
  // BHP rate is configured so the per-day value-conversion path
  // succeeds and continues to emit aggregate value/cost points
  // regardless of the contributions latch.
  let service = FailingConversionService(
    rates: [bhp.id: Decimal(50)],
    failingInstrumentIds: [usd.id]
  )
  let txns = [
    openingBalance(in: aud, qty: 1_000, daysAfterEpoch: 0),  // host-currency, fast path
    buy(instrument: bhp, qty: 10, fiat: 500, daysAfterEpoch: 1),  // intra-account, no flow
    Transaction(  // boundary-crossing USD transfer-in — flowAmounts will throw
      date: date(daysAfterEpoch: 3),
      legs: [
        TransactionLeg(accountId: accountId, instrument: usd, quantity: 100, type: .income),
        TransactionLeg(accountId: UUID(), instrument: usd, quantity: -100, type: .expense),
      ]
    ),
  ]
  let builder = PositionsHistoryBuilder(conversionService: service)
  let series = await builder.build(
    transactions: txns, accountId: accountId,
    hostCurrency: aud, range: .threeMonths,
    now: date(daysAfterEpoch: 5)
  )
  let day1 = try #require(
    series.totalSeries.first { $0.date == date(daysAfterEpoch: 1) }
  )
  let day4 = try #require(
    series.totalSeries.first { $0.date == date(daysAfterEpoch: 4) }
  )
  #expect(day1.contributions == 1_000)  // succeeded; valid as-of-day-1
  #expect(day4.contributions == nil)     // failure on day 3; sticky
  // value/cost still populated for both — the BHP value-conversion
  // path is independent of the contributions latch.
  #expect(day1.value == 10 * Decimal(50))
  #expect(day4.value == 10 * Decimal(50))
}

@Test("cancellation latches contributions to nil and exits cleanly")
func contributionsCancellation() async throws {
  // Service throws CancellationError on every call. The builder's
  // contribution fold catches it, sets state.contributions = nil
  // (Rule 11 — no stale partial reaches an emitted point), and
  // rethrows; the build's per-day loop converts the throw into a
  // partial-series return.
  let service = ThrowingCountingConversionService(
    outcome: { _ in .failure(CancellationError()) }
  )
  let txns = [
    openingBalance(in: Instrument.USD, qty: 1_000, daysAfterEpoch: 0),
    buy(instrument: bhp, qty: 10, fiat: 500, daysAfterEpoch: 1),
  ]
  let builder = PositionsHistoryBuilder(conversionService: service)
  let series = await builder.build(
    transactions: txns, accountId: accountId,
    hostCurrency: aud, range: .threeMonths,
    now: date(daysAfterEpoch: 5)
  )
  // No emitted aggregate point should carry a non-nil contributions
  // value, because the very first contribution conversion failed
  // (USD opening balance leg, day 0) — the latch is set before any
  // post-day-0 emission. The series may be empty or contain only
  // value/cost-only points.
  for point in series.totalSeries {
    #expect(point.contributions == nil)
  }
}
```

All fixtures referenced in this step
(`ThrowingCountingConversionService`, `FailingConversionService`,
`DateBasedFixedConversionService`, `FixedConversionService`) exist
in `MoolahTests/Support/` with the API shapes shown — verified at
plan-write time. Do **not** modify `MoolahTests/Support/` files in
this task.

- [ ] **Step 4.2: Run the new tests, expecting them to fail (production not yet updated)**

```bash
just test-mac PositionsHistoryBuilderTests 2>&1 | tee .agent-tmp/test.txt
grep -i 'failed\|error:' .agent-tmp/test.txt
```

Expected: every new test fails with
`Expectation failed: ... .contributions == ... (got nil)` because
`Point.contributions` is currently passed `nil` from every builder
emission (Task 3.4).

- [ ] **Step 4.3: Update `BuildState`, `apply(transaction:)`, and `emitDailyPoints` in `PositionsHistoryBuilder`**

In `Shared/PositionsHistoryBuilder.swift`:

(a) Extend `BuildState` (currently around line 187):

```swift
private struct BuildState {
  var quantities: [Instrument: Decimal] = [:]
  var engine = CostBasisEngine()
  var txnIndex = 0
  var perInstrument: [String: [HistoricalValueSeries.Point]] = [:]
  var total: [HistoricalValueSeries.Point] = []
  /// Running cumulative contributions in `hostCurrency`. `nil` once
  /// any contribution conversion has thrown — sticky latch never
  /// reset within a build (Rule 11 cumulative-sum semantics).
  /// `BuildState` is exclusively owned by the single `@concurrent`
  /// build task; no other task ever holds a reference.
  var contributions: Decimal? = 0

  func series(hostCurrency: Instrument) -> HistoricalValueSeries {
    HistoricalValueSeries(
      hostCurrency: hostCurrency, total: total, perInstrument: perInstrument)
  }
}
```

(b) Modify `apply(transaction:accountId:hostCurrency:quantities:engine:)` to
also accept `BuildState` `inout` (or to be split — see below).

Because the existing `apply` takes only `quantities` and `engine`,
the simplest refactor is to inline the contribution fold next to
the existing classifier call. Replace the body of `apply` with:

```swift
private func apply(
  transaction: Transaction,
  accountId: UUID,
  hostCurrency: Instrument,
  state: inout BuildState
) async {
  let accountLegs = transaction.legs.filter { $0.accountId == accountId }

  // Quantities (existing logic).
  for leg in accountLegs where leg.instrument != hostCurrency {
    state.quantities[leg.instrument, default: 0] += leg.quantity
  }

  // Cost-basis fold via classifier (existing logic).
  do {
    let classification = try await TradeEventClassifier.classify(
      legs: accountLegs, on: transaction.date,
      hostCurrency: hostCurrency, conversionService: conversionService
    )
    for buy in classification.buys {
      state.engine.processBuy(
        instrument: buy.instrument, quantity: buy.quantity,
        costPerUnit: buy.costPerUnit, date: transaction.date)
    }
    for sell in classification.sells {
      _ = state.engine.processSell(
        instrument: sell.instrument, quantity: sell.quantity,
        proceedsPerUnit: sell.proceedsPerUnit, date: transaction.date)
    }
  } catch {
    logger.warning(
      "TradeEventClassifier failed for txn \(transaction.id, privacy: .public) on \(transaction.date, privacy: .public): \(error.localizedDescription, privacy: .public)"
    )
  }

  // Contributions fold (new — sticky latch).
  guard let running = state.contributions else { return }
  do {
    let amounts = try await AccountCashFlows.flowAmounts(
      for: transaction, accountId: accountId,
      hostCurrency: hostCurrency, service: conversionService
    )
    if !amounts.isEmpty {
      state.contributions = running + amounts.reduce(0, +)
    }
  } catch is CancellationError {
    // Rule 11: don't let a stale partial total reach an emitted
    // point if cancellation interrupted mid-transaction. Latch
    // contributions unavailable AND rethrow so the build's
    // structured-cancellation chain tears down cleanly per
    // CONCURRENCY_GUIDE.md §3 — the outer build() converts the
    // throw back into a "return partial series" exit so the
    // function signature stays non-throwing for callers.
    state.contributions = nil
    throw CancellationError()
  } catch {
    state.contributions = nil  // sticky latch — see design §6
    logger.warning(
      "AccountCashFlows.flowAmounts failed for txn \(transaction.id, privacy: .public) on \(transaction.date, privacy: .public): \(error.localizedDescription, privacy: .public)"
    )
  }
}
```

The function signature changes to `private func apply(...) async throws`
so the `CancellationError` rethrow is propagable. General errors
(non-`CancellationError`) are still caught locally and converted to
the sticky latch — they never escape `apply`.

(c) Update the two callers (`preFoldHistory` and
`applyTransactions`) to:
- become `async throws`,
- pass `&state` instead of `&state.quantities, engine: &state.engine`,
- propagate `CancellationError` (no other error type can escape
  `apply`).

```swift
private func preFoldHistory(
  before start: Date,
  context: BuildContext,
  state: inout BuildState
) async throws {
  while state.txnIndex < context.sortedTxns.count
    && context.calendar.startOfDay(for: context.sortedTxns[state.txnIndex].date) < start
  {
    try await apply(
      transaction: context.sortedTxns[state.txnIndex],
      accountId: context.accountId,
      hostCurrency: context.hostCurrency,
      state: &state
    )
    state.txnIndex += 1
  }
}

private func applyTransactions(
  on day: Date,
  context: BuildContext,
  state: inout BuildState
) async throws {
  while state.txnIndex < context.sortedTxns.count
    && context.calendar.startOfDay(for: context.sortedTxns[state.txnIndex].date) == day
  {
    try await apply(
      transaction: context.sortedTxns[state.txnIndex],
      accountId: context.accountId,
      hostCurrency: context.hostCurrency,
      state: &state
    )
    state.txnIndex += 1
  }
}
```

(c.2) `build(...)` keeps its `async` (non-throws) signature; wrap
the two call sites that can now throw `CancellationError` in a
`do/catch is CancellationError` block that returns the partial
series. This preserves the existing public API (callers do not
need to gain `try`):

```swift
// inside build()'s per-day loop:
do {
  try await applyTransactions(on: day, context: context, state: &state)
} catch is CancellationError {
  return state.series(hostCurrency: hostCurrency)
}
```

And the pre-fold call:

```swift
do {
  try await preFoldHistory(before: start, context: context, state: &state)
} catch is CancellationError {
  return state.series(hostCurrency: hostCurrency)
}
```

Both `catch` arms `return state.series(...)` rather than rethrowing
because `build` is `async` (matches the existing public contract
that callers do not see throws).

(d) Update `emitDailyPoints` to write `state.contributions` on the
aggregate point (and leave per-instrument emission's
`contributions: nil` from Task 3):

```swift
if anyHeld && aggOK {
  state.total.append(
    HistoricalValueSeries.Point(
      date: day, value: aggValue, cost: aggCost,
      contributions: state.contributions))
}
```

Per-instrument emission within the same loop already passes
`contributions: nil` (Task 3.4). Verify by inspection.

- [ ] **Step 4.4: Run the new tests + the existing builder suite**

```bash
just test-mac PositionsHistoryBuilderTests 2>&1 | tee .agent-tmp/test.txt
grep -i 'failed\|error:' .agent-tmp/test.txt || echo "all passed"
```

Expected: all eight new tests pass; the existing 20+ tests still
pass. If any existing test fails, the refactor of `apply`'s
signature was incomplete — diff the changes against the original
`apply` and ensure the cost-basis behaviour is byte-for-byte
identical.

- [ ] **Step 4.5: Run the full test suite to catch any cross-file regression**

```bash
just test-mac 2>&1 | tee .agent-tmp/test.txt
grep -ci 'failed' .agent-tmp/test.txt
```

Expected: exit message says zero failures. Investigate any
unexpected red, especially in `AccountPerformanceCalculatorTests`
(now also exercising the helper).

- [ ] **Step 4.6: Format and commit**

```bash
just format
just format-check
git -C "$(pwd)" add Shared/PositionsHistoryBuilder.swift \
  MoolahTests/Shared/PositionsHistoryBuilderTests.swift
git -C "$(pwd)" commit -m "$(cat <<'EOF'
feat(positions): track contributions in PositionsHistoryBuilder

Aggregate HistoricalValueSeries.Point.contributions now reflects
cumulative net external cash flows in host currency. Sticky-nil latch
on conversion failure; pre-fold short-circuits once latched.

Refs plans/2026-05-05-position-chart-invested-and-pl-design.md §2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Unify `PositionsChart` rendering with gain/loss area + invested/cost baseline

**Files:**
- Modify: `Shared/Views/Positions/PositionsChart.swift`
- Create: `MoolahTests/Shared/PositionsChartDataTests.swift`

The chart change is rendering-only; the baseline-selection logic
must be testable without SwiftUI snapshots. The pattern: extract a
`fileprivate` (or private to the chart file) helper struct that
takes `[HistoricalValueSeries.Point]` plus a mode flag and yields
the per-point baseline + a "legend unavailable" signal. Tests
target that helper.

- [ ] **Step 5.1: Write the data-shape tests against a not-yet-existing helper**

Create `MoolahTests/Shared/PositionsChartDataTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("PositionsChart data shape")
struct PositionsChartDataTests {
  let aud = Instrument.AUD

  private func point(
    day: Int, value: Decimal, cost: Decimal, contributions: Decimal?
  ) -> HistoricalValueSeries.Point {
    var components = DateComponents()
    components.year = 2026; components.month = 1; components.day = 1 + day
    let d = Calendar(identifier: .gregorian).date(from: components)!
    return HistoricalValueSeries.Point(
      date: d, value: value, cost: cost, contributions: contributions
    )
  }

  @Test("aggregate mode picks point.contributions as baseline")
  func aggregateBaselineIsContributions() {
    let points = [
      point(day: 0, value: 1_100, cost: 800, contributions: 1_000),
      point(day: 1, value: 1_150, cost: 800, contributions: 1_000),
    ]
    let resolved = PositionsChartBaselineResolver.resolve(
      points: points, mode: .aggregate
    )
    #expect(resolved.map(\.baseline) == [1_000, 1_000])
    #expect(resolved.map(\.gainSegment) == [100, 150])
    #expect(resolved.map(\.lossSegment) == [0, 0])
    #expect(resolved.last?.legendUnavailable == false)
  }

  @Test("per-instrument mode picks point.cost as baseline (contributions nil-tolerant)")
  func perInstrumentBaselineIsCost() {
    let points = [
      point(day: 0, value: 850, cost: 800, contributions: nil),
      point(day: 1, value: 900, cost: 800, contributions: nil),
    ]
    let resolved = PositionsChartBaselineResolver.resolve(
      points: points, mode: .perInstrument
    )
    #expect(resolved.map(\.baseline) == [800, 800])
    #expect(resolved.map(\.gainSegment) == [50, 100])
  }

  @Test("loss segments are emitted when value < baseline")
  func lossSegments() {
    let points = [point(day: 0, value: 950, cost: 1_000, contributions: nil)]
    let resolved = PositionsChartBaselineResolver.resolve(
      points: points, mode: .perInstrument
    )
    #expect(resolved[0].gainSegment == 0)
    #expect(resolved[0].lossSegment == 50)
  }

  @Test("nil baseline produces a no-area entry; value-line still renderable")
  func nilBaselineSuppressesArea() {
    let points = [
      point(day: 0, value: 1_100, cost: 800, contributions: 1_000),
      point(day: 1, value: 1_150, cost: 800, contributions: nil),
    ]
    let resolved = PositionsChartBaselineResolver.resolve(
      points: points, mode: .aggregate
    )
    #expect(resolved[0].baseline != nil)
    #expect(resolved[1].baseline == nil)
    #expect(resolved[1].gainSegment == 0)
    #expect(resolved[1].lossSegment == 0)
  }

  @Test("most-recent point with nil baseline triggers legend-unavailable signal")
  func legendUnavailableWhenLatestNil() {
    let points = [
      point(day: 0, value: 1_100, cost: 800, contributions: 1_000),
      point(day: 1, value: 1_150, cost: 800, contributions: nil),
    ]
    let resolved = PositionsChartBaselineResolver.resolve(
      points: points, mode: .aggregate
    )
    #expect(resolved.last?.legendUnavailable == true)
  }
}
```

- [ ] **Step 5.2: Run, expecting compile failure (helper does not exist)**

```bash
just test-mac PositionsChartDataTests 2>&1 | tee .agent-tmp/test.txt
```

Expected: `cannot find 'PositionsChartBaselineResolver' in scope`.

- [ ] **Step 5.3: Add the helper at the top of `PositionsChart.swift`**

In `Shared/Views/Positions/PositionsChart.swift`, above the
existing `struct PositionsChart: View` declaration, add (with a
`// MARK: - Render-row resolution` heading per CODE_GUIDE.md §3 to
keep the file navigable as it grows):

After this task, run `just format-check` once and confirm the
file's `file_length` does not regress against
`.swiftlint-baseline.yml`. If a new violation appears, factor the
helper out into `Shared/Views/Positions/PositionsChartRenderRow.swift`
(its own file) before committing — do **not** modify
`.swiftlint-baseline.yml`.



```swift
/// Per-point rendering inputs computed by `PositionsChartBaseline
/// Resolver.resolve`. The chart consumes `baseline`, `gainSegment`,
/// and `lossSegment` directly to emit `AreaMark` / `LineMark` per
/// row; `legendUnavailable` on the last entry drives the legend
/// swatch state.
struct PositionsChartRenderRow: Sendable, Hashable {
  let date: Date
  let value: Decimal
  /// `nil` when the per-mode baseline is unavailable for this point
  /// (per-instrument: cost; aggregate: contributions). When `nil`,
  /// the chart emits the value line only — no area, no baseline
  /// line for this row.
  let baseline: Decimal?
  /// `max(value - baseline, 0)` when baseline is non-nil, else 0.
  let gainSegment: Decimal
  /// `max(baseline - value, 0)` when baseline is non-nil, else 0.
  let lossSegment: Decimal
  /// True for every row whose `baseline == nil` AND the row is the
  /// last in the resolved sequence — drives the legend's
  /// "Profit/Loss unavailable" state. Always false on non-last rows.
  let legendUnavailable: Bool
}

enum PositionsChartMode: Sendable {
  case aggregate
  case perInstrument
}

enum PositionsChartBaselineResolver {
  static func resolve(
    points: [HistoricalValueSeries.Point], mode: PositionsChartMode
  ) -> [PositionsChartRenderRow] {
    guard !points.isEmpty else { return [] }
    let lastIndex = points.count - 1
    return points.enumerated().map { index, point in
      let baseline: Decimal?
      switch mode {
      case .aggregate: baseline = point.contributions
      case .perInstrument: baseline = point.cost
      }
      let gain = baseline.map { max(point.value - $0, 0) } ?? 0
      let loss = baseline.map { max($0 - point.value, 0) } ?? 0
      let isLast = (index == lastIndex)
      return PositionsChartRenderRow(
        date: point.date, value: point.value, baseline: baseline,
        gainSegment: gain, lossSegment: loss,
        legendUnavailable: isLast && baseline == nil
      )
    }
  }
}
```

- [ ] **Step 5.4: Run the data tests, expecting them to pass**

```bash
just test-mac PositionsChartDataTests 2>&1 | tee .agent-tmp/test.txt
grep -i 'failed\|error:' .agent-tmp/test.txt || echo "all passed"
```

Expected: all five pass.

- [ ] **Step 5.5: Replace `PositionsChart`'s `chartBody` to use the resolver**

A single `private static let gainLossOpacity: Double = 0.20` constant
defined on `PositionsChart` is the source of truth for both the
chart-area opacity AND the legend swatch fill. This prevents drift
between the swatch preview and the actual chart shading during the
visual-tuning pass in step 5.8.

In the same file, replace the existing `Chart { ForEach(points) { ... } }`
block in `chartBody` (currently around line 70) with:

```swift
private static let gainLossOpacity: Double = 0.20

@ViewBuilder private var chartBody: some View {
  let points = visiblePoints
  if points.isEmpty {
    ContentUnavailableView {
      Label("No chart data yet", systemImage: "chart.line.uptrend.xyaxis")
    } description: {
      Text("Record a trade to start tracking value over time.")
    }
    .frame(minHeight: 200)
  } else {
    let mode: PositionsChartMode =
      (selectedInstrument == nil) ? .aggregate : .perInstrument
    let rows = PositionsChartBaselineResolver.resolve(points: points, mode: mode)
    Chart {
      ForEach(rows, id: \.date) { row in
        // Gain area (green) — rendered only when value > baseline.
        if let baseline = row.baseline, row.gainSegment > 0 {
          AreaMark(
            x: .value("Date", row.date),
            yStart: .value("Baseline", Double(truncating: baseline as NSDecimalNumber)),
            yEnd: .value("Top", Double(truncating: (baseline + row.gainSegment) as NSDecimalNumber))
          )
          .foregroundStyle(.green.opacity(Self.gainLossOpacity))
        }
        // Loss area (red) — rendered only when value < baseline.
        if let baseline = row.baseline, row.lossSegment > 0 {
          AreaMark(
            x: .value("Date", row.date),
            yStart: .value("Bottom", Double(truncating: (baseline - row.lossSegment) as NSDecimalNumber)),
            yEnd: .value("Baseline", Double(truncating: baseline as NSDecimalNumber))
          )
          .foregroundStyle(.red.opacity(Self.gainLossOpacity))
        }
        // Value line.
        LineMark(
          x: .value("Date", row.date),
          y: .value("Value", Double(truncating: row.value as NSDecimalNumber)),
          series: .value("Series", "Value")
        )
        .foregroundStyle(Color.accentColor)
        .lineStyle(StrokeStyle(lineWidth: 2))
        .interpolationMethod(.linear)
        // Baseline step line (skip when nil).
        if let baseline = row.baseline {
          LineMark(
            x: .value("Date", row.date),
            y: .value("Baseline", Double(truncating: baseline as NSDecimalNumber)),
            series: .value("Series", "Baseline")
          )
          .foregroundStyle(.secondary)
          .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
          .interpolationMethod(.stepEnd)
        }
      }
    }
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: 4)) { value in
        AxisGridLine()
        AxisTick()
        if let date = value.as(Date.self) {
          AxisValueLabel {
            Text(date, format: .dateTime.month(.abbreviated))
              .font(.caption2)
          }
        }
      }
    }
    .chartYAxis {
      AxisMarks { value in
        AxisGridLine()
        AxisValueLabel {
          if let amount = value.as(Double.self) {
            Text(amount, format: .number.notation(.compactName))
              .font(.caption2)
              .monospacedDigit()
          }
        }
      }
    }
    .frame(height: 220)
    .accessibilityChartDescriptor(self)

    legendRow(rows: rows, mode: mode)
  }
}

@ViewBuilder
private func legendRow(rows: [PositionsChartRenderRow], mode: PositionsChartMode) -> some View {
  let baselineLabel: String = (mode == .aggregate) ? "Invested amount" : "Cost basis"
  let unavailable = rows.last?.legendUnavailable == true
  HStack(spacing: 16) {
    legendItem(color: Color.accentColor, label: "Value", dashed: false)
    legendItem(color: .secondary, label: baselineLabel, dashed: true)
    profitLossLegendItem(unavailable: unavailable)
    Spacer()
  }
  .font(.caption2)
  .foregroundStyle(.secondary)
}

@ViewBuilder
private func profitLossLegendItem(unavailable: Bool) -> some View {
  // Swatch opacity must match the chart's gain/loss area opacity
  // so the legend genuinely previews what the user sees on the
  // plot. Gray fallback for the unavailable state uses the same
  // opacity for visual consistency.
  HStack(spacing: 4) {
    VStack(spacing: 1) {
      Rectangle()
        .fill(unavailable
          ? Color.gray.opacity(Self.gainLossOpacity)
          : Color.green.opacity(Self.gainLossOpacity))
        .frame(width: 14, height: 4)
      Rectangle()
        .fill(unavailable
          ? Color.gray.opacity(Self.gainLossOpacity)
          : Color.red.opacity(Self.gainLossOpacity))
        .frame(width: 14, height: 4)
    }
    .accessibilityHidden(true)
    Text(unavailable ? "Profit/Loss unavailable" : "Profit/Loss")
  }
  .accessibilityElement(children: .combine)
  .accessibilityLabel(
    unavailable ? "Profit and Loss area, unavailable" : "Profit and Loss area"
  )
}
```

The existing `legendItem(color:label:dashed:)` function and
`DashedLineSwatch` struct are reused — do not delete them. The
`legend` computed property previously rendered two legend items via
that function; it is now replaced by `legendRow` and called from
`chartBody`. Search and remove the old top-level `legend` `View`
property and its now-unreferenced `Spacer`-bearing definition (was
~lines 126–133); leave `legendItem(...)` and `DashedLineSwatch`
alone.

The previous solid blue area (`AreaMark` with
`Color.accentColor.opacity(0.18)` at the original
`PositionsChart.swift:73`) is removed by this rewrite — verify no
`Color.accentColor.opacity(0.18)` remains in the file.

- [ ] **Step 5.6: Update the AX chart-descriptor snapshot to read `Invested amount` / `Cost basis` accordingly, and skip nil baseline points**

The existing `chartSnapshot()` (~line 226) hard-codes
`"Cost basis"` as the second series name. The new code must:

1. Choose the series name based on mode (`Invested amount` for
   aggregate, `Cost basis` for per-instrument).
2. **Filter out** any point whose baseline is `nil` from the
   `AXDataSeriesDescriptor`'s data — VoiceOver will speak `.nan`
   as "not a number" if it is included, and the existing
   per-instrument cost-basis path also drops days where cost is
   unavailable. Filtering preserves that contract.

```swift
let baselineName: String =
  selectedInstrument == nil ? "Invested amount" : "Cost basis"

// Pair each point with its baseline (or nil); drop nil-baseline rows
// before they reach the AX descriptor so VoiceOver doesn't speak NaN.
let baselinePairs: [(label: String, value: Double)] = points.compactMap { point in
  let baseline: Decimal? =
    selectedInstrument == nil ? point.contributions : point.cost
  guard let baseline else { return nil }
  return (
    point.date.formatted(.dateTime.month(.abbreviated).day().year()),
    Double(truncating: baseline as NSDecimalNumber)
  )
}

let baselineSeries = AXDataSeriesDescriptor(
  name: baselineName,
  isContinuous: true,
  dataPoints: baselinePairs.map { AXDataPoint(x: $0.label, y: $0.value) }
)
```

The existing `costDoubles` array (used to compute the y-axis
range) is recomputed from `baselinePairs.map(\.value)` so the
y-axis range still bounds the visible data correctly. Update
references in `chartSnapshot` accordingly.

- [ ] **Step 5.7: Build, run tests, and verify the full suite**

```bash
just build-mac
just test-mac PositionsChartDataTests PositionsHistoryBuilderTests
just test-mac 2>&1 | tee .agent-tmp/test.txt
grep -ci 'failed' .agent-tmp/test.txt
```

Expected: green. Address any failure before proceeding.

- [ ] **Step 5.8: Visually verify the chart in `#Preview` (light + dark mode, four cases)**

Use the `reviewing-ui-with-preview` skill. Open
`Shared/Views/Positions/PositionsChart.swift` in Xcode; activate
the canvas; render four previews in both light and dark mode.
Capture each via `mcp__xcode__RenderPreview` when iterating with
the user.

Required preview gates (acceptance criteria are gates — every
named gate must be verified before this step is marked done):

1. **Existing `"Chart - aggregate"`** — gain/loss area reads as a
   clear translucent green fill above the dashed gray invested
   line; legend reads `Value`, `Invested amount`, `Profit/Loss`.
2. **Existing `"Chart - filtered to instrument"`** — same shape
   with a red or green area between value and the dashed cost-
   basis baseline; legend reads `Value`, `Cost basis`,
   `Profit/Loss`.
3. **Existing `"Chart - empty"`** — `ContentUnavailableView`
   renders, no axes.
4. **NEW `#Preview("Chart - unavailable")`** — add a preview
   inline alongside the existing ones whose
   `HistoricalValueSeries` has at least one point with
   `contributions: nil` as the **last** point. Acceptance: legend
   reads `Profit/Loss unavailable`, the swatch is visibly muted
   (gray, same opacity as the green/red swatches in case 1), and
   no green/red area is drawn for the nil-baseline day(s).

Adjust `Self.gainLossOpacity` from `0.20` to `0.16` (lighter) or
`0.24` (denser) only if cases 1 and 2 read visually wrong in
either colour scheme. Both legend swatch and chart area share the
constant, so the tuning automatically affects both.

Also verify the seam-at-crossing risk from the design's "Risks"
section: render a synthetic preview where two adjacent points
straddle the baseline (one with value > baseline, the next with
value < baseline). Acceptance: the colour transition is clean
(no 1-pixel seam visible at the crossing); if a seam appears, the
mitigation is to gate area emission on `gainSegment > 0` /
`lossSegment > 0` (already in step 5.5's snippet).

- [ ] **Step 5.9: Format, commit**

```bash
just format
just format-check
git -C "$(pwd)" add Shared/Views/Positions/PositionsChart.swift \
  MoolahTests/Shared/PositionsChartDataTests.swift
git -C "$(pwd)" commit -m "$(cat <<'EOF'
feat(positions): unify chart with gain/loss area + invested baseline

Aggregate chart now plots cumulative contributions as the baseline
(switchable to cost basis on per-instrument selection). Stacked
green/red AreaMark pair shades the gap between value and baseline.
Solid blue area fill removed; legend gains a Profit/Loss swatch.

Refs plans/2026-05-05-position-chart-invested-and-pl-design.md §3.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Add `Invested $X` subtitle to `AccountPerformanceTiles.currentValueTile`

**Files:**
- Create: `Shared/Views/Positions/AccountPerformanceTileLabels.swift`
  (view-layer helper that derives display strings from
  `AccountPerformance` — kept out of `Domain/Models/` because the
  domain layer must not own UI copy per `CLAUDE.md` "Domain Layer:
  Strictly isolated").
- Modify: `Shared/Views/Positions/AccountPerformanceTiles.swift`
- Create: `MoolahTests/Shared/AccountPerformanceTileLabelsTests.swift`

The tile is a SwiftUI view; the project's pattern for tile tests
(see `PositionsViewInputTests`) asserts on the data the view
consumes rather than rendering pixels. We extract the
accessibility-label string and the subtitle's display string into
a pure caseless `enum` namespace at the view layer, so the test
can call them directly with `AccountPerformance` fixtures via
`@testable import Moolah`.

- [ ] **Step 6.1: Write the eight tile-label tests**

Create `MoolahTests/Shared/AccountPerformanceTileLabelsTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("AccountPerformanceTileLabels")
struct AccountPerformanceTileLabelsTests {
  let aud = Instrument.AUD

  private func performance(
    currentValue: Decimal? = nil,
    contributions: Decimal? = nil,
    profitLoss: Decimal? = nil,
    firstFlowDate: Date? = nil
  ) -> AccountPerformance {
    AccountPerformance(
      instrument: aud,
      currentValue: currentValue.map { InstrumentAmount(quantity: $0, instrument: aud) },
      totalContributions: contributions.map { InstrumentAmount(quantity: $0, instrument: aud) },
      profitLoss: profitLoss.map { InstrumentAmount(quantity: $0, instrument: aud) },
      profitLossPercent: nil,
      annualisedReturn: nil,
      firstFlowDate: firstFlowDate
    )
  }

  @Test("subtitle shows Invested $X when both flowDate and contributions populated")
  func subtitleShowsInvested() {
    let p = performance(
      currentValue: 12_000, contributions: 10_000,
      firstFlowDate: Date(timeIntervalSince1970: 1_700_000_000)
    )
    #expect(AccountPerformanceTileLabels.investedSubtitleText(p) == "Invested \(InstrumentAmount(quantity: 10_000, instrument: aud).formatted)")
  }

  @Test("subtitle shows Invested em-dash when flowDate set but contributions nil")
  func subtitleShowsUnavailable() {
    let p = performance(
      currentValue: 12_000, contributions: nil,
      firstFlowDate: Date(timeIntervalSince1970: 1_700_000_000)
    )
    #expect(AccountPerformanceTileLabels.investedSubtitleText(p) == "Invested —")
  }

  @Test("subtitle hidden when no flows yet")
  func subtitleHiddenNoFlows() {
    let p = performance(currentValue: 12_000, contributions: nil, firstFlowDate: nil)
    #expect(AccountPerformanceTileLabels.investedSubtitleText(p) == nil)
  }

  @Test("accessibility label combines both fields when both populated")
  func accessibilityBothPopulated() {
    let p = performance(
      currentValue: 12_000, contributions: 10_000,
      firstFlowDate: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let cv = InstrumentAmount(quantity: 12_000, instrument: aud).formatted
    let inv = InstrumentAmount(quantity: 10_000, instrument: aud).formatted
    #expect(AccountPerformanceTileLabels.currentValueAccessibilityLabel(p) == "Current Value: \(cv), Invested: \(inv)")
  }

  @Test("accessibility label when currentValue nil but contributions populated")
  func accessibilityCurrentValueNil() {
    let p = performance(
      contributions: 10_000,
      firstFlowDate: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let inv = InstrumentAmount(quantity: 10_000, instrument: aud).formatted
    #expect(AccountPerformanceTileLabels.currentValueAccessibilityLabel(p) == "Current Value: Unavailable, Invested: \(inv)")
  }

  @Test("accessibility label when currentValue populated but contributions nil")
  func accessibilityContributionsNil() {
    let p = performance(
      currentValue: 12_000,
      firstFlowDate: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let cv = InstrumentAmount(quantity: 12_000, instrument: aud).formatted
    #expect(AccountPerformanceTileLabels.currentValueAccessibilityLabel(p) == "Current Value: \(cv), Invested: Unavailable")
  }

  @Test("accessibility label drops Invested clause when no flows yet")
  func accessibilityNoFlowsClause() {
    let p = performance(currentValue: 12_000, firstFlowDate: nil)
    let cv = InstrumentAmount(quantity: 12_000, instrument: aud).formatted
    #expect(AccountPerformanceTileLabels.currentValueAccessibilityLabel(p) == "Current Value: \(cv)")
  }

  @Test("accessibility label when both nil and no flows")
  func accessibilityAllUnavailable() {
    let p = performance()
    #expect(AccountPerformanceTileLabels.currentValueAccessibilityLabel(p) == "Current Value: Unavailable")
  }
}
```

These tests reference `AccountPerformanceTileLabels.investedSubtitle
Text(_:)` and `.currentValueAccessibilityLabel(_:)` static methods
that do not exist yet — they will be added in a new view-layer
helper file at `Shared/Views/Positions/AccountPerformanceTileLabels
.swift` (NOT on `AccountPerformance` in the domain layer, which is
forbidden from carrying UI-formatting logic per CLAUDE.md "Domain
Layer: Strictly isolated").

- [ ] **Step 6.2: Run, expecting compile failure**

```bash
just test-mac AccountPerformanceTileLabelsTests 2>&1 | tee .agent-tmp/test.txt
```

Expected: `cannot find 'AccountPerformanceTileLabels' in scope`.

- [ ] **Step 6.3: Add the helper namespace at the view layer**

Create `Shared/Views/Positions/AccountPerformanceTileLabels.swift`:

```swift
import Foundation

/// View-layer helpers that derive presentation strings from
/// `AccountPerformance`. Lives here (not on the domain model)
/// because the `Domain/` layer is strictly isolated from UI copy
/// and localisation-sensitive formatting (CLAUDE.md "Domain
/// Layer"). Tested directly via `@testable import Moolah` so the
/// SwiftUI view does not need a snapshot harness.
///
/// Caseless `enum` (CODE_GUIDE.md §5 — pure namespace).
enum AccountPerformanceTileLabels {
  /// Subtitle text for the Current Value tile, or `nil` to hide
  /// the subtitle row. Hidden when no flows exist; renders the
  /// formatted contributions when populated; renders an em-dash
  /// label when contributions are unavailable but flows exist
  /// (Rule 11 — never silently drop a partial sum).
  static func investedSubtitleText(_ performance: AccountPerformance) -> String? {
    guard performance.firstFlowDate != nil else { return nil }
    if let contributions = performance.totalContributions {
      return "Invested \(contributions.formatted)"
    }
    return "Invested —"
  }

  /// Accessibility label for the Current Value tile. Speaks the
  /// main value and (when flows exist) the contributions number.
  static func currentValueAccessibilityLabel(_ performance: AccountPerformance) -> String {
    let main: String
    if let value = performance.currentValue {
      main = "Current Value: \(value.formatted)"
    } else {
      main = "Current Value: Unavailable"
    }
    guard performance.firstFlowDate != nil else { return main }
    if let contributions = performance.totalContributions {
      return "\(main), Invested: \(contributions.formatted)"
    }
    return "\(main), Invested: Unavailable"
  }
}
```

- [ ] **Step 6.4: Run the new test suite, expecting it to pass**

```bash
just test-mac AccountPerformanceTileLabelsTests 2>&1 | tee .agent-tmp/test.txt
grep -i 'failed\|error:' .agent-tmp/test.txt || echo "all passed"
```

Expected: all eight pass.

- [ ] **Step 6.5: Wire the subtitle into the `currentValueTile` view**

In `Shared/Views/Positions/AccountPerformanceTiles.swift`, replace
the existing `currentValueTile` body with:

```swift
@ViewBuilder private var currentValueTile: some View {
  Tile(label: "Current Value") {
    if let value = performance.currentValue {
      Text(value.formatted)
        .font(.title3)
        .monospacedDigit()
    } else {
      Text("Unavailable")
        .font(.title3)
        .foregroundStyle(.secondary)
    }
  } subtitle: {
    investedSubtitleView
  }
  .accessibilityLabel(
    AccountPerformanceTileLabels.currentValueAccessibilityLabel(performance)
  )
}

@ViewBuilder private var investedSubtitleView: some View {
  if let text = AccountPerformanceTileLabels.investedSubtitleText(performance) {
    if performance.totalContributions != nil {
      Text(text)
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    } else {
      // "Invested —" form: no number to monospace; tertiary colour
      // matches the P/L tile's `—` styling for consistency.
      // The label prefix is intentional and **does not** match the
      // P/L tile's bare `—`: the subtitle has no adjacent label to
      // supply context, so the prefix is needed for the row to be
      // intelligible in isolation.
      Text(text)
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
  }
}
```

The existing `currentValueAccessibilityLabel` *property* defined
inline on the view (currently around line 158) is **deleted** —
its logic now lives on `AccountPerformance`. Search the file for
`private var currentValueAccessibilityLabel:` and remove that
block.

- [ ] **Step 6.6: Build + run all tests**

```bash
just build-mac
just test-mac 2>&1 | tee .agent-tmp/test.txt
grep -ci 'failed' .agent-tmp/test.txt
```

Expected: green.

- [ ] **Step 6.7: Visually verify in `#Preview` (four named gates)**

Open `AccountPerformanceTiles.swift`, render the four existing
previews in both light and dark mode. Acceptance per preview:

- **`"Gain"`** — Current Value `$23,405` over `Invested $21,605`
  in `.caption` `.secondary` styling.
- **`"Loss"`** — Current Value `$9,500` over
  `Invested $10,000` in `.caption` `.secondary` styling.
- **`"Unavailable"`** — Current Value reads `Unavailable`; the
  Invested subtitle is **hidden** (because
  `.unavailable(in:)` returns `firstFlowDate: nil`).
- **`"No flows yet"`** — Current Value `$0.00` with **no**
  Invested subtitle row.

Adjust nothing visual — the styling follows the P/L tile's
existing subtitle treatment. If any of the four gates fails
visually, fix the implementation (do not adjust copy without
returning to the spec for approval).

Also add an inline preview to verify the `Invested —` failure
state, since none of the canonical previews exercise it:

```swift
#Preview("Invested unavailable") {
  AccountPerformanceTiles(
    title: "Brokerage",
    performance: AccountPerformance(
      instrument: .AUD,
      currentValue: InstrumentAmount(quantity: 12_000, instrument: .AUD),
      totalContributions: nil,           // forces "Invested —"
      profitLoss: nil,
      profitLossPercent: nil,
      annualisedReturn: nil,
      firstFlowDate: Calendar.current.date(byAdding: .year, value: -1, to: Date())
    )
  )
  .frame(width: 720)
  .padding()
}
```

Acceptance: subtitle row renders `Invested —` in `.tertiary`
styling.

- [ ] **Step 6.8: Format, commit**

```bash
just format
just format-check
git -C "$(pwd)" add Shared/Views/Positions/AccountPerformanceTileLabels.swift \
  Shared/Views/Positions/AccountPerformanceTiles.swift \
  MoolahTests/Shared/AccountPerformanceTileLabelsTests.swift
git -C "$(pwd)" commit -m "$(cat <<'EOF'
feat(positions): add Invested subtitle to Current Value tile

Renders "Invested $X" under the Current Value number when flows
exist; "Invested —" when contributions extraction failed; hidden
when no flows have occurred. Accessibility label speaks both
fields.

Refs plans/2026-05-05-position-chart-invested-and-pl-design.md §4.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Final integration verification

**Files:** none modified — runtime smoke verification only.

- [ ] **Step 7.1: Run the full test suite on both platforms**

```bash
just test 2>&1 | tee .agent-tmp/test.txt
grep -ci 'failed' .agent-tmp/test.txt
```

Expected: zero failures across iOS and macOS targets.

- [ ] **Step 7.2: Build the macOS app and run it on a profile with position-tracked accounts**

Use the `automate-app` or `run-mac-app-with-logs` skill (whichever
the contributor prefers) to launch the built app:

```bash
just run-mac
```

Manually navigate to a position-tracked investment account
(default Test Profile → Brokerage). Verify:

1. Aggregate (no instrument selected) chart shows green or red
   shading between value and a dashed gray invested-amount line.
2. Click a position row in the table — chart switches to that
   instrument, baseline becomes cost basis (still dashed gray),
   gain/loss shading still works.
3. Press Escape (or click the chip's ✕) — chart returns to
   aggregate.
4. The Current Value tile shows `Invested $X` underneath the main
   number.
5. The legend reads `Value`, `Invested amount` (or `Cost basis` in
   per-instrument mode), `Profit/Loss`.

If the legend reads `Profit/Loss unavailable` for an account with
real flows, that indicates a contribution-conversion failure —
inspect the app logs (`os.Logger` warnings labelled
`AccountCashFlows.flowAmounts failed`) and re-run with caches
warmed if appropriate. Do not ship if the unavailable state appears
on previously-working accounts without an external cause.

- [ ] **Step 7.3: Verify VoiceOver behaviour**

On macOS, enable VoiceOver (`Cmd+F5`) and tab through the
investment account view. The Current Value tile should speak
`Current Value: $X, Invested: $Y`. The chart legend's Profit/Loss
swatch should speak `Profit and Loss area` (or
`Profit and Loss area, unavailable` when greyed). Disable
VoiceOver after verification.

- [ ] **Step 7.4: Final format-check, then push the branch**

```bash
just format-check
just build-mac
git -C "$(pwd)" log --oneline origin/main..HEAD
git -C "$(pwd)" push origin feat/investment-chart-invested-and-pl:feat/investment-chart-invested-and-pl
```

Expected: ~6 commits since `origin/main`, build green, push
succeeds. Do **not** rely on `git push -u`; use the explicit
`<src>:<dst>` form per CLAUDE.md.

- [ ] **Step 7.5: Open the PR and queue it**

```bash
gh pr create --title "Position chart: invested baseline + gain/loss shading + Invested tile subtitle" --body "$(cat <<'EOF'
## Summary
- Adds a cumulative-contributions baseline + green/red gain/loss area to the per-account position-tracked investment chart.
- Per-instrument view gains the same gain/loss shading using cost basis as the baseline.
- Current Value tile gains an "Invested $X" subtitle.
- Shared `AccountCashFlows.flowAmounts(for:)` helper unifies the boundary-crossing flow predicate between `AccountPerformanceCalculator` and `PositionsHistoryBuilder`.

## Test plan
- [ ] `just test` passes on both platforms.
- [ ] `just format-check` clean.
- [ ] Manual: aggregate chart on Test Profile → Brokerage shows shaded gain/loss area + dashed invested line.
- [ ] Manual: per-instrument chart shows same shading with cost basis baseline.
- [ ] Manual: Current Value tile shows "Invested $X" subtitle when flows exist; hides on fresh accounts.
- [ ] VoiceOver: tile + legend swatch both speak meaningful labels.

Closes (no tracking issue — feature work).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

After the PR URL is returned, hand it to the merge-queue skill per
the project convention:

```
/merge-queue add <PR_URL>
```

(Do not merge manually.)

- [ ] **Step 7.6: Move design + plan files to `plans/completed/` once the PR lands**

Not part of this plan — perform after the merge train ships the PR
to main, in a separate commit on a follow-up branch.

---

## Self-review summary

Spec coverage check (skim each spec section, point to a task):

- §1 `HistoricalValueSeries.Point.contributions` → Task 3.
- §2 `AccountCashFlows` helper + builder integration → Tasks 1, 2,
  4.
- §3 chart rendering (aggregate + per-instrument unified, gain/loss
  area, legend, accessibility) → Task 5.
- §4 tile subtitle → Task 6.
- §5 single-source-of-truth → Tasks 1+2+4 collectively.
- §6 failure modes (Rule 11 sticky latch) → Task 4 (sticky-latch
  test) + Task 5 (legend unavailable signal) + Task 6 (subtitle
  unavailable rendering).
- §7 view wiring → no changes needed; covered implicitly because
  `PositionsViewInput` carries `HistoricalValueSeries` unchanged.
- §Tests → Task 1 (helper), Task 2 (calculator regression), Task 3
  (model), Task 4 (builder), Task 5 (chart data), Task 6 (tile).
- §Risks: 1-pixel seam → Step 5.8 visual verify. Pre-fold long
  histories → covered by Step 4.4 (existing test suite latency).
  Subtitle truncation → Step 6.7 visual verify.

Type / signature consistency:
`AccountCashFlows.flowAmounts(for:)` signature is identical across
Tasks 1, 2, and 4. `HistoricalValueSeries.Point` initializer
ordering is `(date, value, cost, contributions)` everywhere.
`AccountPerformanceTileLabels.investedSubtitleText(_:)` /
`.currentValueAccessibilityLabel(_:)` defined in Task 6.3 are referenced
in Task 6.1 tests (TDD-correct order: tests first against the
not-yet-existing API).

No placeholders found.
