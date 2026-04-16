import Foundation

struct AccountDTO: Codable {
  let id: String
  let name: String
  let type: String
  let balance: Int  // Transaction-based balance in cents
  let value: Int?  // Latest market value in cents (for investments)
  let position: Int
  let hidden: Bool

  func toDomain(instrument: Instrument) -> Account {
    let investmentValue: InstrumentAmount? =
      if type == "investment", let value {
        InstrumentAmount(quantity: Decimal(value) / 100, instrument: instrument)
      } else {
        nil
      }

    return Account(
      id: FlexibleUUID.parse(id) ?? UUID(),
      name: name,
      type: AccountType(rawValue: type) ?? .asset,
      instrument: instrument,
      balance: InstrumentAmount(quantity: Decimal(balance) / 100, instrument: instrument),
      investmentValue: investmentValue,
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
