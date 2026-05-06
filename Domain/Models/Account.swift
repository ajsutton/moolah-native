import Foundation

// SyncBoundary — adding a case requires bumping DataFormatVersion.current.
enum AccountType: String, Codable, Sendable, CaseIterable {
  case bank
  case creditCard = "cc"
  case asset
  case investment
  case crypto

  var isCurrent: Bool {
    self == .bank || self == .asset || self == .creditCard
  }

  /// Whether this type should be treated as an investment account for sidebar
  /// grouping and any query that filters investments. `true` for `.investment`
  /// and `.crypto`.
  var isInvestmentLike: Bool {
    self == .investment || self == .crypto
  }

  var displayName: String {
    switch self {
    case .bank: return "Bank Account"
    case .creditCard: return "Credit Card"
    case .asset: return "Asset"
    case .investment: return "Investment"
    case .crypto: return "Crypto Wallet"
    }
  }
}

struct Account {
  let id: UUID
  var name: String
  var type: AccountType
  var instrument: Instrument
  var positions: [Position]
  var position: Int
  var isHidden: Bool
  /// `0x…` lowercased wallet address. Required when `type == .crypto`.
  var walletAddress: String?
  /// EVM chain ID (1 = Ethereum, 10 = OP, 8453 = Base, 137 = Polygon).
  /// Required when `type == .crypto`.
  var chainId: Int?
  var valuationMode: ValuationMode

  init(
    id: UUID = UUID(),
    name: String,
    type: AccountType,
    instrument: Instrument,
    positions: [Position] = [],
    position: Int = 0,
    isHidden: Bool = false,
    valuationMode: ValuationMode = .recordedValue,
    walletAddress: String? = nil,
    chainId: Int? = nil
  ) {
    self.id = id
    self.name = name
    self.type = type
    self.instrument = instrument
    self.positions = positions
    self.position = position
    self.isHidden = isHidden
    self.valuationMode = valuationMode
    self.walletAddress = walletAddress
    self.chainId = chainId
  }
}

extension Account: Sendable {}

extension Account: Identifiable {}

extension Account: Codable {
  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case type
    case instrument
    case position
    case isHidden = "hidden"
    case valuationMode
    case walletAddress
    case chainId
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    // Defensive decode for `type`: an older build receiving an Account
    // record from a newer device (e.g. with `type = "crypto"` before this
    // build added the case, or any future type after) falls back to
    // `.asset` rather than throwing — so archive/preview paths don't
    // break on encountering a future type. The wire-layer mapper applies
    // the same fallback for sync correctness.
    let typeRaw = try container.decode(String.self, forKey: .type)
    type = AccountType(rawValue: typeRaw) ?? .asset
    instrument = try container.decodeIfPresent(Instrument.self, forKey: .instrument) ?? .AUD
    // positions are not persisted via Codable — they are computed by the
    // repository layer from transaction legs and injected at fetch time.
    positions = []
    position = try container.decode(Int.self, forKey: .position)
    isHidden = try container.decode(Bool.self, forKey: .isHidden)
    valuationMode =
      try container.decodeIfPresent(ValuationMode.self, forKey: .valuationMode) ?? .recordedValue
    walletAddress = try container.decodeIfPresent(String.self, forKey: .walletAddress)
    chainId = try container.decodeIfPresent(Int.self, forKey: .chainId)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(type, forKey: .type)
    try container.encode(instrument, forKey: .instrument)
    try container.encode(position, forKey: .position)
    try container.encode(isHidden, forKey: .isHidden)
    try container.encode(valuationMode, forKey: .valuationMode)
    try container.encodeIfPresent(walletAddress, forKey: .walletAddress)
    try container.encodeIfPresent(chainId, forKey: .chainId)
  }
}

extension Account: Hashable {
  static func == (lhs: Account, rhs: Account) -> Bool {
    lhs.id == rhs.id && lhs.name == rhs.name && lhs.type == rhs.type
      && lhs.instrument == rhs.instrument
      && lhs.position == rhs.position && lhs.isHidden == rhs.isHidden
      && lhs.valuationMode == rhs.valuationMode
      && lhs.walletAddress == rhs.walletAddress && lhs.chainId == rhs.chainId
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(name)
    hasher.combine(type)
    hasher.combine(instrument)
    hasher.combine(position)
    hasher.combine(isHidden)
    hasher.combine(valuationMode)
    hasher.combine(walletAddress)
    hasher.combine(chainId)
  }
}

extension Account: Comparable {
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
