import SwiftData
import XCTest

@testable import Moolah

/// Benchmarks for sync batch operations — upsert (download) and balance invalidation.
final class SyncBatchBenchmarks: XCTestCase {

  nonisolated(unsafe) private static var _container: ModelContainer!
  nonisolated(unsafe) private static var _existingIds400: [UUID] = []

  override class func setUp() {
    super.setUp()
    let result = try! TestBackend.create()
    _container = result.container
    try! awaitSync { @MainActor in
      BenchmarkFixtures.seed(scale: .x2, in: result.container)
      var descriptor = FetchDescriptor<TransactionRecord>()
      descriptor.fetchLimit = 400
      _existingIds400 = try result.container.mainContext.fetch(descriptor).map(\.id)
    }
  }

  override class func tearDown() {
    _container = nil
    _existingIds400 = []
    super.tearDown()
  }

  private var container: ModelContainer { Self._container }

  private var metrics: [XCTMetric] { [XCTClockMetric(), XCTMemoryMetric()] }
  private var options: XCTMeasureOptions {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 10
    return opts
  }

  /// Simulates upserting 400 NEW transaction records into an 18k dataset.
  func testBatchUpsert_insertHeavy() {
    let currency = Currency.defaultTestCurrency
    let container = self.container
    measure(metrics: metrics, options: options) {
      _ = try! awaitSync { @MainActor in
        let context = ModelContext(container)
        var newRecords: [TransactionRecord] = []
        for i in 0..<400 {
          newRecords.append(
            TransactionRecord(
              id: UUID(),
              type: TransactionType.expense.rawValue,
              date: Date(),
              accountId: BenchmarkFixtures.heavyAccountId,
              amount: -(i + 1) * 100,
              currencyCode: currency.code,
              payee: "Bench Insert \(i)"
            ))
        }
        let incomingIds = newRecords.map(\.id)
        let existing = try context.fetch(
          FetchDescriptor<TransactionRecord>(
            predicate: #Predicate { incomingIds.contains($0.id) }))
        var byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for record in newRecords {
          if byId[record.id] == nil {
            context.insert(record)
            byId[record.id] = record
          }
        }
        context.rollback()
      }
    }
  }

  /// Simulates upserting 400 EXISTING transaction records (update path).
  func testBatchUpsert_updateHeavy() {
    let existingIds = Self._existingIds400
    let container = self.container
    measure(metrics: metrics, options: options) {
      _ = try! awaitSync { @MainActor in
        let context = ModelContext(container)
        let matched = try context.fetch(
          FetchDescriptor<TransactionRecord>(
            predicate: #Predicate { existingIds.contains($0.id) }))
        let byId = Dictionary(uniqueKeysWithValues: matched.map { ($0.id, $0) })
        for id in existingIds {
          byId[id]?.payee = "Updated"
        }
        context.rollback()
      }
    }
  }

  /// Measures the balance invalidation sweep that follows a transaction sync.
  func testBalanceInvalidation() {
    let container = self.container
    measure(metrics: metrics, options: options) {
      _ = try! awaitSync { @MainActor in
        let context = ModelContext(container)
        let accounts = try context.fetch(FetchDescriptor<AccountRecord>())
        for account in accounts { account.cachedBalance = nil }
        context.rollback()
      }
    }
  }
}
