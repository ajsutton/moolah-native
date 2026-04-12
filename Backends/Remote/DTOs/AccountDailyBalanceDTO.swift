import Foundation

struct AccountDailyBalanceDTO: Codable {
  let date: String  // "yyyy-MM-dd"
  let balance: Int  // Cents

  func toDomain(instrument: Instrument) -> AccountDailyBalance {
    let parsedDate = BackendDateFormatter.date(from: date) ?? Date()
    return AccountDailyBalance(
      date: parsedDate,
      balance: InstrumentAmount(quantity: Decimal(balance) / 100, instrument: instrument)
    )
  }
}
