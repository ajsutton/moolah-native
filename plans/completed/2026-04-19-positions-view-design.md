# Positions View — Design Spec

**Date:** 2026-04-19
**Status:** Draft — awaiting review

## Context

Moolah currently shows per-instrument positions in three different views:

- `Features/Investments/Views/StockPositionsView.swift` — used on position-tracked investment accounts. Header with total + list of stock rows, with a separate "Cash" section for fiat positions. Always visible.
- `Shared/Views/PositionListView.swift` — a compact "Balances" section used inside `EditAccountView` and at the top of filtered `TransactionListView`. Renders one row per instrument with no total. Hidden when the entity holds only one instrument.
- `Features/Accounts/CryptoPositionsSectionView.swift` — a crypto-specific section for accounts holding crypto, with its own valuation loop.

These three views have overlapping responsibilities and diverging presentation, and none of them treats stocks, crypto, and fiat as peers of a single concept. As the app gains support for FX cost basis, category/earmark filtered flow summaries, and richer portfolio insights, the duplication gets worse.

This spec describes **`PositionsView`**, a single unified component that replaces all three, used anywhere the app needs to present a collection of instrument positions.

## Scope

### In scope

- A new `PositionsView` component, used in two host contexts:
  1. **Primary** — the investment account page, as the main content above the transaction list.
  2. **Filtered transactions** — at the top of `TransactionListView` when the list is filtered by account, earmark, or category and the filtered set yields multiple non-zero instrument positions.
- Retire `StockPositionsView`, `PositionListView`, and `CryptoPositionsSectionView`.
- Remove the `PositionListView`-backed "Balances" section from `EditAccountView` entirely. Positions are not edited from that screen, and the current form already shows the account's primary-currency balance — the redundant per-instrument list can go.

### Out of scope

- The **legacy manual-valuation chart** (`InvestmentChartView` + `InvestmentValuesView` + `InvestmentSummaryView`) stays untouched. `InvestmentStore.hasLegacyValuations` continues to gate whether an investment account shows the legacy chart + valuations pane or the new `PositionsView`.
- Recording trades. Trades are multi-leg transactions entered through `TransactionDetailView`; there is no "Record Trade" affordance inside `PositionsView`.
- Context-menu actions, double-click drill-in, instrument-filtered transaction views, sort-order persistence, multi-instrument comparison on the chart. All deferred — see "Deferred" below.

## Composition

`PositionsView` is a container with three pieces, stacked vertically:

```
┌─────────────────────────────────────────────┐
│ Header — title · total · P&L pill           │
├─────────────────────────────────────────────┤
│ Chart (optional)                            │
│ ├─ Value line + Cost basis (dashed) line    │
│ └─ Time-range picker                        │
├─────────────────────────────────────────────┤
│ Table / list of positions                   │
│ ├─ Group: Stocks (subtotal if >1 group)     │
│ ├─ Group: Crypto                            │
│ └─ Group: Cash                              │
└─────────────────────────────────────────────┘
```

### Header

- **Title** — supplied by the caller (typically the account name, but may be "Positions" or an earmark label when embedded elsewhere).
- **Aggregate value** — sum of per-row values in the account / host currency. Single-instrument fast path applies (rows whose instrument equals the host currency skip conversion).
- **P&L pill** — `+$X,XXX.XX (±Y.Y%)`, computed as `Σ(value − cost)` across all positions; positions without a cost basis contribute `cost = value` (zero gain/loss). The pill is **hidden only when no position has cost basis** (pure fiat context with no FX cost basis tracked).
- Green for gains, red for losses, semantic colour only (no hardcoded RGB).

### Chart

- **Visibility rule.** The chart is shown when at least one position has a cost basis. In a flow context (filtered transaction list), positions represent net flow rather than holdings — those inputs don't carry cost basis, so the chart naturally doesn't render. No mode flag is needed; the component's inputs determine whether the chart appears.
- **Series.**
  - **Value** — solid accent-coloured line + soft fill beneath. Account total (default) or single-instrument (when a row is selected).
  - **Cost basis** — dashed grey line over the same time range. It is a step function that changes when buys, sells, or corporate actions shift the cost basis of the (account or instrument) — not a flat line. For the all-positions chart, cost basis at each date is the sum of per-instrument cost bases at that date.
