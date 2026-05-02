import CloudKit
import Foundation
import SwiftData
import Testing

@testable import Moolah

/// Regression tests for issue #619: a sync event for a profile whose
/// `ProfileSession` is not open must apply successfully. Before the fix,
/// `SyncCoordinator.handlerForProfileZone` threw
/// `SyncCoordinatorError.profileNotRegistered` and the apply path
/// trapped via `preconditionFailure`. After the fix, the coordinator
/// constructs the per-profile GRDB repositories on demand from
/// `containerManager.database(for:)`.
@Suite("SyncCoordinator — registration-free apply")
@MainActor
struct SyncCoordinatorRegistrationFreeTests {
  @Test("handlerForProfileZone constructs a handler when no bundle is registered")
  func handlerConstructedWithoutRegistration() throws {
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

  @Test("a second call returns the cached handler")
  func handlerCachedAcrossCalls() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let profileId = UUID()
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)

    let first = try coordinator.handlerForProfileZone(profileId: profileId, zoneID: zoneID)
    let second = try coordinator.handlerForProfileZone(profileId: profileId, zoneID: zoneID)

    #expect(first === second)
  }
}
