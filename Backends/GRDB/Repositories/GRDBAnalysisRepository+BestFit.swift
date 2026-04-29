import Foundation

/// Linear-regression best-fit overlay for the historic span of
/// `fetchDailyBalances`.
///
/// Lifted into its own sibling-file extension so the regression math is
/// localised — the rest of the daily-balances assembly is about
/// `PositionBook` walking and per-day conversion, neither of which
/// touch the regression. Free of stored-state coupling: the function is
/// `static` and takes its dependencies as parameters, mirroring the
/// shape of `+DailyBalancesForecast.swift` and `+Conversion.swift`.
extension GRDBAnalysisRepository {
  /// Apply linear-regression best-fit line to daily balances. Uses
  /// `availableFunds.quantity` as the y-axis value and the day offset
  /// from the first balance as the x-axis. Falls back to a no-op when
  /// the regression denominator collapses (single-day or perfectly
  /// vertical inputs) so the chart still renders the raw history.
  static func applyBestFit(to balances: inout [DailyBalance], instrument: Instrument) {
    guard balances.count >= 2 else { return }

    let referenceDate = balances[0].date
    let calendar = Calendar.current

    var sumX: Double = 0
    var sumY: Double = 0
    var sumXY: Double = 0
    var sumXX: Double = 0
    let count = Double(balances.count)

    var xValues: [Double] = []
    for balance in balances {
      let xValue = Double(
        calendar.dateComponents([.day], from: referenceDate, to: balance.date).day ?? 0)
      let yValue = Double(truncating: balance.availableFunds.quantity as NSDecimalNumber)
      xValues.append(xValue)
      sumX += xValue
      sumY += yValue
      sumXY += xValue * yValue
      sumXX += xValue * xValue
    }

    let denominator = count * sumXX - sumX * sumX
    guard abs(denominator) > 0.001 else { return }

    let slope = (count * sumXY - sumX * sumY) / denominator
    let intercept = (sumY - slope * sumX) / count

    for index in balances.indices {
      let predicted = Decimal(slope * xValues[index] + intercept)
      let existing = balances[index]
      balances[index] = DailyBalance(
        date: existing.date,
        balance: existing.balance,
        earmarked: existing.earmarked,
        availableFunds: existing.availableFunds,
        investments: existing.investments,
        investmentValue: existing.investmentValue,
        netWorth: existing.netWorth,
        bestFit: InstrumentAmount(quantity: predicted, instrument: instrument),
        isForecast: existing.isForecast
      )
    }
  }
}
