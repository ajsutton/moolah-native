import Foundation

/// A known import source: one registered parser + a canonical set of headers
/// + the Moolah account the rows belong to. On every import, the pipeline
/// looks up existing profiles by `(parserIdentifier, headerSignature)`; if
/// exactly one matches, the file routes silently. Multi-match uses duplicate
/// overlap and filename pattern to disambiguate (see design doc).
///
/// Synced via CloudKit so profiles follow the user across devices.
struct CSVImportProfile: Codable, Sendable, Identifiable, Hashable {
  let id: UUID
  var accountId: UUID
  let parserIdentifier: String
  let headerSignature: [String]
  var filenamePattern: String?
  var deleteAfterImport: Bool
  let createdAt: Date
  var lastUsedAt: Date?
  /// User-confirmed date format for ambiguous generic-bank exports. `nil`
  /// means "auto-detect". Stored as the raw-value string form of
  /// `GenericBankCSVParser.DateFormat` so the domain layer doesn't depend
  /// on Shared/. Format strings follow `DateFormatter` conventions (e.g.
  /// `"dd/MM/yyyy"`, `"MM/dd/yyyy"`, `"yyyy-MM-dd"`).
  var dateFormatRawValue: String?
  /// User-confirmed column role assignments from the Needs Setup form,
  /// positional by header index. An empty array (or an all-nil array)
  /// means "let the detector pick" — matching the runtime behaviour
  /// before this override was added. Each element is a
  /// `ColumnRole.rawValue` (or `nil` to leave the column unassigned /
  /// ignored).
  ///
  /// Domain-layer type: a `[String?]` so we don't force `Domain/` to
  /// depend on `Features/` where the enum lives. See
  /// `CSVImportProfile.columnRoles(for:)` for decoding.
  var columnRoleRawValues: [String?]

  init(
    id: UUID = UUID(),
    accountId: UUID,
    parserIdentifier: String,
    headerSignature: [String],
    filenamePattern: String? = nil,
    deleteAfterImport: Bool = false,
    createdAt: Date = Date(),
    lastUsedAt: Date? = nil,
    dateFormatRawValue: String? = nil,
    columnRoleRawValues: [String?] = []
  ) {
    self.id = id
    self.accountId = accountId
    self.parserIdentifier = parserIdentifier
    self.headerSignature = headerSignature.map { Self.normalise($0) }
    self.filenamePattern = filenamePattern
    self.deleteAfterImport = deleteAfterImport
    self.createdAt = createdAt
    self.lastUsedAt = lastUsedAt
    self.dateFormatRawValue = dateFormatRawValue
    self.columnRoleRawValues = columnRoleRawValues
  }

  /// Canonical header form: trimmed + lowercased. This is what both the
  /// profile and the fingerprint matcher compare against.
  static func normalise(_ header: String) -> String {
    header.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}
