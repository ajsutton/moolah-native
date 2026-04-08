import Charts
import SwiftUI

struct NetWorthGraphCard: View {
  let balances: [DailyBalance]

  @State private var selectedDate: Date?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Net Worth")
        .font(.title2)
        .fontWeight(.semibold)

      if balances.isEmpty {
        emptyState
      } else {
        chart
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
    Text("No balance data available")
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .center)
      .frame(height: 300)
  }

  private var chart: some View {
    Chart {
      // Actual balances
      ForEach(actualBalances) { balance in
        // Available Funds (green area)
        AreaMark(
          x: .value("Date", balance.date),
          y: .value("Amount", balance.availableFunds.cents)
        )
        .foregroundStyle(.green.opacity(0.3))
        .interpolationMethod(.stepEnd)

        LineMark(
          x: .value("Date", balance.date),
          y: .value("Amount", balance.availableFunds.cents)
        )
        .foregroundStyle(.green)
        .lineStyle(StrokeStyle(lineWidth: 2))
        .interpolationMethod(.stepEnd)

        // Net Worth (blue line)
        LineMark(
          x: .value("Date", balance.date),
          y: .value("Amount", balance.netWorth.cents)
        )
        .foregroundStyle(.blue)
        .lineStyle(StrokeStyle(lineWidth: 2))
        .interpolationMethod(.stepEnd)

        // Best Fit (gray dashed line)
        if let bestFit = balance.bestFit {
          LineMark(
            x: .value("Date", balance.date),
            y: .value("Amount", bestFit.cents)
          )
          .foregroundStyle(.gray)
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
        }
      }

      // Forecasted balances (lighter colors, dashed)
      ForEach(forecastBalances) { balance in
        AreaMark(
          x: .value("Date", balance.date),
          y: .value("Amount", balance.availableFunds.cents)
        )
        .foregroundStyle(.green.opacity(0.1))
        .interpolationMethod(.stepEnd)

        LineMark(
          x: .value("Date", balance.date),
          y: .value("Amount", balance.availableFunds.cents)
        )
        .foregroundStyle(.green.opacity(0.5))
        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        .interpolationMethod(.stepEnd)

        LineMark(
          x: .value("Date", balance.date),
          y: .value("Amount", balance.netWorth.cents)
        )
        .foregroundStyle(.blue.opacity(0.5))
        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        .interpolationMethod(.stepEnd)
      }

      // Selection rule
      if let selectedDate = selectedDate {
        RuleMark(x: .value("Selected", selectedDate))
          .foregroundStyle(.gray.opacity(0.5))
          .lineStyle(StrokeStyle(lineWidth: 1))
      }
    }
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: 6)) { value in
        AxisGridLine()
        AxisTick()
        AxisValueLabel(format: .dateTime.month().day())
      }
    }
    .chartYAxis {
      AxisMarks { value in
        AxisGridLine()
        AxisValueLabel {
          if let cents = value.as(Int.self) {
            Text(MonetaryAmount(cents: cents, currency: .defaultCurrency).formatNoSymbol)
              .monospacedDigit()
          }
        }
      }
    }
    .chartXSelection(value: $selectedDate)
    .frame(height: 300)
    .accessibilityLabel("Net worth graph showing available funds and total net worth over time")
  }

  private var legend: some View {
    HStack(spacing: 16) {
      LegendItem(color: .green, label: "Available Funds")
      LegendItem(color: .blue, label: "Net Worth")
      if actualBalances.contains(where: { $0.bestFit != nil }) {
        LegendItem(color: .gray, label: "Best Fit", dashed: true)
      }
      if !forecastBalances.isEmpty {
        LegendItem(color: .green.opacity(0.5), label: "Forecast", dashed: true)
      }
    }
    .font(.caption)
  }

  private var actualBalances: [DailyBalance] {
    balances.filter { !$0.isForecast }
  }

  private var forecastBalances: [DailyBalance] {
    balances.filter { $0.isForecast }
  }
}

struct LegendItem: View {
  let color: Color
  let label: String
  var dashed: Bool = false

  var body: some View {
    HStack(spacing: 4) {
      if dashed {
        Rectangle()
          .stroke(color, style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
          .frame(width: 16, height: 2)
      } else {
        Rectangle()
          .fill(color)
          .frame(width: 16, height: 2)
      }
      Text(label)
        .foregroundStyle(.primary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(label) series")
  }
}

#Preview {
  let balances = [
    DailyBalance(
      date: Date().addingTimeInterval(-86400 * 7),
      balance: MonetaryAmount(cents: 100000, currency: .defaultCurrency),
      earmarked: MonetaryAmount(cents: 20000, currency: .defaultCurrency),
      investments: MonetaryAmount(cents: 50000, currency: .defaultCurrency)
    ),
    DailyBalance(
      date: Date().addingTimeInterval(-86400 * 3),
      balance: MonetaryAmount(cents: 120000, currency: .defaultCurrency),
      earmarked: MonetaryAmount(cents: 25000, currency: .defaultCurrency),
      investments: MonetaryAmount(cents: 55000, currency: .defaultCurrency)
    ),
    DailyBalance(
      date: Date(),
      balance: MonetaryAmount(cents: 110000, currency: .defaultCurrency),
      earmarked: MonetaryAmount(cents: 22000, currency: .defaultCurrency),
      investments: MonetaryAmount(cents: 60000, currency: .defaultCurrency)
    ),
  ]

  return NetWorthGraphCard(balances: balances)
    .frame(width: 800)
    .padding()
}
