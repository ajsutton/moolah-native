import Foundation
import SwiftData

@Model
final class AccountRecord {

  #Index<AccountRecord>([\.id])

  var id = UUID()
  var name: String = ""
  var type: String = "bank"  // Raw value of AccountType
  var position: Int = 0
  var instrumentId: String = "AUD"
  var isHidden: Bool = false
  var valuationMode: String = "recordedValue"  // Raw value of ValuationMode
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

  /// Throws `BackendError.dataCorrupted` when `type` carries a raw value
  /// the compiled `AccountType` enum doesn't recognise — see
  /// `AccountType.decoded(rawValue:)`.
  func toDomain(
    instruments: [String: Instrument] = [:],
    positions: [Position] = []
  ) throws -> Account {
    let instrument = instruments[instrumentId] ?? Instrument.fiat(code: instrumentId)
    return Account(
      id: id,
      name: name,
      type: try AccountType.decoded(rawValue: type),
      instrument: instrument,
      positions: positions,
      position: position,
      isHidden: isHidden,
      valuationMode: ValuationMode(rawValue: valuationMode) ?? .recordedValue
    )
  }

  static func from(_ account: Account) -> AccountRecord {
    let record = AccountRecord(
      id: account.id,
      name: account.name,
      type: account.type.rawValue,
      instrumentId: account.instrument.id,
      position: account.position,
      isHidden: account.isHidden
    )
    record.valuationMode = account.valuationMode.rawValue
    return record
  }
}
