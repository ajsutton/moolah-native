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
  var instrument: Instrument
  var positions: [Position]
  var savedPositions: [Position]
  var spentPositions: [Position]
  var isHidden: Bool
  var position: Int
  var savingsGoal: InstrumentAmount?
  var savingsStartDate: Date?
  var savingsEndDate: Date?

  init(
    id: UUID = UUID(),
    name: String,
    instrument: Instrument = .AUD,
    positions: [Position] = [],
    savedPositions: [Position] = [],
    spentPositions: [Position] = [],
    isHidden: Bool = false,
    position: Int = 0,
    savingsGoal: InstrumentAmount? = nil,
    savingsStartDate: Date? = nil,
    savingsEndDate: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.instrument = instrument
    self.positions = positions
    self.savedPositions = savedPositions
    self.spentPositions = spentPositions
    self.isHidden = isHidden
    self.position = position
    self.savingsGoal = savingsGoal
    self.savingsStartDate = savingsStartDate
    self.savingsEndDate = savingsEndDate
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case instrument
    case isHidden = "hidden"
    case position
    case savingsGoal = "savingsTarget"
    case savingsStartDate
    case savingsEndDate
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    instrument =
      try container.decodeIfPresent(Instrument.self, forKey: .instrument) ?? .AUD
    positions = []
    savedPositions = []
    spentPositions = []
    isHidden = try container.decode(Bool.self, forKey: .isHidden)
    position = try container.decode(Int.self, forKey: .position)
    savingsGoal = try container.decodeIfPresent(InstrumentAmount.self, forKey: .savingsGoal)
    savingsStartDate = try container.decodeIfPresent(Date.self, forKey: .savingsStartDate)
    savingsEndDate = try container.decodeIfPresent(Date.self, forKey: .savingsEndDate)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(instrument, forKey: .instrument)
    try container.encode(isHidden, forKey: .isHidden)
    try container.encode(position, forKey: .position)
    try container.encodeIfPresent(savingsGoal, forKey: .savingsGoal)
    try container.encodeIfPresent(savingsStartDate, forKey: .savingsStartDate)
    try container.encodeIfPresent(savingsEndDate, forKey: .savingsEndDate)
  }

  static func == (lhs: Earmark, rhs: Earmark) -> Bool {
    lhs.id == rhs.id && lhs.name == rhs.name
      && lhs.instrument == rhs.instrument
      && lhs.positions == rhs.positions
      && lhs.savedPositions == rhs.savedPositions
      && lhs.spentPositions == rhs.spentPositions
      && lhs.isHidden == rhs.isHidden && lhs.position == rhs.position
      && lhs.savingsGoal == rhs.savingsGoal
      && lhs.savingsStartDate == rhs.savingsStartDate
      && lhs.savingsEndDate == rhs.savingsEndDate
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(name)
    hasher.combine(instrument)
    hasher.combine(positions)
    hasher.combine(savedPositions)
    hasher.combine(spentPositions)
    hasher.combine(isHidden)
    hasher.combine(position)
    hasher.combine(savingsGoal)
    hasher.combine(savingsStartDate)
    hasher.combine(savingsEndDate)
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

  /// Returns a new Earmarks collection with positions, savedPositions, and spentPositions adjusted.
  func adjustingPositions(
    of earmarkId: UUID,
    positionDeltas: [Instrument: Decimal],
    savedDeltas: [Instrument: Decimal],
    spentDeltas: [Instrument: Decimal]
  ) -> Earmarks {
    guard byId[earmarkId] != nil else { return self }
    let adjusted = ordered.map { earmark in
      guard earmark.id == earmarkId else { return earmark }
      var copy = earmark
      copy.positions = copy.positions.applying(deltas: positionDeltas)
      copy.savedPositions = copy.savedPositions.applying(deltas: savedDeltas)
      copy.spentPositions = copy.spentPositions.applying(deltas: spentDeltas)
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
