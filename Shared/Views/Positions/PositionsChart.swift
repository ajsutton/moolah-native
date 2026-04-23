// swiftlint:disable multiline_arguments

import Accessibility
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

  #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      chartBody
      rangePicker
    }
    .padding(.horizontal)
  }

  // MARK: - Header

  @ViewBuilder private var header: some View {
    if let selectedInstrument {
      HStack(spacing: 6) {
        KindBadge(kind: selectedInstrument.kind)
        Text(selectedInstrument.displayLabel)
          .font(.caption.weight(.semibold))
        Button {
          self.selectedInstrument = nil
        } label: {
          Image(systemName: "xmark.circle.fill")
            .imageScale(.medium)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
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

  @ViewBuilder private var chartBody: some View {
    let points = visiblePoints
    if points.isEmpty {
      ContentUnavailableView {
        Label("No chart data yet", systemImage: "chart.line.uptrend.xyaxis")
      } description: {
        Text("Record a trade to start tracking value over time.")
      }
      .frame(minHeight: 200)
    } else {
      Chart {
        ForEach(points, id: \.date) { point in
          AreaMark(
            x: .value("Date", point.date),
            y: .value("Value", Double(truncating: point.value as NSDecimalNumber))
          )
          .foregroundStyle(Color.accentColor.opacity(0.18))
          .interpolationMethod(.linear)

          LineMark(
            x: .value("Date", point.date),
            y: .value("Value", Double(truncating: point.value as NSDecimalNumber)),
            series: .value("Series", "Value")
          )
          .foregroundStyle(Color.accentColor)
          .lineStyle(StrokeStyle(lineWidth: 2))
          .interpolationMethod(.linear)

          LineMark(
            x: .value("Date", point.date),
            y: .value("Cost", Double(truncating: point.cost as NSDecimalNumber)),
            series: .value("Series", "Cost")
          )
          .foregroundStyle(.secondary)
          .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
          .interpolationMethod(.stepEnd)
        }
      }
      .chartXAxis {
        AxisMarks(values: .automatic(desiredCount: 4)) { value in
          AxisGridLine()
          AxisTick()
          if let date = value.as(Date.self) {
            AxisValueLabel {
              Text(date, format: .dateTime.month(.abbreviated))
                .font(.caption2)
            }
          }
        }
      }
      .chartYAxis {
        AxisMarks { value in
          AxisGridLine()
          AxisValueLabel {
            if let amount = value.as(Double.self) {
              Text(amount, format: .number.notation(.compactName))
                .font(.caption2)
                .monospacedDigit()
            }
          }
        }
      }
      .frame(height: 220)
      .accessibilityChartDescriptor(self)

      HStack(spacing: 16) {
        legendItem(color: .accentColor, label: "Value", dashed: false)
        legendItem(color: .secondary, label: "Cost basis", dashed: true)
        Spacer()
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func legendItem(color: Color, label: String, dashed: Bool) -> some View {
    HStack(spacing: 4) {
      if dashed {
        DashedLineSwatch(color: color)
      } else {
        Capsule()
          .fill(color)
          .frame(width: 14, height: 2)
      }
      Text(label)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(label)
  }

  private struct DashedLineSwatch: View {
    let color: Color
    var body: some View {
      GeometryReader { _ in
        Path { path in
          path.move(to: .init(x: 0, y: 1))
          path.addLine(to: .init(x: 14, y: 1))
        }
        .stroke(style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
        .foregroundStyle(color)
      }
      .frame(width: 14, height: 2)
    }
  }

  // MARK: - Range picker

  @ViewBuilder private var rangePicker: some View {
    let picker =
      Picker("Range", selection: $range) {
        ForEach(PositionsTimeRange.allCases) { option in
          Text(option.label)
            .accessibilityLabel(option.accessibilityLabel)
            .tag(option)
        }
      }
      .accessibilityLabel("Chart time range")
    #if os(macOS)
      picker.pickerStyle(.segmented)
    #else
      if sizeClass == .compact {
        picker.pickerStyle(.menu)
      } else {
        picker.pickerStyle(.segmented)
      }
    #endif
  }

  // MARK: - Data

  /// Filtered or aggregate slice for the current selection.
  private var visiblePoints: [HistoricalValueSeries.Point] {
    guard let series = input.historicalValue else { return [] }
    if let selectedInstrument {
      return series.series(for: selectedInstrument)
    }
    return input.showsAggregateChart ? series.totalSeries : []
  }
}

// MARK: - AXChartDescriptorRepresentable

extension PositionsChart: AXChartDescriptorRepresentable {
  nonisolated func makeChartDescriptor() -> AXChartDescriptor {
    let snapshot = MainActor.assumeIsolated { chartSnapshot() }
    return AXChartDescriptor(
      title: snapshot.title,
      summary: snapshot.summary,
      xAxis: AXCategoricalDataAxisDescriptor(
        title: "Date", categoryOrder: snapshot.dateLabels
      ),
      yAxis: AXNumericDataAxisDescriptor(
        title: snapshot.yTitle,
        range: snapshot.yMin...snapshot.yMax,
        gridlinePositions: []
      ) { value in
        String(format: "%.2f", value)
      },
      additionalAxes: [],
      series: snapshot.series
    )
  }

  /// Snapshot of view state for the descriptor.
  @MainActor
  private func chartSnapshot() -> ChartSnapshot {
    let points = visiblePoints
    let title =
      selectedInstrument.map { "Chart of \($0.displayLabel)" } ?? "Chart of all positions"

    let dateLabels = points.map { $0.date.formatted(.dateTime.month(.abbreviated).day().year()) }
    let valueDoubles = points.map { Double(truncating: $0.value as NSDecimalNumber) }
    let costDoubles = points.map { Double(truncating: $0.cost as NSDecimalNumber) }

    let allValues = valueDoubles + costDoubles
    let minVal = allValues.min() ?? 0
    let maxVal = allValues.max() ?? max(minVal + 1, 1)

    let valueSeries = AXDataSeriesDescriptor(
      name: "Value", isContinuous: true,
      dataPoints: zip(dateLabels, valueDoubles).map { date, val in
        AXDataPoint(x: date, y: val)
      }
    )
    let costSeries = AXDataSeriesDescriptor(
      name: "Cost basis", isContinuous: true,
      dataPoints: zip(dateLabels, costDoubles).map { date, val in
        AXDataPoint(x: date, y: val)
      }
    )

    let summary: String? =
      points.isEmpty
      ? "No data"
      : "\(points.count) daily points, value range \(String(format: "%.0f", minVal)) to \(String(format: "%.0f", maxVal)) \(input.hostCurrency.id)"

    return ChartSnapshot(
      title: title,
      summary: summary,
      dateLabels: dateLabels,
      yTitle: "Value (\(input.hostCurrency.id))",
      yMin: minVal,
      yMax: max(minVal + 1, maxVal),
      series: [valueSeries, costSeries]
    )
  }

  private struct ChartSnapshot: @unchecked Sendable {
    let title: String
    let summary: String?
    let dateLabels: [String]
    let yTitle: String
    let yMin: Double
    let yMax: Double
    let series: [AXDataSeriesDescriptor]
  }
}

// MARK: - Previews

#Preview("Chart - aggregate") {
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let aud = Instrument.AUD
  let calendar = Calendar(identifier: .gregorian)
  let now = Date()
  let points: [HistoricalValueSeries.Point] = (0..<60).map { offset in
    let date = calendar.date(byAdding: .day, value: -59 + offset, to: now) ?? now
    let trend = Decimal(10_000) + Decimal(offset) * 30
    return HistoricalValueSeries.Point(date: date, value: trend, cost: 9_500)
  }
  let series = HistoricalValueSeries(
    hostCurrency: aud,
    total: points,
    perInstrument: [bhp.id: points]
  )
  let input = PositionsViewInput(
    title: "Brokerage", hostCurrency: aud,
    positions: [
      ValuedPosition(
        instrument: bhp, quantity: 100,
        unitPrice: nil,
        costBasis: InstrumentAmount(quantity: 9_500, instrument: aud),
        value: InstrumentAmount(quantity: points.last?.value ?? 0, instrument: aud)
      )
    ],
    historicalValue: series
  )
  return PositionsChart(
    input: input,
    range: .constant(.threeMonths),
    selectedInstrument: .constant(nil)
  )
  .frame(width: 600, height: 320)
  .padding()
}

#Preview("Chart - filtered to instrument") {
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let aud = Instrument.AUD
  let calendar = Calendar(identifier: .gregorian)
  let now = Date()
  let points: [HistoricalValueSeries.Point] = (0..<30).map { offset in
    let date = calendar.date(byAdding: .day, value: -29 + offset, to: now) ?? now
    return HistoricalValueSeries.Point(
      date: date, value: 4_500 + Decimal(offset) * 25, cost: 4_000)
  }
  let series = HistoricalValueSeries(
    hostCurrency: aud, total: points,
    perInstrument: [bhp.id: points]
  )
  let input = PositionsViewInput(
    title: "Brokerage", hostCurrency: aud,
    positions: [
      ValuedPosition(
        instrument: bhp, quantity: 100, unitPrice: nil,
        costBasis: InstrumentAmount(quantity: 4_000, instrument: aud),
        value: InstrumentAmount(quantity: points.last?.value ?? 0, instrument: aud)
      )
    ],
    historicalValue: series
  )
  return PositionsChart(
    input: input,
    range: .constant(.oneMonth),
    selectedInstrument: .constant(bhp)
  )
  .frame(width: 600, height: 320)
  .padding()
}

#Preview("Chart - empty") {
  PositionsChart(
    input: PositionsViewInput(
      title: "x", hostCurrency: .AUD, positions: [], historicalValue: nil
    ),
    range: .constant(.oneMonth),
    selectedInstrument: .constant(nil)
  )
  .frame(width: 600, height: 320)
  .padding()
}
