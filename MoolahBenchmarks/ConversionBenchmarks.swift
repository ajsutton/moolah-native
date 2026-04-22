import SwiftData
import XCTest

@testable import Moolah

/// Benchmarks for TransactionRecord.toDomain() conversion.
/// Measures fetch + conversion together since TransactionRecord is a managed
/// object that can't cross isolation boundaries. In the multi-instrument model,
/// each transaction also requires fetching its associated leg records.
final class ConversionBenchmarks: XCTestCase {

  nonisolated(unsafe) private static var _container: ModelContainer!

  override static func setUp() {
    super.setUp()
    let result = try! TestBackend.create()
    _container = result.container
    try! awaitSync { @MainActor in
      BenchmarkFixtures.seed(scale: .x2, in: result.container)
    }
  }

  override static func tearDown() {
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
        let txnIds = records.map(\.id)
        let legRecords = try container.mainContext.fetch(
          FetchDescriptor<TransactionLegRecord>(
            predicate: #Predicate { txnIds.contains($0.transactionId) }
          )
        )
        let legsByTxn = Dictionary(grouping: legRecords, by: \.transactionId)
        return records.map { record in
          let legs = (legsByTxn[record.id] ?? [])
            .sorted(by: { $0.sortOrder < $1.sortOrder })
            .map { $0.toDomain(instrument: Instrument.fiat(code: $0.instrumentId)) }
          return record.toDomain(legs: legs)
        }
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
        let txnIds = records.map(\.id)
        let legRecords = try container.mainContext.fetch(
          FetchDescriptor<TransactionLegRecord>(
            predicate: #Predicate { txnIds.contains($0.transactionId) }
          )
        )
        let legsByTxn = Dictionary(grouping: legRecords, by: \.transactionId)
        return records.map { record in
          let legs = (legsByTxn[record.id] ?? [])
            .sorted(by: { $0.sortOrder < $1.sortOrder })
            .map { $0.toDomain(instrument: Instrument.fiat(code: $0.instrumentId)) }
          return record.toDomain(legs: legs)
        }
      }
    }
  }
}
