// Backends/GRDB/Records/ProfileRow.swift

import Foundation
import GRDB

/// One row in the `profile` table — the GRDB-backed counterpart to the
/// SwiftData `@Model` `ProfileRecord`. Lives in `profile-index.sqlite`
/// (an app-scoped DB shared across all profiles), not in any
/// per-profile `data.sqlite`.
///
/// **Naming.** "Row" is the GRDB convention. The SwiftData
/// `ProfileRecord` retains its name until Slice 3 Phase B deletes the
/// `@Model` class entirely.
///
/// **Sync metadata.** `recordName` is the canonical CloudKit recordName
/// (`"ProfileRecord|<uuid>"`, see
/// `Backends/CloudKit/Sync/CKRecordIDRecordName.swift`).
/// `encodedSystemFields` holds the cached CKRecord change-tag blob;
/// these bytes are bit-for-bit copies of what CloudKit returned and
/// are never decoded outside the sync boundary.
struct ProfileRow {
  static let databaseTableName = "profile"

  enum Columns: String, ColumnExpression, CaseIterable {
    case id
    case recordName = "record_name"
    case label
    case currencyCode = "currency_code"
    case financialYearStartMonth = "financial_year_start_month"
    case createdAt = "created_at"
    case encodedSystemFields = "encoded_system_fields"
  }

  enum CodingKeys: String, CodingKey {
    case id
    case recordName = "record_name"
    case label
    case currencyCode = "currency_code"
    case financialYearStartMonth = "financial_year_start_month"
    case createdAt = "created_at"
    case encodedSystemFields = "encoded_system_fields"
  }

  var id: UUID
  var recordName: String
  var label: String
  var currencyCode: String
  var financialYearStartMonth: Int
  var createdAt: Date
  var encodedSystemFields: Data?
}

extension ProfileRow: Codable {}
extension ProfileRow: Sendable {}
extension ProfileRow: Identifiable {}
extension ProfileRow: FetchableRecord {}
extension ProfileRow: PersistableRecord {}
extension ProfileRow: GRDBSystemFieldsStampable {}
