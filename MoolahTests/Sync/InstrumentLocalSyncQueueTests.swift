import Foundation
import GRDB
import Testing

@testable import Moolah

/// Pins the contract that local mutations which auto-insert non-fiat
/// `InstrumentRow`s into the `instrument` table also queue those records
/// for CloudKit upload. Without this, instruments created by paths that
/// don't go through `InstrumentRegistryRepository.registerStock /
/// registerCrypto` (e.g. SelfWealth CSV import or any
/// `transactionRepository.create` whose leg references a not-yet-known
/// stock) live only on the device that created them — sibling devices
/// see the legs but no `InstrumentRow`, fall back to
/// `Instrument.fiat(code: id)` in `fetchInstrumentMap`, and route stock
/// conversions through Frankfurter, which 404s.
@Suite("Local mutations queue auto-inserted instruments for sync")
@MainActor
struct InstrumentLocalSyncQueueTests {

  // MARK: - Capture helpers

  /// Confined to `@MainActor` so the (non-Sendable) closures wired to
  /// the repository can append into the buffer without crossing actors.
  @MainActor
  final class Capture {
    var instruments: [Instrument] = []
    /// Convenience for assertions that only care about identity.
    var instrumentIds: [String] { instruments.map(\.id) }
  }

  private func makeInstrumentChangedHook(
    _ capture: Capture
  ) -> @Sendable (Instrument) -> Void {
    { instrument in
      Task { @MainActor in
        capture.instruments.append(instrument)
      }
    }
  }

  /// Drains queued main-actor hops so callers can read the capture state
  /// after a repository write completes. Mirrors
  /// `RepositoryHookRecordTypeTests.drainHookHops`.
  private func drainHookHops() async throws {
    try await Task.sleep(for: .milliseconds(50))
  }

  private func makeStockInstrument(ticker: String) -> Instrument {
    Instrument.stock(ticker: "\(ticker).AX", exchange: "ASX", name: ticker)
  }

  private func makeStockLeg(
    instrument: Instrument,
    accountId: UUID,
    quantity: Decimal = 100
  ) -> TransactionLeg {
    TransactionLeg(
      accountId: accountId,
      instrument: instrument,
      quantity: quantity,
      type: .trade,
      categoryId: nil,
      earmarkId: nil)
  }

  // MARK: - GRDBTransactionRepository.create

