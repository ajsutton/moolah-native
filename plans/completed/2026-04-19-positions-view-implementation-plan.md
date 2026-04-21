# Positions View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `StockPositionsView`, `PositionListView`, and `CryptoPositionsSectionView` with a single unified `PositionsView` used on the investment account page and at the top of filtered transaction lists.

**Architecture:** A pure value-typed input (`PositionsViewInput`) feeds a thin SwiftUI container (`PositionsView`) composed of a header, optional chart, and responsive table/list. Per-row valuations and historical series are produced by two new pure helpers (`PositionsValuator`, `PositionsHistoryBuilder`) so the view has zero direct repository or store coupling. `InvestmentStore` builds the input for the investment-account host; the transaction list builds it inline (no chart, no cost basis). Conversion failures degrade per the project's "never display a partial aggregate" rule.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI (iOS 26+ / macOS 26+), Swift Charts, Swift Testing, `xcodegen`, `just` task runner, existing `InstrumentConversionService` + `CostBasisEngine`.

**Spec reference:** `plans/2026-04-19-positions-view-design.md`. Read it before starting any task.

---

## File Structure

### New files

| Path | Responsibility |
|---|---|
| `Domain/Models/ValuedPosition.swift` | Value type per row: instrument + qty + unitPrice + costBasis + value (replaces the 2-field struct currently in `Features/Investments/InvestmentStore.swift`). |
| `Domain/Models/PositionsViewInput.swift` | Top-level immutable input passed to `PositionsView`: title, host currency, valued rows, optional historical series. |
| `Domain/Models/HistoricalValueSeries.swift` | Per-instrument and aggregate daily (value, cost) points used by the chart. |
| `Shared/PositionsValuator.swift` | Pure helper: `[Position]` + cost-basis snapshot + conversion service → `[ValuedPosition]`. |
| `Shared/PositionsHistoryBuilder.swift` | Pure helper: account legs + range + conversion service → `HistoricalValueSeries`. |
| `Shared/TradeEventClassifier.swift` | Extracted from `CapitalGainsCalculator.classifyLegsWithConversion`: classifies a transaction's legs into FIFO buy / sell events including crypto-to-crypto swaps. Single source of truth for both `CapitalGainsCalculator` and the new positions helpers. |
| `MoolahTests/Shared/TradeEventClassifierTests.swift` | Fiat-paired buy, fiat-paired sell, crypto-to-crypto swap each produce the right buy/sell events. |
| `Shared/Views/Positions/PositionsView.swift` | Top-level container. Header + (optional) chart + table. |
| `Shared/Views/Positions/PositionsHeader.swift` | Title, total amount or "Unavailable", P&L pill. |
| `Shared/Views/Positions/PositionsChart.swift` | Value + cost-basis lines, range picker, instrument-filter chip. |
| `Shared/Views/Positions/PositionsTable.swift` | Wide layout (`Table`) + narrow layout (`List`) with grouping subtotals. |
| `Shared/Views/Positions/PositionRow.swift` | Single-row presentation across stock / crypto / fiat. |
| `Shared/Views/Positions/PositionsTimeRange.swift` | Local enum `1M / 3M / 6M / YTD / 1Y / All`, with cutoff date + sample-spacing rule. |
| `MoolahTests/Domain/PositionsViewInputTests.swift` | Visibility derivation rules (P&L pill, chart). |
| `MoolahTests/Shared/PositionsValuatorTests.swift` | Per-row valuation, single-instrument fast path, per-row failure. |
| `MoolahTests/Shared/PositionsHistoryBuilderTests.swift` | Per-instrument & aggregate series correctness, range filtering, conversion-failure degradation. |
| `MoolahTests/Features/InvestmentStorePositionsInputTests.swift` | `InvestmentStore.positionsViewInput(...)` end-to-end against `TestBackend`. |

### Files modified

| Path | Change |
|---|---|
| `Features/Investments/InvestmentStore.swift` | Remove the 2-field `ValuedPosition` definition (now lives in Domain). Add `positionsViewInput(range:)` returning the new input. Keep `valuatePositions` but route it through `PositionsValuator`. Cost-basis snapshot uses `TradeEventClassifier` so swaps contribute correctly. |
| `Shared/CapitalGainsCalculator.swift` | Replace the private `classifyLegs` / `classifyLegsWithConversion` helpers with calls to the new `TradeEventClassifier` (no behaviour change — extraction only). |
| `Features/Investments/Views/InvestmentAccountView.swift` | Swap `StockPositionsView` for `PositionsView`. Remove `Record Trade` toolbar item. |
| `Features/Transactions/Views/TransactionListView.swift` | Replace `PositionListView(positions:)` with `PositionsView(input:)` built from `positions` + `targetInstrument` + `conversionService`. Add `conversionService` and `targetInstrument` parameters to the view. |
| `Features/Accounts/Views/EditAccountView.swift` | Delete the `PositionListView(positions:)` line entirely. |
| `project.yml` | No change required (xcodegen picks up new files under tracked groups). After file additions, run `just generate`. |

### Files deleted (final task)

| Path |
|---|
| `Features/Investments/Views/StockPositionsView.swift` |
| `Features/Investments/Views/StockPositionRow.swift` |
| `Features/Accounts/CryptoPositionsSectionView.swift` |
| `Shared/Views/PositionListView.swift` |
| `MoolahTests/Features/CryptoPositionValuatorTests.swift` (replaced by `PositionsValuatorTests`) |
| `MoolahTests/Features/StockPositionDisplayTests.swift` (replaced by snapshot/preview validation in `PositionsView`) |

---

## Conventions for every task

- **Worktree:** all work in this branch's worktree (`.worktrees/positions-view-design`). Never touch `main` directly.
- **TDD:** write the failing test first, run it, see the failure message printed match the expectation in the step, then implement.
- **Build/test commands always go through `just`:** never `swiftc` / `xcodebuild` / `swift test` directly.
- **Pipe test output to `.agent-tmp/`:** `mkdir -p .agent-tmp && just test PositionsValuatorTests 2>&1 | tee .agent-tmp/test.txt`. Delete the file when done.
- **Format before every commit:** `just format`.
- **Regenerate after adding files:** `just generate`.
- **Commit after each task** with the exact message listed at the end of the task.

---

## Task 1: Add `ValuedPosition` value type to Domain

**Files:**
- Create: `Domain/Models/ValuedPosition.swift`
- Test: `MoolahTests/Domain/PositionsViewInputTests.swift` (created here, expanded in Task 3)

- [ ] **Step 1.1: Write the failing test**

Create `MoolahTests/Domain/PositionsViewInputTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("ValuedPosition")
struct ValuedPositionTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")

  @Test("amount returns InstrumentAmount in the position's instrument")
  func amountWrapsInstrument() {
    let row = ValuedPosition(
      instrument: bhp,
      quantity: 250,
      unitPrice: InstrumentAmount(quantity: 45.30, instrument: aud),
      costBasis: InstrumentAmount(quantity: 10_125, instrument: aud),
      value: InstrumentAmount(quantity: 11_325, instrument: aud)
    )
    #expect(row.amount == InstrumentAmount(quantity: 250, instrument: bhp))
  }

  @Test("hasCostBasis is true only when costBasis is non-nil")
  func hasCostBasisFlag() {
    let withCost = ValuedPosition(
      instrument: bhp, quantity: 1,
      unitPrice: nil,
      costBasis: InstrumentAmount(quantity: 50, instrument: aud),
      value: InstrumentAmount(quantity: 60, instrument: aud)
    )
    let withoutCost = ValuedPosition(
      instrument: bhp, quantity: 1,
      unitPrice: nil, costBasis: nil,
      value: InstrumentAmount(quantity: 60, instrument: aud)
    )
    #expect(withCost.hasCostBasis)
    #expect(!withoutCost.hasCostBasis)
  }

  @Test("gainLoss computes value - cost in host currency")
  func gainLossSubtraction() {
    let row = ValuedPosition(
      instrument: bhp, quantity: 250,
      unitPrice: nil,
      costBasis: InstrumentAmount(quantity: 10_125, instrument: aud),
      value: InstrumentAmount(quantity: 11_325, instrument: aud)
    )
    #expect(row.gainLoss == InstrumentAmount(quantity: 1200, instrument: aud))
  }

  @Test("gainLoss is nil when value is nil")
  func gainLossNilOnFailure() {
    let row = ValuedPosition(
      instrument: bhp, quantity: 250,
      unitPrice: nil,
      costBasis: InstrumentAmount(quantity: 10_125, instrument: aud),
      value: nil
    )
    #expect(row.gainLoss == nil)
  }

  @Test("gainLoss is nil when costBasis is nil (pure flow row)")
  func gainLossNilWithoutCost() {
    let row = ValuedPosition(
      instrument: aud, quantity: 1_000,
      unitPrice: nil, costBasis: nil,
      value: InstrumentAmount(quantity: 1_000, instrument: aud)
    )
    #expect(row.gainLoss == nil)
  }
}
```

- [ ] **Step 1.2: Run test to verify it fails**

```bash
mkdir -p .agent-tmp
just test PositionsViewInputTests 2>&1 | tee .agent-tmp/test.txt
```

Expected: build failure with "cannot find type 'ValuedPosition' in scope" (the existing `Features/Investments/InvestmentStore.swift` has a `ValuedPosition` with a different shape — the test's signature doesn't match).

- [ ] **Step 1.3: Move/replace `ValuedPosition` into Domain**

Delete the existing definition at `Features/Investments/InvestmentStore.swift:6-11` (lines `struct ValuedPosition: Identifiable, Sendable { ... var id: String { position.instrument.id } }`).

Create `Domain/Models/ValuedPosition.swift`:

```swift
import Foundation

/// One row in a `PositionsView`: instrument identity + quantity, plus the
/// current unit price, cost basis, and total value all expressed in the host
/// currency. `value`, `unitPrice`, and `costBasis` are independently optional
/// so callers can supply only what they have:
///
/// - Flow contexts (filtered transaction list): `costBasis` and `unitPrice`
///   are `nil`; `value` is the converted flow amount or `nil` on failure.
/// - Investment account: all four are populated where the conversion service
///   succeeds. A per-row conversion failure leaves `value` (and the derived
///   `gainLoss`) `nil`; the caller still renders qty + identifier.
struct ValuedPosition: Sendable, Hashable, Identifiable {
  let instrument: Instrument
  let quantity: Decimal
  let unitPrice: InstrumentAmount?
  let costBasis: InstrumentAmount?
  let value: InstrumentAmount?

  var id: String { instrument.id }

  /// The position quantity wrapped as an `InstrumentAmount` in the
  /// instrument's own units (not the host currency).
  var amount: InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: instrument)
  }

  /// `true` iff a cost basis has been provided for this row.
  var hasCostBasis: Bool { costBasis != nil }

  /// Value minus cost basis in the host currency, or `nil` if either side is
  /// missing. Per CLAUDE.md sign convention the result preserves its sign —
  /// callers must not `abs()` the gain when colouring or sorting.
  var gainLoss: InstrumentAmount? {
    guard let value, let costBasis else { return nil }
    return value - costBasis
  }
}
```

- [ ] **Step 1.4: Adjust the legacy InvestmentStore call sites**

`InvestmentStore.swift` previously held `ValuedPosition(position:marketValue:)`. We replace those constructions with the new five-field initialiser. In `Features/Investments/InvestmentStore.swift`, replace the body of `valuatePositions(profileCurrency:on:)` (currently lines 203-236):

```swift
func valuatePositions(profileCurrency: Instrument, on date: Date) async {
  var valued: [ValuedPosition] = []
  var total: Decimal = 0
  var firstFailure: Error?

  for position in positions {
    if position.instrument.id == profileCurrency.id {
      valued.append(
        ValuedPosition(
          instrument: position.instrument,
          quantity: position.quantity,
          unitPrice: nil,
          costBasis: nil,
          value: InstrumentAmount(quantity: position.quantity, instrument: profileCurrency)
        ))
      total += position.quantity
      continue
    }
    do {
      let value = try await conversionService.convert(
        position.quantity, from: position.instrument, to: profileCurrency, on: date
      )
      let unit =
        position.quantity == 0
        ? nil
        : InstrumentAmount(quantity: value / position.quantity, instrument: profileCurrency)
      valued.append(
        ValuedPosition(
          instrument: position.instrument,
          quantity: position.quantity,
          unitPrice: unit,
          costBasis: nil,
          value: InstrumentAmount(quantity: value, instrument: profileCurrency)
        ))
      total += value
    } catch {
      logger.warning(
        "Failed to valuate position \(position.instrument.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      valued.append(
        ValuedPosition(
          instrument: position.instrument,
          quantity: position.quantity,
          unitPrice: nil,
          costBasis: nil,
          value: nil
        ))
      if firstFailure == nil { firstFailure = error }
    }
  }

  valuedPositions = valued
  if let firstFailure {
    totalPortfolioValue = nil
    self.error = firstFailure
  } else {
    totalPortfolioValue = total
  }
}
```

