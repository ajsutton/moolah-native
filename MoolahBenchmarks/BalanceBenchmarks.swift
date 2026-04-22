import SwiftData
import XCTest

@testable import Moolah

/// Benchmarks for priorBalance computation in transaction fetch —
/// measures the full fetch path including the priorBalance reduction.
final class PriorBalanceBenchmarks: XCTestCase {

  nonisolated(unsafe) private static var _backend: CloudKitBackend!
  nonisolated(unsafe) private static var _container: ModelContainer!

  override static func setUp() {
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

  override static func tearDown() {
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

  /// Account fetchAll — computes balances by summing transaction legs per account.
  func testAccountFetchAll() {
    let repo = backend.accounts
    measure(metrics: metrics, options: options) {
      _ = try! awaitSync { try await repo.fetchAll() }
    }
  }

  /// Transaction fetch for the heaviest account — measures the priorBalance
  /// computation that sums all preceding legs.
  func testFetchHeavyAccountPriorBalance() {
    let repo = backend.transactions
    let filter = TransactionFilter(accountId: BenchmarkFixtures.heavyAccountId)
    measure(metrics: metrics, options: options) {
      _ = try! awaitSync { try await repo.fetch(filter: filter, page: 0, pageSize: 50) }
    }
  }
}
