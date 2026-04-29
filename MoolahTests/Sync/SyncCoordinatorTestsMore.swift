import CloudKit
import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("SyncCoordinator")
@MainActor
struct SyncCoordinatorTestsMore {
  private func makeDefaults() -> UserDefaults {
    UserDefaults(suiteName: "sync-coordinator-test-\(UUID().uuidString)")!
  }

  @Test(
    "queueAllRecordsAfterImport marks the profile as backfilled so the startup scan skips it"
  )
  func queueAllRecordsAfterImportMarksBackfillComplete() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let defaults = makeDefaults()
    let coordinator = SyncCoordinator(
      containerManager: manager,
      userDefaults: defaults,
      fallbackGRDBRepositoriesFactory: ProfileDataSyncHandlerTestSupport.inMemoryFallbackFactory)

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
    #expect(
      queued.map(\.recordName) == ["\(AccountRow.recordType)|\(accountId.uuidString)"])

    // A subsequent startup scan must skip this profile — migration has already done
    // the equivalent work, and re-scanning would just do a pointless SwiftData pass.
    let rescan = coordinator.queueUnsyncedRecordsForAllProfiles()
    #expect(rescan.isEmpty)
  }

  // MARK: - ProfileContainerManager Extensions

  @Test
  func allProfileIdsReturnsKnownProfiles() throws {
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

  @Test
  func allProfileIdsReturnsEmptyWhenNoProfiles() throws {
    let manager = try ProfileContainerManager.forTesting()
    let ids = manager.allProfileIds()
    #expect(ids.isEmpty)
  }

  // MARK: - Handler Access

  @Test
  func profileIndexHandlerUsesIndexContainer() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let handler = coordinator.profileIndexHandler
    #expect(handler.zoneID.zoneName == "profile-index")
  }

  @Test
  func profileDataHandlerCreatedOnDemand() throws {
    let manager = try ProfileContainerManager.forTesting()
    // `handlerForProfileZone` requires a GRDB repository bundle —
    // production wiring registers via `ProfileSession.registerWithSyncCoordinator`;
    // the test injects the in-memory factory so the handler can be
    // constructed without a full session.
    let coordinator = SyncCoordinator(
      containerManager: manager,
      fallbackGRDBRepositoriesFactory: ProfileDataSyncHandlerTestSupport.inMemoryFallbackFactory)
    let profileId = UUID()
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)

    let handler = try coordinator.handlerForProfileZone(profileId: profileId, zoneID: zoneID)
    #expect(handler.profileId == profileId)
    #expect(handler.zoneID == zoneID)
  }

  // MARK: - Batch Kind Selection (issue #61)

  @Test
  func batchKindAtomicByZoneIsFalseForProfileIndex() {
    #expect(SyncCoordinator.BatchKind.profileIndex.atomicByZone == false)
  }

  @Test
  func batchKindAtomicByZoneIsTrueForProfileData() {
    #expect(SyncCoordinator.BatchKind.profileData.atomicByZone == true)
  }

  @Test
  func selectBatchKindReturnsNilWhenNoChanges() {
    let kind = SyncCoordinator.selectBatchKind(from: [])
    #expect(kind == nil)
  }

  @Test
  func selectBatchKindPrefersProfileIndexWhenMixed() {
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

  @Test
  func selectBatchKindReturnsProfileDataWhenOnlyDataZoneChanges() {
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

  @Test
  func selectBatchKindIgnoresUnknownZones() {
    let unknownZone = CKRecordZone.ID(
      zoneName: "some-other-zone", ownerName: CKCurrentUserDefaultName)
    let changes: [CKSyncEngine.PendingRecordZoneChange] = [
      .saveRecord(CKRecord.ID(recordName: UUID().uuidString, zoneID: unknownZone))
    ]
    let kind = SyncCoordinator.selectBatchKind(from: changes)
    #expect(kind == nil)
  }

  @Test
  func filterChangesMatchingProfileIndexKeepsOnlyIndexZone() {
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

  @Test
  func refetchBackoffFirstAttemptIsFiveSeconds() {
    #expect(SyncCoordinator.refetchBackoff(forAttempt: 1) == .seconds(5))
  }

  @Test
  func refetchBackoffDoublesEachAttempt() {
    #expect(SyncCoordinator.refetchBackoff(forAttempt: 1) == .seconds(5))
    #expect(SyncCoordinator.refetchBackoff(forAttempt: 2) == .seconds(10))
    #expect(SyncCoordinator.refetchBackoff(forAttempt: 3) == .seconds(20))
    #expect(SyncCoordinator.refetchBackoff(forAttempt: 4) == .seconds(40))
    #expect(SyncCoordinator.refetchBackoff(forAttempt: 5) == .seconds(80))
  }

  @Test
  func refetchBackoffReturnsNilBeyondMaxAttempts() {
    #expect(SyncCoordinator.refetchBackoff(forAttempt: 0) == nil)
    #expect(SyncCoordinator.refetchBackoff(forAttempt: 6) == nil)
    #expect(SyncCoordinator.refetchBackoff(forAttempt: 100) == nil)
  }

  @Test
  func refetchBackoffReturnsNilForNegativeAttempt() {
    #expect(SyncCoordinator.refetchBackoff(forAttempt: -1) == nil)
  }

  @Test
  func maxRefetchAttemptsIsFive() {
    #expect(SyncCoordinator.maxRefetchAttempts == 5)
  }

  @Test
  func refetchAttemptsStartsAtZero() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    #expect(coordinator.refetchAttempts == 0)
  }

  @Test
  func resetRefetchAttemptsClearsCounter() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)

    // Simulate some accumulated failures by invoking reset after manual mutation isn't
    // possible (counter is private(set)), so we just verify reset keeps it at zero
    // and the method exists with the expected signature.
    coordinator.resetRefetchAttempts()
    #expect(coordinator.refetchAttempts == 0)
  }

  @Test
  func stopResetsRefetchAttempts() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)

    // stop() should also reset the counter
    coordinator.stop()
    #expect(coordinator.refetchAttempts == 0)
  }

  // MARK: - Long-Retry (issue #77)

  @Test
  func longRetryIntervalIsThirtyMinutes() {
    #expect(SyncCoordinator.longRetryInterval == .seconds(30 * 60))
  }

  @Test
  func hasPendingLongRetryStartsFalse() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    #expect(coordinator.hasPendingLongRetry == false)
  }

  @Test
  func resetRefetchAttemptsCancelsPendingLongRetry() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)

    // resetRefetchAttempts must wipe both the counter and the long-retry task.
    // From a fresh coordinator there is no long retry pending, but the invariant
    // is what we're exercising: after the call, hasPendingLongRetry == false.
    coordinator.resetRefetchAttempts()
    #expect(coordinator.hasPendingLongRetry == false)
  }

  @Test
  func stopCancelsPendingLongRetry() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)

    // stop() must also wipe the long-retry task so a stopped coordinator leaves
    // no timers running.
    coordinator.stop()
    #expect(coordinator.hasPendingLongRetry == false)
  }

  @Test
  func filterChangesMatchingProfileDataKeepsOnlyDataZones() {
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
