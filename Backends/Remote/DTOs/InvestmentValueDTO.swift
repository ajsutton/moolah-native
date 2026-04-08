import Foundation

struct InvestmentValueDTO: Codable {
  let date: String  // "yyyy-MM-dd"
  let value: Int  // Cents

  func toDomain() -> InvestmentValue {
    let parsedDate = BackendDateFormatter.date(from: date) ?? Date()
    return InvestmentValue(
      date: parsedDate,
      value: MonetaryAmount(cents: value, currency: Currency.defaultCurrency)
    )
  }

  struct ListWrapper: Codable {
    let values: [InvestmentValueDTO]
    let hasMore: Bool
  }
}
