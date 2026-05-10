// Backends/GRDB/Repositories/GRDBAccountRepository.swift

import Foundation
import GRDB

/// GRDB-backed implementation of `AccountRepository`. Replaces the
/// SwiftData-backed `CloudKitAccountRepository` for the `account` table.
///
/// **Position computation.** `fetchAll()` returns accounts with their
/// per-instrument `positions` populated. Positions are summed from
/// non-scheduled `transaction_leg` rows grouped by
/// `(account_id, instrument_id)` and resolved against the `instrument`
/// registry (with ambient ISO fiat as a fallback). Mirrors the
/// SwiftData-era `CloudKitAccountRepository.computePositions`.
///
/// **Opening balance.** `create(_:openingBalance:)` performs the account
/// insert and the optional opening-balance transaction (one
/// `TransactionRow` + one `TransactionLegRow`) inside a single
/// `database.write { … }`. Hook fan-out happens after the transaction
/// commits — emitting hooks inside the write would publish changes that
/// haven't yet been made durable.
///
/// **`@unchecked Sendable` justification.** All stored properties are
/// `let`. `database` (`any DatabaseWriter`) is itself `Sendable` (GRDB
/// protocol guarantee — the queue's serial executor mediates concurrent
/// access). `onRecordChanged` and `onRecordDeleted` are `@Sendable`
/// closures captured at init. Nothing mutates post-init, so the
/// reference can be shared across actor boundaries without a data
/// race; `@unchecked` only waives Swift's structural check that
/// `final class` types meet `Sendable`'s requirements automatically.
/// See `guides/CONCURRENCY_GUIDE.md` §2 "False Positives to Avoid",
/// Carve-out 3 (GRDB repositories).
final class GRDBAccountRepository: AccountRepository, @unchecked Sendable {
  // `database` and `errorChannel` are deliberately not `private` so the
  // sibling `+Observation.swift` extension can reach them. Treat them
  // as private-by-convention from elsewhere in the module.
  let database: any DatabaseWriter
  /// Receives `(recordType, id)` so the opening-balance create path can
  /// tag its txn and leg writes with `TransactionRow.recordType` /
  /// `TransactionLegRow.recordType` instead of the account's own type —
  /// see `RepositoryHookRecordTypeTests`.
  private let onRecordChanged: @Sendable (String, UUID) -> Void
  private let onRecordDeleted: @Sendable (String, UUID) -> Void
  /// `Instrument` value of any non-fiat instrument that
  /// `performAccountInsert` had to auto-insert into the per-profile
  /// `instrument` table to satisfy a stock / crypto account's
  /// denomination. The wired closure publishes the value to the shared
  /// registry on the profile-index zone so sibling devices see it; the
  /// per-profile copy stays for read paths. Without this hook the new
  /// row would never reach CloudKit and sibling devices would fall
  /// back to `Instrument.fiat(code: id)` — see
  /// `InstrumentLocalSyncQueueTests`.
  private let onInstrumentChanged: @Sendable (Instrument) -> Void
  /// Single shared error channel for every `observeAll()` subscription
  /// returned by this repo instance. The bridge in
  /// `Backends/GRDB/Observation/AsyncValueObservation+AsyncStream.swift`
  /// is single-shot, so once `surfaceAndFinish(_:)` is called the
  /// channel terminates — subsequent observations from the same repo
  /// share that fate. This matches the design's "repository instance
  /// owns the channel" rule.
  let errorChannel = ObservationErrorChannel()

  init(
    database: any DatabaseWriter,
    onRecordChanged: @escaping @Sendable (String, UUID) -> Void = { _, _ in },
    onRecordDeleted: @escaping @Sendable (String, UUID) -> Void = { _, _ in },
    onInstrumentChanged: @escaping @Sendable (Instrument) -> Void = { _ in }
  ) {
    self.database = database
    self.onRecordChanged = onRecordChanged
    self.onRecordDeleted = onRecordDeleted
    self.onInstrumentChanged = onInstrumentChanged
  }

  // MARK: - AccountRepository conformance

  func fetchAll() async throws -> [Account] {
    try await database.read { database in
      let instruments = try Self.fetchInstrumentMap(database: database)
      let rows =
        try AccountRow
        .order(AccountRow.Columns.position.asc)
        .fetchAll(database)
      let positionsByAccount = try Self.computePositions(
        database: database, instruments: instruments)
      return try rows.map { row in
        try row.toDomain(
          instruments: instruments,
          positions: positionsByAccount[row.id] ?? [])
      }
    }
  }

