// Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository.swift

import Foundation
import GRDB
import OSLog
import os

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
/// **`@unchecked Sendable` justification.** Has two mutable stored
/// properties: `subscribers` (the `@MainActor`-confined
/// AsyncStream-continuation map driving `observeChanges()`) and
/// `hooks` (the lock-guarded `HookState` swapped in by
/// `attachSyncHooks`). Both are race-free at runtime — see
/// `guides/CONCURRENCY_GUIDE.md` §2 "False Positives to Avoid",
/// Carve-out 3 (GRDB repositories).
final class GRDBInstrumentRegistryRepository:
  InstrumentRegistryRepository, @unchecked Sendable
{
  // `database` is `internal` rather than `private` so the sibling
  // extension file `GRDBInstrumentRegistryRepository+Lookup.swift` (which
  // hosts `cryptoRegistration(byId:)` to keep this file under SwiftLint's
  // length budgets) can read from it. The other stored properties remain
  // private — only the database handle is shared across files.
  /// Holds the post-init hook closures so they can be swapped in
  /// atomically by `attachSyncHooks`. Mirrors the pattern used by
  /// `GRDBProfileIndexRepository` — the shared registry is constructed
  /// at app boot before the `SyncCoordinator` exists, so the hooks
  /// arrive later via the lock-guarded swap.
  ///
  /// `internal` (default) so the sibling `+SyncHooks` extension file
  /// can declare `attachSyncHooks` over it.
  struct HookState {
    var onRecordChanged: @Sendable (String) -> Void
    var onRecordDeleted: @Sendable (String) -> Void
  }

  let database: any DatabaseWriter
  // `internal` (default) so the sibling `+SyncHooks` extension file
  // can read / mutate the lock-guarded hook closures. The lock itself
  // is the threading primitive; the property's visibility is module-
  // scoped because Swift extensions in separate files don't share
  // `private` access.
  let hooks: OSAllocatedUnfairLock<HookState>
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
    self.hooks = OSAllocatedUnfairLock(
      initialState: HookState(
        onRecordChanged: onRecordChanged,
        onRecordDeleted: onRecordDeleted))
  }

  // MARK: - Cross-extension internals
  //
  // `attachSyncHooks` and the `fireOnRecord*` helpers live in
  // `GRDBInstrumentRegistryRepository+SyncHooks.swift` so this file
  // stays under SwiftLint's `file_length` / `type_body_length`
  // thresholds. They access `hooks` directly via the `internal`
  // visibility implied by Swift's same-module-extension scope.

  // MARK: - InstrumentRegistryRepository conformance

  func all() async throws -> [Instrument] {
    let stored = try await database.read { database in
      try InstrumentRow.fetchAll(database).map { try $0.toDomain() }
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
      return try rows.compactMap { row in try Self.project(row: row) }
    }
  }

  // `cryptoRegistration(byId:)` lives in
  // `GRDBInstrumentRegistryRepository+Lookup.swift` to keep this file
  // under SwiftLint's `file_length` and `type_body_length` thresholds.

  func registerCrypto(
    _ instrument: Instrument, mapping: CryptoProviderMapping
  ) async throws {
    precondition(instrument.kind == .cryptoToken)
    try await database.write { database in
      try Self.upsertCrypto(
        database: database, instrument: instrument, mapping: mapping)
    }
    fireOnRecordChanged(instrument.id)
    await notifySubscribers()
  }

  func registerStock(_ instrument: Instrument) async throws {
    precondition(instrument.kind == .stock)
    try await database.write { database in
      try Self.upsertStock(database: database, instrument: instrument)
    }
    fireOnRecordChanged(instrument.id)
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
    fireOnRecordDeleted(id)
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
      for var row in rows {
        // Apply the field-level merge rule for `pricingStatus` before
        // upserting. CKSyncEngine's default "server wins" would let
        // the daily auto-resolver on one device clobber a `.spam`
        // classification a user made on another. The rule is
        // centralised in `PricingStatusMerge.merge` and unit-tested
        // against the full 3x3 truth table.
        //
        // Unrecognised raw values (only possible from a future-version
        // device sending an enum case this build doesn't compile against,
        // since legacy records that omit the field decode as `"priced"`
        // in `InstrumentRow+CloudKit.swift`) decode as `.priced`. That
        // matches the legacy fallback and keeps the merge defensive
        // rather than throwing.
        if let existing =
          try InstrumentRow
          .filter(InstrumentRow.Columns.id == row.id)
          .fetchOne(database)
        {
          let local = TokenPricingStatus(rawValue: existing.pricingStatus) ?? .priced
          let incoming = TokenPricingStatus(rawValue: row.pricingStatus) ?? .priced
          row.pricingStatus =
            PricingStatusMerge.merge(
              local: local, incoming: incoming
            ).rawValue
        }
        try row.upsert(database)
      }
      for id in ids {
        _ = try InstrumentRow.deleteOne(database, key: id)
      }
    }
  }

  /// Persists a new `pricingStatus` for the row identified by
  /// `registration.instrument.id`, leaving every other column unchanged.
  /// Used by `CryptoTokenStore.setStatus(_:for:)` to record a user-driven
  /// classification (`.spam` / `.priced` / `.unpriced`). Throws when no
  /// row is registered for the supplied instrument id — callers should
  /// have an existing registration in hand before calling.
  ///
  /// **Field coverage.** Only the `pricing_status` column is rewritten;
  /// `instrument` / `mapping` are read from `registration` purely to
  /// locate the row. To rewrite the provider mapping, call
  /// `registerCrypto(_:mapping:)` instead. Splitting the two surfaces
  /// keeps the cross-device merge rule (which only governs
  /// `pricing_status`) from having to reason about partial updates of
  /// other server-authoritative columns.
  ///
  /// Fires `onRecordChanged` and the `observeChanges()` fan-out on
  /// success so CKSyncEngine queues the record for upload and any picker
  /// UI refreshes.
  func update(_ registration: CryptoRegistration) async throws {
    let updated = try await database.write { database -> Bool in
      guard
        var existing =
          try InstrumentRow
          .filter(InstrumentRow.Columns.id == registration.instrument.id)
          .fetchOne(database)
      else { return false }
      existing.pricingStatus = registration.pricingStatus.rawValue
      try existing.update(database)
      return true
    }
    guard updated else {
      throw BackendError.notFound(
        "InstrumentRegistry: no row registered for id '\(registration.instrument.id)'"
      )
    }
    fireOnRecordChanged(registration.instrument.id)
    await notifySubscribers()
  }

  // The synchronous entry points used by `ProfileIndexSyncHandler`
  // (`setEncodedSystemFieldsSync`, `clearAllSystemFieldsSync`,
  // `unsyncedRowIdsSync`, `allRowIdsSync`, `fetchRowSync`,
  // `fetchRowsSync`, `deleteAllSync`) live in the sibling
  // `+SyncEntryPoints` extension file so this file stays under
  // SwiftLint's length thresholds.
  // `unsyncedNonFiatRowIdsSync` similarly lives in `+Lookup`.
}
