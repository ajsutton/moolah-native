// Backends/GRDB/Records/ImportRuleRow.swift

import Foundation
import GRDB

/// One row in the `import_rule` table — the GRDB-backed counterpart to
/// the SwiftData `@Model` `ImportRuleRecord`.
///
/// Naming follows the convention documented on `CSVImportProfileRow`:
/// `*Row` is the GRDB type, `*Record` is the SwiftData (`@Model`) type
/// kept around so the one-shot SwiftData → GRDB migrator can read existing
/// rows on first launch.
///
/// `conditions_json` and `actions_json` are stored as `BLOB` containing
/// the JSON encodings of `[RuleCondition]` and `[RuleAction]`. The
/// encoder used must match the SwiftData layer byte-for-byte (default
/// `JSONEncoder()` with no `outputFormatting` /
/// `keyEncodingStrategy` / `dateEncodingStrategy` overrides) so the
/// CKRecord wire bytes stay stable across the migration — see
/// `Backends/GRDB/Records/ImportRuleRow+Mapping.swift`.
struct ImportRuleRow {
  static let databaseTableName = "import_rule"

  enum Columns: String, ColumnExpression, CaseIterable {
    case id
    case recordName = "record_name"
    case name
    case enabled
    case position
    case matchMode = "match_mode"
    case conditionsJSON = "conditions_json"
    case actionsJSON = "actions_json"
    case accountScope = "account_scope"
    case encodedSystemFields = "encoded_system_fields"
  }

  enum CodingKeys: String, CodingKey {
    case id
    case recordName = "record_name"
    case name
    case enabled
    case position
    case matchMode = "match_mode"
    case conditionsJSON = "conditions_json"
    case actionsJSON = "actions_json"
    case accountScope = "account_scope"
    case encodedSystemFields = "encoded_system_fields"
  }

  var id: UUID
  var recordName: String
  var name: String
  var enabled: Bool
  var position: Int
  /// Raw value of `MatchMode` (`"any"` / `"all"`). Domain-layer enum
  /// lookup happens during mapping back to `ImportRule`.
  var matchMode: String
  /// JSON-encoded `[RuleCondition]`. Stored as BLOB so the bytes round
  /// trip exactly even if SQLite's text-affinity normalisation kicks in
  /// somewhere upstream.
  var conditionsJSON: Data
  /// JSON-encoded `[RuleAction]`.
  var actionsJSON: Data
  /// `nil` for global rules; otherwise the account this rule scopes to.
  var accountScope: UUID?
  var encodedSystemFields: Data?
}

extension ImportRuleRow: Codable {}
extension ImportRuleRow: Sendable {}
extension ImportRuleRow: Identifiable {}
extension ImportRuleRow: FetchableRecord {}
extension ImportRuleRow: PersistableRecord {}
extension ImportRuleRow: GRDBSystemFieldsStampable {}
