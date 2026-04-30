import Foundation
import Testing

@testable import Moolah

@Suite("ProfileStore")
@MainActor
struct ProfileStoreTestsMoreSecondHalf {
  private func makeDefaults() -> UserDefaults {
    let suiteName = "com.moolah.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  private func makeProfile(label: String = "Test") -> Profile {
    Profile(label: label)
  }

  @Test("updateProfile calls onProfileChanged for CloudKit profiles")
  func updateCloudProfileCallsOnProfileChanged() async throws {
    let defaults = makeDefaults()
    let containerManager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: defaults, containerManager: containerManager)
    await drainPendingMutations(store)

    var profile = makeProfile(label: "Cloud")
    store.addProfile(profile)
    await drainPendingMutations(store)

    var changedIDs: [UUID] = []
    store.onProfileChanged = { id in changedIDs.append(id) }

    profile.label = "Updated"
    store.updateProfile(profile)
    await drainPendingMutations(store)

    #expect(changedIDs == [profile.id])
  }

  @Test("removeProfile calls onProfileDeleted for CloudKit profiles")
  func removeCloudProfileCallsOnProfileDeleted() async throws {
    let defaults = makeDefaults()
    let containerManager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: defaults, containerManager: containerManager)
    await drainPendingMutations(store)

    let profile = makeProfile(label: "Cloud")
    store.addProfile(profile)
    await drainPendingMutations(store)

    var deletedIDs: [UUID] = []
    store.onProfileDeleted = { id in deletedIDs.append(id) }

    store.removeProfile(profile.id)
    await drainPendingMutations(store)

    #expect(deletedIDs == [profile.id])
  }

  @Test("loadCloudProfiles does not clean up profiles on initial load")
  func initialLoadDoesNotCleanUp() async throws {
    let defaults = makeDefaults()
    let containerManager = try ProfileContainerManager.forTesting()

    // Pre-save a cloud profile as the active one
    let cloudProfileID = UUID()
    defaults.set(cloudProfileID.uuidString, forKey: "com.moolah.activeProfileID")

    let store = ProfileStore(defaults: defaults, containerManager: containerManager)

    var removedIDs: [UUID] = []
    store.onProfileRemoved = { id in removedIDs.append(id) }

    // Initial load with empty GRDB DB — should NOT trigger cleanup
    store.loadCloudProfiles(isInitialLoad: true)
    await drainPendingMutations(store)

    #expect(removedIDs.isEmpty)
  }

  // MARK: - Retry task lifecycle

  @Test("initial load schedules a retry when cloud store is empty but active profile is cloud")
  func initialLoadSchedulesRetry() throws {
    let defaults = makeDefaults()
    let cloudProfileID = UUID()
    defaults.set(cloudProfileID.uuidString, forKey: "com.moolah.activeProfileID")

    let containerManager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: defaults, containerManager: containerManager)

    #expect(store.isCloudLoadPending == true)
  }

  @Test("loadCloudProfiles cancels the pending retry once profiles are found")
  func loadCloudProfilesCancelsPendingRetry() async throws {
    let defaults = makeDefaults()
    let cloudProfileID = UUID()
    defaults.set(cloudProfileID.uuidString, forKey: "com.moolah.activeProfileID")

    let containerManager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: defaults, containerManager: containerManager)

    // Retry should be pending because the active profile has no backing record yet.
    #expect(store.isCloudLoadPending == true)

    // Insert the matching profile into GRDB directly — simulates the
    // sync engine landing a remote insert after the store was constructed.
    let profile = Profile(
      id: cloudProfileID,
      label: "Cloud",
      currencyCode: "AUD",
      financialYearStartMonth: 7
    )
    try await containerManager.profileIndexRepository.upsert(profile)

    // A remote-change-driven reload should find the profile and cancel the
    // pending retry so we don't do redundant work.
    store.loadCloudProfiles(isInitialLoad: false)
    await drainPendingMutations(store)

    #expect(store.profiles.count == 1)
    #expect(store.isCloudLoadPending == false)
  }
}
