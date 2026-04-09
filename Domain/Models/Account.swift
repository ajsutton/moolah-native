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
  var balance: MonetaryAmount
  /// Market value for investment accounts. Nil for non-investment accounts.
  var investmentValue: MonetaryAmount?
  var position: Int
  var isHidden: Bool

  /// The display value for this account. For investment accounts, prefers
  /// `investmentValue` (market value) over `balance` (invested amount).
  var displayBalance: MonetaryAmount {
    if type == .investment, let investmentValue {
      return investmentValue
    }
    return balance
  }

  init(
    id: UUID = UUID(),
    name: String,
    type: AccountType,
    balance: MonetaryAmount = .zero,
    investmentValue: MonetaryAmount? = nil,
    position: Int = 0,
    isHidden: Bool = false
  ) {
    self.id = id
    self.name = name
    self.type = type
    self.balance = balance
    self.investmentValue = investmentValue
    self.position = position
    self.isHidden = isHidden
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case type
    case balance
    case investmentValue
    case position
    case isHidden = "hidden"
  }

  static func < (lhs: Account, rhs: Account) -> Bool {
    lhs.position < rhs.position
  }
}

struct Accounts: RandomAccessCollection {
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

  /// Returns a new Accounts collection with the balance of the given account adjusted by `delta`.
  func adjustingBalance(of accountId: UUID, by delta: MonetaryAmount) -> Accounts {
    guard byId[accountId] != nil else { return self }
    let adjusted = ordered.map { account in
      guard account.id == accountId else { return account }
      var copy = account
      copy.balance = copy.balance + delta
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
