import Foundation

/// Caseless `enum` (CODE_GUIDE.md §5 — pure namespace) that turns a
/// `[HistoricalValueSeries.Point]` into the per-row rendering inputs
/// the chart consumes. Pure function with no SwiftUI dependency so
/// the data-shape tests can exercise the rendering decisions
/// without spinning up a view harness.
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
        date: point.date,
        value: point.value,
        baseline: baseline,
        gainSegment: gain,
        lossSegment: loss,
        legendUnavailable: isLast && baseline == nil
      )
    }
  }
}
