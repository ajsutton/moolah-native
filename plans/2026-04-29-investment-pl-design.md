# Investment Account Performance — Design Spec

**Date:** 2026-04-29
**Status:** Draft
**Author:** brainstorming session with Adrian

## Goals

For an investment account — and for each currently-held position within it — surface three numbers that answer the questions a user actually asks:

1. **How much profit or loss has this account made overall?** (in profile currency, plus a percentage)
2. **What's the annual rate of return?**
3. **What's the cost basis** (per position, applicable to tax)?

These numbers should be simple to read, accurate enough to act on, and consistent with the account-level total a user already sees.

## Non-Goals

- Capital gains tax reporting (CGT discount, parcel selection, franking credits). That belongs to the existing tax design (`plans/2026-04-11-australian-tax-reporting-design.md`) and its `CapitalGainsCalculator` / `CostBasisEngine` foundations, which this design consumes but does not change.
- Per-position annualised return. Deferred until there is a position detail surface to host it.
- Dividend attribution to the paying position. The data model has no link from `.income` legs to the instrument that paid them. Out of scope.
- Time-windowed P&L (1Y / YTD / etc.) for the headline numbers. Headline numbers are always lifetime; the existing chart range picker continues to drive only the chart line.
- Replacing the legacy manual-valuation flow (`InvestmentValueRecord`s + `dailyBalances`). Its visual presentation is preserved; only the IRR math underneath is unified with the new path.

## Background — what already exists

This design adds calculations and a small UI strip; the underlying machinery is already in place:

- `Position` (computed from legs), `ValuedPosition` (with `costBasis` and `gainLoss`), `CostBasisLot`, `CapitalGainEvent`, `InstrumentProfitLoss`.
- `CostBasisEngine` (FIFO), `CapitalGainsCalculator`, `TradeEventClassifier`, `ProfitLossCalculator`, `PositionsHistoryBuilder`.
- `TransactionType.trade` (per `plans/2026-04-28-trade-transaction-ui-design.md`).
- `InvestmentStore` with cost-basis snapshotting and a binary-search IRR (`annualizedReturnRate(currentValue:)` ported from the web app).
- `PositionsView` / `PositionsHeader` / `PositionsTable` / `PositionRow` rendering positions with a P&L pill in the header and a Gain column in the table.
- Legacy `InvestmentSummaryView` showing `Current Value`, `Invested Amount`, `ROI` for accounts that use manually-recorded `InvestmentValue`s.

The gap: account-level performance numbers for **position-tracked** accounts have nowhere to live, and the legacy IRR has known math bugs (30-day month approximation, monthly-rate-as-percent). We surface the missing numbers and unify the IRR math along the way.

---

## Section 1 — Architecture overview

Three pure calculation pieces, plumbed into the existing `InvestmentStore`. No new repositories, no schema changes, no new persisted data — every figure derives from data already stored (`.transfer` legs, `.openingBalance` legs, `.trade` legs, position quantities, market prices via `InstrumentConversionService`).

```
Transactions ─┐
              ├→ AccountPerformanceCalculator ─→ AccountPerformance
Positions ────┤        (uses IRRSolver)
              │
Profile.instrument ┘
```

**New domain / shared types:**

- `Domain/Models/CashFlow.swift` — value type: `(date, amount in profile currency)`.
- `Domain/Models/AccountPerformance.swift` — result struct.
- `Shared/IRRSolver.swift` — Newton–Raphson seeded by Modified Dietz, day-precise compounding, returns effective annual rate.
- `Shared/AccountPerformanceCalculator.swift` — pure orchestrator: takes transactions + valued positions + profile currency, returns `AccountPerformance`. Two entry points: `compute(...)` (position-tracked) and `computeLegacy(...)` (manual-valuation accounts).
- `Shared/Views/Positions/AccountPerformanceTiles.swift` — three-tile horizontal strip rendering Current Value / P&L / Annualised Return.

**Repurposed:**

