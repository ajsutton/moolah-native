import Foundation
import SwiftData

@Model
final class AccountRecord {

  #Index<AccountRecord>([\.id])

  var id: UUID = UUID()
  var name: String = ""
  var type: String = "bank"  // Raw value of AccountType
  var position: Int = 0
  var instrumentId: String = "AUD"
  var isHidden: Bool = false
  var encodedSystemFields: Data?

  init(
    id: UUID = UUID(),
    name: String,
    type: String,
    instrumentId: String = "AUD",
    position: Int = 0,
    isHidden: Bool = false
  ) {
    self.id = id
    self.name = name
    self.type = type
    self.instrumentId = instrumentId
    self.position = position
    self.isHidden = isHidden
  }

  func toDomain(
    instrument: Instrument,
    positions: [Position] = []
  ) -> Account {
    Account(
      id: id,
      name: name,
      type: AccountType(rawValue: type) ?? .bank,
      instrument: instrument,
      positions: positions,
      position: position,
      isHidden: isHidden
    )
  }

  static func from(_ account: Account) -> AccountRecord {
    AccountRecord(
      id: account.id,
      name: account.name,
      type: account.type.rawValue,
      instrumentId: account.instrument.id,
      position: account.position,
      isHidden: account.isHidden
    )
  }
}
