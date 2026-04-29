// Backends/GRDB/Repositories/GRDBInvestmentRepository.swift

import Foundation
import GRDB

/// GRDB-backed implementation of `InvestmentRepository`. Replaces the
/// SwiftData-backed `CloudKitInvestmentRepository` for the
/// `investment_value` table.
///
/// **Composite uniqueness** on `(account_id, date)` is enforced at the
/// repository layer (matching the SwiftData status quo), not as a SQL
/// UNIQUE constraint — `setValue(...)` does an explicit
/// `SELECT … LIMIT 1` followed by `UPDATE` or `INSERT` so a same-day
/// re-write replaces in place.
///
/// **`@unchecked Sendable` justification.** All stored properties are
/// `let`. `database` (`any DatabaseWriter`) is itself `Sendable` (GRDB
/// protocol guarantee — the queue's serial executor mediates concurrent
/// access). `defaultInstrument` is a value type. `onRecordChanged` and
/// `onRecordDeleted` are `@Sendable` closures captured at init. Nothing
/// mutates post-init, so the reference can be shared across actor
/// boundaries without a data race; `@unchecked` only waives Swift's
/// structural check that `final class` types meet `Sendable`'s
/// requirements automatically.
final class GRDBInvestmentRepository: InvestmentRepository, @unchecked Sendable {
  private let database: any DatabaseWriter
  /// Used as the labelling instrument on `AccountDailyBalance` rows
  /// returned from `fetchDailyBalances(...)`. Mirrors
  /// `CloudKitInvestmentRepository.instrument`.
  private let defaultInstrument: Instrument
  private let onRecordChanged: @Sendable (String, UUID) -> Void
  private let onRecordDeleted: @Sendable (String, UUID) -> Void

  init(
    database: any DatabaseWriter,
    defaultInstrument: Instrument,
    onRecordChanged: @escaping @Sendable (String, UUID) -> Void = { _, _ in },
    onRecordDeleted: @escaping @Sendable (String, UUID) -> Void = { _, _ in }
  ) {
    self.database = database
    self.defaultInstrument = defaultInstrument
    self.onRecordChanged = onRecordChanged
    self.onRecordDeleted = onRecordDeleted
  }

  // MARK: - InvestmentRepository conformance

  func fetchValues(
    accountId: UUID, page: Int, pageSize: Int
  ) async throws -> InvestmentValuePage {
    try await database.read { database in
      // Fetch one extra row to detect `hasMore` without a separate
      // count query. Trim before mapping.
      let rows =
        try InvestmentValueRow
        .filter(InvestmentValueRow.Columns.accountId == accountId)
        .order(InvestmentValueRow.Columns.date.desc)
        .limit(pageSize + 1, offset: page * pageSize)
        .fetchAll(database)
      let hasMore = rows.count > pageSize
      let values = rows.prefix(pageSize).map { $0.toDomain() }
      return InvestmentValuePage(values: Array(values), hasMore: hasMore)
    }
  }

  func setValue(accountId: UUID, date: Date, value: InstrumentAmount) async throws {
    let normalisedDate = Calendar.current.startOfDay(for: date)
    let changedId = try await database.write { database -> UUID in
      if var existing =
        try InvestmentValueRow
        .filter(
          InvestmentValueRow.Columns.accountId == accountId
            && InvestmentValueRow.Columns.date == normalisedDate
        )
        .fetchOne(database)
      {
        existing.value = value.storageValue
        existing.instrumentId = value.instrument.id
        try existing.update(database)
        return existing.id
      }

      let id = UUID()
      let row = InvestmentValueRow(
        id: id,
        recordName: InvestmentValueRow.recordName(for: id),
        accountId: accountId,
        date: normalisedDate,
        value: value.storageValue,
        instrumentId: value.instrument.id,
        encodedSystemFields: nil)
      try row.insert(database)
      return id
    }
    onRecordChanged(InvestmentValueRow.recordType, changedId)
  }

  func removeValue(accountId: UUID, date: Date) async throws {
    let normalisedDate = Calendar.current.startOfDay(for: date)
    let deletedId = try await database.write { database -> UUID in
      guard
        let existing =
          try InvestmentValueRow
          .filter(
            InvestmentValueRow.Columns.accountId == accountId
              && InvestmentValueRow.Columns.date == normalisedDate
          )
          .fetchOne(database)
      else {
        throw BackendError.notFound("Investment value not found")
      }
      let id = existing.id
      try existing.delete(database)
      return id
    }
    onRecordDeleted(InvestmentValueRow.recordType, deletedId)
  }

  func fetchDailyBalances(accountId: UUID) async throws -> [AccountDailyBalance] {
    let defaultInstrument = self.defaultInstrument
    return try await database.read { database in
      try Self.computeDailyBalances(
        database: database,
        accountId: accountId,
        defaultInstrument: defaultInstrument)
    }
  }

