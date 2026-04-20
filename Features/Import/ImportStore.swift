import Foundation
import OSLog
import Observation

/// Result of a single `ingest` call. `ImportStore.recentSessions` carries
/// the last few for the Recently Added view.
enum ImportSessionResult: Sendable {
  case imported(sessionId: UUID, imported: [Transaction], skippedAsDuplicate: Int)
  case needsSetup(pendingId: UUID)
  case failed(message: String)
}

/// Summary of a recent import session for the UI.
struct ImportSessionSummary: Sendable, Identifiable, Hashable {
  var id: UUID
  var importedCount: Int
  var skippedAsDuplicate: Int
  var importedAt: Date
  var filename: String?
}

/// Errors that can abort a pipeline run before reaching the persist stage.
/// All land in the Failed Files panel; nothing bubbles to the user.
enum IngestError: Error, Sendable {
  case decode(String)
  case parse(CSVParserError)
  case empty
  case other(String)

  var message: String {
    switch self {
    case .decode(let s): return "Could not decode file: \(s)"
    case .parse(let error):
      switch error {
      case .headerMismatch: return "Headers did not match any known parser"
      case .malformedRow(let index, let reason):
        return "Malformed row \(index): \(reason)"
      case .emptyFile: return "File was empty"
      }
    case .empty: return "File had no rows"
    case .other(let s): return s
    }
  }

  var offendingRow: (row: [String]?, index: Int?) {
    if case .parse(let e) = self, case .malformedRow(let index, _) = e {
      return (nil, index)
    }
    return (nil, nil)
  }
}

/// The top-level CSV import orchestrator. One instance per profile.
///
/// `ingest(data:source:)` walks the full pipeline:
///   bytes → tokenize → parser select → parse → profile match
///        → dedup → rule evaluation → persist → update profile + recent
///
/// Failure anywhere before persistence routes the bytes into the staging
/// store (pending for "needs user attention", failed for "can't parse").
/// Per-row persistence failures are logged and the rest continue (spec:
/// no batch rollback).
@Observable
@MainActor
final class ImportStore {

  private(set) var isImporting: Bool = false
  private(set) var pendingSetup: [PendingSetupFile] = []
  private(set) var failedFiles: [FailedImportFile] = []
  /// Session summaries for the Recently Added view, newest first.
  private(set) var recentSessions: [ImportSessionSummary] = []
  private(set) var lastError: String?

  private let backend: any BackendProvider
  private let registry: CSVParserRegistry
  private let staging: ImportStagingStore
  private let fileManager: FileManager
  private let logger = Logger(subsystem: "com.moolah.app", category: "ImportStore")

  init(
    backend: any BackendProvider,
    staging: ImportStagingStore,
    registry: CSVParserRegistry = .default,
    fileManager: FileManager = .default
  ) {
    self.backend = backend
    self.registry = registry
    self.staging = staging
    self.fileManager = fileManager
  }

  // MARK: - Public API

  /// Ingest one file. Updates `recentSessions`, `pendingSetup`, and
  /// `failedFiles` as a side effect. Never throws: every failure path lands
  /// in the staging store.
  @discardableResult
  func ingest(data: Data, source: ImportSource) async -> ImportSessionResult {
    isImporting = true
    defer { isImporting = false }
    lastError = nil
    let sessionId = UUID()
    do {
      let result = try await runPipeline(data: data, source: source, sessionId: sessionId)
      if case .imported(_, let imported, let skipped) = result {
        recentSessions.insert(
          ImportSessionSummary(
            id: sessionId,
            importedCount: imported.count,
            skippedAsDuplicate: skipped,
            importedAt: Date(),
            filename: source.filename),
          at: 0)
      }
      if case .needsSetup = result {
        await reloadStagingLists()
      }
      return result
    } catch let error as IngestError {
      let pendingId = await stageFailed(error: error, source: source, data: data)
      lastError = error.message
      await reloadStagingLists()
      return .failed(message: error.message + " (staged as \(pendingId))")
    } catch {
      let ingest = IngestError.other(error.localizedDescription)
      let pendingId = await stageFailed(error: ingest, source: source, data: data)
      lastError = error.localizedDescription
      await reloadStagingLists()
      return .failed(message: error.localizedDescription + " (staged as \(pendingId))")
    }
  }

  /// Re-fetch pending + failed from staging. Call on view appear.
  func reloadStagingLists() async {
    do {
      pendingSetup = try await staging.pendingFiles()
      failedFiles = try await staging.failedFiles()
    } catch {
      logger.error("Staging reload failed: \(error.localizedDescription)")
    }
  }

  func dismissPending(id: UUID) async {
    do {
      try await staging.dismiss(pendingId: id)
      await reloadStagingLists()
    } catch {
      logger.error("Dismiss pending failed: \(error.localizedDescription)")
    }
  }

  func dismissFailed(id: UUID) async {
    do {
      try await staging.dismiss(failedId: id)
      await reloadStagingLists()
    } catch {
      logger.error("Dismiss failed failed: \(error.localizedDescription)")
    }
  }

