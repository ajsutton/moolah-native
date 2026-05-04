// Backends/GRDB/Repositories/GRDBTransactionRepository.swift

import Foundation
import GRDB
import OSLog

/// GRDB-backed implementation of `TransactionRepository`. Replaces the
/// SwiftData-backed `CloudKitTransactionRepository` for the
/// `"transaction"` and `transaction_leg` tables.
///
/// **Header + legs together.** Every write path (`create`, `update`,
/// `delete`) inserts/deletes the `TransactionRow` and its
/// `TransactionLegRow`s inside a single `database.write { … }`. On any
/// throw the entire mutation rolls back. After
/// `v5_drop_foreign_keys` the schema no longer enforces FK CASCADE on
/// `transaction_leg.transaction_id`; `delete(id:)` and the sync
/// `applyRemoteChangesSync` in `+Sync.swift` therefore delete legs
/// explicitly before the parent, in the same write transaction, so a
/// partially committed header cannot leave orphaned legs. Rollback
/// test mandatory; see `guides/DATABASE_CODE_GUIDE.md`.
///
/// **Instrument resolution.** Each leg's `instrument` is resolved by
/// reading the `instrument` table inside the same read transaction
/// (matching `GRDBAccountRepository.fetchInstrumentMap`). Stored rows
/// win over ambient fiat synthesised from `Locale.Currency.isoCurrencies`.
/// Mirrors `CloudKitTransactionRepository.resolveInstrument(id:)`.
///
/// **Running balance.** The repository does not compute running balances —
/// `TransactionPage.withRunningBalances(...)` is the domain helper the
/// store calls after the fetch returns. The `priorBalance` field on the
/// page is the account-scoped subtotal of every leg _after_ the page
/// (newer pages have already been read), converted to the target
/// instrument by `InstrumentConversionService`. Returns `nil` on any
/// conversion failure (Rule 11 of `guides/INSTRUMENT_CONVERSION_GUIDE.md`).
///
/// **`@unchecked Sendable` justification.** All stored properties are
/// `let`. `database` (`any DatabaseWriter`) is itself `Sendable` (GRDB
/// protocol guarantee — the queue's serial executor mediates concurrent
/// access). `defaultInstrument` is a value type. `conversionService` is
/// a `Sendable` protocol. `onRecordChanged` and `onRecordDeleted` are
/// `@Sendable` closures captured at init. Nothing mutates post-init, so
/// the reference can be shared across actor boundaries without a data
/// race; `@unchecked` only waives Swift's structural check that
/// `final class` types meet `Sendable`'s requirements automatically.
/// See `guides/CONCURRENCY_GUIDE.md` §2 "False Positives to Avoid",
/// Carve-out 3 (GRDB repositories).
final class GRDBTransactionRepository: TransactionRepository, @unchecked Sendable {
  let database: any DatabaseWriter
  /// Profile instrument used to label the running balance for global
  /// (non-account-scoped) fetches. Mirrors
  /// `CloudKitTransactionRepository.instrument`.
  private let defaultInstrument: Instrument
  private let conversionService: any InstrumentConversionService
  /// Receives `(recordType, id)` so legs and parent transactions tag
  /// their own CloudKit `recordName` correctly. The transaction repo
  /// emits both `TransactionRow.recordType` (parent) and
  /// `TransactionLegRow.recordType` (per leg) ids from the same
  /// mutation, so the callback must carry the type — see
  /// `RepositoryHookRecordTypeTests`.
  private let onRecordChanged: @Sendable (String, UUID) -> Void
  private let onRecordDeleted: @Sendable (String, UUID) -> Void

  private let logger = Logger(
    subsystem: "com.moolah.app", category: "GRDBTransactionRepository")

  init(
    database: any DatabaseWriter,
    defaultInstrument: Instrument,
    conversionService: any InstrumentConversionService,
    onRecordChanged: @escaping @Sendable (String, UUID) -> Void = { _, _ in },
    onRecordDeleted: @escaping @Sendable (String, UUID) -> Void = { _, _ in }
  ) {
    self.database = database
    self.defaultInstrument = defaultInstrument
    self.conversionService = conversionService
    self.onRecordChanged = onRecordChanged
    self.onRecordDeleted = onRecordDeleted
  }

  // MARK: - TransactionRepository conformance

  func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage {
    let snapshot = try await database.read { database -> FetchSnapshot in
      try Self.buildFetchSnapshot(
        database: database,
        filter: filter,
        page: page,
        pageSize: pageSize,
        defaultInstrument: self.defaultInstrument)
    }
    let priorBalance = await resolvePriorBalance(snapshot: snapshot)
    return TransactionPage(
      transactions: snapshot.pageTransactions,
      targetInstrument: snapshot.resolvedTarget,
      priorBalance: priorBalance,
      totalCount: snapshot.totalCount)
  }

