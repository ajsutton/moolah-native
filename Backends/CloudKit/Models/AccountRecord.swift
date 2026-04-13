import Foundation
import SwiftData

@Model
final class AccountRecord {

  #Index<AccountRecord>([\.id])

  var id: UUID = UUID()
  var name: String = ""
  var type: String = "bank"  // Raw value of AccountType
  var position: Int = 0
  var isHidden: Bool = false
  var currencyCode: String = ""
  var cachedBalance: Int?

  init(
    id: UUID = UUID(),
    name: String,
    type: String,
    position: Int = 0,
    isHidden: Bool = false,
    currencyCode: String,
    cachedBalance: Int? = nil
  ) {
    self.id = id
    self.name = name
    self.type = type
    self.position = position
    self.isHidden = isHidden
    self.currencyCode = currencyCode
    self.cachedBalance = cachedBalance
  }

  func toDomain(balance: MonetaryAmount, investmentValue: MonetaryAmount?) -> Account {
    Account(
      id: id,
      name: name,
      type: AccountType(rawValue: type) ?? .bank,
      balance: balance,
      investmentValue: investmentValue,
      position: position,
      isHidden: isHidden
    )
  }

  static func from(_ account: Account, currencyCode: String) -> AccountRecord {
    AccountRecord(
      id: account.id,
      name: account.name,
      type: account.type.rawValue,
      position: account.position,
      isHidden: account.isHidden,
      currencyCode: currencyCode
    )
  }
}
