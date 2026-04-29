import GRDB
import XCTest

@testable import Moolah

/// Benchmarks for sync batch operations — upsert (download).
final class SyncBatchBenchmarks: XCTestCase {

  nonisolated(unsafe) private static var _database: DatabaseQueue?
  nonisolated(unsafe) private static var _existingIds400: [UUID] = []

  override static func setUp() {
    super.setUp()
    let result = expecting("benchmark TestBackend.create failed") {
      try TestBackend.create()
    }
    _database = result.database
    BenchmarkFixtures.seed(scale: .twoX, in: result.database)
    let ids = expecting("benchmark fetch existing ids failed") {
      try result.database.read { database in
        try TransactionRow
          .limit(400)
          .fetchAll(database)
          .map(\.id)
      }
    }
    _existingIds400 = ids
  }

  override static func tearDown() {
    _database = nil
    _existingIds400 = []
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

  /// Simulates upserting 400 NEW transaction rows into a 37k dataset.
  func testBatchUpsert_insertHeavy() {
    let database = self.database
    measure(metrics: metrics, options: options) {
      _ = try? database.write { database in
        try Self.runWithRollback(database: database) {
          try Self.insertBenchTransactions(database: database)
        }
      }
    }
  }

  /// Simulates upserting 400 EXISTING transaction rows (update path).
  func testBatchUpsert_updateHeavy() {
    let existingIds = Self._existingIds400
    let database = self.database
    measure(metrics: metrics, options: options) {
      _ = try? database.write { database in
        try Self.runWithRollback(database: database) {
          try Self.updateBenchTransactions(existingIds: existingIds, database: database)
        }
      }
    }
  }

  /// Wraps `block` in a SAVEPOINT so the dataset stays clean between
  /// iterations — matches the SwiftData benchmark's `context.rollback()`.
  private static func runWithRollback(
    database: Database,
    _ block: () throws -> Void
  ) throws {
    try database.execute(sql: "SAVEPOINT bench_savepoint")
    try block()
    try database.execute(sql: "ROLLBACK TO bench_savepoint")
    try database.execute(sql: "RELEASE bench_savepoint")
  }

  private static func insertBenchTransactions(database: Database) throws {
    let instrument = Instrument.defaultTestInstrument
    for i in 0..<400 {
      let txnId = UUID()
      let txnRow = TransactionRow(
        id: txnId,
        recordName: TransactionRow.recordName(for: txnId),
        date: Date(),
        payee: "Bench Insert \(i)",
        notes: nil,
        recurPeriod: nil,
        recurEvery: nil,
        importOriginRawDescription: nil,
        importOriginBankReference: nil,
        importOriginRawAmount: nil,
        importOriginRawBalance: nil,
        importOriginImportedAt: nil,
        importOriginImportSessionId: nil,
        importOriginSourceFilename: nil,
        importOriginParserIdentifier: nil,
        encodedSystemFields: nil)
      try txnRow.insert(database)
      let legId = UUID()
      let legRow = TransactionLegRow(
        id: legId,
        recordName: TransactionLegRow.recordName(for: legId),
        transactionId: txnId,
        accountId: BenchmarkFixtures.heavyAccountId,
        instrumentId: instrument.id,
        quantity: InstrumentAmount(
          quantity: Decimal(-(i + 1)), instrument: instrument
        ).storageValue,
        type: TransactionType.expense.rawValue,
        categoryId: nil,
        earmarkId: nil,
        sortOrder: 0,
        encodedSystemFields: nil)
      try legRow.insert(database)
    }
  }

  private static func updateBenchTransactions(
    existingIds: [UUID],
    database: Database
  ) throws {
    let matched =
      try TransactionRow
      .filter(existingIds.contains(TransactionRow.Columns.id))
      .fetchAll(database)
    var byId = Dictionary(uniqueKeysWithValues: matched.map { ($0.id, $0) })
    for id in existingIds {
      if var row = byId[id] {
        row.payee = "Updated"
        try row.update(database)
        byId[id] = row
      }
    }
  }
}
