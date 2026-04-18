# Analysis Unified Position Book — Design

**Date:** 2026-04-17
**Author:** Claude (brainstorming with Adrian)
**Related:** Phase 6 multi-currency in `plans/ROADMAP.md`; follow-up to the forecast conversion fix landed as commit `ef8c6e7`.

## Problem

`CloudKitAnalysisRepository.fetchDailyBalances` and its static twin `computeDailyBalances` build daily balances in two passes:

1. A sequential accumulator (`applyTransaction`) that sums `balance`, `investments`, and per-earmark totals *in the profile instrument*.
2. A correction pass (`applyMultiInstrumentConversion`) that, only when `hasMultiInstrument` is true, tracks per-instrument positions and overwrites each affected day's balance with a correctly converted value.

Pass 1 crashes before pass 2 can run whenever any historical transaction has a leg in a non-profile instrument — `InstrumentAmount.+= ` has a `precondition` on matching instruments. Per-account currency shipped in Phase 6, so this crash is now reachable for any user with multi-currency history.

In addition, the repository contains two near-duplicate implementations (instance and `@concurrent` static) of the same flow, the `investmentTransfersOnly: Bool` flag changes meaning across the `after` boundary (creating the discontinuity logged in `BUGS.md`), and the position math for stores' incremental updates (`Shared/BalanceDeltaCalculator.swift`) duplicates concepts of the analysis accumulator.

## Goal

Collapse the two-pass, two-copy structure into a single correct-by-construction path backed by the same position-math primitive used by the delta calculator. Produce semantically identical output to today for every existing contract test — deviations require explicit user approval.

## Non-Goals

- **Changing the `investmentTransfersOnly` behaviour.** Preserved faithfully; discontinuity logged in `BUGS.md` for a separate decision.
- **Changing `applyInvestmentValues` or `applyBestFit`.** They run unchanged after the unified accumulator.
- **Fixing the forecast conversion.** Already landed (`ef8c6e7`).
- **Adding analysis UI.** No view changes in this spec.

## Design

### Core primitive: `PositionBook`

A pure value type that owns the per-entity, per-instrument position state. It is the single place where position math lives.

```swift
struct PositionBook: Equatable, Sendable {
  var accounts: [UUID: [Instrument: Decimal]] = [:]
  var earmarks: [UUID: [Instrument: Decimal]] = [:]
  var earmarksSaved: [UUID: [Instrument: Decimal]] = [:]
  var earmarksSpent: [UUID: [Instrument: Decimal]] = [:]
  /// Positions on investment accounts arising from `.transfer` legs only — used
  /// to compute `investments` total under `.investmentTransfersOnly` rule.
  var accountsFromTransfers: [UUID: [Instrument: Decimal]] = [:]

  static let empty = PositionBook()

  mutating func apply(_ leg: TransactionLeg, sign: Decimal)
  mutating func apply(_ txn: Transaction, sign: Decimal = 1)
  mutating func apply(_ delta: BalanceDelta)

  enum AccumulationRule: Sendable {
    case allLegs
    case investmentTransfersOnly
  }

  func dailyBalance(
    on date: Date,
    investmentAccountIds: Set<UUID>,
    profileInstrument: Instrument,
    rule: AccumulationRule,
    conversionService: any InstrumentConversionService,
    isForecast: Bool
  ) async throws -> DailyBalance
}
```

### Why the extra `accountsFromTransfers` dict

The existing `investmentTransfersOnly` rule says: during post-`after` accumulation, *non-transfer* legs on investment accounts do not contribute to the displayed `investments` total. Filtering at accumulation time would destroy information needed for `.allLegs` (starting balance) use. Tracking both states in parallel lets one accumulator serve both rules. The dict is populated only for investment-account legs; for most users (no investment accounts) it stays empty.

### Shared math with `BalanceDeltaCalculator`

`BalanceDeltaCalculator` already has the per-leg math with an explicit `sign` parameter (used to reverse old legs and apply new ones). We lift that math onto `PositionBook.apply(_ leg:sign:)`:

- `PositionBook.apply(_ leg:sign:)` — the canonical per-leg math. Mutates the four+1 dicts based on leg type and account/earmark membership.
- `PositionBook.apply(_ txn:sign:)` — walks `txn.legs`, calling `apply(_ leg:sign:)`.
- `PositionBook.apply(_ delta:)` — merges one PositionBook into another (used where deltas are already computed).

`BalanceDeltaCalculator.deltas(old:new:)` becomes a thin wrapper:
```swift
static func deltas(old: Transaction?, new: Transaction?) -> BalanceDelta {
  var book = PositionBook.empty
  if let old, !old.isScheduled { book.apply(old, sign: -1) }
  if let new, !new.isScheduled { book.apply(new, sign:  1) }
  book.cleanZeros()
  return BalanceDelta(from: book)
}
```

