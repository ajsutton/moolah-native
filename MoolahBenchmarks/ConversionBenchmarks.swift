import SwiftData
import XCTest

@testable import Moolah

/// Benchmarks for TransactionRecord.toDomain() conversion.
/// Measures fetch + conversion together since TransactionRecord is a managed
/// object that can't cross isolation boundaries. The fetch cost is small
/// relative to 5000x Currency.from(code:) calls.
final class ConversionBenchmarks: XCTestCase {

  nonisolated(unsafe) private static var _container: ModelContainer!

  override class func setUp() {
    super.setUp()
    let result = try! TestBackend.create()
    _container = result.container
    try! awaitSync { @MainActor in
      BenchmarkFixtures.seed(scale: .x2, in: result.container)
    }
  }

  override class func tearDown() {
    _container = nil
    super.tearDown()
  }

  private var container: ModelContainer { Self._container }

  private var metrics: [XCTMetric] { [XCTClockMetric(), XCTMemoryMetric()] }
  private var options: XCTMeasureOptions {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 10
    return opts
  }

  func testToDomain_1000records() {
    let container = self.container
    measure(metrics: metrics, options: options) {
      _ = try! awaitSync { @MainActor in
        var descriptor = FetchDescriptor<TransactionRecord>()
        descriptor.fetchLimit = 1000
        let records = try container.mainContext.fetch(descriptor)
        return records.map { $0.toDomain() }
      }
    }
  }

  func testToDomain_5000records() {
    let container = self.container
    measure(metrics: metrics, options: options) {
      _ = try! awaitSync { @MainActor in
        var descriptor = FetchDescriptor<TransactionRecord>()
        descriptor.fetchLimit = 5000
        let records = try container.mainContext.fetch(descriptor)
        return records.map { $0.toDomain() }
      }
    }
  }
}