Update `StockPositionsView.swift` and `StockPositionRow.swift` previews and bodies to use the new fields. (These files are deleted in Task 12; for now, just keep the project compiling by replacing `valuedPosition.position.instrument` with `valuedPosition.instrument`, `valuedPosition.position.quantity` with `valuedPosition.quantity`, `valuedPosition.marketValue` with `valuedPosition.value?.quantity`. Same for the previews — replace `ValuedPosition(position: Position(instrument: x, quantity: y), marketValue: z)` with `ValuedPosition(instrument: x, quantity: y, unitPrice: nil, costBasis: nil, value: z.map { InstrumentAmount(quantity: $0, instrument: .AUD) })`.)

- [ ] **Step 1.5: Run the new tests + the full suite to confirm nothing else broke**

```bash
just test PositionsViewInputTests 2>&1 | tee .agent-tmp/test.txt
grep -i 'failed\|error:' .agent-tmp/test.txt || echo "PASS"
just test 2>&1 | tee .agent-tmp/test-all.txt
grep -i 'failed\|error:' .agent-tmp/test-all.txt
```

Expected: `PositionsViewInputTests` all pass; full suite returns no `error:` and no `failed`. `StockPositionDisplayTests` may need its construction lines updated the same way as the previews — fix them inline.

- [ ] **Step 1.6: Format + commit**

```bash
just format
git -C . add Domain/Models/ValuedPosition.swift \
  Features/Investments/InvestmentStore.swift \
  Features/Investments/Views/StockPositionsView.swift \
  Features/Investments/Views/StockPositionRow.swift \
  MoolahTests/Domain/PositionsViewInputTests.swift \
  MoolahTests/Features/StockPositionDisplayTests.swift \
  Moolah.xcodeproj/project.pbxproj 2>/dev/null || true
just generate
git -C . add -u Moolah.xcodeproj
git -C . commit -m "feat(positions): introduce ValuedPosition value type in Domain"
```

---

## Task 2: Add `HistoricalValueSeries` value type

**Files:**
- Create: `Domain/Models/HistoricalValueSeries.swift`
- Modify: `MoolahTests/Domain/PositionsViewInputTests.swift`

- [ ] **Step 2.1: Write the failing test**

Append to `MoolahTests/Domain/PositionsViewInputTests.swift`:

```swift
@Suite("HistoricalValueSeries")
struct HistoricalValueSeriesTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let cba = Instrument.stock(ticker: "CBA.AX", exchange: "ASX", name: "CBA")

  private func date(_ day: Int) -> Date {
    Date(timeIntervalSince1970: TimeInterval(day) * 86_400)
  }

  @Test("series(for:) returns the per-instrument slice when present")
  func sliceLookup() {
    let series = HistoricalValueSeries(
      hostCurrency: aud,
      total: [
        HistoricalValueSeries.Point(date: date(1), value: 100, cost: 80),
        HistoricalValueSeries.Point(date: date(2), value: 110, cost: 80),
      ],
      perInstrument: [
        bhp.id: [
          HistoricalValueSeries.Point(date: date(1), value: 60, cost: 50)
        ]
      ]
    )

    #expect(series.series(for: bhp).count == 1)
    #expect(series.series(for: cba).isEmpty)
    #expect(series.totalSeries.count == 2)
  }

  @Test("instruments lists every per-instrument key")
  func instrumentsReturnsKeys() {
    let series = HistoricalValueSeries(
      hostCurrency: aud,
      total: [],
      perInstrument: [
        bhp.id: [], cba.id: [],
      ]
    )
    #expect(Set(series.instruments) == Set([bhp.id, cba.id]))
  }
}
```

- [ ] **Step 2.2: Run to verify it fails**

```bash
just test HistoricalValueSeriesTests 2>&1 | tee .agent-tmp/test.txt
```

Expected: build error "cannot find type 'HistoricalValueSeries' in scope".

- [ ] **Step 2.3: Implement the type**

Create `Domain/Models/HistoricalValueSeries.swift`:

```swift
import Foundation

/// Daily (or sampled) `(value, cost)` time series in a single host currency,
/// driving the chart in `PositionsView`.
///
/// `total` is the account-wide aggregate: at each sample date `value` is the
/// sum of converted per-instrument values and `cost` is the sum of remaining
/// cost bases. `perInstrument` carries the same series per instrument id, used
/// when a single row is selected and the chart filters to that instrument.
///
/// The series excludes any sample date whose conversion failed for the
/// relevant instrument (or for any instrument, in the case of `total`); the
/// project rule "never display a partial aggregate" means an aggregate point
/// is only emitted if every contributing per-instrument conversion succeeded
/// on that date. Callers can therefore plot what is here without further
/// guards.
struct HistoricalValueSeries: Sendable, Hashable {
  struct Point: Sendable, Hashable {
    let date: Date
    let value: Decimal
    let cost: Decimal
  }

  let hostCurrency: Instrument
  /// Aggregate series. May be empty when every sample failed.
  let total: [Point]
  /// Per-instrument series keyed by `Instrument.id`.
  let perInstrument: [String: [Point]]

  /// All instrument ids represented in the per-instrument map.
  var instruments: [String] { Array(perInstrument.keys) }

  /// The aggregate points; convenience for symmetry with `series(for:)`.
  var totalSeries: [Point] { total }

  /// Per-instrument points; empty array when the instrument has no slice.
  func series(for instrument: Instrument) -> [Point] {
    perInstrument[instrument.id] ?? []
  }
}
```

- [ ] **Step 2.4: Run, format, commit**

```bash
just test HistoricalValueSeriesTests 2>&1 | tee .agent-tmp/test.txt
grep -i 'failed\|error:' .agent-tmp/test.txt || echo "PASS"
just format
just generate
git -C . add Domain/Models/HistoricalValueSeries.swift \
  MoolahTests/Domain/PositionsViewInputTests.swift Moolah.xcodeproj
git -C . commit -m "feat(positions): add HistoricalValueSeries value type"
```

---

## Task 3: Add `PositionsViewInput` with derived visibility

**Files:**
- Create: `Domain/Models/PositionsViewInput.swift`
- Modify: `MoolahTests/Domain/PositionsViewInputTests.swift`

- [ ] **Step 3.1: Write the failing tests**

Append to `MoolahTests/Domain/PositionsViewInputTests.swift`:

```swift
@Suite("PositionsViewInput")
struct PositionsViewInputTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")

  private func amount(_ q: Decimal) -> InstrumentAmount {
    InstrumentAmount(quantity: q, instrument: aud)
  }

  @Test("totalValue sums all row values in host currency")
  func totalSumsRowValues() {
    let input = PositionsViewInput(
      title: "Brokerage",
      hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil, costBasis: nil,
          value: amount(11_325)),
        ValuedPosition(
          instrument: aud, quantity: 1_000, unitPrice: nil, costBasis: nil,
          value: amount(1_000)),
      ],
      historicalValue: nil
    )
    #expect(input.totalValue == amount(12_325))
  }

  @Test("totalValue is nil when any row's value is nil")
  func totalUnavailableOnFailure() {
    let input = PositionsViewInput(
      title: "Brokerage",
      hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil, costBasis: nil,
          value: amount(100)),
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil, costBasis: nil,
          value: nil),
      ],
      historicalValue: nil
    )
    #expect(input.totalValue == nil)
  }

  @Test("totalGainLoss sums per-row gain/loss; rows without cost contribute 0")
  func totalGainLossSums() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: amount(80), value: amount(100)),
        ValuedPosition(
          instrument: aud, quantity: 1, unitPrice: nil,
          costBasis: nil, value: amount(50)),
      ],
      historicalValue: nil
    )
    #expect(input.totalGainLoss == amount(20))
  }

  @Test("showsPLPill is false when no row has cost basis")
  func plPillHiddenWhenNoCostBasis() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: aud, quantity: 1, unitPrice: nil,
          costBasis: nil, value: amount(100))
      ],
      historicalValue: nil
    )
    #expect(!input.showsPLPill)
  }

  @Test("showsPLPill is false when total is unavailable")
  func plPillHiddenWhenTotalUnavailable() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: amount(50), value: nil)
      ],
      historicalValue: nil
    )
    #expect(!input.showsPLPill)
  }

  @Test("showsChart is false when historicalValue is nil")
  func chartHiddenWithoutSeries() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: amount(50), value: amount(60))
      ],
      historicalValue: nil
    )
    #expect(!input.showsChart)
  }

  @Test("showsChart is false when no row carries cost basis")
  func chartHiddenWithoutAnyCostBasis() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: aud, quantity: 1, unitPrice: nil,
          costBasis: nil, value: amount(100))
      ],
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [], perInstrument: [:])
    )
    #expect(!input.showsChart)
  }

  @Test("showsAggregateChart is false when any row's value is nil")
  func aggregateChartHiddenOnFailure() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: amount(50), value: amount(60)),
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: amount(40), value: nil),
      ],
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [], perInstrument: [:])
    )
    #expect(!input.showsAggregateChart)
    #expect(input.showsChart)  // chart can still render for working instruments
  }

  @Test("showsGroupSubtotals is true only when more than one kind is present")
  func subtotalsRequireMultipleKinds() {
    let stockOnly = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: nil, value: amount(60))
      ],
      historicalValue: nil
    )
    #expect(!stockOnly.showsGroupSubtotals)

    let mixed = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: nil, value: amount(60)),
        ValuedPosition(
          instrument: aud, quantity: 1, unitPrice: nil,
          costBasis: nil, value: amount(60)),
      ],
      historicalValue: nil
    )
    #expect(mixed.showsGroupSubtotals)
  }
}
```

- [ ] **Step 3.2: Run to verify it fails**

```bash
just test PositionsViewInputTests 2>&1 | tee .agent-tmp/test.txt
```

Expected: build failure "cannot find type 'PositionsViewInput' in scope".

- [ ] **Step 3.3: Implement the type**

Create `Domain/Models/PositionsViewInput.swift`:

```swift
import Foundation

/// Immutable input passed to `PositionsView`. Computed properties on this type
/// are the single place where header / chart visibility rules live, so the
/// view itself stays a thin renderer with no policy.
///
/// All monetary fields on the rows are expressed in `hostCurrency`. Per the
/// project's sign convention (CLAUDE.md), value, cost basis, and gain/loss
/// preserve their sign — callers must never `abs()` them.
struct PositionsViewInput: Sendable, Hashable {
  let title: String
  let hostCurrency: Instrument
  let positions: [ValuedPosition]
  let historicalValue: HistoricalValueSeries?

  /// Sum of per-row values. `nil` if any row's `value` is `nil` — per the
  /// project rule "never display a partial aggregate", a single conversion
  /// failure marks the whole total unavailable.
  var totalValue: InstrumentAmount? {
    var total = InstrumentAmount.zero(instrument: hostCurrency)
    for row in positions {
      guard let value = row.value else { return nil }
      total += value
    }
    return total
  }

  /// Sum of per-row gains. Rows without a cost basis contribute zero (their
  /// gain/loss is undefined). `nil` if `totalValue` is unavailable.
  var totalGainLoss: InstrumentAmount? {
    guard totalValue != nil else { return nil }
    var total = InstrumentAmount.zero(instrument: hostCurrency)
    for row in positions {
      if let gain = row.gainLoss {
        total += gain
      }
    }
    return total
  }

  /// `true` iff at least one row has a cost basis AND the total is available.
  var showsPLPill: Bool {
    guard totalValue != nil else { return false }
    return positions.contains(where: { $0.hasCostBasis })
  }

  /// `true` iff the chart container is rendered at all (a historical series
  /// exists and at least one row carries cost basis).
  var showsChart: Bool {
    guard historicalValue != nil else { return false }
    return positions.contains(where: { $0.hasCostBasis })
  }

  /// `true` iff the all-positions chart line should render. False when any
  /// row's current value is unavailable — partial historical totals would be
  /// misleading.
  var showsAggregateChart: Bool {
    guard showsChart, totalValue != nil else { return false }
    return true
  }

  /// `true` iff more than one `Instrument.Kind` is represented. Drives whether
  /// the table renders per-group subtotals.
  var showsGroupSubtotals: Bool {
    let kinds = Set(positions.map(\.instrument.kind))
    return kinds.count > 1
  }
}
```

- [ ] **Step 3.4: Run, format, commit**

```bash
just test PositionsViewInputTests 2>&1 | tee .agent-tmp/test.txt
grep -i 'failed\|error:' .agent-tmp/test.txt || echo "PASS"
just format
just generate
git -C . add Domain/Models/PositionsViewInput.swift \
  MoolahTests/Domain/PositionsViewInputTests.swift Moolah.xcodeproj
git -C . commit -m "feat(positions): add PositionsViewInput with visibility derivation"
```

---

## Task 4: Add `PositionsValuator` pure helper

**Files:**
- Create: `Shared/PositionsValuator.swift`
- Create: `MoolahTests/Shared/PositionsValuatorTests.swift`

- [ ] **Step 4.1: Write the failing tests**

