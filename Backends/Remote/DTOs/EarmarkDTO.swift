import Foundation

struct EarmarkDTO: Codable {
  let id: String
  let name: String
  let position: Int
  let hidden: Bool
  let savingsTarget: Int?
  let savingsStartDate: String?
  let savingsEndDate: String?
  let balance: Int
  let saved: Int
  let spent: Int

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
  }()

  func toDomain() -> Earmark {
    Earmark(
      id: FlexibleUUID.parse(id) ?? UUID(),
      name: name,
      balance: MonetaryAmount(cents: balance, currency: Currency.defaultCurrency),
      saved: MonetaryAmount(cents: saved, currency: Currency.defaultCurrency),
      spent: MonetaryAmount(cents: spent, currency: Currency.defaultCurrency),
      isHidden: hidden,
      position: position,
      savingsGoal: savingsTarget.map {
        MonetaryAmount(cents: $0, currency: Currency.defaultCurrency)
      },
      savingsStartDate: savingsStartDate.flatMap { Self.dateFormatter.date(from: $0) },
      savingsEndDate: savingsEndDate.flatMap { Self.dateFormatter.date(from: $0) }
    )
  }

  struct ListWrapper: Codable {
    let earmarks: [EarmarkDTO]
  }
}
