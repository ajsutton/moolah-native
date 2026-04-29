import GRDB
import XCTest

@testable import Moolah

/// Benchmarks for balance delta calculation and store application.
///
/// Proves that the delta approach (applyDelta) is fast enough to run on every
/// transaction edit, while reload (reloadFromSync) is too expensive for that path.
final class BalanceDeltaBenchmarks: XCTestCase {

  nonisolated(unsafe) private static var _backend: CloudKitBackend?
  nonisolated(unsafe) private static var _database: DatabaseQueue?

  override static func setUp() {
    super.setUp()
    let result = expecting("benchmark TestBackend.create failed") {
      try TestBackend.create()
    }
    _backend = result.backend
    _database = result.database
    BenchmarkFixtures.seed(scale: .twoX, in: result.database)
    // Pre-warm: load accounts so balances are computed from legs.
    _ = awaitSyncExpecting { try await result.backend.accounts.fetchAll() }
  }

  override static func tearDown() {
    _backend = nil
    _database = nil
    super.tearDown()
  }

  private var backend: CloudKitBackend {
    guard let backend = Self._backend else {
      fatalError("setUp must initialise _backend before tests run")
    }
    return backend
  }
  private var database: DatabaseQueue {
    guard let database = Self._database else {
      fatalError("setUp must initialise _database before tests run")
    }
    return database
  }

  private var metrics: [XCTMetric] { [XCTClockMetric(), XCTMemoryMetric()] }
  private var options: XCTMeasureOptions {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 10
    return opts
  }

  // MARK: - Delta Calculator

  /// Measures delta calculation for a single-leg expense (create).
  /// Runs 10,000 iterations to get meaningful numbers since each call is sub-microsecond.
  func testDeltaCalculatorSingleLeg() {
    let instrument = Instrument.defaultTestInstrument
    let accountId = BenchmarkFixtures.heavyAccountId
    let transaction = Transaction(
      date: Date(),
      payee: "Benchmark Expense",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: instrument,
          quantity: Decimal(-42),
          type: .expense
        )
      ]
    )

    measure(metrics: metrics, options: options) {
      for _ in 0..<10_000 {
        _ = BalanceDeltaCalculator.deltas(old: nil, new: transaction)
      }
    }
  }

  /// Measures delta calculation for an update with 3-leg old and 3-leg new transaction
  /// (worst case: different accounts, instruments, earmarks).
  /// Runs 10,000 iterations.
  func testDeltaCalculatorMultiLeg() {
    let aud = Instrument.defaultTestInstrument
    let usd = Instrument.USD
    let accountA = UUID()
    let accountB = UUID()
    let accountC = UUID()
    let earmarkA = UUID()
    let earmarkB = UUID()

    let oldTransaction = Transaction(
      date: Date(),
      payee: "Old Multi-Leg",
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: aud, quantity: Decimal(-100),
          type: .expense, earmarkId: earmarkA),
        TransactionLeg(
          accountId: accountB, instrument: aud, quantity: Decimal(-200),
          type: .expense),
        TransactionLeg(
          accountId: accountC, instrument: usd, quantity: Decimal(-50),
          type: .expense, earmarkId: earmarkB),
      ]
    )

    let newTransaction = Transaction(
      date: Date(),
      payee: "New Multi-Leg",
      legs: [
        TransactionLeg(
          accountId: accountB, instrument: aud, quantity: Decimal(-150),
          type: .expense, earmarkId: earmarkA),
        TransactionLeg(
          accountId: accountC, instrument: usd, quantity: Decimal(-75),
          type: .expense, earmarkId: earmarkB),
        TransactionLeg(
          accountId: accountA, instrument: aud, quantity: Decimal(-300),
          type: .income),
      ]
    )

    measure(metrics: metrics, options: options) {
      for _ in 0..<10_000 {
        _ = BalanceDeltaCalculator.deltas(old: oldTransaction, new: newTransaction)
      }
    }
  }

  // MARK: - Account Store

  /// Measures applyDelta on AccountStore with a realistic account set.
  /// Applies a single-account, single-instrument delta 100 times per iteration.
  func testAccountStoreApplyDelta() {
    let backend = self.backend
    let accountStore = awaitSyncExpecting { @MainActor in
      let store = AccountStore(
        repository: backend.accounts,
        conversionService: backend.conversionService,
        targetInstrument: .AUD)
      await store.load()
      return store
    }
    let accountId = awaitSyncExpecting { @MainActor in
      accountStore.currentAccounts.first!.id
    }
    measure(metrics: metrics, options: options) {
      awaitSyncExpecting { @MainActor in
        let deltas: PositionDeltas = [accountId: [.AUD: Decimal(-50)]]
        for _ in 0..<100 {
          await accountStore.applyDelta(deltas)
        }
      }
    }
  }

  /// Measures reloadFromSync on AccountStore — the expensive path that
  /// re-fetches everything. This is the baseline we're trying to avoid.
  func testAccountReloadFromSync() {
    let backend = self.backend
    let accountStore = awaitSyncExpecting { @MainActor in
      let store = AccountStore(
        repository: backend.accounts,
        conversionService: backend.conversionService,
        targetInstrument: .AUD)
      await store.load()
      return store
    }
    measure(metrics: metrics, options: options) {
      awaitSyncExpecting { @MainActor in
        await accountStore.reloadFromSync()
      }
    }
  }

  // MARK: - Earmark Store

  /// Measures reloadFromSync on EarmarkStore — how expensive the earmark reload is.
  func testEarmarkReloadFromSync() {
    let backend = self.backend
    let earmarkStore = awaitSyncExpecting { @MainActor in
      let store = EarmarkStore(
        repository: backend.earmarks,
        conversionService: backend.conversionService,
        targetInstrument: .AUD)
      await store.load()
      return store
    }
    measure(metrics: metrics, options: options) {
      awaitSyncExpecting { @MainActor in
        await earmarkStore.reloadFromSync()
      }
    }
  }
}
