import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("SyncCoordinator — profileIndexFetchedAtLeastOnce")
@MainActor
struct SyncCoordinatorProfileIndexFetchTests {

  @Test("initial value is false")
  func initialValue() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(
      containerManager: manager,
      isCloudKitAvailable: true
    )
    #expect(coordinator.profileIndexFetchedAtLeastOnce == false)
  }

  @Test("fetchSessionTouchedIndexZone starts false on each beginFetchingChanges")
  func sessionFlagResetsOnBegin() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(
      containerManager: manager,
      isCloudKitAvailable: true
    )

    coordinator.beginFetchingChanges()
    coordinator.fetchSessionTouchedIndexZone = true
    coordinator.endFetchingChanges()

    coordinator.beginFetchingChanges()
    #expect(coordinator.fetchSessionTouchedIndexZone == false)
  }

  @Test("markZoneFetched flips session flag true for index zone")
  func touchedFlagSetOnIndexZone() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(
      containerManager: manager,
      isCloudKitAvailable: true
    )
    let indexZoneID = coordinator.profileIndexHandler.zoneID

    coordinator.beginFetchingChanges()
    coordinator.markZoneFetched(indexZoneID)
    #expect(coordinator.fetchSessionTouchedIndexZone == true)
  }

  @Test("markZoneFetched leaves session flag false for profile-data zone")
  func touchedFlagIgnoresDataZone() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(
      containerManager: manager,
      isCloudKitAvailable: true
    )
    let dataZoneID = CKRecordZone.ID(
      zoneName: "profile-\(UUID().uuidString)",
      ownerName: CKCurrentUserDefaultName
    )

    coordinator.beginFetchingChanges()
    coordinator.markZoneFetched(dataZoneID)
    #expect(coordinator.fetchSessionTouchedIndexZone == false)
  }

  @Test("markZoneFetched leaves session flag false for unknown zone")
  func touchedFlagIgnoresUnknownZone() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(
      containerManager: manager,
      isCloudKitAvailable: true
    )
    let unknownZoneID = CKRecordZone.ID(
      zoneName: "some-other-zone",
      ownerName: CKCurrentUserDefaultName
    )

    coordinator.beginFetchingChanges()
    coordinator.markZoneFetched(unknownZoneID)
    #expect(coordinator.fetchSessionTouchedIndexZone == false)
  }

  @Test("profileIndexFetchedAtLeastOnce flips after first session that touched index zone")
  func flipsOnFirstIndexSession() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(
      containerManager: manager,
      isCloudKitAvailable: true
    )
    let indexZoneID = coordinator.profileIndexHandler.zoneID

    coordinator.beginFetchingChanges()
    coordinator.markZoneFetched(indexZoneID)
    coordinator.endFetchingChanges()

    #expect(coordinator.profileIndexFetchedAtLeastOnce == true)
  }

  @Test("profileIndexFetchedAtLeastOnce stays false when only profile-data zones fetched")
  func staysFalseOnDataOnlySession() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(
      containerManager: manager,
      isCloudKitAvailable: true
    )
    let dataZoneID = CKRecordZone.ID(
      zoneName: "profile-\(UUID().uuidString)",
      ownerName: CKCurrentUserDefaultName
    )

    coordinator.beginFetchingChanges()
    coordinator.markZoneFetched(dataZoneID)
    coordinator.endFetchingChanges()

    #expect(coordinator.profileIndexFetchedAtLeastOnce == false)
  }

  @Test("profileIndexFetchedAtLeastOnce stays true once set")
  func remainsTrue() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(
      containerManager: manager,
      isCloudKitAvailable: true
    )
    let indexZoneID = coordinator.profileIndexHandler.zoneID
    let dataZoneID = CKRecordZone.ID(
      zoneName: "profile-\(UUID().uuidString)",
      ownerName: CKCurrentUserDefaultName
    )

    coordinator.beginFetchingChanges()
    coordinator.markZoneFetched(indexZoneID)
    coordinator.endFetchingChanges()

    coordinator.beginFetchingChanges()
    coordinator.markZoneFetched(dataZoneID)
    coordinator.endFetchingChanges()

    #expect(coordinator.profileIndexFetchedAtLeastOnce == true)
  }
}
