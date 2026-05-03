import Charts
import SwiftUI

/// Per-series chart-content builders. Split out so the main view's body
/// stays focused on layout / accessibility / state, and the
/// `type_body_length` budget isn't dominated by Swift Charts plumbing.
extension NetWorthGraphCard {
  @ChartContentBuilder var availableFundsMarks: some ChartContent {
    if visibleSeries.contains(.availableFunds) {
      ForEach(actualBalances) { balance in
        LineMark(
          x: .value("Date", balance.date),
          y: .value("Amount", balance.availableFunds.doubleValue),
          series: .value("Series", "Available Funds")
        )
        .foregroundStyle(.green)
        .lineStyle(StrokeStyle(lineWidth: 2))
        .interpolationMethod(.stepEnd)
      }
      ForEach(forecastBalances) { balance in
        LineMark(
          x: .value("Date", balance.date),
          y: .value("Amount", balance.availableFunds.doubleValue),
          series: .value("Series", "Available Funds Forecast")
        )
        .foregroundStyle(.green.opacity(0.5))
        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        .interpolationMethod(.stepEnd)
      }
    }
  }

  @ChartContentBuilder var currentFundsMarks: some ChartContent {
    if visibleSeries.contains(.currentFunds) {
      ForEach(actualBalances) { balance in
        LineMark(
          x: .value("Date", balance.date),
          y: .value("Amount", balance.balance.doubleValue),
          series: .value("Series", "Current Funds")
        )
        .foregroundStyle(.orange)
        .lineStyle(StrokeStyle(lineWidth: 2))
        .interpolationMethod(.stepEnd)
      }
      ForEach(forecastBalances) { balance in
        LineMark(
          x: .value("Date", balance.date),
          y: .value("Amount", balance.balance.doubleValue),
          series: .value("Series", "Current Funds Forecast")
        )
        .foregroundStyle(.orange.opacity(0.5))
        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        .interpolationMethod(.stepEnd)
      }
    }
  }

  @ChartContentBuilder var investedAmountMarks: some ChartContent {
    if visibleSeries.contains(.investedAmount) {
      ForEach(actualBalances) { balance in
        LineMark(
          x: .value("Date", balance.date),
          y: .value("Amount", balance.investments.doubleValue),
          series: .value("Series", "Invested Amount")
        )
        .foregroundStyle(.purple)
        .lineStyle(StrokeStyle(lineWidth: 2))
        .interpolationMethod(.stepEnd)
      }
    }
  }

  @ChartContentBuilder var investmentValueMarks: some ChartContent {
    if visibleSeries.contains(.investmentValue) {
      ForEach(actualBalances.filter { $0.investmentValue != nil }) { balance in
        LineMark(
          x: .value("Date", balance.date),
          y: .value("Amount", (balance.investmentValue?.doubleValue) ?? 0),
          series: .value("Series", "Investment Value")
        )
        .foregroundStyle(.indigo)
        .lineStyle(StrokeStyle(lineWidth: 2))
        .interpolationMethod(.stepEnd)
      }
    }
  }

  @ChartContentBuilder var netWorthMarks: some ChartContent {
    if visibleSeries.contains(.netWorth) {
      ForEach(actualBalances) { balance in
        LineMark(
          x: .value("Date", balance.date),
          y: .value("Amount", balance.netWorth.doubleValue),
          series: .value("Series", "Net Worth")
        )
        .foregroundStyle(.blue)
        .lineStyle(StrokeStyle(lineWidth: 2))
        .interpolationMethod(.stepEnd)
      }
      ForEach(forecastBalances) { balance in
        LineMark(
          x: .value("Date", balance.date),
          y: .value("Amount", balance.netWorth.doubleValue),
          series: .value("Series", "Net Worth Forecast")
        )
        .foregroundStyle(.blue.opacity(0.5))
        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        .interpolationMethod(.stepEnd)
      }
    }
  }

  @ChartContentBuilder var bestFitMarks: some ChartContent {
    if visibleSeries.contains(.bestFit) {
      ForEach(actualBalances.filter { $0.bestFit != nil }) { balance in
        LineMark(
          x: .value("Date", balance.date),
          y: .value("Amount", (balance.bestFit?.doubleValue) ?? 0),
          series: .value("Series", "Best Fit")
        )
        .foregroundStyle(.gray)
        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
      }
    }
  }
}
