// Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository.swift

import Foundation
import GRDB
import OSLog

/// GRDB-backed implementation of `InstrumentRegistryRepository`. Replaces
/// the SwiftData-backed `CloudKitInstrumentRegistryRepository` for the
/// `instrument` table.
///
/// `Instrument` is the only synced row that uses an arbitrary string ID
/// (e.g. `"AUD"`, `"ASX:BHP"`, `"1:0xa0b8…"`) instead of a UUID, so the
/// hook closures and sync entry points are string-keyed rather than
/// UUID-keyed. The repo also exposes a `MainActor`-isolated
/// `observeChanges()` AsyncStream so picker UIs can refresh after local
/// mutations, and a non-protocol `notifyExternalChange()` method that the
/// sync layer calls when remote pulls touch instrument rows.
///
/// **`@unchecked Sendable` justification.** All stored properties are
/// `let` except `subscribers`, which is `@MainActor`-isolated and only
/// touched from `MainActor`-isolated methods. `database`
/// (`any DatabaseWriter`) is itself `Sendable` (GRDB protocol guarantee —
/// the queue's serial executor mediates concurrent access).
/// `onRecordChanged` and `onRecordDeleted` are `@Sendable` closures
/// captured at init. Nothing mutates post-init outside the
/// `MainActor`-confined dictionary, so the reference can be shared
/// across actor boundaries without a data race; `@unchecked` only waives
/// Swift's structural check that `final class` types meet `Sendable`'s
/// requirements automatically.
final class GRDBInstrumentRegistryRepository:
  InstrumentRegistryRepository, @unchecked Sendable
{
  private let database: any DatabaseWriter
  private let onRecordChanged: @Sendable (String) -> Void
  private let onRecordDeleted: @Sendable (String) -> Void
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "InstrumentRegistry")

  @MainActor private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]

  /// - Parameters:
  ///   - onRecordChanged: Invoked from whatever task context completes
  ///     the GRDB write — do not assume `@MainActor`. Typically used to
  ///     queue CKSyncEngine saves, which are themselves thread-safe.
  ///   - onRecordDeleted: Invoked from whatever task context completes
  ///     the GRDB write — do not assume `@MainActor`. Typically used to
  ///     queue CKSyncEngine deletes, which are themselves thread-safe.
  init(
    database: any DatabaseWriter,
    onRecordChanged: @escaping @Sendable (String) -> Void = { _ in },
    onRecordDeleted: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.database = database
    self.onRecordChanged = onRecordChanged
    self.onRecordDeleted = onRecordDeleted
  }

  // MARK: - InstrumentRegistryRepository conformance

  func all() async throws -> [Instrument] {
    let stored = try await database.read { database in
      try InstrumentRow.fetchAll(database).map { $0.toDomain() }
    }
    let storedIds = Set(stored.map(\.id))
    let ambient =
      Locale.Currency.isoCurrencies
      .map(\.identifier)
      .map { Instrument.fiat(code: $0) }
      .filter { !storedIds.contains($0.id) }
    return stored + ambient
  }

  func allCryptoRegistrations() async throws -> [CryptoRegistration] {
    try await database.read { database in
      let cryptoKind = Instrument.Kind.cryptoToken.rawValue
      let rows =
        try InstrumentRow
        .filter(InstrumentRow.Columns.kind == cryptoKind)
        .fetchAll(database)
      return rows.compactMap { row -> CryptoRegistration? in
        guard let mapping = row.cryptoMapping() else { return nil }
        return CryptoRegistration(instrument: row.toDomain(), mapping: mapping)
      }
    }
  }

  func registerCrypto(
    _ instrument: Instrument, mapping: CryptoProviderMapping
  ) async throws {
    precondition(instrument.kind == .cryptoToken)
    try await database.write { database in
      try Self.upsertCrypto(
        database: database, instrument: instrument, mapping: mapping)
    }
    onRecordChanged(instrument.id)
    await notifySubscribers()
  }

  func registerStock(_ instrument: Instrument) async throws {
    precondition(instrument.kind == .stock)
    try await database.write { database in
      try Self.upsertStock(database: database, instrument: instrument)
    }
    onRecordChanged(instrument.id)
    await notifySubscribers()
  }

  func remove(id: String) async throws {
    let didDelete = try await database.write { database -> Bool in
      let fiatKind = Instrument.Kind.fiatCurrency.rawValue
      guard
        let existing =
          try InstrumentRow
          .filter(InstrumentRow.Columns.id == id)
          .fetchOne(database)
      else { return false }
      guard existing.kind != fiatKind else { return false }
      return try InstrumentRow.deleteOne(database, key: id)
    }
    guard didDelete else { return }
    onRecordDeleted(id)
    await notifySubscribers()
  }

  // MARK: - Upsert helpers

  /// Inserts a new crypto row or updates the existing one in-place,
  /// preserving `recordName` and `encodedSystemFields`. Mirrors
  /// `CloudKitInstrumentRegistryRepository.upsertCrypto`.
  private static func upsertCrypto(
    database: Database,
    instrument: Instrument,
    mapping: CryptoProviderMapping
  ) throws {
    if var existing =
      try InstrumentRow
      .filter(InstrumentRow.Columns.id == instrument.id)
      .fetchOne(database)
    {
      existing.kind = instrument.kind.rawValue
      existing.name = instrument.name
      existing.decimals = instrument.decimals
      existing.ticker = instrument.ticker
      existing.exchange = instrument.exchange
      existing.chainId = instrument.chainId
      existing.contractAddress = instrument.contractAddress
      existing.coingeckoId = mapping.coingeckoId
      existing.cryptocompareSymbol = mapping.cryptocompareSymbol
      existing.binanceSymbol = mapping.binanceSymbol
      try existing.update(database)
    } else {
      var row = InstrumentRow(domain: instrument)
      row.coingeckoId = mapping.coingeckoId
      row.cryptocompareSymbol = mapping.cryptocompareSymbol
      row.binanceSymbol = mapping.binanceSymbol
      try row.insert(database)
    }
  }

  /// Inserts a new stock row or updates the existing one in-place. Stock
  /// upserts never touch the provider-mapping columns — they are written
  /// only by `registerCrypto`. Mirrors
  /// `CloudKitInstrumentRegistryRepository.upsertStock`.
  private static func upsertStock(
    database: Database,
    instrument: Instrument
  ) throws {
    if var existing =
      try InstrumentRow
      .filter(InstrumentRow.Columns.id == instrument.id)
      .fetchOne(database)
    {
      existing.kind = instrument.kind.rawValue
      existing.name = instrument.name
      existing.decimals = instrument.decimals
      existing.ticker = instrument.ticker
      existing.exchange = instrument.exchange
      try existing.update(database)
    } else {
      let row = InstrumentRow(domain: instrument)
      try row.insert(database)
    }
  }

  // MARK: - Change fan-out

  @MainActor
  func observeChanges() -> AsyncStream<Void> {
    let key = UUID()
    return AsyncStream { [weak self] continuation in
      guard let self else {
        continuation.finish()
        return
      }
      self.subscribers[key] = continuation
      continuation.onTermination = { @Sendable [weak self] _ in
        Task { @MainActor [weak self] in
          self?.subscribers.removeValue(forKey: key)
        }
      }
    }
  }

  @MainActor
  private func notifySubscribers() {
    for continuation in subscribers.values {
      continuation.yield()
    }
  }

  /// Yields a `Void` to every active `observeChanges()` subscriber
  /// without performing a local write. The sync layer calls this when a
  /// remote pull touches `InstrumentRow`s so picker UIs refresh without
  /// waiting for an app relaunch. Concrete-only — not part of the
  /// `InstrumentRegistryRepository` protocol because it is implementation
  /// plumbing, not a domain contract.
  @MainActor
  func notifyExternalChange() {
    notifySubscribers()
  }

  // MARK: - Sync entry points (synchronous, GRDB-queue-blocking)
  //
  // Called from the CKSyncEngine delegate executor on a non-MainActor
  // context. `DatabaseWriter.write { db in … }` has both async and sync
  // overloads; the sync form blocks the calling thread until the queue's
  // serial executor admits the closure. Never call these from
  // `@MainActor`.

  func applyRemoteChangesSync(saved rows: [InstrumentRow], deleted ids: [String]) throws {
    try database.write { database in
      for row in rows {
        try row.upsert(database)
      }
      for id in ids {
        _ = try InstrumentRow.deleteOne(database, key: id)
      }
    }
  }

  /// Writes (or clears) the cached system-fields blob on a single row.
  /// Returns `true` when a row was found and updated.
  @discardableResult
  func setEncodedSystemFieldsSync(id: String, data: Data?) throws -> Bool {
    try database.write { database in
      try InstrumentRow
        .filter(InstrumentRow.Columns.id == id)
        .updateAll(database, [InstrumentRow.Columns.encodedSystemFields.set(to: data)])
        > 0
    }
  }

  /// Clears `encoded_system_fields` on every row. Used after an
  /// `encryptedDataReset`.
  func clearAllSystemFieldsSync() throws {
    try database.write { database in
      _ =
        try InstrumentRow
        .updateAll(
          database,
          [InstrumentRow.Columns.encodedSystemFields.set(to: nil)])
    }
  }

  /// Returns IDs of rows whose `encoded_system_fields` is `NULL`.
  func unsyncedRowIdsSync() throws -> [String] {
    try database.read { database in
      try InstrumentRow
        .filter(InstrumentRow.Columns.encodedSystemFields == nil)
        .select(InstrumentRow.Columns.id, as: String.self)
        .fetchAll(database)
    }
  }

  /// Returns IDs of every row in the table.
  func allRowIdsSync() throws -> [String] {
    try database.read { database in
      try InstrumentRow
        .select(InstrumentRow.Columns.id, as: String.self)
        .fetchAll(database)
    }
  }

  /// Looks up a single row by id. Used by the per-record upload path in
  /// the sync handler.
  func fetchRowSync(id: String) throws -> InstrumentRow? {
    try database.read { database in
      try InstrumentRow
        .filter(InstrumentRow.Columns.id == id)
        .fetchOne(database)
    }
  }

  /// Batch lookup by ids — used by the batch-build phase of the sync
  /// handler.
  func fetchRowsSync(ids: [String]) throws -> [InstrumentRow] {
    let idSet = Set(ids)
    return try database.read { database in
      try InstrumentRow
        .filter(idSet.contains(InstrumentRow.Columns.id))
        .fetchAll(database)
    }
  }

  /// Deletes every row in the table. Used by `deleteLocalData` after a
  /// remote zone deletion.
  func deleteAllSync() throws {
    try database.write { database in
      _ = try InstrumentRow.deleteAll(database)
    }
  }
}
