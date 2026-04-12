import Foundation

struct EarmarkBudgetItem: Codable, Sendable, Identifiable, Hashable {
  let id: UUID
  var categoryId: UUID
  var amount: InstrumentAmount

  init(id: UUID = UUID(), categoryId: UUID, amount: InstrumentAmount) {
    self.id = id
    self.categoryId = categoryId
    self.amount = amount
  }
}

struct Earmark: Codable, Sendable, Identifiable, Hashable, Comparable {
  let id: UUID
  var name: String
  var balance: InstrumentAmount
  var saved: InstrumentAmount
  var spent: InstrumentAmount
  var isHidden: Bool
  var position: Int
  var savingsGoal: InstrumentAmount?
  var savingsStartDate: Date?
  var savingsEndDate: Date?

  init(
    id: UUID = UUID(),
    name: String,
    balance: InstrumentAmount = .zero(instrument: .AUD),
    saved: InstrumentAmount = .zero(instrument: .AUD),
    spent: InstrumentAmount = .zero(instrument: .AUD),
    isHidden: Bool = false,
    position: Int = 0,
    savingsGoal: InstrumentAmount? = nil,
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

struct Earmarks: RandomAccessCollection, Sendable {
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

  /// Returns a new Earmarks collection with the balance, saved, and spent adjusted for the given earmark.
  /// Positive deltas increase saved and balance; negative deltas increase spent and decrease balance.
  func adjustingBalance(of earmarkId: UUID, by delta: InstrumentAmount) -> Earmarks {
    guard byId[earmarkId] != nil else { return self }
    let adjusted = ordered.map { earmark in
      guard earmark.id == earmarkId else { return earmark }
      var copy = earmark
      copy.balance = copy.balance + delta

      if delta.isPositive {
        // Positive delta: income/saving
        copy.saved = copy.saved + delta
      } else if delta.isNegative {
        // Negative delta: expense
        copy.spent = copy.spent + (-delta)
      }
      return copy
    }
    return Earmarks(from: adjusted)
  }

  var endIndex: Int {
    return ordered.count
  }

  subscript(index: Int) -> Earmark {
    ordered[index]
  }
}