- `InvestmentStore` gains `accountPerformance: AccountPerformance?` published state, computed at the end of `loadAllData(...)` and refreshed on trades / value mutations.
- `PositionsViewInput` gains `performance: AccountPerformance?`. When non-nil, `PositionsView` renders `AccountPerformanceTiles` in place of the existing single-row `PositionsHeader`. When nil (any non-investment caller), the existing header renders unchanged.
- `PositionsTable.gainCell` and `PositionRow.trailingColumn` extend their existing `+$X.XX` rendering to `+$X.XX  +Y.Y%`.
- `ValuedPosition` gains a `gainLossPercent: Decimal?` derived property.

**Deleted:**

- `Features/Investments/InvestmentStore+PositionsInput.swift` lines 88–203 (the binary-search IRR `annualizedReturnRate(currentValue:)` and its private helpers `BalancePoint`, `RateBracket`, `BracketResult`, `futureValue`, `bracketReturnRate`, `binarySearchReturnRate`).
- `Features/Investments/Views/InvestmentSummaryView.swift` — superseded by `AccountPerformanceTiles`.

**Untouched:**

- `Position`, `ValuedPosition` (apart from the new derived property), `CostBasisLot`, `CapitalGainEvent`, `InstrumentProfitLoss`, `TradeEventClassifier`, `CapitalGainsCalculator`, `CostBasisEngine`, `ProfitLossCalculator`, `PositionsHistoryBuilder`.
- `PositionsChart`, `PositionsTimeRange`, the chart range picker, selection / filter / row tap behaviour.

---

## Section 2 — Cash flow extraction rule

A `CashFlow` is `(date, amountInProfileCurrency)` where positive = into the account from outside, negative = out of the account to outside.

```swift
struct CashFlow: Sendable, Hashable {
  let date: Date
  let amount: Decimal   // signed, in profile currency
}
```

### Inclusion rule

> A leg L in account A produces a `CashFlow` iff either:
> 1. `L.type == .openingBalance`, OR
> 2. The transaction containing L has at least one *other* leg whose `accountId != A` and `accountId != nil` (i.e. the transaction crosses an account boundary).

```swift
func externalCashFlowLegs(of transaction: Transaction, account: UUID) -> [TransactionLeg] {
  let otherAccountIds = Set(transaction.legs.compactMap(\.accountId)) - [account]
  return transaction.legs.filter { leg in
    leg.accountId == account
      && (leg.type == .openingBalance || !otherAccountIds.isEmpty)
  }
}
```

For each qualifying leg, the calculator emits one `CashFlow(transaction.date, leg.quantity converted to profile currency on transaction.date)`.

### Why this shape

The rule treats *any* transaction that crosses an account boundary as moving capital, regardless of leg type. This subsumes the obvious cases (transfers, opening balance) and self-corrects the data-model edge cases:

- **Pure transfer A→B.** Two `.transfer` legs in different accounts → boundary-crossing → flows on each side. ✓
- **Pure trade in A** (two `.trade` legs both in A, optional fees in A). Single-account → no flows. Cost basis still set per-position by `TradeEventClassifier`. ✓
- **Cross-account `.trade` misuse** (e.g. `.trade` paid leg in A, `.trade` received leg in B — semantically a cross-currency transfer the user expressed as a trade). Boundary-crossing → flows on each side. `TradeEventClassifier` already handles cross-account `.trade` legs (it pairs by leg, not by account), so per-position cost basis is correct; this rule makes account-level numbers also correct.
- **Single `.trade` leg, no counterpart.** Single-account (no boundary) → no flow → V_now reflects the new position quantity at zero cost. The user has effectively recorded "I now hold X for free", which is an honest depiction of what they entered. Same effect as recording an `.income` leg of the same instrument.
- **Dividend `.income` leg in A.** Single-account, no boundary → no flow → cash from the dividend sits in A's cash position → V_now is higher → gain reflects it. ✓
- **Brokerage fee `.expense` leg in A.** Same — cash decreases, V_now lower, gain reflects the cost. ✓
- **Transfer with fee in source** (`.transfer` -$100 in A + `.transfer` +$100 in B + `.expense` -$1 in A). Boundary-crossing → all three legs in A and B emit flows. A sees -$101 outflow (correctly attributing the fee as part of the cost of moving capital out); B sees +$100 inflow.

