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
final class GRDBAccountRepository: AccountRepository, @unchecked Sendable {
  private let database: any DatabaseWriter
  /// Receives `(recordType, id)` so the opening-balance create path can
  /// tag its txn and leg writes with `TransactionRow.recordType` /
  /// `TransactionLegRow.recordType` instead of the account's own type —
  /// see `RepositoryHookRecordTypeTests`.
  private let onRecordChanged: @Sendable (String, UUID) -> Void
  private let onRecordDeleted: @Sendable (String, UUID) -> Void

  init(
    database: any DatabaseWriter,
    onRecordChanged: @escaping @Sendable (String, UUID) -> Void = { _, _ in },
    onRecordDeleted: @escaping @Sendable (String, UUID) -> Void = { _, _ in }
  ) {
    self.database = database
    self.onRecordChanged = onRecordChanged
    self.onRecordDeleted = onRecordDeleted
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
      return rows.map { row in
        row.toDomain(
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

    let inserts = try await database.write { database -> OpeningBalanceInserts in
      try Self.performAccountInsert(
        database: database,
        account: account,
        openingBalance: openingBalance)
    }

    onRecordChanged(AccountRow.recordType, account.id)
    if let txnId = inserts.transactionId {
      onRecordChanged(TransactionRow.recordType, txnId)
    }
    if let legId = inserts.legId {
      onRecordChanged(TransactionLegRow.recordType, legId)
    }
    return account
  }

  /// Single-statement body of `create(_:openingBalance:)`'s
  /// `database.write { … }` block. Inserts the account row, and — when
  /// the caller passes a non-zero opening balance — a one-leg
  /// `TransactionRow` + `TransactionLegRow` to seed the account's
  /// initial position. Returns the ids the caller fans out as hooks.
  private static func performAccountInsert(
    database: Database,
    account: Account,
    openingBalance: InstrumentAmount?
  ) throws -> OpeningBalanceInserts {
    // Non-fiat instruments (stocks, crypto) must have a row in the
    // `instrument` table so `fetchAll` can resolve the full
    // `Instrument` value (kind, ticker, exchange, chainId, decimals).
    // Fiat is ambient — synthesised from `Locale.Currency.isoCurrencies`
    // by `fetchInstrumentMap`. Mirrors the SwiftData-era
    // `CloudKitAccountRepository.ensureInstrument`.
    if account.instrument.kind != .fiatCurrency {
      let exists =
        try InstrumentRow
        .filter(InstrumentRow.Columns.id == account.instrument.id)
        .fetchOne(database)
      if exists == nil {
        try InstrumentRow(domain: account.instrument).insert(database)
      }
    }

    let accountRow = AccountRow(domain: account)
    try accountRow.insert(database)

    // No opening balance — only the account row was inserted.
    guard let openingBalance, !openingBalance.isZero else {
      return OpeningBalanceInserts(transactionId: nil, legId: nil)
    }

    let txnId = UUID()
    let txnRow = TransactionRow(
      id: txnId,
      recordName: TransactionRow.recordName(for: txnId),
      date: Date(),
      payee: nil,
      notes: nil,
      recurPeriod: nil,
      recurEvery: nil,
      importOriginRawDescription: nil,
      importOriginBankReference: nil,
      importOriginRawAmount: nil,
      importOriginRawBalance: nil,
      importOriginImportedAt: nil,
      importOriginImportSessionId: nil,
      importOriginSourceFilename: nil,
      importOriginParserIdentifier: nil,
      encodedSystemFields: nil)
    try txnRow.insert(database)

    let legId = UUID()
    let legRow = TransactionLegRow(
      id: legId,
      recordName: TransactionLegRow.recordName(for: legId),
      transactionId: txnId,
      accountId: account.id,
      instrumentId: account.instrument.id,
      quantity: openingBalance.storageValue,
      type: TransactionType.openingBalance.rawValue,
      categoryId: nil,
      earmarkId: nil,
      sortOrder: 0,
      encodedSystemFields: nil)
    try legRow.insert(database)

    return OpeningBalanceInserts(transactionId: txnId, legId: legId)
  }

  func update(_ account: Account) async throws -> Account {
    guard !account.name.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw BackendError.validationFailed("Account name cannot be empty")
    }

    let updated = try await database.write { database -> AccountRow in
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
      try existing.update(database)
      return existing
    }
    onRecordChanged(AccountRow.recordType, account.id)

    return try await database.read { database -> Account in
      let instruments = try Self.fetchInstrumentMap(database: database)
      let positions = try Self.computePositions(
        database: database, instruments: instruments, accountId: account.id)
      return updated.toDomain(instruments: instruments, positions: positions)
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

  // MARK: - Helpers

  /// Captures the ids written by `create(_:openingBalance:)` so the
  /// caller can fan out hook fires after the write transaction commits.
  private struct OpeningBalanceInserts {
    let transactionId: UUID?
    let legId: UUID?
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
