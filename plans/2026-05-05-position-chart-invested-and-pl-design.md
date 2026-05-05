# Position-Tracked Chart: Invested Amount and Profit/Loss — Design

**Date:** 2026-05-05
**Status:** Draft — round 2 (post-review revisions)

## Scope

The per-account chart on a position-tracked investment account
(`InvestmentAccountView`'s position-tracked branch, rendered by
`PositionsChart`) gains a profit/loss visualisation:

- **Aggregate (all-positions) view** — adds an *invested amount* step line
  (cumulative net contributions to the account, in the profile instrument)
  and a green/red shaded area between the value line and the invested-amount
  line.
- **Per-instrument view** (when a row is tapped) — keeps its existing
  cost-basis dashed line, and adds the same green/red shaded area between
  the value line and the cost-basis line.
- The existing solid-blue area fill underneath the value line is removed
  in both views (it would clash with the new gain/loss area).

The "Current Value" tile in `AccountPerformanceTiles` gains an
`Invested $X` subtitle in the same caption style as the existing P/L `+%`
and Annualised Return `since [date]` subtitles. Source:
`AccountPerformance.totalContributions` (already populated, currently
unused by the tile).

## Motivation

Today's chart shows a solid blue value line over a soft blue area, with a
dashed gray cost-basis step line. Two problems:

1. The cost-basis line is rendered in a colour and weight (`.secondary`,
   `1.5pt` dashed) that visually disappears against the value line's blue
   area fill on real data, where cost basis usually tracks close to value.
   Users miss it entirely.
2. The number a user actually wants to reason about on the aggregate chart
   is *"how much did I put in vs. how much is it worth?"* That is
   cumulative external contributions, not remaining FIFO cost basis. After
   a partial sell, cost basis drops even though invested amount has not
   changed.

`AccountPerformance.totalContributions` already computes the right
aggregate number (used by the P/L tile internally as
`currentValue − totalContributions`), but it is invisible — neither shown
on a tile nor plotted over time.

