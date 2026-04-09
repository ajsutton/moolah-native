import Charts
import SwiftUI

/// Multi-series investment chart with value, invested amount, and profit/loss.
struct InvestmentChartView: View {
  let dataPoints: [InvestmentChartDataPoint]
  let currency: Currency

  @State private var selectedDate: Date?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if dataPoints.isEmpty {
        emptyState
      } else {
        chartContent
        legend
      }
    }
    .padding()
    #if os(macOS)
      .background(Color(nsColor: .controlBackgroundColor))
    #else
      .background(Color(uiColor: .systemBackground))
    #endif
    .cornerRadius(12)
  }

  private var emptyState: some View {
    Text("Not enough data for chart")
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .center)
      .frame(height: 250)
  }

  private var chartContent: some View {
    VStack(spacing: 8) {
      Chart {
        ForEach(dataPoints) { point in
          // Profit/Loss area (orange)
          if let profitLoss = point.profitLoss {
            AreaMark(
              x: .value("Date", point.date),
              y: .value("Profit/Loss", profitLoss)
            )
            .foregroundStyle(.orange.opacity(0.2))
            .interpolationMethod(.catmullRom)
          }

          // Investment Value line (blue)
          if let value = point.value {
            LineMark(
              x: .value("Date", point.date),
              y: .value("Value", value),
              series: .value("Series", "Value")
            )
            .foregroundStyle(.blue)
            .lineStyle(StrokeStyle(lineWidth: 2))
            .interpolationMethod(.catmullRom)
          }

          // Invested Amount line (gray, step interpolation)
          if let balance = point.balance {
            LineMark(
              x: .value("Date", point.date),
              y: .value("Balance", balance),
              series: .value("Series", "Balance")
            )
            .foregroundStyle(.gray)
            .lineStyle(StrokeStyle(lineWidth: 2))
            .interpolationMethod(.stepEnd)
          }
        }

        // Selection rule
        if let selectedDate {
          RuleMark(x: .value("Selected", selectedDate))
            .foregroundStyle(.gray.opacity(0.5))
            .lineStyle(StrokeStyle(lineWidth: 1))
        }
      }
      .chartXAxis {
        AxisMarks(values: .automatic(desiredCount: 6)) { value in
          AxisGridLine()
          AxisTick()
          if let date = value.as(Date.self) {
            AxisValueLabel {
              Text(date, format: .dateTime.month(.abbreviated).year(.twoDigits))
                .font(.caption)
            }
          }
        }
      }
      .chartYAxis {
        AxisMarks { value in
          AxisGridLine()
          AxisValueLabel {
            if let cents = value.as(Int.self) {
              Text(MonetaryAmount(cents: cents, currency: currency).formatNoSymbol)
                .monospacedDigit()
                .font(.caption)
            }
          }
        }
      }
      .chartXSelection(value: $selectedDate)
      .chartLegend(.hidden)
      .frame(height: 250)
      .accessibilityLabel(
        "Investment chart showing value, invested amount, and profit or loss over time")

      // Selection detail overlay
      if let selectedDate, let point = closestPoint(to: selectedDate) {
        selectionDetail(point: point)
      }
    }
  }

  @ViewBuilder
  private func selectionDetail(point: InvestmentChartDataPoint) -> some View {
    HStack(spacing: 16) {
      Text(point.date, format: .dateTime.day().month(.abbreviated).year())
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()

      if let value = point.value {
        detailItem(
          label: "Value",
          amount: MonetaryAmount(cents: value, currency: currency),
          color: .blue)
      }

      if let balance = point.balance {
        detailItem(
          label: "Invested",
          amount: MonetaryAmount(cents: balance, currency: currency),
          color: .gray)
      }

      if let profitLoss = point.profitLoss {
        detailItem(
          label: "P/L",
          amount: MonetaryAmount(cents: profitLoss, currency: currency),
          color: .orange)
      }
    }
    .font(.caption)
    .padding(.horizontal)
  }

  private func detailItem(label: String, amount: MonetaryAmount, color: Color) -> some View {
    HStack(spacing: 4) {
      Circle()
        .fill(color)
        .frame(width: 6, height: 6)
      Text(label)
        .foregroundStyle(.secondary)
      MonetaryAmountView(amount: amount, font: .caption)
    }
    .accessibilityElement(children: .combine)
  }

  private var legend: some View {
    HStack(spacing: 16) {
      LegendItem(color: .blue, label: "Investment Value")
      LegendItem(color: .gray, label: "Invested Amount")
      LegendItem(color: .orange, label: "Profit/Loss")
    }
    .font(.caption)
  }

  private func closestPoint(to date: Date) -> InvestmentChartDataPoint? {
    dataPoints.min(by: {
      abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
    })
  }
}
