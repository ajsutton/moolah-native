@preconcurrency import CloudKit
import SwiftData
import XCTest

@testable import Moolah

/// Benchmarks for the sync upload path — `buildBatchRecordLookup` record resolution.
///
/// These measure the cost of building the UUID -> CKRecord lookup table that drives
/// outbound CKSyncEngine saves, which is the hot path when uploading a large batch
/// of local changes to CloudKit.
final class SyncUploadBenchmarks: XCTestCase {

  nonisolated(unsafe) private static var _container: ModelContainer!
  nonisolated(unsafe) private static var _handler: ProfileDataSyncHandler!
  nonisolated(unsafe) private static var _transactionUUIDs400: Set<UUID> = []

  override class func setUp() {
    super.setUp()
    let result = try! TestBackend.create()
    _container = result.container
    try! awaitSync { @MainActor in
      BenchmarkFixtures.seed(scale: .x2, in: result.container)
      let profileId = UUID()
      let zoneID = CKRecordZone.ID(
        zoneName: "profile-\(profileId.uuidString)",
        ownerName: CKCurrentUserDefaultName)
      _handler = ProfileDataSyncHandler(
        profileId: profileId, zoneID: zoneID, modelContainer: result.container)
      var descriptor = FetchDescriptor<TransactionRecord>()
      descriptor.fetchLimit = 400
      let records = try result.container.mainContext.fetch(descriptor)
      _transactionUUIDs400 = Set(records.map(\.id))
    }
  }

  override class func tearDown() {
    _handler = nil
    _container = nil
    _transactionUUIDs400 = []
    super.tearDown()
  }

  private var handler: ProfileDataSyncHandler { Self._handler }
  private var transactionUUIDs400: Set<UUID> { Self._transactionUUIDs400 }

  private var metrics: [XCTMetric] { [XCTClockMetric(), XCTMemoryMetric()] }
  private var options: XCTMeasureOptions {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 10
    return opts
  }

  // MARK: - Benchmarks

  /// Measures `buildBatchRecordLookup` for 400 transaction UUIDs in an 18k dataset.
  ///
  /// Uses IN-predicate batch fetches (6 queries total) rather than per-UUID sequential
  /// lookups (up to 2400 queries). All 400 UUIDs are existing transactions so the
  /// first fetch resolves all of them and the remaining 5 type queries are skipped.
  func testBuildBatchRecordLookup_400transactions() {
    let handler = handler
    let uuids = transactionUUIDs400
    measure(metrics: metrics, options: options) {
      _ = try! awaitSync { @MainActor in
        handler.buildBatchRecordLookup(for: uuids)
      }
    }
  }
}
