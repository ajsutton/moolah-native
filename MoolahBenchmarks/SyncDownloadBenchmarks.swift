@preconcurrency import CloudKit
import SwiftData
import XCTest

@testable import Moolah

/// Benchmarks for the sync download path — `applyRemoteChanges` inserts and deletions.
///
/// These measure the cost of applying remote CKRecord changes to the local SwiftData store,
/// which is the hot path when syncing a large transaction history from another device.
final class SyncDownloadBenchmarks: XCTestCase {

  nonisolated(unsafe) private static var _container: ModelContainer?
  nonisolated(unsafe) private static var _handler: ProfileDataSyncHandler?
  nonisolated(unsafe) private static var _zoneID: CKRecordZone.ID?

  override static func setUp() {
    super.setUp()
    let result = expecting("benchmark TestBackend.create failed") {
      try TestBackend.create()
    }
    _container = result.container
    awaitSyncExpecting { @MainActor in
      BenchmarkFixtures.seed(scale: .twoX, in: result.container)
      let profileId = UUID()
      let zoneID = CKRecordZone.ID(
        zoneName: "profile-\(profileId.uuidString)",
        ownerName: CKCurrentUserDefaultName)
      let handler = ProfileDataSyncHandler(
        profileId: profileId, zoneID: zoneID, modelContainer: result.container)
      _handler = handler
      _zoneID = zoneID
    }
  }

  override static func tearDown() {
    _handler = nil
    _zoneID = nil
    _container = nil
    super.tearDown()
  }

  private var container: ModelContainer {
    guard let container = Self._container else {
      fatalError("setUp must initialise _container before tests run")
    }
    return container
  }
  private var handler: ProfileDataSyncHandler {
    guard let handler = Self._handler else {
      fatalError("setUp must initialise _handler before tests run")
    }
    return handler
  }
  private var zoneID: CKRecordZone.ID {
    guard let zoneID = Self._zoneID else {
      fatalError("setUp must initialise _zoneID before tests run")
    }
    return zoneID
  }

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
    let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    let record = CKRecord(recordType: TransactionRecord.recordType, recordID: recordID)
    record["date"] = Date() as CKRecordValue
    record["payee"] = "Sync Insert \(index)" as CKRecordValue
    return record
  }

  /// Builds a CKRecord for a transaction leg.
  private func makeFreshLegCKRecord(transactionId: UUID, index: Int) -> CKRecord {
    let instrument = Instrument.defaultTestInstrument
    let legId = UUID()
    let recordID = CKRecord.ID(recordName: legId.uuidString, zoneID: zoneID)
    let record = CKRecord(recordType: TransactionLegRecord.recordType, recordID: recordID)
    record["transactionId"] = transactionId.uuidString as CKRecordValue
    record["accountId"] = BenchmarkFixtures.heavyAccountId.uuidString as CKRecordValue
    record["instrumentId"] = instrument.id as CKRecordValue
    record["quantity"] =
      InstrumentAmount(
        quantity: Decimal(-(index + 1)), instrument: instrument
      ).storageValue as CKRecordValue
    record["type"] = TransactionType.expense.rawValue as CKRecordValue
    record["sortOrder"] = 0 as CKRecordValue
    return record
  }

  // MARK: - Benchmarks

  /// Applies 400 new transaction CKRecords with legs (insert path) into a 37k dataset.
  func testApplyRemoteChanges_400inserts() {
    let handler = handler
    measure(metrics: metrics, options: options) {
      var records: [CKRecord] = []
      records.reserveCapacity(800)
      for i in 0..<400 {
        let txnRecord = makeFreshTransactionCKRecord(index: i)
        let txnId = UUID(uuidString: txnRecord.recordID.recordName)!
        let legRecord = makeFreshLegCKRecord(transactionId: txnId, index: i)
        records.append(txnRecord)
        records.append(legRecord)
      }
      awaitSyncExpecting { @MainActor in
        _ = handler.applyRemoteChanges(saved: records, deleted: [])
      }
    }
  }

  /// Applies 400 deletion events into a 37k dataset.
  ///
  /// Re-seeds 400 transaction records before each measured iteration so the
  /// deletions always find live records to remove.
  func testApplyRemoteChanges_400deletions() {
    let handler = handler
    let container = self.container
    let zone = zoneID

    let clockOptions = XCTMeasureOptions()
    clockOptions.iterationCount = 10
    clockOptions.invocationOptions = [.manuallyStart, .manuallyStop]

    measure(metrics: [XCTClockMetric()], options: clockOptions) {
      // --- Setup (excluded from measurement) ---
      let deletionTargets: [(CKRecord.ID, String)] = awaitSyncExpecting { @MainActor in
        let context = ModelContext(container)
        var targets: [(CKRecord.ID, String)] = []
        targets.reserveCapacity(400)
        for _ in 0..<400 {
          let id = UUID()
          let record = TransactionRecord(
            id: id,
            date: Date(),
            payee: "Delete Target"
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
      awaitSyncExpecting { @MainActor in
        _ = handler.applyRemoteChanges(saved: [], deleted: deletionTargets)
      }
      self.stopMeasuring()
    }
  }
}
