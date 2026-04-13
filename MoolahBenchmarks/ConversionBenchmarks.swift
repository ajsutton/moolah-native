import SwiftData
import XCTest

@testable import Moolah

/// Benchmarks for TransactionRecord.toDomain() conversion.
/// Isolates the per-record cost including Currency.from(code:) which allocates
/// a NumberFormatter on every call.
final class ConversionBenchmarks: XCTestCase {

  nonisolated(unsafe) private static var _records1k: [TransactionRecord] = []
  nonisolated(unsafe) private static var _records5k: [TransactionRecord] = []

  override class func setUp() {
    super.setUp()
    let result = try! TestBackend.create()
    try! awaitSync { @MainActor in
      BenchmarkFixtures.seed(scale: .x2, in: result.container)
      let context = result.container.mainContext
      var descriptor = FetchDescriptor<TransactionRecord>()
      descriptor.fetchLimit = 5000
      let all = try context.fetch(descriptor)
      _records1k = Array(all.prefix(1000))
      _records5k = all
    }
  }

  override class func tearDown() {
    _records1k = []
    _records5k = []
    super.tearDown()
  }

  private var metrics: [XCTMetric] { [XCTClockMetric(), XCTMemoryMetric()] }
  private var options: XCTMeasureOptions {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 10
    return opts
  }

  func testToDomain_1000records() {
    let records = Self._records1k
    measure(metrics: metrics, options: options) {
      autoreleasepool {
        _ = records.map { $0.toDomain() }
      }
    }
  }

  func testToDomain_5000records() {
    let records = Self._records5k
    measure(metrics: metrics, options: options) {
      autoreleasepool {
        _ = records.map { $0.toDomain() }
      }
    }
  }
}