Create `MoolahTests/Shared/PositionsValuatorTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("PositionsValuator")
struct PositionsValuatorTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let cba = Instrument.stock(ticker: "CBA.AX", exchange: "ASX", name: "CBA")

  @Test("converts each position to host currency on the given date")
  func convertsAll() async throws {
    let positions = [
      Position(instrument: bhp, quantity: 250),
      Position(instrument: cba, quantity: 80),
    ]
    let service = FixedConversionService(rates: [
      bhp.id: Decimal(45.30),
      cba.id: Decimal(120),
    ])
    let valuator = PositionsValuator(conversionService: service)
    let rows = try await valuator.valuate(
      positions: positions,
      hostCurrency: aud,
      costBasis: [:],
      on: Date()
    )

    let bhpRow = try #require(rows.first(where: { $0.instrument == bhp }))
    let cbaRow = try #require(rows.first(where: { $0.instrument == cba }))
    #expect(bhpRow.value == InstrumentAmount(quantity: 250 * Decimal(45.30), instrument: aud))
    #expect(bhpRow.unitPrice == InstrumentAmount(quantity: Decimal(45.30), instrument: aud))
    #expect(cbaRow.value == InstrumentAmount(quantity: 80 * Decimal(120), instrument: aud))
  }

  @Test("single-instrument fast path skips the conversion service")
  func fastPath() async throws {
    let positions = [Position(instrument: aud, quantity: 1_000)]
    // service throws for any conversion — must not be called for AUD->AUD.
    let service = FailingConversionService(failingInstrumentIds: [aud.id])
    let valuator = PositionsValuator(conversionService: service)
    let rows = try await valuator.valuate(
      positions: positions, hostCurrency: aud,
      costBasis: [:], on: Date()
    )
    #expect(rows.count == 1)
    #expect(rows[0].value == InstrumentAmount(quantity: 1_000, instrument: aud))
    // unitPrice is nil for the fast-path fiat row; meaningless to display
    // 1 AUD = $1.
    #expect(rows[0].unitPrice == nil)
  }

  @Test("per-row conversion failure leaves value nil; siblings still render")
  func perRowFailure() async throws {
    let positions = [
      Position(instrument: bhp, quantity: 100),
      Position(instrument: cba, quantity: 50),
    ]
    let service = FailingConversionService(
      rates: [bhp.id: Decimal(40)],
      failingInstrumentIds: [cba.id]
    )
    let valuator = PositionsValuator(conversionService: service)
    let rows = try await valuator.valuate(
      positions: positions, hostCurrency: aud,
      costBasis: [:], on: Date()
    )
    let bhpRow = try #require(rows.first(where: { $0.instrument == bhp }))
    let cbaRow = try #require(rows.first(where: { $0.instrument == cba }))
    #expect(bhpRow.value != nil)
    #expect(cbaRow.value == nil)
    #expect(cbaRow.quantity == 50)  // qty still rendered
  }

  @Test("cost basis snapshot is propagated into the row")
  func costBasisPropagated() async throws {
    let positions = [Position(instrument: bhp, quantity: 100)]
    let service = FixedConversionService(rates: [bhp.id: Decimal(50)])
    let valuator = PositionsValuator(conversionService: service)
    let rows = try await valuator.valuate(
      positions: positions, hostCurrency: aud,
      costBasis: [bhp.id: Decimal(4_000)], on: Date()
    )
    #expect(rows[0].costBasis == InstrumentAmount(quantity: 4_000, instrument: aud))
  }
}
```

(`FixedConversionService` and `FailingConversionService` already exist in `MoolahTests/Support/`.)

- [ ] **Step 4.2: Run to verify it fails**

```bash
just test PositionsValuatorTests 2>&1 | tee .agent-tmp/test.txt
```

Expected: "cannot find type 'PositionsValuator' in scope".

- [ ] **Step 4.3: Implement the helper**

Create `Shared/PositionsValuator.swift`:

```swift
import Foundation
import OSLog

/// Pure, async, throws-never helper that builds `[ValuedPosition]` for
/// `PositionsView` from a list of raw `Position`s plus an optional cost-basis
/// snapshot keyed by `Instrument.id`.
///
/// Per `guides/INSTRUMENT_CONVERSION_GUIDE.md`:
/// - Rule 8 (single-instrument fast path): rows whose instrument equals
///   `hostCurrency` skip the conversion service entirely.
/// - Rule 11 (per-row failure): a thrown conversion is logged and emitted as
///   a row with `value == nil`. Sibling rows still receive their successful
///   values. The aggregate visibility of the total / chart is the caller's
///   responsibility (see `PositionsViewInput.totalValue`).
struct PositionsValuator: Sendable {
  let conversionService: any InstrumentConversionService
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "PositionsValuator")

  /// Build one `ValuedPosition` per input position.
  ///
  /// - Parameters:
  ///   - positions: raw quantities per instrument (zeroes filtered upstream).
  ///   - hostCurrency: target instrument for value/unitPrice/costBasis.
  ///   - costBasis: remaining cost basis per instrument id, expressed in
  ///     `hostCurrency`. Use `[:]` when no cost basis is known (flow context).
  ///   - on: valuation date.
  /// - Returns: rows in input order. Never throws — failures map to
  ///   `value == nil` per row.
  func valuate(
    positions: [Position],
    hostCurrency: Instrument,
    costBasis: [String: Decimal],
    on date: Date
  ) async -> [ValuedPosition] {
    var rows: [ValuedPosition] = []
    rows.reserveCapacity(positions.count)
    for position in positions {
      rows.append(await row(for: position, hostCurrency: hostCurrency, costBasis: costBasis, on: date))
    }
    return rows
  }

  private func row(
    for position: Position,
    hostCurrency: Instrument,
    costBasis: [String: Decimal],
    on date: Date
  ) async -> ValuedPosition {
    let cost: InstrumentAmount? = costBasis[position.instrument.id].map {
      InstrumentAmount(quantity: $0, instrument: hostCurrency)
    }

    if position.instrument == hostCurrency {
      return ValuedPosition(
        instrument: position.instrument,
        quantity: position.quantity,
        unitPrice: nil,
        costBasis: cost,
        value: InstrumentAmount(quantity: position.quantity, instrument: hostCurrency)
      )
    }

    do {
      let total = try await conversionService.convert(
        position.quantity, from: position.instrument, to: hostCurrency, on: date
      )
      let unit: InstrumentAmount? =
        position.quantity == 0
        ? nil
        : InstrumentAmount(quantity: total / position.quantity, instrument: hostCurrency)
      return ValuedPosition(
        instrument: position.instrument,
        quantity: position.quantity,
        unitPrice: unit,
        costBasis: cost,
        value: InstrumentAmount(quantity: total, instrument: hostCurrency)
      )
    } catch {
      logger.warning(
        "Failed to valuate position \(position.instrument.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      return ValuedPosition(
        instrument: position.instrument,
        quantity: position.quantity,
        unitPrice: nil,
        costBasis: cost,
        value: nil
      )
    }
  }
}
```

(Note: `valuate` is annotated `async` not `async throws` — failures degrade per row, never as a thrown aggregate. Update the test accordingly: drop the `try` from the call sites.)

- [ ] **Step 4.4: Drop `try` from the test call sites**

In `MoolahTests/Shared/PositionsValuatorTests.swift`, replace each `try await valuator.valuate(...)` with `await valuator.valuate(...)` (the function does not throw).

- [ ] **Step 4.5: Run, format, commit**

```bash
just test PositionsValuatorTests 2>&1 | tee .agent-tmp/test.txt
grep -i 'failed\|error:' .agent-tmp/test.txt || echo "PASS"
just format
just generate
git -C . add Shared/PositionsValuator.swift \
  MoolahTests/Shared/PositionsValuatorTests.swift Moolah.xcodeproj
git -C . commit -m "feat(positions): add pure PositionsValuator helper"
```

---

## Task 5: Add `PositionsTimeRange` enum

**Files:**
- Create: `Shared/Views/Positions/PositionsTimeRange.swift`
- Create: `MoolahTests/Shared/PositionsTimeRangeTests.swift`

- [ ] **Step 5.1: Write the failing test**

Create `MoolahTests/Shared/PositionsTimeRangeTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("PositionsTimeRange")
struct PositionsTimeRangeTests {
  @Test("all has a nil cutoff (caller treats as: from earliest holding)")
  func allRangeUnbounded() {
    #expect(PositionsTimeRange.all.cutoff(from: Date()) == nil)
  }

  @Test("YTD cutoff is start-of-year for the given reference date")
  func ytdCutoff() {
    var components = DateComponents()
    components.year = 2026
    components.month = 4
    components.day = 20
    components.hour = 12
    let calendar = Calendar(identifier: .gregorian)
    let now = calendar.date(from: components)!
    let cutoff = PositionsTimeRange.ytd.cutoff(from: now)!

    let cutoffComponents = calendar.dateComponents([.year, .month, .day], from: cutoff)
    #expect(cutoffComponents.year == 2026)
    #expect(cutoffComponents.month == 1)
    #expect(cutoffComponents.day == 1)
  }

  @Test("month-based ranges subtract the right number of months")
  func monthRangeCutoff() {
    let now = Date(timeIntervalSince1970: 1_775_000_000)  // 2026-04-09 ish
    let calendar = Calendar(identifier: .gregorian)
    let oneMonth = PositionsTimeRange.oneMonth.cutoff(from: now)!
    let expected = calendar.date(byAdding: .month, value: -1, to: now)!
    #expect(abs(oneMonth.timeIntervalSince(expected)) < 1)
  }

  @Test("allCases includes all 6 picker entries in order")
  func allCasesOrder() {
    #expect(
      PositionsTimeRange.allCases == [
        .oneMonth, .threeMonths, .sixMonths, .ytd, .oneYear, .all,
      ]
    )
  }
}
```

- [ ] **Step 5.2: Run to verify it fails**

```bash
just test PositionsTimeRangeTests 2>&1 | tee .agent-tmp/test.txt
```

Expected: "cannot find type 'PositionsTimeRange'".

- [ ] **Step 5.3: Implement the enum**

Create `Shared/Views/Positions/PositionsTimeRange.swift`:

```swift
import Foundation

/// The six time-range options the chart picker offers, scoped to
/// `PositionsView`. Distinct from `Domain/Models/TimePeriod.swift` (which
/// covers a wider grid for reporting) so we don't over-fit the global type
/// to one screen's needs.
enum PositionsTimeRange: Hashable, Sendable, CaseIterable, Identifiable {
  case oneMonth
  case threeMonths
  case sixMonths
  case ytd
  case oneYear
  case all

  static var allCases: [PositionsTimeRange] {
    [.oneMonth, .threeMonths, .sixMonths, .ytd, .oneYear, .all]
  }

  var id: String { label }

  var label: String {
    switch self {
    case .oneMonth: return "1M"
    case .threeMonths: return "3M"
    case .sixMonths: return "6M"
    case .ytd: return "YTD"
    case .oneYear: return "1Y"
    case .all: return "All"
    }
  }

  /// First date inside the range, given a `now` reference. `nil` for `.all`
  /// (caller treats as "from the earliest available data point").
  func cutoff(from now: Date) -> Date? {
    let calendar = Calendar(identifier: .gregorian)
    switch self {
    case .oneMonth: return calendar.date(byAdding: .month, value: -1, to: now)
    case .threeMonths: return calendar.date(byAdding: .month, value: -3, to: now)
    case .sixMonths: return calendar.date(byAdding: .month, value: -6, to: now)
    case .ytd:
      let comps = calendar.dateComponents([.year], from: now)
      return calendar.date(from: comps)
    case .oneYear: return calendar.date(byAdding: .year, value: -1, to: now)
    case .all: return nil
    }
  }
}
```

- [ ] **Step 5.4: Run, format, commit**

```bash
just test PositionsTimeRangeTests 2>&1 | tee .agent-tmp/test.txt
grep -i 'failed\|error:' .agent-tmp/test.txt || echo "PASS"
just format
just generate
git -C . add Shared/Views/Positions/PositionsTimeRange.swift \
  MoolahTests/Shared/PositionsTimeRangeTests.swift Moolah.xcodeproj
git -C . commit -m "feat(positions): add PositionsTimeRange enum"
```

---

## Task 5b: Extract `TradeEventClassifier` from `CapitalGainsCalculator`

Cost basis (in both the per-row snapshot and the historical chart line) needs the same buy/sell classification that `CapitalGainsCalculator` already performs — *including* crypto-to-crypto swaps, where each non-fiat leg is converted to the host currency to derive the buy lot's cost or the sell's proceeds. Today that logic lives in two private functions inside `CapitalGainsCalculator`. Extract them into a single shared helper so `PositionsHistoryBuilder` and `InvestmentStore` use exactly one code path.

**Files:**
- Create: `Shared/TradeEventClassifier.swift`
- Create: `MoolahTests/Shared/TradeEventClassifierTests.swift`
- Modify: `Shared/CapitalGainsCalculator.swift`

- [ ] **Step 5b.1: Write the failing classifier tests**

