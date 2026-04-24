import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("SyncCoordinator — applyAvailability")
@MainActor
struct SyncCoordinatorAccountChangeTests {
  private let testUser = CKRecord.ID(recordName: "test-user")
  private let otherUser = CKRecord.ID(recordName: "other-user")

  @Test("applyAvailability(.signIn) sets availability to .available")
  func applyAvailabilitySignIn() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(
      containerManager: manager,
      isCloudKitAvailable: true
    )
    coordinator.iCloudAvailability = .unavailable(reason: .notSignedIn)

    coordinator.applyAvailability(from: .signIn(currentUser: testUser))

    #expect(coordinator.iCloudAvailability == .available)
  }

  @Test("applyAvailability(.signOut) sets availability to .unavailable(.notSignedIn)")
  func applyAvailabilitySignOut() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(
      containerManager: manager,
      isCloudKitAvailable: true
    )
    coordinator.iCloudAvailability = .available

    coordinator.applyAvailability(from: .signOut(previousUser: testUser))

    #expect(coordinator.iCloudAvailability == .unavailable(reason: .notSignedIn))
  }

  @Test("applyAvailability(.switchAccounts) sets availability to .available")
  func applyAvailabilitySwitchAccounts() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(
      containerManager: manager,
      isCloudKitAvailable: true
    )
    coordinator.iCloudAvailability = .unknown

    coordinator.applyAvailability(
      from: .switchAccounts(previousUser: testUser, currentUser: otherUser)
    )

    #expect(coordinator.iCloudAvailability == .available)
  }
}
