import Foundation

// Computed read-only properties for `InvestmentStore`. Pure reads that
// need no privileged access to `private(set)` setters.
extension InvestmentStore {
  /// Investment values filtered by the selected time period.
  var filteredValues: [InvestmentValue] {
    guard let startDate = selectedPeriod.startDate else { return values }
    return values.filter { $0.date >= startDate }
  }

  /// Daily balances filtered by the selected time period.
  var filteredBalances: [AccountDailyBalance] {
    guard let startDate = selectedPeriod.startDate else { return dailyBalances }
    return dailyBalances.filter { $0.date >= startDate }
  }

  /// Forward-fills gaps so the chart renders a continuous P/L line on
  /// days that received neither a snapshot nor a derived balance. See
  /// `InvestmentChartData.merge` for the algorithm.
  var chartDataPoints: [InvestmentChartDataPoint] {
    InvestmentChartData.merge(
      values: values,
      balances: dailyBalances,
      period: selectedPeriod
    )
  }
}
