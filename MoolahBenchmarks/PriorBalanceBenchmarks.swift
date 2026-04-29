import GRDB
import XCTest

@testable import Moolah

/// Benchmarks for priorBalance computation in transaction fetch —
/// measures the full fetch path including the priorBalance reduction.
final class PriorBalanceBenchmarks: XCTestCase {

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

  private var metrics: [XCTMetric] { [XCTClockMetric(), XCTMemoryMetric()] }
  private var options: XCTMeasureOptions {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 10
    return opts
  }

  /// Account fetchAll — computes balances by summing transaction legs per account.
  func testAccountFetchAll() {
    let repo = backend.accounts
    measure(metrics: metrics, options: options) {
      _ = awaitSyncExpecting { try await repo.fetchAll() }
    }
  }

  /// Transaction fetch for the heaviest account — measures the priorBalance
  /// computation that sums all preceding legs.
  func testFetchHeavyAccountPriorBalance() {
    let repo = backend.transactions
    let filter = TransactionFilter(accountId: BenchmarkFixtures.heavyAccountId)
    measure(metrics: metrics, options: options) {
      _ = awaitSyncExpecting { try await repo.fetch(filter: filter, page: 0, pageSize: 50) }
    }
  }
}
