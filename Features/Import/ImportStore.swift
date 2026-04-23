// swiftlint:disable multiline_arguments

import Foundation
import OSLog
import Observation
import os

private let importStoreBackgroundLogger = Logger(
  subsystem: "com.moolah.app", category: "ImportStore.Background")

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
    case .decode(let detail): return "Could not decode file: \(detail)"
    case .parse(let error):
      switch error {
      case .headerMismatch: return "Headers did not match any known parser"
      case .malformedRow(let index, let reason, _):
        return "Malformed row \(index): \(reason)"
      case .emptyFile: return "File was empty"
      }
    case .empty: return "File had no rows"
    case .other(let detail): return detail
    }
  }

  var offendingRow: (row: [String]?, index: Int?) {
    if case .parse(let parserError) = self,
      case .malformedRow(let index, _, let row) = parserError
    {
      return (row, index)
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
  /// Count of recently-imported transactions with no category assigned.
  /// Drives the sidebar badge on Recently Added. Refreshed at app launch
  /// and after every successful ingest.
  private(set) var unreviewedBadgeCount: Int = 0
  private(set) var lastError: String?

  private let backend: any BackendProvider
  private let registry: CSVParserRegistry
  /// Exposed so the Needs Setup sheet can re-read staged bytes via its own
  /// `CSVImportSetupStore`. Mutations still flow through the `ImportStore`
  /// public API; external callers should only read.
  let staging: ImportStagingStore
  /// Optional resolver for the folder-watch "delete after import" default.
  /// `ProfileSession` wires this to `ImportPreferences.deleteAfterImportFolderDefault`
  /// so `.folderWatch` ingests honour the setting even when the matched
  /// profile's own `deleteAfterImport` is false.
  var folderWatchDeleteAfterImport: (@MainActor () -> Bool)?
  private let logger = Logger(subsystem: "com.moolah.app", category: "ImportStore")

  init(
    backend: any BackendProvider,
    staging: ImportStagingStore,
    registry: CSVParserRegistry = .default
  ) {
    self.backend = backend
    self.registry = registry
    self.staging = staging
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
        await refreshBadge()
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

  /// Refresh the sidebar badge count (transactions imported in the last
  /// 24 hours whose legs are all uncategorised). Call at app launch, on
  /// scene-foreground, and after each successful ingest.
  func refreshBadge(now: Date = Date()) async {
    do {
      let page = try await backend.transactions.fetch(
        filter: TransactionFilter(), page: 0, pageSize: 500)
      let windowStart = now.addingTimeInterval(-86_400)
      unreviewedBadgeCount =
        page.transactions.filter { transaction in
          guard let origin = transaction.importOrigin else { return false }
          guard origin.importedAt >= windowStart && origin.importedAt <= now else {
            return false
          }
          return transaction.legs.allSatisfy { $0.categoryId == nil }
        }.count
    } catch {
      logger.error(
        "refreshBadge failed: \(error.localizedDescription, privacy: .public)")
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

  /// Retry a previously-failed file: re-read the staged bytes, drop the
  /// failed record, and send the bytes back through `ingest`. Works for
  /// any file we staged (picker, drop, paste, folder-watch) because we
  /// use the on-disk copy, not the original URL.
  @discardableResult
  func retryFailed(id: UUID) async -> ImportSessionResult {
    do {
      guard let record = try await staging.failedFiles().first(where: { $0.id == id })
      else {
        return .failed(message: "Failed file not found")
      }
      let bytes = try await staging.data(forFailedId: id)
      try await staging.dismiss(failedId: id)
      await reloadStagingLists()
      return await ingest(
        data: bytes,
        source: .reingestFromSetup(
          filename: record.originalFilename, sourceURL: nil))
    } catch {
      logger.error("retryFailed failed: \(error.localizedDescription)")
      return .failed(message: error.localizedDescription)
    }
  }

  /// Complete a Needs Setup file: caller supplies the profile that will be
  /// created/attached. The bytes are re-read from staging and the pipeline
  /// runs end-to-end with the profile pre-matched.
  @discardableResult
  func finishSetup(pendingId: UUID, profile: CSVImportProfile) async -> ImportSessionResult {
    do {
      let pendingRecord = try await staging.pendingFiles().first {
        $0.id == pendingId
      }
      let originalFilename = pendingRecord?.originalFilename ?? "setup-\(pendingId.uuidString)"
      // Resolve the source bookmark (if any) so delete-after-import still
      // works on the file the user originally picked.
      let bookmark = pendingRecord?.sourceBookmark
      let sourceURL: URL? = {
        guard let bookmark else { return nil }
        var isStale = false
        #if os(macOS)
          let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
          let options: URL.BookmarkResolutionOptions = []
        #endif
        return try? URL(
          resolvingBookmarkData: bookmark,
          options: options,
          relativeTo: nil,
          bookmarkDataIsStale: &isStale)
      }()
      let bytes = try await staging.data(for: pendingId)
      _ = try await backend.csvImportProfiles.create(profile)
      try await staging.dismiss(pendingId: pendingId)
      await reloadStagingLists()
      return await ingest(
        data: bytes,
        source: .reingestFromSetup(
          filename: originalFilename, sourceURL: sourceURL))
    } catch {
      logger.error("finishSetup failed: \(error.localizedDescription)")
      return .failed(message: error.localizedDescription)
    }
  }

  // MARK: - Pipeline

  private func runPipeline(
    data: Data, source: ImportSource, sessionId: UUID
  ) async throws -> ImportSessionResult {
    let pipelineSignpost = OSSignpostID(log: Signposts.importPipeline)
    os_signpost(
      .begin, log: Signposts.importPipeline, name: "ingest", signpostID: pipelineSignpost)
    defer {
      os_signpost(
        .end, log: Signposts.importPipeline, name: "ingest", signpostID: pipelineSignpost)
    }

    // 1. Decode + tokenize.
    let rows = try tokenize(data)
    guard let headers = rows.first else { throw IngestError.empty }

    // 2. Select parser + candidates.
    let parsing = try await selectAndParse(rows: rows, headers: headers, source: source)
    let candidates = parsing.candidates
    if candidates.isEmpty {
      // Every row skipped (summary-only fixture, empty file) — treat as a
      // successful no-op rather than failing.
      return .imported(sessionId: sessionId, imported: [], skippedAsDuplicate: 0)
    }

    // 3. Profile match (or forced-account override).
    let profile = try await resolveProfile(
      data: data,
      source: source,
      parserIdentifier: parsing.parser.identifier,
      headers: headers,
      candidates: candidates)
    let resolvedProfile: CSVImportProfile
    switch profile {
    case .routed(let routedProfile):
      resolvedProfile = routedProfile
    case .needsSetup(let pendingId):
      return .needsSetup(pendingId: pendingId)
    }

    // 4. Dedup + 5. Rules + persist.
    let dedup = try await runDedup(candidates: candidates, accountId: resolvedProfile.accountId)
    let persisted = try await persistCandidates(
      dedup: dedup,
      resolvedProfile: resolvedProfile,
      sessionId: sessionId,
      source: source,
      parserIdentifier: parsing.parser.identifier)

    // 6. Update profile lastUsedAt (best-effort — log on failure rather
    // than silently swallow so a backend hiccup isn't invisible).
    await touchProfileLastUsedAt(resolvedProfile)

    // 7. Optional delete source. Honour either the profile-level flag or
    // (for folder-watched files) the folder-level default.
    let folderDefaultDelete: Bool = {
      if case .folderWatch = source {
        return folderWatchDeleteAfterImport?() ?? false
      }
      return false
    }()
    if resolvedProfile.deleteAfterImport || folderDefaultDelete,
      let url = source.sourceURL
    {
      await Self.deleteSourceInBackground(at: url)
    }

    return .imported(
      sessionId: sessionId,
      imported: persisted,
      skippedAsDuplicate: dedup.skipped.count)
  }

  private func tokenize(_ data: Data) throws -> [[String]] {
    let tokenizeSignpost = OSSignpostID(log: Signposts.importPipeline)
    os_signpost(
      .begin, log: Signposts.importPipeline, name: "tokenize",
      signpostID: tokenizeSignpost)
    defer {
      os_signpost(
        .end, log: Signposts.importPipeline, name: "tokenize",
        signpostID: tokenizeSignpost)
    }
    do {
      return try CSVTokenizer.parse(data)
    } catch {
      throw IngestError.decode(error.localizedDescription)
    }
  }

  private struct ParseOutcome {
    let parser: any CSVParser
    let candidates: [ParsedTransaction]
  }

  /// Selects a parser via `registry.select` + pre-existing profile lookup
  /// (so saved `dateFormatRawValue` and column-role overrides are threaded
  /// into the parser), runs the parse, and projects parsed records down to
  /// transaction candidates.
  private func selectAndParse(
    rows: [[String]], headers: [String], source: ImportSource
  ) async throws -> ParseOutcome {
    let parser = registry.select(for: headers)
    let profileForOverride = try? await preExistingProfile(
      parserIdentifier: parser.identifier, headers: headers,
      forcedAccountId: source.forcedAccountId)
    let dateFormatOverride = profileForOverride?.dateFormatRawValue
      .flatMap(GenericBankCSVParser.DateFormat.fromRawValue)

    // Column-role override: if the profile stored a user-edited column
    // mapping, rebuild the ColumnMapping from it and pass as an explicit
    // `overrideMapping` so the parser doesn't re-auto-detect. Without
    // this, the user's first-time setup choice would be ignored on every
    // subsequent import with the same header signature.
    let columnMappingOverride = profileForOverride?.columnRoleRawValues.flatMap {
      Self.buildColumnMapping(
        headers: headers,
        columnRoleRawValues: $0,
        sampleRows: Array(rows.dropFirst().prefix(5)),
        dateFormatOverride: dateFormatOverride)
    }

    let records = try runParse(
      parser: parser, rows: rows,
      columnMappingOverride: columnMappingOverride,
      dateFormatOverride: dateFormatOverride)
    let candidates = records.compactMap { record -> ParsedTransaction? in
      if case .transaction(let transaction) = record {
        return transaction
      } else {
        return nil
      }
    }
    return ParseOutcome(parser: parser, candidates: candidates)
  }

  private func runParse(
    parser: any CSVParser,
    rows: [[String]],
    columnMappingOverride: GenericBankCSVParser.ColumnMapping?,
    dateFormatOverride: GenericBankCSVParser.DateFormat?
  ) throws -> [ParsedRecord] {
    let parseSignpost = OSSignpostID(log: Signposts.importPipeline)
    os_signpost(
      .begin, log: Signposts.importPipeline, name: "parse", signpostID: parseSignpost)
    defer {
      os_signpost(
        .end, log: Signposts.importPipeline, name: "parse", signpostID: parseSignpost)
    }
    do {
      if let genericParser = parser as? GenericBankCSVParser {
        if let mapping = columnMappingOverride {
          return try genericParser.parse(rows: rows, overrideMapping: mapping)
        }
        return try genericParser.parse(rows: rows, overrideDateFormat: dateFormatOverride)
      }
      return try parser.parse(rows: rows)
    } catch let error as CSVParserError {
      throw IngestError.parse(error)
    }
  }

  private func runDedup(
    candidates: [ParsedTransaction], accountId: UUID
  ) async throws -> CSVDedupResult {
    let dedupSignpost = OSSignpostID(log: Signposts.importPipeline)
    os_signpost(
      .begin, log: Signposts.importPipeline, name: "dedup", signpostID: dedupSignpost)
    defer {
      os_signpost(
        .end, log: Signposts.importPipeline, name: "dedup", signpostID: dedupSignpost)
    }
    let existingPage = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId),
      page: 0, pageSize: 1000)
    return CSVDeduplicator.filter(
      candidates,
      against: existingPage.transactions,
      accountId: accountId)
  }

  /// Evaluate import rules against each surviving candidate and persist
  /// the resulting transactions. Fetches every account once and builds a
  /// `{ id → instrument }` map so `buildTransaction` can stamp each leg
  /// with its own account's instrument — in particular the destination
  /// leg of a `.markAsTransfer` rule, which may target an account in a
  /// different instrument than the source (Rule 11a — never write a leg
  /// with the wrong instrument).
  private func persistCandidates(
    dedup: CSVDedupResult,
    resolvedProfile: CSVImportProfile,
    sessionId: UUID,
    source: ImportSource,
    parserIdentifier: String
  ) async throws -> [Transaction] {
    let rulesSignpost = OSSignpostID(log: Signposts.importPipeline)
    os_signpost(
      .begin, log: Signposts.importPipeline, name: "rules", signpostID: rulesSignpost)
    defer {
      os_signpost(
        .end, log: Signposts.importPipeline, name: "rules", signpostID: rulesSignpost)
    }
    let rules = try await backend.importRules.fetchAll()
    let allAccounts = try await backend.accounts.fetchAll()
    let accountInstruments: [UUID: Instrument] = Dictionary(
      uniqueKeysWithValues: allAccounts.map { ($0.id, $0.instrument) })
    guard let routedInstrument = accountInstruments[resolvedProfile.accountId] else {
      throw IngestError.other(
        "Account \(resolvedProfile.accountId) not found; cannot resolve its instrument.")
    }

    var persisted: [Transaction] = []
    for candidate in dedup.kept {
      let evaluation = ImportRulesEngine.evaluate(
        candidate, routedAccountId: resolvedProfile.accountId, rules: rules)
      if evaluation.isSkipped { continue }
      let transaction = buildTransaction(
        from: evaluation,
        routedAccountId: resolvedProfile.accountId,
        accountInstrument: routedInstrument,
        accountInstruments: accountInstruments,
        sessionId: sessionId,
        source: source,
        parserIdentifier: parserIdentifier)
      do {
        persisted.append(try await backend.transactions.create(transaction))
      } catch {
        logger.error(
          "Create failed for candidate at \(candidate.date): \(error.localizedDescription)")
      }
    }
    return persisted
  }

  private func touchProfileLastUsedAt(_ resolvedProfile: CSVImportProfile) async {
    var updatedProfile = resolvedProfile
    updatedProfile.lastUsedAt = Date()
    do {
      _ = try await backend.csvImportProfiles.update(updatedProfile)
    } catch {
      logger.warning(
        "Profile lastUsedAt update failed (non-critical): \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  // MARK: - Profile resolution

  private enum ProfileResolution {
    case routed(CSVImportProfile)
    case needsSetup(pendingId: UUID)
  }

  /// Cheap lookup used to pre-fetch a profile before parsing, so parser
  /// overrides like `dateFormatRawValue` can be threaded into the parse
  /// step. Returns nil when zero / multiple profiles match — the pipeline
  /// then falls back to auto-detect.
  private func preExistingProfile(
    parserIdentifier: String,
    headers: [String],
    forcedAccountId: UUID?
  ) async throws -> CSVImportProfile? {
    let profiles = try await backend.csvImportProfiles.fetchAll()
    let normalisedHeaders = headers.map { CSVImportProfile.normalise($0) }
    if let forcedAccountId {
      return profiles.first(where: {
        $0.accountId == forcedAccountId
          && $0.parserIdentifier == parserIdentifier
          && $0.headerSignature == normalisedHeaders
      })
    }
    let matching = profiles.filter {
      $0.parserIdentifier == parserIdentifier
        && $0.headerSignature == normalisedHeaders
    }
    return matching.count == 1 ? matching[0] : nil
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
    accountInstruments: [UUID: Instrument],
    sessionId: UUID,
    source: ImportSource,
    parserIdentifier: String
  ) -> Transaction {
    var legs = evaluation.transaction.legs.map { leg in
      resolveParsedLeg(leg, routedAccountId: routedAccountId, accountInstrument: accountInstrument)
    }
    if let categoryId = evaluation.assignedCategoryId,
      let index = legs.firstIndex(where: { $0.type == .expense })
    {
      legs[index].categoryId = categoryId
    }
    if let toId = evaluation.transferTargetAccountId, let cash = legs.first {
      legs = makeTransferLegs(
        from: cash,
        fromAccountId: routedAccountId,
        toAccountId: toId,
        accountInstruments: accountInstruments)
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

  /// Rewrite placeholder-instrument legs (cash legs from parsers) to the
  /// routed account's actual instrument. Explicit instrument legs (e.g.
  /// SelfWealth's `ASX:BHP` position leg) are left alone. The flag is set
  /// by the parser at the leg's point-of-origin, replacing the earlier
  /// fragile "is it AUD?" heuristic.
  private func resolveParsedLeg(
    _ leg: ParsedLeg, routedAccountId: UUID, accountInstrument: Instrument
  ) -> TransactionLeg {
    let resolvedAccount = leg.accountId ?? routedAccountId
    let resolvedInstrument =
      leg.isInstrumentPlaceholder ? accountInstrument : leg.instrument
    return TransactionLeg(
      accountId: resolvedAccount,
      instrument: resolvedInstrument,
      quantity: leg.quantity,
      type: leg.type,
      categoryId: nil,
      earmarkId: nil)
  }

  /// Build the pair of legs for a `.markAsTransfer` evaluation. Each side
  /// of a transfer carries ITS OWN account's instrument (Rule 11a). Falls
  /// back to the source leg's instrument if the destination account isn't
  /// in the lookup — that's a same-instrument transfer, which is the safe
  /// default when the map is incomplete.
  private func makeTransferLegs(
    from cash: TransactionLeg,
    fromAccountId: UUID,
    toAccountId: UUID,
    accountInstruments: [UUID: Instrument]
  ) -> [TransactionLeg] {
    let destinationInstrument = accountInstruments[toAccountId] ?? cash.instrument
    return [
      TransactionLeg(
        accountId: fromAccountId,
        instrument: cash.instrument,
        quantity: -abs(cash.quantity),
        type: .transfer,
        categoryId: nil, earmarkId: nil),
      TransactionLeg(
        accountId: toAccountId,
        instrument: destinationInstrument,
        quantity: abs(cash.quantity),
        type: .transfer,
        categoryId: nil, earmarkId: nil),
    ]
  }

  /// Rebuild a `GenericBankCSVParser.ColumnMapping` from the raw strings
  /// persisted on `CSVImportProfile.columnRoleRawValues`. Static +
  /// nonisolated so it can be called from `runPipeline` without crossing
  /// actor boundaries. Returns nil when the raw-values array is empty /
  /// all nil / obviously inconsistent with the live headers.
  nonisolated static func buildColumnMapping(
    headers: [String],
    columnRoleRawValues: [String?],
    sampleRows: [[String]],
    dateFormatOverride: GenericBankCSVParser.DateFormat?
  ) -> GenericBankCSVParser.ColumnMapping? {
    guard columnRoleRawValues.count == headers.count else { return nil }
    // Resolve role per column; indices < 0 mean "unassigned" which
    // `safe(row:_:)` turns into "".
    func firstIndex(of role: CSVImportSetupStore.ColumnRole) -> Int? {
      columnRoleRawValues.firstIndex { $0 == role.rawValue }
    }
    let date = firstIndex(of: .date) ?? -1
    let description = firstIndex(of: .description) ?? -1
    guard date >= 0, description >= 0 else { return nil }
    let amount = firstIndex(of: .amount)
    let debit = firstIndex(of: .debit)
    let credit = firstIndex(of: .credit)
    let balance = firstIndex(of: .balance)
    let reference = firstIndex(of: .reference)
    guard amount != nil || (debit != nil && credit != nil) else { return nil }

    // Date format: prefer the explicit override; otherwise re-detect
    // against the current sample rows using the same algorithm the
    // detector uses when a profile has no stored format.
    let parser = GenericBankCSVParser()
    let detectedMapping = parser.inferMapping(from: headers, sampleRows: sampleRows)
    let detectedFormat =
      detectedMapping?.dateFormat ?? .ddMMyyyy(separator: "/")
    let dateFormat = dateFormatOverride ?? detectedFormat

    return GenericBankCSVParser.ColumnMapping(
      date: date,
      description: description,
      amount: amount,
      debit: debit,
      credit: credit,
      balance: balance,
      reference: reference,
      dateFormat: dateFormat,
      dateFormatAmbiguous: false)
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

  /// File delete runs off the main actor so the UI isn't blocked on a slow
  /// filesystem call — network-share volumes, security-scoped resource
  /// locks, and iCloud Drive materialisation can all push `removeItem` into
  /// the hundreds-of-ms range. As a `nonisolated` async function called via
  /// `await` from the main actor, Swift's concurrency runtime schedules
  /// the body on a cooperative pool thread automatically — no
  /// `Task.detached` needed.
  nonisolated private static func deleteSourceInBackground(at url: URL) async {
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      let path = url.path
      let description = error.localizedDescription
      importStoreBackgroundLogger.warning(
        "Could not delete source file at \(path, privacy: .public): \(description, privacy: .public)"
      )
    }
  }
}
