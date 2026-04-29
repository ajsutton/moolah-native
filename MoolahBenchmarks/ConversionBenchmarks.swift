import GRDB
import XCTest

@testable import Moolah

/// Benchmarks for TransactionRow.toDomain() conversion.
/// Measures fetch + conversion together. In the multi-instrument model,
/// each transaction also requires fetching its associated leg rows.
final class ConversionBenchmarks: XCTestCase {

  nonisolated(unsafe) private static var _database: DatabaseQueue?

  override static func setUp() {
    super.setUp()
    let result = expecting("benchmark TestBackend.create failed") {
      try TestBackend.create()
    }
    _database = result.database
    BenchmarkFixtures.seed(scale: .twoX, in: result.database)
  }

  override static func tearDown() {
    _database = nil
    super.tearDown()
  }

  private var database: DatabaseQueue {
    guard let database = Self._database else {
      fatalError("setUp must initialise _database before tests run")
    }
    return database
  }

  private var metrics: [XCTMetric] { [XCTClockMetric(), XCTMemoryMetric()] }
  private var options: XCTMeasureOptions {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 10
    return opts
  }

  func testToDomain_1000records() {
    let database = self.database
    measure(metrics: metrics, options: options) {
      _ = awaitSyncExpecting {
        try await database.read { database in
          try Self.fetchAndConvert(database: database, limit: 1000)
        }
      }
    }
  }

  func testToDomain_5000records() {
    let database = self.database
    measure(metrics: metrics, options: options) {
      _ = awaitSyncExpecting {
        try await database.read { database in
          try Self.fetchAndConvert(database: database, limit: 5000)
        }
      }
    }
  }

  private static func fetchAndConvert(database: Database, limit: Int) throws -> [Transaction] {
    let rows = try TransactionRow.limit(limit).fetchAll(database)
    let txnIds = rows.map(\.id)
    let legRows =
      try TransactionLegRow
      .filter(txnIds.contains(TransactionLegRow.Columns.transactionId))
      .fetchAll(database)
    let legsByTxn = Dictionary(grouping: legRows, by: \.transactionId)
    return rows.map { row in
      let legs = (legsByTxn[row.id] ?? [])
        .sorted(by: { $0.sortOrder < $1.sortOrder })
        .map { $0.toDomain(instrument: Instrument.fiat(code: $0.instrumentId)) }
      return row.toDomain(legs: legs)
    }
  }
}
