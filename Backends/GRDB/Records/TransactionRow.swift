// Backends/GRDB/Records/TransactionRow.swift

import Foundation
import GRDB

/// One row in the `"transaction"` table. Carries the denormalised
/// `import_origin_*` columns directly — one column per `ImportOrigin`
/// field rather than a single JSON blob — so the CKRecord wire format
/// stays stable across the codebase.
///
/// `import_origin_kind` discriminates the `TransactionImportOrigin`
/// case: `"single"` projects through the eight existing
/// `import_origin_*` columns; `"merged"` projects the outgoing side
/// through those eight and the incoming side through the eight
/// `import_origin_incoming_*` columns. A null kind is a pre-v12 row
/// and reads as `.single`. `transfer_suggestion_*` carry the optional
/// `TransferSuggestion`; both columns are non-null together or both
/// null.
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
    case importOriginKind = "import_origin_kind"
    case importOriginIncomingRawDescription = "import_origin_incoming_raw_description"
    case importOriginIncomingBankReference = "import_origin_incoming_bank_reference"
    case importOriginIncomingRawAmount = "import_origin_incoming_raw_amount"
    case importOriginIncomingRawBalance = "import_origin_incoming_raw_balance"
    case importOriginIncomingImportedAt = "import_origin_incoming_imported_at"
    case importOriginIncomingImportSessionId = "import_origin_incoming_import_session_id"
    case importOriginIncomingSourceFilename = "import_origin_incoming_source_filename"
    case importOriginIncomingParserIdentifier = "import_origin_incoming_parser_identifier"
    case transferSuggestionCounterpartId = "transfer_suggestion_counterpart_id"
    case transferSuggestionSuggestedAt = "transfer_suggestion_suggested_at"
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
    case importOriginKind = "import_origin_kind"
    case importOriginIncomingRawDescription = "import_origin_incoming_raw_description"
    case importOriginIncomingBankReference = "import_origin_incoming_bank_reference"
    case importOriginIncomingRawAmount = "import_origin_incoming_raw_amount"
    case importOriginIncomingRawBalance = "import_origin_incoming_raw_balance"
    case importOriginIncomingImportedAt = "import_origin_incoming_imported_at"
    case importOriginIncomingImportSessionId = "import_origin_incoming_import_session_id"
    case importOriginIncomingSourceFilename = "import_origin_incoming_source_filename"
    case importOriginIncomingParserIdentifier = "import_origin_incoming_parser_identifier"
    case transferSuggestionCounterpartId = "transfer_suggestion_counterpart_id"
    case transferSuggestionSuggestedAt = "transfer_suggestion_suggested_at"
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
  // ImportOrigin denormalised — each field is nullable to match the
  // domain `ImportOrigin` shape. Decimals stored as String to preserve
  // precision across the database ↔ CloudKit ↔ Domain round-trip.
  var importOriginRawDescription: String?
  var importOriginBankReference: String?
  var importOriginRawAmount: String?
  var importOriginRawBalance: String?
  var importOriginImportedAt: Date?
  var importOriginImportSessionId: UUID?
  var importOriginSourceFilename: String?
  var importOriginParserIdentifier: String?
  /// `TransactionImportOrigin` case discriminator: `"single"`,
  /// `"merged"`, or null for a pre-v12 row (which reads as `.single`).
  var importOriginKind: String?
  // Incoming side of a `.merged` origin. Mirrors the eight columns
  // above field-for-field; all null when the origin is `.single` or
  // absent.
  var importOriginIncomingRawDescription: String?
  var importOriginIncomingBankReference: String?
  var importOriginIncomingRawAmount: String?
  var importOriginIncomingRawBalance: String?
  var importOriginIncomingImportedAt: Date?
  var importOriginIncomingImportSessionId: UUID?
  var importOriginIncomingSourceFilename: String?
  var importOriginIncomingParserIdentifier: String?
  // TransferSuggestion denormalised. Both columns are non-null
  // together or both null; one populated and one null reads as no
  // suggestion.
  var transferSuggestionCounterpartId: UUID?
  var transferSuggestionSuggestedAt: Date?
  var encodedSystemFields: Data?

  // Explicit memberwise initializer. The transfer-detection columns
  // default to nil so call sites that predate them — and the
  // CloudKit field projection, which does not carry them — construct
  // a row without naming every column.
  init(
    id: UUID,
    recordName: String,
    date: Date,
    payee: String? = nil,
    notes: String? = nil,
    recurPeriod: String? = nil,
    recurEvery: Int? = nil,
    importOriginRawDescription: String? = nil,
    importOriginBankReference: String? = nil,
    importOriginRawAmount: String? = nil,
    importOriginRawBalance: String? = nil,
    importOriginImportedAt: Date? = nil,
    importOriginImportSessionId: UUID? = nil,
    importOriginSourceFilename: String? = nil,
    importOriginParserIdentifier: String? = nil,
    importOriginKind: String? = nil,
    importOriginIncomingRawDescription: String? = nil,
    importOriginIncomingBankReference: String? = nil,
    importOriginIncomingRawAmount: String? = nil,
    importOriginIncomingRawBalance: String? = nil,
    importOriginIncomingImportedAt: Date? = nil,
    importOriginIncomingImportSessionId: UUID? = nil,
    importOriginIncomingSourceFilename: String? = nil,
    importOriginIncomingParserIdentifier: String? = nil,
    transferSuggestionCounterpartId: UUID? = nil,
    transferSuggestionSuggestedAt: Date? = nil,
    encodedSystemFields: Data? = nil
  ) {
    self.id = id
    self.recordName = recordName
    self.date = date
    self.payee = payee
    self.notes = notes
    self.recurPeriod = recurPeriod
    self.recurEvery = recurEvery
    self.importOriginRawDescription = importOriginRawDescription
    self.importOriginBankReference = importOriginBankReference
    self.importOriginRawAmount = importOriginRawAmount
    self.importOriginRawBalance = importOriginRawBalance
    self.importOriginImportedAt = importOriginImportedAt
    self.importOriginImportSessionId = importOriginImportSessionId
    self.importOriginSourceFilename = importOriginSourceFilename
    self.importOriginParserIdentifier = importOriginParserIdentifier
    self.importOriginKind = importOriginKind
    self.importOriginIncomingRawDescription = importOriginIncomingRawDescription
    self.importOriginIncomingBankReference = importOriginIncomingBankReference
    self.importOriginIncomingRawAmount = importOriginIncomingRawAmount
    self.importOriginIncomingRawBalance = importOriginIncomingRawBalance
    self.importOriginIncomingImportedAt = importOriginIncomingImportedAt
    self.importOriginIncomingImportSessionId = importOriginIncomingImportSessionId
    self.importOriginIncomingSourceFilename = importOriginIncomingSourceFilename
    self.importOriginIncomingParserIdentifier = importOriginIncomingParserIdentifier
    self.transferSuggestionCounterpartId = transferSuggestionCounterpartId
    self.transferSuggestionSuggestedAt = transferSuggestionSuggestedAt
    self.encodedSystemFields = encodedSystemFields
  }
}

extension TransactionRow: Codable {}
extension TransactionRow: Sendable {}
extension TransactionRow: Identifiable {}
extension TransactionRow: FetchableRecord {}
extension TransactionRow: PersistableRecord {}
extension TransactionRow: GRDBSystemFieldsStampable {}
