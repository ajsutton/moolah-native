import Foundation

/// A single day's financial snapshot, either historical (isForecast: false)
/// or projected from scheduled transactions (isForecast: true).
struct DailyBalance: Sendable, Codable, Identifiable, Hashable {
  var id: String { date.ISO8601Format() }  // For SwiftUI List/ForEach

  /// The date of this balance snapshot (YYYY-MM-DD midnight UTC)
  let date: Date

  /// Total balance in non-investment accounts (current funds)
  let balance: InstrumentAmount

  /// Amount allocated to earmarks (subset of balance)
  let earmarked: InstrumentAmount

  /// Available funds = balance - earmarked
  let availableFunds: InstrumentAmount

  /// Total amount in investment accounts (contributed amount, not market value)
  let investments: InstrumentAmount

  /// Market value of investments (if available from investment tracking)
  let investmentValue: InstrumentAmount?

  /// Net worth = balance + (investmentValue ?? investments)
  let netWorth: InstrumentAmount

  /// Linear regression best-fit value (for trend line visualization)
  let bestFit: InstrumentAmount?

  /// True if this balance was projected from scheduled transactions
  /// (only present in scheduledBalances array from dailyBalances endpoint)
  let isForecast: Bool
}

extension DailyBalance {
  /// Convenience initializer for testing (sets isForecast: false, no bestFit)
  init(
    date: Date,
    balance: InstrumentAmount,
    earmarked: InstrumentAmount? = nil,
    investments: InstrumentAmount? = nil,
    investmentValue: InstrumentAmount? = nil
  ) {
    let earmarked = earmarked ?? .zero(instrument: balance.instrument)
    let investments = investments ?? .zero(instrument: balance.instrument)
    self.date = date
    self.balance = balance
    self.earmarked = earmarked
    self.availableFunds = balance - earmarked
    self.investments = investments
    self.investmentValue = investmentValue
    self.netWorth = balance + (investmentValue ?? investments)
    self.bestFit = nil
    self.isForecast = false
  }

  /// Returns a copy of this balance with a different date, preserving the
  /// original `isForecast` flag. Use `withDate(_:isForecast:)` to override it.
  func withDate(_ newDate: Date) -> DailyBalance {
    withDate(newDate, isForecast: self.isForecast)
  }

  /// Returns a copy of this balance with a different date and an explicit
  /// `isForecast` flag.
  func withDate(_ newDate: Date, isForecast: Bool) -> DailyBalance {
    DailyBalance(
      date: newDate,
      balance: balance,
      earmarked: earmarked,
      availableFunds: availableFunds,
      investments: investments,
      investmentValue: investmentValue,
      netWorth: netWorth,
      bestFit: bestFit,
      isForecast: isForecast
    )
  }
}
