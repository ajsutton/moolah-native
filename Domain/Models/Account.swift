import Foundation

enum AccountType: String, Codable, Sendable, CaseIterable {
  case bank
  case creditCard = "cc"
  case asset
  case investment

  var isCurrent: Bool {
    self == .bank || self == .asset || self == .creditCard
  }

  var displayName: String {
    switch self {
    case .bank: return "Bank Account"
    case .creditCard: return "Credit Card"
    case .asset: return "Asset"
    case .investment: return "Investment"
    }
  }
}

struct Account: Codable, Sendable, Identifiable, Hashable, Comparable {
  let id: UUID
  var name: String
  var type: AccountType
  var instrument: Instrument
  var positions: [Position]
  var position: Int
  var isHidden: Bool

  init(
    id: UUID = UUID(),
    name: String,
    type: AccountType,
    instrument: Instrument,
    positions: [Position] = [],
    position: Int = 0,
    isHidden: Bool = false
  ) {
    self.id = id
    self.name = name
    self.type = type
    self.instrument = instrument
    self.positions = positions
    self.position = position
    self.isHidden = isHidden
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case type
    case instrument
    case position
    case isHidden = "hidden"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    type = try container.decode(AccountType.self, forKey: .type)
    instrument = try container.decodeIfPresent(Instrument.self, forKey: .instrument) ?? .AUD
    positions = []
    position = try container.decode(Int.self, forKey: .position)
    isHidden = try container.decode(Bool.self, forKey: .isHidden)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(type, forKey: .type)
    try container.encode(instrument, forKey: .instrument)
    try container.encode(position, forKey: .position)
    try container.encode(isHidden, forKey: .isHidden)
  }

  static func == (lhs: Account, rhs: Account) -> Bool {
    lhs.id == rhs.id && lhs.name == rhs.name && lhs.type == rhs.type
      && lhs.instrument == rhs.instrument
      && lhs.position == rhs.position && lhs.isHidden == rhs.isHidden
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(name)
    hasher.combine(type)
    hasher.combine(instrument)
    hasher.combine(position)
    hasher.combine(isHidden)
  }

  static func < (lhs: Account, rhs: Account) -> Bool {
    lhs.position < rhs.position
  }
}

struct Accounts: RandomAccessCollection, Sendable {
  let startIndex: Int = 0

  let ordered: [Account]
  let byId: [UUID: Account]

  init(from: [Account]) {
    byId = from.reduce(into: [:]) { $0[$1.id] = $1 }
    ordered = from.sorted()
  }

  func by(id: UUID) -> Account? {
    byId[id]
  }

  /// Returns a new Accounts collection with positions adjusted by instrument deltas.
  func adjustingPositions(of accountId: UUID, by deltas: [Instrument: Decimal]) -> Accounts {
    guard byId[accountId] != nil else { return self }
    let adjusted = ordered.map { account in
      guard account.id == accountId else { return account }
      var copy = account
      copy.positions = copy.positions.applying(deltas: deltas)
      return copy
    }
    return Accounts(from: adjusted)
  }

  var endIndex: Int {
    ordered.count
  }

  subscript(idex: Int) -> Account {
    ordered[idex]
  }
}
