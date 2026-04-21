import Foundation
import SwiftData

@Model
final class CSVImportProfileRecord {

  #Index<CSVImportProfileRecord>([\.id])

  var id = UUID()
  var accountId = UUID()
  var parserIdentifier: String = ""
  /// Normalised CSV headers joined by the ASCII unit-separator (U+001F) so
  /// the column fits a single CKRecord `String` field rather than an array.
  /// The separator is chosen because it is never produced by the tokenizer.
  var headerSignature: String = ""
  var filenamePattern: String?
  var deleteAfterImport: Bool = false
  var createdAt = Date()
  var lastUsedAt: Date?
  /// Persisted user-confirmed date format (see CSVImportProfile).
  var dateFormatRawValue: String?
  /// Positional column-role overrides serialised as the same unit-separator
  /// joined form as `headerSignature`. `nil` element becomes the empty
  /// string; a completely-nil serialisation ("\u{1F}\u{1F}…") survives
  /// round-tripping. Stored as a single `String?` so the CKRecord stays a
  /// flat dictionary of scalars.
  var columnRoleRawValuesEncoded: String?
  var encodedSystemFields: Data?

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
    columnRoleRawValuesEncoded: String? = nil
  ) {
    self.id = id
    self.accountId = accountId
    self.parserIdentifier = parserIdentifier
    self.headerSignature = headerSignature.joined(separator: CSVImportProfileRecord.separator)
    self.filenamePattern = filenamePattern
    self.deleteAfterImport = deleteAfterImport
    self.createdAt = createdAt
    self.lastUsedAt = lastUsedAt
    self.dateFormatRawValue = dateFormatRawValue
    self.columnRoleRawValuesEncoded = columnRoleRawValuesEncoded
  }

  /// Unit-separator (U+001F). Chosen because the CSV tokenizer never produces
  /// this character, so the round-trip is loss-free.
  static let separator = "\u{1F}"

  func toDomain() -> CSVImportProfile {
    CSVImportProfile(
      id: id,
      accountId: accountId,
      parserIdentifier: parserIdentifier,
      headerSignature: headerSignature.isEmpty
        ? []
        : headerSignature.components(separatedBy: Self.separator),
      filenamePattern: filenamePattern,
      deleteAfterImport: deleteAfterImport,
      createdAt: createdAt,
      lastUsedAt: lastUsedAt,
      dateFormatRawValue: dateFormatRawValue,
      columnRoleRawValues: Self.decodeColumnRoles(columnRoleRawValuesEncoded))
  }

  static func from(_ profile: CSVImportProfile) -> CSVImportProfileRecord {
    CSVImportProfileRecord(
      id: profile.id,
      accountId: profile.accountId,
      parserIdentifier: profile.parserIdentifier,
      headerSignature: profile.headerSignature,
      filenamePattern: profile.filenamePattern,
      deleteAfterImport: profile.deleteAfterImport,
      createdAt: profile.createdAt,
      lastUsedAt: profile.lastUsedAt,
      dateFormatRawValue: profile.dateFormatRawValue,
      columnRoleRawValuesEncoded: Self.encodeColumnRoles(profile.columnRoleRawValues))
  }

  /// Join the `[String?]` role list into a single String using the same
  /// unit-separator as `headerSignature`. `nil` elements become empty
  /// strings; round-tripping preserves position + identity.
  static func encodeColumnRoles(_ roles: [String?]?) -> String? {
    guard let roles else { return nil }
    return roles.map { $0 ?? "" }.joined(separator: Self.separator)
  }

  static func decodeColumnRoles(_ encoded: String?) -> [String?]? {
    guard let encoded, !encoded.isEmpty else { return nil }
    return encoded.components(separatedBy: Self.separator).map { $0.isEmpty ? nil : $0 }
  }
}
