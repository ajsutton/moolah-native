import Foundation

struct InvestmentValueDTO: Codable {
  let date: String  // "yyyy-MM-dd"
  let value: Int  // Cents

  func toDomain(currency: Currency) -> InvestmentValue {
    let parsedDate = BackendDateFormatter.date(from: date) ?? Date()
    return InvestmentValue(
      date: parsedDate,
      value: MonetaryAmount(cents: value, currency: currency)
    )
  }

  struct ListWrapper: Codable {
    let values: [InvestmentValueDTO]
    let hasMore: Bool
  }
}