Create `MoolahTests/Shared/TradeEventClassifierTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("TradeEventClassifier")
struct TradeEventClassifierTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  let btc = Instrument.crypto(
    chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8)
  let date = Date(timeIntervalSince1970: 1_700_000_000)

  @Test("fiat-paired buy: emits one buy event with cost-per-unit derived from fiat outflow")
  func fiatPairedBuy() async throws {
    let legs = [
      TransactionLeg(accountId: UUID(), instrument: bhp, quantity: 100, type: .income),
      TransactionLeg(accountId: UUID(), instrument: aud, quantity: -4_000, type: .expense),
    ]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud,
      conversionService: FixedConversionService(rates: [:])
    )
    #expect(result.buys.count == 1)
    #expect(result.buys[0].instrument == bhp)
    #expect(result.buys[0].quantity == 100)
    #expect(result.buys[0].costPerUnit == 40)
    #expect(result.sells.isEmpty)
  }

  @Test("fiat-paired sell: emits one sell event with proceeds-per-unit")
  func fiatPairedSell() async throws {
    let legs = [
      TransactionLeg(accountId: UUID(), instrument: bhp, quantity: -50, type: .income),
      TransactionLeg(accountId: UUID(), instrument: aud, quantity: 2_500, type: .income),
    ]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud,
      conversionService: FixedConversionService(rates: [:])
    )
    #expect(result.sells.count == 1)
    #expect(result.sells[0].instrument == bhp)
    #expect(result.sells[0].quantity == 50)
    #expect(result.sells[0].proceedsPerUnit == 50)
  }

  @Test("crypto-to-crypto swap: emits one buy + one sell, each priced via the conversion service")
  func swap() async throws {
    let legs = [
      TransactionLeg(accountId: UUID(), instrument: eth, quantity: -2, type: .income),
      TransactionLeg(accountId: UUID(), instrument: btc, quantity: 0.1, type: .income),
    ]
    let service = FixedConversionService(rates: [
      eth.id: Decimal(3_000),  // 1 ETH = 3000 AUD
      btc.id: Decimal(60_000),  // 1 BTC = 60000 AUD
    ])
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud, conversionService: service
    )
    #expect(result.sells.count == 1)
    #expect(result.sells[0].instrument == eth)
    #expect(result.sells[0].quantity == 2)
    #expect(result.sells[0].proceedsPerUnit == 3_000)

    #expect(result.buys.count == 1)
    #expect(result.buys[0].instrument == btc)
    #expect(result.buys[0].quantity == Decimal(string: "0.1")!)
    #expect(result.buys[0].costPerUnit == 60_000)
  }
}
```

- [ ] **Step 5b.2: Run to verify it fails**

```bash
just test TradeEventClassifierTests 2>&1 | tee .agent-tmp/test.txt
```

Expected: "cannot find 'TradeEventClassifier' in scope".

- [ ] **Step 5b.3: Implement the extracted classifier**

Create `Shared/TradeEventClassifier.swift`:

```swift
import Foundation

/// One step in the FIFO cost-basis machine. The shape mirrors what
/// `CostBasisEngine.processBuy` / `processSell` consume, so callers can feed
/// these straight in.
struct TradeBuyEvent: Sendable, Equatable {
  let instrument: Instrument
  let quantity: Decimal
  let costPerUnit: Decimal
}

struct TradeSellEvent: Sendable, Equatable {
  let instrument: Instrument
  let quantity: Decimal
  let proceedsPerUnit: Decimal
}

struct TradeEventClassification: Sendable {
  let buys: [TradeBuyEvent]
  let sells: [TradeSellEvent]
}

/// Classifies a single transaction's legs into FIFO buy / sell events.
///
/// Two cases:
///
/// **Fiat-paired:** non-fiat legs paired with one or more fiat legs in the
/// same transaction. Cost / proceeds-per-unit derive from `fiatOutflow /
/// qty` or `fiatInflow / qty`. Mixed-currency fiat is allowed: each fiat
/// leg is converted to `hostCurrency` on the txn date before being summed
/// (per `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 1).
///
/// **Non-fiat swap:** every leg is non-fiat (e.g. ETH → BTC). Each leg's
/// signed quantity is converted to `hostCurrency`; positive legs are buys
/// (cost = converted value / qty), negative legs are sells (proceeds =
/// converted value / qty).
///
/// Per CLAUDE.md sign convention, signs are preserved end-to-end; we never
/// `abs()` a raw leg quantity. Per-unit values are always positive because
/// numerator and denominator share the leg's sign.
///
/// This is the single source of truth used by both
/// `CapitalGainsCalculator` (tax reporting) and the
/// `PositionsHistoryBuilder` / `InvestmentStore` cost-basis snapshots
/// (chart + per-row).
enum TradeEventClassifier {
  static func classify(
    legs: [TransactionLeg],
    on date: Date,
    hostCurrency: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> TradeEventClassification {
    let fiatLegs = legs.filter { $0.instrument.kind == .fiatCurrency }
    let nonFiatLegs = legs.filter { $0.instrument.kind != .fiatCurrency }

    var fiatOutflow: Decimal = 0
    var fiatInflow: Decimal = 0
    for leg in fiatLegs where leg.quantity != 0 {
      let converted = try await conversionService.convert(
        leg.quantity, from: leg.instrument, to: hostCurrency, on: date
      )
      if leg.quantity < 0 {
        fiatOutflow -= converted
      } else {
        fiatInflow += converted
      }
    }

    var buys: [TradeBuyEvent] = []
    var sells: [TradeSellEvent] = []
    for leg in nonFiatLegs {
      if leg.quantity > 0 && fiatOutflow > 0 {
        buys.append(
          TradeBuyEvent(
            instrument: leg.instrument, quantity: leg.quantity,
            costPerUnit: fiatOutflow / leg.quantity))
      } else if leg.quantity < 0 && fiatInflow > 0 {
        let sellQty = -leg.quantity
        sells.append(
          TradeSellEvent(
            instrument: leg.instrument, quantity: sellQty,
            proceedsPerUnit: fiatInflow / sellQty))
      }
    }
    if !buys.isEmpty || !sells.isEmpty {
      return TradeEventClassification(buys: buys, sells: sells)
    }

    // Non-fiat swap: every leg is non-fiat.
    guard nonFiatLegs.count >= 2 else {
      return TradeEventClassification(buys: [], sells: [])
    }
    for leg in nonFiatLegs {
      let profileValue = try await conversionService.convert(
        leg.quantity, from: leg.instrument, to: hostCurrency, on: date
      )
      let valuePerUnit = profileValue / leg.quantity
      if leg.quantity > 0 {
        buys.append(
          TradeBuyEvent(
            instrument: leg.instrument, quantity: leg.quantity, costPerUnit: valuePerUnit))
      } else {
        let sellQty = -leg.quantity
        sells.append(
          TradeSellEvent(
            instrument: leg.instrument, quantity: sellQty, proceedsPerUnit: valuePerUnit))
      }
    }
    return TradeEventClassification(buys: buys, sells: sells)
  }
}
```

- [ ] **Step 5b.4: Replace the inline classifier in `CapitalGainsCalculator`**

In `Shared/CapitalGainsCalculator.swift`:

1. Delete the private `BuyEvent` / `SellEvent` structs and the private `classifyLegs(...)` / `classifyLegsWithConversion(...)` functions (currently spanning roughly lines 128-278).

2. Replace the body of `compute(transactions:profileCurrency:sellDateRange:)` and `computeWithConversion(...)` so they call `TradeEventClassifier.classify` instead of the deleted helpers. For the synchronous `compute`, a fiat-only conversion service (use `FiatConversionService` available in the same target — confirm by grep) provides instant fiat-to-fiat conversions; or, simpler: change the synchronous `compute` to async and call the unified classifier. Audit every caller of `compute(...)` and update them.

   Concrete patch — replace `compute(transactions:profileCurrency:sellDateRange:)` with:

   ```swift
   static func computeWithConversion(
     transactions: [LegTransaction],
     profileCurrency: Instrument,
     conversionService: any InstrumentConversionService,
     sellDateRange: ClosedRange<Date>? = nil
   ) async throws -> CapitalGainsResult {
     var engine = CostBasisEngine()
     var allEvents: [CapitalGainEvent] = []
     let sorted = transactions.sorted { $0.date < $1.date }

     for tx in sorted {
       let classification = try await TradeEventClassifier.classify(
         legs: tx.legs, on: tx.date,
         hostCurrency: profileCurrency,
         conversionService: conversionService
       )
       for buy in classification.buys {
         engine.processBuy(
           instrument: buy.instrument, quantity: buy.quantity,
           costPerUnit: buy.costPerUnit, date: tx.date)
       }
       for sell in classification.sells {
         let inRange = sellDateRange.map { $0.contains(tx.date) } ?? true
         let events = engine.processSell(
           instrument: sell.instrument, quantity: sell.quantity,
           proceedsPerUnit: sell.proceedsPerUnit, date: tx.date)
         if inRange { allEvents.append(contentsOf: events) }
       }
     }
     return CapitalGainsResult(events: allEvents, openLots: engine.allOpenLots())
   }
   ```

   Then either delete the synchronous `compute(...)` (if no caller depends on it) or wrap it as `try await computeWithConversion(transactions:profileCurrency:conversionService: FiatConversionService.identity, sellDateRange:)`. Run `grep -rn "CapitalGainsCalculator.compute(" --include="*.swift"` to find callers and update each.

- [ ] **Step 5b.5: Run the existing capital-gains tests + the new classifier tests**

```bash
just test TradeEventClassifierTests CapitalGainsCalculatorTests 2>&1 | tee .agent-tmp/test.txt
grep -i 'failed\|error:' .agent-tmp/test.txt || echo "PASS"
just test 2>&1 | tee .agent-tmp/test-all.txt
grep -i 'failed\|error:' .agent-tmp/test-all.txt || echo "ALL PASS"
```

Expected: pre-existing `CapitalGainsCalculatorTests` keep passing (extraction is pure refactor).

- [ ] **Step 5b.6: Format, commit**

```bash
just format
just generate
git -C . add Shared/TradeEventClassifier.swift Shared/CapitalGainsCalculator.swift \
  MoolahTests/Shared/TradeEventClassifierTests.swift Moolah.xcodeproj
git -C . commit -m "refactor(positions): extract TradeEventClassifier from CapitalGainsCalculator"
```

---

## Task 6: Add `PositionsHistoryBuilder` for the chart series

**Files:**
- Create: `Shared/PositionsHistoryBuilder.swift`
- Create: `MoolahTests/Shared/PositionsHistoryBuilderTests.swift`

- [ ] **Step 6.1: Write the failing tests**

Create `MoolahTests/Shared/PositionsHistoryBuilderTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("PositionsHistoryBuilder")
struct PositionsHistoryBuilderTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let cba = Instrument.stock(ticker: "CBA.AX", exchange: "ASX", name: "CBA")
  let accountId = UUID()

  /// Day 0 = 2026-01-01.
  private func date(daysAfterEpoch days: Int) -> Date {
    var components = DateComponents()
    components.year = 2026
    components.month = 1
    components.day = 1 + days
    return Calendar(identifier: .gregorian).date(from: components)!
  }

  private func buy(
    instrument: Instrument, qty: Decimal, fiat: Decimal, daysAfterEpoch days: Int
  ) -> Transaction {
    Transaction(
      date: date(daysAfterEpoch: days),
      legs: [
        TransactionLeg(accountId: accountId, instrument: instrument, quantity: qty, type: .income),
        TransactionLeg(accountId: accountId, instrument: aud, quantity: -fiat, type: .expense),
      ]
    )
  }

  @Test("value series emits one point per day in range; aggregate sums across instruments")
  func dailyValueSeries() async throws {
    let txns = [
      buy(instrument: bhp, qty: 100, fiat: 4_000, daysAfterEpoch: 1),
      buy(instrument: cba, qty: 50, fiat: 5_000, daysAfterEpoch: 2),
    ]
    let service = FixedConversionService(rates: [
      bhp.id: Decimal(50),
      cba.id: Decimal(110),
    ])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let now = date(daysAfterEpoch: 5)
    let series = await builder.build(
      transactions: txns,
      accountId: accountId,
      hostCurrency: aud,
      range: .oneMonth,
      now: now
    )

    // Daily samples from cutoff (or first holding date) through `now`.
    // First holding is day 1 (BHP buy), so total range is days 1..5 = 5 points.
    #expect(series.totalSeries.count == 5)

    // Last day = both holdings priced.
    let last = try #require(series.totalSeries.last)
    #expect(last.value == 100 * Decimal(50) + 50 * Decimal(110))

    // Day 1 (only BHP held).
    let firstAggregate = try #require(series.totalSeries.first)
    #expect(firstAggregate.value == 100 * Decimal(50))
  }

  @Test("cost-basis points appear at every event plus a closing point")
  func costBasisIsExactStepFunction() async throws {
    let txns = [
      buy(instrument: bhp, qty: 100, fiat: 4_000, daysAfterEpoch: 1),
      buy(instrument: bhp, qty: 50, fiat: 2_500, daysAfterEpoch: 10),
    ]
    let service = FixedConversionService(rates: [bhp.id: Decimal(50)])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let now = date(daysAfterEpoch: 30)

    let series = await builder.build(
      transactions: txns, accountId: accountId,
      hostCurrency: aud, range: .threeMonths, now: now
    )

    // The per-instrument series is one point per day. Cost on each daily
    // point reflects the cumulative cost basis at that date — exact step
    // function: 4_000 from day 1, 6_500 from day 10 onwards.
    let bhpSeries = series.series(for: bhp)
    let day5 = try #require(bhpSeries.first { Calendar.current.isDate($0.date, inSameDayAs: date(daysAfterEpoch: 5)) })
    let day20 = try #require(bhpSeries.first { Calendar.current.isDate($0.date, inSameDayAs: date(daysAfterEpoch: 20)) })
    #expect(day5.cost == 4_000)
    #expect(day20.cost == 6_500)
  }

