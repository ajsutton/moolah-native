import Foundation

struct EarmarkDTO: Codable {
  let id: String
  let name: String
  let position: Int?
  let hidden: Bool
  let savingsTarget: Int?
  let savingsStartDate: String?
  let savingsEndDate: String?
  let balance: Int
  let saved: Int
  let spent: Int

  func toDomain() -> Earmark {
    Earmark(
      id: FlexibleUUID.parse(id) ?? UUID(),
      name: name,
      balance: MonetaryAmount(cents: balance, currency: Currency.defaultCurrency),
      saved: MonetaryAmount(cents: saved, currency: Currency.defaultCurrency),
      spent: MonetaryAmount(cents: spent, currency: Currency.defaultCurrency),
      isHidden: hidden,
      position: position ?? 0,
      savingsGoal: savingsTarget.map {
        MonetaryAmount(cents: $0, currency: Currency.defaultCurrency)
      },
      savingsStartDate: savingsStartDate.flatMap { BackendDateFormatter.date(from: $0) },
      savingsEndDate: savingsEndDate.flatMap { BackendDateFormatter.date(from: $0) }
    )
  }

  static func fromDomain(_ earmark: Earmark) -> EarmarkDTO {
    EarmarkDTO(
      id: earmark.id.uuidString,
      name: earmark.name,
      position: earmark.position,
      hidden: earmark.isHidden,
      savingsTarget: earmark.savingsGoal?.cents,
      savingsStartDate: earmark.savingsStartDate.map { BackendDateFormatter.string(from: $0) },
      savingsEndDate: earmark.savingsEndDate.map { BackendDateFormatter.string(from: $0) },
      balance: earmark.balance.cents,
      saved: earmark.saved.cents,
      spent: earmark.spent.cents
    )
  }

  struct ListWrapper: Codable {
    let earmarks: [EarmarkDTO]
  }
}

/// DTO for creating a new earmark (excludes computed fields and only includes non-null optionals)
struct CreateEarmarkDTO: Codable {
  let name: String
  let savingsTarget: Int?
  let savingsStartDate: String?
  let savingsEndDate: String?

  init(from earmark: Earmark) {
    self.name = earmark.name
    self.savingsTarget = earmark.savingsGoal?.cents
    self.savingsStartDate = earmark.savingsStartDate.map { BackendDateFormatter.string(from: $0) }
    self.savingsEndDate = earmark.savingsEndDate.map { BackendDateFormatter.string(from: $0) }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)

    // Only encode non-nil values to avoid sending null
    if let savingsTarget = savingsTarget {
      try container.encode(savingsTarget, forKey: .savingsTarget)
    }
    if let savingsStartDate = savingsStartDate {
      try container.encode(savingsStartDate, forKey: .savingsStartDate)
    }
    if let savingsEndDate = savingsEndDate {
      try container.encode(savingsEndDate, forKey: .savingsEndDate)
    }
  }

  private enum CodingKeys: String, CodingKey {
    case name
    case savingsTarget
    case savingsStartDate
    case savingsEndDate
  }
}
