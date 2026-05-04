// Backends/GRDB/Records/AccountRow.swift

import Foundation
import GRDB

/// One row in the `account` table — the GRDB-backed counterpart to the
/// SwiftData `@Model` `AccountRecord`.
///
/// **Instrument resolution.** The row stores `instrumentId: String`,
/// not a full `Instrument`. The repository reconstructs the `Instrument`
/// during `toDomain` using its `InstrumentRegistryRepository` lookup —
/// the registry disambiguates synced stock / crypto IDs from ambient
/// fiat (which has no `instrument` row).
struct AccountRow {
  static let databaseTableName = "account"

  enum Columns: String, ColumnExpression, CaseIterable {
    case id
    case recordName = "record_name"
    case name
    case type
    case instrumentId = "instrument_id"
    case position
    case isHidden = "is_hidden"
    case encodedSystemFields = "encoded_system_fields"
    case valuationMode = "valuation_mode"
  }

  enum CodingKeys: String, CodingKey {
    case id
    case recordName = "record_name"
    case name
    case type
    case instrumentId = "instrument_id"
    case position
    case isHidden = "is_hidden"
    case encodedSystemFields = "encoded_system_fields"
    case valuationMode = "valuation_mode"
  }

  var id: UUID
  var recordName: String
  var name: String
  /// Raw value of `AccountType` (`"bank"`, `"creditCard"`, `"asset"`,
  /// `"investment"`). Pinned by a CHECK constraint.
  var type: String
  var instrumentId: String
  var position: Int
  var isHidden: Bool
  var encodedSystemFields: Data?
  /// Raw value of `ValuationMode` (`"recordedValue"` /
  /// `"calculatedFromTrades"`). Decoded with a `recordedValue` fallback
  /// to tolerate forward-incompatible schema migrations.
  var valuationMode: String
}

extension AccountRow: Codable {}
extension AccountRow: Sendable {}
extension AccountRow: Identifiable {}
extension AccountRow: FetchableRecord {}
extension AccountRow: PersistableRecord {}
extension AccountRow: GRDBSystemFieldsStampable {}