  @Test("aggregate point is omitted on days where any instrument's conversion fails")
  func aggregateSkipsOnPartialFailure() async {
    let txns = [
      buy(instrument: bhp, qty: 100, fiat: 4_000, daysAfterEpoch: 1),
      buy(instrument: cba, qty: 50, fiat: 5_000, daysAfterEpoch: 2),
    ]
    let service = FailingConversionService(
      rates: [bhp.id: Decimal(50)],
      failingInstrumentIds: [cba.id]
    )
    let builder = PositionsHistoryBuilder(conversionService: service)
    let series = await builder.build(
      transactions: txns, accountId: accountId,
      hostCurrency: aud, range: .threeMonths,
      now: date(daysAfterEpoch: 5)
    )
    // From day 2 onwards CBA is held; every aggregate point that includes
    // CBA must be skipped.
    #expect(series.totalSeries.allSatisfy { $0.date < self.date(daysAfterEpoch: 2) })
    // Per-instrument BHP still has full daily coverage.
    #expect(series.series(for: bhp).count == 5)
  }

  @Test("range cutoff drops samples earlier than the requested window")
  func rangeFilters() async {
    let txns = [
      buy(instrument: bhp, qty: 10, fiat: 500, daysAfterEpoch: 0)
    ]
    let service = FixedConversionService(rates: [bhp.id: Decimal(60)])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let now = date(daysAfterEpoch: 200)
    let oneMonth = await builder.build(
      transactions: txns, accountId: accountId,
      hostCurrency: aud, range: .oneMonth, now: now
    )
    let cutoff = PositionsTimeRange.oneMonth.cutoff(from: now)!
    let cutoffDay = Calendar(identifier: .gregorian).startOfDay(for: cutoff)
    #expect(oneMonth.totalSeries.allSatisfy { $0.date >= cutoffDay })
  }
}
```

- [ ] **Step 6.2: Run to verify it fails**

```bash
just test PositionsHistoryBuilderTests 2>&1 | tee .agent-tmp/test.txt
```

Expected: "cannot find type 'PositionsHistoryBuilder'".

- [ ] **Step 6.3: Implement the builder**

Create `Shared/PositionsHistoryBuilder.swift`:

```swift
import Foundation
import OSLog

/// Builds the `(value, cost)` time series the chart in `PositionsView` plots.
///
/// **Cost basis line is exact.** Cost only changes on transaction events, so
/// we walk transactions chronologically through `CostBasisEngine` once and
/// emit the resulting `(quantity, remainingCost)` snapshot for *every* day
/// in the visible range. Days between events carry forward the prior
/// snapshot — no interpolation, no approximation.
///
/// **Value line is queried daily.** For each day `d` in
/// `[startOfRange ... today]` and each instrument with a non-zero holding
/// on `d`, we ask the conversion service for `convert(qty, instrument,
/// hostCurrency, on: d)`. The conversion service is backed by
/// `StockPriceCache` / `ExchangeRateCache` / `CryptoPriceCache`, so the
/// only network calls are for prices not yet in cache; subsequent loads of
/// the same chart (and overlapping ranges across users of the same
/// instrument) are O(1) per day. There is no sampling, no smoothing — the
/// chart shows the actual portfolio value on every day.
///
/// Aggregate points are emitted only when *every* contributing
/// per-instrument conversion succeeds on that date — partial sums are
/// forbidden by `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 11. A
/// per-instrument series whose conversion fails for some days simply
/// omits those days; sibling instruments still chart.
///
/// Cancellation: callers should run this from a `.task { ... }` so it is
/// torn down when the view goes away. We check `Task.isCancelled` once per
/// day to bail out quickly on dismissal.
struct PositionsHistoryBuilder: Sendable {
  let conversionService: any InstrumentConversionService
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "PositionsHistoryBuilder")

  func build(
    transactions: [Transaction],
    accountId: UUID,
    hostCurrency: Instrument,
    range: PositionsTimeRange,
    now: Date = Date()
  ) async -> HistoricalValueSeries {
    let calendar = Calendar(identifier: .gregorian)
    let sortedTxns = transactions
      .filter { $0.legs.contains(where: { $0.accountId == accountId }) }
      .sorted { $0.date < $1.date }

    guard let firstTxnDate = sortedTxns.first?.date else {
      return HistoricalValueSeries(
        hostCurrency: hostCurrency, total: [], perInstrument: [:])
    }

    // Range start: max of (cutoff for selected range, first holding date).
    let cutoff = range.cutoff(from: now) ?? firstTxnDate
    let start = calendar.startOfDay(for: max(cutoff, firstTxnDate))
    let endDay = calendar.startOfDay(for: now)
    guard endDay >= start else {
      return HistoricalValueSeries(
        hostCurrency: hostCurrency, total: [], perInstrument: [:])
    }

    // Pre-compute per-day snapshots in one pass over transactions. We fold
    // each transaction into a running snapshot, then on every distinct
    // event date emit "the snapshot as of end-of-that-day". Days in between
    // events carry the prior snapshot forward.
    var quantities: [Instrument: Decimal] = [:]
    var engine = CostBasisEngine()
    var txnIndex = 0

    var perInstrument: [String: [HistoricalValueSeries.Point]] = [:]
    var total: [HistoricalValueSeries.Point] = []

    // Pre-fold any transactions strictly before `start` so the snapshot at
    // `start` already reflects historical buys.
    while txnIndex < sortedTxns.count
      && calendar.startOfDay(for: sortedTxns[txnIndex].date) < start
    {
      await apply(
        transaction: sortedTxns[txnIndex], accountId: accountId,
        hostCurrency: hostCurrency,
        quantities: &quantities, engine: &engine
      )
      txnIndex += 1
    }

    var day = start
    while day <= endDay {
      if Task.isCancelled { return HistoricalValueSeries(
        hostCurrency: hostCurrency, total: total, perInstrument: perInstrument) }

      // Apply every transaction whose start-of-day is `day`.
      while txnIndex < sortedTxns.count
        && calendar.startOfDay(for: sortedTxns[txnIndex].date) == day
      {
        await apply(
          transaction: sortedTxns[txnIndex], accountId: accountId,
          hostCurrency: hostCurrency,
          quantities: &quantities, engine: &engine
        )
        txnIndex += 1
      }

      // Emit a point per held instrument + an aggregate (when complete).
      var aggValue: Decimal = 0
      var aggCost: Decimal = 0
      var aggOK = true
      var anyHeld = false

      for (instrument, qty) in quantities where qty != 0 {
        anyHeld = true
        let cost = engine.openLots(for: instrument)
          .reduce(Decimal(0)) { $0 + $1.remainingCost }

        let value: Decimal?
        if instrument == hostCurrency {
          value = qty
        } else {
          do {
            value = try await conversionService.convert(
              qty, from: instrument, to: hostCurrency, on: day)
          } catch {
            logger.warning(
              "history conversion failed for \(instrument.id, privacy: .public) on \(day, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            value = nil
            aggOK = false
          }
        }

        if let value {
          perInstrument[instrument.id, default: []].append(
            HistoricalValueSeries.Point(date: day, value: value, cost: cost))
          aggValue += value
          aggCost += cost
        }
      }

      if anyHeld && aggOK {
        total.append(HistoricalValueSeries.Point(date: day, value: aggValue, cost: aggCost))
      }

      guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
      day = next
    }

    return HistoricalValueSeries(
      hostCurrency: hostCurrency, total: total, perInstrument: perInstrument)
  }

  /// Fold one transaction into the running quantity dict and FIFO engine.
  ///
  /// Quantities update directly from the account's signed leg quantities
  /// (so an ETH→BTC swap subtracts ETH and adds BTC). Cost basis updates
  /// via the shared `TradeEventClassifier`, which handles fiat-paired
  /// trades AND crypto-to-crypto swaps — for a swap, ETH gets a sell event
  /// (proceeds = host-currency value of ETH on this date) and BTC gets a
  /// buy event (cost = host-currency value of BTC on this date).
  private func apply(
    transaction: Transaction,
    accountId: UUID,
    hostCurrency: Instrument,
    quantities: inout [Instrument: Decimal],
    engine: inout CostBasisEngine
  ) async {
    let accountLegs = transaction.legs.filter { $0.accountId == accountId }
    for leg in accountLegs {
      quantities[leg.instrument, default: 0] += leg.quantity
    }

    do {
      let classification = try await TradeEventClassifier.classify(
        legs: accountLegs, on: transaction.date,
        hostCurrency: hostCurrency, conversionService: conversionService
      )
      for buy in classification.buys {
        engine.processBuy(
          instrument: buy.instrument, quantity: buy.quantity,
          costPerUnit: buy.costPerUnit, date: transaction.date)
      }
      for sell in classification.sells {
        _ = engine.processSell(
          instrument: sell.instrument, quantity: sell.quantity,
          proceedsPerUnit: sell.proceedsPerUnit, date: transaction.date)
      }
    } catch {
      // A failed conversion when classifying a swap means we cannot derive
      // a cost basis for this leg. Quantities still update so the value
      // line is correct; cost basis on the affected instrument simply
      // stops advancing (the chart will draw a flat dashed line through
      // the gap, which is the honest representation of "we don't know").
      logger.warning(
        "TradeEventClassifier failed for txn \(transaction.id, privacy: .public) on \(transaction.date, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
  }
}
```

- [ ] **Step 6.4: Run, format, commit**

```bash
just test PositionsHistoryBuilderTests 2>&1 | tee .agent-tmp/test.txt
grep -i 'failed\|error:' .agent-tmp/test.txt || echo "PASS"
just format
just generate
git -C . add Shared/PositionsHistoryBuilder.swift \
  MoolahTests/Shared/PositionsHistoryBuilderTests.swift Moolah.xcodeproj
git -C . commit -m "feat(positions): add PositionsHistoryBuilder for chart series"
```

---

## Task 7: Add `PositionRow` view

**Files:**
- Create: `Shared/Views/Positions/PositionRow.swift`

(No new tests — preview validation is covered by Task 11; row math is covered by `ValuedPositionTests`.)

- [ ] **Step 7.1: Implement the row**

Create `Shared/Views/Positions/PositionRow.swift`:

```swift
import SwiftUI

/// Single-row presentation in `PositionsTable`. Used by both the wide
/// (`Table`) layout (where columns position the cells) and the narrow
/// (`List`) layout (where the row composes its own two-line layout).
///
/// Failed valuations render as `—` per `guides/UI_GUIDE.md`. Signs are
/// preserved across value, cost, and gain — the row never `abs()`s an amount.
struct PositionRow: View {
  let row: ValuedPosition

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          KindBadge(kind: row.instrument.kind)
          Text(row.instrument.name)
            .font(.headline)
        }
        if let secondary = secondaryIdentifier {
          Text(secondary)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text(quantityText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 2) {
        if let value = row.value {
          Text(value.formatted)
            .monospacedDigit()
        } else {
          Text("—")
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Value unavailable")
        }
        if let gain = row.gainLoss {
          Text(gainText(gain))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(gain.isNegative ? .red : .green)
        }
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
  }

  private var quantityText: String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = min(row.instrument.decimals, 8)
    let qty = formatter.string(from: row.quantity as NSDecimalNumber) ?? "\(row.quantity)"
    switch row.instrument.kind {
    case .fiatCurrency: return InstrumentAmount(quantity: row.quantity, instrument: row.instrument).formatted
    case .stock: return "\(qty) shares"
    case .cryptoToken: return "\(qty) \(row.instrument.displayLabel)"
    }
  }

  private var secondaryIdentifier: String? {
    switch row.instrument.kind {
    case .stock: return row.instrument.exchange
    case .cryptoToken:
      if let chainId = row.instrument.chainId {
        return Instrument.chainName(for: chainId)
      }
      return nil
    case .fiatCurrency: return nil
    }
  }

  private func gainText(_ gain: InstrumentAmount) -> String {
    let sign = gain.quantity > 0 ? "+" : ""
    return "\(sign)\(gain.formatted)"
  }

  private var accessibilityLabel: String {
    var parts: [String] = [row.instrument.name, quantityText]
    if let value = row.value {
      parts.append("valued at \(value.formatted)")
    } else {
      parts.append("value unavailable")
    }
    if let gain = row.gainLoss {
      parts.append("gain \(gainText(gain))")
    }
    return parts.joined(separator: ", ")
  }
}

/// Coloured badge prefix for a row, distinguishing instrument kinds at a
/// glance. Colours are semantic (no hardcoded RGB).
struct KindBadge: View {
  let kind: Instrument.Kind

  var body: some View {
    let (label, tint): (String, Color) = {
      switch kind {
      case .stock: return ("S", .blue)
      case .cryptoToken: return ("C", .orange)
      case .fiatCurrency: return ("$", .secondary)
      }
    }()
    Text(label)
      .font(.caption2.weight(.bold))
      .foregroundStyle(.white)
      .frame(width: 18, height: 18)
      .background(tint, in: RoundedRectangle(cornerRadius: 4))
      .accessibilityHidden(true)
  }
}

#Preview("rows") {
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  let aud = Instrument.AUD
  List {
    PositionRow(
      row: ValuedPosition(
        instrument: bhp, quantity: 250,
        unitPrice: InstrumentAmount(quantity: 45.30, instrument: aud),
        costBasis: InstrumentAmount(quantity: 10_125, instrument: aud),
        value: InstrumentAmount(quantity: 11_325, instrument: aud)
      ))
    PositionRow(
      row: ValuedPosition(
        instrument: eth, quantity: 2.45,
        unitPrice: InstrumentAmount(quantity: 4_000, instrument: aud),
        costBasis: InstrumentAmount(quantity: 7_500, instrument: aud),
        value: InstrumentAmount(quantity: 9_800, instrument: aud)
      ))
    PositionRow(
      row: ValuedPosition(
        instrument: aud, quantity: 1_520,
        unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 1_520, instrument: aud)
      ))
    PositionRow(
      row: ValuedPosition(
        instrument: bhp, quantity: 100,
        unitPrice: nil, costBasis: nil, value: nil))
  }
  .frame(width: 420)
}
```

- [ ] **Step 7.2: Build & format & commit**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/build.txt
grep -i 'error:' .agent-tmp/build.txt || echo "BUILD OK"
just format
git -C . add Shared/Views/Positions/PositionRow.swift Moolah.xcodeproj
git -C . commit -m "feat(positions): add PositionRow"
```