### Currency conversion

Each emitted `CashFlow.amount` is converted to profile currency at the leg's instrument and the transaction's date via `InstrumentConversionService.convert(...)`. Per `INSTRUMENT_CONVERSION_GUIDE.md` Rule 11: if any conversion fails, the entire `AccountPerformance` is marked unavailable (calculator throws) and the calling store sets `accountPerformance = nil` and `error`. We do not show partial sums.

### SQL implementability (informational)

The rule decomposes into one EXISTS-style boundary check plus a flat scan, both falling on existing FK indexes. A single-query SQLite implementation is straightforward:

```sql
SELECT t.date, l.instrument_id, l.quantity, l.type
FROM transaction_legs l
JOIN transactions t ON l.transaction_id = t.id
WHERE l.account_id = :account_id
  AND (
    l.type = 'openingBalance'
    OR EXISTS (
      SELECT 1 FROM transaction_legs l2
      WHERE l2.transaction_id = l.transaction_id
        AND l2.account_id IS NOT NULL
        AND l2.account_id <> :account_id
    )
  )
ORDER BY t.date;
```

Currency conversion stays in Swift behind the existing `InstrumentConversionService` (it falls back to nearest-date and to network fetch; not pure-SQL expressible). The implementation phase coordinates with the GRDB-slice work in flight to land this query as part of the repository surface, but the calculator's signature is the same either way.

### Known limitation (data-model-level)

Salary recorded as `.income` directly into an investment account (skipping a checking account) looks like free returns rather than contributed capital. The workaround is to record it as a `.transfer` from a notional cash source — which is the correct shape anyway. Fixing this in the calculator would require a tax-category-or-similar marker on `.income` legs and is out of scope.

---

## Section 3 — Calculation engines

### `IRRSolver`

Newton–Raphson with a Modified Dietz seed. Pure, synchronous, deterministic.

```swift
enum IRRSolver {
  /// Effective annual rate. Returns nil when:
  ///   - flows is empty, or
  ///   - flows span < 1 day (cannot annualise meaningfully), or
  ///   - Newton-Raphson fails to converge within 50 iterations and the
  ///     bisection fallback also fails (pathological multi-root cases).
  static func annualisedReturn(
    flows: [CashFlow],
    terminalValue: Decimal,
    terminalDate: Date
  ) -> Decimal?
}
```

Algorithm:

1. **Seed `r₀`** from the closed-form Modified Dietz period return:
   `MD = (V − ΣCᵢ) / Σ(wᵢ · Cᵢ)` where `wᵢ = (T − tᵢ) / T`,
   then annualise to `(1 + MD)^(365/T) − 1`.
2. **Newton–Raphson** iterate: `rₙ₊₁ = rₙ − f(rₙ)/f'(rₙ)` where
   `f(r) = Σ Cᵢ · (1+r)^(−tᵢ/365) − V · (1+r)^(−T/365)`
   (sign convention: contributions are signed inflows; V is treated as a negative final return so the equation roots at the IRR).
   Stop when `|f(rₙ)| < 1e-9` or 50 iterations.
3. **Bisection fallback** if Newton–Raphson diverges (rare; happens only with strongly multi-root patterns). Range `[−0.99, 10.0]`, ~30 iterations.
4. Return `rₙ` directly — already an effective annual rate by construction (day-fraction exponents).

Day-precise compounding (`tᵢ` measured in days from the first flow) replaces the legacy 30-day-month approximation.

### `AccountPerformance`