  func create(
    _ account: Account,
    openingBalance: InstrumentAmount? = nil
  ) async throws -> Account {
    guard !account.name.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw BackendError.validationFailed("Account name cannot be empty")
    }

    // Capture the wall clock outside the write block so the closure body
    // doesn't read `Date()` while holding the GRDB queue's serial
    // executor.
    let openingBalanceDate = Date()
    let inserts = try await database.write { database -> OpeningBalanceInserts in
      try Self.performAccountInsert(
        database: database,
        account: account,
        openingBalance: openingBalance,
        openingBalanceDate: openingBalanceDate)
    }

    onRecordChanged(AccountRow.recordType, account.id)
    if let txnId = inserts.transactionId {
      onRecordChanged(TransactionRow.recordType, txnId)
    }
    if let legId = inserts.legId {
      onRecordChanged(TransactionLegRow.recordType, legId)
    }
    if let instrument = inserts.instrument {
      onInstrumentChanged(instrument)
    }
    return account
  }

  // `performAccountInsert` and `OpeningBalanceInserts` live in
  // `GRDBAccountRepository+Create.swift` to keep this file under
  // SwiftLint's `type_body_length` and `file_length` budgets.

  func update(_ account: Account) async throws -> Account {
    guard !account.name.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw BackendError.validationFailed("Account name cannot be empty")
    }

    // Combine the row update and the post-update position read into a
    // single `database.write` so the returned `Account` reflects the
    // exact same database state as the row mutation. A separate
    // follow-up `database.read` would race with concurrent writers and
    // could observe positions from after the update commit, or — worse
    // — emit `onRecordChanged` before the second read settled.
    let resolved = try await database.write { database -> Account in
      guard
        var existing =
          try AccountRow
          .filter(AccountRow.Columns.id == account.id)
          .fetchOne(database)
      else {
        throw BackendError.notFound("Account not found")
      }
      existing.name = account.name
      existing.type = account.type.rawValue
      existing.instrumentId = account.instrument.id
      existing.position = account.position
      existing.isHidden = account.isHidden
      existing.valuationMode = account.valuationMode.rawValue
      try existing.update(database)

      let instruments = try Self.fetchInstrumentMap(database: database)
      let positions = try Self.computePositions(
        database: database, instruments: instruments, accountId: account.id)
      return try existing.toDomain(instruments: instruments, positions: positions)
    }
    onRecordChanged(AccountRow.recordType, account.id)
    return resolved
  }

  /// Single-statement bootstrap migration: flips every investment
  /// account without an `InvestmentValue` snapshot to
  /// `valuationMode = .calculatedFromTrades`. Runs inside one
  /// `database.write { … }` so the whole pass is one transaction / one
  /// fsync — replaces the historic per-account loop driven by
  /// `ValuationModeMigration.run()`.
  ///
  /// Idempotency lives one level up — `ValuationModeMigration` gates
  /// the call on a per-profile `UserDefaults` flag and never invokes
  /// this method twice for the same install.
  ///
  /// Hooks are deliberately not fired: this runs at bootstrap before
  /// any sync subscriber is attached, and the new value is locally
  /// derived state (CKSyncEngine treats `valuation_mode` like any
  /// other field — the next remote upload will surface the change via
  /// the regular store path).
  func backfillValuationModeForUnsnapshotInvestmentAccounts() async throws -> Int {
    try await database.write { database in
      try database.execute(
        literal: """
          UPDATE account
          SET valuation_mode = \(ValuationMode.calculatedFromTrades.rawValue)
          WHERE type = \(AccountType.investment.rawValue)
            AND id NOT IN (SELECT DISTINCT account_id FROM investment_value)
          """)
      return database.changesCount
    }
  }

  func delete(id: UUID) async throws {
    // Soft-delete: flip `is_hidden = true` on the matching row.
    // Rejects deletes against an account with non-zero positions —
    // mirrors the SwiftData-era contract enforced by
    // `CloudKitAccountRepository.delete(id:)`.
    try await database.write { database in
      guard
        var existing =
          try AccountRow
          .filter(AccountRow.Columns.id == id)
          .fetchOne(database)
      else {
        throw BackendError.notFound("Account not found")
      }
      let instruments = try Self.fetchInstrumentMap(database: database)
      let positions = try Self.computePositions(
        database: database, instruments: instruments, accountId: id)
      if positions.contains(where: { $0.quantity != 0 }) {
        throw BackendError.validationFailed(
          "Cannot delete account with non-zero balance")
      }
      existing.isHidden = true
      try existing.update(database)
    }
    onRecordChanged(AccountRow.recordType, id)
  }

  // MARK: - Sync entry points (synchronous, GRDB-queue-blocking)
  //
  // Called from the CKSyncEngine delegate executor on a non-MainActor
  // context. `DatabaseWriter.write { db in … }` has both async and sync
  // overloads; the sync form blocks the calling thread until the queue's
  // serial executor admits the closure. Never call these from
  // `@MainActor`.

  func applyRemoteChangesSync(saved rows: [AccountRow], deleted ids: [UUID]) throws {
    try database.write { database in
      for row in rows {
        try row.upsert(database)
      }
      for id in ids {
        // Replicates the v3-era ON DELETE CASCADE on
        // `investment_value.account_id` and ON DELETE SET NULL on
        // `transaction_leg.account_id` after `v5_drop_foreign_keys`
        // removed the FKs. Same write transaction so the cascade is
        // atomic with the parent delete.
        _ =
          try InvestmentValueRow
          .filter(InvestmentValueRow.Columns.accountId == id)
          .deleteAll(database)
        _ =
          try TransactionLegRow
          .filter(TransactionLegRow.Columns.accountId == id)
          .updateAll(
            database,
            [TransactionLegRow.Columns.accountId.set(to: nil)])
        _ = try AccountRow.deleteOne(database, id: id)
      }
    }
  }

  /// Writes (or clears) the cached system-fields blob on a single row.
  /// Returns `true` when a row was found and updated.
  @discardableResult
  func setEncodedSystemFieldsSync(id: UUID, data: Data?) throws -> Bool {
    try database.write { database in
      try AccountRow
        .filter(AccountRow.Columns.id == id)
        .updateAll(database, [AccountRow.Columns.encodedSystemFields.set(to: data)])
        > 0
    }
  }

  /// Batch counterpart to `setEncodedSystemFieldsSync` — writes every
  /// update in a single GRDB transaction so `databaseDidCommit` fires
  /// once rather than once per row. See the doc on
  /// `GRDBTransactionRepository.setEncodedSystemFieldsBatchSync` for
  /// the rationale and issue #865 for the follow-up that drops the
  /// observation-region dependency on this column.
  func setEncodedSystemFieldsBatchSync(
    _ updates: [(id: UUID, data: Data?)]
  ) throws -> Int {
    guard !updates.isEmpty else { return 0 }
    return try database.write { database in
      var updatedCount = 0
      for (id, data) in updates {
        updatedCount +=
          try AccountRow
          .filter(AccountRow.Columns.id == id)
          .updateAll(
            database,
            [AccountRow.Columns.encodedSystemFields.set(to: data)])
      }
      return updatedCount
    }
  }

  /// Clears `encoded_system_fields` on every row. Used after an
  /// `encryptedDataReset`.
  func clearAllSystemFieldsSync() throws {
    try database.write { database in
      _ =
        try AccountRow
        .updateAll(
          database,
          [AccountRow.Columns.encodedSystemFields.set(to: nil)])
    }
  }

  /// Returns IDs of rows whose `encoded_system_fields` is `NULL`.
  func unsyncedRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try AccountRow
        .filter(AccountRow.Columns.encodedSystemFields == nil)
        .select(AccountRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  /// Returns IDs of every row in the table.
  func allRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try AccountRow
        .select(AccountRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  /// Looks up a single row by id. Used by the per-record upload path in
  /// the sync handler.
  func fetchRowSync(id: UUID) throws -> AccountRow? {
    try database.read { database in
      try AccountRow
        .filter(AccountRow.Columns.id == id)
        .fetchOne(database)
    }
  }

  /// Batch lookup by ids — used by the batch-build phase of the sync
  /// handler.
  func fetchRowsSync(ids: [UUID]) throws -> [AccountRow] {
    let idSet = Set(ids)
    return try database.read { database in
      try AccountRow
        .filter(idSet.contains(AccountRow.Columns.id))
        .fetchAll(database)
    }
  }

  /// Deletes every row in the table. Used by `deleteLocalData` after a
  /// remote zone deletion.
  func deleteAllSync() throws {
    try database.write { database in
      _ = try AccountRow.deleteAll(database)
    }
  }
}
