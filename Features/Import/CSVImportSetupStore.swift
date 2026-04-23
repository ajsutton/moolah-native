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
  /// Per-column role overrides keyed by header index. `.ignore` means the
  /// column won't be used. See `ColumnRole`.
  var columnRoles: [ColumnRole?] = []

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

  /// The role a column has been assigned by the user or by the detector.
  enum ColumnRole: String, CaseIterable, Identifiable, Sendable {
    case date, description, amount, debit, credit, balance, reference, ignore

    var id: String { rawValue }
    var label: String {
      switch self {
      case .date: return "Date"
      case .description: return "Description"
      case .amount: return "Amount"
      case .debit: return "Debit"
      case .credit: return "Credit"
      case .balance: return "Balance"
      case .reference: return "Reference"
      case .ignore: return "Ignore"
      }
    }
  }

  /// Compose a `ColumnMapping` from the user's current role assignments.
  /// `columnRoles` is seeded from the detected mapping in `regeneratePreview`,
  /// so this function derives the mapping purely from the roles array — a
  /// role set to `.ignore` (or simply left `nil`) means the column is unused,
  /// even if the detector had originally picked it.
  ///
  /// Missing `.date` / `.description` columns resolve to `-1`; the parser's
  /// `safe(row:_:)` helper returns `""` for out-of-bounds indices, which is
  /// the intended "not mapped" behaviour.
  func effectiveMapping() -> GenericBankCSVParser.ColumnMapping? {
    guard let base = detectedMapping else { return nil }
    // If columnRoles hasn't been seeded yet (no regeneratePreview run),
    // ship the detected mapping with the date-format override applied.
    guard columnRoles.count == detectedHeaders.count else {
      var mapping = base
      if let override = dateFormatOverride {
        mapping.dateFormat = override
        mapping.dateFormatAmbiguous = false
      }
      return mapping
    }
    var mapping = base
    mapping.date = columnRoles.firstIndex(of: .date) ?? -1
    mapping.description = columnRoles.firstIndex(of: .description) ?? -1
    mapping.amount = columnRoles.firstIndex(of: .amount)
    mapping.debit = columnRoles.firstIndex(of: .debit)
    mapping.credit = columnRoles.firstIndex(of: .credit)
    mapping.balance = columnRoles.firstIndex(of: .balance)
    mapping.reference = columnRoles.firstIndex(of: .reference)
    if let override = dateFormatOverride {
      mapping.dateFormat = override
      mapping.dateFormatAmbiguous = false
    }
    return mapping
  }

  /// Re-read the preview after a role change.
  func applyColumnRole(_ role: ColumnRole?, forColumn index: Int) async {
    while columnRoles.count < detectedHeaders.count {
      columnRoles.append(nil)
    }
    // Single-value roles (date / description / amount / debit / credit /
    // balance / reference) map to exactly one column — reassigning them
    // clears the previous column. `.ignore` is deliberately excluded from
    // this rule because multiple columns can legitimately be ignored.
    if let role, role != .ignore {
      for otherIndex in columnRoles.indices
      where otherIndex != index && columnRoles[otherIndex] == role {
        columnRoles[otherIndex] = nil
      }
    }
    guard columnRoles.indices.contains(index) else { return }
    columnRoles[index] = role
    await regeneratePreviewCancellable()
  }

  /// Wraps `regeneratePreview()` with cancellation of the previous task
  /// so rapid role / date-format changes don't race. The window of
  /// vulnerability is small (one `await staging.data` hop), but the
  /// concurrency guide explicitly calls for this pattern on stored-state
  /// reloads triggered by UI input.
  private func regeneratePreviewCancellable() async {
    previewTask?.cancel()
    let task = Task { [weak self] in
      guard let self else { return }
      await self.regeneratePreview()
    }
    previewTask = task
    await task.value
  }

  private let backend: any BackendProvider
  private let importStore: ImportStore
  private let staging: ImportStagingStore
  private let registry: CSVParserRegistry
  private let logger = Logger(subsystem: "com.moolah.app", category: "CSVImportSetupStore")
  /// Stored so that rapid-fire role changes cancel the previous preview
  /// regeneration instead of racing with it. `applyColumnRole` fires on
  /// every picker change; without cancellation a slow `staging.data`
  /// read from the old request could stomp the newer one.
  private var previewTask: Task<Void, Never>?

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

  /// Update the date-format override and regenerate the preview in one
  /// atomic step. Called by the view's `onChange` so the mutation and the
  /// async reload stay together inside the store.
  func applyDateFormatOverride(
    _ override: GenericBankCSVParser.DateFormat?
  ) async {
    dateFormatOverride = override
    await regeneratePreviewCancellable()
  }

  /// Parse the staged bytes with the current settings, populate the preview.
  func regeneratePreview() async {
    do {
      let data = try await staging.data(for: pending.id)
      let rows = try CSVTokenizer.parse(data)
      rowCount = max(0, rows.count - 1)
      let headers = rows.first ?? []
      detectedHeaders = headers
      let parser = registry.select(for: headers)
      detectedParserIdentifier = parser.identifier
      if let generic = parser as? GenericBankCSVParser {
        detectedMapping = generic.inferMapping(
          from: headers, sampleRows: Array(rows.dropFirst().prefix(5)))
      } else {
        detectedMapping = nil
      }
      // Seed columnRoles from the detected mapping on first run so the UI
      // picker starts at the detector's choice AND so the mapping can be
      // derived purely from `columnRoles` from here on (a `.ignore` or
      // `nil` entry means the column is unused — the detector's original
      // pick does not "leak through").
      if columnRoles.count != headers.count {
        if let detected = detectedMapping {
          columnRoles = Self.seedColumnRoles(headers: headers, from: detected)
        } else {
          columnRoles = Array(repeating: nil, count: headers.count)
        }
      }
      let records: [ParsedRecord]
      if parser is GenericBankCSVParser, let mapping = effectiveMapping() {
        records = try parseGenericWith(mapping: mapping, rows: rows)
      } else {
        records = try parser.parse(rows: rows)
      }
      preview = Array(
        records.compactMap { rec -> ParsedTransaction? in
          if case .transaction(let transaction) = rec { return transaction } else { return nil }
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

  /// Parse the rows with an explicit mapping. Bypasses the detector so the
  /// user's role assignments take effect immediately in the preview.
  private func parseGenericWith(
    mapping: GenericBankCSVParser.ColumnMapping, rows: [[String]]
  ) throws -> [ParsedRecord] {
    let parser = GenericBankCSVParser()
    return try parser.parse(
      rows: rows, overrideMapping: mapping)
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
    // Generic-bank files MUST have a Date column assigned — otherwise
    // every row throws a date-parse error at ingest time with no obvious
    // remediation. Surface it up-front in the Setup sheet instead.
    if isGenericParser, let mapping = effectiveMapping() {
      if mapping.date < 0 {
        let message = "Assign a Date column before saving."
        saveError = message
        return .failed(message: message)
      }
      if mapping.description < 0 {
        let message = "Assign a Description column before saving."
        saveError = message
        return .failed(message: message)
      }
      if mapping.amount == nil && (mapping.debit == nil || mapping.credit == nil) {
        let message =
          "Assign an Amount column, or both Debit and Credit columns, before saving."
        saveError = message
        return .failed(message: message)
      }
    }
    isSaving = true
    defer { isSaving = false }
    saveError = nil
    let profile = CSVImportProfile(
      accountId: accountId,
      parserIdentifier: detectedParserIdentifier,
      headerSignature: detectedHeaders,
      filenamePattern: filenamePattern.isEmpty ? nil : filenamePattern,
      deleteAfterImport: deleteAfterImport,
      dateFormatRawValue: dateFormatOverride?.rawValue,
      columnRoleRawValues: columnRoleRawValuesForPersistence)
    return await importStore.finishSetup(pendingId: pending.id, profile: profile)
  }

  /// Persist the user's column-role overrides only when they actually
  /// diverge from the detected mapping — otherwise future imports should
  /// continue to benefit from detector improvements on the same
  /// (parser, headers) combination. Checks both "any non-nil role" and
  /// "differs from the detector's seed". Returns `[]` when the detector
  /// seed should win (no override persisted).
  private var columnRoleRawValuesForPersistence: [String?] {
    guard !columnRoles.isEmpty else { return [] }
    guard let detected = detectedMapping else { return [] }
    let seeded = Self.seedColumnRoles(
      headers: detectedHeaders, from: detected)
    // Rows where the user hasn't touched anything match the seed; skip
    // persistence so the profile stays auto-detect where possible.
    if seeded == columnRoles { return [] }
    return columnRoles.map { $0?.rawValue }
  }

  /// Pure seeding logic extracted so `regeneratePreview` and
  /// `columnRoleRawValuesForPersistence` stay in sync. Mirrors whatever
  /// the detector returned from `inferMapping`.
  static func seedColumnRoles(
    headers: [String], from detected: GenericBankCSVParser.ColumnMapping
  ) -> [ColumnRole?] {
    var roles: [ColumnRole?] = Array(repeating: nil, count: headers.count)
    if roles.indices.contains(detected.date) { roles[detected.date] = .date }
    if roles.indices.contains(detected.description) {
      roles[detected.description] = .description
    }
    if let idx = detected.amount, roles.indices.contains(idx) { roles[idx] = .amount }
    if let idx = detected.debit, roles.indices.contains(idx) { roles[idx] = .debit }
    if let idx = detected.credit, roles.indices.contains(idx) { roles[idx] = .credit }
    if let idx = detected.balance, roles.indices.contains(idx) { roles[idx] = .balance }
    if let idx = detected.reference, roles.indices.contains(idx) { roles[idx] = .reference }
    return roles
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
