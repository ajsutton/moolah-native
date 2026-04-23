import CloudKit
import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("SyncCoordinator")
@MainActor
struct SyncCoordinatorTests {

  // MARK: - Zone Parsing

  @Test
  func parseZoneProfileIndex() {
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-index", ownerName: CKCurrentUserDefaultName)
    let result = SyncCoordinator.parseZone(zoneID)
    #expect(result == .profileIndex)
  }

  @Test
  func parseZoneProfileData() {
    let profileId = UUID()
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)
    let result = SyncCoordinator.parseZone(zoneID)
    #expect(result == .profileData(profileId))
  }

  @Test
  func parseZoneUnknown() {
    let zoneID = CKRecordZone.ID(
      zoneName: "some-other-zone", ownerName: CKCurrentUserDefaultName)
    let result = SyncCoordinator.parseZone(zoneID)
    #expect(result == .unknown)
  }

  @Test
  func parseZoneInvalidProfileUUID() {
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-not-a-uuid", ownerName: CKCurrentUserDefaultName)
    let result = SyncCoordinator.parseZone(zoneID)
    #expect(result == .unknown)
  }

  // MARK: - State File Path

  @Test
  func stateFileUsesCorrectName() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    #expect(coordinator.stateFileURL.lastPathComponent == "Moolah-v2-sync.syncstate")
  }

  // MARK: - Observer Lifecycle

  @Test
  func addObserverReturnsToken() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let profileId = UUID()

    let token = coordinator.addObserver(for: profileId) { _ in }
    #expect(token.profileId == profileId)
  }

  @Test
  func removeObserverStopsCallbacks() throws {
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

  @Test
  func multipleObserversForSameProfile() throws {
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

  @Test
  func indexObserverFiresOnNotification() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    var callCount = 0

    _ = coordinator.addIndexObserver { callCount += 1 }

    coordinator.notifyIndexObservers()
    #expect(callCount == 1)
  }

  @Test
  func removeIndexObserverStopsCallbacks() throws {
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

  @Test
  func fetchSessionBatchesDeferCallbacks() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let profileId = UUID()
    var callbackInvocations: [Set<String>] = []

    _ = coordinator.addObserver(for: profileId) { types in
      callbackInvocations.append(types)
    }

    // Begin fetch session
    coordinator.beginFetchingChanges()
    #expect(coordinator.isFetchingChanges)

    // Simulate accumulated changes — callback should NOT fire yet
    coordinator.accumulateFetchSessionChanges(for: profileId, changedTypes: ["Account"])
    #expect(callbackInvocations.isEmpty)

    coordinator.accumulateFetchSessionChanges(for: profileId, changedTypes: ["Transaction"])
    #expect(callbackInvocations.isEmpty)

    // End fetch session — callback fires once with all accumulated types
    coordinator.endFetchingChanges()
    #expect(!coordinator.isFetchingChanges)
    #expect(callbackInvocations == [Set(["Account", "Transaction"])])
  }

  @Test
  func fetchSessionCallbackNotFiredWhenNoChanges() throws {
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
}
