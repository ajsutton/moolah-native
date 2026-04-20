import Foundation
import OSLog
import Observation

/// Thin drives the CSVImportSetupView. Loads the staged bytes, builds a
/// preview, and on Save & Import persists a `CSVImportProfile` and re-enters
/// the pipeline via `ImportStore.finishSetup(pendingId:profile:)`.
///
/// @Observable @MainActor because it binds to a SwiftUI form.
@Observable
@MainActor
final class CSVImportSetupStore {

  /// The pending file this setup form is resolving.
  let pending: PendingSetupFile

  /// Editable fields.
  var targetAccountId: UUID?
  var filenamePattern: String
  var deleteAfterImport: Bool = false
  /// Override date-format detection when the user disagrees.
  var dateFormatOverride: GenericBankCSVParser.DateFormat?

  /// Computed read-only state for the view.
  private(set) var detectedParserIdentifier: String
  private(set) var detectedHeaders: [String]
  private(set) var detectedMapping: GenericBankCSVParser.ColumnMapping?
  private(set) var rowCount: Int = 0
  private(set) var preview: [ParsedTransaction] = []
  private(set) var saveError: String?
  private(set) var isSaving: Bool = false

  /// Is the detected parser the fallback generic one (column-mapping UI shown),
  /// or a source-specific parser (mapping hidden).
  var isGenericParser: Bool { detectedParserIdentifier == "generic-bank" }

  private let backend: any BackendProvider
  private let importStore: ImportStore
  private let staging: ImportStagingStore
  private let registry: CSVParserRegistry
  private let logger = Logger(subsystem: "com.moolah.app", category: "CSVImportSetupStore")

  init(
    pending: PendingSetupFile,
    backend: any BackendProvider,
    importStore: ImportStore,
    staging: ImportStagingStore,
    registry: CSVParserRegistry = .default
  ) {
    self.pending = pending
    self.backend = backend
    self.importStore = importStore
    self.staging = staging
    self.registry = registry
    self.detectedParserIdentifier = pending.detectedParserIdentifier ?? "generic-bank"
    self.detectedHeaders = pending.detectedHeaders
    self.filenamePattern = Self.suggestedFilenamePattern(from: pending.originalFilename)
  }

  /// Parse the staged bytes with the current settings, populate the preview.
  func regeneratePreview() async {
    do {
      let data = try await staging.data(for: pending.id)
      let rows = try CSVTokenizer.parse(data)
      rowCount = max(0, rows.count - 1)
      let parser = registry.select(for: rows.first ?? [])
      detectedParserIdentifier = parser.identifier
      if let generic = parser as? GenericBankCSVParser {
        detectedMapping = generic.inferMapping(
          from: rows.first ?? [], sampleRows: Array(rows.dropFirst().prefix(5)))
      } else {
        detectedMapping = nil
      }
      let records = try parser.parse(rows: rows)
      preview = Array(
        records.compactMap { rec -> ParsedTransaction? in
          if case .transaction(let tx) = rec { return tx } else { return nil }
        }
        .prefix(5)
      )
      saveError = nil
    } catch {
      preview = []
      saveError = error.localizedDescription
      logger.error(
        "Preview failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Build the profile, persist it, and re-enter the pipeline. Returns the
  /// `ImportSessionResult` from `ImportStore.finishSetup`.
  @discardableResult
  func saveAndImport() async -> ImportSessionResult {
    guard let accountId = targetAccountId else {
      let message = "Pick a target account before saving."
      saveError = message
      return .failed(message: message)
    }
    isSaving = true
    defer { isSaving = false }
    saveError = nil
    let profile = CSVImportProfile(
      accountId: accountId,
      parserIdentifier: detectedParserIdentifier,
      headerSignature: detectedHeaders,
      filenamePattern: filenamePattern.isEmpty ? nil : filenamePattern,
      deleteAfterImport: deleteAfterImport)
    return await importStore.finishSetup(pendingId: pending.id, profile: profile)
  }

  /// Leave the pending file where it is; just dismiss the sheet.
  func cancel() {
    saveError = nil
  }

  /// Permanently drop the staged file (user decided they don't want it).
  func deletePending() async {
    await importStore.dismissPending(id: pending.id)
  }

  // MARK: - Helpers

  /// Turn `cba-april-2026.csv` into `cba-*.csv`. The rule: lower-case,
  /// everything up to the first dash stays literal, then `*` then the
  /// extension.
  static func suggestedFilenamePattern(from filename: String) -> String {
    let lower = filename.lowercased()
    let ext = (lower as NSString).pathExtension
    let stem = (lower as NSString).deletingPathExtension
    let components = stem.split(separator: "-", omittingEmptySubsequences: true)
    if components.count >= 2 {
      let head = components[0]
      return ext.isEmpty ? "\(head)-*" : "\(head)-*.\(ext)"
    }
    return ext.isEmpty ? "\(stem)*" : "\(stem)*.\(ext)"
  }
}