---

## Task 8: Add `PositionsTable` (wide + narrow layouts)

**Files:**
- Create: `Shared/Views/Positions/PositionsTable.swift`

- [ ] **Step 8.1: Implement the table**

Create `Shared/Views/Positions/PositionsTable.swift`:

```swift
import SwiftUI

/// Responsive table of `ValuedPosition`s. On wide layouts (macOS, regular iOS
/// width) renders a `Table` with sortable columns. On compact layouts falls
/// back to a `List` of `PositionRow`s.
///
/// Group subtotals only render when more than one `Instrument.Kind` is
/// present (per `PositionsViewInput.showsGroupSubtotals`).
struct PositionsTable: View {
  let input: PositionsViewInput
  @Binding var selection: Instrument?

  @Environment(\.horizontalSizeClass) private var sizeClass

  var body: some View {
    Group {
      #if os(macOS)
        wideLayout
      #else
        if sizeClass == .regular {
          wideLayout
        } else {
          narrowLayout
        }
      #endif
    }
  }

  private var groups: [InstrumentGroup] {
    InstrumentGroup.from(input.positions)
  }

  // MARK: - Wide

  @ViewBuilder
  private var wideLayout: some View {
    let allRows = groups.flatMap(\.rows)
    Table(allRows, selection: rowSelectionBinding) {
      TableColumn("Instrument") { row in
        HStack(spacing: 6) {
          KindBadge(kind: row.instrument.kind)
          VStack(alignment: .leading) {
            Text(row.instrument.name)
            if let exchange = row.instrument.exchange {
              Text(exchange).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
      TableColumn("Qty") { row in
        Text(qtyString(for: row))
          .monospacedDigit()
      }
      TableColumn("Unit Price") { row in
        if let unit = row.unitPrice {
          Text(unit.formatted).monospacedDigit()
        } else {
          Text("—").foregroundStyle(.tertiary)
        }
      }
      TableColumn("Cost") { row in
        if let cost = row.costBasis {
          Text(cost.formatted).monospacedDigit()
        } else {
          Text("—").foregroundStyle(.tertiary)
        }
      }
      TableColumn("Value") { row in
        if let value = row.value {
          Text(value.formatted).monospacedDigit()
        } else {
          Text("—").foregroundStyle(.tertiary)
        }
      }
      TableColumn("Gain") { row in
        if let gain = row.gainLoss {
          Text(gainString(gain))
            .monospacedDigit()
            .foregroundStyle(gain.isNegative ? .red : .green)
        } else {
          Text("—").foregroundStyle(.tertiary)
        }
      }
    }
  }

  /// `Table` selects on `id` (which is `instrument.id`); we adapt that to
  /// our `Instrument?` selection binding.
  private var rowSelectionBinding: Binding<Set<String>> {
    Binding(
      get: { selection.map { [$0.id] } ?? [] },
      set: { ids in
        if let id = ids.first, let instrument = input.positions.first(where: { $0.id == id })?.instrument {
          selection = (selection?.id == id) ? nil : instrument
        } else {
          selection = nil
        }
      }
    )
  }

  // MARK: - Narrow

  @ViewBuilder
  private var narrowLayout: some View {
    List {
      ForEach(groups) { group in
        if input.showsGroupSubtotals {
          Section(group.title) {
            ForEach(group.rows) { row in
              PositionRow(row: row)
                .contentShape(Rectangle())
                .onTapGesture {
                  selection = (selection == row.instrument) ? nil : row.instrument
                }
                .background(selection == row.instrument ? Color.accentColor.opacity(0.12) : .clear)
            }
          }
        } else {
          ForEach(group.rows) { row in
            PositionRow(row: row)
              .contentShape(Rectangle())
              .onTapGesture {
                selection = (selection == row.instrument) ? nil : row.instrument
              }
              .background(selection == row.instrument ? Color.accentColor.opacity(0.12) : .clear)
          }
        }
      }
    }
    #if !os(macOS)
      .listStyle(.plain)
    #endif
  }

  // MARK: - Helpers

  private func qtyString(for row: ValuedPosition) -> String {
    switch row.instrument.kind {
    case .fiatCurrency:
      return InstrumentAmount(quantity: row.quantity, instrument: row.instrument).formatted
    case .stock:
      let formatter = NumberFormatter()
      formatter.numberStyle = .decimal
      formatter.maximumFractionDigits = row.instrument.decimals
      return formatter.string(from: row.quantity as NSDecimalNumber) ?? "\(row.quantity)"
    case .cryptoToken:
      let formatter = NumberFormatter()
      formatter.numberStyle = .decimal
      formatter.maximumFractionDigits = min(row.instrument.decimals, 8)
      let qty = formatter.string(from: row.quantity as NSDecimalNumber) ?? "\(row.quantity)"
      return "\(qty) \(row.instrument.displayLabel)"
    }
  }

  private func gainString(_ gain: InstrumentAmount) -> String {
    let sign = gain.quantity > 0 ? "+" : ""
    return "\(sign)\(gain.formatted)"
  }
}

/// Internal grouping helper — splits the rows into Stocks / Crypto / Cash
/// in spec order. Each group is empty if no row of that kind appears.
struct InstrumentGroup: Identifiable {
  enum Kind { case stocks, crypto, cash }
  let kind: Kind
  let rows: [ValuedPosition]
  var id: String {
    switch kind {
    case .stocks: return "stocks"
    case .crypto: return "crypto"
    case .cash: return "cash"
    }
  }
  var title: String {
    switch kind {
    case .stocks: return "Stocks"
    case .crypto: return "Crypto"
    case .cash: return "Cash"
    }
  }

  static func from(_ rows: [ValuedPosition]) -> [InstrumentGroup] {
    let stocks = rows.filter { $0.instrument.kind == .stock }
    let crypto = rows.filter { $0.instrument.kind == .cryptoToken }
    let cash = rows.filter { $0.instrument.kind == .fiatCurrency }
    return [
      .init(kind: .stocks, rows: stocks),
      .init(kind: .crypto, rows: crypto),
      .init(kind: .cash, rows: cash),
    ].filter { !$0.rows.isEmpty }
  }
}
```

- [ ] **Step 8.2: Build, format, commit**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/build.txt
grep -i 'error:' .agent-tmp/build.txt || echo "BUILD OK"
just format
git -C . add Shared/Views/Positions/PositionsTable.swift Moolah.xcodeproj
git -C . commit -m "feat(positions): add responsive PositionsTable with grouping"
```

---

## Task 9: Add `PositionsHeader`

**Files:**
- Create: `Shared/Views/Positions/PositionsHeader.swift`

- [ ] **Step 9.1: Implement the header**

Create `Shared/Views/Positions/PositionsHeader.swift`:

```swift
import SwiftUI

/// Title + total + optional P&L pill. Visibility rules live in
/// `PositionsViewInput.showsPLPill` and `totalValue`.
struct PositionsHeader: View {
  let input: PositionsViewInput

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(input.title)
        .font(.headline)
      Spacer()
      if let total = input.totalValue {
        Text(total.formatted)
          .font(.headline)
          .monospacedDigit()
      } else {
        Text("Unavailable")
          .font(.headline)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Total unavailable")
      }
      if input.showsPLPill, let gain = input.totalGainLoss, let total = input.totalValue {
        plPill(gain: gain, total: total)
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 12)
  }

  private func plPill(gain: InstrumentAmount, total: InstrumentAmount) -> some View {
    let cost = total - gain
    let percent: Double =
      cost.quantity == 0 ? 0 : Double(truncating: (gain.quantity / cost.quantity * 100) as NSDecimalNumber)
    let sign = gain.quantity > 0 ? "+" : ""
    let percentSign = percent > 0 ? "+" : ""
    let label = "\(sign)\(gain.formatted) (\(percentSign)\(String(format: "%.1f", percent))%)"
    return Text(label)
      .font(.caption.weight(.semibold))
      .monospacedDigit()
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        (gain.isNegative ? Color.red : .green).opacity(0.15),
        in: Capsule()
      )
      .foregroundStyle(gain.isNegative ? Color.red : .green)
      .accessibilityLabel(
        gain.isNegative
          ? "Down \(gain.formatted), \(String(format: "%.1f", percent)) percent"
          : "Up \(gain.formatted), \(String(format: "%.1f", percent)) percent"
      )
  }
}

#Preview {
  PositionsHeader(
    input: PositionsViewInput(
      title: "Brokerage",
      hostCurrency: .AUD,
      positions: [
        ValuedPosition(
          instrument: Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP"),
          quantity: 250,
          unitPrice: nil,
          costBasis: InstrumentAmount(quantity: 10_125, instrument: .AUD),
          value: InstrumentAmount(quantity: 11_325, instrument: .AUD)
        )
      ],
      historicalValue: nil
    )
  )
  .frame(width: 420)
}
```

- [ ] **Step 9.2: Build, format, commit**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/build.txt
grep -i 'error:' .agent-tmp/build.txt || echo "BUILD OK"
just format
git -C . add Shared/Views/Positions/PositionsHeader.swift Moolah.xcodeproj
git -C . commit -m "feat(positions): add PositionsHeader with P&L pill"
```

---

## Task 10: Add `PositionsChart`

**Files:**
- Create: `Shared/Views/Positions/PositionsChart.swift`

- [ ] **Step 10.1: Implement the chart**

Create `Shared/Views/Positions/PositionsChart.swift`:

```swift
import Charts
import SwiftUI

/// Chart of value (solid line + soft area) and cost basis (dashed step) over
/// the active time range. Driven by `PositionsViewInput.historicalValue`.
///
/// When `selectedInstrument` is non-nil, plots that instrument's series
/// instead of the aggregate (and shows a clearable filter chip in the
/// header).
struct PositionsChart: View {
  let input: PositionsViewInput
  @Binding var range: PositionsTimeRange
  @Binding var selectedInstrument: Instrument?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      chartBody
      Picker("Range", selection: $range) {
        ForEach(PositionsTimeRange.allCases) { r in
          Text(r.label).tag(r)
        }
      }
      .pickerStyle(.segmented)
      .accessibilityLabel("Chart time range")
    }
    .padding(.horizontal)
  }

  // MARK: - Header

  @ViewBuilder
  private var header: some View {
    if let selectedInstrument {
      HStack(spacing: 6) {
        KindBadge(kind: selectedInstrument.kind)
        Text(selectedInstrument.displayLabel)
          .font(.caption.weight(.semibold))
        Button {
          self.selectedInstrument = nil
        } label: {
          Image(systemName: "xmark")
            .font(.caption2.weight(.bold))
            .padding(4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear instrument filter, showing all positions")
        Spacer()
      }
    } else {
      Text("All positions")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Chart

  @ViewBuilder
  private var chartBody: some View {
    let points = visiblePoints
    if points.isEmpty {
      Text("Not enough data to chart")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 200)
    } else {
      Chart {
        ForEach(points, id: \.date) { point in
          AreaMark(
            x: .value("Date", point.date),
            y: .value("Value", Double(truncating: point.value as NSDecimalNumber))
          )
          .foregroundStyle(Color.accentColor.opacity(0.18))
          .interpolationMethod(.catmullRom)

          LineMark(
            x: .value("Date", point.date),
            y: .value("Value", Double(truncating: point.value as NSDecimalNumber)),
            series: .value("Series", "Value")
          )
          .foregroundStyle(Color.accentColor)
          .lineStyle(StrokeStyle(lineWidth: 2))
          .interpolationMethod(.catmullRom)

          LineMark(
            x: .value("Date", point.date),
            y: .value("Cost", Double(truncating: point.cost as NSDecimalNumber)),
            series: .value("Series", "Cost")
          )
          .foregroundStyle(.gray)
          .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
          .interpolationMethod(.stepEnd)
        }
      }
      .frame(height: 220)
      .accessibilityChartDescriptor(self)
    }
  }

  /// Filtered or aggregate slice for the current selection.
  private var visiblePoints: [HistoricalValueSeries.Point] {
    guard let series = input.historicalValue else { return [] }
    if let selectedInstrument {
      return series.series(for: selectedInstrument)
    }
    return input.showsAggregateChart ? series.totalSeries : []
  }
}

extension PositionsChart: AXChartDescriptorRepresentable {
  func makeChartDescriptor() -> AXChartDescriptor {
    AXChartDescriptor(
      title: selectedInstrument.map { "Chart of \($0.displayLabel)" } ?? "Chart of all positions",
      summary: nil,
      xAxis: AXNumericDataAxisDescriptor(
        title: "Date", range: 0...1, gridlinePositions: []
      ) { _ in "" },
      yAxis: AXNumericDataAxisDescriptor(
        title: "Value (\(input.hostCurrency.id))",
        range: 0...1, gridlinePositions: []
      ) { _ in "" },
      additionalAxes: [],
      series: []
    )
  }
}
```

