// Backends/GRDB/Records/InvestmentValueRow+Mapping.swift

import Foundation

extension InvestmentValueRow {
  /// The CloudKit recordType on the wire. Frozen contract.
  static let recordType = "InvestmentValueRecord"

  /// Canonical CloudKit `recordName` for a UUID-keyed investment value.
  static func recordName(for id: UUID) -> String {
    "\(recordType)|\(id.uuidString)"
  }

  /// Builds a row from a domain `InvestmentValue`. `InvestmentValue`
  /// does not carry an `accountId`, `id`, or `instrumentId` — the
  /// repository supplies them. Mirrors `InvestmentValueRecord(...)`
  /// in `Backends/CloudKit/Models/InvestmentValueRecord.swift`.
  init(
    id: UUID = UUID(),
    domain value: InvestmentValue,
    accountId: UUID
  ) {
    self.id = id
    self.recordName = Self.recordName(for: id)
    self.accountId = accountId
    self.date = value.date
    self.value = value.value.storageValue
    self.instrumentId = value.value.instrument.id
    self.encodedSystemFields = nil
  }

  /// Domain projection. Mirrors `InvestmentValueRecord.toDomain()` —
  /// reconstructs the amount in the row's recorded `instrumentId`,
  /// falling back to ambient fiat when no synced `instrument` row
  /// exists. Repositories that need a precise `Instrument` (e.g. for
  /// stock display) reconstruct it via `InstrumentRegistryRepository`
  /// before showing the result; this mirrors the SwiftData
  /// status-quo conversion-on-read behaviour.
  func toDomain() -> InvestmentValue {
    let instrument = Instrument.fiat(code: instrumentId)
    return InvestmentValue(
      date: date,
      value: InstrumentAmount(storageValue: value, instrument: instrument))
  }
}
