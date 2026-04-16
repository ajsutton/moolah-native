import Foundation

struct EarmarkDTO: Codable {
  let id: ServerUUID
  let name: String
  let position: Int?
  let hidden: Bool
  let savingsTarget: Int?
  let savingsStartDate: String?
  let savingsEndDate: String?
  let balance: Int
  let saved: Int
  let spent: Int

  func toDomain(instrument: Instrument) -> Earmark {
    let balanceAmount = InstrumentAmount(quantity: Decimal(balance) / 100, instrument: instrument)
    let savedAmount = InstrumentAmount(quantity: Decimal(saved) / 100, instrument: instrument)
    let spentAmount = InstrumentAmount(quantity: Decimal(spent) / 100, instrument: instrument)

    return Earmark(
      id: id.uuid,
      name: name,
      instrument: instrument,
      positions: balanceAmount.isZero
        ? [] : [Position(instrument: instrument, quantity: balanceAmount.quantity)],
      savedPositions: savedAmount.isZero
        ? [] : [Position(instrument: instrument, quantity: savedAmount.quantity)],
      spentPositions: spentAmount.isZero
        ? [] : [Position(instrument: instrument, quantity: spentAmount.quantity)],
      isHidden: hidden,
      position: position ?? 0,
      savingsGoal: savingsTarget.map {
        InstrumentAmount(quantity: Decimal($0) / 100, instrument: instrument)
      },
      savingsStartDate: savingsStartDate.flatMap { BackendDateFormatter.date(from: $0) },
      savingsEndDate: savingsEndDate.flatMap { BackendDateFormatter.date(from: $0) }
    )
  }

  static func fromDomain(_ earmark: Earmark) -> EarmarkDTO {
    let balanceQty = earmark.positions.reduce(Decimal.zero) { $0 + $1.quantity }
    let savedQty = earmark.savedPositions.reduce(Decimal.zero) { $0 + $1.quantity }
    let spentQty = earmark.spentPositions.reduce(Decimal.zero) { $0 + $1.quantity }

    return EarmarkDTO(
      id: ServerUUID(earmark.id),
      name: earmark.name,
      position: earmark.position,
      hidden: earmark.isHidden,
      savingsTarget: earmark.savingsGoal.map {
        Int(truncating: ($0.quantity * 100) as NSDecimalNumber)
      },
      savingsStartDate: earmark.savingsStartDate.map { BackendDateFormatter.string(from: $0) },
      savingsEndDate: earmark.savingsEndDate.map { BackendDateFormatter.string(from: $0) },
      balance: Int(truncating: (balanceQty * 100) as NSDecimalNumber),
      saved: Int(truncating: (savedQty * 100) as NSDecimalNumber),
      spent: Int(truncating: (spentQty * 100) as NSDecimalNumber)
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
    self.savingsTarget = earmark.savingsGoal.map {
      Int(truncating: ($0.quantity * 100) as NSDecimalNumber)
    }
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
