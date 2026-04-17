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
  var instrumentId: String?
  var savingsEndDate: Date?
  var encodedSystemFields: Data?

  init(
    id: UUID = UUID(),
    name: String,
    position: Int = 0,
    isHidden: Bool = false,
    instrumentId: String? = nil,
    savingsTarget: Int64? = nil,
    savingsTargetInstrumentId: String? = nil,
    savingsStartDate: Date? = nil,
    savingsEndDate: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.position = position
    self.isHidden = isHidden
    self.instrumentId = instrumentId
    self.savingsTarget = savingsTarget
    self.savingsTargetInstrumentId = savingsTargetInstrumentId
    self.savingsStartDate = savingsStartDate
    self.savingsEndDate = savingsEndDate
  }

  func toDomain(
    defaultInstrument: Instrument,
    positions: [Position] = [], savedPositions: [Position] = [], spentPositions: [Position] = []
  ) -> Earmark {
    let instrument = instrumentId.map { Instrument.fiat(code: $0) } ?? defaultInstrument
    // Savings goal is always expressed in the earmark's own instrument. The
    // `savingsTargetInstrumentId` column is preserved for backwards
    // compatibility with older records but any drift is resolved here — the
    // quantity is kept, the label is the earmark's instrument.
    let savingsGoal: InstrumentAmount? = savingsTarget.map { target in
      InstrumentAmount(storageValue: target, instrument: instrument)
    }
    return Earmark(
      id: id,
      name: name,
      instrument: instrument,
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
      instrumentId: earmark.instrument.id,
      savingsTarget: earmark.savingsGoal?.storageValue,
      savingsTargetInstrumentId: earmark.savingsGoal?.instrument.id,
      savingsStartDate: earmark.savingsStartDate,
      savingsEndDate: earmark.savingsEndDate
    )
  }
}
