import Foundation
import Testing

@testable import Moolah

@Suite("ProfileStore — iCloudAvailability passthrough")
@MainActor
struct ProfileStoreAvailabilityTests {
  private func makeDefaults() throws -> UserDefaults {
    let suiteName = "com.moolah.test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  @Test("mirrors SyncCoordinator.iCloudAvailability")
  func mirrors() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(
      containerManager: manager,
      isCloudKitAvailable: true
    )
    let store = ProfileStore(
      defaults: try makeDefaults(),
      containerManager: manager,
      syncCoordinator: coordinator
    )

    coordinator.iCloudAvailability = .unavailable(reason: .notSignedIn)
    #expect(store.iCloudAvailability == .unavailable(reason: .notSignedIn))

    coordinator.iCloudAvailability = .available
    #expect(store.iCloudAvailability == .available)
  }

  @Test("returns .unknown when no coordinator is injected")
  func defaultsUnknown() throws {
    let store = ProfileStore(defaults: try makeDefaults())
    #expect(store.iCloudAvailability == .unknown)
  }
}
