import Foundation

/// Per-point rendering inputs computed by
/// `PositionsChartBaselineResolver.resolve`. The chart consumes
/// `baseline`, `gainSegment`, and `lossSegment` directly to emit
/// `AreaMark` / `LineMark` per row; `legendUnavailable` on the last
/// entry drives the legend swatch state.
///
/// Lives in its own file (rather than nested inside
/// `PositionsChart.swift`) because that view file is already at
/// `file_length` budget and the rendering helper is plain Swift —
/// a SwiftUI dependency is not required for the resolver, so it
/// tests cleanly without `@MainActor` machinery.
struct PositionsChartRenderRow: Sendable, Hashable {
  let date: Date
  let value: Decimal
  /// `nil` when the per-mode baseline is unavailable for this point
  /// (per-instrument: cost — but cost is non-optional, so this only
  /// happens in aggregate mode where contributions can be `nil`
  /// after a Rule 11 latch). When `nil`, the chart emits the value
  /// line only — no area, no baseline line for this row.
  let baseline: Decimal?
  /// `max(value - baseline, 0)` when baseline is non-nil, else 0.
  let gainSegment: Decimal
  /// `max(baseline - value, 0)` when baseline is non-nil, else 0.
  let lossSegment: Decimal
  /// True for every row whose `baseline == nil` AND the row is the
  /// last in the resolved sequence — drives the legend's
  /// "Profit/Loss unavailable" state. Always false on non-last rows
  /// (the chart's legend reads only the most recent point's value).
  let legendUnavailable: Bool
}