For a single instrument, cost basis remains the right secondary line
(matches the table's `Cost` column) — but the same gain/loss shading
between value and cost basis communicates the unrealised gain on currently
held lots without making the reader subtract two near-equal numbers.

## Goals

- Aggregate chart shows three concepts: market value, cumulative
  contributions, profit/loss (as a green/red filled area between the
  first two).
- Per-instrument chart shows three concepts: market value, cost basis of
  currently held lots, unrealised P/L (as a green/red filled area between
  the first two).
- The "Current Value" tile shows total contributions as a subtitle.
- Tile and chart agree on the aggregate invested number: the subtitle and
  the chart's right-most `contributions` point are derived from the same
  source so they cannot disagree (see §5).
- Per-day Rule 11 contract is preserved: no aggregate point ever shows a
  partial sum. If contribution conversion fails for any flow, the
  aggregate `contributions` series is unavailable from that flow's date
  forward (see §6).
- All historical contribution conversions go through
  `InstrumentConversionService` on the *transaction date*
  (`guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 5 and Rule 8 fast path).
- Conversion-date normalisation: `transaction.date` is passed to the
  conversion service **without** `startOfDay` truncation, matching
  the existing `AccountPerformanceCalculator.extractFlows` contract.
  The day-walk emission uses `calendar.startOfDay(for: now)` to key
  emitted points; these two roles are distinct (emission day-key vs.
  conversion clock-time). The conversion service applies its own
  Rule 10 same-day normalisation internally — callers do not pre-
  truncate. Unit tests cover this by passing a `Date` whose time
  component is non-zero and asserting the resulting amount equals
  the rate configured for that calendar day.

## Non-Goals

- **No new top-level tile.** Total Invested is a subtitle on the
  Current Value tile, not its own card.
- **No change to the legacy manual-valuation chart.**
  `InvestmentChartView` already has all three series and stays as-is.
- **No change to `PositionsValuator`** (the today-only path that
  populates the table's `Value` column).
- **No change to `AccountPerformance` shape or
  `AccountPerformanceCalculator`.** The flow extraction this spec reuses
  for time-series contributions is conceptually identical to
  `AccountPerformanceCalculator.extractFlows`; we factor the helper out
  so it serves both call sites (see §5).
- **No change to the historical net-worth chart**
  (`Domain/Models/DailyBalance.swift` / `walkDays`). Per-account chart
  only.
- **No persisted contribution series.** Re-derived from
  `transaction_leg` rows on each chart load, same as the existing
  cost-basis fold in `PositionsHistoryBuilder`.
- **No new currency-conversion failure UI.** The chart already gaps
  days that fail per-instrument value conversion; contribution-conversion
  failure surfaces through the same legend-only "Unavailable" pattern
  that other charts use today (see §6 for details).

## Design

### 1. Extend `HistoricalValueSeries.Point`

`Domain/Models/HistoricalValueSeries.swift`:

```swift
struct HistoricalValueSeries: Sendable, Hashable {
  struct Point: Sendable, Hashable {
    let date: Date
    /// Market value in `hostCurrency` on this date.
    let value: Decimal
    /// Remaining cost basis of currently-held lots in `hostCurrency`.
    /// Meaningful for both aggregate and per-instrument series.
    let cost: Decimal
    /// Cumulative net external contributions to the account in
    /// `hostCurrency`, evaluated at this date. Populated only for the
    /// aggregate (account-level) series; per-instrument series leave
    /// this `nil`. `nil` does not mean zero — it means "not applicable
    /// at this granularity" or "conversion failure for some flow on or
    /// before this date" (see §6).
    let contributions: Decimal?
  }
  // existing fields unchanged
}
```

`contributions` is `Decimal?` rather than `Decimal` so the
per-instrument series cleanly says "not applicable" without conflating
it with a literal zero contribution. Existing call sites that read
`value` and `cost` are unaffected.

### 2. Builder change — `PositionsHistoryBuilder`

`Shared/PositionsHistoryBuilder.swift` gains cumulative-contribution
tracking on the aggregate path. Per-instrument generation is unchanged.

The contribution tracker uses the same boundary-crossing rule that
`AccountPerformanceCalculator.extractFlows` uses today (a leg in the
account counts as a flow iff `type == .openingBalance` OR the
transaction touches at least one other non-nil `accountId`). To avoid
two divergent copies of that rule, factor the per-leg classifier into
a shared helper:

```swift
// Shared/AccountCashFlows.swift  (new file)
//
// Caseless `enum` (CODE_GUIDE.md §5 — pure namespace).
enum AccountCashFlows {
  /// Returns the host-currency contribution amount for every leg in
  /// `transaction` that belongs to `accountId` and counts as a flow.
  /// A leg counts iff `leg.type == .openingBalance` OR `transaction`
  /// touches at least one other non-nil `accountId`. The
  /// boundary-crossing predicate is evaluated once per transaction
  /// inside this helper so callers cannot duplicate or diverge from
  /// the rule.
  ///
  /// Returns one `Decimal` per qualifying leg (in `hostCurrency`) in
  /// the order legs appear on `transaction`. Empty when no leg
  /// qualifies — distinguishable from a single-zero-leg case if
  /// callers care.
  ///
  /// Throws on the *first* conversion failure (rather than returning
  /// a partial list). Callers decide policy:
  /// `AccountPerformanceCalculator` aborts the whole `compute(...)`
  /// pass; `PositionsHistoryBuilder` marks `state.contributions =
  /// nil` for the rest of the build. Throw-and-rethrow is intentional
  /// — swallowing the error inside the helper would force every
  /// caller to its own policy via a sentinel return shape, which is
  /// less clear at the call site.
  ///
  /// `nonisolated` so call sites that are `@concurrent` (`Positions
  /// HistoryBuilder.build`) do not hop to the main actor per
  /// transaction; the calculator's existing default-isolation call
  /// site is unaffected because `nonisolated` is callable from any
  /// context.
  nonisolated static func flowAmounts(
    for transaction: Transaction,
    accountId: UUID,
    hostCurrency: Instrument,
    service: any InstrumentConversionService
  ) async throws -> [Decimal]
}
```

The implementation walks `transaction.legs` in order. After each
qualifying-leg `await service.convert(...)` call, the helper invokes
`try Task.checkCancellation()` so a dismissed view's task tears
down promptly even on a high-leg-count transaction (per
`guides/CONCURRENCY_GUIDE.md` §3 — check cancellation after every
suspension point in a loop).

`AccountPerformanceCalculator.extractFlows` is rewritten to call
`AccountCashFlows.flowAmounts(for:)` once per transaction, then expand
the returned list into `CashFlow(date: transaction.date, amount:)`
records (preserving per-leg granularity for IRR / Modified Dietz
weights). `PositionsHistoryBuilder` calls the same helper inside its
per-day fold and folds the returned list into the running total.

Both call sites end up with a single source of truth for the
boundary-crossing predicate, leg iteration order, and
on-transaction-date conversion. The shared helper has its own
test suite (§Tests) so its contract is regression-locked
independently of either caller.

The builder's existing `BuildState` is exclusively owned by the
single `@concurrent` build task — no other task ever holds a
reference to it, so its `inout`-across-`await` mutation pattern in
the existing per-day loop is safe. The new field continues that
ownership invariant:

```swift
private struct BuildState {
  // existing fields unchanged
  /// Running cumulative contributions in `hostCurrency`. `nil` once
  /// any contribution conversion has thrown — the latch is sticky
  /// and never reset within a build, so the entire aggregate
  /// `contributions` series renders `nil` after a failure (Rule 11
  /// — see §6).
  var contributions: Decimal? = 0
}
```

A single `Decimal?` replaces the prior two-field `Decimal` +
`Bool` design: the type system now enforces the invariant
"unavailable contributions have no running value" instead of
relying on prose. The contribution loop in `apply(transaction:…)`
becomes:

```swift
guard let running = state.contributions else {
  // Already unavailable — sticky latch; do not call the helper
  // (avoids redundant network/cache traffic post-failure and
  // matches the §6 "from failure forward" guarantee).
  return
}
do {
  let amounts = try await AccountCashFlows.flowAmounts(
    for: transaction, accountId: accountId,
    hostCurrency: hostCurrency, service: conversionService)
  try Task.checkCancellation()  // post-await hygiene
  if !amounts.isEmpty {
    state.contributions = running + amounts.reduce(0, +)
  }
} catch is CancellationError {
  throw CancellationError()  // propagate; outer loop handles teardown
} catch {
  state.contributions = nil  // sticky latch — see §6
  logger.warning(
    "AccountCashFlows.flowAmounts failed for txn \(transaction.id, privacy: .public) on \(transaction.date, privacy: .public): \(error.localizedDescription, privacy: .public)"
  )
}
```

The `guard` at the top is the explicit sticky-latch short-circuit:
once `state.contributions == nil` the helper is not called for any
later transaction in this build, so the prose claim "later
transactions are not converted" is enforced by the code shape
rather than by ordering convention. Pre-fold and the per-day fold
share this code path.

`emitDailyPoints` writes:

```swift
state.total.append(
  HistoricalValueSeries.Point(
    date: day, value: aggValue, cost: aggCost,
    contributions: state.contributions))
```

Per-instrument emission passes `contributions: nil` unconditionally.

Pre-fold mirrors the existing cost-basis pre-fold: `preFoldHistory`
walks transactions strictly before the visible window's `start` and
applies the same contribution helper. By the time the visible window
emits its first point, `state.contributions` either reflects every
prior contribution or is `nil` (sticky after any pre-window
conversion failure).

**Rule 11 cumulative-sum semantics (clarified per round-1 review):**
A cumulative running total whose Nth point includes a possibly-bad
addend is wrong at every Nth-and-later point. The helper-throw +
sticky-`nil` design therefore makes **every** point's
`contributions` go to `nil` from the moment of failure forward —
including the rest of the visible window. Earlier points retained
in `state.total` keep their populated values; those points were
fully valid at the time they were emitted. (No retroactive rewrite,
because the pre-failure points were genuinely correct at their
emission time.)

### 3. Chart rendering — shared gain/loss area

`Shared/Views/Positions/PositionsChart.swift`:

The chart picks a *baseline* value per point based on which view is
active:

- Aggregate: `point.contributions` (already `Decimal?`).
- Per-instrument: `point.cost` (lifted into an `Optional` purely so
  the rendering helper has a uniform signature; cost is always
  populated for per-instrument points).

The render is driven per point: when a point's baseline is nil, only
the value line is drawn for that day (no area, no baseline line
segment); otherwise the value line, baseline line, and gain/loss
area are all drawn. Adjacent days where one has a nil baseline and
the other does not produce a clean step rather than an interpolated
crossing, because the baseline line uses `.stepEnd` interpolation
and the area marks are scoped per data point.

For each point with a non-nil baseline, two stacked area marks are
emitted:

```swift
// gain segment: visible only when value >= baseline
AreaMark(
  x: .value("Date", point.date),
  yStart: .value("Baseline", baseline),
  yEnd: .value("Top", max(point.value, baseline))
)
.foregroundStyle(.green.opacity(0.20))

// loss segment: visible only when value < baseline
AreaMark(
  x: .value("Date", point.date),
  yStart: .value("Bottom", min(point.value, baseline)),
  yEnd: .value("Baseline", baseline)
)
.foregroundStyle(.red.opacity(0.20))
```

When `value == baseline` both segments collapse to height zero. At a
crossing between two adjacent points, both segments meet at the
baseline so the colour transition has no gap or overdraw. (The
crossing is rendered at the resolution of one daily sample — the chart
does not interpolate sub-day crossings, but daily fidelity is
sufficient for a multi-month view and matches the data's natural
resolution.)

The solid blue value-area fill (`AreaMark` with
`Color.accentColor.opacity(0.18)` at `PositionsChart.swift:73`) is
removed.

The dashed gray baseline line is unchanged in style (`.secondary`,
`1.5pt`, dash `[4, 3]`, `.stepEnd` interpolation). Only its data
source switches per mode.

The legend gains a third entry for the gain/loss area. Order:
`Value` / `<baseline label>` / `Profit/Loss`.

The Profit/Loss entry is a two-tone swatch — a small green block
over a small red block — paired with the literal label
`Profit/Loss`. Per UI_GUIDE.md §5 (color must never be the sole
information channel), the label itself is the non-color pairing;
the spec **forbids** splitting this into two separate "Gain" /
"Loss" rows under the same swatch, since that would communicate the
gain-vs-loss state through color alone.

Accessibility:

- The two coloured blocks inside the swatch are
  `.accessibilityHidden(true)` so VoiceOver does not read their
  individual colour names.
- The combined swatch + label element is
  `.accessibilityElement(children: .combine)` with an
  `.accessibilityLabel("Profit and Loss area")` (or `"Profit and
  Loss area, unavailable"` when greyed out). VoiceOver order
  follows the visual order: Value → Baseline → Profit/Loss.

Dark mode: SwiftUI's `.green` / `.red` are semantic colours that
adapt automatically. The 0.20 opacity was chosen for legibility
against the chart's plot-area background; the
`reviewing-ui-with-preview` skill is used during implementation to
verify both schemes before locking the value (light mode tends to
read denser at the same alpha).

Localisation: this PR keeps the existing project convention of
plain-English literals in `Text(...)` (matches sibling
`InvestmentChartView` and the existing `PositionsChart`'s `"Cost
basis"` / `"Value"`). Introducing `LocalizedStringKey` is a
project-wide migration and is out of scope here; new strings stay
consistent with the file's neighbours.

### 4. Tile change — `AccountPerformanceTiles`

`Shared/Views/Positions/AccountPerformanceTiles.swift`'s
`currentValueTile` switches from the no-subtitle `Tile` init to the
subtitle-bearing init. `AccountPerformance.totalContributions` is
typed `InstrumentAmount?` (matching `currentValue` and `profitLoss`
— `AccountPerformance.swift:17`); the implementation must guard the
optional everywhere it is read:

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
    investedSubtitle
  }
  .accessibilityLabel(currentValueAccessibilityLabel)
}

@ViewBuilder private var investedSubtitle: some View {
  if performance.firstFlowDate != nil {
    if let contributions = performance.totalContributions {
      Text("Invested \(contributions.formatted)")
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    } else {
      // flows extracted but conversion failed — show explicit
      // unavailable rather than silently dropping the line.
      // The "Invested —" form (label kept, value as em-dash) is
      // intentional and **does not** match the P/L tile's bare
      // `—`: the subtitle has no other label nearby, so the prefix
      // is needed for the row to make sense in isolation.
      Text("Invested —")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
  }
}
```

Visibility:

- `firstFlowDate == nil` → no flows yet (fresh account, or
  intra-account-only activity); subtitle hidden. Matches how the
  Annualised Return tile hides its `since X` subtitle in the same
  state.
- `firstFlowDate != nil`, `totalContributions != nil` → render
  `Invested $X`.
- `firstFlowDate != nil`, `totalContributions == nil` → render
  `Invested —` (Rule 11 — explicit unavailability rather than a
  partial sum or a hidden subtitle, matching how the P/L tile
  renders `—` for `profitLoss == nil`).
- `currentValue == nil` (Rule 11 unavailability) → main line shows
  `Unavailable`, subtitle still shows when flows exist. The two
  fields fail independently per `AccountPerformanceCalculator
  .assemble`'s "Row 6" branch.

`currentValueAccessibilityLabel` extends to speak both numbers,
respecting the same optional shape:

```swift
private var currentValueAccessibilityLabel: String {
  let main: String
  if let value = performance.currentValue {
    main = "Current Value: \(value.formatted)"
  } else {
    main = "Current Value: Unavailable"
  }
  guard performance.firstFlowDate != nil else { return main }
  if let contributions = performance.totalContributions {
    return "\(main), Invested: \(contributions.formatted)"
  } else {
    return "\(main), Invested: Unavailable"
  }
}
```

`InstrumentAmount.formatted` uses `.currency(code: instrument.id)`,
which Foundation localises into the user's spoken-currency phrasing
under VoiceOver (e.g., "one thousand two hundred thirty-four
dollars"). The accessibility label inherits that behaviour without
introducing a new formatter.

### 5. Single source of truth for "invested amount"

The tile subtitle and the right-most chart `contributions` point both
need to read the same number. Two paths feed them today:

- **Tile**: `AccountPerformance.totalContributions`, computed by
  `AccountPerformanceCalculator.compute` (an async, conversion-aware
  pass over the same `transaction_leg` rows).
- **Chart**: the new `BuildState.contributions` running total inside
  `PositionsHistoryBuilder.build`.

Because both will now route their per-leg conversions through
`AccountCashFlows.flowAmounts(for:)` (§2), they cannot disagree on a
per-flow basis. The tile and chart will still differ if one sees a
conversion failure that the other does not — that is, if the chart
load and the tile load happen across a network state change. In that
case the tile shows `Invested —` and the chart shows the gain/loss
area unavailable, or vice-versa; both render their failure state
honestly, and a refresh resyncs them. This is the same convergence
model the rest of the per-account view uses today.

### 6. Failure modes (Rule 11 contract)

Three independent conversion failure surfaces feed this chart:

1. **Per-day per-instrument value conversion** (existing). Already
   handled by `emitDailyPoints` — the failing day is dropped from
   `state.total`. The new contributions logic does not change this.
2. **Per-flow contribution conversion** (new). On any conversion
   failure, the sticky latch in §2 sets `state.contributions = nil`
   and never resets. Because transactions are walked in chronological
   order (existing `sortedTxns` invariant in `PositionsHistoryBuilder
   .build`), this guarantees:

   - Every emitted point **before** the failure has a populated
     `contributions` value that genuinely reflects the cumulative
     contributions as of that date — no retroactive rewrite is
     needed because every flow up to that date was successfully
     converted.
   - Every emitted point **on or after** the failure date carries
     `contributions: nil`, including the right-most point in the
     visible window. There is no scenario where a "good" right-most
     point follows a "failed" mid-history point (sticky latch +
     chronological walk).

   The legend therefore reads the right-most visible point's
   `contributions` and toggles between `Profit/Loss` (populated) and
   `Profit/Loss unavailable` (`nil`) based on that single check —
   sufficient and necessary.

   The `Value` line and the cost-basis line are independent of this
   latch and continue to render normally (subject to their own
   per-day `value` failures, handled separately by failure-mode 1).
3. **`AccountPerformanceCalculator` flow extraction failure**. Already
   handled — the tile shows `Profit/Loss: —` and `Annualised Return:
   —`. With the new subtitle, when `currentValue` is unavailable but
   contributions extraction succeeded (the `assemble` "Row 6" branch),
   the subtitle still shows; this is unchanged from current behaviour.

Cancellation: `CancellationError` continues to short-circuit the build
loop immediately. The contribution accumulator is per-build state and
is discarded on cancellation along with the rest of `BuildState`.

### 7. View wiring (`InvestmentAccountView`)

No structural changes. The `PositionsChart` is passed
`input.historicalValue` as before. The new `contributions` field
reaches the chart through that same `HistoricalValueSeries` value.
`PositionsViewInput` is unchanged.

`InvestmentStore.positionsViewInput(...)` (in the
`+PositionsInput` extension) calls `PositionsHistoryBuilder.build`
exactly as today; the only difference is the resulting
`HistoricalValueSeries.Point.contributions` is populated for aggregate
points.

## Tests

### Domain / model

- `MoolahTests/Domain/HistoricalValueSeriesTests.swift` — extend the
  existing fixture to assert `contributions` is reachable on a Point
  and round-trips via `Hashable` / `Sendable` conformances. Aggregate
  vs. per-instrument distinction (nil vs. populated) is asserted at
  builder level.

### Builder — `PositionsHistoryBuilderTests`

New cases (sibling of existing tests, same fixtures and seam):

- *Opening balance establishes contributions* — account opened with a
  non-zero opening balance leg; first emitted aggregate point has
  `contributions == openingBalanceAmount` in host currency.
- *External transfer in steps contributions up* — boundary-crossing
  transaction credits the account in host currency; `contributions`
  steps up by exactly the leg amount on that day, holds flat
  thereafter.
- *External transfer out steps contributions down* — the dual case;
  `contributions` decreases.
- *Intra-account trade does not change contributions* — a buy that is
  entirely cash-out + stock-in within the same account leaves
  `contributions` unchanged.
- *Cross-currency contribution converts on transaction date* — leg
  instrument differs from `hostCurrency`; the test uses
  `DateBasedFixedConversionService` configured with **two distinct
  rates on different dates** so that "convert on `transaction.date`"
  and "convert on `Date()`" produce different amounts. The assertion
  is on the exact rate value, locking in the date choice as a
  regression guard. A plain date-ignoring fixture would let the
  Rule 5 / Rule 8 contract silently regress to "convert on today".
- *Pre-fold contributions* — transactions strictly before the visible
  window contribute to the day-1 value but emit no point of their
  own. Pre-fold also short-circuits once `state.contributions == nil`
  (verified by counting conversion-service calls after a forced
  pre-window failure).
- *Conversion failure makes whole forward series unavailable* —
  fixture conversion service throws on a specific transaction date;
  every aggregate point on or after that date has
  `contributions == nil`; earlier days retain their populated value
  (chronological-walk + sticky-latch invariant); per-instrument and
  `value` / `cost` series unaffected.
- *Cancellation* — cancelling the task during the build returns
  promptly without applying a partial flow. Specifically: the
  `Task.checkCancellation()` call inside the `flowAmounts` fold
  throws `CancellationError` and the build exits with a consistent
  `state` (no leg's amount applied without all of its siblings).

### Tile — `AccountPerformanceTilesTests` (new file)

- Subtitle visible when `firstFlowDate != nil` and
  `totalContributions != nil`; renders `Invested <formatted>`.
- Subtitle renders `Invested —` when `firstFlowDate != nil` and
  `totalContributions == nil` (Rule 11 — explicit unavailable).
- Subtitle hidden when `firstFlowDate == nil` (no flows yet).
- Subtitle visible alongside `Unavailable` main line when
  `currentValue == nil` and flows exist.
- Accessibility label combinations. Tests assert against
  `InstrumentAmount.formatted` output applied to the fixture amounts
  (not against hand-written `"$X"` literals — the formatter is
  locale-aware and the test must follow the same path the view
  takes):
  - both populated → `"Current Value: \(currentValue.formatted),
    Invested: \(totalContributions.formatted)"`
  - `currentValue == nil`, contributions populated →
    `"Current Value: Unavailable, Invested:
    \(totalContributions.formatted)"`
  - both populated but `totalContributions == nil` →
    `"Current Value: \(currentValue.formatted), Invested:
    Unavailable"`
  - no flows (`firstFlowDate == nil`) →
    `"Current Value: \(currentValue.formatted)"` (no Invested
    clause).

### Chart — data-shape unit tests (project pattern)

Existing tests in this area (`PositionsViewInputTests`) use plain
Swift Testing assertions over view-input shape rather than SwiftUI
snapshots; this spec follows that convention — assertions on the
data the chart consumes, not pixels.

- *Aggregate render data shape* — given a `HistoricalValueSeries`
  with populated `contributions`, the helper that selects the
  baseline returns `point.contributions` for each point; gain /
  loss areas are computed against that baseline.
- *Per-instrument render data shape* — given a
  `HistoricalValueSeries` filtered to an instrument (`contributions
  == nil` per point), the same helper returns `point.cost` as the
  baseline.
- *Nil-baseline transition* — given a sequence where some points
  have `contributions != nil` and later points are `nil`, the
  helper produces a baseline value for the populated days and `nil`
  for the unavailable days, so the rendering code can suppress
  area + baseline-line marks for nil days while still drawing the
  value line. (Validates the §3 "render is driven per point" rule.)
- *Most-recent-point legend signal* — visible-window's right-most
  point with `contributions == nil` causes the legend's
  `unavailable` flag to be true; populated → false.

### Shared helper — `AccountCashFlowsTests` (new file)

Coverage for the extracted helper:

- Opening-balance leg → returns `[legAmount]` (converted on txn date
  if cross-currency).
- Boundary-crossing transaction, account leg in host currency →
  returns `[legQuantity]` unchanged (Rule 8 fast path; conversion
  service is *not* called — verified via call counter on the
  fixture).
- Boundary-crossing, cross-currency → returns
  `[service.convert(qty, leg.instrument, host, on: txn.date)]`.
  Uses `DateBasedFixedConversionService` with two distinct rates
  on different dates so the assertion locks the conversion-date
  choice.
- Intra-account-only transaction → returns `[]`.
- Multi-leg transaction (e.g., two opening-balance legs in the
  account) → returns one entry per qualifying leg in `transaction
  .legs` order.
- Conversion service throws on the first qualifying leg → helper
  rethrows; later legs are not converted (verified via call
  counter on the fixture).
- Conversion service throws `CancellationError` → helper rethrows
  it unwrapped (`CancellationError`, not wrapped).

`AccountPerformanceCalculatorTests` keeps its existing coverage; the
contract under test does not change because the helper is a
behaviour-preserving extraction. One added regression test there
asserts the resulting `[CashFlow]` order (per-leg granularity is
preserved across the refactor).

## Out of scope (explicit)

- Annualised return computed over the chart's visible window
  (currently lifetime-only on the tile).
- Currency-toggle on the chart axis (always renders in profile
  instrument).
- Selectable points / hover detail on the position chart (the legacy
  chart has selection detail; per-instrument and aggregate position
  chart do not, and this PR keeps it that way).
- A "Total Invested" tile in its own card.

## Risks and open questions

- **Visual readability of two stacked area marks at a crossing.**
  Swift Charts may paint a 1-pixel seam where the gain segment ends
  and the loss segment begins on a single sample. If the seam shows
  on real data, mitigation is to clamp the smaller of the two
  segments to zero height explicitly via a conditional `AreaMark`
  emission rather than letting Charts collapse it. Implementation
  step §3 should verify this in `#Preview` before locking the
  rendering shape.
- **Pre-fold of contributions across very long histories.** The
  pre-fold walks all transactions strictly before the visible window
  to seed `state.contributions`. On accounts with thousands of
  pre-window transactions this is one extra `flowAmounts(for:)` call
  per pre-window transaction, each of which may hit
  `InstrumentConversionService` (cached). Because the conversion
  service is backed by `ExchangeRateCache` / `StockPriceCache`,
  steady-state cost is O(1) per leg after the first chart load.
  Cold-cache cost is bounded by the same one-call-per-historical-
  date that the existing per-instrument value walk already pays;
  contributions add no new networked dates.
- **Subtitle truncation in narrow tile widths (compact iOS).** The
  Current Value tile already shows a `$XXX,XXX.XX` main number and
  the new subtitle adds a similar-width string. On the narrowest
  iPhone the three-tile strip may need the subtitle to truncate
  rather than reflow; SwiftUI's default truncation behaviour on
  `.caption` is acceptable. The `.dynamicTypeSize(...accessibility2)`
  cap stays.
