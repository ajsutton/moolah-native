import Foundation
import SwiftData

@Model
final class CSVImportProfileRecord {

  #Index<CSVImportProfileRecord>([\.id])

  var id: UUID = UUID()
  var accountId: UUID = UUID()
  var parserIdentifier: String = ""
  /// Normalised CSV headers joined by the ASCII unit-separator (U+001F) so
  /// the column fits a single CKRecord `String` field rather than an array.
  /// The separator is chosen because it is never produced by the tokenizer.
  var headerSignature: String = ""
  var filenamePattern: String?
  var deleteAfterImport: Bool = false
  var createdAt: Date = Date()
  var lastUsedAt: Date?
  var encodedSystemFields: Data?

  init(
    id: UUID = UUID(),
    accountId: UUID,
    parserIdentifier: String,
    headerSignature: [String],
    filenamePattern: String? = nil,
    deleteAfterImport: Bool = false,
    createdAt: Date = Date(),
    lastUsedAt: Date? = nil
  ) {
    self.id = id
    self.accountId = accountId
    self.parserIdentifier = parserIdentifier
    self.headerSignature = headerSignature.joined(separator: CSVImportProfileRecord.separator)
    self.filenamePattern = filenamePattern
    self.deleteAfterImport = deleteAfterImport
    self.createdAt = createdAt
    self.lastUsedAt = lastUsedAt
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
      lastUsedAt: lastUsedAt)
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
      lastUsedAt: profile.lastUsedAt)
  }
}
