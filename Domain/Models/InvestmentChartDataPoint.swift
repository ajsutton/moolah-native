import Foundation

/// A single merged data point for the investment chart.
/// Combines investment value, invested amount (balance), and profit/loss.
struct InvestmentChartDataPoint: Identifiable, Sendable {
  let date: Date
  /// Market value at this date (from investment values)
  let value: Decimal?
  /// Cumulative invested amount at this date (from daily balances)
  let balance: Decimal?
  /// Profit/loss = value - balance (nil if either is missing)
  let profitLoss: Decimal?

  var id: Date { date }
}
