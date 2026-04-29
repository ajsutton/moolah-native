// Backends/GRDB/Records/TransactionRow.swift

import Foundation
import GRDB

/// One row in the `"transaction"` table — the GRDB-backed counterpart
/// to the SwiftData `@Model` `TransactionRecord`. Mirrors the SwiftData
/// shape field-for-field including the eight denormalised
/// `import_origin_*` columns. Using one column per `ImportOrigin`
/// field (rather than a single JSON blob) keeps the CKRecord wire
/// format byte-identical.
struct TransactionRow {
  static let databaseTableName = "transaction"

  enum Columns: String, ColumnExpression, CaseIterable {
    case id
    case recordName = "record_name"
    case date
    case payee
    case notes
    case recurPeriod = "recur_period"
    case recurEvery = "recur_every"
    case importOriginRawDescription = "import_origin_raw_description"
    case importOriginBankReference = "import_origin_bank_reference"
    case importOriginRawAmount = "import_origin_raw_amount"
    case importOriginRawBalance = "import_origin_raw_balance"
    case importOriginImportedAt = "import_origin_imported_at"
    case importOriginImportSessionId = "import_origin_import_session_id"
    case importOriginSourceFilename = "import_origin_source_filename"
    case importOriginParserIdentifier = "import_origin_parser_identifier"
    case encodedSystemFields = "encoded_system_fields"
  }

  enum CodingKeys: String, CodingKey {
    case id
    case recordName = "record_name"
    case date
    case payee
    case notes
    case recurPeriod = "recur_period"
    case recurEvery = "recur_every"
    case importOriginRawDescription = "import_origin_raw_description"
    case importOriginBankReference = "import_origin_bank_reference"
    case importOriginRawAmount = "import_origin_raw_amount"
    case importOriginRawBalance = "import_origin_raw_balance"
    case importOriginImportedAt = "import_origin_imported_at"
    case importOriginImportSessionId = "import_origin_import_session_id"
    case importOriginSourceFilename = "import_origin_source_filename"
    case importOriginParserIdentifier = "import_origin_parser_identifier"
    case encodedSystemFields = "encoded_system_fields"
  }

  var id: UUID
  var recordName: String
  var date: Date
  var payee: String?
  var notes: String?
  /// Raw value of `RecurPeriod`. Pinned by a CHECK constraint.
  var recurPeriod: String?
  var recurEvery: Int?
  // ImportOrigin denormalised — preserve nullability per
  // `TransactionRecord.swift:53–90`. Decimals stored as String to
  // preserve precision across the SwiftData ↔ CloudKit ↔ Domain
  // round-trip; mirror that here.
  var importOriginRawDescription: String?
  var importOriginBankReference: String?
  var importOriginRawAmount: String?
  var importOriginRawBalance: String?
  var importOriginImportedAt: Date?
  var importOriginImportSessionId: UUID?
  var importOriginSourceFilename: String?
  var importOriginParserIdentifier: String?
  var encodedSystemFields: Data?
}

extension TransactionRow: Codable {}
extension TransactionRow: Sendable {}
extension TransactionRow: Identifiable {}
extension TransactionRow: FetchableRecord {}
extension TransactionRow: PersistableRecord {}