- **Time range.** Segmented picker with `1M / 3M / 6M / YTD / 1Y / All`. Last-used range is session-scoped; no persistence required for v1.
- **Interaction — row selection filters the chart.**
  - Default: chart shows account total (sum over all positions at each date).
  - When a row is selected, the chart switches to that instrument's value vs. cost.
  - Two filter cues (both present when filtered):
    - **Chip** in the chart header — instrument badge + ticker + `×` to clear. Replaces the default "All positions" label.
    - **Row tint** — the selected row gets the standard `Table` selection highlight.
  - Clearing the filter (click `×` on the chip, click the selected row again, or click empty space in the table) returns the chart to "all positions".
- **Hide conditions.**
  - All-positions chart is hidden entirely if **any** position's current conversion failed — rendering it with partial data would produce a misleading total line. This matches the project rule that aggregate totals never include a partial sum.
  - Filtered chart for instrument X is hidden only if X's conversion failed. Selecting a different (working) instrument still renders.

### Table / List

Content per row:

| Column | Stock | Crypto | Fiat |
|---|---|---|---|
| Badge | blue, ticker text | orange, symbol | slate, currency code |
| Name (primary) | `BHP` | `Ethereum` | `US Dollar` |
| Identifier (secondary) | `ASX` | — | — |
| Qty | `250` (or `250 shares`) | `2.45 ETH` | `$1,000.00` |
| Unit price | `A$45.30` | `A$4,000.00 / ETH` | fx rate (`1 USD = A$1.52`) |
| Cost | `A$10,125.00` | `A$7,500.00` | `—` (until FX cost basis) |
| Value | `A$11,325.00` | `A$9,800.00` | `A$1,520.00` |
| Gain / loss | `+A$1,200 · +11.9%` | `+A$2,300 · +30.7%` | `—` |

Monospaced digits throughout on monetary and quantity cells. Signed values preserve their sign (no `abs()`).

### Grouping & sort

- Rows are grouped by `Instrument.Kind`: **Stocks**, **Crypto**, **Cash** (in that order).
- Each group has a subtotal heading **only when more than one group is present**. A brokerage with only stocks, or a travel account with only fiat, renders as a flat list with no subtotals.
- **Default sort within each group:** value descending.
- **Interactive sort:** clicking a column header on the macOS `Table` sorts by that column. Sort state is per-view-instance; not persisted across screen dismissals in v1.

### Responsive behaviour

The component uses a single responsive layout — the wide and compact variants share row data but differ in presentation:

- **Wide** (macOS window, iPad regular width) — SwiftUI `Table` with aligned columns. Cost basis and unit price are inline.
- **Narrow** (iPhone, compact-width iPad) — `List` rows with a two-line layout: primary name + secondary identifier/qty on the left, value + gain/loss stacked on the right. Cost basis and unit price move into the secondary line where they fit; the rest is omitted.

Both hosts (investment account page and filtered transactions) use the same responsive component. Neither passes a "mode" flag — the chart's appearance and the P&L pill's visibility are driven by whether the passed-in data carries cost basis.

### Interactions (v1)

- **Click / tap a row** — selects the row, filters the chart to that instrument (if chart is visible).
- **Click the selected row again, the chip's `×`, or empty space** — clears selection.
- **Keyboard** — arrow keys move selection through the table (standard `Table` behaviour); Escape clears selection.
- **No** double-click, context menu, drag, or "Record Trade" button in v1.

### Conversion failures

The component follows the existing project rule: **never display a partial aggregate**. In detail:

- **Per-row failure** — that row's Value, Gain, and (where derived) Cost columns render as `—`. The row still appears and still shows Qty and Unit price where those don't require conversion.
- **Header total** — shows `Unavailable` if *any* row's conversion failed. Never a partial sum, never a "convertible portion only" shortcut.
- **P&L pill** — hidden when the header total is `Unavailable`.
- **All-positions chart** — hidden entirely if any position's current conversion failed (historical points would also be inaccurate, and the eye is drawn to the present).
- **Filtered chart** — for a single instrument, hidden only when that instrument's conversion failed. Other instruments with successful conversions still render their series on request.

### Empty state

When the input position set is empty, the component renders nothing and takes no layout space. The host view decides whether to show any empty-state messaging appropriate to its context.

## Data inputs

The component is driven by a value-typed input:

