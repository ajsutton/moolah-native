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

  func toDomain(instrument: Instrument, isForecast: Bool) -> DailyBalance {
    let balanceAmount = InstrumentAmount(quantity: Decimal(balance) / 100, instrument: instrument)
    let earmarkedAmount = InstrumentAmount(
      quantity: Decimal(earmarked ?? 0) / 100, instrument: instrument)
    let investmentsAmount = InstrumentAmount(
      quantity: Decimal(investments ?? 0) / 100, instrument: instrument)
    return DailyBalance(
      date: BackendDateFormatter.date(from: date) ?? Date(),
      balance: balanceAmount,
      earmarked: earmarkedAmount,
      availableFunds: InstrumentAmount(
        quantity: Decimal(availableFunds) / 100, instrument: instrument),
      investments: investmentsAmount,
      investmentValue: investmentValue.map {
        InstrumentAmount(quantity: Decimal($0) / 100, instrument: instrument)
      },
      netWorth: InstrumentAmount(
        quantity: Decimal(netWorth ?? (balance + (investmentValue ?? (investments ?? 0)))) / 100,
        instrument: instrument),
      bestFit: bestFit.map {
        InstrumentAmount(quantity: Decimal($0) / 100, instrument: instrument)
      },
      isForecast: isForecast
    )
  }
}