```swift
struct AccountPerformance: Sendable, Hashable {
  let instrument: Instrument                    // profile currency at calc time
  let currentValue: InstrumentAmount?           // nil if any conversion failed
  let totalContributions: InstrumentAmount?     // Σ Cᵢ, signed
  let profitLoss: InstrumentAmount?             // currentValue − totalContributions
  let profitLossPercent: Decimal?               // see formula below
  let annualisedReturn: Decimal?                // from IRRSolver
  let firstFlowDate: Date?                      // for "since Mar 2023" subtitle
}
```

**`profitLossPercent` formula:** the Modified Dietz period return (not annualised) — `(V − ΣCᵢ) / Σ(wᵢ · Cᵢ)`. We compute MD anyway as the Newton–Raphson seed, so reusing it is free. It's a fairer denominator than gross deposits (which penalises any withdrawal) and matches the IRR's underlying capital base.

### `AccountPerformanceCalculator`

```swift
enum AccountPerformanceCalculator {
  /// Position-tracked accounts. Walks transactions for §2-rule cash flows,
  /// uses valuedPositions for V_now (sum of converted values, or nil if
  /// any failed). Throws on conversion failure when deriving flows.
  static func compute(
    accountId: UUID,
    transactions: [Transaction],
    valuedPositions: [ValuedPosition],
    profileCurrency: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> AccountPerformance

  /// Legacy manual-valuation accounts. Cash flows = consecutive
  /// dailyBalance deltas. Terminal value = latest InvestmentValue.
  /// Preserves today's semantics — every transaction counts as a flow,
  /// not just §2-rule legs — so displayed numbers are stable for
  /// existing legacy users. Synchronous (no conversion needed; legacy
  /// accounts are mono-instrument by construction).
  static func computeLegacy(
    dailyBalances: [AccountDailyBalance],
    values: [InvestmentValue],
    instrument: Instrument
  ) -> AccountPerformance
}
```

Both share `IRRSolver` for the p.a. figure and the same Modified Dietz formula for `profitLossPercent`, so the legacy path automatically picks up day-precise compounding and the proper effective-annual-rate output.

### Edge-case behaviour

| Scenario | currentValue | totalContributions | profitLoss | profitLossPercent | annualisedReturn |
|---|---|---|---|---|---|
| Account just opened, no flows | 0 | 0 | 0 | nil | nil |
| Single deposit, no trades | = deposit | = deposit | 0 | 0 | 0 |
| All withdrawn (Σ flows = 0, V = 0) | 0 | 0 | 0 | nil (0/0) | 0 (or nil if < 1 day span) |
| First flow < 1 day ago | normal | normal | normal | nil (T → 0) | nil |
| Conversion failed on any flow | nil | nil | nil | nil | nil |
| Conversion failed on a position | nil | normal | nil | nil | nil |

UI renders any `nil` field as `—` using existing `amountCell` / `gainCell` patterns.

---

## Section 4 — UI changes

### `AccountPerformanceTiles`

A horizontal strip of three tiles, replacing both the existing `PositionsHeader` (title + total + pill) for investment-account hosts and the legacy `InvestmentSummaryView`.

```
┌────────────────────────────────────────────────────────────┐
│ Brokerage                                                  │
├──────────────────┬──────────────────┬─────────────────────┤
│ Current Value    │ Profit/Loss      │ Annualised Return   │
│ $23,405          │ +$1,800          │ +8.3% p.a.          │
│                  │ +8.3%            │ since Mar 2023      │
└──────────────────┴──────────────────┴─────────────────────┘
```

Layout:
- Each tile: `VStack` with caption-style label, headline-style amount (`monospacedDigit`), optional small subtitle (the % under P&L $, the "since Mar 2023" under p.a.).
- `.green` / `.red` foreground on the P&L $ tile and its subtitle, and on the p.a. tile, using existing `gainColor(_:)` semantics.
- Vertical dividers between tiles (matches legacy `InvestmentSummaryView`).
- Title row above tiles — title gets its own row to make space for the tile strip.
- Edge cases:
  - `currentValue == nil` → that tile shows "Unavailable".
  - `profitLoss == nil` → P&L tile shows `—`, no subtitle, no colour.
  - `annualisedReturn == nil` → p.a. tile shows `—`, no subtitle, with a `.help(...)` tooltip on macOS / accessibility hint on iOS explaining the cause ("Not enough activity yet" or "Conversion unavailable").

