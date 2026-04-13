@preconcurrency import CloudKit
import SwiftData
import XCTest

@testable import Moolah

/// Benchmarks for the sync download path — `applyRemoteChanges` inserts and deletions.
///
/// These measure the cost of applying remote CKRecord changes to the local SwiftData store,
/// which is the hot path when syncing a large transaction history from another device.
final class SyncDownloadBenchmarks: XCTestCase {

  nonisolated(unsafe) private static var _container: ModelContainer!
  nonisolated(unsafe) private static var _syncEngine: ProfileSyncEngine!
  nonisolated(unsafe) private static var _zoneID: CKRecordZone.ID!

  override class func setUp() {
    super.setUp()
    let result = try! TestBackend.create()
    _container = result.container
    try! awaitSync { @MainActor in
      BenchmarkFixtures.seed(scale: .x2, in: result.container)
      let profileId = UUID()
      let engine = ProfileSyncEngine(profileId: profileId, modelContainer: result.container)
      _syncEngine = engine
      _zoneID = engine.zoneID
    }
  }

  override class func tearDown() {
    _syncEngine = nil
    _zoneID = nil
    _container = nil
    super.tearDown()
  }

  private var container: ModelContainer { Self._container }
  private var syncEngine: ProfileSyncEngine { Self._syncEngine }
  private var zoneID: CKRecordZone.ID { Self._zoneID }

  private var metrics: [XCTMetric] { [XCTClockMetric(), XCTMemoryMetric()] }
  private var options: XCTMeasureOptions {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 10
    return opts
  }

  // MARK: - Helpers

  /// Builds a CKRecord for a new transaction with a fresh UUID.
  private func makeFreshTransactionCKRecord(index: Int) -> CKRecord {
    let id = UUID()
    let currency = Currency.defaultTestCurrency
    let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    let record = CKRecord(recordType: TransactionRecord.recordType, recordID: recordID)
    record["type"] = TransactionType.expense.rawValue as CKRecordValue
    record["date"] = Date() as CKRecordValue
    record["amount"] = (-(index + 1) * 100) as CKRecordValue
    record["currencyCode"] = currency.code as CKRecordValue
    record["accountId"] = BenchmarkFixtures.heavyAccountId.uuidString as CKRecordValue
    record["payee"] = "Sync Insert \(index)" as CKRecordValue
    return record
  }

  // MARK: - Benchmarks

  /// Applies 400 new transaction CKRecords (insert path) into an 18k dataset.
  ///
  /// Uses fresh UUIDs each iteration so every run exercises the insert code path
  /// rather than the update path (records must not already exist in the store).
  func testApplyRemoteChanges_400inserts() {
    let engine = syncEngine
    measure(metrics: metrics, options: options) {
      // Generate 400 fresh CKRecords with new UUIDs for this iteration.
      // Fresh UUIDs guarantee the insert path — no existing record to update.
      var records: [CKRecord] = []
      records.reserveCapacity(400)
      for i in 0..<400 {
        records.append(makeFreshTransactionCKRecord(index: i))
      }
      try! awaitSync { @MainActor in
        engine.applyRemoteChanges(saved: records, deleted: [])
      }
    }
  }

  /// Applies 400 deletion events into an 18k dataset.
  ///
  /// Re-seeds 400 transaction records before each measured iteration so the
  /// deletions always find live records to remove. Uses only `XCTClockMetric`
  /// with `startMeasuring`/`stopMeasuring` to exclude per-iteration setup time.
  /// (`XCTMemoryMetric` requires full-iteration measurement and cannot be scoped.)
  func testApplyRemoteChanges_400deletions() {
    let engine = syncEngine
    let container = self.container
    let zone = zoneID
    let currency = Currency.defaultTestCurrency

    let clockOptions = XCTMeasureOptions()
    clockOptions.iterationCount = 10
    clockOptions.invocationOptions = [.manuallyStart, .manuallyStop]

    measure(metrics: [XCTClockMetric()], options: clockOptions) {
      // --- Setup (excluded from measurement) ---
      // Insert 400 fresh transaction records and return their CKRecord.IDs for deletion.
      let deletionTargets: [(CKRecord.ID, String)] = try! awaitSync { @MainActor in
        let context = ModelContext(container)
        var targets: [(CKRecord.ID, String)] = []
        targets.reserveCapacity(400)
        for i in 0..<400 {
          let id = UUID()
          let record = TransactionRecord(
            id: id,
            type: TransactionType.expense.rawValue,
            date: Date(),
            accountId: BenchmarkFixtures.heavyAccountId,
            amount: -(i + 1) * 100,
            currencyCode: currency.code,
            payee: "Delete Target \(i)"
          )
          context.insert(record)
          let ckRecordID = CKRecord.ID(recordName: id.uuidString, zoneID: zone)
          targets.append((ckRecordID, TransactionRecord.recordType))
        }
        try context.save()
        return targets
      }

      // --- Measurement ---
      self.startMeasuring()
      try! awaitSync { @MainActor in
        engine.applyRemoteChanges(saved: [], deleted: deletionTargets)
      }
      self.stopMeasuring()
    }
  }
}