  /// Single-statement body of `fetchDailyBalances`'s `database.read`
  /// closure. Reads booked legs (excluding scheduled recurrences),
  /// looks up their dates, accumulates a running balance, and
  /// collapses to one entry per calendar day. Mirrors
  /// `CloudKitInvestmentRepository.fetchDailyBalances`.
  private static func computeDailyBalances(
    database: Database,
    accountId: UUID,
    defaultInstrument: Instrument
  ) throws -> [AccountDailyBalance] {
    // Exclude legs on scheduled (recurring) transactions — they have
    // not yet been booked.
    let scheduledIds =
      try TransactionRow
      .filter(TransactionRow.Columns.recurPeriod != nil)
      .select(TransactionRow.Columns.id, as: UUID.self)
      .fetchAll(database)
    let scheduledIdSet = Set(scheduledIds)

    let legs =
      try TransactionLegRow
      .filter(TransactionLegRow.Columns.accountId == accountId)
      .fetchAll(database)
    let bookedLegs = legs.filter { !scheduledIdSet.contains($0.transactionId) }

    let txnIds = Set(bookedLegs.map(\.transactionId))
    let txnRows =
      try TransactionRow
      .filter(txnIds.contains(TransactionRow.Columns.id))
      .fetchAll(database)
    let dateById: [UUID: Date] = Dictionary(
      uniqueKeysWithValues: txnRows.map { ($0.id, $0.date) }
    )

    let entries: [(date: Date, quantity: Int64)] =
      bookedLegs
      .compactMap { leg in
        guard let date = dateById[leg.transactionId] else { return nil }
        return (date: date, quantity: leg.quantity)
      }
      .sorted { $0.date < $1.date }

    var runningStorage: Int64 = 0
    var dailyBalances: [(date: Date, storageValue: Int64)] = []
    let calendar = Calendar.current

    for entry in entries {
      runningStorage += entry.quantity
      let dayKey = calendar.startOfDay(for: entry.date)
      if let lastIndex = dailyBalances.lastIndex(where: {
        $0.date.isSameDay(as: dayKey)
      }) {
        dailyBalances[lastIndex] = (date: dayKey, storageValue: runningStorage)
      } else {
        dailyBalances.append((date: dayKey, storageValue: runningStorage))
      }
    }

    return dailyBalances.map {
      AccountDailyBalance(
        date: $0.date,
        balance: InstrumentAmount(
          storageValue: $0.storageValue,
          instrument: defaultInstrument))
    }
  }

  // MARK: - Sync entry points (synchronous, GRDB-queue-blocking)
  //
  // Called from the CKSyncEngine delegate executor on a non-MainActor
  // context. `DatabaseWriter.write { db in … }` has both async and sync
  // overloads; the sync form blocks the calling thread until the queue's
  // serial executor admits the closure. Never call these from
  // `@MainActor`.

  func applyRemoteChangesSync(
    saved rows: [InvestmentValueRow], deleted ids: [UUID]
  ) throws {
    try database.write { database in
      for row in rows {
        try row.upsert(database)
      }
      for id in ids {
        _ = try InvestmentValueRow.deleteOne(database, id: id)
      }
    }
  }

  /// Writes (or clears) the cached system-fields blob on a single row.
  /// Returns `true` when a row was found and updated.
  @discardableResult
  func setEncodedSystemFieldsSync(id: UUID, data: Data?) throws -> Bool {
    try database.write { database in
      try InvestmentValueRow
        .filter(InvestmentValueRow.Columns.id == id)
        .updateAll(
          database,
          [InvestmentValueRow.Columns.encodedSystemFields.set(to: data)])
        > 0
    }
  }

  /// Clears `encoded_system_fields` on every row. Used after an
  /// `encryptedDataReset`.
  func clearAllSystemFieldsSync() throws {
    try database.write { database in
      _ =
        try InvestmentValueRow
        .updateAll(
          database,
          [InvestmentValueRow.Columns.encodedSystemFields.set(to: nil)])
    }
  }

  /// Returns IDs of rows whose `encoded_system_fields` is `NULL`.
  func unsyncedRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try InvestmentValueRow
        .filter(InvestmentValueRow.Columns.encodedSystemFields == nil)
        .select(InvestmentValueRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  /// Returns IDs of every row in the table.
  func allRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try InvestmentValueRow
        .select(InvestmentValueRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  /// Looks up a single row by id. Used by the per-record upload path in
  /// the sync handler.
  func fetchRowSync(id: UUID) throws -> InvestmentValueRow? {
    try database.read { database in
      try InvestmentValueRow
        .filter(InvestmentValueRow.Columns.id == id)
        .fetchOne(database)
    }
  }

  /// Batch lookup by ids — used by the batch-build phase of the sync
  /// handler.
  func fetchRowsSync(ids: [UUID]) throws -> [InvestmentValueRow] {
    let idSet = Set(ids)
    return try database.read { database in
      try InvestmentValueRow
        .filter(idSet.contains(InvestmentValueRow.Columns.id))
        .fetchAll(database)
    }
  }

  /// Deletes every row in the table. Used by `deleteLocalData` after a
  /// remote zone deletion.
  func deleteAllSync() throws {
    try database.write { database in
      _ = try InvestmentValueRow.deleteAll(database)
    }
  }
}