```swift
struct PositionsViewInput {
  let title: String
  let hostCurrency: Instrument
  let positions: [ValuedPosition]           // per-row data
  let historicalValue: HistoricalValueSeries?  // nil disables chart
}

struct ValuedPosition {
  let instrument: Instrument
  let quantity: Decimal
  let unitPrice: InstrumentAmount?          // in host currency
  let costBasis: InstrumentAmount?          // in host currency
  let value: InstrumentAmount?              // nil = conversion failed
}

struct HistoricalValueSeries {
  // Daily (value, cost) points over the active range for each instrument
  // and for the account total. Chart selects the slice matching the
  // user's time-range choice and the current filter (instrument or total).
}
```

The exact `HistoricalValueSeries` shape is an implementation detail for the plan — see "Implementation notes" below.

### Visibility derivation (summary)

- **Header P&L pill** — hidden iff every `position.costBasis == nil`.
- **Chart** — visible iff `historicalValue != nil` and at least one position has cost basis.
- **Group subtotals** — present iff more than one instrument kind is represented.

## Accessibility

- Every row announces: badge kind, instrument name, qty, and value. Failed conversions announce "value unavailable".
- Header announces the title, total (or "Unavailable"), and P&L change in both absolute and percent terms.
- Chart — `accessibilityChartDescriptor` with the visible series and range; selected filter chip labelled `"Chart filtered to <instrument>, double-tap to clear"`.
- Keyboard navigation on macOS — arrow keys move selection; Return / Space toggles selection off when the row is already selected; Escape clears selection. Tab focus order: header → chart range picker → chart filter chip `×` (when present) → table header row → rows.

## Deferred

- Multi-select chart comparison (Shift / Cmd-click) — overlay multiple instrument series, or sum them.
- Sort order persistence across screen dismissals.
- Context menu (View Transactions, Copy Ticker, Reveal in Chart) and double-click drill-in.
- Chart in flow contexts (filtered transaction list). Positions represent net flow there; a meaningful chart would need different semantics (cumulative flow, per-period bars).
- Instrument-level detail panel (cost-basis lots, day change). Expandable/selectable detail row is a natural v2.

## Implementation notes

These are not design decisions — they are flagged for the implementation plan.

- **File layout.** The new component is shared across features. Proposed location: `Shared/Views/Positions/` (new folder) with `PositionsView.swift`, `PositionsChart.swift`, `PositionsTable.swift`, plus a small row component. The input types (`PositionsViewInput`, `HistoricalValueSeries`) live in `Domain/Models/`.
- **Historical value series.** The chart needs value-at-date and cost-at-date series for the account as a whole and — when filtered — for a single instrument. `PositionBook.dailyBalance(on:...)` already produces daily totals using the conversion service; the plan should evaluate whether to (a) extend the analysis pipeline to emit per-instrument daily values for investment accounts, (b) add a dedicated repository method that batches historical price lookups for the active instruments over the active range, or (c) pre-compute a cached series on the server/CloudKit side. Option (a) is the cheapest to prototype since the pipeline already iterates positions per day.
- **Table sort.** SwiftUI `Table<Row>` supports sortable columns via `KeyPathComparator`. Sort state is a local `@State` on `PositionsTable`. The default comparator is `value, descending`.
- **Selection model.** Single selection via `@State var selected: Instrument?`. Passed to the chart as a filter. Clearing is a simple assignment to `nil` from either the chip's `×` tap, a second click on the selected row, or keyboard Escape.
- **Currency formatting.** Uses existing `InstrumentAmount.formatted` + `.monospacedDigit()`. Signed amounts preserve their sign.
- **InvestmentAccountView wiring.** The existing `hasLegacyValuations` branch is preserved. The non-legacy branch swaps `StockPositionsView` for `PositionsView`. `Record Trade` toolbar item is removed.
- **TransactionListView wiring.** The existing `PositionListView(positions:)` call site is replaced by `PositionsView` configured without a historical series. Positions here already come from the in-view `positions` computation.
- **EditAccountView.** The `PositionListView(positions:)` section is deleted; no replacement.

## Verification

- All contract tests for repositories used to source positions continue to pass.
- New tests cover: header aggregation (success, partial failure → Unavailable), P&L pill visibility (none/some/all positions with cost basis), chart visibility derivation, row selection updates chart filter, conversion-failure row presentation, empty-set rendering to nothing.
- Snapshot / preview validation via `RenderPreview` across `Default`, `BHP selected`, `All fiat / no chart`, `Conversion failure`, and `Empty` preview states.
- UI review (`@ui-review`) on the new views for UI_GUIDE + HIG compliance before merge.
- Concurrency review (`@concurrency-review`) if the historical series fetch introduces new async surface in stores.
