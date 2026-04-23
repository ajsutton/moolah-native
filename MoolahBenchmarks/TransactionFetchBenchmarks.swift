import SwiftData
import XCTest

@testable import Moolah

/// Benchmarks for CloudKitTransactionRepository.fetch() at 1x scale (18k transactions).
/// Data is seeded once for the entire class to avoid repeated 3s seeding overhead.
final class TransactionFetchBenchmarks: XCTestCase {

  nonisolated(unsafe) private static var _backend: CloudKitBackend?
  nonisolated(unsafe) private static var _container: ModelContainer?

  override static func setUp() {
    super.setUp()
    let result = try! TestBackend.create()
    _backend = result.backend
    _container = result.container
    try! awaitSync { @MainActor in
      BenchmarkFixtures.seed(scale: .twoX, in: result.container)
    }
    // Pre-warm: load accounts so balances are computed from legs.
    _ = try! awaitSync { try await result.backend.accounts.fetchAll() }
  }

  override static func tearDown() {
    _backend = nil
    _container = nil
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

  /// Fetch page 0 for the busiest account (~7k transactions matching).
  func testFetchByAccount() {
    let repo = backend.transactions
    let filter = TransactionFilter(accountId: BenchmarkFixtures.heavyAccountId)
    measure(metrics: metrics, options: options) {
      _ = try! awaitSync { try await repo.fetch(filter: filter, page: 0, pageSize: 50) }
    }
  }

  /// Fetch all non-scheduled transactions (the default filter).
  func testFetchAllNonScheduled() {
    let repo = backend.transactions
    let filter = TransactionFilter(scheduled: false)
    measure(metrics: metrics, options: options) {
      _ = try! awaitSync { try await repo.fetch(filter: filter, page: 0, pageSize: 50) }
    }
  }

  /// Fetch with a date range (one year of transactions).
  func testFetchWithDateRange() {
    let repo = backend.transactions
    let oneYearAgo = Calendar.current.date(byAdding: .year, value: -1, to: Date())!
    let filter = TransactionFilter(
      accountId: BenchmarkFixtures.heavyAccountId,
      dateRange: oneYearAgo...Date()
    )
    measure(metrics: metrics, options: options) {
      _ = try! awaitSync { try await repo.fetch(filter: filter, page: 0, pageSize: 50) }
    }
  }

  /// Fetch with category filter (exercises the in-memory post-filter path).
  func testFetchWithCategoryFilter() {
    let repo = backend.transactions
    // Category namespace is 0x03 in BenchmarkFixtures.deterministicUUID
    let categoryIds: Set<UUID> = Set(
      (0..<5).map { index in
        UUID(uuidString: String(format: "03000000-BE00-4000-A000-%012X", index))!
      })
    let filter = TransactionFilter(
      accountId: BenchmarkFixtures.heavyAccountId,
      categoryIds: categoryIds
    )
    measure(metrics: metrics, options: options) {
      _ = try! awaitSync { try await repo.fetch(filter: filter, page: 0, pageSize: 50) }
    }
  }

  /// Fetch page 10 to measure offset/pagination cost.
  func testFetchDeepPagination() {
    let repo = backend.transactions
    let filter = TransactionFilter(accountId: BenchmarkFixtures.heavyAccountId)
    measure(metrics: metrics, options: options) {
      _ = try! awaitSync { try await repo.fetch(filter: filter, page: 10, pageSize: 50) }
    }
  }
}
