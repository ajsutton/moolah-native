import Foundation
import SwiftData

@Model
final class InvestmentValueRecord {

  #Index<InvestmentValueRecord>([\.id], [\.accountId])

  var id: UUID = UUID()
  var accountId: UUID = UUID()
  var date: Date = Date()
  var value: Int64 = 0  // storageValue (× 10^8)
  var instrumentId: String = ""
  var encodedSystemFields: Data?

  init(
    id: UUID = UUID(),
    accountId: UUID,
    date: Date,
    value: Int64,
    instrumentId: String
  ) {
    self.id = id
    self.accountId = accountId
    self.date = date
    self.value = value
    self.instrumentId = instrumentId
  }

  func toDomain() -> InvestmentValue {
    let instrument = Instrument.fiat(code: instrumentId)
    return InvestmentValue(
      date: date, value: InstrumentAmount(storageValue: value, instrument: instrument))
  }
}
