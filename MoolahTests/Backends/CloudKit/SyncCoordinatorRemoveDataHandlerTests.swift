import CloudKit
import Foundation
import Testing

@testable import Moolah

/// Verifies `SyncCoordinator.removeDataHandler(for:)` evicts the per-profile
/// `ProfileDataSyncHandler` from the `dataHandlers` cache. `SessionManager`
/// calls this on mid-session teardown when a remote bump pushes the profile's
/// `dataFormatVersion` above `DataFormatVersion.current`, so the coordinator
/// stops routing further fetched changes for the per-profile zone — see
/// data-format-gate spec §4.2.
@Suite("SyncCoordinator — removeDataHandler")
@MainActor
struct SyncCoordinatorRemoveDataHandlerTests {
  @Test("removeDataHandler evicts the per-profile handler from dataHandlers")
  func removeDataHandlerEvictsHandler() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let profileId = UUID()
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)

    // Install a handler via the public registration pathway so the
    // dictionary state mirrors a live sync session.
    _ = try coordinator.handlerForProfileZone(profileId: profileId, zoneID: zoneID)
    #expect(coordinator.hasDataHandler(forProfile: profileId))

    coordinator.removeDataHandler(for: profileId)
    #expect(!coordinator.hasDataHandler(forProfile: profileId))
  }

  @Test("removeDataHandler is a no-op for an unknown profile id")
  func removeDataHandlerUnknownProfileIsNoOp() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let unknownProfileId = UUID()

    #expect(!coordinator.hasDataHandler(forProfile: unknownProfileId))
    coordinator.removeDataHandler(for: unknownProfileId)
    #expect(!coordinator.hasDataHandler(forProfile: unknownProfileId))
  }
}
