import Foundation

struct DailyBalancesResponseDTO: Codable {
  let dailyBalances: [DailyBalanceDTO]
  let scheduledBalances: [DailyBalanceDTO]?
}

struct DailyBalanceDTO: Codable {
  let date: String  // "YYYY-MM-DD"
  let balance: Int
  let earmarked: Int
  let availableFunds: Int
  let investments: Int
  let investmentValue: Int?
  let netWorth: Int
  let bestFit: Double?

  func toDomain(isForecast: Bool) -> DailyBalance {
    return DailyBalance(
      date: BackendDateFormatter.date(from: date) ?? Date(),
      balance: MonetaryAmount(cents: balance, currency: .defaultCurrency),
      earmarked: MonetaryAmount(cents: earmarked, currency: .defaultCurrency),
      availableFunds: MonetaryAmount(cents: availableFunds, currency: .defaultCurrency),
      investments: MonetaryAmount(cents: investments, currency: .defaultCurrency),
      investmentValue: investmentValue.map {
        MonetaryAmount(cents: $0, currency: .defaultCurrency)
      },
      netWorth: MonetaryAmount(cents: netWorth, currency: .defaultCurrency),
      bestFit: bestFit.map { MonetaryAmount(cents: Int($0), currency: .defaultCurrency) },
      isForecast: isForecast
    )
  }
}
