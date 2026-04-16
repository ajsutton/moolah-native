import Foundation
import SwiftData

@Model
final class EarmarkRecord {

  #Index<EarmarkRecord>([\.id])

  var id: UUID = UUID()
  var name: String = ""
  var position: Int = 0
  var isHidden: Bool = false
  var savingsTarget: Int64?  // storageValue (× 10^8)
  var savingsTargetInstrumentId: String?
  var savingsStartDate: Date?
  var savingsEndDate: Date?
  var encodedSystemFields: Data?

  init(
    id: UUID = UUID(),
    name: String,
    position: Int = 0,
    isHidden: Bool = false,
    savingsTarget: Int64? = nil,
    savingsTargetInstrumentId: String? = nil,
    savingsStartDate: Date? = nil,
    savingsEndDate: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.position = position
    self.isHidden = isHidden
    self.savingsTarget = savingsTarget
    self.savingsTargetInstrumentId = savingsTargetInstrumentId
    self.savingsStartDate = savingsStartDate
    self.savingsEndDate = savingsEndDate
  }

  func toDomain(
    balance: InstrumentAmount, saved: InstrumentAmount, spent: InstrumentAmount,
    positions: [Position] = [], savedPositions: [Position] = [], spentPositions: [Position] = []
  ) -> Earmark {
    let savingsGoal: InstrumentAmount? = savingsTarget.flatMap { target in
      guard let instrumentId = savingsTargetInstrumentId else { return nil }
      let instrument = Instrument.fiat(code: instrumentId)
      return InstrumentAmount(storageValue: target, instrument: instrument)
    }
    return Earmark(
      id: id,
      name: name,
      balance: balance,
      saved: saved,
      spent: spent,
      positions: positions,
      savedPositions: savedPositions,
      spentPositions: spentPositions,
      isHidden: isHidden,
      position: position,
      savingsGoal: savingsGoal,
      savingsStartDate: savingsStartDate,
      savingsEndDate: savingsEndDate
    )
  }

  static func from(_ earmark: Earmark) -> EarmarkRecord {
    EarmarkRecord(
      id: earmark.id,
      name: earmark.name,
      position: earmark.position,
      isHidden: earmark.isHidden,
      savingsTarget: earmark.savingsGoal?.storageValue,
      savingsTargetInstrumentId: earmark.savingsGoal?.instrument.id,
      savingsStartDate: earmark.savingsStartDate,
      savingsEndDate: earmark.savingsEndDate
    )
  }
}