  @Test("create fires onInstrumentChanged once for a new non-fiat leg instrument")
  func createFiresHookForNewStockLeg() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = Capture()
    let repo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      conversionService: FixedConversionService(),
      instrumentResolver: PerProfileInstrumentMapResolver(database: database),
      onInstrumentChanged: makeInstrumentChangedHook(capture))

    let stock = makeStockInstrument(ticker: "IFRA")
    let txn = Transaction(
      date: Date(), payee: "Buy IFRA",
      legs: [makeStockLeg(instrument: stock, accountId: UUID())])

    _ = try await repo.create(txn)
    try await drainHookHops()

    #expect(capture.instrumentIds == [stock.id])
  }

  @Test("create does not fire onInstrumentChanged for fiat legs")
  func createDoesNotFireHookForFiatLeg() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = Capture()
    let repo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      conversionService: FixedConversionService(),
      instrumentResolver: PerProfileInstrumentMapResolver(database: database),
      onInstrumentChanged: makeInstrumentChangedHook(capture))

    let txn = Transaction(
      date: Date(), payee: "Coffee",
      legs: [
        makeContractTestLeg(accountId: UUID(), quantity: -5, type: .expense)
      ])

    _ = try await repo.create(txn)
    try await drainHookHops()

    #expect(capture.instrumentIds.isEmpty)
  }

  @Test("create does not fire onInstrumentChanged when the instrument row already exists")
  func createDoesNotFireHookWhenInstrumentAlreadyRegistered() async throws {
    let database = try ProfileDatabase.openInMemory()
    let stock = makeStockInstrument(ticker: "VAS")
    try await database.write { database in
      try InstrumentRow(domain: stock).insert(database)
    }
    let capture = Capture()
    let repo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      conversionService: FixedConversionService(),
      instrumentResolver: PerProfileInstrumentMapResolver(database: database),
      onInstrumentChanged: makeInstrumentChangedHook(capture))

    let txn = Transaction(
      date: Date(), payee: "Buy VAS",
      legs: [makeStockLeg(instrument: stock, accountId: UUID())])

    _ = try await repo.create(txn)
    try await drainHookHops()

    #expect(capture.instrumentIds.isEmpty)
  }

  @Test("create dedupes the hook for two legs sharing one new instrument")
  func createDedupesHookForRepeatedInstrument() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = Capture()
    let repo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      conversionService: FixedConversionService(),
      instrumentResolver: PerProfileInstrumentMapResolver(database: database),
      onInstrumentChanged: makeInstrumentChangedHook(capture))

    let stock = makeStockInstrument(ticker: "VGS")
    let accountId = UUID()
    // Two legs on the same stock — only the first insert actually
    // writes the InstrumentRow; the hook should fire once, not twice.
    let txn = Transaction(
      date: Date(), payee: "Trade",
      legs: [
        makeStockLeg(instrument: stock, accountId: accountId, quantity: 10),
        makeStockLeg(instrument: stock, accountId: accountId, quantity: -5),
      ])

    _ = try await repo.create(txn)
    try await drainHookHops()

    #expect(capture.instrumentIds == [stock.id])
  }

  // MARK: - GRDBTransactionRepository.update

  @Test("update fires onInstrumentChanged for a new non-fiat instrument added to a leg")
  func updateFiresHookForNewlyAddedStockLeg() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = Capture()
    let repo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      conversionService: FixedConversionService(),
      instrumentResolver: PerProfileInstrumentMapResolver(database: database),
      onInstrumentChanged: makeInstrumentChangedHook(capture))

    // Seed a fiat-only transaction first.
    let accountId = UUID()
    let original = Transaction(
      date: Date(), payee: "Setup",
      legs: [
        makeContractTestLeg(accountId: accountId, quantity: -100, type: .expense)
      ])
    _ = try await repo.create(original)
    try await drainHookHops()
    capture.instruments.removeAll()

    // Replace with a stock leg, which should auto-insert the InstrumentRow
    // and fire the hook.
    let stock = makeStockInstrument(ticker: "IOZ")
    let updated = Transaction(
      id: original.id,
      date: original.date, payee: "Buy IOZ",
      legs: [makeStockLeg(instrument: stock, accountId: accountId)])
    _ = try await repo.update(updated)
    try await drainHookHops()

    #expect(capture.instrumentIds == [stock.id])
  }

  // MARK: - GRDBAccountRepository.create

  @Test("account create fires onInstrumentChanged for a new non-fiat account instrument")
  func accountCreateFiresHookForNewStockAccountInstrument() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = Capture()
    let repo = GRDBAccountRepository(
      database: database,
      instrumentResolver: PerProfileInstrumentMapResolver(database: database),
      onInstrumentChanged: makeInstrumentChangedHook(capture))

    let stock = makeStockInstrument(ticker: "VAP")
    let account = Account(name: "VAP Holdings", type: .investment, instrument: stock)

    _ = try await repo.create(account)
    try await drainHookHops()

    #expect(capture.instrumentIds == [stock.id])
  }

  @Test("account create does not fire onInstrumentChanged for fiat accounts")
  func accountCreateDoesNotFireHookForFiatAccount() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = Capture()
    let repo = GRDBAccountRepository(
      database: database,
      instrumentResolver: PerProfileInstrumentMapResolver(database: database),
      onInstrumentChanged: makeInstrumentChangedHook(capture))

    let account = Account(name: "Cash", type: .bank, instrument: .defaultTestInstrument)
    _ = try await repo.create(account)
    try await drainHookHops()

    #expect(capture.instrumentIds.isEmpty)
  }

  @Test("account create does not fire onInstrumentChanged when the row already exists")
  func accountCreateDoesNotFireHookWhenInstrumentAlreadyRegistered() async throws {
    let database = try ProfileDatabase.openInMemory()
    let stock = makeStockInstrument(ticker: "VGS")
    try await database.write { database in
      try InstrumentRow(domain: stock).insert(database)
    }
    let capture = Capture()
    let repo = GRDBAccountRepository(
      database: database,
      instrumentResolver: PerProfileInstrumentMapResolver(database: database),
      onInstrumentChanged: makeInstrumentChangedHook(capture))

    let account = Account(name: "VGS Holdings", type: .investment, instrument: stock)
    _ = try await repo.create(account)
    try await drainHookHops()

    #expect(capture.instrumentIds.isEmpty)
  }

  // MARK: - Reconciliation: existing unsynced non-fiat rows

  @Test("unsyncedNonFiatRowIdsSync returns non-fiat rows with null encoded_system_fields")
  func unsyncedNonFiatRowIdsSyncReturnsUnsyncedStocks() async throws {
    let database = try ProfileDatabase.openInMemory()
    let stock = Instrument.stock(ticker: "IFRA.AX", exchange: "ASX", name: "IFRA")
    try await database.write { database in
      try InstrumentRow(domain: stock).insert(database)
    }
    let registry = GRDBInstrumentRegistryRepository(database: database)

    let ids = try registry.unsyncedNonFiatRowIdsSync()

    #expect(ids == [stock.id])
  }

  @Test("unsyncedNonFiatRowIdsSync excludes rows whose encoded_system_fields is non-null")
  func unsyncedNonFiatRowIdsSyncExcludesSyncedRows() async throws {
    let database = try ProfileDatabase.openInMemory()
    let stock = Instrument.stock(ticker: "IOZ.AX", exchange: "ASX", name: "IOZ")
    try await database.write { database in
      var row = InstrumentRow(domain: stock)
      row.encodedSystemFields = Data(count: 4)  // sentinel: anything non-nil
      try row.insert(database)
    }
    let registry = GRDBInstrumentRegistryRepository(database: database)

    let ids = try registry.unsyncedNonFiatRowIdsSync()

    #expect(ids.isEmpty)
  }

  @Test("unsyncedNonFiatRowIdsSync excludes fiat rows even when unsynced")
  func unsyncedNonFiatRowIdsSyncExcludesFiat() async throws {
    let database = try ProfileDatabase.openInMemory()
    // Synthetic fiat rows aren't normally written, but the migration
    // boundary means a stale row might exist; the helper must filter
    // them out so the reconciliation pass doesn't try to upload AUD.
    try await database.write { database in
      try InstrumentRow(domain: .AUD).insert(database)
    }
    let registry = GRDBInstrumentRegistryRepository(database: database)

    let ids = try registry.unsyncedNonFiatRowIdsSync()

    #expect(ids.isEmpty)
  }
}