### `PositionsView` integration

`PositionsViewInput` gains an optional `performance: AccountPerformance?` field. `PositionsView`'s body becomes:

```swift
VStack(spacing: 0) {
  if let perf = input.performance {
    AccountPerformanceTiles(title: input.title, performance: perf)
  } else {
    PositionsHeader(input: input)   // existing title + total + pill, unchanged
  }
  if input.showsChart { ... }
  PositionsTable(input: input, selection: $selection)
}
```

Non-investment-account hosts (anywhere `PositionsView` is reused) leave `performance: nil`, preserving the existing single-row header path. No behavioural change for those callers.

### `PositionsTable` and `PositionRow` Gain cell

`ValuedPosition` gains:

```swift
extension ValuedPosition {
  /// Gain as a percentage of cost basis. nil if either value or cost basis
  /// is missing, or cost basis is zero. Sign preserved per CLAUDE.md.
  var gainLossPercent: Decimal? {
    guard let value, let costBasis, costBasis.quantity != 0 else { return nil }
    return (value.quantity - costBasis.quantity) / costBasis.quantity * 100
  }
}
```

`PositionsTable.gainCell(_:)` and `PositionRow.trailingColumn` change their existing `gain.signedFormatted` rendering to render `gain.signedFormatted` plus a small `+x.x%` directly after. Wide table:

```
Instrument        Qty    Unit Price    Cost      Value     Gain
[S] BHP.AX        250    $45.30        $10,125   $11,325   +$1,200  +11.9%
[S] CBA.AX         80    $120.00        $9,000    $9,600     +$600   +6.7%
[$] AUD         2,480    —              —         $2,480       —
```

Narrow row:

```
[S] BHP.AX                              $11,325
    ASX                          +$1,200 +11.9%
    250 shares
```

When `gainLossPercent` is `nil`, only the dollar gain renders (or `—` per existing rules). No new nil paths to plumb. Accessibility labels updated: `…, gain of $1,200, up 11.9%`.

The existing responsive rule is unchanged — `Table` on macOS / iOS regular size class, `List` of `PositionRow`s on iOS compact size class.

---

## Section 5 — Wiring in `InvestmentStore`

### New state

```swift
@Observable @MainActor
final class InvestmentStore {
  // existing: values, dailyBalances, positions, valuedPositions, totalPortfolioValue, ...
  private(set) var accountPerformance: AccountPerformance?
  // ...
}
```

`accountPerformance` is set at the end of `loadAllData(...)`, refreshed on `reloadPositionsIfNeeded(...)` (after a trade is recorded) and on `setValue(...)` / `removeValue(...)` for the legacy path.

### `loadAllData(...)` flow

```swift
func loadAllData(accountId: UUID, profileCurrency: Instrument) async {
  loadedHostCurrency = profileCurrency
  await loadValues(accountId: accountId)
  if hasLegacyValuations {
    await loadDailyBalances(accountId: accountId)
    accountPerformance = AccountPerformanceCalculator.computeLegacy(
      dailyBalances: dailyBalances, values: values, instrument: profileCurrency)
  } else {
    await loadPositions(accountId: accountId)
    await valuatePositions(profileCurrency: profileCurrency, on: Date())
    do {
      let txns = try await fetchAllTransactions(repository: transactionRepository!)
      accountPerformance = try await AccountPerformanceCalculator.compute(
        accountId: accountId, transactions: txns,
        valuedPositions: valuedPositions,
        profileCurrency: profileCurrency,
        conversionService: conversionService)
    } catch {
      logger.warning(
        "AccountPerformance unavailable: \(error.localizedDescription, privacy: .public)")
      accountPerformance = nil
      self.error = error
    }
  }
}
```

`fetchAllTransactions` already exists for the cost-basis snapshot path; it's reused. When the SQL slice lands this becomes a single-query call, but the calculator's signature is unchanged.

