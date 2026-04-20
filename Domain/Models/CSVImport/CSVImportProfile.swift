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
  var parserIdentifier: String
  var headerSignature: [String]
  var filenamePattern: String?
  var deleteAfterImport: Bool
  let createdAt: Date
  var lastUsedAt: Date?

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
    self.headerSignature = headerSignature.map { Self.normalise($0) }
    self.filenamePattern = filenamePattern
    self.deleteAfterImport = deleteAfterImport
    self.createdAt = createdAt
    self.lastUsedAt = lastUsedAt
  }

  /// Canonical header form: trimmed + lowercased. This is what both the
  /// profile and the fingerprint matcher compare against.
  static func normalise(_ header: String) -> String {
    header.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}
