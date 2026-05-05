// Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository+Lookup.swift

import Foundation
import GRDB

extension GRDBInstrumentRegistryRepository {
  /// Looks up a single crypto registration by id. Mirrors the row-shape
  /// projection in `allCryptoRegistrations()` — rows whose three provider
  /// columns are all `nil` (e.g. a CSV-imported placeholder that never
  /// went through the picker) project to `nil` here, matching the
  /// `cryptoMapping() != nil` filter on the bulk read.
  ///
  /// Lives in a sibling extension file so the main repository class body
  /// stays under SwiftLint's `type_body_length` and `file_length` budgets.
  func cryptoRegistration(byId id: String) async throws -> CryptoRegistration? {
    try await database.read { database in
      let cryptoKind = Instrument.Kind.cryptoToken.rawValue
      guard
        let row =
          try InstrumentRow
          .filter(InstrumentRow.Columns.id == id)
          .filter(InstrumentRow.Columns.kind == cryptoKind)
          .fetchOne(database)
      else { return nil }
      guard let mapping = row.cryptoMapping() else { return nil }
      let status =
        TokenPricingStatus(rawValue: row.pricingStatus) ?? .priced
      return CryptoRegistration(
        instrument: try row.toDomain(),
        mapping: mapping,
        pricingStatus: status)
    }
  }
}
