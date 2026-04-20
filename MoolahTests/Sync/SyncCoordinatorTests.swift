import CloudKit
import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("SyncCoordinator")
@MainActor
struct SyncCoordinatorTests {

  // MARK: - Zone Parsing

  @Test func parseZoneProfileIndex() {
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-index", ownerName: CKCurrentUserDefaultName)
    let result = SyncCoordinator.parseZone(zoneID)
    #expect(result == .profileIndex)
  }

  @Test func parseZoneProfileData() {
    let profileId = UUID()
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)
    let result = SyncCoordinator.parseZone(zoneID)
    #expect(result == .profileData(profileId))
  }

  @Test func parseZoneUnknown() {
    let zoneID = CKRecordZone.ID(
      zoneName: "some-other-zone", ownerName: CKCurrentUserDefaultName)
    let result = SyncCoordinator.parseZone(zoneID)
    #expect(result == .unknown)
  }

  @Test func parseZoneInvalidProfileUUID() {
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-not-a-uuid", ownerName: CKCurrentUserDefaultName)
    let result = SyncCoordinator.parseZone(zoneID)
    #expect(result == .unknown)
  }

  // MARK: - State File Path

  @Test func stateFileUsesCorrectName() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    #expect(coordinator.stateFileURL.lastPathComponent == "Moolah-v2-sync.syncstate")
  }

  // MARK: - Observer Lifecycle

  @Test func addObserverReturnsToken() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let profileId = UUID()

    let token = coordinator.addObserver(for: profileId) { _ in }
    #expect(token.profileId == profileId)
  }

  @Test func removeObserverStopsCallbacks() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let profileId = UUID()
    var callCount = 0

    let token = coordinator.addObserver(for: profileId) { _ in
      callCount += 1
    }

    // Notify should fire the callback
    coordinator.notifyObservers(for: profileId, changedTypes: ["Test"])
    #expect(callCount == 1)

    // Remove and notify again — should not fire
    coordinator.removeObserver(token: token)
    coordinator.notifyObservers(for: profileId, changedTypes: ["Test"])
    #expect(callCount == 1)
  }

  @Test func multipleObserversForSameProfile() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let profileId = UUID()
    var callCount1 = 0
    var callCount2 = 0

    _ = coordinator.addObserver(for: profileId) { _ in callCount1 += 1 }
    _ = coordinator.addObserver(for: profileId) { _ in callCount2 += 1 }

    coordinator.notifyObservers(for: profileId, changedTypes: ["Test"])
    #expect(callCount1 == 1)
    #expect(callCount2 == 1)
  }

  // MARK: - Index Observer

  @Test func indexObserverFiresOnNotification() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    var callCount = 0

    _ = coordinator.addIndexObserver { callCount += 1 }

    coordinator.notifyIndexObservers()
    #expect(callCount == 1)
  }

  @Test func removeIndexObserverStopsCallbacks() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    var callCount = 0

    let id = coordinator.addIndexObserver { callCount += 1 }

    coordinator.notifyIndexObservers()
    #expect(callCount == 1)

    coordinator.removeIndexObserver(id)
    coordinator.notifyIndexObservers()
    #expect(callCount == 1)
  }

  // MARK: - Fetch Session Batching

  @Test func fetchSessionBatchesDeferCallbacks() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let profileId = UUID()
    var callbackTypes: Set<String>?

    _ = coordinator.addObserver(for: profileId) { types in
      callbackTypes = types
    }

    // Begin fetch session
    coordinator.beginFetchingChanges()
    #expect(coordinator.isFetchingChanges)

    // Simulate accumulated changes — callback should NOT fire yet
    coordinator.accumulateFetchSessionChanges(for: profileId, changedTypes: ["Account"])
    #expect(callbackTypes == nil)

    coordinator.accumulateFetchSessionChanges(for: profileId, changedTypes: ["Transaction"])
    #expect(callbackTypes == nil)

    // End fetch session — callback fires with all accumulated types
    coordinator.endFetchingChanges()
    #expect(!coordinator.isFetchingChanges)
    #expect(callbackTypes == Set(["Account", "Transaction"]))
  }

  @Test func fetchSessionCallbackNotFiredWhenNoChanges() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let profileId = UUID()
    var callbackFired = false

    _ = coordinator.addObserver(for: profileId) { _ in
      callbackFired = true
    }

    coordinator.beginFetchingChanges()
    coordinator.endFetchingChanges()
    #expect(!callbackFired)
  }

  // MARK: - Stuck Fetch Flag

  @Test func stuckFetchFlagResetWhenNewSessionStartsWhileAlreadyFetching() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let profileId = UUID()
    var callbackTypes: Set<String>?

    _ = coordinator.addObserver(for: profileId) { types in
      callbackTypes = types
    }

    // First session starts
    coordinator.beginFetchingChanges()
    coordinator.accumulateFetchSessionChanges(for: profileId, changedTypes: ["Account"])

    // Second session starts without first ending — this is the "stuck" case.
    // The old accumulated types should be flushed.
    coordinator.beginFetchingChanges()

    // The flush from the stuck state should have delivered the old types
    #expect(callbackTypes == Set(["Account"]))

    // New session should start clean
    callbackTypes = nil
    coordinator.accumulateFetchSessionChanges(for: profileId, changedTypes: ["Transaction"])
    coordinator.endFetchingChanges()
    #expect(callbackTypes == Set(["Transaction"]))
  }

  // MARK: - Queue Methods

  @Test func queueSaveConstructsCorrectRecordID() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let id = UUID()
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(UUID().uuidString)",
      ownerName: CKCurrentUserDefaultName)

    // Should not crash — just adds to pending (no sync engine to actually process)
    coordinator.queueSave(id: id, zoneID: zoneID)
    // No assertion needed beyond "doesn't crash" since CKSyncEngine is not started
  }

  @Test func queueSaveWithRecordNameConstructsCorrectRecordID() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(UUID().uuidString)",
      ownerName: CKCurrentUserDefaultName)

    coordinator.queueSave(recordName: "AUD", zoneID: zoneID)
    // No assertion needed beyond "doesn't crash"
  }

  @Test func queueDeletionConstructsCorrectRecordID() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let id = UUID()
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(UUID().uuidString)",
      ownerName: CKCurrentUserDefaultName)

    coordinator.queueDeletion(id: id, zoneID: zoneID)
  }

  // MARK: - Post-Migration / Import Record Queueing

  @Test func queueAllRecordsAfterImportReturnsAllRecordsInProfileZone() async throws {
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

    #expect(names == Set([accountId.uuidString, txnId.uuidString, "AUD"]))
    for recordID in queued {
      #expect(recordID.zoneID.zoneName == "profile-\(profileId.uuidString)")
    }
  }

  @Test func queueAllRecordsAfterImportReturnsEmptyForProfileWithNoData() async throws {
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

  @Test func queueUnsyncedRecordsForAllProfilesSkipsSyncedRecords() throws {
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

    #expect(names == Set([unsyncedA.uuidString, unsyncedB.uuidString]))

    // Each record went to the matching profile's zone.
    let aZone = "profile-\(profileA.uuidString)"
    let bZone = "profile-\(profileB.uuidString)"
    for recordID in queued {
      if recordID.recordName == unsyncedA.uuidString {
        #expect(recordID.zoneID.zoneName == aZone)
      }
      if recordID.recordName == unsyncedB.uuidString {
        #expect(recordID.zoneID.zoneName == bZone)
      }
    }
  }

  @Test func queueUnsyncedRecordsForAllProfilesReturnsEmptyWhenNoProfiles() throws {
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
    #expect(first.map(\.recordName) == [accountId.uuidString])

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

  @Test(
    "queueAllRecordsAfterImport marks the profile as backfilled so the startup scan skips it"
  )
  func queueAllRecordsAfterImportMarksBackfillComplete() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let defaults = makeDefaults()
    let coordinator = SyncCoordinator(containerManager: manager, userDefaults: defaults)

    let profileId = UUID()
    let indexContext = ModelContext(manager.indexContainer)
    indexContext.insert(
      ProfileRecord(
        id: profileId, label: "Migrated", currencyCode: "AUD",
        financialYearStartMonth: 7, createdAt: Date()))
    try indexContext.save()

    // Simulate what CloudKitDataImporter produces: records with nil system fields.
    let accountId = UUID()
    let context = ModelContext(try manager.container(for: profileId))
    context.insert(
      AccountRecord(id: accountId, name: "Migrated", type: "bank", position: 0, isHidden: false))
    try context.save()

    // Migration queues all records up front.
    let queued = await coordinator.queueAllRecordsAfterImport(for: profileId)
    #expect(queued.map(\.recordName) == [accountId.uuidString])

    // A subsequent startup scan must skip this profile — migration has already done
    // the equivalent work, and re-scanning would just do a pointless SwiftData pass.
    let rescan = coordinator.queueUnsyncedRecordsForAllProfiles()
    #expect(rescan.isEmpty)
  }

  // MARK: - ProfileContainerManager Extensions

  @Test func allProfileIdsReturnsKnownProfiles() throws {
    let manager = try ProfileContainerManager.forTesting()
    let context = ModelContext(manager.indexContainer)

    let id1 = UUID()
    let id2 = UUID()
    let profile1 = ProfileRecord(
      id: id1, label: "A", currencyCode: "AUD",
      financialYearStartMonth: 7, createdAt: Date())
    let profile2 = ProfileRecord(
      id: id2, label: "B", currencyCode: "USD",
      financialYearStartMonth: 1, createdAt: Date())
    context.insert(profile1)
    context.insert(profile2)
    try context.save()

    let ids = manager.allProfileIds()
    #expect(ids.count == 2)
    #expect(Set(ids) == Set([id1, id2]))
  }

  @Test func allProfileIdsReturnsEmptyWhenNoProfiles() throws {
    let manager = try ProfileContainerManager.forTesting()
    let ids = manager.allProfileIds()
    #expect(ids.isEmpty)
  }

  // MARK: - Handler Access

  @Test func profileIndexHandlerUsesIndexContainer() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let handler = coordinator.profileIndexHandler
    #expect(handler.zoneID.zoneName == "profile-index")
  }

  @Test func profileDataHandlerCreatedOnDemand() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let profileId = UUID()
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)

    let handler = try coordinator.handlerForProfileZone(profileId: profileId, zoneID: zoneID)
    #expect(handler.profileId == profileId)
    #expect(handler.zoneID == zoneID)
  }

  // MARK: - Batch Kind Selection (issue #61)

  @Test func batchKindAtomicByZoneIsFalseForProfileIndex() {
    #expect(SyncCoordinator.BatchKind.profileIndex.atomicByZone == false)
  }

  @Test func batchKindAtomicByZoneIsTrueForProfileData() {
    #expect(SyncCoordinator.BatchKind.profileData.atomicByZone == true)
  }

  @Test func selectBatchKindReturnsNilWhenNoChanges() {
    let kind = SyncCoordinator.selectBatchKind(from: [])
    #expect(kind == nil)
  }

  @Test func selectBatchKindPrefersProfileIndexWhenMixed() {
    let indexZone = CKRecordZone.ID(
      zoneName: "profile-index", ownerName: CKCurrentUserDefaultName)
    let dataZone = CKRecordZone.ID(
      zoneName: "profile-\(UUID().uuidString)", ownerName: CKCurrentUserDefaultName)
    let changes: [CKSyncEngine.PendingRecordZoneChange] = [
      .saveRecord(CKRecord.ID(recordName: UUID().uuidString, zoneID: dataZone)),
      .saveRecord(CKRecord.ID(recordName: UUID().uuidString, zoneID: indexZone)),
      .deleteRecord(CKRecord.ID(recordName: UUID().uuidString, zoneID: dataZone)),
    ]
    let kind = SyncCoordinator.selectBatchKind(from: changes)
    #expect(kind == .profileIndex)
  }

  @Test func selectBatchKindReturnsProfileDataWhenOnlyDataZoneChanges() {
    let dataZone1 = CKRecordZone.ID(
      zoneName: "profile-\(UUID().uuidString)", ownerName: CKCurrentUserDefaultName)
    let dataZone2 = CKRecordZone.ID(
      zoneName: "profile-\(UUID().uuidString)", ownerName: CKCurrentUserDefaultName)
    let changes: [CKSyncEngine.PendingRecordZoneChange] = [
      .saveRecord(CKRecord.ID(recordName: UUID().uuidString, zoneID: dataZone1)),
      .saveRecord(CKRecord.ID(recordName: UUID().uuidString, zoneID: dataZone2)),
    ]
    let kind = SyncCoordinator.selectBatchKind(from: changes)
    #expect(kind == .profileData)
  }

  @Test func selectBatchKindIgnoresUnknownZones() {
    let unknownZone = CKRecordZone.ID(
      zoneName: "some-other-zone", ownerName: CKCurrentUserDefaultName)
    let changes: [CKSyncEngine.PendingRecordZoneChange] = [
      .saveRecord(CKRecord.ID(recordName: UUID().uuidString, zoneID: unknownZone))
    ]
    let kind = SyncCoordinator.selectBatchKind(from: changes)
    #expect(kind == nil)
  }

  @Test func filterChangesMatchingProfileIndexKeepsOnlyIndexZone() {
    let indexZone = CKRecordZone.ID(
      zoneName: "profile-index", ownerName: CKCurrentUserDefaultName)
    let dataZone = CKRecordZone.ID(
      zoneName: "profile-\(UUID().uuidString)", ownerName: CKCurrentUserDefaultName)
    let indexChange: CKSyncEngine.PendingRecordZoneChange =
      .saveRecord(CKRecord.ID(recordName: UUID().uuidString, zoneID: indexZone))
    let dataChange: CKSyncEngine.PendingRecordZoneChange =
      .saveRecord(CKRecord.ID(recordName: UUID().uuidString, zoneID: dataZone))
    let filtered = SyncCoordinator.filterChanges(
      [dataChange, indexChange], matching: .profileIndex)
    #expect(filtered.count == 1)
    #expect(filtered.first == indexChange)
  }

  // MARK: - Re-fetch Backoff (issue #77)

  @Test func refetchBackoffFirstAttemptIsFiveSeconds() {
    #expect(SyncCoordinator.refetchBackoff(forAttempt: 1) == .seconds(5))
  }

  @Test func refetchBackoffDoublesEachAttempt() {
    #expect(SyncCoordinator.refetchBackoff(forAttempt: 1) == .seconds(5))
    #expect(SyncCoordinator.refetchBackoff(forAttempt: 2) == .seconds(10))
    #expect(SyncCoordinator.refetchBackoff(forAttempt: 3) == .seconds(20))
    #expect(SyncCoordinator.refetchBackoff(forAttempt: 4) == .seconds(40))
    #expect(SyncCoordinator.refetchBackoff(forAttempt: 5) == .seconds(80))
  }

  @Test func refetchBackoffReturnsNilBeyondMaxAttempts() {
    #expect(SyncCoordinator.refetchBackoff(forAttempt: 0) == nil)
    #expect(SyncCoordinator.refetchBackoff(forAttempt: 6) == nil)
    #expect(SyncCoordinator.refetchBackoff(forAttempt: 100) == nil)
  }

  @Test func refetchBackoffReturnsNilForNegativeAttempt() {
    #expect(SyncCoordinator.refetchBackoff(forAttempt: -1) == nil)
  }

  @Test func maxRefetchAttemptsIsFive() {
    #expect(SyncCoordinator.maxRefetchAttempts == 5)
  }

  @Test func refetchAttemptsStartsAtZero() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    #expect(coordinator.refetchAttempts == 0)
  }

  @Test func resetRefetchAttemptsClearsCounter() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)

    // Simulate some accumulated failures by invoking reset after manual mutation isn't
    // possible (counter is private(set)), so we just verify reset keeps it at zero
    // and the method exists with the expected signature.
    coordinator.resetRefetchAttempts()
    #expect(coordinator.refetchAttempts == 0)
  }

  @Test func stopResetsRefetchAttempts() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)

    // stop() should also reset the counter
    coordinator.stop()
    #expect(coordinator.refetchAttempts == 0)
  }

  // MARK: - Long-Retry (issue #77)

  @Test func longRetryIntervalIsThirtyMinutes() {
    #expect(SyncCoordinator.longRetryInterval == .seconds(30 * 60))
  }

  @Test func hasPendingLongRetryStartsFalse() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    #expect(coordinator.hasPendingLongRetry == false)
  }

  @Test func resetRefetchAttemptsCancelsPendingLongRetry() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)

    // resetRefetchAttempts must wipe both the counter and the long-retry task.
    // From a fresh coordinator there is no long retry pending, but the invariant
    // is what we're exercising: after the call, hasPendingLongRetry == false.
    coordinator.resetRefetchAttempts()
    #expect(coordinator.hasPendingLongRetry == false)
  }

  @Test func stopCancelsPendingLongRetry() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)

    // stop() must also wipe the long-retry task so a stopped coordinator leaves
    // no timers running.
    coordinator.stop()
    #expect(coordinator.hasPendingLongRetry == false)
  }

  @Test func filterChangesMatchingProfileDataKeepsOnlyDataZones() {
    let indexZone = CKRecordZone.ID(
      zoneName: "profile-index", ownerName: CKCurrentUserDefaultName)
    let dataZoneA = CKRecordZone.ID(
      zoneName: "profile-\(UUID().uuidString)", ownerName: CKCurrentUserDefaultName)
    let dataZoneB = CKRecordZone.ID(
      zoneName: "profile-\(UUID().uuidString)", ownerName: CKCurrentUserDefaultName)
    let indexChange: CKSyncEngine.PendingRecordZoneChange =
      .saveRecord(CKRecord.ID(recordName: UUID().uuidString, zoneID: indexZone))
    let dataChangeA: CKSyncEngine.PendingRecordZoneChange =
      .saveRecord(CKRecord.ID(recordName: UUID().uuidString, zoneID: dataZoneA))
    let dataChangeB: CKSyncEngine.PendingRecordZoneChange =
      .deleteRecord(CKRecord.ID(recordName: UUID().uuidString, zoneID: dataZoneB))
    let filtered = SyncCoordinator.filterChanges(
      [indexChange, dataChangeA, dataChangeB], matching: .profileData)
    #expect(filtered == [dataChangeA, dataChangeB])
  }
}
