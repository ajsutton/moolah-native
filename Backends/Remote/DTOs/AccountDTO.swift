import Foundation

struct AccountDTO: Codable {
  let id: String
  let name: String
  let type: String
  let balance: Int  // Transaction-based balance in cents
  let value: Int?  // Latest market value in cents (for investments). Not mapped to domain—InvestmentStore manages investment values independently
  let position: Int
  let hidden: Bool

  func toDomain(instrument: Instrument) -> Account {
    // Build positions from the balance field. The value field from the server is intentionally
    // not mapped because InvestmentStore manages investment values independently of account data.
    var positions: [Position] = []
    if balance != 0 {
      positions.append(Position(instrument: instrument, quantity: Decimal(balance) / 100))
    }

    return Account(
      id: FlexibleUUID.parse(id) ?? UUID(),
      name: name,
      type: AccountType(rawValue: type) ?? .asset,
      instrument: instrument,
      positions: positions,
      position: position,
      isHidden: hidden
    )
  }

  struct ListWrapper: Codable {
    let accounts: [AccountDTO]
  }
}

struct CreateAccountDTO: Codable {
  let name: String
  let type: String
  let balance: Int
  let position: Int
  let date: String
}

struct UpdateAccountDTO: Codable {
  let id: String
  let name: String
  let type: String
  let position: Int
  let hidden: Bool
}
