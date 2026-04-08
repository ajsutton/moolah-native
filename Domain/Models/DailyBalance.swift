import Foundation

/// A single day's financial snapshot, either historical (isForecast: false)
/// or projected from scheduled transactions (isForecast: true).
struct DailyBalance: Sendable, Codable, Identifiable, Hashable {
  var id: String { date.ISO8601Format() }  // For SwiftUI List/ForEach

  /// The date of this balance snapshot (YYYY-MM-DD midnight UTC)
  let date: Date

  /// Total balance in non-investment accounts (current funds)
  let balance: MonetaryAmount

  /// Amount allocated to earmarks (subset of balance)
  let earmarked: MonetaryAmount

  /// Available funds = balance - earmarked
  let availableFunds: MonetaryAmount

  /// Total amount in investment accounts (contributed amount, not market value)
  let investments: MonetaryAmount

  /// Market value of investments (if available from investment tracking)
  let investmentValue: MonetaryAmount?

  /// Net worth = balance + (investmentValue ?? investments)
  let netWorth: MonetaryAmount

  /// Linear regression best-fit value (for trend line visualization)
  let bestFit: MonetaryAmount?

  /// True if this balance was projected from scheduled transactions
  /// (only present in scheduledBalances array from dailyBalances endpoint)
  let isForecast: Bool
}

extension DailyBalance {
  /// Convenience initializer for testing (sets isForecast: false, no bestFit)
  init(
    date: Date,
    balance: MonetaryAmount,
    earmarked: MonetaryAmount = .zero,
    investments: MonetaryAmount = .zero,
    investmentValue: MonetaryAmount? = nil
  ) {
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
}
