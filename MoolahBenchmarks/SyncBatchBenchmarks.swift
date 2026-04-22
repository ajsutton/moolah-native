import SwiftData
import XCTest

@testable import Moolah

/// Benchmarks for sync batch operations — upsert (download).
final class SyncBatchBenchmarks: XCTestCase {

  nonisolated(unsafe) private static var _container: ModelContainer!
  nonisolated(unsafe) private static var _existingIds400: [UUID] = []

  override static func setUp() {
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

  override static func tearDown() {
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

  /// Simulates upserting 400 NEW transaction records into a 37k dataset.
  func testBatchUpsert_insertHeavy() {
    let instrument = Instrument.defaultTestInstrument
    let container = self.container
    measure(metrics: metrics, options: options) {
      _ = try! awaitSync { @MainActor in
        let context = ModelContext(container)
        for i in 0..<400 {
          let txnId = UUID()
          let txnRecord = TransactionRecord(
            id: txnId,
            date: Date(),
            payee: "Bench Insert \(i)"
          )
          context.insert(txnRecord)
          let leg = TransactionLegRecord(
            transactionId: txnId,
            accountId: BenchmarkFixtures.heavyAccountId,
            instrumentId: instrument.id,
            quantity: InstrumentAmount(
              quantity: Decimal(-(i + 1)), instrument: instrument
            ).storageValue,
            type: TransactionType.expense.rawValue,
            sortOrder: 0
          )
          context.insert(leg)
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
}