Its 28 existing tests stay untouched — they test the public API, not the internals. Stores continue to consume `BalanceDelta` as they do today.

### `dailyBalance(...)` — converting to profile currency

Iterates each bucket's per-instrument positions, converting to `profileInstrument` on the given `date` when instruments differ. Same math as today's `applyMultiInstrumentConversion`, with:

- Fast path: if a bucket has a single entry keyed to `profileInstrument.id`, no conversion call.
- Per-earmark clamp to zero before summing (matches existing behaviour).
- `investments` total: under `.allLegs`, sum positions for investment accounts; under `.investmentTransfersOnly`, sum `accountsFromTransfers` for investment accounts.
- `investmentValue` left `nil`; `applyInvestmentValues` fills it in unchanged.
- `bestFit` left `nil`; `applyBestFit` fills it in unchanged.

### Call-site consolidation

Today: `fetchDailyBalances` (instance) and `computeDailyBalances` (`@concurrent static`) are near-duplicates. Both contain the same loop, call `applyTransaction`, `applyMultiInstrumentConversion`, `applyInvestmentValues`, `applyBestFit`, `generateForecast`.

After: the `@concurrent static` becomes the sole implementation. The instance method becomes a thin wrapper that fetches `MainActor`-bound data and delegates. `generateForecast` continues to use `PositionBook` internally via the same pre-conversion approach that landed in `ef8c6e7` — the forecast-time leg pre-conversion logic is unchanged; only the accumulator primitive it feeds switches.

Sketch:

```swift
@concurrent
private static func computeDailyBalances(
  nonScheduled: [Transaction],
  scheduled: [Transaction],
  accounts: [Account],
  investmentValues: [(accountId: UUID, date: Date, value: InstrumentAmount)],
  after: Date?,
  forecastUntil: Date?,
  instrument: Instrument,
  conversionService: any InstrumentConversionService
) async throws -> [DailyBalance] {
  let investmentAccountIds = Set(accounts.filter { $0.type == .investment }.map(\.id))
  let sorted = nonScheduled.sorted { $0.date < $1.date }

  var book = PositionBook.empty
  var dailyBalances: [Date: DailyBalance] = [:]

  // Pre-`after` starting balance: all legs count toward investments.
  if let after {
    for txn in sorted where txn.date < after {
      book.apply(txn)
    }
  }

  // Post-`after` daily deltas: investment transfers only rule in effect
  // (but tracked via accumulator; applied at dailyBalance build time).
  for txn in sorted where after == nil || txn.date >= after {
    book.apply(txn)
    let dayKey = Calendar.current.startOfDay(for: txn.date)
    dailyBalances[dayKey] = try await book.dailyBalance(
      on: txn.date,
      investmentAccountIds: investmentAccountIds,
      profileInstrument: instrument,
      rule: .investmentTransfersOnly,
      conversionService: conversionService,
      isForecast: false
    )
  }

  try await applyInvestmentValues(
    investmentValues, to: &dailyBalances,
    instrument: instrument, conversionService: conversionService)

  var actualBalances = dailyBalances.values.sorted { $0.date < $1.date }
  applyBestFit(to: &actualBalances, instrument: instrument)

  var forecastBalances: [DailyBalance] = []
  if let forecastUntil {
    let lastDate = sorted.filter { after == nil || $0.date >= after }.last?.date ?? Date()
    forecastBalances = try await generateForecast(
      scheduled: scheduled,
      startingBook: book,
      startDate: lastDate,
      endDate: forecastUntil,
      investmentAccountIds: investmentAccountIds,
      profileInstrument: instrument,
      conversionService: conversionService
    )
  }

  return actualBalances + forecastBalances
}
```

The `startingBook` parameter hands the accumulator state cleanly to `generateForecast`, which continues to operate with `.investmentTransfersOnly` under the same rule boundary. Forecast-leg pre-conversion at `Date()` stays intact.

### Deletions after this lands

- `applyTransaction(_:to:investments:perEarmarkAmounts:...)` — replaced by `PositionBook.apply`.
- `applyMultiInstrumentConversion(...)` — replaced by `PositionBook.dailyBalance`.
- `clampedEarmarkTotal(...)` — inlined into `dailyBalance`.
- The `investmentTransfersOnly: Bool` flag on `applyTransaction` — replaced by the `rule` parameter on `dailyBalance`.
- The instance `fetchDailyBalances`'s duplicate accumulator loop — becomes a wrapper.
- The `BalanceDelta`/`BalanceDeltaCalculator` internals (accumulator dicts, `applyLeg` private) — the math moves to `PositionBook`, wrapper stays.

Net change: significant code reduction (~400 LOC deleted, ~250 LOC added).

## Contract test invariance — acceptance bar

