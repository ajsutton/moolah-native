// Backends/GRDB/Records/AccountRow+Mapping.swift

import Foundation

extension AccountRow {
  /// The CloudKit recordType on the wire. Frozen contract.
  static let recordType = "AccountRecord"

  /// Canonical CloudKit `recordName` for a UUID-keyed account.
  static func recordName(for id: UUID) -> String {
    "\(recordType)|\(id.uuidString)"
  }

  /// Builds a row from a domain `Account`. The `instrument` value is
  /// flattened to its id; the repository reconstructs the full
  /// `Instrument` on `toDomain`.
  init(domain: Account) {
    self.id = domain.id
    self.recordName = Self.recordName(for: domain.id)
    self.name = domain.name
    self.type = domain.type.rawValue
    self.instrumentId = domain.instrument.id
    self.position = domain.position
    self.isHidden = domain.isHidden
    self.encodedSystemFields = nil
  }

  /// Domain projection. `instruments` is the registry lookup
  /// table (`[String: Instrument]`); falls back to ambient fiat for
  /// unknown ids — mirrors `AccountRecord.toDomain`. `positions` are
  /// computed by the analysis layer and passed through here.
  ///
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
      isHidden: isHidden)
  }
}