- [ ] **Step 10.2: Build, format, commit**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/build.txt
grep -i 'error:' .agent-tmp/build.txt || echo "BUILD OK"
just format
git -C . add Shared/Views/Positions/PositionsChart.swift Moolah.xcodeproj
git -C . commit -m "feat(positions): add PositionsChart with value + cost lines"
```

---

## Task 11: Add `PositionsView` container

**Files:**
- Create: `Shared/Views/Positions/PositionsView.swift`

- [ ] **Step 11.1: Implement the container**

Create `Shared/Views/Positions/PositionsView.swift`:

```swift
import SwiftUI

/// Unified container for displaying positions across the app. Composes a
/// header, optional chart, and responsive table from a single
/// `PositionsViewInput`. Renders nothing for empty input — callers decide
/// whether to show context-specific empty state.
///
/// Selection: a single tap on a row filters the chart to that instrument.
/// Tapping again, the chip's ✕, or pressing Escape clears the selection.
struct PositionsView: View {
  let input: PositionsViewInput

  @State private var selection: Instrument?
  @State private var range: PositionsTimeRange = .threeMonths

  var body: some View {
    if input.positions.isEmpty {
      EmptyView()
    } else {
      VStack(spacing: 0) {
        PositionsHeader(input: input)
        if input.showsChart {
          Divider()
          PositionsChart(
            input: input,
            range: $range,
            selectedInstrument: $selection
          )
          .padding(.vertical, 8)
        }
        Divider()
        PositionsTable(input: input, selection: $selection)
      }
      #if os(macOS)
        .onExitCommand { selection = nil }
      #endif
    }
  }
}

#Preview("Default") {
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let cba = Instrument.stock(ticker: "CBA.AX", exchange: "ASX", name: "CBA")
  let aud = Instrument.AUD
  PositionsView(
    input: PositionsViewInput(
      title: "Brokerage",
      hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 250,
          unitPrice: InstrumentAmount(quantity: 45.30, instrument: aud),
          costBasis: InstrumentAmount(quantity: 10_125, instrument: aud),
          value: InstrumentAmount(quantity: 11_325, instrument: aud)
        ),
        ValuedPosition(
          instrument: cba, quantity: 80,
          unitPrice: InstrumentAmount(quantity: 120, instrument: aud),
          costBasis: InstrumentAmount(quantity: 9_000, instrument: aud),
          value: InstrumentAmount(quantity: 9_600, instrument: aud)
        ),
        ValuedPosition(
          instrument: aud, quantity: 2_480,
          unitPrice: nil, costBasis: nil,
          value: InstrumentAmount(quantity: 2_480, instrument: aud)
        ),
      ],
      historicalValue: nil  // chart hidden in preview to keep snapshot stable
    )
  )
  .frame(width: 720, height: 480)
}

#Preview("All fiat") {
  PositionsView(
    input: PositionsViewInput(
      title: "Travel Wallet",
      hostCurrency: .AUD,
      positions: [
        ValuedPosition(
          instrument: .USD, quantity: 100,
          unitPrice: nil, costBasis: nil,
          value: InstrumentAmount(quantity: 152, instrument: .AUD)),
        ValuedPosition(
          instrument: .AUD, quantity: 1_000,
          unitPrice: nil, costBasis: nil,
          value: InstrumentAmount(quantity: 1_000, instrument: .AUD)),
      ],
      historicalValue: nil
    )
  )
  .frame(width: 480, height: 240)
}

#Preview("Conversion failure") {
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  PositionsView(
    input: PositionsViewInput(
      title: "Brokerage",
      hostCurrency: .AUD,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 250,
          unitPrice: nil, costBasis: nil, value: nil)
      ],
      historicalValue: nil
    )
  )
  .frame(width: 480, height: 240)
}

#Preview("Empty") {
  PositionsView(
    input: PositionsViewInput(
      title: "Empty",
      hostCurrency: .AUD,
      positions: [],
      historicalValue: nil
    )
  )
  .frame(width: 480, height: 200)
}
```

- [ ] **Step 11.2: Build, format, commit**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/build.txt
grep -i 'error:' .agent-tmp/build.txt || echo "BUILD OK"
just format
git -C . add Shared/Views/Positions/PositionsView.swift Moolah.xcodeproj
git -C . commit -m "feat(positions): add PositionsView container"
```

---

## Task 12: Wire `InvestmentStore` to produce `PositionsViewInput`

**Files:**
- Modify: `Features/Investments/InvestmentStore.swift`
- Create: `MoolahTests/Features/InvestmentStorePositionsInputTests.swift`

- [ ] **Step 12.1: Write the failing test**

Create `MoolahTests/Features/InvestmentStorePositionsInputTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@MainActor
@Suite("InvestmentStore positionsViewInput")
struct InvestmentStorePositionsInputTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")

  @Test("input title is the account name and host currency is the account instrument")
  func inputCarriesIdentity() async throws {
    let backend = TestBackend.create()
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService
    )
    let account = Account(name: "Brokerage", type: .investment, instrument: aud)
    _ = try await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 0, instrument: aud))
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        legs: [
          TransactionLeg(accountId: account.id, instrument: bhp, quantity: 100, type: .income),
          TransactionLeg(accountId: account.id, instrument: aud, quantity: -4_000, type: .expense),
        ]
      )
    )
    await store.loadAllData(accountId: account.id, profileCurrency: aud)

    let input = await store.positionsViewInput(
      title: account.name, range: .threeMonths)

    #expect(input.title == "Brokerage")
    #expect(input.hostCurrency == aud)
    #expect(input.positions.contains(where: { $0.instrument == bhp }))
    // cost basis is propagated for the BHP row
    let bhpRow = input.positions.first(where: { $0.instrument == bhp })!
    #expect(bhpRow.costBasis == InstrumentAmount(quantity: 4_000, instrument: aud))
  }

  @Test("crypto-to-crypto swap shifts cost basis correctly")
  func swapShiftsCostBasis() async throws {
    let backend = TestBackend.create()
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let btc = Instrument.crypto(
      chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8)
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService
    )
    let account = Account(name: "Crypto", type: .investment, instrument: aud)
    _ = try await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 0, instrument: aud))

    // Buy 4 ETH for 12,000 AUD on day 1.
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(timeIntervalSinceNow: -86_400 * 10),
        legs: [
          TransactionLeg(accountId: account.id, instrument: eth, quantity: 4, type: .income),
          TransactionLeg(accountId: account.id, instrument: aud, quantity: -12_000, type: .expense),
        ]
      )
    )
    // Swap 2 ETH → 0.1 BTC on day 5. Conversion service must be configured
    // so that on the swap date 2 ETH ≈ 6,000 AUD and 0.1 BTC ≈ 6,000 AUD.
    // Inspect TestBackend's conversion fixtures and seed the rates the swap
    // date will hit (or use a FixedConversionService when constructing the
    // store for this test). After the swap, the engine should have:
    //   - ETH: 2 remaining @ 3000 AUD each → cost basis 6,000.
    //   - BTC: 0.1 lot @ 60,000 AUD each → cost basis 6,000.
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(timeIntervalSinceNow: -86_400 * 5),
        legs: [
          TransactionLeg(accountId: account.id, instrument: eth, quantity: -2, type: .income),
          TransactionLeg(accountId: account.id, instrument: btc, quantity: Decimal(string: "0.1")!, type: .income),
        ]
      )
    )

    await store.loadAllData(accountId: account.id, profileCurrency: aud)
    let input = await store.positionsViewInput(title: account.name, range: .threeMonths)

    let ethRow = try #require(input.positions.first(where: { $0.instrument == eth }))
    let btcRow = try #require(input.positions.first(where: { $0.instrument == btc }))
    #expect(ethRow.costBasis == InstrumentAmount(quantity: 6_000, instrument: aud))
    #expect(btcRow.costBasis == InstrumentAmount(quantity: 6_000, instrument: aud))
  }
}
```

> **Note for the implementer.** The swap test depends on `TestBackend`'s default conversion service returning 3,000 AUD per ETH and 60,000 AUD per BTC on the swap date. If those rates aren't part of the default fixture, construct `InvestmentStore` with a `FixedConversionService` configured with the right rates and pass that into the store directly (the constructor already accepts a `conversionService`).

- [ ] **Step 12.2: Run to verify it fails**

```bash
just test InvestmentStorePositionsInputTests 2>&1 | tee .agent-tmp/test.txt
```

Expected: "value of type 'InvestmentStore' has no member 'positionsViewInput'".

- [ ] **Step 12.3: Implement `positionsViewInput`**

Append to `Features/Investments/InvestmentStore.swift` (inside the class):

```swift
// MARK: - PositionsView Input

/// Builds the `PositionsViewInput` for the unified positions UI. Reads from
/// the already-loaded `valuedPositions` for the row data, replays trade
/// transactions through `CostBasisEngine` to derive a per-instrument cost
/// basis snapshot, and asks `PositionsHistoryBuilder` for the chart series.
///
/// Caller-supplied `title` lets the host pass the account name (or any
/// embedding-appropriate label).
func positionsViewInput(
  title: String,
  range: PositionsTimeRange
) async -> PositionsViewInput {
  guard let transactionRepository else {
    return PositionsViewInput(
      title: title, hostCurrency: .AUD,
      positions: valuedPositions, historicalValue: nil)
  }

  // Use the cached valuedPositions if available — they're refreshed by
  // valuatePositions(...). Cost basis snapshot from CostBasisEngine.
  let txns = (try? await fetchAllTransactions(repository: transactionRepository)) ?? []
  let hostCurrency = valuedPositions.first?.value?.instrument ?? .AUD
  let costSnapshot = await costBasisSnapshot(
    transactions: txns, hostCurrency: hostCurrency)
  let rowsWithCost: [ValuedPosition] = valuedPositions.map { row in
    ValuedPosition(
      instrument: row.instrument,
      quantity: row.quantity,
      unitPrice: row.unitPrice,
      costBasis: costSnapshot[row.instrument.id].map {
        InstrumentAmount(quantity: $0, instrument: hostCurrency)
      },
      value: row.value
    )
  }

  let series = await PositionsHistoryBuilder(conversionService: conversionService).build(
    transactions: txns,
    accountId: txns.first?.legs.first?.accountId ?? UUID(),
    hostCurrency: hostCurrency,
    range: range
  )

  return PositionsViewInput(
    title: title,
    hostCurrency: hostCurrency,
    positions: rowsWithCost,
    historicalValue: series
  )
}

private func fetchAllTransactions(
  repository: TransactionRepository
) async throws -> [Transaction] {
  // We assume `loadPositions(accountId:)` already ran; reuse the same
  // pagination loop to grab the full set for this account.
  guard let accountId = positions.first.flatMap({ _ in
    valuedPositions.first?.instrument.id  // sentinel to reuse below
  }) else { return [] }
  _ = accountId
  // The caller holds the account id; in practice positionsViewInput is
  // called from the view which knows the id. To keep the method's signature
  // clean we require InvestmentStore to track the most recent loaded
  // account; reload when the id changes (which the host already does on
  // .task(id: account.id)).
  return []
}

private func costBasisSnapshot(
  transactions: [Transaction], hostCurrency: Instrument
) async -> [String: Decimal] {
  var engine = CostBasisEngine()
  let sorted = transactions.sorted { $0.date < $1.date }
  for txn in sorted {
    do {
      let classification = try await TradeEventClassifier.classify(
        legs: txn.legs, on: txn.date,
        hostCurrency: hostCurrency, conversionService: conversionService
      )
      for buy in classification.buys {
        engine.processBuy(
          instrument: buy.instrument, quantity: buy.quantity,
          costPerUnit: buy.costPerUnit, date: txn.date)
      }
      for sell in classification.sells {
        _ = engine.processSell(
          instrument: sell.instrument, quantity: sell.quantity,
          proceedsPerUnit: sell.proceedsPerUnit, date: txn.date)
      }
    } catch {
      logger.warning(
        "Failed to classify txn \(txn.id, privacy: .public) for cost basis: \(error.localizedDescription, privacy: .public)"
      )
    }
  }
  var result: [String: Decimal] = [:]
  for lot in engine.allOpenLots() {
    result[lot.instrument.id, default: 0] += lot.remainingCost
  }
  return result
}
```

The placeholder `fetchAllTransactions` stub is intentionally empty — Step 12.4 fixes it.

- [ ] **Step 12.4: Track the loaded account id and use it for fetch**

Replace the `fetchAllTransactions` stub above with a real implementation by adding a tracked id property at the top of the class (just below `var selectedPeriod: TimePeriod = .all`):

```swift
private(set) var loadedAccountId: UUID?
```

Update `loadPositions(accountId:)` (currently lines 155-193) to set it after the fetch:

```swift
loadedAccountId = accountId
positions = quantityByInstrument.compactMap { ... }.sorted { ... }
```

