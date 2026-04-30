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

  /// Account-level performance numbers for the host. Non-nil triggers
  /// the three-tile `AccountPerformanceTiles` strip in place of the
  /// single-row `PositionsHeader`. Non-investment-account hosts leave
  /// this `nil` and keep the existing header layout.
  let performance: AccountPerformance?

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
  var showsAggregateChart: Bool { showsChart && totalValue != nil }

  /// `true` iff more than one `Instrument.Kind` is represented. Drives whether
  /// the table renders per-group subtotals.
  var showsGroupSubtotals: Bool {
    let kinds = Set(positions.map(\.instrument.kind))
    return kinds.count > 1
  }

  /// `true` when `PositionsView` should render nothing. Two cases:
  /// 1. There are no positions at all (nothing to show).
  /// 2. Every non-zero-quantity position is in `hostCurrency` — the host
  ///    surface's balance already surfaces this, so a second "100 AUD" row
  ///    would be redundant noise.
  ///
  /// When `hostCurrency` differs from the underlying holdings' instrument
  /// (e.g. a BTC-denominated investment account reporting in AUD), the rule
  /// does not fire — the conversion columns still add information.
  var shouldHide: Bool {
    if positions.isEmpty { return true }
    let nonZeroInstruments = Set(
      positions.lazy.filter { $0.quantity != 0 }.map(\.instrument)
    )
    return nonZeroInstruments == [hostCurrency]
  }
}

extension PositionsViewInput {
  /// Backward-compat init for the four-arg shape that pre-dates
  /// `performance`. Lets non-investment-account callers (the
  /// transaction list, all previews) keep their existing
  /// `PositionsViewInput(title:hostCurrency:positions:historicalValue:)`
  /// invocation unchanged. The investment-account path opts in via
  /// the synthesised memberwise init.
  init(
    title: String,
    hostCurrency: Instrument,
    positions: [ValuedPosition],
    historicalValue: HistoricalValueSeries?
  ) {
    self.init(
      title: title,
      hostCurrency: hostCurrency,
      positions: positions,
      historicalValue: historicalValue,
      performance: nil)
  }
}
