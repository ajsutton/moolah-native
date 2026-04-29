@preconcurrency import CloudKit
import GRDB
import SwiftData
import XCTest

@testable import Moolah

/// Benchmarks for the sync upload path — `buildBatchRecordLookup` record resolution.
///
/// These measure the cost of building the UUID -> CKRecord lookup table that drives
/// outbound CKSyncEngine saves, which is the hot path when uploading a large batch
/// of local changes to CloudKit.
final class SyncUploadBenchmarks: XCTestCase {

  nonisolated(unsafe) private static var _container: ModelContainer?
  nonisolated(unsafe) private static var _database: DatabaseQueue?
  nonisolated(unsafe) private static var _handler: ProfileDataSyncHandler?
  nonisolated(unsafe) private static var _transactionUUIDs400: Set<UUID> = []

  override static func setUp() {
    super.setUp()
    let result = expecting("benchmark TestBackend.create failed") {
      try TestBackend.create()
    }
    _database = result.database
    BenchmarkFixtures.seed(scale: .twoX, in: result.database)
    let container = expecting("benchmark sync-handler container") {
      try TestModelContainer.create()
    }
    _container = container
    let profileId = UUID()
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)
    let bundle = ProfileGRDBRepositories(
      csvImportProfiles: result.backend.grdbCSVImportProfiles,
      importRules: result.backend.grdbImportRules,
      instruments: result.backend.grdbInstruments,
      categories: result.backend.grdbCategories,
      accounts: result.backend.grdbAccounts,
      earmarks: result.backend.grdbEarmarks,
      earmarkBudgetItems: result.backend.grdbEarmarkBudgetItems,
      investmentValues: result.backend.grdbInvestments,
      transactions: result.backend.grdbTransactions,
      transactionLegs: result.backend.grdbTransactionLegs)
    _handler = ProfileDataSyncHandler(
      profileId: profileId, zoneID: zoneID, modelContainer: container,
      grdbRepositories: bundle)
    let ids = expecting("benchmark fetch existing ids failed") {
      try result.database.read { database in
        try TransactionRow
          .limit(400)
          .fetchAll(database)
          .map(\.id)
      }
    }
    _transactionUUIDs400 = Set(ids)
  }

  override static func tearDown() {
    _handler = nil
    _container = nil
    _database = nil
    _transactionUUIDs400 = []
    super.tearDown()
  }

  private var handler: ProfileDataSyncHandler {
    guard let handler = Self._handler else {
      fatalError("setUp must initialise _handler before tests run")
    }
    return handler
  }
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
    let groups: [String: Set<UUID>] = [TransactionRow.recordType: uuids]
    measure(metrics: metrics, options: options) {
      _ = awaitSyncExpecting { @MainActor in
        handler.buildBatchRecordLookup(byRecordType: groups)
      }
    }
  }
}
