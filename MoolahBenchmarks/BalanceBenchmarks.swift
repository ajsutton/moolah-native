import SwiftData
import XCTest

@testable import Moolah

/// Benchmarks for account balance recomputation — measures fetchAll when all
/// cachedBalance values are nil, triggering recomputeAllBalances.
final class BalanceRecomputeBenchmarks: XCTestCase {

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

  /// Account fetchAll when all cachedBalance values are nil.
  /// Triggers recomputeAllBalances which sums transactions per account.
  func testAccountFetchAllWithInvalidatedBalances() {
    let repo = backend.accounts
    let container = self.container
    measure(metrics: metrics, options: options) {
      _ = try! awaitSync { @MainActor in
        let accounts = try container.mainContext.fetch(FetchDescriptor<AccountRecord>())
        for account in accounts { account.cachedBalance = nil }
        try container.mainContext.save()
      }
      _ = try! awaitSync { try await repo.fetchAll() }
    }
  }
}

/// Benchmarks for priorBalance computation in transaction fetch —
/// measures the full fetch path including the priorBalance reduction.
final class PriorBalanceBenchmarks: XCTestCase {

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
    // Trigger balance recomputation so cachedBalance is populated for the fast path.
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

  /// Transaction fetch for the heaviest account — measures the fast-path priorBalance
  /// computation that uses cachedBalance instead of loading all records.
  func testFetchHeavyAccountPriorBalance() {
    let repo = backend.transactions
    let filter = TransactionFilter(accountId: BenchmarkFixtures.heavyAccountId)
    measure(metrics: metrics, options: options) {
      _ = try! awaitSync { try await repo.fetch(filter: filter, page: 0, pageSize: 50) }
    }
  }
}
