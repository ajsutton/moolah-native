import CloudKit
import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("SyncCoordinator")
@MainActor
struct SyncCoordinatorTestsExtra {
  @Test
  func stuckFetchFlagResetWhenNewSessionStartsWhileAlreadyFetching() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let profileId = UUID()
    var callbackInvocations: [Set<String>] = []

    _ = coordinator.addObserver(for: profileId) { types in
      callbackInvocations.append(types)
    }

    // First session starts
    coordinator.beginFetchingChanges()
    coordinator.accumulateFetchSessionChanges(for: profileId, changedTypes: ["Account"])

    // Second session starts without first ending — this is the "stuck" case.
    // The old accumulated types should be flushed.
    coordinator.beginFetchingChanges()

    // The flush from the stuck state should have delivered the old types
    #expect(callbackInvocations == [Set(["Account"])])

    // New session should start clean
    callbackInvocations.removeAll()
    coordinator.accumulateFetchSessionChanges(for: profileId, changedTypes: ["Transaction"])
    coordinator.endFetchingChanges()
    #expect(callbackInvocations == [Set(["Transaction"])])
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

    // Seed the new profile's data container (as a migration import would).
    let dataContainer = try manager.container(for: profileId)
    let context = ModelContext(dataContainer)
    let accountId = UUID()
    let txnId = UUID()
    context.insert(
      AccountRecord(id: accountId, name: "Imported", type: "bank", position: 0, isHidden: false))
    context.insert(TransactionRecord(id: txnId, date: Date(), payee: "Imported"))
    context.insert(
      InstrumentRecord(
        id: "AUD", kind: "fiatCurrency", name: "Australian Dollar", decimals: 2))
    try context.save()
    let database = try manager.database(for: profileId)
    try ProfileDataSyncHandlerTestSupport.mirrorContainerToDatabase(
      container: dataContainer, database: database)

    let queued = await coordinator.queueAllRecordsAfterImport(for: profileId)
    let names = Set(queued.map(\.recordName))

    #expect(
      names
        == Set([
          "\(AccountRow.recordType)|\(accountId.uuidString)",
          "\(TransactionRow.recordType)|\(txnId.uuidString)",
          "AUD",
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

    // Initialize the data container so the handler can be resolved,
    // but leave it empty.
    _ = try manager.container(for: profileId)

    let queued = await coordinator.queueAllRecordsAfterImport(for: profileId)
    #expect(queued.isEmpty)
  }

  // MARK: - Startup Backfill of Unsynced Records

  private func makeDefaults() -> UserDefaults {
    UserDefaults(suiteName: "sync-coordinator-test-\(UUID().uuidString)")!
  }

  /// Registers a profile in the GRDB index, seeds its SwiftData container
  /// via `seed`, and mirrors the seeded rows into the per-profile GRDB
  /// queue. Used by `queueUnsyncedRecordsForAllProfilesSkipsSyncedRecords`
  /// to keep the test body under SwiftLint's `function_body_length` cap.
  private func seedProfile(
    in manager: ProfileContainerManager,
    profile: Profile,
    seed: (ModelContext) -> Void
  ) async throws {
    try await manager.profileIndexRepository.upsert(profile)
    let container = try manager.container(for: profile.id)
    let context = ModelContext(container)
    seed(context)
    try context.save()
    let database = try manager.database(for: profile.id)
    try ProfileDataSyncHandlerTestSupport.mirrorContainerToDatabase(
      container: container, database: database)
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
    try await seedProfile(in: manager, profile: profileA) { context in
      context.insert(
        AccountRecord(
          id: unsyncedA, name: "A-unsynced", type: "bank", position: 0, isHidden: false))
      let syncedRecord = AccountRecord(
        id: syncedA, name: "A-synced", type: "bank", position: 1, isHidden: false)
      syncedRecord.encodedSystemFields = Data([0x01])
      context.insert(syncedRecord)
    }

    // Profile B: one unsynced transaction.
    try await seedProfile(in: manager, profile: profileB) { context in
      context.insert(TransactionRecord(id: unsyncedB, date: Date(), payee: "B-unsynced"))
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
    let container = try manager.container(for: profileId)
    let context = ModelContext(container)
    context.insert(
      AccountRecord(id: accountId, name: "Unsynced", type: "bank", position: 0, isHidden: false))
    try context.save()
    let database = try manager.database(for: profileId)
    try ProfileDataSyncHandlerTestSupport.mirrorContainerToDatabase(
      container: container, database: database)

    // First scan should find and queue the unsynced record.
    let first = await coordinator.queueUnsyncedRecordsForAllProfiles()
    #expect(first.map(\.recordName) == ["\(AccountRow.recordType)|\(accountId.uuidString)"])

    // Second scan must NOT re-queue the same record — the profile has been marked
    // as scanned and is skipped. Avoids doing a SwiftData pass on every app launch.
    let second = await coordinator.queueUnsyncedRecordsForAllProfiles()
    #expect(second.isEmpty)
  }

  // (Sign-out / encryptedDataReset / zone-deleted backfill-flag tests
  // live in `SyncCoordinatorBackfillFlagTests.swift` to keep the type
  // body under the SwiftLint threshold.)
}
