import Foundation

struct Earmark: Codable, Sendable, Identifiable, Hashable, Comparable {
  let id: UUID
  var name: String
  var balance: MonetaryAmount
  var saved: MonetaryAmount
  var spent: MonetaryAmount
  var isHidden: Bool
  var position: Int
  var savingsGoal: MonetaryAmount?
  var savingsStartDate: Date?
  var savingsEndDate: Date?

  init(
    id: UUID = UUID(),
    name: String,
    balance: MonetaryAmount = .zero,
    saved: MonetaryAmount = .zero,
    spent: MonetaryAmount = .zero,
    isHidden: Bool = false,
    position: Int = 0,
    savingsGoal: MonetaryAmount? = nil,
    savingsStartDate: Date? = nil,
    savingsEndDate: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.balance = balance
    self.saved = saved
    self.spent = spent
    self.isHidden = isHidden
    self.position = position
    self.savingsGoal = savingsGoal
    self.savingsStartDate = savingsStartDate
    self.savingsEndDate = savingsEndDate
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case balance
    case saved
    case spent
    case isHidden = "hidden"
    case position
    case savingsGoal = "savingsTarget"
    case savingsStartDate
    case savingsEndDate
  }

  static func < (lhs: Earmark, rhs: Earmark) -> Bool {
    lhs.position < rhs.position
  }
}

struct Earmarks: RandomAccessCollection {
  let startIndex: Int = 0

  let ordered: [Earmark]
  let byId: [UUID: Earmark]

  init(from: [Earmark]) {
    byId = from.reduce(into: [:]) { $0[$1.id] = $1 }
    ordered = from.sorted()
  }

  func by(id: UUID) -> Earmark? {
    byId[id]
  }

  var endIndex: Int {
    return ordered.count
  }

  subscript(index: Int) -> Earmark {
    ordered[index]
  }
}
