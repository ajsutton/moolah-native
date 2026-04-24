import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("SyncCoordinator — iCloudAvailability")
@MainActor
struct SyncCoordinatorICloudAvailabilityTests {

  @Test("initial state is .unknown before start (entitlements present)")
  func initialState() throws {
    let manager = try ProfileContainerManager.forTesting()
    // Force entitlements "available" — in test builds CLOUDKIT_ENABLED is
    // unset, which would otherwise synchronously flip state to
    // `.unavailable(.entitlementsMissing)`.
    let coordinator = SyncCoordinator(
      containerManager: manager,
      isCloudKitAvailable: true
    )
    #expect(coordinator.iCloudAvailability == .unknown)
  }

  @Test("sets .entitlementsMissing synchronously when CloudKit is unavailable")
  func entitlementsMissing() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(
      containerManager: manager,
      isCloudKitAvailable: false
    )
    #expect(coordinator.iCloudAvailability == .unavailable(reason: .entitlementsMissing))
  }

  @Test("maps CKAccountStatus.available → .available")
  func mapAvailable() {
    #expect(SyncCoordinator.mapAccountStatus(.available) == .available)
  }

  @Test("maps CKAccountStatus.noAccount → .unavailable(.notSignedIn)")
  func mapNoAccount() {
    #expect(
      SyncCoordinator.mapAccountStatus(.noAccount)
        == .unavailable(reason: .notSignedIn))
  }

  @Test("maps CKAccountStatus.restricted → .unavailable(.restricted)")
  func mapRestricted() {
    #expect(
      SyncCoordinator.mapAccountStatus(.restricted)
        == .unavailable(reason: .restricted))
  }

  @Test("maps CKAccountStatus.temporarilyUnavailable → .unavailable(.temporarilyUnavailable)")
  func mapTemporarilyUnavailable() {
    #expect(
      SyncCoordinator.mapAccountStatus(.temporarilyUnavailable)
        == .unavailable(reason: .temporarilyUnavailable))
  }

  @Test("maps CKAccountStatus.couldNotDetermine → .unknown (transient)")
  func mapCouldNotDetermine() {
    #expect(SyncCoordinator.mapAccountStatus(.couldNotDetermine) == .unknown)
  }

  @Test("stop() resets iCloudAvailability to .unknown when entitlements present")
  func stopResetsToUnknown() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(
      containerManager: manager,
      isCloudKitAvailable: true
    )
    coordinator.iCloudAvailability = .available

    coordinator.stop()

    #expect(coordinator.iCloudAvailability == .unknown)
  }

  @Test("stop() keeps .entitlementsMissing when entitlements are unavailable")
  func stopKeepsEntitlementsMissing() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(
      containerManager: manager,
      isCloudKitAvailable: false
    )
    coordinator.stop()

    #expect(
      coordinator.iCloudAvailability == .unavailable(reason: .entitlementsMissing)
    )
  }
}