**Zero diffs** to tests in `MoolahTests/Domain/AnalysisRepositoryContractTests.swift`, `MoolahTests/Features/AccountStoreTests.swift`, `MoolahTests/Features/EarmarkStoreTests.swift`, `MoolahTests/Shared/BalanceDeltaCalculatorTests.swift`.

If any existing test requires modification during implementation, the implementer must stop and escalate — that is a behaviour regression disguised as a test edit, and the user signs off or not.

## New test coverage

### `PositionBook` unit tests (new `MoolahTests/Shared/PositionBookTests.swift`)

- `empty book has no positions`
- `applying a single leg records the position`
- `applying a transaction records all its legs`
- `sign = -1 reverses an application`
- `applying old-sign-negative then new-sign-positive matches BalanceDeltaCalculator's output`
- `single-instrument dailyBalance skips conversion`
- `multi-instrument dailyBalance converts at the given date's rates`
- `earmarks are per-earmark clamped to zero before summing`
- `allLegs rule sums all investment-account positions`
- `investmentTransfersOnly rule sums only transfer-derived positions`
- `investment-account expense leg does not inflate transfers-only total`
- `investment-account transfer leg appears in both all-legs and transfers-only`

### `AnalysisRepositoryContractTests` additions (multi-instrument coverage gap)

- `holding revalues daily as exchange rate changes` — 100 USD opening balance, rate changes across days, verify each day's `balance.quantity` uses that day's rate.
- `multi-currency starting balance before 'after' cutoff` — historical AUD + USD + EUR priors; verify filtered starting balance is correct.
- `multi-currency investment account with no market value record` — USD investment account, position-tracking only; verify revaluation over time.
- `multi-currency earmark clamping` — negative foreign-currency earmark clamped before summation.
- `multi-currency expense breakdown across months` — extend existing test.
- `multi-currency income/expense with rate changes across months`.
- `category balances multi-currency` — extend existing test.
- `mixed bank + investment + earmark + multi-currency + rate-varying` — end-to-end smoke.
- `applyInvestmentValues override still wins on multi-currency investments`.
- `forecast starting from multi-currency actuals` — actuals leave USD holdings; forecast builds from that book, conversion at `Date()`.

Each test seeds an in-memory SwiftData container via `CloudKitAnalysisTestBackend(conversionService:)` with a `FixedConversionService` tuned to the scenario, and asserts observable properties of `DailyBalance` / `ExpenseBreakdown` / `MonthlyIncomeExpense` — no mocking of internals.

## Migration sequence

Designed so main builds and every existing test passes at every step.

1. **Add `PositionBook` + tests** (dead code, not called). Verify tests pass.
2. **Switch `BalanceDeltaCalculator.deltas(old:new:)` internals** to use `PositionBook`. Run existing delta tests and store tests — all green before continuing.
3. **Port `generateForecast`** to use `PositionBook`. Existing forecast tests pass.
4. **Port `computeDailyBalances`** to use `PositionBook`, leaving `applyMultiInstrumentConversion` alive in the tree and gated by a debug-only equivalence assertion in test builds. Run existing contract tests. Escalate if any fails.
5. **Port instance `fetchDailyBalances`** to delegate to the static path.
6. **Add new multi-instrument contract tests** — the big coverage push. They should all pass; if any fail, that's a real bug the old code also had (investigate, fix, note).
7. **Delete `applyTransaction`, `applyMultiInstrumentConversion`, `clampedEarmarkTotal`, `investmentTransfersOnly` flag**, and the debug-only equivalence assertion.

Each step ends with a commit. The implementer should not batch steps — any test-failure-on-a-step indicates a regression in that step, diagnosable in isolation.

## Risks

- **Numerical equivalence drift.** Banker's rounding in conversion, iteration order over dicts, and the precise moment of conversion all matter. The debug-only equivalence assertion in step 4 gates this before deletion in step 7.
- **Performance.** Per-day `dailyBalance(...)` walks up to 5 dicts plus conversion. For single-instrument users each dict has ≤1 entry, so cost is a handful of dict lookups per transaction — expected negligible. Benchmark via `just benchmark AnalysisBenchmarks` before merge; flag if any regression >5%.
- **Sendable correctness across `@concurrent` boundary.** `PositionBook` is a value type containing dicts of value types — naturally `Sendable`. `InstrumentConversionService` is already `Sendable`. Verified in the forecast-conversion PR; same pattern applies here.

## Open Questions

None. Raise on implementation if anything surfaces.

## Out of Scope Reminders

- The `investmentTransfersOnly` discontinuity is preserved, not fixed. `BUGS.md` entry tracks it.
- No change to `RemoteAnalysisRepository` (server-backed path) — that does network fetches, not local math.
- No change to UI — this is backend-only.
