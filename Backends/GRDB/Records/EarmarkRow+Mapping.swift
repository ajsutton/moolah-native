// Backends/GRDB/Records/EarmarkRow+Mapping.swift

import Foundation

extension EarmarkRow {
  /// The CloudKit recordType on the wire for this record. Frozen contract.
  static let recordType = "EarmarkRecord"

  /// Canonical CloudKit `recordName` for a UUID-keyed earmark.
  static func recordName(for id: UUID) -> String {
    "\(recordType)|\(id.uuidString)"
  }

  init(domain: Earmark) {
    self.id = domain.id
    self.recordName = Self.recordName(for: domain.id)
    self.name = domain.name
    self.position = domain.position
    self.isHidden = domain.isHidden
    self.instrumentId = domain.instrument.id
    self.savingsTarget = domain.savingsGoal?.storageValue
    // Legacy column — populated from the goal's instrument when present
    // (matches `EarmarkRecord.from(_:)` at lines 78–79). The reader
    // ignores this; preserving the bytes keeps the wire format identical
    // for migrator byte-equality tests.
    self.savingsTargetInstrumentId = domain.savingsGoal?.instrument.id
    self.savingsStartDate = domain.savingsStartDate
    self.savingsEndDate = domain.savingsEndDate
    self.encodedSystemFields = nil
  }

  /// Domain projection. Mirrors `EarmarkRecord.toDomain(...)` line-for-line.
  /// The savings goal is always labelled in the earmark's own `instrument`
  /// — see `EarmarkRecord.toDomain` at lines 53–56 for the policy.
  func toDomain(
    defaultInstrument: Instrument,
    positions: [Position] = [],
    savedPositions: [Position] = [],
    spentPositions: [Position] = []
  ) -> Earmark {
    let instrument = instrumentId.map { Instrument.fiat(code: $0) } ?? defaultInstrument
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
}
