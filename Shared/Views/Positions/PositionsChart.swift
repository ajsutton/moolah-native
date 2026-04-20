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
      .accessibilityLabel(
        selectedInstrument.map { "Chart of \($0.displayLabel)" } ?? "Chart of all positions"
      )
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