### `positionsViewInput(...)` plumbing

The existing `positionsViewInput(title:range:)` gains one new line:

```swift
return PositionsViewInput(
  title: title,
  hostCurrency: hostCurrency,
  positions: rowsWithCost,
  historicalValue: series,
  performance: accountPerformance     // new
)
```

### `valuatePositions(...)` callbacks

`reloadPositionsIfNeeded(...)` re-runs `valuatePositions(...)` and now also re-runs the position-tracked compute. About 10 lines of additions.

### Concurrency

`AccountPerformanceCalculator.compute(...)` is `async` because it calls `conversionService.convert(...)` for each cash flow leg. It is not `@MainActor` — it inherits the caller's isolation. The `accountPerformance` write happens back on `InvestmentStore` (`@MainActor`).

`IRRSolver` is `Sendable` (enum with static methods, no state), synchronous, no I/O.
`AccountPerformance` and `CashFlow` are `Sendable` (immutable structs of `Sendable` fields).

### Deletions

`InvestmentStore+PositionsInput.swift:88-203` — `annualizedReturnRate(currentValue:)` and helpers (`BalancePoint`, `RateBracket`, `BracketResult`, `futureValue`, `bracketReturnRate`, `binarySearchReturnRate`).

`Features/Investments/Views/InvestmentSummaryView.swift` — superseded by `AccountPerformanceTiles`.

---

## Section 6 — Testing strategy

### `IRRSolverTests` (pure unit, no backend)

- Convergence on canonical patterns: single deposit + hold + grow 10% → 10% p.a.; multi-deposit cumulative case.
- Negative-return path (deposit $100, now $90 a year later → ≈ −10% p.a.).
- Zero growth (deposit then full withdrawal at same value).
- Cross-checks: IRR within 0.1% of Modified Dietz for short/simple patterns; IRR diverges from MD as flows lengthen / accelerate (sanity check that NR is doing real work).
- Edge cases returning `nil`: empty flows; flows span < 1 day; pathological alternating signs that trigger bisection fallback.
- Determinism: same inputs → same output bit-for-bit (pure `Decimal` math).

### `AccountPerformanceCalculatorTests` (pure unit, mocked conversion service)

- §2 rule coverage:
  - Opening balance only → one flow; `currentValue == flow`; gain 0.
  - Pure trade (two `.trade` legs same account) → no flow; gain reflects price drift.
  - Cross-account `.trade` misuse → flow on each side; cost basis still set correctly via classifier.
  - Same-currency transfer in then out → two flows; nets correctly.
  - Cross-currency transfer in (source AUD, dest USD account, profile AUD) → flow in destination at source's converted amount on date.
  - Trade with `.expense` fee leg same account → no flow (intra-account).
  - `.income` leg standalone (dividend) → no flow; reflected via V_now.
  - `.expense` leg standalone (platform fee) → no flow.
- Edge cases: empty transactions → all-zero/nil; single flow same day as terminal → `p.a.=nil`; first flow > 1 day ago, no growth → `p.a.=0`.
- Failure propagation: conversion service throws on one flow → calculator throws → caller marks `accountPerformance = nil`.

### `AccountPerformanceCalculatorLegacyTests` (pure unit, synchronous)

- Replicate a few existing `InvestmentStore.annualizedReturnRate` test cases against `computeLegacy(...)` and assert agreement within 0.1% (regression guard against the day-precise compounding fix).
- Edge: empty `values` → all-nil `AccountPerformance`.

### `ValuedPositionTests` (pure unit, additions)

- `gainLossPercent` for normal case (positive, negative, zero).
- `nil` when `value` missing, `costBasis` missing, or `costBasis.quantity == 0`.
- Sign preservation (CLAUDE.md rule): `−$50` value vs `+$50` cost → `−200%`, not `200%`.

### `InvestmentStoreTests` (existing pattern, real backend)