  func fetchAll(filter: TransactionFilter) async throws -> [Transaction] {
    try await database.read { database in
      let instruments = try Self.fetchInstrumentMap(database: database)
      let candidateRows = try Self.candidateTransactionRows(
        database: database, filter: filter)
      let filteredRows = try Self.applyLegFilters(
        rows: candidateRows, filter: filter, database: database)
      let legsByTxnId = try Self.fetchLegs(
        database: database,
        transactionIds: filteredRows.map(\.id),
        instruments: instruments)
      return try filteredRows.map { row in
        try row.toDomain(legs: legsByTxnId[row.id] ?? [])
      }
    }
  }

  func create(_ transaction: Transaction) async throws -> Transaction {
    let insertedLegIds = try await database.write { database -> [UUID] in
      let txnRow = TransactionRow(domain: transaction)
      try txnRow.insert(database)

      var legIds: [UUID] = []
      legIds.reserveCapacity(transaction.legs.count)
      for (index, leg) in transaction.legs.enumerated() {
        // Ensure non-fiat instrument rows exist so `fetchAll` can resolve
        // the full `Instrument` value on read. After v5 dropped FKs, a leg
        // referencing an account/category/earmark that hasn't arrived yet
        // is allowed to land as-is — see `+FKEnsure.swift` and SYNC_GUIDE.
        try Self.ensureInstrumentReadable(
          database: database,
          leg: leg)
        let legId = UUID()
        let legRow = TransactionLegRow(
          id: legId,
          domain: leg,
          transactionId: transaction.id,
          sortOrder: index)
        try legRow.insert(database)
        legIds.append(legId)
      }
      return legIds
    }

    onRecordChanged(TransactionRow.recordType, transaction.id)
    for legId in insertedLegIds {
      onRecordChanged(TransactionLegRow.recordType, legId)
    }
    return transaction
  }

  func update(_ transaction: Transaction) async throws -> Transaction {
    let outcome = try await database.write { database -> UpdateOutcome in
      try Self.performUpdate(
        database: database,
        transaction: transaction)
    }

    onRecordChanged(TransactionRow.recordType, transaction.id)
    for legId in outcome.insertedLegIds {
      onRecordChanged(TransactionLegRow.recordType, legId)
    }
    for legId in outcome.deletedLegIds {
      onRecordDeleted(TransactionLegRow.recordType, legId)
    }
    return transaction
  }

  func delete(id: UUID) async throws {
    // Explicit delete of legs before the parent, replacing the v3-era
    // ON DELETE CASCADE on `transaction_leg.transaction_id` that v5
    // dropped (`v5_drop_foreign_keys`). The `fetchAll(...).map(\.id)`
    // for hook fan-out MUST precede `deleteAll(...)` — after the delete
    // the fetch returns empty and per-leg `onRecordDeleted` hooks
    // silently stop firing. Both deletes share the same write
    // transaction so the parent + children disappear atomically.
    let outcome = try await database.write { database -> (didDelete: Bool, legIds: [UUID]) in
      let legIds =
        try TransactionLegRow
        .filter(TransactionLegRow.Columns.transactionId == id)
        .fetchAll(database)
        .map(\.id)
      _ =
        try TransactionLegRow
        .filter(TransactionLegRow.Columns.transactionId == id)
        .deleteAll(database)
      let didDelete = try TransactionRow.deleteOne(database, id: id)
      return (didDelete, legIds)
    }
    guard outcome.didDelete else {
      throw BackendError.notFound("Transaction not found")
    }
    onRecordDeleted(TransactionRow.recordType, id)
    for legId in outcome.legIds {
      onRecordDeleted(TransactionLegRow.recordType, legId)
    }
  }

  func fetchPayeeSuggestions(
    prefix: String, excludingTransactionId: UUID?
  ) async throws -> [String] {
    guard !prefix.isEmpty else { return [] }
    return try await database.read { database in
      // `LIKE ? || '%'` keeps the wildcard out of the bound argument so
      // a payee containing literal `%` cannot inject a wildcard into
      // the match. Lowercasing is symmetric on both sides. Ordering by
      // frequency (descending) puts most-used payees at the top, with
      // the payee string as a stable tie-breaker for deterministic
      // pagination.
      //
      // `excludingTransactionId` removes the editing row from both the
      // GROUP BY count and the visible list (#538) so a payee that only
      // exists on the row being edited disappears, and one that exists
      // on N rows is counted as N-1 from that row's perspective.
      if let excludingTransactionId {
        let sql = """
          SELECT payee
          FROM "transaction"
          WHERE payee IS NOT NULL
            AND id != ?
            AND lower(payee) LIKE lower(?) || '%'
          GROUP BY payee
          ORDER BY COUNT(*) DESC, payee ASC
          LIMIT 20
          """
        return try String.fetchAll(
          database, sql: sql, arguments: [excludingTransactionId, prefix])
      }
      let sql = """
        SELECT payee
        FROM "transaction"
        WHERE payee IS NOT NULL
          AND lower(payee) LIKE lower(?) || '%'
        GROUP BY payee
        ORDER BY COUNT(*) DESC, payee ASC
        LIMIT 20
        """
      return try String.fetchAll(database, sql: sql, arguments: [prefix])
    }
  }

