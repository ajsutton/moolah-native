import Charts
import SwiftUI

enum ChartSeries: String, CaseIterable, Identifiable {
  case availableFunds = "Available Funds"
  case currentFunds = "Current Funds"
  case investedAmount = "Invested Amount"
  case investmentValue = "Investment Value"
  case netWorth = "Net Worth"
  case bestFit = "Best Fit"

  var id: String { rawValue }

  var color: Color {
    switch self {
    case .availableFunds: .green
    case .currentFunds: .orange
    case .investedAmount: .purple
    case .investmentValue: .indigo
    case .netWorth: .blue
    case .bestFit: .gray
    }
  }

  var enabledByDefault: Bool {
    true
  }
}

struct NetWorthGraphCard: View {
  let balances: [DailyBalance]

  @State private var selectedDate: Date?
  @State private var visibleSeries: Set<ChartSeries> = Set(
    ChartSeries.allCases.filter(\.enabledByDefault))

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Net Worth")
        .font(.title2)
        .fontWeight(.semibold)

      if balances.isEmpty {
        emptyState
      } else {
        chart
        seriesToggles
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
      // Each series gets its own ForEach so Swift Charts properly connects data points.
      // Actual data: solid lines. Forecast data: dashed, lighter lines.
      if visibleSeries.contains(.availableFunds) {
        ForEach(actualBalances) { balance in
          LineMark(
            x: .value("Date", balance.date),
            y: .value("Amount", balance.availableFunds.cents),
            series: .value("Series", "Available Funds")
          )
          .foregroundStyle(.green)
          .lineStyle(StrokeStyle(lineWidth: 2))
          .interpolationMethod(.stepEnd)
        }
        ForEach(forecastBalances) { balance in
          LineMark(
            x: .value("Date", balance.date),
            y: .value("Amount", balance.availableFunds.cents),
            series: .value("Series", "Available Funds Forecast")
          )
          .foregroundStyle(.green.opacity(0.5))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
          .interpolationMethod(.stepEnd)
        }
      }

      if visibleSeries.contains(.currentFunds) {
        ForEach(actualBalances) { balance in
          LineMark(
            x: .value("Date", balance.date),
            y: .value("Amount", balance.balance.cents),
            series: .value("Series", "Current Funds")
          )
          .foregroundStyle(.orange)
          .lineStyle(StrokeStyle(lineWidth: 2))
          .interpolationMethod(.stepEnd)
        }
        ForEach(forecastBalances) { balance in
          LineMark(
            x: .value("Date", balance.date),
            y: .value("Amount", balance.balance.cents),
            series: .value("Series", "Current Funds Forecast")
          )
          .foregroundStyle(.orange.opacity(0.5))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
          .interpolationMethod(.stepEnd)
        }
      }

      if visibleSeries.contains(.investedAmount) {
        ForEach(actualBalances) { balance in
          LineMark(
            x: .value("Date", balance.date),
            y: .value("Amount", balance.investments.cents),
            series: .value("Series", "Invested Amount")
          )
          .foregroundStyle(.purple)
          .lineStyle(StrokeStyle(lineWidth: 2))
          .interpolationMethod(.stepEnd)
        }
      }

      if visibleSeries.contains(.investmentValue) {
        ForEach(actualBalances.filter({ $0.investmentValue != nil })) { balance in
          LineMark(
            x: .value("Date", balance.date),
            y: .value("Amount", balance.investmentValue!.cents),
            series: .value("Series", "Investment Value")
          )
          .foregroundStyle(.indigo)
          .lineStyle(StrokeStyle(lineWidth: 2))
          .interpolationMethod(.stepEnd)
        }
      }

      if visibleSeries.contains(.netWorth) {
        ForEach(actualBalances) { balance in
          LineMark(
            x: .value("Date", balance.date),
            y: .value("Amount", balance.netWorth.cents),
            series: .value("Series", "Net Worth")
          )
          .foregroundStyle(.blue)
          .lineStyle(StrokeStyle(lineWidth: 2))
          .interpolationMethod(.stepEnd)
        }
        ForEach(forecastBalances) { balance in
          LineMark(
            x: .value("Date", balance.date),
            y: .value("Amount", balance.netWorth.cents),
            series: .value("Series", "Net Worth Forecast")
          )
          .foregroundStyle(.blue.opacity(0.5))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
          .interpolationMethod(.stepEnd)
        }
      }

      if visibleSeries.contains(.bestFit) {
        ForEach(actualBalances.filter({ $0.bestFit != nil })) { balance in
          LineMark(
            x: .value("Date", balance.date),
            y: .value("Amount", balance.bestFit!.cents),
            series: .value("Series", "Best Fit")
          )
          .foregroundStyle(.gray)
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
        }
      }

      if let selectedDate {
        RuleMark(x: .value("Selected", selectedDate))
          .foregroundStyle(.gray.opacity(0.5))
          .lineStyle(StrokeStyle(lineWidth: 1))
      }
    }
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: 6)) { _ in
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
            Text(
              MonetaryAmount(cents: cents, currency: balances.first?.balance.currency ?? .AUD)
                .formatNoSymbol
            )
            .monospacedDigit()
          }
        }
      }
    }
    .chartXSelection(value: $selectedDate)
    .frame(height: 300)
    .accessibilityLabel("Net worth graph showing financial data over time")
  }

  private var seriesToggles: some View {
    HStack(spacing: 16) {
      ForEach(availableSeries) { series in
        Button {
          if visibleSeries.contains(series) {
            visibleSeries.remove(series)
          } else {
            visibleSeries.insert(series)
          }
        } label: {
          HStack(spacing: 4) {
            if series == .bestFit {
              Rectangle()
                .stroke(series.color, style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                .frame(width: 16, height: 2)
            } else {
              Rectangle()
                .fill(series.color)
                .frame(width: 16, height: 2)
            }
            Text(series.rawValue)
              .foregroundStyle(visibleSeries.contains(series) ? .primary : .tertiary)
          }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(series.rawValue) series")
        .accessibilityAddTraits(visibleSeries.contains(series) ? .isSelected : [])
        .accessibilityHint("Double tap to toggle visibility")
      }
    }
    .font(.caption)
  }

  private var availableSeries: [ChartSeries] {
    var series: [ChartSeries] = [.availableFunds, .currentFunds, .netWorth]

    if balances.contains(where: { $0.investments.cents != 0 }) {
      series.append(.investedAmount)
    }
    if balances.contains(where: { $0.investmentValue != nil }) {
      series.append(.investmentValue)
    }
    if balances.contains(where: { $0.bestFit != nil }) {
      series.append(.bestFit)
    }
    if !forecastBalances.isEmpty {
      // Forecast is implicit — shown when forecast data exists for enabled series
    }
    return series
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
      balance: MonetaryAmount(cents: 100000, currency: .AUD),
      earmarked: MonetaryAmount(cents: 20000, currency: .AUD),
      investments: MonetaryAmount(cents: 50000, currency: .AUD)
    ),
    DailyBalance(
      date: Date().addingTimeInterval(-86400 * 3),
      balance: MonetaryAmount(cents: 120000, currency: .AUD),
      earmarked: MonetaryAmount(cents: 25000, currency: .AUD),
      investments: MonetaryAmount(cents: 55000, currency: .AUD)
    ),
    DailyBalance(
      date: Date(),
      balance: MonetaryAmount(cents: 110000, currency: .AUD),
      earmarked: MonetaryAmount(cents: 22000, currency: .AUD),
      investments: MonetaryAmount(cents: 60000, currency: .AUD)
    ),
  ]

  return NetWorthGraphCard(balances: balances)
    .frame(width: 800)
    .padding()
}