  /// Complete a Needs Setup file: caller supplies the profile that will be
  /// created/attached. The bytes are re-read from staging and the pipeline
  /// runs end-to-end with the profile pre-matched.
  @discardableResult
  func finishSetup(pendingId: UUID, profile: CSVImportProfile) async -> ImportSessionResult {
    do {
      let bytes = try await staging.data(for: pendingId)
      _ = try await backend.csvImportProfiles.create(profile)
      try await staging.dismiss(pendingId: pendingId)
      await reloadStagingLists()
      return await ingest(
        data: bytes,
        source: .paste(text: "", label: "setup-\(pendingId.uuidString)"))
    } catch {
      logger.error("finishSetup failed: \(error.localizedDescription)")
      return .failed(message: error.localizedDescription)
    }
  }

  // MARK: - Pipeline

  private func runPipeline(
    data: Data, source: ImportSource, sessionId: UUID
  ) async throws -> ImportSessionResult {

    // 1. Decode + tokenize.
    let rows: [[String]]
    do {
      rows = try CSVTokenizer.parse(data)
    } catch {
      throw IngestError.decode(error.localizedDescription)
    }
    guard let headers = rows.first else { throw IngestError.empty }

    // 2. Select parser + parse.
    let parser = registry.select(for: headers)
    let records: [ParsedRecord]
    do {
      records = try parser.parse(rows: rows)
    } catch let error as CSVParserError {
      throw IngestError.parse(error)
    }
    let candidates = records.compactMap { record -> ParsedTransaction? in
      if case .transaction(let tx) = record { return tx } else { return nil }
    }
    if candidates.isEmpty {
      // Every row skipped (summary-only fixture, empty file) — treat as a
      // successful no-op rather than failing.
      return .imported(sessionId: sessionId, imported: [], skippedAsDuplicate: 0)
    }

    // 3. Profile match (or forced-account override).
    let profile = try await resolveProfile(
      data: data,
      source: source,
      parserIdentifier: parser.identifier,
      headers: headers,
      candidates: candidates)
    let resolvedProfile: CSVImportProfile
    switch profile {
    case .routed(let p):
      resolvedProfile = p
    case .needsSetup(let pendingId):
      return .needsSetup(pendingId: pendingId)
    }

    // 4. Dedup.
    let existingPage = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: resolvedProfile.accountId),
      page: 0, pageSize: 1000)
    let dedup = CSVDeduplicator.filter(
      candidates,
      against: existingPage.transactions,
      accountId: resolvedProfile.accountId)

    // 5. Rules engine + persist.
    let rules = try await backend.importRules.fetchAll()
    let accountInstrument = try await resolveInstrument(
      for: resolvedProfile.accountId)
    var persisted: [Transaction] = []
    for candidate in dedup.kept {
      let evaluation = ImportRulesEngine.evaluate(
        candidate, routedAccountId: resolvedProfile.accountId, rules: rules)
      if evaluation.isSkipped { continue }
      let transaction = buildTransaction(
        from: evaluation,
        routedAccountId: resolvedProfile.accountId,
        accountInstrument: accountInstrument,
        sessionId: sessionId,
        source: source,
        parserIdentifier: parser.identifier)
      do {
        persisted.append(try await backend.transactions.create(transaction))
      } catch {
        logger.error(
          "Create failed for candidate at \(candidate.date): \(error.localizedDescription)")
      }
    }

    // 6. Update profile lastUsedAt (best-effort).
    var updatedProfile = resolvedProfile
    updatedProfile.lastUsedAt = Date()
    _ = try? await backend.csvImportProfiles.update(updatedProfile)

    // 7. Optional delete source.
    if resolvedProfile.deleteAfterImport, let url = source.sourceURL {
      deleteSourceIfPossible(at: url)
    }

    return .imported(
      sessionId: sessionId,
      imported: persisted,
      skippedAsDuplicate: dedup.skipped.count)
  }

  // MARK: - Profile resolution

  private enum ProfileResolution {
    case routed(CSVImportProfile)
    case needsSetup(pendingId: UUID)
  }

  private func resolveProfile(
    data: Data,
    source: ImportSource,
    parserIdentifier: String,
    headers: [String],
    candidates: [ParsedTransaction]
  ) async throws -> ProfileResolution {
    let profiles = try await backend.csvImportProfiles.fetchAll()
    let normalisedHeaders = headers.map { CSVImportProfile.normalise($0) }

    // Forced target via explicit drop: bypass matcher. Create or update a
    // profile on the fly if one doesn't exist.
    if let forcedId = source.forcedAccountId {
      if let match = profiles.first(where: {
        $0.accountId == forcedId && $0.parserIdentifier == parserIdentifier
          && $0.headerSignature == normalisedHeaders
      }) {
        return .routed(match)
      }
      let created = try await backend.csvImportProfiles.create(
        CSVImportProfile(
          accountId: forcedId,
          parserIdentifier: parserIdentifier,
          headerSignature: normalisedHeaders))
      return .routed(created)
    }

    // Build existingByAccountId map for each candidate profile.
    let candidateProfiles = profiles.filter {
      $0.parserIdentifier == parserIdentifier
        && $0.headerSignature == normalisedHeaders
    }
    var existingByAccount: [UUID: [Transaction]] = [:]
    for profile in candidateProfiles {
      let page = try await backend.transactions.fetch(
        filter: TransactionFilter(accountId: profile.accountId),
        page: 0, pageSize: 1000)
      existingByAccount[profile.accountId] = page.transactions
    }
    let matcherInput = MatcherInput(
      filename: source.filename,
      parserIdentifier: parserIdentifier,
      headerSignature: headers,
      candidates: candidates,
      existingByAccountId: existingByAccount,
      profiles: profiles)
    switch CSVImportProfileMatcher.match(matcherInput) {
    case .routed(let profile):
      return .routed(profile)
    case .needsSetup:
      let pendingId = try await stagePending(
        data: data,
        headers: headers,
        parserIdentifier: parserIdentifier,
        filename: source.filename)
      return .needsSetup(pendingId: pendingId)
    }
  }

  // MARK: - Transaction construction

  private func buildTransaction(
    from evaluation: RuleEvaluation,
    routedAccountId: UUID,
    accountInstrument: Instrument,
    sessionId: UUID,
    source: ImportSource,
    parserIdentifier: String
  ) -> Transaction {
    var legs = evaluation.transaction.legs.map { leg -> TransactionLeg in
      let resolvedAccount = leg.accountId ?? routedAccountId
      // Rewrite the placeholder AUD on cash-side legs to match the account's
      // actual instrument. Position legs (non-AUD) are left alone.
      let resolvedInstrument =
        (leg.instrument == .AUD && accountInstrument != .AUD)
        ? accountInstrument : leg.instrument
      return TransactionLeg(
        accountId: resolvedAccount,
        instrument: resolvedInstrument,
        quantity: leg.quantity,
        type: leg.type,
        categoryId: nil,
        earmarkId: nil)
    }

    if let categoryId = evaluation.assignedCategoryId,
      let index = legs.firstIndex(where: { $0.type == .expense })
    {
      legs[index].categoryId = categoryId
    }

    if let toId = evaluation.transferTargetAccountId,
      let cash = legs.first
    {
      legs = [
        TransactionLeg(
          accountId: routedAccountId,
          instrument: cash.instrument,
          quantity: -abs(cash.quantity),
          type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: toId,
          instrument: cash.instrument,
          quantity: abs(cash.quantity),
          type: .transfer,
          categoryId: nil, earmarkId: nil),
      ]
    }

    let origin = ImportOrigin(
      rawDescription: evaluation.transaction.rawDescription,
      bankReference: evaluation.transaction.bankReference,
      rawAmount: evaluation.transaction.rawAmount,
      rawBalance: evaluation.transaction.rawBalance,
      importedAt: Date(),
      importSessionId: sessionId,
      sourceFilename: source.filename,
      parserIdentifier: parserIdentifier)
    return Transaction(
      date: evaluation.transaction.date,
      payee: evaluation.assignedPayee,
      notes: evaluation.appendedNotes,
      legs: legs,
      importOrigin: origin)
  }

  private func resolveInstrument(for accountId: UUID) async throws -> Instrument {
    let accounts = try await backend.accounts.fetchAll()
    return accounts.first(where: { $0.id == accountId })?.instrument ?? .AUD
  }

  // MARK: - Staging helpers

  private func stagePending(
    data: Data,
    headers: [String],
    parserIdentifier: String,
    filename: String?
  ) async throws -> UUID {
    let id = UUID()
    let path = await staging.stagingPath(for: id)
    let file = PendingSetupFile(
      id: id,
      originalFilename: filename ?? "pasted.csv",
      stagingPath: path,
      securityScopedBookmark: nil,
      detectedParserIdentifier: parserIdentifier,
      detectedHeaders: headers.map { CSVImportProfile.normalise($0) },
      parsedAt: Date(),
      sourceBookmark: nil)
    try await staging.stagePending(file, data: data)
    return id
  }

  private func stageFailed(
    error: IngestError, source: ImportSource, data: Data
  ) async -> UUID {
    let id = UUID()
    let path = await staging.stagingPath(for: id)
    let (row, index) = error.offendingRow
    let file = FailedImportFile(
      id: id,
      originalFilename: source.filename ?? "pasted.csv",
      stagingPath: path,
      error: error.message,
      offendingRow: row,
      offendingRowIndex: index,
      parsedAt: Date())
    do {
      try await staging.stageFailed(file, data: data)
    } catch {
      logger.error("Stage failed file failed: \(error.localizedDescription)")
    }
    return id
  }

  private func deleteSourceIfPossible(at url: URL) {
    do {
      try fileManager.removeItem(at: url)
    } catch {
      let description = error.localizedDescription
      logger.warning(
        "Could not delete source file at \(url.path, privacy: .public): \(description, privacy: .public)"
      )
    }
  }
}
