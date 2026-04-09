import Foundation

struct DailyBalancesResponseDTO: Codable {
  let dailyBalances: [DailyBalanceDTO]
  let scheduledBalances: [DailyBalanceDTO]?
}

struct DailyBalanceDTO: Codable {
  let date: String  // "YYYY-MM-DD"
  let balance: Int
  let earmarked: Int?  // Missing from scheduled balances
  let availableFunds: Int
  let investments: Int?  // Missing from scheduled balances
  let investmentValue: Int?
  let netWorth: Int?  // Missing from scheduled balances
  let bestFit: Double?

  func toDomain(currency: Currency, isForecast: Bool) -> DailyBalance {
    let balanceAmount = MonetaryAmount(cents: balance, currency: currency)
    let earmarkedAmount = MonetaryAmount(cents: earmarked ?? 0, currency: currency)
    let investmentsAmount = MonetaryAmount(cents: investments ?? 0, currency: currency)
    return DailyBalance(
      date: BackendDateFormatter.date(from: date) ?? Date(),
      balance: balanceAmount,
      earmarked: earmarkedAmount,
      availableFunds: MonetaryAmount(cents: availableFunds, currency: currency),
      investments: investmentsAmount,
      investmentValue: investmentValue.map {
        MonetaryAmount(cents: $0, currency: currency)
      },
      netWorth: MonetaryAmount(
        cents: netWorth ?? (balance + (investmentValue ?? (investments ?? 0))),
        currency: currency),
      bestFit: bestFit.map { MonetaryAmount(cents: Int($0), currency: currency) },
      isForecast: isForecast
    )
  }
}
