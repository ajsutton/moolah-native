import SwiftData
import XCTest

@testable import Moolah

/// Benchmarks for balance computation — both the priorBalance reduction in transaction
/// fetch and the full account fetchAll with invalidated cached balances.
final class BalanceBenchmarks: XCTestCase {

  nonisolated(unsafe) private static var _backend: CloudKitBackend!
  nonisolated(unsafe) private static var _container: ModelContainer!

  override class func setUp() {
    super.setUp()
    let result = try! TestBackend.create()
    _backend = result.backend
    _container = result.container
    try! awaitSync { @MainActor in
      BenchmarkFixtures.seed(scale: .x1, in: result.container)
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

  /// Transaction fetch for the heaviest account — implicitly measures priorBalance
  /// reduction since fetch() sums all transactions after the page.
  func testFetchHeavyAccountPriorBalance() {
    let repo = backend.transactions
    let filter = TransactionFilter(accountId: BenchmarkFixtures.heavyAccountId)
    measure(metrics: metrics, options: options) {
      _ = try! awaitSync { try await repo.fetch(filter: filter, page: 0, pageSize: 50) }
    }
  }
}
