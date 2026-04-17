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
