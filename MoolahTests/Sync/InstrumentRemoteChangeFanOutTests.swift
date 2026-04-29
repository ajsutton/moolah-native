import CloudKit
import Foundation
import GRDB
import SwiftData
import Testing

@testable import Moolah

/// Verifies that `ProfileDataSyncHandler.applyRemoteChanges` fires the
/// `onInstrumentRemoteChange` closure whenever a remote pull touches an
/// `InstrumentRecord` row (either via upsert or via deletion), and only
/// then. This is the sync-side fan-out that lets the picker UI's
/// `observeChanges()` subscribers refresh after a token registered on
/// another device arrives — without it, the registry's notify path only
/// fires for local writes.
@Suite("ProfileDataSyncHandler — onInstrumentRemoteChange fan-out")
@MainActor
struct InstrumentRemoteChangeFanOutTests {

  // MARK: - Helpers

  /// Bundle returned by `makeHandler(fired:)` so call sites can keep a
  /// strong reference to the in-memory container and GRDB queue while
  /// the handler is in use. Replaces a four-tuple to satisfy
  /// SwiftLint's `large_tuple` policy.
  struct Harness {
    let handler: ProfileDataSyncHandler
    let container: ModelContainer
    let database: DatabaseQueue
  }

  /// Builds a handler whose `onInstrumentRemoteChange` closure increments
  /// the supplied `LockedBox<Int>` every time it fires.
  private func makeHandler(fired: LockedBox<Int>) throws -> Harness {
    let container = try TestModelContainer.create()
    let database = try ProfileDatabase.openInMemory()
    let profileId = UUID()
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName
    )
    let bundle = ProfileGRDBRepositories(
      csvImportProfiles: GRDBCSVImportProfileRepository(database: database),
      importRules: GRDBImportRuleRepository(database: database),
      instruments: GRDBInstrumentRegistryRepository(database: database),
      categories: GRDBCategoryRepository(database: database),
      accounts: GRDBAccountRepository(database: database),
      earmarks: GRDBEarmarkRepository(
        database: database, defaultInstrument: .defaultTestInstrument),
      earmarkBudgetItems: GRDBEarmarkBudgetItemRepository(database: database),
      investmentValues: GRDBInvestmentRepository(
        database: database, defaultInstrument: .defaultTestInstrument),
      transactions: GRDBTransactionRepository(
        database: database, defaultInstrument: .defaultTestInstrument,
        conversionService: FixedConversionService()),
      transactionLegs: GRDBTransactionLegRepository(database: database))
    let handler = ProfileDataSyncHandler(
      profileId: profileId,
      zoneID: zoneID,
      modelContainer: container,
      grdbRepositories: bundle,
      onInstrumentRemoteChange: {
        fired.set(fired.get() + 1)
      }
    )
    return Harness(handler: handler, container: container, database: database)
  }

  private func makeInstrumentRecord(
    id: String, in zoneID: CKRecordZone.ID
  ) -> CKRecord {
    let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
    let record = CKRecord(recordType: InstrumentRow.recordType, recordID: recordID)
    record["kind"] = "cryptoToken" as CKRecordValue
    record["name"] = "Uniswap" as CKRecordValue
    record["decimals"] = 18 as CKRecordValue
    record["coingeckoId"] = "uniswap" as CKRecordValue
    return record
  }

  private func makeAccountRecord(
    in zoneID: CKRecordZone.ID
  ) -> CKRecord {
    let accountId = UUID()
    let recordID = CKRecord.ID(
      recordType: AccountRow.recordType, uuid: accountId, zoneID: zoneID)
    let record = CKRecord(recordType: AccountRow.recordType, recordID: recordID)
    record["name"] = "Checking" as CKRecordValue
    record["type"] = "bank" as CKRecordValue
    record["position"] = 0 as CKRecordValue
    record["isHidden"] = 0 as CKRecordValue
    return record
  }

  // MARK: - Tests

  @Test("Remote upsert of an instrument fires the closure exactly once")
  func remoteUpsertOfInstrumentFiresClosure() throws {
    let fired = LockedBox(0)
    let handler = try makeHandler(fired: fired).handler
    let record = makeInstrumentRecord(id: "1:0xuni", in: handler.zoneID)

    let result = handler.applyRemoteChanges(saved: [record], deleted: [])

    guard case .success = result else {
      Issue.record("Expected .success but got \(result)")
      return
    }
    #expect(fired.get() == 1)
  }

  @Test("A multi-instrument batch still fires the closure exactly once")
  func multiInstrumentBatchFiresClosureOnce() throws {
    let fired = LockedBox(0)
    let handler = try makeHandler(fired: fired).handler
    let first = makeInstrumentRecord(id: "1:0xuni", in: handler.zoneID)
    let second = makeInstrumentRecord(id: "1:0xaave", in: handler.zoneID)

    _ = handler.applyRemoteChanges(saved: [first, second], deleted: [])

    #expect(fired.get() == 1)
  }

  @Test("Remote upsert of a non-instrument record does not fire the closure")
  func remoteUpsertOfNonInstrumentDoesNotFireClosure() throws {
    let fired = LockedBox(0)
    let handler = try makeHandler(fired: fired).handler
    let record = makeAccountRecord(in: handler.zoneID)

    _ = handler.applyRemoteChanges(saved: [record], deleted: [])

    #expect(fired.get() == 0)
  }

  @Test("Remote deletion of an instrument fires the closure exactly once")
  func remoteDeletionOfInstrumentFiresClosure() throws {
    let fired = LockedBox(0)
    let harness = try makeHandler(fired: fired)
    // Seed the row directly via GRDB (the handler reads exclusively
    // from `data.sqlite`); the SwiftData container is intentionally
    // bypassed here so the test verifies the GRDB-side delete.
    try harness.database.write { database in
      try InstrumentRow(
        domain: Instrument(
          id: "1:0xuni",
          kind: .cryptoToken,
          name: "Uniswap",
          decimals: 18,
          ticker: nil,
          exchange: nil,
          chainId: nil,
          contractAddress: nil)
      ).insert(database)
    }

    let recordID = CKRecord.ID(recordName: "1:0xuni", zoneID: harness.handler.zoneID)
    let result = harness.handler.applyRemoteChanges(
      saved: [],
      deleted: [(recordID, InstrumentRow.recordType)]
    )

    guard case .success = result else {
      Issue.record("Expected .success but got \(result)")
      return
    }
    #expect(fired.get() == 1)
    // Verify the row was actually deleted from the GRDB store.
    let remaining = try harness.database.read { database in
      try InstrumentRow.fetchAll(database)
    }
    #expect(remaining.isEmpty)
  }

  @Test("Remote deletion of a non-instrument record does not fire the closure")
  func remoteDeletionOfNonInstrumentDoesNotFireClosure() throws {
    let fired = LockedBox(0)
    let handler = try makeHandler(fired: fired).handler
    let recordID = CKRecord.ID(
      recordType: AccountRow.recordType, uuid: UUID(), zoneID: handler.zoneID)

    _ = handler.applyRemoteChanges(
      saved: [],
      deleted: [(recordID, AccountRow.recordType)]
    )

    #expect(fired.get() == 0)
  }
}
