import SwiftData
import XCTest

@testable import Moolah

/// Benchmarks for AnalysisRepository — measures loadAll and fetchCategoryBalances
/// on a realistic x2-scale dataset (37k transactions, 62 accounts, 5k investment values).
final class AnalysisBenchmarks: XCTestCase {

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

  private var repo: CloudKitAnalysisRepository {
    guard let repo = backend.analysis as? CloudKitAnalysisRepository else {
      fatalError(
        "AnalysisBenchmarks requires CloudKitAnalysisRepository; "
          + "got \(type(of: backend.analysis))")
    }
    return repo
  }

  private var metrics: [XCTMetric] { [XCTClockMetric(), XCTMemoryMetric()] }
  private var options: XCTMeasureOptions {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 10
    return opts
  }

  /// loadAll with 12 months of history and 3 months of forecast.
  /// Exercises the full concurrent pipeline: daily balances, expense breakdown,
  /// income/expense — all computed off the main thread.
  func testLoadAll_12months() {
    let repo = self.repo
    let historyAfter = Calendar.current.date(byAdding: .month, value: -12, to: Date())!
    let forecastUntil = Calendar.current.date(byAdding: .month, value: 3, to: Date())!
    measure(metrics: metrics, options: options) {
      _ = try! awaitSync {
        try await repo.loadAll(
          historyAfter: historyAfter, forecastUntil: forecastUntil, monthEnd: 31)
      }
    }
  }

  /// loadAll with nil historyAfter — loads all 5 years of history.
  /// Measures the worst-case full-dataset analysis path.
  func testLoadAll_allHistory() {
    let repo = self.repo
    let forecastUntil = Calendar.current.date(byAdding: .month, value: 3, to: Date())!
    measure(metrics: metrics, options: options) {
      _ = try! awaitSync {
        try await repo.loadAll(historyAfter: nil, forecastUntil: forecastUntil, monthEnd: 31)
      }
    }
  }

  /// fetchCategoryBalances for a 12-month expense window with no additional filters.
  /// Measures the filter + group-by aggregation over the full transaction set.
  func testFetchCategoryBalances() {
    let repo = self.repo
    let end = Date()
    let start = Calendar.current.date(byAdding: .month, value: -12, to: end)!
    let dateRange = start...end
    measure(metrics: metrics, options: options) {
      _ = try! awaitSync {
        try await repo.fetchCategoryBalances(
          dateRange: dateRange, transactionType: .expense, filters: nil,
          targetInstrument: .defaultTestInstrument)
      }
    }
  }

  /// fetchCategoryBalancesByType — combined income+expense in a single pass.
  /// Should be faster than two separate fetchCategoryBalances calls.
  func testFetchCategoryBalancesByType() {
    let repo = self.repo
    let end = Date()
    let start = Calendar.current.date(byAdding: .month, value: -12, to: end)!
    let dateRange = start...end
    measure(metrics: metrics, options: options) {
      _ = try! awaitSync {
        try await repo.fetchCategoryBalancesByType(
          dateRange: dateRange, filters: nil,
          targetInstrument: .defaultTestInstrument)
      }
    }
  }
}
