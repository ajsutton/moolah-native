import Foundation

struct AccountDailyBalanceDTO: Codable {
  let date: String  // "yyyy-MM-dd"
  let balance: Int  // Cents

  func toDomain() -> AccountDailyBalance {
    let parsedDate = BackendDateFormatter.date(from: date) ?? Date()
    return AccountDailyBalance(
      date: parsedDate,
      balance: MonetaryAmount(cents: balance, currency: Currency.defaultCurrency)
    )
  }
}
