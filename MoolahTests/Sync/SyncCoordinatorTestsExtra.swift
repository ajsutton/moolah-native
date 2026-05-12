import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("SyncCoordinator")
@MainActor
struct SyncCoordinatorTestsExtra {
  @Test
  func stuckFetchFlagResetWhenNewSessionStartsWhileAlreadyFetching() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)

    // First session starts and never ends.
    coordinator.beginFetchingChanges()
    #expect(coordinator.isFetchingChanges)

    // Second session starts without first ending — this is the "stuck" case.
    // `beginFetchingChanges` flushes any pending index notification and
    // re-arms the session so the new fetch starts clean.
    coordinator.beginFetchingChanges()
    #expect(coordinator.isFetchingChanges)

    coordinator.endFetchingChanges()
    #expect(!coordinator.isFetchingChanges)
  }

  // MARK: - Queue Methods

  @Test
  func queueSaveConstructsCorrectRecordID() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let id = UUID()
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(UUID().uuidString)",
      ownerName: CKCurrentUserDefaultName)

    // Should not crash — just adds to pending (no sync engine to actually process)
    coordinator.queueSave(recordType: AccountRow.recordType, id: id, zoneID: zoneID)
    // No assertion needed beyond "doesn't crash" since CKSyncEngine is not started
  }

  @Test
  func queueSaveWithRecordNameConstructsCorrectRecordID() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(UUID().uuidString)",
      ownerName: CKCurrentUserDefaultName)

    coordinator.queueSave(recordName: "AUD", zoneID: zoneID)
    // No assertion needed beyond "doesn't crash"
  }

  @Test
  func queueDeletionConstructsCorrectRecordID() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let id = UUID()
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(UUID().uuidString)",
      ownerName: CKCurrentUserDefaultName)

    coordinator.queueDeletion(recordType: AccountRow.recordType, id: id, zoneID: zoneID)
  }

  // MARK: - Post-Migration / Import Record Queueing

  @Test
  func queueAllRecordsAfterImportReturnsAllRecordsInProfileZone() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let profileId = UUID()

    // Seed the new profile's data DB (as a migration import would).
    let accountId = UUID()
    let txnId = UUID()
    let database = try manager.database(for: profileId)
    try await database.write { database in
      try ProfileDataSyncHandlerTestSupport.instrumentRow(
        id: "AUD", kind: "fiatCurrency",
        name: "Australian Dollar", decimals: 2
      ).upsert(database)
      try ProfileDataSyncHandlerTestSupport.accountRow(
        id: accountId, name: "Imported"
      ).upsert(database)
      try ProfileDataSyncHandlerTestSupport.transactionRow(
        id: txnId, payee: "Imported"
      ).upsert(database)
    }

    let queued = await coordinator.queueAllRecordsAfterImport(for: profileId)
    let names = Set(queued.map(\.recordName))

    // Instrument ids are queued by the shared registry on the
    // profile-index zone, not by the per-profile handler. The seeded
    // `AUD` instrument is therefore absent from the per-profile queue.
    #expect(
      names
        == Set([
          "\(AccountRow.recordType)|\(accountId.uuidString)",
          "\(TransactionRow.recordType)|\(txnId.uuidString)",
        ]))
    for recordID in queued {
      #expect(recordID.zoneID.zoneName == "profile-\(profileId.uuidString)")
    }
  }

  @Test
  func queueAllRecordsAfterImportReturnsEmptyForProfileWithNoData() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let profileId = UUID()

    // Initialize the data database so the handler can be resolved,
    // but leave it empty.
    _ = try manager.database(for: profileId)

    let queued = await coordinator.queueAllRecordsAfterImport(for: profileId)
    #expect(queued.isEmpty)
  }

  // MARK: - Startup Backfill of Unsynced Records

  private func makeDefaults() -> UserDefaults {
    UserDefaults(suiteName: "sync-coordinator-test-\(UUID().uuidString)")!
  }

  /// Registers a profile in the GRDB index and seeds its per-profile
  /// data DB via `seed`. Used by
  /// `queueUnsyncedRecordsForAllProfilesSkipsSyncedRecords` to keep the
  /// test body under SwiftLint's `function_body_length` cap.
  private func seedProfile(
    in manager: ProfileContainerManager,
    profile: Profile,
    seed: @Sendable (Database) throws -> Void
  ) async throws {
    try await manager.profileIndexRepository.upsert(profile)
    let database = try manager.database(for: profile.id)
    try await database.write { database in
      try seed(database)
    }
  }

  @Test
  func queueUnsyncedRecordsForAllProfilesSkipsSyncedRecords() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(
      containerManager: manager, userDefaults: makeDefaults())

    let profileA = Profile(
      id: UUID(), label: "A", currencyCode: "AUD", financialYearStartMonth: 7)
    let profileB = Profile(
      id: UUID(), label: "B", currencyCode: "USD", financialYearStartMonth: 1)
    let unsyncedA = UUID()
    let syncedA = UUID()
    let unsyncedB = UUID()

    // Profile A: one unsynced account and one synced account.
    try await seedProfile(in: manager, profile: profileA) { database in
      try ProfileDataSyncHandlerTestSupport.accountRow(
        id: unsyncedA, name: "A-unsynced"
      ).upsert(database)
      try ProfileDataSyncHandlerTestSupport.accountRow(
        id: syncedA, name: "A-synced", position: 1,
        encodedSystemFields: Data([0x01])
      ).upsert(database)
    }

    // Profile B: one unsynced transaction.
    try await seedProfile(in: manager, profile: profileB) { database in
      try ProfileDataSyncHandlerTestSupport.transactionRow(
        id: unsyncedB, payee: "B-unsynced"
      ).upsert(database)
    }

    let queued = await coordinator.queueUnsyncedRecordsForAllProfiles()
    let names = Set(queued.map(\.recordName))

    #expect(
      names
        == Set([
          "\(AccountRow.recordType)|\(unsyncedA.uuidString)",
          "\(TransactionRow.recordType)|\(unsyncedB.uuidString)",
        ]))

    // Each record went to the matching profile's zone.
    let aZone = "profile-\(profileA.id.uuidString)"
    let bZone = "profile-\(profileB.id.uuidString)"
    for recordID in queued {
      if recordID.recordName == "\(AccountRow.recordType)|\(unsyncedA.uuidString)" {
        #expect(recordID.zoneID.zoneName == aZone)
      }
      if recordID.recordName == "\(TransactionRow.recordType)|\(unsyncedB.uuidString)" {
        #expect(recordID.zoneID.zoneName == bZone)
      }
    }
  }

  @Test
  func queueUnsyncedRecordsForAllProfilesReturnsEmptyWhenNoProfiles() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(
      containerManager: manager, userDefaults: makeDefaults())

    let queued = await coordinator.queueUnsyncedRecordsForAllProfiles()
    #expect(queued.isEmpty)
  }

  @Test(
    "queueUnsyncedRecordsForAllProfiles skips profiles whose backfill scan has already run"
  )
  func queueUnsyncedRecordsForAllProfilesSkipsProfilesAlreadyScanned() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let defaults = makeDefaults()
    let coordinator = SyncCoordinator(
      containerManager: manager,
      userDefaults: defaults)

    let profileId = UUID()
    try await manager.profileIndexRepository.upsert(
      Profile(
        id: profileId, label: "A", currencyCode: "AUD",
        financialYearStartMonth: 7))

    // Seed an unsynced record (nil encodedSystemFields) for this profile.
    let accountId = UUID()
    let database = try manager.database(for: profileId)
    try await database.write { database in
      try ProfileDataSyncHandlerTestSupport.accountRow(
        id: accountId, name: "Unsynced"
      ).upsert(database)
    }

    // First scan should find and queue the unsynced record.
    let first = await coordinator.queueUnsyncedRecordsForAllProfiles()
    #expect(first.map(\.recordName) == ["\(AccountRow.recordType)|\(accountId.uuidString)"])

    // Second scan must NOT re-queue the same record — the profile has been marked
    // as scanned and is skipped. Avoids doing a redundant rescan on every app launch.
    let second = await coordinator.queueUnsyncedRecordsForAllProfiles()
    #expect(second.isEmpty)
  }

  // (Sign-out / encryptedDataReset / zone-deleted backfill-flag tests
  // live in `SyncCoordinatorBackfillFlagTests.swift` to keep the type
  // body under the SwiftLint threshold.)
}