(Add the line just before the `positions = ...` assignment.)

Now replace the stub `fetchAllTransactions(repository:)` with:

```swift
private func fetchAllTransactions(
  repository: TransactionRepository
) async throws -> [Transaction] {
  guard let accountId = loadedAccountId else { return [] }
  var all: [Transaction] = []
  var page = 0
  while true {
    let result = try await repository.fetch(
      filter: TransactionFilter(accountId: accountId),
      page: page, pageSize: 200
    )
    if Task.isCancelled { return all }
    all.append(contentsOf: result.transactions)
    if result.transactions.count < 200 { break }
    page += 1
  }
  return all
}
```

Update `positionsViewInput(...)` to pass the right `accountId` to the history builder:

```swift
let series = await PositionsHistoryBuilder(conversionService: conversionService).build(
  transactions: txns,
  accountId: loadedAccountId ?? UUID(),
  hostCurrency: hostCurrency,
  range: range
)
```

- [ ] **Step 12.5: Run the test, format, commit**

```bash
just test InvestmentStorePositionsInputTests 2>&1 | tee .agent-tmp/test.txt
grep -i 'failed\|error:' .agent-tmp/test.txt || echo "PASS"
just format
git -C . add Features/Investments/InvestmentStore.swift \
  MoolahTests/Features/InvestmentStorePositionsInputTests.swift Moolah.xcodeproj
git -C . commit -m "feat(positions): build PositionsViewInput from InvestmentStore"
```

---

## Task 13: Replace `StockPositionsView` in `InvestmentAccountView`

**Files:**
- Modify: `Features/Investments/Views/InvestmentAccountView.swift`

- [ ] **Step 13.1: Swap the view and remove the toolbar**

In `Features/Investments/Views/InvestmentAccountView.swift`:

1. Replace the `else` branch of `if investmentStore.hasLegacyValuations` (currently lines 81-88) with:

```swift
} else {
  PositionsView(
    input: positionsInput
  )
}
```

2. Add the input wrapper as a `@State`:

At the top of the view's properties, just below `@State private var selectedTransaction: Transaction?`, add:

```swift
@State private var positionsInput: PositionsViewInput = PositionsViewInput(
  title: "", hostCurrency: .AUD, positions: [], historicalValue: nil)
@State private var positionsRange: PositionsTimeRange = .threeMonths
```

3. Refresh the input from the store inside `.task(id: account.id)` and `.refreshable`. Replace the existing `.task(id:)` body (currently lines 137-140) with:

```swift
.task(id: account.id) {
  await investmentStore.loadAllData(
    accountId: account.id, profileCurrency: profileCurrencyInstrument)
  positionsInput = await investmentStore.positionsViewInput(
    title: account.name, range: positionsRange)
}
```

Replace `.refreshable` (currently lines 148-151) with:

```swift
.refreshable {
  await investmentStore.loadAllData(
    accountId: account.id, profileCurrency: profileCurrencyInstrument)
  positionsInput = await investmentStore.positionsViewInput(
    title: account.name, range: positionsRange)
}
```

4. Remove the `Record Trade` toolbar item (currently lines 126-135). The whole `if !investmentStore.hasLegacyValuations { ToolbarItem(placement: .primaryAction) { ... } }` block goes.

5. Remove the `.sheet(isPresented: $showingRecordTrade)` block (currently lines 117-124) and the `@State private var showingRecordTrade = false` declaration. Trades are now created via the new-transaction flow per the spec.

6. Remove the `.onChange(of: showingRecordTrade)` block (currently lines 141-147).

7. The `tradeStore: TradeStore` parameter is now unused. Remove it from the property list and the `init` signature, and update the preview at the bottom (lines 241, 257) — drop the line `let tradeStore = TradeStore(...)` and the argument to `InvestmentAccountView(...)`.

8. Update any other call site that still passes `tradeStore:` to `InvestmentAccountView` — `grep -rn "InvestmentAccountView(" --include="*.swift"` should find them all. Each gets the `tradeStore:` argument removed.

- [ ] **Step 13.2: Build & run the suite**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/build.txt
grep -i 'error:' .agent-tmp/build.txt || echo "BUILD OK"
just test 2>&1 | tee .agent-tmp/test.txt
grep -i 'failed\|error:' .agent-tmp/test.txt || echo "PASS"
```

Expected: build succeeds; full test suite green. (`TradeStoreTests`, `TokenSwapDraftTests`, `TradeFlowIntegrationTests` continue to exist — `TradeStore` itself stays alive for the existing inspector flow; only the `Record Trade` toolbar is removed.)

- [ ] **Step 13.3: Format and commit**

```bash
just format
git -C . add Features/Investments/Views/InvestmentAccountView.swift Moolah.xcodeproj
git -C . commit -m "refactor(positions): use PositionsView in InvestmentAccountView"
```

---

## Task 14: Replace `PositionListView` in `TransactionListView`

**Files:**
- Modify: `Features/Transactions/Views/TransactionListView.swift`

- [ ] **Step 14.1: Add input parameters and replace the call site**

In `Features/Transactions/Views/TransactionListView.swift`:

1. Add two parameters next to `var positions: [Position] = []`:

```swift
var positionsHostCurrency: Instrument = .AUD
var positionsTitle: String = "Balances"
var conversionService: (any InstrumentConversionService)?
```

2. Update both `init`s to accept and store the new parameters (same defaults; `conversionService: nil` default).

3. Add a `@State` for the built input, refreshed when `positions` changes:

```swift
@State private var positionsInput: PositionsViewInput?
```

4. Replace the existing `PositionListView(positions: positions)` call (line 218) with:

```swift
if let positionsInput, !positionsInput.positions.isEmpty {
  PositionsView(input: positionsInput)
}
```

5. Add a `.task(id: positions)` to (re)build the input:

```swift
.task(id: positions) {
  guard let conversionService, !positions.isEmpty else {
    positionsInput = nil
    return
  }
  let valuator = PositionsValuator(conversionService: conversionService)
  let rows = await valuator.valuate(
    positions: positions,
    hostCurrency: positionsHostCurrency,
    costBasis: [:],
    on: Date()
  )
  positionsInput = PositionsViewInput(
    title: positionsTitle,
    hostCurrency: positionsHostCurrency,
    positions: rows,
    historicalValue: nil
  )
}
```

6. Update every call site of `TransactionListView(...)` that passed `positions:` (search with grep) so it also passes `positionsHostCurrency:` (the account/earmark instrument or `Profile.currency`) and `conversionService:` (the backend provider's conversion service). Where the host has `@Environment(BackendProvider.self)`, that's `backend.conversionService`.

Likely affected hosts: `EarmarkDetailView`, `CategoryDetailView`, `AccountDetailView`. Use grep:

```bash
grep -rn "TransactionListView(" --include="*.swift" Features/ App/
```

Wire each call site that already supplies `positions:` so the unified view can run.

- [ ] **Step 14.2: Build, run tests, format, commit**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/build.txt
grep -i 'error:' .agent-tmp/build.txt || echo "BUILD OK"
just test 2>&1 | tee .agent-tmp/test.txt
grep -i 'failed\|error:' .agent-tmp/test.txt || echo "PASS"
just format
git -C . add Features/Transactions/Views/TransactionListView.swift \
  Features/ App/ Moolah.xcodeproj
git -C . commit -m "refactor(positions): use PositionsView in TransactionListView"
```

---

## Task 15: Remove `PositionListView` from `EditAccountView`

**Files:**
- Modify: `Features/Accounts/Views/EditAccountView.swift`

- [ ] **Step 15.1: Delete the line**

In `Features/Accounts/Views/EditAccountView.swift`, remove line 68:

```swift
PositionListView(positions: accountStore.positions(for: account.id))
```

The whole line goes — no replacement. The form now ends after the `LabeledContent("Current Balance") { ... }` section.

- [ ] **Step 15.2: Build, run tests, format, commit**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/build.txt
grep -i 'error:' .agent-tmp/build.txt || echo "BUILD OK"
just test 2>&1 | tee .agent-tmp/test.txt
grep -i 'failed\|error:' .agent-tmp/test.txt || echo "PASS"
just format
git -C . add Features/Accounts/Views/EditAccountView.swift Moolah.xcodeproj
git -C . commit -m "refactor(positions): drop per-instrument list from EditAccountView"
```

---

## Task 16: Delete the retired views and their tests

**Files:**
- Delete: `Features/Investments/Views/StockPositionsView.swift`
- Delete: `Features/Investments/Views/StockPositionRow.swift`
- Delete: `Features/Accounts/CryptoPositionsSectionView.swift`
- Delete: `Shared/Views/PositionListView.swift`
- Delete: `MoolahTests/Features/CryptoPositionValuatorTests.swift`
- Delete: `MoolahTests/Features/StockPositionDisplayTests.swift`

- [ ] **Step 16.1: Verify no remaining references**

```bash
grep -rn "StockPositionsView\|StockPositionRow\|CryptoPositionsSectionView\|PositionListView\|CryptoPositionValuator" \
  --include="*.swift" \
  Domain/ Shared/ Features/ App/ MoolahTests/
```

Expected: no output (every reference replaced in earlier tasks).

If any matches show up, fix them before deleting the source files.

- [ ] **Step 16.2: Delete the files**

```bash
rm Features/Investments/Views/StockPositionsView.swift \
   Features/Investments/Views/StockPositionRow.swift \
   Features/Accounts/CryptoPositionsSectionView.swift \
   Shared/Views/PositionListView.swift \
   MoolahTests/Features/CryptoPositionValuatorTests.swift \
   MoolahTests/Features/StockPositionDisplayTests.swift
```

- [ ] **Step 16.3: Regenerate, build, test, format, commit**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/build.txt
grep -i 'error:' .agent-tmp/build.txt || echo "BUILD OK"
just test 2>&1 | tee .agent-tmp/test.txt
grep -i 'failed\|error:' .agent-tmp/test.txt || echo "PASS"
just format
git -C . add -A Features/ Shared/ MoolahTests/ Moolah.xcodeproj
git -C . commit -m "chore(positions): remove retired StockPositionsView, PositionListView, CryptoPositionsSectionView"
```

---

## Task 17: UI + concurrency review and final verification

- [ ] **Step 17.1: Run the UI review agent**

```bash
just format-check
```

Then invoke the `@ui-review` agent over the new files:

- `Shared/Views/Positions/PositionsView.swift`
- `Shared/Views/Positions/PositionsHeader.swift`
- `Shared/Views/Positions/PositionsChart.swift`
- `Shared/Views/Positions/PositionsTable.swift`
- `Shared/Views/Positions/PositionRow.swift`

Address every blocking issue inline before continuing.

- [ ] **Step 17.2: Run the concurrency review agent**

Invoke the `@concurrency-review` agent over:

- `Features/Investments/InvestmentStore.swift` (new methods)
- `Shared/PositionsValuator.swift`
- `Shared/PositionsHistoryBuilder.swift`

Address every blocking issue inline.

- [ ] **Step 17.3: Run the instrument-conversion review agent**

Invoke `@instrument-conversion-review` over:

- `Shared/PositionsValuator.swift`
- `Shared/PositionsHistoryBuilder.swift`
- `Features/Investments/InvestmentStore.swift`
- `Domain/Models/PositionsViewInput.swift`

Confirms `InstrumentAmount` arithmetic stays instrument-safe and conversion dates use the snapshot date for historical points (per `guides/INSTRUMENT_CONVERSION_GUIDE.md`).

- [ ] **Step 17.4: Final verification**

```bash
just format
just format-check
just test 2>&1 | tee .agent-tmp/test-final.txt
grep -i 'failed\|error:' .agent-tmp/test-final.txt || echo "ALL PASS"
just build-mac
just build-ios
rm -rf .agent-tmp
```

- [ ] **Step 17.5: Open the PR**

```bash
git -C . push -u origin design/positions-view
gh pr create --title "Positions view: unified PositionsView + retire three legacy views" \
  --body "$(cat <<'EOF'
## Summary
- Introduces a single `PositionsView` covering investment-account positions and filtered-transaction balances, replacing `StockPositionsView`, `PositionListView`, and `CryptoPositionsSectionView`.
- Adds `ValuedPosition`, `PositionsViewInput`, and `HistoricalValueSeries` value types so the view is fully decoupled from stores.
- Adds pure helpers `PositionsValuator` and `PositionsHistoryBuilder` for current valuation and chart series; both honour the "never display a partial aggregate" rule.
- Removes the `Record Trade` toolbar shortcut and the per-instrument balances row in `EditAccountView` (per spec).

Spec: `plans/2026-04-19-positions-view-design.md`
Plan: `plans/2026-04-19-positions-view-implementation-plan.md`

## Test plan
- [ ] `just format-check`
- [ ] `just test`
- [ ] Investment account page renders new view with chart + P&L pill (BHP + cash).
- [ ] Investment account page falls back to legacy chart when `hasLegacyValuations`.
- [ ] Filtered transaction list (by account / earmark / category) shows balances above the list.
- [ ] `EditAccountView` no longer shows the per-instrument list.
- [ ] Conversion failure for a single position renders `—` for that row, "Unavailable" for the total, hides P&L pill, hides the all-positions chart line.
- [ ] Selecting a row filters the chart; chip ✕ and Escape clear the selection.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Then return the PR URL.

---