- `loadAllData(...)` populates `accountPerformance` for both legacy and position-tracked paths.
- `reloadPositionsIfNeeded(...)` after a trade refreshes `accountPerformance`.
- `setValue(...)` / `removeValue(...)` on the legacy path refresh `accountPerformance`.
- Conversion failure path: `accountPerformance == nil` and `error != nil`.

### UI render tests (`#Preview` + `mcp__xcode__RenderPreview`)

- `AccountPerformanceTiles` previews: gain / loss / zero / unavailable / mixed-availability variants.
- `PositionRow` previews: gain $/% rendering for positive, negative, missing-cost-basis cases.
- Existing `PositionsTable` and `PositionsView` previews extended with `performance:` non-nil to verify tile-strip swap.

No new XCUITest needed — all user-visible changes are pure rendering of new fields with no new gestures or flows. Existing `MoolahUITests_macOS` previews of `InvestmentAccountView` cover the integration smoke at the screen level.

---

## File roster

**New files (5):**

- `Domain/Models/AccountPerformance.swift`
- `Domain/Models/CashFlow.swift`
- `Shared/IRRSolver.swift`
- `Shared/AccountPerformanceCalculator.swift`
- `Shared/Views/Positions/AccountPerformanceTiles.swift`

**New tests (3):**

- `MoolahTests/Shared/IRRSolverTests.swift`
- `MoolahTests/Shared/AccountPerformanceCalculatorTests.swift`
- `MoolahTests/Shared/AccountPerformanceCalculatorLegacyTests.swift`

**Modified files (7):**

- `Domain/Models/PositionsViewInput.swift` — adds `performance: AccountPerformance?` field.
- `Domain/Models/ValuedPosition.swift` — adds `gainLossPercent` derived property.
- `Features/Investments/InvestmentStore.swift` — adds `accountPerformance` published state and the legacy-path call.
- `Features/Investments/InvestmentStore+PositionsInput.swift` — adds the position-tracked compute call; deletes lines 88–203.
- `Shared/Views/Positions/PositionsView.swift` — header swap (`AccountPerformanceTiles` if performance, else existing `PositionsHeader`).
- `Shared/Views/Positions/PositionsTable.swift` — gain cell renders $ + %.
- `Shared/Views/Positions/PositionRow.swift` — gain caption renders $ + %.

**Deleted files (1):**

- `Features/Investments/Views/InvestmentSummaryView.swift`

---

## Known limitations

1. **Salary / external income recorded as `.income` direct to investment account** looks like free returns rather than contributed capital. Workaround: record as a `.transfer`. Fixing requires a tax-category-or-similar marker on `.income` legs. Out of scope.
2. **Cost basis excludes brokerage fees** until issue [#558](https://github.com/ajsutton/moolah-native/issues/558) lands. The account-level `currentValue − contributions` math is fee-aware via the cash balance, but per-position `gainLossPercent` will under-count cost basis on traded positions in the same way it does today.
3. **Single `.trade` leg with no counterpart** records a position with zero cost basis; account-level gain looks like "free value". Honest depiction of the data, not a design flaw — same effect as recording an `.income` leg of the instrument.
4. **Dividends are not attributed to the position that paid them.** Per-position rows show only unrealized capital gain. Dividends roll up into the account-level number via the cash balance. Would need a new model link from `.income` legs to a paying instrument; out of scope.
5. **Pathological IRR cases** (many alternating-sign flows) can have multiple real roots; `IRRSolver` returns the first root Newton–Raphson finds (seeded by Modified Dietz). For typical retail patterns this is the meaningful one. Documented in the solver's docstring.
6. **Cross-currency cash flow conversion** uses the `InstrumentConversionService` rate at the transaction's date. If the rate cache misses and the network fetch fails, the entire `AccountPerformance` is marked unavailable per Rule 11 — no partial sums are shown.

---

## Open questions

None at design time. Implementation-time judgement calls (e.g. the exact Newton–Raphson tolerance, the fallback bisection range, the SwiftUI primitive for the tile-strip layout) are deferred to the implementation plan.
