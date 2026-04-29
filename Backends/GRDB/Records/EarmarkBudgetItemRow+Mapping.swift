// Backends/GRDB/Records/EarmarkBudgetItemRow+Mapping.swift

import Foundation

extension EarmarkBudgetItemRow {
  /// The CloudKit recordType on the wire for this record. Frozen contract.
  static let recordType = "EarmarkBudgetItemRecord"

  /// Canonical CloudKit `recordName` for a UUID-keyed budget item.
  static func recordName(for id: UUID) -> String {
    "\(recordType)|\(id.uuidString)"
  }

  /// Builds a row from a domain `EarmarkBudgetItem`. The earmark id is
  /// supplied by the caller because `EarmarkBudgetItem` does not carry
  /// it (mirrors `EarmarkBudgetItemRecord` which takes a separate
  /// `earmarkId:` initializer parameter).
  init(domain: EarmarkBudgetItem, earmarkId: UUID) {
    self.id = domain.id
    self.recordName = Self.recordName(for: domain.id)
    self.earmarkId = earmarkId
    self.categoryId = domain.categoryId
    self.amount = domain.amount.storageValue
    self.instrumentId = domain.amount.instrument.id
    self.encodedSystemFields = nil
  }

  /// Domain projection. Mirrors `EarmarkBudgetItemRecord.toDomain` —
  /// when `earmarkInstrument` is supplied (the typical path through
  /// `EarmarkRepository.fetchBudget`), the amount is labelled in that
  /// instrument; otherwise falls back to the row's own `instrumentId`.
  func toDomain(earmarkInstrument: Instrument? = nil) -> EarmarkBudgetItem {
    let instrument = earmarkInstrument ?? Instrument.fiat(code: instrumentId)
    return EarmarkBudgetItem(
      id: id,
      categoryId: categoryId,
      amount: InstrumentAmount(storageValue: amount, instrument: instrument))
  }
}
