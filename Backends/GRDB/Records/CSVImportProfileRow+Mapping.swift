// Backends/GRDB/Records/CSVImportProfileRow+Mapping.swift

import Foundation

extension CSVImportProfileRow {
  /// The CloudKit recordType on the wire for this record. Frozen contract;
  /// existing iCloud zones reference this exact string regardless of how
  /// the local Swift type is named.
  static let recordType = "CSVImportProfileRecord"

  /// Unit-separator (U+001F). Chosen because the CSV tokenizer never
  /// produces it, so joined-string round trips are loss-free. Mirrors the
  /// `CSVImportProfileRecord.separator` value the SwiftData model used.
  static let separator = "\u{1F}"

  /// Builds the canonical CloudKit `recordName` for a given UUID. The
  /// shape (`"<recordType>|<uuid>"`) must match the existing
  /// `CKRecord.ID(recordType:uuid:zoneID:)` initialiser in
  /// `Backends/CloudKit/Sync/CKRecordIDRecordName.swift` — preserved
  /// byte-for-byte so the migrator can keep the cached system-fields blob
  /// referencing the same CKRecord identity.
  static func recordName(for id: UUID) -> String {
    "\(recordType)|\(id.uuidString)"
  }

  /// Builds a row from a domain object. Pre-existing `recordName` and
  /// `encodedSystemFields` are out of band — created/looked up by the
  /// repository inside its write closure.
  init(domain: CSVImportProfile) {
    self.id = domain.id
    self.recordName = Self.recordName(for: domain.id)
    self.accountId = domain.accountId
    self.parserIdentifier = domain.parserIdentifier
    self.headerSignature = domain.headerSignature.joined(separator: Self.separator)
    self.filenamePattern = domain.filenamePattern
    self.deleteAfterImport = domain.deleteAfterImport
    self.createdAt = domain.createdAt
    self.lastUsedAt = domain.lastUsedAt
    self.dateFormatRawValue = domain.dateFormatRawValue
    self.columnRoleRawValuesEncoded = Self.encodeColumnRoles(domain.columnRoleRawValues)
    self.encodedSystemFields = nil
  }

  /// Splits the joined string fields back into arrays.
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

  /// Joins `[String?]` role list using the same separator as
  /// `headerSignature`. `nil` elements become empty strings so position +
  /// identity round-trip. Returns `nil` for an empty array, matching the
  /// existing CloudKit field-absent semantics.
  static func encodeColumnRoles(_ roles: [String?]) -> String? {
    guard !roles.isEmpty else { return nil }
    return roles.map { $0 ?? "" }.joined(separator: Self.separator)
  }

  /// Inverse of `encodeColumnRoles`. Returns an empty array when the
  /// encoded form is absent / empty (the "no override" sentinel).
  static func decodeColumnRoles(_ encoded: String?) -> [String?] {
    guard let encoded, !encoded.isEmpty else { return [] }
    return encoded.components(separatedBy: Self.separator).map { $0.isEmpty ? nil : $0 }
  }
}
