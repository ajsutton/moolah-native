import SwiftData
import XCTest

@testable import Moolah

/// Benchmarks for balance delta calculation and store application.
///
/// Proves that the delta approach (applyDelta) is fast enough to run on every
/// transaction edit, while reload (reloadFromSync) is too expensive for that path.
final class BalanceDeltaBenchmarks: XCTestCase {

  nonisolated(unsafe) private static var _backend: CloudKitBackend!
  nonisolated(unsafe) private static var _container: ModelContainer!

  override class func setUp() {
    super.setUp()
    let result = try! TestBackend.create()
    _backend = result.backend
    _container = result.container
    try! awaitSync { @MainActor in
      BenchmarkFixtures.seed(scale: .x2, in: result.container)
    }
    // Pre-warm: load accounts so balances are computed from legs.
    _ = try! awaitSync { try await result.backend.accounts.fetchAll() }
  }

  override class func tearDown() {
    _backend = nil
    _container = nil
    super.tearDown()
  }

  private var backend: CloudKitBackend { Self._backend }
  private var container: ModelContainer { Self._container }

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
    let accountStore = try! awaitSync { @MainActor in
      let store = AccountStore(
        repository: Self._backend.accounts,
        conversionService: Self._backend.conversionService,
        targetInstrument: .AUD)
      await store.load()
      return store
    }
    let accountId = try! awaitSync { @MainActor in
      accountStore.currentAccounts.first!.id
    }
    measure(metrics: metrics, options: options) {
      try! awaitSync { @MainActor in
        let deltas: PositionDeltas = [accountId: [.AUD: Decimal(-50)]]
        for _ in 0..<100 {
          accountStore.applyDelta(deltas)
        }
      }
    }
  }

  /// Measures reloadFromSync on AccountStore — the expensive path that
  /// re-fetches everything. This is the baseline we're trying to avoid.
  func testAccountReloadFromSync() {
    let accountStore = try! awaitSync { @MainActor in
      let store = AccountStore(
        repository: Self._backend.accounts,
        conversionService: Self._backend.conversionService,
        targetInstrument: .AUD)
      await store.load()
      return store
    }
    measure(metrics: metrics, options: options) {
      try! awaitSync { @MainActor in
        await accountStore.reloadFromSync()
      }
    }
  }

  // MARK: - Earmark Store

  /// Measures reloadFromSync on EarmarkStore — how expensive the earmark reload is.
  func testEarmarkReloadFromSync() {
    let earmarkStore = try! awaitSync { @MainActor in
      let store = EarmarkStore(
        repository: Self._backend.earmarks,
        conversionService: Self._backend.conversionService,
        targetInstrument: .AUD)
      await store.load()
      return store
    }
    measure(metrics: metrics, options: options) {
      try! awaitSync { @MainActor in
        await earmarkStore.reloadFromSync()
      }
    }
  }
}
