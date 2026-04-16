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
  var balance: InstrumentAmount
  /// Market value for investment accounts. Nil for non-investment accounts.
  var investmentValue: InstrumentAmount?
  var positions: [Position]
  /// Whether this account tracks per-instrument positions from transaction legs.
  /// When true, the account's value is derived from positions rather than manual investmentValue entries.
  /// When false (default), investment accounts use the legacy investmentValue approach.
  var usesPositionTracking: Bool
  var position: Int
  var isHidden: Bool

  /// The display value for this account. For investment accounts, prefers
  /// `investmentValue` (market value) over `balance` (invested amount).
  var displayBalance: InstrumentAmount {
    if type == .investment, let investmentValue {
      return investmentValue
    }
    return balance
  }

  init(
    id: UUID = UUID(),
    name: String,
    type: AccountType,
    balance: InstrumentAmount = .zero(instrument: .AUD),
    investmentValue: InstrumentAmount? = nil,
    positions: [Position] = [],
    usesPositionTracking: Bool = false,
    position: Int = 0,
    isHidden: Bool = false
  ) {
    self.id = id
    self.name = name
    self.type = type
    self.balance = balance
    self.investmentValue = investmentValue
    self.positions = positions
    self.usesPositionTracking = usesPositionTracking
    self.position = position
    self.isHidden = isHidden
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case type
    case balance
    case investmentValue
    case usesPositionTracking
    case position
    case isHidden = "hidden"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    type = try container.decode(AccountType.self, forKey: .type)
    balance = try container.decode(InstrumentAmount.self, forKey: .balance)
    investmentValue = try container.decodeIfPresent(InstrumentAmount.self, forKey: .investmentValue)
    positions = []
    usesPositionTracking =
      try container.decodeIfPresent(Bool.self, forKey: .usesPositionTracking) ?? false
    position = try container.decode(Int.self, forKey: .position)
    isHidden = try container.decode(Bool.self, forKey: .isHidden)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(type, forKey: .type)
    try container.encode(balance, forKey: .balance)
    try container.encodeIfPresent(investmentValue, forKey: .investmentValue)
    try container.encode(usesPositionTracking, forKey: .usesPositionTracking)
    try container.encode(position, forKey: .position)
    try container.encode(isHidden, forKey: .isHidden)
  }

  static func == (lhs: Account, rhs: Account) -> Bool {
    lhs.id == rhs.id && lhs.name == rhs.name && lhs.type == rhs.type
      && lhs.balance == rhs.balance && lhs.investmentValue == rhs.investmentValue
      && lhs.usesPositionTracking == rhs.usesPositionTracking
      && lhs.position == rhs.position && lhs.isHidden == rhs.isHidden
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(name)
    hasher.combine(type)
    hasher.combine(balance)
    hasher.combine(investmentValue)
    hasher.combine(usesPositionTracking)
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
      // Update legacy balance field for single-instrument accounts
      if let primaryPosition = copy.positions.first(where: {
        $0.instrument == copy.balance.instrument
      }) {
        copy.balance = primaryPosition.amount
      } else if copy.positions.isEmpty {
        copy.balance = .zero(instrument: copy.balance.instrument)
      }
      return copy
    }
    return Accounts(from: adjusted)
  }

  var endIndex: Int {
    return ordered.count
  }

  subscript(idex: Int) -> Account {
    ordered[idex]
  }
}
