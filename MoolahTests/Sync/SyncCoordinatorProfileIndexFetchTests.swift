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
}
