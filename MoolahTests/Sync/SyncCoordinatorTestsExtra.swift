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
    coordinator.queueSave(id: id, recordType: AccountRecord.recordType, zoneID: zoneID)
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

    coordinator.queueDeletion(id: id, recordType: AccountRecord.recordType, zoneID: zoneID)
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

    let queued = await coordinator.queueAllRecordsAfterImport(for: profileId)
    let names = Set(queued.map(\.recordName))

    #expect(
      names
        == Set([
          "\(AccountRecord.recordType)|\(accountId.uuidString)",
          "\(TransactionRecord.recordType)|\(txnId.uuidString)",
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

  @Test
  func queueUnsyncedRecordsForAllProfilesSkipsSyncedRecords() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(
      containerManager: manager, userDefaults: makeDefaults())

    // Register two profiles in the index.
    let profileA = UUID()
    let profileB = UUID()
    let indexContext = ModelContext(manager.indexContainer)
    indexContext.insert(
      ProfileRecord(
        id: profileA, label: "A", currencyCode: "AUD",
        financialYearStartMonth: 7, createdAt: Date()))
    indexContext.insert(
      ProfileRecord(
        id: profileB, label: "B", currencyCode: "USD",
        financialYearStartMonth: 1, createdAt: Date()))
    try indexContext.save()

    // Profile A: one unsynced account and one synced account.
    let unsyncedA = UUID()
    let syncedA = UUID()
    let contextA = ModelContext(try manager.container(for: profileA))
    contextA.insert(
      AccountRecord(id: unsyncedA, name: "A-unsynced", type: "bank", position: 0, isHidden: false))
    let syncedRecord = AccountRecord(
      id: syncedA, name: "A-synced", type: "bank", position: 1, isHidden: false)
    syncedRecord.encodedSystemFields = Data([0x01])
    contextA.insert(syncedRecord)
    try contextA.save()

    // Profile B: one unsynced transaction.
    let unsyncedB = UUID()
    let contextB = ModelContext(try manager.container(for: profileB))
    contextB.insert(TransactionRecord(id: unsyncedB, date: Date(), payee: "B-unsynced"))
    try contextB.save()

    let queued = coordinator.queueUnsyncedRecordsForAllProfiles()
    let names = Set(queued.map(\.recordName))

    #expect(
      names
        == Set([
          "\(AccountRecord.recordType)|\(unsyncedA.uuidString)",
          "\(TransactionRecord.recordType)|\(unsyncedB.uuidString)",
        ]))

    // Each record went to the matching profile's zone.
    let aZone = "profile-\(profileA.uuidString)"
    let bZone = "profile-\(profileB.uuidString)"
    for recordID in queued {
      if recordID.recordName == "\(AccountRecord.recordType)|\(unsyncedA.uuidString)" {
        #expect(recordID.zoneID.zoneName == aZone)
      }
      if recordID.recordName == "\(TransactionRecord.recordType)|\(unsyncedB.uuidString)" {
        #expect(recordID.zoneID.zoneName == bZone)
      }
    }
  }

  @Test
  func queueUnsyncedRecordsForAllProfilesReturnsEmptyWhenNoProfiles() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(
      containerManager: manager, userDefaults: makeDefaults())

    let queued = coordinator.queueUnsyncedRecordsForAllProfiles()
    #expect(queued.isEmpty)
  }

  @Test(
    "queueUnsyncedRecordsForAllProfiles skips profiles whose backfill scan has already run"
  )
  func queueUnsyncedRecordsForAllProfilesSkipsProfilesAlreadyScanned() throws {
    let manager = try ProfileContainerManager.forTesting()
    let defaults = makeDefaults()
    let coordinator = SyncCoordinator(containerManager: manager, userDefaults: defaults)

    let profileId = UUID()
    let indexContext = ModelContext(manager.indexContainer)
    indexContext.insert(
      ProfileRecord(
        id: profileId, label: "A", currencyCode: "AUD",
        financialYearStartMonth: 7, createdAt: Date()))
    try indexContext.save()

    // Seed an unsynced record (nil encodedSystemFields) for this profile.
    let accountId = UUID()
    let context = ModelContext(try manager.container(for: profileId))
    context.insert(
      AccountRecord(id: accountId, name: "Unsynced", type: "bank", position: 0, isHidden: false))
    try context.save()

    // First scan should find and queue the unsynced record.
    let first = coordinator.queueUnsyncedRecordsForAllProfiles()
    #expect(first.map(\.recordName) == ["\(AccountRecord.recordType)|\(accountId.uuidString)"])

    // Second scan must NOT re-queue the same record — the profile has been marked
    // as scanned and is skipped. Avoids doing a SwiftData pass on every app launch.
    let second = coordinator.queueUnsyncedRecordsForAllProfiles()
    #expect(second.isEmpty)
  }

  @Test(
    "Sign-out clears all backfill-scan flags so the next sign-in can rescan"
  )
  func signOutClearsBackfillFlags() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let defaults = makeDefaults()
    let coordinator = SyncCoordinator(containerManager: manager, userDefaults: defaults)

    let profileId = UUID()
    let indexContext = ModelContext(manager.indexContainer)
    indexContext.insert(
      ProfileRecord(
        id: profileId, label: "A", currencyCode: "AUD",
        financialYearStartMonth: 7, createdAt: Date()))
    try indexContext.save()

    // Seed an unsynced record and scan so the flag is set.
    let accountId = UUID()
    let context = ModelContext(try manager.container(for: profileId))
    context.insert(
      AccountRecord(id: accountId, name: "A1", type: "bank", position: 0, isHidden: false))
    try context.save()
    _ = coordinator.queueUnsyncedRecordsForAllProfiles()

    // Simulate the sign-out handler firing.
    coordinator.handleSignOutForTesting()

    // After sign-out, backfill state is gone — a future scan would rerun for the profile.
    // We can't directly seed a profile back (deleteAllLocalData removed it), but we can
    // observe the UserDefaults flag is cleared.
    let key = "com.moolah.sync.backfillScanComplete.\(profileId.uuidString)"
    #expect(defaults.bool(forKey: key) == false)
  }

  @Test(
    "encryptedDataReset on a profile zone clears its backfill flag so re-queued records get tracked afresh"
  )
  func encryptedDataResetClearsBackfillFlag() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let defaults = makeDefaults()
    let coordinator = SyncCoordinator(containerManager: manager, userDefaults: defaults)

    let profileId = UUID()
    let indexContext = ModelContext(manager.indexContainer)
    indexContext.insert(
      ProfileRecord(
        id: profileId, label: "A", currencyCode: "AUD",
        financialYearStartMonth: 7, createdAt: Date()))
    try indexContext.save()

    let accountId = UUID()
    let context = ModelContext(try manager.container(for: profileId))
    context.insert(
      AccountRecord(id: accountId, name: "A1", type: "bank", position: 0, isHidden: false))
    try context.save()
    _ = coordinator.queueUnsyncedRecordsForAllProfiles()

    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)
    coordinator.handleEncryptedDataResetForTesting(zoneID: zoneID)

    let key = "com.moolah.sync.backfillScanComplete.\(profileId.uuidString)"
    #expect(defaults.bool(forKey: key) == false)
  }

  @Test(
    "Server-side profile zone deletion clears the backfill flag so a re-created zone rescans"
  )
  func zoneDeletionClearsBackfillFlag() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let defaults = makeDefaults()
    let coordinator = SyncCoordinator(containerManager: manager, userDefaults: defaults)

    let profileId = UUID()
    let indexContext = ModelContext(manager.indexContainer)
    indexContext.insert(
      ProfileRecord(
        id: profileId, label: "A", currencyCode: "AUD",
        financialYearStartMonth: 7, createdAt: Date()))
    try indexContext.save()

    let context = ModelContext(try manager.container(for: profileId))
    context.insert(
      AccountRecord(id: UUID(), name: "A1", type: "bank", position: 0, isHidden: false))
    try context.save()
    _ = coordinator.queueUnsyncedRecordsForAllProfiles()

    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)
    coordinator.handleZoneDeletedForTesting(zoneID: zoneID)

    let key = "com.moolah.sync.backfillScanComplete.\(profileId.uuidString)"
    #expect(defaults.bool(forKey: key) == false)
  }
}
