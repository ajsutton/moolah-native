// Backends/GRDB/Records/EarmarkRow.swift

import Foundation
import GRDB

/// One row in the `earmark` table — the GRDB-backed counterpart to the
/// SwiftData `@Model` `EarmarkRecord`.
///
/// **Legacy `savingsTargetInstrumentId`.** The SwiftData model carried a
/// `savingsTargetInstrumentId` column for backwards compatibility with
/// older records that stored the savings goal in a different instrument
/// than the earmark itself. The GRDB row preserves the column so a
/// migrator round-trip is byte-identical, but `toDomain()` always
/// labels the goal in the earmark's own `instrumentId` (matches the
/// existing `EarmarkRecord.toDomain` policy at lines 53–56).
struct EarmarkRow {
  static let databaseTableName = "earmark"

  enum Columns: String, ColumnExpression, CaseIterable {
    case id
    case recordName = "record_name"
    case name
    case position
    case isHidden = "is_hidden"
    case instrumentId = "instrument_id"
    case savingsTarget = "savings_target"
    case savingsTargetInstrumentId = "savings_target_instrument_id"
    case savingsStartDate = "savings_start_date"
    case savingsEndDate = "savings_end_date"
    case encodedSystemFields = "encoded_system_fields"
  }

  enum CodingKeys: String, CodingKey {
    case id
    case recordName = "record_name"
    case name
    case position
    case isHidden = "is_hidden"
    case instrumentId = "instrument_id"
    case savingsTarget = "savings_target"
    case savingsTargetInstrumentId = "savings_target_instrument_id"
    case savingsStartDate = "savings_start_date"
    case savingsEndDate = "savings_end_date"
    case encodedSystemFields = "encoded_system_fields"
  }

  var id: UUID
  var recordName: String
  var name: String
  var position: Int
  var isHidden: Bool
  /// Optional to match SwiftData's nullable column. Domain
  /// reconstruction defaults to `defaultInstrument` when nil.
  var instrumentId: String?
  /// `Decimal × 10^8` storage form (the existing SwiftData convention).
  var savingsTarget: Int64?
  /// Legacy column. `toDomain` ignores this and always labels the goal
  /// in the earmark's own `instrumentId` (mirrors `EarmarkRecord` at
  /// lines 53–56).
  var savingsTargetInstrumentId: String?
  var savingsStartDate: Date?
  var savingsEndDate: Date?
  var encodedSystemFields: Data?
}

extension EarmarkRow: Codable {}
extension EarmarkRow: Sendable {}
extension EarmarkRow: Identifiable {}
extension EarmarkRow: FetchableRecord {}
extension EarmarkRow: PersistableRecord {}
extension EarmarkRow: GRDBSystemFieldsStampable {}