  // MARK: - Private helpers

  private struct UpdateOutcome {
    let deletedLegIds: [UUID]
    let insertedLegIds: [UUID]
  }

  /// Single-statement body of `update`'s `database.write { … }`
  /// closure. Looks up the existing header row, applies the domain
  /// fields, replaces every leg, and returns the deleted/inserted leg
  /// ids so the caller can fan out the right hooks after the
  /// transaction commits.
  private static func performUpdate(
    database: Database,
    transaction: Transaction
  ) throws -> UpdateOutcome {
    guard
      var existing =
        try TransactionRow
        .filter(TransactionRow.Columns.id == transaction.id)
        .fetchOne(database)
    else {
      throw BackendError.notFound("Transaction not found")
    }
    applyMetadata(of: transaction, to: &existing)
    try existing.update(database)

    let oldLegs =
      try TransactionLegRow
      .filter(TransactionLegRow.Columns.transactionId == transaction.id)
      .fetchAll(database)
    let oldLegIds = oldLegs.map(\.id)
    _ =
      try TransactionLegRow
      .filter(TransactionLegRow.Columns.transactionId == transaction.id)
      .deleteAll(database)

    var newLegIds: [UUID] = []
    newLegIds.reserveCapacity(transaction.legs.count)
    for (index, leg) in transaction.legs.enumerated() {
      try Self.ensureInstrumentReadable(database: database, leg: leg)
      let legId = UUID()
      let legRow = TransactionLegRow(
        id: legId,
        domain: leg,
        transactionId: transaction.id,
        sortOrder: index)
      try legRow.insert(database)
      newLegIds.append(legId)
    }
    return UpdateOutcome(deletedLegIds: oldLegIds, insertedLegIds: newLegIds)
  }

  /// Converts the snapshot's per-instrument after-page subtotals to a
  /// single `priorBalance` on the target instrument. Returns `nil` on
  /// any conversion failure so callers can mark the running-balance
  /// column unavailable (Rule 11 of `INSTRUMENT_CONVERSION_GUIDE.md`).
  private func resolvePriorBalance(snapshot: FetchSnapshot) async -> InstrumentAmount? {
    if snapshot.isPastEnd || !snapshot.hasAccountFilter {
      return InstrumentAmount.zero(instrument: snapshot.resolvedTarget)
    }

    let target = snapshot.resolvedTarget
    var total = InstrumentAmount.zero(instrument: target)
    let today = Date()
    for entry in snapshot.afterPageSubtotals {
      if entry.instrument == target {
        total += entry.amount
        continue
      }
      do {
        let converted = try await conversionService.convertAmount(
          entry.amount, to: target, on: today)
        if Task.isCancelled { return nil }
        total += converted
      } catch {
        logger.warning(
          """
          priorBalance conversion failed for \
          \(entry.instrument.id, privacy: .public) → \
          \(target.id, privacy: .public): \
          \(String(describing: error), privacy: .public)
          """)
        return nil
      }
    }
    return total
  }

  /// Mirrors `CloudKitTransactionRepository.applyMetadata`. Copies the
  /// header fields (including the eight denormalised
  /// `import_origin_*` columns) from the domain object onto the
  /// existing row.
  private static func applyMetadata(
    of transaction: Transaction, to row: inout TransactionRow
  ) {
    let fresh = TransactionRow(domain: transaction)
    row.date = fresh.date
    row.payee = fresh.payee
    row.notes = fresh.notes
    row.recurPeriod = fresh.recurPeriod
    row.recurEvery = fresh.recurEvery
    row.importOriginRawDescription = fresh.importOriginRawDescription
    row.importOriginBankReference = fresh.importOriginBankReference
    row.importOriginRawAmount = fresh.importOriginRawAmount
    row.importOriginRawBalance = fresh.importOriginRawBalance
    row.importOriginImportedAt = fresh.importOriginImportedAt
    row.importOriginImportSessionId = fresh.importOriginImportSessionId
    row.importOriginSourceFilename = fresh.importOriginSourceFilename
    row.importOriginParserIdentifier = fresh.importOriginParserIdentifier
  }

}
