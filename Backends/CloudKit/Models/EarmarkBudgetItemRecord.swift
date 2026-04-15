import Foundation
import SwiftData

@Model
final class EarmarkBudgetItemRecord {

  #Index<EarmarkBudgetItemRecord>([\.id], [\.earmarkId])

  var id: UUID = UUID()
  var earmarkId: UUID = UUID()
  var categoryId: UUID = UUID()
  var amount: Int64 = 0  // storageValue (× 10^8)
  var instrumentId: String = ""
  var encodedSystemFields: Data?

  init(
    id: UUID = UUID(),
    earmarkId: UUID,
    categoryId: UUID,
    amount: Int64,
    instrumentId: String
  ) {
    self.id = id
    self.earmarkId = earmarkId
    self.categoryId = categoryId
    self.amount = amount
    self.instrumentId = instrumentId
  }

  func toDomain() -> EarmarkBudgetItem {
    let instrument = Instrument.fiat(code: instrumentId)
    return EarmarkBudgetItem(
      id: id, categoryId: categoryId,
      amount: InstrumentAmount(storageValue: amount, instrument: instrument))
  }
}
