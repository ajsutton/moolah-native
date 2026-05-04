# Trades-Mode Historical Net-Worth Contribution — Design

**Date:** 2026-05-04
**Status:** Draft, pending review
**Tracking issue:** [#738](https://github.com/ajsutton/moolah-native/issues/738)
**Predecessor:**
[`plans/completed/2026-05-04-per-account-valuation-mode-design.md`](completed/2026-05-04-per-account-valuation-mode-design.md)
(Pre-Existing Limitation: Historical Chart, plus §5e).

## Scope

Make trades-mode investment accounts contribute correctly to the historical
net-worth chart by adding a per-day "valued positions over time" fold. For
each trades-mode investment account, compute the held positions
(per-instrument quantities) cumulative through each historical day with
activity, valuate each instrument quantity in the profile instrument using
the historical price for that day (per
`guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 5), and add the result into the
day's `DailyBalance.investmentValue` and `netWorth`.

The current value (today's number) is already correct for trades-mode
accounts via `PositionsValuator`; only the *historical series* is broken.

## Motivation

PR series #731–#736 introduced the per-account `ValuationMode` toggle
(`recordedValue` / `calculatedFromTrades`). PR #735 wired the daily-balance
fold to filter `fetchInvestmentAccountIds` by mode so trades-mode accounts
no longer leak stale snapshots into the historical chart. This left a
documented hole: there is no equivalent fold for *trade-derived position
market values over time*. A trades-mode account with no snapshots and only
trades silently contributes zero (or only the cash transfer leg of each
trade) to the historical net-worth chart. The chart is therefore
inaccurate for any user who:

- imports trades from CSV into a fresh investment account, then flips it to
  trades mode, **or**
- creates a new investment account (which now defaults to
  `.calculatedFromTrades` after PR #736).

Issue #738 calls this out as the natural next step now that the toggle
itself is shipped and stable.

## Goals

- For every trades-mode investment account, the historical net-worth chart
  reflects the value of its held positions on every historical day with
  activity, using historical prices for that day.
- Snapshot-mode accounts continue to contribute via the existing
  `applyInvestmentValues` fold without behavioural change.
- Mixed-mode profiles (some accounts in each mode) sum both contributions
  cleanly into a single `investmentValue` per day.
- Per-day Rule 11 contract for the new fold matches the existing
  `applyInvestmentValues` pattern (log + skip the override on per-day
  conversion failure; `CancellationError` rethrows immediately). This is a
  conscious match of the in-tree pattern; tightening Rule 11 compliance
  for the daily-balance pipeline is a separate concern (see Out-of-Scope).
- All historical conversions go through `InstrumentConversionService` on
  the day's `Date` (Rule 5 / Rule 10 / Rule 8 fast path).
- SQL plan-pinning maintained — no new full table scans introduced; the
  new SELECT mirrors the existing snapshot-mode predicate and uses the
  same shape.

## Non-Goals

- **No change to the forecast tail.** Forecast days continue to use the
  `generateForecast` extrapolation. Trades-mode accounts do not contribute
  to forecast days under this change. (Trade transactions are not
  recurring, so the forecast pipeline never sees them; today's positions
  carry forward to the forecast tail only via the existing position-book
  state, which the forecast already handles for non-investment accounts.)
- **No new conversion service.** The fold uses the existing
  `InstrumentConversionService` — same path that
  `PositionsHistoryBuilder` and `PositionsValuator` already use.
- **No change to `PositionsValuator`.** The current-value path is
  unchanged.
- **No change to `applyInvestmentValues`** (the snapshot fold).
- **No change to per-account chart on `InvestmentAccountView`**
  (`PositionsHistoryBuilder` already covers it).
- **No tightening of `applyInvestmentValues`'s pre-existing Rule 11
  deviation** (it logs + leaves the day's investmentValue at whatever
  walkDays produced, rather than dropping the day from the dict). The new
  fold matches that pattern for consistency; a separate issue can address
  Rule 11 compliance for the entire daily-balance pipeline.
- **No new `Position`-history schema or persisted series.** The series is
  computed Swift-side per request from the existing `transaction_leg`
  rows (same source of truth as `walkDays` itself), so there is no new
  persisted state, no new sync surface, and no new migration.

## Design

### 1. New SQL fetch — trades-mode investment account ids

Add a sibling of `fetchInvestmentAccountIds`
(`Backends/GRDB/Repositories/GRDBAnalysisRepository+DailyBalancesInvestmentValues.swift`):

```swift
static func fetchTradesModeInvestmentAccountIds(database: Database) throws -> Set<UUID> {
  let rows = try Row.fetchAll(
    database,
    sql: """
      SELECT id FROM account
      WHERE type = 'investment' AND valuation_mode = 'calculatedFromTrades'
      """)
  // ... same decode as fetchInvestmentAccountIds ...
}
```

The two SELECTs differ only on the `valuation_mode = '…'` literal — kept
as a separate function for `guides/DATABASE_CODE_GUIDE.md` §4 (no
dynamically composed `sql:` arguments). The plan is the same shape as
`fetchInvestmentAccountIds` (a small-table scan); no new index required.

### 2. Aggregation type carries both account-id sets

Extend `DailyBalancesAggregation`
(`+DailyBalances.swift`) with one extra field:

```swift
struct DailyBalancesAggregation: Sendable {
  // existing fields ...
  let investmentAccountIds: Set<UUID>            // recorded-value (existing)
  let tradesModeInvestmentAccountIds: Set<UUID>  // new
  // ...
}
```

`investmentAccountIds` keeps its current meaning (recorded-value only) so
that `accountsFromTransfers` continues to be populated only for the
snapshot mode — exactly as PR #735 designed. The new field is consumed
only by the new fold (see §4) and the assembly context (see §3).

`fetchDailyBalancesAggregation`
(`+DailyBalancesAggregation.swift`) calls the new fetch alongside
`fetchInvestmentAccountIds` and threads the result onto the struct.

### 3. Assembly context exposes both sets

Extend `DailyBalancesAssemblyContext` (`+DailyBalances.swift`) with the
trades-mode set so the new fold can take it from a stable context object
rather than a free parameter (matches the existing pattern of carrying
`investmentAccountIds`, `instrumentMap`, `profileInstrument`,
`conversionService` in one struct):

```swift
struct DailyBalancesAssemblyContext: Sendable {
  let investmentAccountIds: Set<UUID>            // recorded-value (existing)
  let tradesModeInvestmentAccountIds: Set<UUID>  // new
  let instrumentMap: [String: Instrument]
  let profileInstrument: Instrument
  let conversionService: any InstrumentConversionService
}
```

`seedPriorBook`, `walkDays`, and `applyDailyDeltas` continue to read only
`investmentAccountIds` (recorded-value) for `accountsFromTransfers`
membership — none of those helpers need to know about the trades-mode
set, because trades-mode accounts contribute via the new fold instead.

### 4. New fold — `applyTradesModePositionValuations`

Lives next to `applyInvestmentValues` in
`+DailyBalancesInvestmentValues.swift` so the two folds share a file (and
a SwiftLint budget). Public entry point:

```swift
static func applyTradesModePositionValuations(
  priorAccountRows: [DailyBalanceAccountRow],
  accountRows: [DailyBalanceAccountRow],
  to dailyBalances: inout [Date: DailyBalance],
  context: DailyBalancesAssemblyContext,
  handlers: DailyBalancesHandlers
) async throws
```

Algorithm:

1. **Early return** if `context.tradesModeInvestmentAccountIds` is empty
   or `dailyBalances` is empty.
2. **Pre-fold priors** (rows with `t.date < :after`) into a per-account,
   per-instrument cumulative dict
   `var positions: [UUID: [Instrument: Decimal]] = [:]`. Skip rows whose
   `accountId` is not in `tradesModeInvestmentAccountIds`. Decoding the
   raw `Int64` `qty` → `Decimal` matches `applyDailyDeltas` exactly
   (single `InstrumentAmount(storageValue:instrument:).quantity` step,
   so the storage-unit semantics are pinned in one place).
3. **Group post-cutoff rows by local-startOfDay key.** Use
   `Calendar.current.startOfDay(for: row.sampleDate)` (matching
   `walkDays`'s `dayKey` math — Rule 10 same-`startOfDay` normalization).
   Skip rows whose `accountId` is not in
   `tradesModeInvestmentAccountIds`.
4. **Walk `dailyBalances.keys.sorted()`** in date order. For each
   `dayKey`:
   1. Apply the day's grouped trades-mode rows to the cumulative
      `positions` dict.
   2. Skip the day if `positions` is empty (no trades-mode account has
      ever held anything yet).
   3. Convert per-account-per-instrument positions into a single
      `InstrumentAmount` total via `sumTradesModePositions(...)` — see
      §5. Conversion runs on `dayKey` (the day's local-startOfDay,
      Rule 10), via the conversion service, with the Rule 8 fast path
      for same-instrument positions.
   4. On `CancellationError`, rethrow (no logging).
   5. On any other thrown error,
      `handlers.handleInvestmentValueFailure(error, dayKey)` and
      `continue` — same per-day error contract as
      `applyInvestmentValues`.
   6. Otherwise, **add** the converted total to the day's existing
      `investmentValue` (which is `nil` if no snapshot fold ran for the
      day, else the snapshot total) and recompute `netWorth = balance +
      investmentValue`. Build a fresh `DailyBalance` (the type is a
      struct; mutate via reconstruction).

Per-day error contract is reused from
`DailyBalancesHandlers.handleInvestmentValueFailure` — the existing
callback already carries `(Error, Date)`. The new fold logs through the
same handler; production callers route into the same `os.Logger`
category that the snapshot fold uses.

### 5. Conversion helper — `sumTradesModePositions`

Mirrors `sumInvestmentValues`, file-private:

```swift
private static func sumTradesModePositions(
  positions: [UUID: [Instrument: Decimal]],
  on date: Date,
  profileInstrument: Instrument,
  conversionService: any InstrumentConversionService
) async throws -> InstrumentAmount?
```

For each `(accountId, [Instrument: Decimal])`, for each
`(instrument, qty)`:

- If `instrument.id == profileInstrument.id`, add `qty` to the running
  `Decimal` total (Rule 8 fast path).
- Otherwise call `conversionService.convert(qty, from: instrument, to:
  profileInstrument, on: date)` and add the result.

A failed convert throws to the caller, which routes to
`handleInvestmentValueFailure` per the per-day contract. Returns
`InstrumentAmount(quantity: total, instrument: profileInstrument)`. On a
warm cache the per-day cost is O(distinct instruments held that day),
which is bounded.

### 6. Wire the new fold into `assembleDailyBalances`

Inside `assembleDailyBalances` (`+DailyBalances.swift`), after the
existing `applyInvestmentValues` call:

```swift
try await applyInvestmentValues(
  aggregation.investmentValues,
  to: &dailyBalances,
  context: context,
  handlers: handlers)

try await applyTradesModePositionValuations(
  priorAccountRows: aggregation.priorAccountRows,
  accountRows: aggregation.accountRows,
  to: &dailyBalances,
  context: context,
  handlers: handlers)
```

Order is significant only in that the second fold *adds* to whatever the
first fold left in `investmentValue`. Either ordering would produce the
same arithmetic total since they touch disjoint account sets and addition
is commutative; running the new fold *after* the snapshot fold keeps the
log message ordering consistent with the read order (snapshots → trades).

`bestFit` regression runs after both folds (same line as today). The
forecast extrapolation runs after that, unchanged — see Non-Goals on the
forecast carve-out.

### 7. Edge cases

- **No trades-mode accounts in the profile.** The new fetch returns an
  empty set; the new fold early-returns; behaviour is bit-identical to
  today.
- **Trades-mode account with only a transfer leg (cash deposited but
  never traded).** The cash is in the profile instrument (or some other
  fiat). The fold sums it via the Rule 8 fast path (or via FX
  conversion). The day's investmentValue picks up the cash. This is
  correct: the cash on the investment account is part of the account's
  value.
- **Trades-mode account with a buy on day D and no other activity.** Day
  D appears in `dailyBalances` (walkDays sees the trade legs as account
  rows). The fold valuates the position on day D using day D's price.
  Days after D with other-account activity carry forward the position
  via the cumulative dict; their valuations use that day's price.
- **Stock not yet listed on day D (price-cache miss).** Conversion
  throws → fold logs via `handleInvestmentValueFailure` → fold leaves
  the day's existing `investmentValue` (snapshot fold's contribution, or
  `nil`) untouched. The chart line for that day reflects whatever made
  it through the snapshot fold; the trades-mode contribution drops just
  for that day.
- **Profile instrument changes mid-history.** Out of scope (no profile
  flow currently allows this), and would require re-running the pipeline
  with a new profile instrument anyway.
- **Mixed-mode profile.** Snapshot and trades-mode accounts are
  partitioned by `valuation_mode`; the snapshot fold reads
  `recorded-value` accounts only; the trades fold reads
  `calculated-from-trades` accounts only. Both fold totals add into one
  `investmentValue` per day.
- **Mode flip mid-window.** A user flipping an account from snapshot to
  trades changes the SQL classification; the next pipeline run will
  classify the account into the new set. The historic chart will
  re-render under the new mode (snapshot contributions disappear; trades
  contributions appear). This matches today's mode-flip semantics — same
  surface, no special handling.
- **Two-trade same-day (BUY + SELL on the same day).** SQL `SUM` over
  legs grouped by `(day, account, instrument, type)` already nets these
  in `accountRows`. The fold applies the netted row exactly once per
  `(day, account, instrument, type)` group; cumulative state stays
  consistent.

### 8. SQL plan-pinning test

Add one pinning test next to the existing daily-balance pins
(`MoolahTests/Backends/GRDB/DailyBalancesPlanPinningTests.swift`):

```swift
@Test
func fetchTradesModeInvestmentAccountIdsAvoidsScanWhenSelectiveOrUsesAcceptableScan() throws {
  // ... assert plan shape matches fetchInvestmentAccountIds — both are
  // selective small-table reads; the SQL planner typically emits
  // SCAN account on a tiny table or USING INDEX on the account-type
  // index if/when one exists. Either is acceptable; this test pins the
  // plan to whatever the existing snapshot-mode predicate produces so a
  // future regression that diverges from the established shape is
  // visible. ...
}
```

The test mirrors the existing `fetchInvestmentAccountIdsAvoidsScan…`
pattern (or the closest equivalent in
`DailyBalancesPlanPinningTests`) — same plan-string capture, same
indexed-vs-scan assertion.

### 9. Repository contract / aggregation contract tests

Add tests to the existing
`MoolahTests/Backends/GRDB/GRDBAnalysisRepositoryDailyBalancesTests.swift`
(or its closest sibling) covering:

1. **Trades-mode account with one buy of N shares at price P on day D.**
   Day D's `investmentValue` ≈ `N * P`. Day D+1 (if present in
   `dailyBalances` due to other activity) carries the position forward
   and revaluates at day D+1's price.
2. **Two trades-mode accounts, both with positions on day D.**
   `investmentValue` sums both contributions.
3. **One trades-mode + one recorded-value account on day D.** Day D's
   `investmentValue` = (recorded snapshot total) + (trades-mode
   valuation). `netWorth` reflects both.
4. **Rule 11 per-day failure scoping** — a `DateBasedFailingConversion`
   service that throws only on day D leaves day D's investmentValue at
   whatever the snapshot fold produced (or `nil` if no snapshot fold)
   and *does not* affect day D-1 or D+1. The
   `handleInvestmentValueFailure` callback fires exactly once with
   `(error, dayKey: D)`.
5. **Rule 10 same-startOfDay normalization** — a trade transaction at
   23:59:59 local on day D and a trade at 00:00:01 local on day D+1
   apply on the correct days; `Calendar.current.startOfDay`-keyed
   comparisons match `walkDays`'s key.
6. **No trades-mode accounts ⇒ no behaviour change** — fold is a no-op;
   `investmentValue` reflects only the snapshot fold; pinning tests for
   the existing path stay green.
7. **Empty `dailyBalances` ⇒ no-op** — nothing to fold over; no logger
   output.
8. **CSV-imported trade with a `.transfer` cash leg + a `.trade`
   position leg.** Cumulative position picks up both legs; cash leg adds
   via Rule 8 fast path (when in profile instrument), or FX otherwise;
   position leg adds via stock-price conversion.
9. **Trades-mode account that was previously in recorded mode** — flip
   captured by next pipeline run; chart flips between contributions.

`DateBasedFixedConversionService` is the canonical test double for
date-sensitive conversions per
`guides/INSTRUMENT_CONVERSION_GUIDE.md` §1; we use it (and a
`DateBasedFailingConversion` extension) here.

### 10. Logging

The fold reuses
`DailyBalancesHandlers.handleInvestmentValueFailure: @Sendable (Error,
Date) -> Void` — same callback the snapshot fold uses. The production
caller wires this to its existing `Logger`
(`subsystem: "com.moolah.app", category: "GRDBAnalysisRepository"` or
the closest existing category). No new logger category required.

### 11. Performance

Per-day work after the fold:
- Pre-fold priors: O(N_priors), one-shot, where `N_priors` is the
  number of trade-relevant pre-cutoff legs (already loaded by the
  existing prior-rows fetch — no new SQL).
- Per day: O(M × I) conversion calls, where M = trades-mode account
  count and I = distinct instruments held. Warm-cache calls are O(1)
  per (instrument, date) tuple via `StockPriceCache` /
  `ExchangeRateCache` / `CryptoPriceCache`. Cold-cache calls pay one
  round-trip per (instrument, date) — the same cost
  `PositionsHistoryBuilder` already pays for the per-account chart.

For a typical user (≤5 trades-mode accounts × ≤10 instruments ×
~365 days = ~18 000 conversion calls per request) this is well within
the cached-rate budget. We do NOT introduce parallelism (the fold uses
sequential `await`, matching `applyInvestmentValues` and
`PositionsHistoryBuilder`); switching to a `TaskGroup` is a
self-contained change if profiling later shows it's user-visible.

The new SQL fetch (`fetchTradesModeInvestmentAccountIds`) adds one
small-table read inside the existing `database.read` snapshot; cost is
the same shape as `fetchInvestmentAccountIds`.

## Out-of-Scope Followups

- Tightening `applyInvestmentValues`'s pre-existing Rule 11 deviation
  (logging + skipping the day's override on conversion failure rather
  than dropping the entire day from `dailyBalances`).
- Extending the trades-mode contribution onto the *forecast tail* via
  `Date()` valuation — would mirror Rule 7's service-level clamp behaviour
  and could be added without further design.
- A persisted "valued positions over time" series (e.g. for offline
  rendering or sync). The current design recomputes from scratch on every
  request; persistence would only be worthwhile if profiling shows the
  recompute is the bottleneck.
- Parallelising the per-day conversion fan-out via `TaskGroup`.
- Surfacing per-day "this contribution couldn't be computed" markers in
  the chart UI itself (today the chart silently gaps a missing day; the
  on-screen affordance is a separate UI concern).

## Migration & Rollout

Single PR. The change is additive (one new SQL fetch + one new fold) and
behind no flag. Existing recorded-value behaviour is unchanged.
Trades-mode accounts gain accurate historical chart contribution
immediately — there is no observable regression for any existing user
because the *only* behaviour change is "trades-mode accounts now
contribute their position-valuation series to the historical chart on
days they previously contributed zero (or only a transfer leg)."

The rollout matches recent analysis-fold PRs:

1. Open the PR against `main`.
2. Run `code-review`, `database-code-review`,
   `instrument-conversion-review`, `concurrency-review` agents per
   project policy.
3. Add to the merge queue via the `merge-queue` skill.

No CloudKit schema change. No GRDB migration. No new sync surface.
